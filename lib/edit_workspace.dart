// ./lib/edit_workspace.dart
//
// GUI entry point for source-backed video editing.
//
// EditSurface edits clips that already exist. This wrapper owns the missing
// authoring and transport paths: choose a video, import it into the active
// workspace, serialize a real V1 or V2 CLIP into the same script document,
// and drive EDIT playback from ProjectClock. There is no timeline database
// here. Durable state remains authored source; playback state is transient.
//
// Playback follows the same timing rule as the terminal renderer: Flutter
// vsync asks ProjectClock what project time is current. A Ticker does not
// advance time itself. Integer project frames are published only when they
// change for authored/edit semantics, while exact rational position is
// published every vsync for smooth presentation paint.

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'edit_media_import.dart';
import 'edit_model.dart';
import 'edit_playback_clock.dart';
import 'edit_playback_frame.dart';
import 'edit_surface.dart';
import 'edit_surface_model.dart';
import 'engine.dart';
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
  bool _importing = false;
  bool _playing = false;
  int _cachedEditEndFrame = 0;
  int? _lastPolledPlaybackFrame;
  String? _error;

  bool get _traceProductionPlayback => widget.playbackClockFactory == null;

  @override
  void initState() {
    super.initState();
    _workingSource = widget.source;
    _displayFrame = widget.currentFrame;
    _refreshEditEndCache();
    _displayFrame = _displayFrame.clamp(0, _cachedEditEndFrame);
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
      _refreshEditEndCache();
      _stopPlaybackAt(
        widget.currentFrame,
        publish: false,
        traceReason: 'source_change',
      );
      return;
    }

    if (!_playing && widget.currentFrame != oldWidget.currentFrame) {
      _displayFrame = widget.currentFrame.clamp(0, _cachedEditEndFrame);
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

  void _refreshEditEndCache() {
    try {
      final EditDocumentModel model = EditDocumentModel.parse(_workingSource);
      _cachedEditEndFrame =
          model.edits.isEmpty ? 0 : model.edits.first.projectFrameCount;
    } catch (_) {
      _cachedEditEndFrame = 0;
    }
  }

  int _editEndFrame() => _cachedEditEndFrame;

  void _togglePlayback(EditSequence edit) {
    if (_playing) {
      _pausePlayback();
      return;
    }

    final int end = edit.projectFrameCount;
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
          editId: edit.id,
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

      // PLAY/PAUSE controls and EditSurface's static editing affordances change
      // once when transport starts. Subsequent playback frames do not rebuild
      // this workspace.
      setState(() {});
    } catch (error) {
      _playTicker.stop();
      PlaybackTrace.instance.stop(reason: 'play_error');
      setState(() {
        _playing = false;
        _publishPlaybackFrame(_displayFrame, playing: false);
        _publishPlaybackExactFrame(_displayFrame, playing: false);
        _error = 'EDIT PLAYBACK UNAVAILABLE\n$error';
      });
    }
  }

  void _onPlaybackTick(Duration elapsed) {
    if (!_playing || !mounted) return;

    final int end = _editEndFrame();
    if (end <= 0) {
      _stopPlaybackAt(0, publish: true, traceReason: 'empty_edit');
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
        _error = 'EDIT PLAYBACK CLOCK FAILED\n$error';
      });
      return;
    }

    final int frame = sampled.frame.clamp(0, end);
    if (frame >= end) {
      _stopPlaybackAt(end, publish: true, traceReason: 'end');
      return;
    }

    // Exact presentation position is published every vsync, even while the
    // integer project frame is unchanged. This is the continuous clock signal
    // used by paint-only consumers such as the timeline playhead.
    if (sampled.frame < 0) {
      _publishPlaybackExactFrame(0, playing: true);
    } else {
      _publishPlaybackExact(sampled, playing: true);
    }

    if (frame == _lastPolledPlaybackFrame) return;
    _lastPolledPlaybackFrame = frame;
    _displayFrame = frame;

    // Integer frame state remains quantized deliberately. Authored edit
    // operations, readouts, and the current video selection path continue to
    // receive only real project-frame changes during this diagnostic step.
    _publishPlaybackFrame(frame, playing: true);
  }

  void _pausePlayback() {
    final EditPlaybackClock? clock = _playClock;
    int frame = _displayFrame.clamp(0, _editEndFrame());
    if (clock != null) {
      try {
        frame = clock.sample().frame.clamp(0, _editEndFrame());
      } catch (_) {
        // Holding the last locally visible frame is a safe fallback if
        // sampling fails.
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

    final int safeFrame = frame.clamp(0, _editEndFrame());
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
        // UI state still stops even if the native clock vanished mid-session.
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

  void _seekFromEdit(int frame) {
    final int safeFrame = frame.clamp(0, _editEndFrame());
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
        targetEditId = model.edits.first.id;
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
      setState(() {
        _workingSource = next;
        _error = null;
        _refreshEditEndCache();
        _displayFrame = _displayFrame.clamp(0, _cachedEditEndFrame);
        _publishPlaybackFrame(_displayFrame, playing: false);
        _publishPlaybackExactFrame(_displayFrame, playing: false);
      });
      widget.onSourceChanged(next);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) {
        setState(() => _importing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final EditDocumentModel? model = _parseModel();
    final EditSequence? edit =
        model == null || model.edits.isEmpty ? null : model.edits.first;

    // EditWorkspace is intentionally safe to mount as a complete workspace,
    // not only underneath EditorScreen. R3Button and EditSurface use InkWell
    // and Slider, both of which require a Material sheet. MaterialApp provides
    // theme/navigation but does not itself promise a Material ancestor around
    // arbitrary home content, so the workspace supplies its own transparent
    // sheet here.
    return Material(
      type: MaterialType.transparency,
      child: Column(
        children: [
          _buildImportBar(edit),
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
                ? _message('EDIT LANGUAGE ERROR')
                : edit == null
                    ? _message(
                        'NO VIDEO EDIT YET\n\nADD VIDEO creates the first V1 clip.',
                      )
                    : EditPlaybackFrameScope(
                        listenable: _playbackFrame,
                        exactListenable: _playbackExact,
                        child: EditSurface(
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
                          onSourceChanged: (String next) {
                            if (_workingSource == next) return;
                            if (_playing) _pausePlayback();
                            setState(() {
                              _workingSource = next;
                              _refreshEditEndCache();
                              _displayFrame =
                                  _displayFrame.clamp(0, _cachedEditEndFrame);
                              _publishPlaybackFrame(
                                _displayFrame,
                                playing: false,
                              );
                              _publishPlaybackExactFrame(
                                _displayFrame,
                                playing: false,
                              );
                            });
                            widget.onSourceChanged(next);
                          },
                          onSeek: _seekFromEdit,
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
      _cachedEditEndFrame =
          model.edits.isEmpty ? 0 : model.edits.first.projectFrameCount;
      return model;
    } catch (error) {
      _error ??= '$error';
      return null;
    }
  }

  Widget _buildImportBar(EditSequence? edit) {
    final List<Widget> controls = <Widget>[
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
      Text(
        'VIDEO = V1   OVERLAY = V2',
        style: widget.theme.micro,
      ),
      SizedBox(width: sc(6)),
      R3MicroLabel('TRANSPORT', theme: widget.theme, accent: true),
      R3Button(
        _playing ? 'PAUSE' : 'PLAY',
        theme: widget.theme,
        compact: true,
        kind: _playing ? R3ButtonKind.hot : R3ButtonKind.primary,
        onPressed: edit == null || _importing
            ? null
            : () => _togglePlayback(edit),
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
      ] else if (edit != null)
        ValueListenableBuilder<EditPlaybackFrameState>(
          valueListenable: _playbackFrame,
          builder: (
            BuildContext context,
            EditPlaybackFrameState state,
            Widget? child,
          ) {
            return Text(
              'EDIT ${edit.id}   F${state.frame} / ${edit.projectFrameCount}',
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
