// ./lib/edit_workspace.dart
//
// GUI entry point for source-backed structural video editing.
//
// EDIT and MOSAIC are both canonical frame sources. This workspace owns only
// transient selection, import, and transport state. Durable changes are always
// serialized back into the same script through EditSurfaceDocument or
// MosaicSurfaceDocument. ProjectClock remains the sole playback authority for
// whichever structural source is selected.
//
// Playback follows the same timing rule as the terminal renderer: Flutter
// vsync asks ProjectClock what project time is current. A Ticker does not
// advance time itself. Integer project frames are published only when they
// change for authored/edit semantics, while exact rational position is
// published every vsync for smooth presentation paint.

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'edit_linter.dart';
import 'edit_media_import.dart';
import 'edit_model.dart';
import 'edit_playback_clock.dart';
import 'edit_playback_frame.dart';
import 'edit_surface.dart';
import 'edit_surface_model.dart';
import 'engine.dart';
import 'mosaic_surface.dart';
import 'mosaic_surface_model.dart';
import 'native_file_dialog.dart';
import 'playback_trace.dart';
import 'project_clock.dart';
import 'ui_theme.dart';

typedef EditVideoPicker = Future<String?> Function();
typedef EditVideoImporter = ImportedEditVideo Function(String pickedPath);

class EditWorkspace extends StatefulWidget {
  final String source;
  final int currentFrame;
  final int voiceFrames;
  final int musicFrames;
  final bool musicLoops;
  final R3Theme theme;
  final ValueChanged<String> onSourceChanged;
  final ValueChanged<int> onSeek;

  /// Test seams. Production uses the GTK chooser, workspace MLT import, and
  /// the native realtime ProjectClock adapter.
  final EditVideoPicker? pickVideo;
  final EditVideoImporter? importVideo;
  final EditPlaybackClockFactory? playbackClockFactory;

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
  String? _selectedSourceRef;
  bool _importing = false;
  bool _playing = false;
  int _cachedSourceEndFrame = 0;
  int? _lastPolledPlaybackFrame;
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

    if (!_playing && widget.currentFrame != oldWidget.currentFrame) {
      _displayFrame = widget.currentFrame.clamp(0, _cachedSourceEndFrame);
      _lastPolledPlaybackFrame = _displayFrame;
      _publishPlaybackFrame(_displayFrame, playing: false);
      _publishPlaybackExactFrame(_displayFrame, playing: false);
    }
  }

  @override
  void dispose() {
    PlaybackTrace.instance.stop(reason: 'workspace_dispose');
    _playTicker.stop();
    _playTicker.dispose();
    _playbackFrame.dispose();
    _playbackExact.dispose();
    _playClock?.dispose();
    _playClock = null;
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

  void _togglePlayback(StructuralSourceRef source, int end) {
    if (_playing) {
      _pausePlayback();
      return;
    }
    if (end <= 0) return;

    int start = _displayFrame.clamp(0, end);
    if (start >= end) {
      start = 0;
      _displayFrame = 0;
      widget.onSeek(0);
    }

    try {
      final EditPlaybackClock clock = _ensurePlaybackClock();
      final ProjectTime startTime = ProjectTime(
        frame: start,
        mode: ProjectClockMode.monotonic,
      );
      clock.playFrom(startTime);

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
      _playing = true;
      _error = null;
      _publishPlaybackFrame(start, playing: true);
      _publishPlaybackExact(startTime, playing: true);
      _playTicker.start();
      setState(() {});
    } catch (error) {
      _playTicker.stop();
      PlaybackTrace.instance.stop(reason: 'play_error');
      setState(() {
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
      setState(() {
        _playing = false;
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
      } catch (_) {
        // Holding the last locally visible frame is a safe fallback.
      }
    }
    _stopPlaybackAt(frame, publish: true, traceReason: 'pause');
  }

  void _stopPlaybackAt(
    int frame, {
    required bool publish,
    String traceReason = 'stop',
  }) {
    _playTicker.stop();

    final int safeFrame = frame.clamp(0, _sourceEndFrame());
    final EditPlaybackClock? clock = _playClock;
    if (clock != null) {
      try {
        clock.holdAt(
          ProjectTime(
            frame: safeFrame,
            mode: ProjectClockMode.scrub,
          ),
        );
      } catch (_) {
        // UI state still stops even if the optional realtime clock vanished.
      }
    }

    _lastPolledPlaybackFrame = safeFrame;
    final bool changed = _playing || _displayFrame != safeFrame;
    _playing = false;
    _displayFrame = safeFrame;
    _publishPlaybackFrame(safeFrame, playing: false);
    _publishPlaybackExactFrame(safeFrame, playing: false);
    PlaybackTrace.instance.stop(reason: traceReason);

    if (publish && safeFrame != widget.currentFrame) {
      widget.onSeek(safeFrame);
    }
    if (changed && mounted) setState(() {});
  }

  void _seekFromSurface(int frame) {
    final int safeFrame = frame.clamp(0, _sourceEndFrame());
    if (_playing) {
      _stopPlaybackAt(
        safeFrame,
        publish: false,
        traceReason: 'seek_during_play',
      );
    } else {
      final EditPlaybackClock? clock = _playClock;
      if (clock != null) {
        try {
          clock.holdAt(
            ProjectTime(
              frame: safeFrame,
              mode: ProjectClockMode.scrub,
            ),
          );
        } catch (_) {
          // Seeking remains valid even if the optional realtime clock failed.
        }
      }
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
    if (ref == null || !model.containsStructuralSource(ref)) return;
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
    if (_playing) _pausePlayback();
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
    if (_importing) return;
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

  void _newMosaic(EditDocumentModel model, StructuralSourceRef selected) {
    final int duration = model.structuralSourceFrameCount(selected);
    if (duration <= 0) {
      setState(() => _error = '${selected.canonicalSource} has no authored frames.');
      return;
    }

    final Set<String> ids =
        model.mosaics.map((MosaicSequence mosaic) => mosaic.id).toSet();
    String id = 'mosaic';
    int suffix = 2;
    while (ids.contains(id)) {
      id = 'mosaic_$suffix';
      suffix++;
    }

    try {
      final String next = createMosaicWithSource(
        source: _workingSource,
        mosaicId: id,
        paneId: 'pane',
        clipId: 'source',
        structuralSource: selected.canonicalSource,
        durationFrames: duration,
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
            onChanged: _playing || model == null
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
        onPressed: model == null || _playing ? null : () => _newEdit(model),
      ),
      R3Button(
        'NEW MOSAIC',
        theme: widget.theme,
        compact: true,
        onPressed: model == null || selected == null || selectedEnd <= 0 || _playing
            ? null
            : () => _newMosaic(model, selected),
      ),
      if (mediaMode) ...[
        SizedBox(width: sc(5)),
        R3MicroLabel('MEDIA', theme: widget.theme, accent: true),
        R3Button(
          'ADD VIDEO',
          theme: widget.theme,
          compact: true,
          kind: R3ButtonKind.primary,
          onPressed: _importing ? null : () => _addVideo('V1'),
        ),
        R3Button(
          'ADD OVERLAY',
          theme: widget.theme,
          compact: true,
          onPressed: _importing ? null : () => _addVideo('V2'),
        ),
      ],
      if (edit != null) ...[
        R3Button(
          'ADD SOURCE',
          theme: widget.theme,
          compact: true,
          onPressed: _importing || _playing || model == null
              ? null
              : () => _addStructuralSource(model, edit),
        ),
      ],
      SizedBox(width: sc(5)),
      R3MicroLabel('TRANSPORT', theme: widget.theme, accent: true),
      R3Button(
        _playing ? 'PAUSE' : 'PLAY',
        theme: widget.theme,
        compact: true,
        kind: _playing ? R3ButtonKind.hot : R3ButtonKind.primary,
        onPressed: selected == null || selectedEnd <= 0 || _importing
            ? null
            : () => _togglePlayback(selected, selectedEnd),
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
      ] else if (selected != null)
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
