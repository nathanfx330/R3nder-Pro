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
// Playback samples ProjectClock at the project frame cadence, but those local
// playhead updates are not republished through EditorScreen. The video preview
// receives the exact current project frame and uses native nonblocking decoder
// workers, while the parent receives only the parked frame on pause, end, or an
// explicit seek.

import 'dart:async';

import 'package:flutter/material.dart';

import 'edit_media_import.dart';
import 'edit_model.dart';
import 'edit_playback_clock.dart';
import 'edit_surface.dart';
import 'edit_surface_model.dart';
import 'engine.dart';
import 'native_file_dialog.dart';
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

class _EditWorkspaceState extends State<EditWorkspace> {
  static const Duration _playbackPollInterval = Duration(
    microseconds: 1000000 ~/ engineFps,
  );

  late String _workingSource;
  late int _displayFrame;
  Timer? _playPoll;
  EditPlaybackClock? _playClock;
  bool _importing = false;
  bool _playing = false;
  int _cachedEditEndFrame = 0;
  int? _lastPolledPlaybackFrame;
  String? _error;

  @override
  void initState() {
    super.initState();
    _workingSource = widget.source;
    _displayFrame = widget.currentFrame;
    _refreshEditEndCache();
    _displayFrame = _displayFrame.clamp(0, _cachedEditEndFrame);
  }

  @override
  void didUpdateWidget(covariant EditWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.source != oldWidget.source && widget.source != _workingSource) {
      _workingSource = widget.source;
      _error = null;
      _refreshEditEndCache();
      _stopPlaybackAt(widget.currentFrame, publish: false);
      return;
    }

    if (!_playing && widget.currentFrame != oldWidget.currentFrame) {
      _displayFrame = widget.currentFrame.clamp(0, _cachedEditEndFrame);
      _lastPolledPlaybackFrame = _displayFrame;
    }
  }

  @override
  void dispose() {
    _playPoll?.cancel();
    _playPoll = null;
    _playClock?.dispose();
    _playClock = null;
    super.dispose();
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
      clock.playFrom(
        ProjectTime(
          frame: start,
          mode: ProjectClockMode.monotonic,
        ),
      );

      _playPoll?.cancel();
      _playPoll = Timer.periodic(_playbackPollInterval, _onPlaybackPoll);
      _lastPolledPlaybackFrame = start;

      setState(() {
        _displayFrame = start;
        _playing = true;
        _error = null;
      });
    } catch (error) {
      _playPoll?.cancel();
      _playPoll = null;
      setState(() {
        _playing = false;
        _error = 'EDIT PLAYBACK UNAVAILABLE\n$error';
      });
    }
  }

  void _onPlaybackPoll(Timer _) {
    if (!_playing || !mounted) return;

    final int end = _editEndFrame();
    if (end <= 0) {
      _stopPlaybackAt(0, publish: true);
      return;
    }

    final EditPlaybackClock? clock = _playClock;
    if (clock == null) return;

    final ProjectTime sampled;
    try {
      sampled = clock.sample();
    } catch (error) {
      _playPoll?.cancel();
      _playPoll = null;
      setState(() {
        _playing = false;
        _error = 'EDIT PLAYBACK CLOCK FAILED\n$error';
      });
      return;
    }

    final int frame = sampled.frame.clamp(0, end);
    if (frame >= end) {
      _stopPlaybackAt(end, publish: true);
      return;
    }

    if (frame == _lastPolledPlaybackFrame) return;
    _lastPolledPlaybackFrame = frame;

    // Local only. EditorScreen is not told about every advancing frame, so the
    // parent editor tree remains outside the playback hot path. EditSurface and
    // its monitor still receive project frames at the real project cadence.
    setState(() => _displayFrame = frame);
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
    _stopPlaybackAt(frame, publish: true);
  }

  void _stopPlaybackAt(int frame, {required bool publish}) {
    _playPoll?.cancel();
    _playPoll = null;

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

    if (publish && safeFrame != widget.currentFrame) {
      widget.onSeek(safeFrame);
    }
    if (changed && mounted) setState(() {});
  }

  void _seekFromEdit(int frame) {
    final int safeFrame = frame.clamp(0, _editEndFrame());
    if (_playing) {
      _stopPlaybackAt(safeFrame, publish: false);
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
      if (_displayFrame != safeFrame && mounted) {
        setState(() => _displayFrame = safeFrame);
      } else {
        _displayFrame = safeFrame;
      }
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
                    : EditSurface(
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
                          });
                          widget.onSourceChanged(next);
                        },
                        onSeek: _seekFromEdit,
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
        Text(
          'EDIT ${edit.id}   F$_displayFrame / ${edit.projectFrameCount}',
          style: widget.theme.micro,
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
