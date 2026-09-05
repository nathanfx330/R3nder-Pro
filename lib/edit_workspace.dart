// ./lib/edit_workspace.dart
//
// GUI entry point for source-backed structural video editing.
//
// EDIT and MOSAIC are both canonical frame sources. This workspace owns only
// transient selection, import, transport, and export state. Durable changes are
// always serialized back into the same script through EditSurfaceDocument or
// MosaicSurfaceDocument. ProjectClock remains the sole playback authority for
// whichever structural source is selected.
//
// Playback follows the same timing rule as the terminal renderer: Flutter
// vsync asks ProjectClock what project time is current. A Ticker does not
// advance time itself. Integer project frames are published only when they
// change for authored/edit semantics, while exact rational position is
// published every vsync for smooth presentation paint.
//
// When a native libpulse bed is available, structural PLAY begins from SCRUB
// rather than MONOTONIC. NativeAudioSink captures that exact authored point,
// holds it through decoder/device prefill, then hands the SAME ProjectClock to
// AUDIO authority only when samples become audible. PAUSE reverses the order:
// the sink generation is stopped first, then SCRUB is reasserted, so a late
// native release can never overwrite the parked frame.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'audio_bed.dart';
import 'edit_linter.dart';
import 'edit_media_import.dart';
import 'edit_model.dart';
import 'edit_playback_clock.dart';
import 'edit_playback_frame.dart';
import 'edit_surface.dart';
import 'edit_surface_model.dart';
import 'edit_video_preview.dart';
import 'engine.dart';
import 'exporter.dart';
import 'media_layer.dart';
import 'mosaic_surface.dart';
import 'mosaic_surface_model.dart';
import 'native_file_dialog.dart';
import 'playback_trace.dart';
import 'project_clock.dart';
import 'session_store.dart';
import 'structural_source_export.dart';
import 'ui_theme.dart';

typedef EditVideoPicker = Future<String?> Function();
typedef EditVideoImporter = ImportedEditVideo Function(String pickedPath);
typedef EditWorkspaceRootResolver = String Function();
typedef EditAudioPlayerResolver = AudioBedPlayer? Function();
typedef EditPlaybackDeviceResolver = Future<PlaybackDevice> Function(
  AudioBedPlayer player,
);
typedef EditAudioProbe = Future<AudioBedInfo> Function(String path);
typedef EditStructuralExportRunner = Future<ExportResult> Function({
  required String source,
  required String structuralSource,
  required String outputPath,
  required VideoExportFormat format,
  required int fps,
  required int width,
  required int height,
  required String Function(String source) resolveSource,
  String? audioPath,
  double audioGainDb,
  String? musicPath,
  double musicGainDb,
  bool musicLoop,
  void Function(int done, int total)? onProgress,
  void Function(String status)? onStatus,
  ExportCancelToken? cancelToken,
});

Future<ExportResult> _defaultStructuralExportRunner({
  required String source,
  required String structuralSource,
  required String outputPath,
  required VideoExportFormat format,
  required int fps,
  required int width,
  required int height,
  required String Function(String source) resolveSource,
  String? audioPath,
  double audioGainDb = 0.0,
  String? musicPath,
  double musicGainDb = 0.0,
  bool musicLoop = false,
  void Function(int done, int total)? onProgress,
  void Function(String status)? onStatus,
  ExportCancelToken? cancelToken,
}) {
  return StructuralSourceExporter.export(
    source: source,
    structuralSource: structuralSource,
    outputPath: outputPath,
    format: format,
    fps: fps,
    width: width,
    height: height,
    resolveSource: resolveSource,
    audioPath: audioPath,
    audioGainDb: audioGainDb,
    musicPath: musicPath,
    musicGainDb: musicGainDb,
    musicLoop: musicLoop,
    onProgress: onProgress,
    onStatus: onStatus,
    cancelToken: cancelToken,
  );
}

AudioBedPlayer? _defaultAudioPlayerResolver() => sharedAudioBedPlayer;

Future<PlaybackDevice> _defaultPlaybackDeviceResolver(
  AudioBedPlayer player,
) async {
  String? storedId;
  try {
    final SessionStore session = SessionStore(
      baseDir: resolvePortableBaseDir(),
    )..load();
    storedId = session.audioDeviceId;
  } catch (_) {
    storedId = null;
  }

  try {
    final List<PlaybackDevice> available = await player.listDevices();
    return resolveDevice(available, storedId);
  } catch (_) {
    return const PlaybackDevice(
      id: null,
      description: 'System Default',
    );
  }
}

class EditWorkspace extends StatefulWidget {
  final String source;
  final int currentFrame;
  final int voiceFrames;
  final int musicFrames;
  final bool musicLoops;
  final R3Theme theme;
  final ValueChanged<String> onSourceChanged;
  final ValueChanged<int> onSeek;

  /// Test seams. Production uses the GTK chooser, workspace MLT import, native
  /// realtime ProjectClock adapter, borrowed app audio backend, active
  /// workspace, structural exporter, native preview decoder, and workspace
  /// media resolver.
  final EditVideoPicker? pickVideo;
  final EditVideoImporter? importVideo;
  final EditPlaybackClockFactory? playbackClockFactory;
  final EditWorkspaceRootResolver? workspaceRootResolver;
  final EditAudioPlayerResolver? audioPlayerResolver;
  final EditPlaybackDeviceResolver? playbackDeviceResolver;
  final EditAudioProbe? audioProbe;
  final EditStructuralExportRunner? exportSource;
  final MediaDecoderBackend? backend;
  final String Function(String source)? resolveSource;

  const EditWorkspace({
    super.key,
    required this.source,
    required this.currentFrame,
    required this.theme,
    required this.onSourceChanged,
    required this.onSeek,
    this.voiceFrames = 0,
    this.musicFrames = 0,
    this.musicLoops = false,
    this.pickVideo,
    this.importVideo,
    this.playbackClockFactory,
    this.workspaceRootResolver,
    this.audioPlayerResolver,
    this.playbackDeviceResolver,
    this.audioProbe,
    this.exportSource,
    this.backend,
    this.resolveSource,
  });

  @override
  State<EditWorkspace> createState() => _EditWorkspaceState();
}

class _EditWorkspaceState extends State<EditWorkspace>
    with SingleTickerProviderStateMixin {
  late String _workingSource;
  late int _displayFrame;
  late final Ticker _playTicker;
  late final ValueNotifier<EditPlaybackFrameState> _playbackFrame;
  late final ValueNotifier<EditPlaybackExactState> _playbackExact;
  EditPlaybackClock? _playClock;
  AudioBedPlayer? _activeAudioPlayer;
  String? _selectedSourceRef;
  bool _importing = false;
  bool _playing = false;
  bool _startingPlayback = false;
  bool _exporting = false;
  int _exportDone = 0;
  int _exportTotal = 0;
  String? _exportStatus;
  ExportCancelToken? _exportCancelToken;
  int _cachedSourceEndFrame = 0;
  int? _lastPolledPlaybackFrame;
  int _transportGeneration = 0;
  String? _musicProbePath;
  double _musicDurationSec = 0.0;
  String? _error;

  bool get _traceProductionPlayback => widget.playbackClockFactory == null;

  @override
  void initState() {
    super.initState();
    _workingSource = widget.source;
    _displayFrame = widget.currentFrame;
    _refreshSourceSelectionAndEnd();
    _displayFrame = _displayFrame.clamp(0, _cachedSourceEndFrame);
    _playbackFrame = ValueNotifier<EditPlaybackFrameState>(
      EditPlaybackFrameState(frame: _displayFrame, isPlaying: false),
    );
    _playbackExact = ValueNotifier<EditPlaybackExactState>(
      EditPlaybackExactState(
        frame: _displayFrame,
        phaseNumerator: 0,
        phaseDenominator: 1,
        isPlaying: false,
      ),
    );
    _playTicker = createTicker(_onPlaybackTick);
  }

  @override
  void didUpdateWidget(covariant EditWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.source != oldWidget.source && widget.source != _workingSource) {
      _workingSource = widget.source;
      _error = null;
      _refreshSourceSelectionAndEnd();
      _stopPlaybackAt(
        widget.currentFrame,
        publish: false,
        traceReason: 'source_change',
      );
      return;
    }

    if (!_playing &&
        !_startingPlayback &&
        widget.currentFrame != oldWidget.currentFrame) {
      _displayFrame = widget.currentFrame.clamp(0, _cachedSourceEndFrame);
      _lastPolledPlaybackFrame = _displayFrame;
      _publishPlaybackFrame(_displayFrame, playing: false);
      _publishPlaybackExactFrame(_displayFrame, playing: false);
    }
  }

  @override
  void dispose() {
    _transportGeneration++;
    _exportCancelToken?.cancel();
    PlaybackTrace.instance.stop(reason: 'workspace_dispose');
    _playTicker.stop();
    _playTicker.dispose();
    _playbackFrame.dispose();
    _playbackExact.dispose();

    final AudioBedPlayer? player = _activeAudioPlayer;
    _activeAudioPlayer = null;
    final EditPlaybackClock? clock = _playClock;
    _playClock = null;
    if (player != null) {
      unawaited(player.stop().whenComplete(() => clock?.dispose()));
    } else {
      clock?.dispose();
    }
    super.dispose();
  }

  void _publishPlaybackFrame(int frame, {required bool playing}) {
    final EditPlaybackFrameState next = EditPlaybackFrameState(
      frame: frame,
      isPlaying: playing,
    );
    if (_playbackFrame.value != next) {
      _playbackFrame.value = next;
      PlaybackTrace.instance.recordIntegerPublish(frame, playing);
    }
  }

  void _publishPlaybackExact(ProjectTime time, {required bool playing}) {
    final EditPlaybackExactState next = EditPlaybackExactState(
      frame: time.frame,
      phaseNumerator: time.phaseNumerator,
      phaseDenominator: time.phaseDenominator,
      isPlaying: playing,
    );
    if (_playbackExact.value != next) {
      _playbackExact.value = next;
      PlaybackTrace.instance.recordExactPublish(time, playing);
    }
  }

  void _publishPlaybackExactFrame(int frame, {required bool playing}) {
    _publishPlaybackExact(
      ProjectTime(
        frame: frame,
        mode: playing ? ProjectClockMode.monotonic : ProjectClockMode.scrub,
      ),
      playing: playing,
    );
  }

  EditPlaybackClock _ensurePlaybackClock() {
    final EditPlaybackClock? existing = _playClock;
    if (existing != null) return existing;

    final RationalFrameRate rate = RationalFrameRate(engineFps);
    final EditPlaybackClock created =
        (widget.playbackClockFactory ?? NativeEditPlaybackClock.new)(rate);
    _playClock = created;
    return created;
  }

  List<StructuralSourceRef> _structuralSources(EditDocumentModel model) {
    return <StructuralSourceRef>[
      for (final EditSequence edit in model.edits)
        StructuralSourceRef.tryParse('EDIT.${edit.id}')!,
      for (final MosaicSequence mosaic in model.mosaics)
        StructuralSourceRef.tryParse('MOSAIC.${mosaic.id}')!,
    ];
  }

  StructuralSourceRef? _selectedRefFor(EditDocumentModel model) {
    final List<StructuralSourceRef> refs = _structuralSources(model);
    if (refs.isEmpty) {
      _selectedSourceRef = null;
      return null;
    }

    final String? selected = _selectedSourceRef;
    if (selected != null) {
      for (final StructuralSourceRef ref in refs) {
        if (ref.canonicalSource == selected) return ref;
      }
    }

    final StructuralSourceRef fallback = refs.first;
    _selectedSourceRef = fallback.canonicalSource;
    return fallback;
  }

  void _refreshSourceSelectionAndEnd() {
    try {
      final EditDocumentModel model = EditDocumentModel.parse(_workingSource);
      final StructuralSourceRef? selected = _selectedRefFor(model);
      _cachedSourceEndFrame = selected == null
          ? 0
          : model.structuralSourceFrameCount(selected);
    } catch (_) {
      _cachedSourceEndFrame = 0;
    }
  }

  int _sourceEndFrame() => _cachedSourceEndFrame;

  static String? _existingAudioPath(String? path) {
    if (path == null || path.trim().isEmpty) return null;
    try {
      return File(path).existsSync() ? path : null;
    } catch (_) {
      return null;
    }
  }

  Future<double> _secondaryMusicSeek(
    String musicPath,
    double startSec,
  ) async {
    if (startSec <= 0.0) return 0.0;

    if (_musicProbePath != musicPath) {
      _musicProbePath = musicPath;
      _musicDurationSec = 0.0;
      try {
        final AudioBedInfo info =
            await (widget.audioProbe ?? AudioBedProbe.probe)(musicPath);
        if (info.ok) _musicDurationSec = info.durationSec;
      } catch (_) {
        _musicDurationSec = 0.0;
      }
    }

    return _musicDurationSec > 0.0
        ? loopedSeek(startSec, _musicDurationSec)
        : startSec;
  }

  void _commitPlaybackStarted(
    int generation,
    StructuralSourceRef source,
    int start,
    ProjectTime startTime, {
    String? warning,
  }) {
    if (!mounted || generation != _transportGeneration) return;

    if (_traceProductionPlayback) {
      PlaybackTrace.instance.start(
        projectFps: engineFps,
        editId: source.canonicalSource,
        startFrame: start,
      );
    }

    _playTicker.stop();
    _lastPolledPlaybackFrame = start;
    _displayFrame = start;
    _startingPlayback = false;
    _playing = true;
    _error = warning;
    _publishPlaybackFrame(start, playing: true);
    _publishPlaybackExact(startTime, playing: true);
    _playTicker.start();
    setState(() {});
  }

  Future<void> _togglePlayback(StructuralSourceRef source, int end) async {
    if (_playing) {
      _pausePlayback();
      return;
    }
    if (_startingPlayback || end <= 0 || _exporting) return;

    int start = _displayFrame.clamp(0, end);
    if (start >= end) {
      start = 0;
      _displayFrame = 0;
      widget.onSeek(0);
    }

    final int generation = ++_transportGeneration;
    setState(() {
      _startingPlayback = true;
      _error = null;
    });

    try {
      final EditPlaybackClock clock = _ensurePlaybackClock();
      final ProjectTime startTime = ProjectTime(
        frame: start,
        mode: ProjectClockMode.monotonic,
      );

      String? workspaceWarning;
      _WorkspaceAudioMix audioMix = const _WorkspaceAudioMix(
        audioPath: null,
        audioGainDb: 0.0,
        musicPath: null,
        musicGainDb: 0.0,
        musicLoop: false,
      );
      try {
        final String workspace =
            (widget.workspaceRootResolver ?? resolveActiveWorkspaceRoot)();
        audioMix = _WorkspaceAudioMix.load(workspace);
      } catch (error) {
        workspaceWarning = 'STRUCTURAL AUDIO CONFIG UNAVAILABLE\n$error';
      }

      final AudioBedPlayer? player =
          (widget.audioPlayerResolver ?? _defaultAudioPlayerResolver)();
      final String? bed = _existingAudioPath(audioMix.audioPath);
      final String? music = _existingAudioPath(audioMix.musicPath);
      final String? primary = bed ?? music;

      if (player == null || primary == null) {
        if (generation != _transportGeneration || !mounted) return;
        clock.playFrom(startTime);
        _activeAudioPlayer = null;
        _commitPlaybackStarted(
          generation,
          source,
          start,
          startTime,
          warning: workspaceWarning,
        );
        return;
      }

      PlaybackDevice device;
      try {
        device = await (widget.playbackDeviceResolver ??
            _defaultPlaybackDeviceResolver)(player);
      } catch (_) {
        device = const PlaybackDevice(
          id: null,
          description: 'System Default',
        );
      }
      if (generation != _transportGeneration || !mounted) return;

      final double startSec = start / engineFps;
      final double remainingSec = (end - start) / engineFps;
      final bool bedIsPrimary = bed != null;
      double? musicSeekSec;
      if (bedIsPrimary &&
          music != null &&
          audioMix.musicLoop &&
          startSec > 0.0) {
        musicSeekSec = await _secondaryMusicSeek(music, startSec);
        if (generation != _transportGeneration || !mounted) return;
      }

      clock.holdAt(startTime.withMode(ProjectClockMode.scrub));
      _activeAudioPlayer = player;

      String? audioWarning = workspaceWarning;
      try {
        await player.play(
          primary,
          startSec: startSec,
          gainDb: bedIsPrimary
              ? audioMix.audioGainDb
              : audioMix.musicGainDb,
          loop: bedIsPrimary ? false : audioMix.musicLoop,
          device: device,
          musicPath: bedIsPrimary ? music : null,
          musicGainDb: audioMix.musicGainDb,
          musicLoop: audioMix.musicLoop,
          musicSeekSec: musicSeekSec,
          durationSec: remainingSec,
        );
      } catch (error) {
        audioWarning = 'STRUCTURAL AUDIO UNAVAILABLE\n$error';
      }

      if (generation != _transportGeneration || !mounted) return;

      if (!player.isPlaying) {
        _activeAudioPlayer = null;
        clock.playFrom(startTime);
      } else if (player.backendName != 'libpulse') {
        clock.playFrom(startTime);
      }

      _commitPlaybackStarted(
        generation,
        source,
        start,
        startTime,
        warning: audioWarning,
      );
    } catch (error) {
      if (generation != _transportGeneration || !mounted) return;
      _playTicker.stop();
      PlaybackTrace.instance.stop(reason: 'play_error');
      final AudioBedPlayer? player = _activeAudioPlayer;
      _activeAudioPlayer = null;
      if (player != null) unawaited(player.stop());
      setState(() {
        _startingPlayback = false;
        _playing = false;
        _publishPlaybackFrame(_displayFrame, playing: false);
        _publishPlaybackExactFrame(_displayFrame, playing: false);
        _error = 'STRUCTURAL PLAYBACK UNAVAILABLE\n$error';
      });
    }
  }

  void _onPlaybackTick(Duration elapsed) {
    if (!_playing || !mounted) return;

    final int end = _sourceEndFrame();
    if (end <= 0) {
      _stopPlaybackAt(0, publish: true, traceReason: 'empty_source');
      return;
    }

    final EditPlaybackClock? clock = _playClock;
    if (clock == null) return;

    final ProjectTime sampled;
    try {
      sampled = clock.sample();
      PlaybackTrace.instance.recordTick(elapsed, sampled);
    } catch (error) {
      _playTicker.stop();
      PlaybackTrace.instance.stop(reason: 'clock_error');
      final AudioBedPlayer? player = _activeAudioPlayer;
      _activeAudioPlayer = null;
      if (player != null) unawaited(player.stop());
      setState(() {
        _playing = false;
        _startingPlayback = false;
        _publishPlaybackFrame(_displayFrame, playing: false);
        _publishPlaybackExactFrame(_displayFrame, playing: false);
        _error = 'STRUCTURAL PLAYBACK CLOCK FAILED\n$error';
      });
      return;
    }

    final int frame = sampled.frame.clamp(0, end);
    if (frame >= end) {
      _stopPlaybackAt(end, publish: true, traceReason: 'end');
      return;
    }

    if (sampled.frame < 0) {
      _publishPlaybackExactFrame(0, playing: true);
    } else {
      _publishPlaybackExact(sampled, playing: true);
    }

    if (frame == _lastPolledPlaybackFrame) return;
    _lastPolledPlaybackFrame = frame;
    _displayFrame = frame;
    _publishPlaybackFrame(frame, playing: true);
  }

  void _pausePlayback() {
    final EditPlaybackClock? clock = _playClock;
    int frame = _displayFrame.clamp(0, _sourceEndFrame());
    if (clock != null) {
      try {
        frame = clock.sample().frame.clamp(0, _sourceEndFrame());
      } catch (_) {}
    }
    _stopPlaybackAt(frame, publish: true, traceReason: 'pause');
  }

  void _holdClockAt(EditPlaybackClock? clock, int frame) {
    if (clock == null) return;
    try {
      clock.holdAt(
        ProjectTime(
          frame: frame,
          mode: ProjectClockMode.scrub,
        ),
      );
    } catch (_) {}
  }

  void _stopPlaybackAt(
    int frame, {
    required bool publish,
    String traceReason = 'stop',
  }) {
    _playTicker.stop();
    final int generation = ++_transportGeneration;

    final int safeFrame = frame.clamp(0, _sourceEndFrame());
    final EditPlaybackClock? clock = _playClock;
    final AudioBedPlayer? player = _activeAudioPlayer;
    _activeAudioPlayer = null;

    _lastPolledPlaybackFrame = safeFrame;
    final bool changed =
        _playing || _startingPlayback || _displayFrame != safeFrame;
    _playing = false;
    _startingPlayback = false;
    _displayFrame = safeFrame;
    _publishPlaybackFrame(safeFrame, playing: false);
    _publishPlaybackExactFrame(safeFrame, playing: false);
    PlaybackTrace.instance.stop(reason: traceReason);

    if (player == null) {
      _holdClockAt(clock, safeFrame);
    } else {
      unawaited(() async {
        try {
          await player.stop();
        } catch (_) {}
        if (generation != _transportGeneration) return;
        _holdClockAt(clock, safeFrame);
      }());
    }

    if (publish && safeFrame != widget.currentFrame) {
      widget.onSeek(safeFrame);
    }
    if (changed && mounted) setState(() {});
  }

  void _seekFromSurface(int frame) {
    final int safeFrame = frame.clamp(0, _sourceEndFrame());
    if (_playing || _startingPlayback) {
      _stopPlaybackAt(
        safeFrame,
        publish: false,
        traceReason: 'seek_during_play',
      );
    } else {
      final EditPlaybackClock? clock = _playClock;
      _holdClockAt(clock, safeFrame);
      _displayFrame = safeFrame;
      _publishPlaybackFrame(safeFrame, playing: false);
      _publishPlaybackExactFrame(safeFrame, playing: false);
      if (mounted) setState(() {});
    }

    _lastPolledPlaybackFrame = safeFrame;
    widget.onSeek(safeFrame);
  }

  void _selectSource(EditDocumentModel model, String source) {
    final StructuralSourceRef? ref = StructuralSourceRef.tryParse(source);
    if (ref == null ||
        !model.containsStructuralSource(ref) ||
        _exporting ||
        _startingPlayback) {
      return;
    }
    if (_playing) _pausePlayback();

    setState(() {
      _selectedSourceRef = ref.canonicalSource;
      _cachedSourceEndFrame = model.structuralSourceFrameCount(ref);
      _displayFrame = _displayFrame.clamp(0, _cachedSourceEndFrame);
      _lastPolledPlaybackFrame = _displayFrame;
      _publishPlaybackFrame(_displayFrame, playing: false);
      _publishPlaybackExactFrame(_displayFrame, playing: false);
      _error = null;
    });
    widget.onSeek(_displayFrame);
  }

  void _applySourceChange(String next, {String? selectSource}) {
    if (_playing || _startingPlayback) _pausePlayback();
    setState(() {
      _workingSource = next;
      if (selectSource != null) _selectedSourceRef = selectSource;
      _error = null;
      _refreshSourceSelectionAndEnd();
      _displayFrame = _displayFrame.clamp(0, _cachedSourceEndFrame);
      _lastPolledPlaybackFrame = _displayFrame;
      _publishPlaybackFrame(_displayFrame, playing: false);
      _publishPlaybackExactFrame(_displayFrame, playing: false);
    });
    widget.onSourceChanged(next);
  }

  Future<void> _addVideo(String trackId) async {
    if (_importing || _exporting || _startingPlayback) return;
    if (_playing) _pausePlayback();
    setState(() {
      _importing = true;
      _error = null;
    });

    try {
      final String? picked = await (widget.pickVideo ?? pickNativeVideoFile)();
      if (picked == null) return;

      final ImportedEditVideo imported =
          (widget.importVideo ?? importVideoToWorkspace)(picked);
      final EditDocumentModel model = EditDocumentModel.parse(_workingSource);
      final ExactClipSpeed importedSpeed = ExactClipSpeed(
        imported.speedNumerator,
        imported.speedDenominator,
      );

      late String next;
      late String targetEditId;
      late String targetClipId;

      if (model.edits.isEmpty) {
        targetEditId = 'main';
        targetClipId = imported.clipBaseId;
        next = createEditWithClip(
          source: _workingSource,
          editId: targetEditId,
          trackId: trackId,
          clipId: targetClipId,
          mediaSource: imported.authoredSource,
          atFrame: _displayFrame,
          durationFrames: imported.durationFrames,
        );
      } else {
        final StructuralSourceRef? selected = _selectedRefFor(model);
        targetEditId = selected?.kind == StructuralSourceKind.edit
            ? selected!.id
            : model.edits.first.id;
        final EditSurfaceDocument document =
            EditSurfaceDocument.parse(_workingSource, targetEditId);
        targetClipId = document.nextClipId(trackId, imported.clipBaseId);
        next = document.addClip(
          trackId: trackId,
          clipId: targetClipId,
          mediaSource: imported.authoredSource,
          atFrame: _displayFrame,
          durationFrames: imported.durationFrames,
        );
      }

      if (importedSpeed != ExactClipSpeed(1)) {
        next = EditSurfaceDocument.parse(next, targetEditId).setSpeed(
          trackId,
          targetClipId,
          importedSpeed,
        );
      }

      if (!mounted) return;
      _applySourceChange(next, selectSource: 'EDIT.$targetEditId');
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _newEdit(EditDocumentModel model) {
    if (_exporting || _startingPlayback) return;
    final Set<String> ids = model.edits.map((EditSequence edit) => edit.id).toSet();
    String id = 'edit';
    int suffix = 2;
    while (ids.contains(id)) {
      id = 'edit_$suffix';
      suffix++;
    }

    final String newline = _workingSource.contains('\r\n') ? '\r\n' : '\n';
    final StringBuffer out = StringBuffer(_workingSource);
    if (_workingSource.isNotEmpty &&
        !_workingSource.endsWith('\n') &&
        !_workingSource.endsWith('\r')) {
      out.write(newline);
    }
    out
      ..write('[EDIT:$id]$newline')
      ..write('[/EDIT]$newline');

    final String next = out.toString();
    EditDocumentModel.parse(next);
    _applySourceChange(next, selectSource: 'EDIT.$id');
  }

  void _newMosaic(EditDocumentModel model) {
    if (_exporting || _startingPlayback) return;

    final Set<String> ids =
        model.mosaics.map((MosaicSequence mosaic) => mosaic.id).toSet();
    String id = 'mosaic';
    int suffix = 2;
    while (ids.contains(id)) {
      id = 'mosaic_$suffix';
      suffix++;
    }

    try {
      final String next = createEmptyMosaic(
        source: _workingSource,
        mosaicId: id,
      );
      _applySourceChange(next, selectSource: 'MOSAIC.$id');
    } catch (error) {
      setState(() => _error = '$error');
    }
  }

  Future<void> _addStructuralSource(
    EditDocumentModel model,
    EditSequence edit,
  ) async {
    if (_exporting || _startingPlayback) return;
    final List<StructuralSourceRef> choices = _structuralSources(model)
        .where((StructuralSourceRef ref) =>
            ref.canonicalSource != 'EDIT.${edit.id}')
        .toList(growable: false);
    if (choices.isEmpty) {
      setState(() => _error = 'No other EDIT or MOSAIC source is available.');
      return;
    }

    String selected = choices.first.canonicalSource;
    final String? picked = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            return AlertDialog(
              backgroundColor: R3Theme.panel,
              title: Text('Add structural source', style: widget.theme.value),
              content: SizedBox(
                width: sc(420),
                child: DropdownButton<String>(
                  value: selected,
                  isExpanded: true,
                  dropdownColor: R3Theme.panel,
                  style: widget.theme.value,
                  items: [
                    for (final StructuralSourceRef ref in choices)
                      DropdownMenuItem<String>(
                        value: ref.canonicalSource,
                        child: Text(ref.canonicalSource),
                      ),
                  ],
                  onChanged: (String? value) {
                    if (value == null) return;
                    setDialogState(() => selected = value);
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('CANCEL'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(selected),
                  child: const Text('ADD'),
                ),
              ],
            );
          },
        );
      },
    );
    if (picked == null || !mounted) return;

    try {
      final StructuralSourceRef ref = StructuralSourceRef.tryParse(picked)!;
      final int duration = model.structuralSourceFrameCount(ref);
      if (duration <= 0) {
        throw StateError('${ref.canonicalSource} has no authored frames.');
      }
      final EditSurfaceDocument document =
          EditSurfaceDocument.parse(_workingSource, edit.id);
      final String baseId = '${ref.kind.name}_${ref.id}';
      final String clipId = document.nextClipId('V1', baseId);
      final String next = document.addClip(
        trackId: 'V1',
        clipId: clipId,
        mediaSource: ref.canonicalSource,
        atFrame: _displayFrame,
        durationFrames: duration,
      );

      final EditLintResult lint =
          EditGraphLinter.lint(EditDocumentModel.parse(next));
      if (!lint.isValid) {
        final EditLintIssue issue = lint.issues.first;
        throw StateError('${issue.message} Path: ${issue.editPath.join(' -> ')}');
      }
      _applySourceChange(next, selectSource: 'EDIT.${edit.id}');
    } catch (error) {
      setState(() => _error = '$error');
    }
  }

  Future<_StructuralExportChoice?> _chooseExportSettings() async {
    String resolution = '1080p';
    VideoExportFormat format = VideoExportFormat.h264Solid;

    return showDialog<_StructuralExportChoice>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            return AlertDialog(
              backgroundColor: R3Theme.panel,
              title: Text('Export structural source', style: widget.theme.value),
              content: SizedBox(
                width: sc(420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('RESOLUTION', style: widget.theme.micro),
                    SizedBox(height: sc(5)),
                    DropdownButton<String>(
                      key: const ValueKey<String>('structural-export-resolution'),
                      value: resolution,
                      isExpanded: true,
                      dropdownColor: R3Theme.panel,
                      style: widget.theme.value,
                      items: const <DropdownMenuItem<String>>[
                        DropdownMenuItem<String>(
                          value: '720p',
                          child: Text('720p   1280 × 720'),
                        ),
                        DropdownMenuItem<String>(
                          value: '1080p',
                          child: Text('1080p   1920 × 1080'),
                        ),
                        DropdownMenuItem<String>(
                          value: '4K',
                          child: Text('4K   3840 × 2160'),
                        ),
                      ],
                      onChanged: (String? value) {
                        if (value == null) return;
                        setDialogState(() => resolution = value);
                      },
                    ),
                    SizedBox(height: sc(14)),
                    Text('FORMAT', style: widget.theme.micro),
                    SizedBox(height: sc(5)),
                    DropdownButton<VideoExportFormat>(
                      key: const ValueKey<String>('structural-export-format'),
                      value: format,
                      isExpanded: true,
                      dropdownColor: R3Theme.panel,
                      style: widget.theme.value,
                      items: const <DropdownMenuItem<VideoExportFormat>>[
                        DropdownMenuItem<VideoExportFormat>(
                          value: VideoExportFormat.h264Solid,
                          child: Text('H.264 MP4'),
                        ),
                        DropdownMenuItem<VideoExportFormat>(
                          value: VideoExportFormat.proresAlpha,
                          child: Text('ProRes 4444 Alpha'),
                        ),
                        DropdownMenuItem<VideoExportFormat>(
                          value: VideoExportFormat.lumaMatte,
                          child: Text('H.264 Fill + Matte'),
                        ),
                      ],
                      onChanged: (VideoExportFormat? value) {
                        if (value == null) return;
                        setDialogState(() => format = value),
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('CANCEL'),
                ),
                TextButton(
                  onPressed: () {
                    final (int width, int height) =
                        _resolutionDimensions(resolution);
                    Navigator.of(context).pop(
                      _StructuralExportChoice(
                        resolution: resolution,
                        width: width,
                        height: height,
                        format: format,
                      ),
                    );
                  },
                  child: const Text('EXPORT'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  static (int, int) _resolutionDimensions(String resolution) {
    switch (resolution) {
      case '720p':
        return (1280, 720);
      case '4K':
        return (3840, 2160);
      case '1080p':
      default:
        return (1920, 1080);
    }
  }

  static String _exportStem(StructuralSourceRef source) {
    String stem = source.canonicalSource
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    stem = stem.replaceAll(RegExp(r'^_+|_+$'), '');
    return stem.isEmpty ? 'structural_source' : stem;
  }

  Future<void> _exportSelected(StructuralSourceRef selected) async {
    if (_exporting || _importing || _startingPlayback) return;
    if (_playing) _pausePlayback();

    final _StructuralExportChoice? choice = await _chooseExportSettings();
    if (choice == null || !mounted) return;

    final ExportCancelToken cancelToken = ExportCancelToken();
    _exportCancelToken = cancelToken;

    setState(() {
      _exporting = true;
      _exportDone = 0;
      _exportTotal = 0;
      _exportStatus = 'PREPARING ${selected.canonicalSource}';
      _error = null;
    });

    try {
      final String workspace =
          (widget.workspaceRootResolver ?? resolveActiveWorkspaceRoot)();
      final _WorkspaceAudioMix audioMix = _WorkspaceAudioMix.load(workspace);
      final Directory outputDirectory = Directory(
        '$workspace${Platform.pathSeparator}output_frames',
      );
      outputDirectory.createSync(recursive: true);

      final String extension =
          choice.format == VideoExportFormat.proresAlpha ? 'mov' : 'mp4';
      final String outputPath =
          '${outputDirectory.path}${Platform.pathSeparator}'
          '${_exportStem(selected)}_${choice.resolution.toLowerCase()}.$extension';

      final EditStructuralExportRunner runner =
          widget.exportSource ?? _defaultStructuralExportRunner;
      final ExportResult result = await runner(
        source: _workingSource,
        structuralSource: selected.canonicalSource,
        outputPath: outputPath,
        format: choice.format,
        fps: engineFps,
        width: choice.width,
        height: choice.height,
        resolveSource: widget.resolveSource ?? resolveWorkspaceMediaSource,
        audioPath: audioMix.audioPath,
        audioGainDb: audioMix.audioGainDb,
        musicPath: audioMix.musicPath,
        musicGainDb: audioMix.musicGainDb,
        musicLoop: audioMix.musicLoop,
        cancelToken: cancelToken,
        onProgress: (int done, int total) {
          if (!mounted) return;
          setState(() {
            _exportDone = done;
            _exportTotal = total;
          });
        },
        onStatus: (String status) {
          if (!mounted) return;
          setState(() => _exportStatus = status.toUpperCase());
        },
      );

      if (!mounted) return;
      setState(() {
        if (result.cancelled) {
          _exportStatus = 'EXPORT CANCELLED';
        } else if (result.success) {
          final String matte = result.mattePath == null
              ? ''
              : '   MATTE ${result.mattePath}';
          _exportStatus = 'EXPORTED ${result.outputPath}$matte';
        } else {
          _exportStatus = null;
          _error = result.error ?? 'Structural export failed.';
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _exportStatus = null;
        _error = '$error';
      });
    } finally {
      _exportCancelToken = null;
      if (mounted) {
        setState(() => _exporting = false);
      }
    }
  }

  void _cancelExport() {
    if (!_exporting) return;
    _exportCancelToken?.cancel();
    setState(() => _exportStatus = 'CANCELLING EXPORT');
  }

  @override
  Widget build(BuildContext context) {
    final EditDocumentModel? model = _parseModel();
    final StructuralSourceRef? selected =
        model == null ? null : _selectedRefFor(model);
    final EditSequence? edit = model != null &&
            selected?.kind == StructuralSourceKind.edit
        ? model.edit(selected!.id)
        : null;
    final MosaicSequence? mosaic = model != null &&
            selected?.kind == StructuralSourceKind.mosaic
        ? model.mosaic(selected!.id)
        : null;

    return Material(
      type: MaterialType.transparency,
      child: Column(
        children: [
          _buildImportBar(model, selected, edit, mosaic),
          if (_error != null)
            Container(
              width: double.infinity,
              padding: EdgeInsets.symmetric(
                horizontal: sc(12),
                vertical: sc(6),
              ),
              color: R3Theme.danger.withValues(alpha: 0.12),
              child: Text(
                _error!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: widget.theme.fine.copyWith(color: R3Theme.danger),
              ),
            ),
          Expanded(
            child: model == null
                ? _message('STRUCTURAL VIDEO LANGUAGE ERROR')
                : selected == null
                    ? _message(
                        'NO VIDEO EDIT YET\n\nADD VIDEO creates the first V1 clip.',
                      )
                    : EditPlaybackFrameScope(
                        listenable: _playbackFrame,
                        exactListenable: _playbackExact,
                        child: edit != null
                            ? EditSurface(
                                key: ValueKey('edit:${edit.id}'),
                                source: _workingSource,
                                editId: edit.id,
                                currentFrame: _displayFrame.clamp(
                                  0,
                                  edit.projectFrameCount,
                                ),
                                isPlaying: _playing,
                                voiceFrames: widget.voiceFrames,
                                musicFrames: widget.musicFrames,
                                musicLoops: widget.musicLoops,
                                theme: widget.theme,
                                onSourceChanged: _applySourceChange,
                                onSeek: _seekFromSurface,
                                backend: widget.backend,
                                resolveSource: widget.resolveSource,
                              )
                            : MosaicSurface(
                                key: ValueKey('mosaic:${mosaic!.id}'),
                                source: _workingSource,
                                mosaicId: mosaic.id,
                                currentFrame: _displayFrame.clamp(
                                  0,
                                  mosaic.projectFrameCount,
                                ),
                                isPlaying: _playing,
                                theme: widget.theme,
                                onSourceChanged: _applySourceChange,
                                onSeek: _seekFromSurface,
                                backend: widget.backend,
                                resolveSource: widget.resolveSource,
                              ),
                      ),
          ),
        ],
      ),
    );
  }

  EditDocumentModel? _parseModel() {
    try {
      final EditDocumentModel model = EditDocumentModel.parse(_workingSource);
      final StructuralSourceRef? selected = _selectedRefFor(model);
      _cachedSourceEndFrame = selected == null
          ? 0
          : model.structuralSourceFrameCount(selected);
      return model;
    } catch (error) {
      _error ??= '$error';
      return null;
    }
  }

  Widget _buildImportBar(
    EditDocumentModel? model,
    StructuralSourceRef? selected,
    EditSequence? edit,
    MosaicSequence? mosaic,
  ) {
    final int selectedEnd = selected == null || model == null
        ? 0
        : model.structuralSourceFrameCount(selected);
    final List<StructuralSourceRef> refs =
        model == null ? const <StructuralSourceRef>[] : _structuralSources(model);
    final bool mediaMode = selected == null || edit != null;

    final List<Widget> controls = <Widget>[
      R3MicroLabel('STRUCTURE', theme: widget.theme, accent: true),
      if (refs.isNotEmpty)
        SizedBox(
          width: sc(180),
          child: DropdownButton<String>(
            key: const ValueKey<String>('structural-source-selector'),
            value: selected?.canonicalSource,
            isExpanded: true,
            dropdownColor: R3Theme.panel,
            style: widget.theme.micro,
            underline: Container(height: 1, color: R3Theme.hairline),
            items: [
              for (final StructuralSourceRef ref in refs)
                DropdownMenuItem<String>(
                  value: ref.canonicalSource,
                  child: Text(ref.canonicalSource),
                ),
            ],
            onChanged: _playing ||
                    _startingPlayback ||
                    _exporting ||
                    model == null
                ? null
                : (String? value) {
                    if (value != null) _selectSource(model, value);
                  },
          ),
        ),
      R3Button(
        'NEW EDIT',
        theme: widget.theme,
        compact: true,
        onPressed: model == null ||
                _playing ||
                _startingPlayback ||
                _exporting
            ? null
            : () => _newEdit(model),
      ),
      R3Button(
        'NEW MOSAIC',
        theme: widget.theme,
        compact: true,
        onPressed: model == null ||
                _playing ||
                _startingPlayback ||
                _exporting
            ? null
            : () => _newMosaic(model),
      ),
      if (mediaMode) ...[
        SizedBox(width: sc(5)),
        R3MicroLabel('MEDIA', theme: widget.theme, accent: true),
        R3Button(
          'ADD VIDEO',
          theme: widget.theme,
          compact: true,
          kind: R3ButtonKind.primary,
          onPressed: _importing || _startingPlayback || _exporting
              ? null
              : () => _addVideo('V1'),
        ),
        R3Button(
          'ADD OVERLAY',
          theme: widget.theme,
          compact: true,
          onPressed: _importing || _startingPlayback || _exporting
              ? null
              : () => _addVideo('V2'),
        ),
      ],
      if (edit != null) ...[
        R3Button(
          'ADD SOURCE',
          theme: widget.theme,
          compact: true,
          onPressed: _importing ||
                  _playing ||
                  _startingPlayback ||
                  _exporting ||
                  model == null
              ? null
              : () => _addStructuralSource(model, edit),
        ),
      ],
      SizedBox(width: sc(5)),
      R3MicroLabel('TRANSPORT', theme: widget.theme, accent: true),
      R3Button(
        _startingPlayback ? 'STARTING' : (_playing ? 'PAUSE' : 'PLAY'),
        theme: widget.theme,
        compact: true,
        kind: _playing ? R3ButtonKind.hot : R3ButtonKind.primary,
        onPressed: selected == null ||
                selectedEnd <= 0 ||
                _importing ||
                _startingPlayback ||
                _exporting
            ? null
            : () => unawaited(_togglePlayback(selected, selectedEnd)),
      ),
      SizedBox(width: sc(5)),
      R3MicroLabel('OUTPUT', theme: widget.theme, accent: true),
      R3Button(
        _exporting ? 'CANCEL EXPORT' : 'EXPORT',
        theme: widget.theme,
        compact: true,
        kind: _exporting ? R3ButtonKind.hot : R3ButtonKind.primary,
        onPressed: _exporting
            ? _cancelExport
            : selected == null ||
                    selectedEnd <= 0 ||
                    _importing ||
                    _startingPlayback
                ? null
                : () => _exportSelected(selected),
      ),
      if (_importing) ...[
        SizedBox(
          width: sc(13),
          height: sc(13),
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: widget.theme.accentDim,
          ),
        ),
        Text('IMPORTING', style: widget.theme.micro),
      ] else if (_startingPlayback) ...[
        SizedBox(
          width: sc(13),
          height: sc(13),
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: widget.theme.accentDim,
          ),
        ),
        Text('SYNCING AUDIO', style: widget.theme.micro),
      ] else if (_exporting) ...[
        SizedBox(
          width: sc(13),
          height: sc(13),
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: widget.theme.accentDim,
          ),
        ),
        Text(
          _exportTotal > 0
              ? '${_exportStatus ?? 'EXPORTING'}   $_exportDone / $_exportTotal'
              : (_exportStatus ?? 'EXPORTING'),
          style: widget.theme.micro,
        ),
      ] else if (_exportStatus != null)
        Text(
          _exportStatus!,
          key: const ValueKey<String>('structural-export-status'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: widget.theme.micro,
        )
      else if (selected != null)
        ValueListenableBuilder<EditPlaybackFrameState>(
          valueListenable: _playbackFrame,
          builder: (
            BuildContext context,
            EditPlaybackFrameState state,
            Widget? child,
          ) {
            final String label = edit != null
                ? 'EDIT ${edit.id}'
                : 'MOSAIC ${mosaic!.id}';
            return Text(
              '$label   F${state.frame} / $selectedEnd',
              style: widget.theme.micro,
            );
          },
        ),
    ];

    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(horizontal: sc(10), vertical: sc(7)),
      decoration: const BoxDecoration(
        color: R3Theme.panel,
        border: Border(bottom: BorderSide(color: R3Theme.hairline)),
      ),
      child: Wrap(
        spacing: sc(8),
        runSpacing: sc(6),
        crossAxisAlignment: WrapCrossAlignment.center,
        children: controls,
      ),
    );
  }

  Widget _message(String text) {
    return Container(
      color: R3Theme.bg,
      alignment: Alignment.center,
      padding: EdgeInsets.all(sc(30)),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: widget.theme.value.copyWith(color: R3Theme.textMid),
      ),
    );
  }
}

class _StructuralExportChoice {
  final String resolution;
  final int width;
  final int height;
  final VideoExportFormat format;

  const _StructuralExportChoice({
    required this.resolution,
    required this.width,
    required this.height,
    required this.format,
  });
}

class _WorkspaceAudioMix {
  final String? audioPath;
  final double audioGainDb;
  final String? musicPath;
  final double musicGainDb;
  final bool musicLoop;

  const _WorkspaceAudioMix({
    required this.audioPath,
    required this.audioGainDb,
    required this.musicPath,
    required this.musicGainDb,
    required this.musicLoop,
  });

  static _WorkspaceAudioMix load(String workspace) {
    String? audioPath;
    double audioGainDb = 0.0;
    String? musicPath;
    double musicGainDb = 0.0;
    bool musicLoop = false;

    final File config = File(
      '$workspace${Platform.pathSeparator}workspace.json',
    );
    if (!config.existsSync()) {
      return const _WorkspaceAudioMix(
        audioPath: null,
        audioGainDb: 0.0,
        musicPath: null,
        musicGainDb: 0.0,
        musicLoop: false,
      );
    }

    try {
      final dynamic decoded = jsonDecode(config.readAsStringSync());
      if (decoded is! Map) {
        throw const FormatException('workspace.json root must be an object.');
      }

      String? pathFrom(dynamic value) {
        if (value is! Map) return null;
        final String name = ((value['file'] as String?) ?? '').trim();
        if (name.isEmpty) return null;
        if (name.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(name)) {
          return name;
        }
        return '$workspace${Platform.pathSeparator}audio'
            '${Platform.pathSeparator}$name';
      }

      double gainFrom(dynamic value) {
        if (value is! Map) return 0.0;
        return ((value['gainDb'] as num?)?.toDouble() ?? 0.0)
            .clamp(-40.0, 12.0)
            .toDouble();
      }

      final dynamic bed = decoded['audioBed'];
      final dynamic music = decoded['musicBed'];
      audioPath = pathFrom(bed);
      audioGainDb = gainFrom(bed);
      musicPath = pathFrom(music);
      musicGainDb = gainFrom(music);
      if (music is Map) {
        musicLoop = (music['loop'] as bool?) ?? false;
      }
    } catch (error) {
      throw FormatException('Could not read workspace audio mix: $error');
    }

    return _WorkspaceAudioMix(
      audioPath: audioPath,
      audioGainDb: audioGainDb,
      musicPath: musicPath,
      musicGainDb: musicGainDb,
      musicLoop: musicLoop,
    );
  }
}
