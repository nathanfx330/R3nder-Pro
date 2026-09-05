// ./lib/edit_surface.dart
//
// Source-backed EDIT cut/trim surface.
//
// This widget is intentionally a view over EDIT / TRACK / CLIP source. It
// keeps only transient gesture state. Every completed edit is serialized back
// through EditSurfaceDocument and returned to the caller as script text.
// During playback, the static timeline document does not rebuild every frame.
// Integer edit state stays quantized while the playhead paints directly from
// the exact rational ProjectClock position published at display cadence.
//
// Workspace voice/music beds deliberately do NOT draw here. This surface is
// where authored video cuts are trimmed before they are assigned into higher
// composition/sequencer structure. Main audio beds remain workspace playback
// and export concerns rather than pretending to be clip-local cut material.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart'
    show
        PointerCancelEvent,
        PointerDownEvent,
        PointerMoveEvent,
        PointerUpEvent,
        kSecondaryMouseButton;
import 'package:flutter/material.dart';

import 'edit_model.dart';
import 'edit_playback_frame.dart';
import 'edit_surface_model.dart';
import 'edit_video_preview.dart';
import 'media_layer.dart';
import 'ui_theme.dart';

class EditSurface extends StatefulWidget {
  final String source;
  final String editId;
  final int currentFrame;
  final bool isPlaying;

  /// Kept for source compatibility with the workspace while M16 separates
  /// cut authoring from composition audio. They are intentionally not drawn.
  final int voiceFrames;
  final int musicFrames;
  final bool musicLoops;

  final R3Theme theme;
  final ValueChanged<String> onSourceChanged;
  final ValueChanged<int> onSeek;

  /// Optional decoder seams forwarded to EditVideoPreview. Production leaves
  /// both null so the preview owns its native MLT backend and workspace source
  /// resolver. Widget tests inject them to stay entirely off native symbols.
  final MediaDecoderBackend? backend;
  final String Function(String source)? resolveSource;

  const EditSurface({
    super.key,
    required this.source,
    required this.editId,
    required this.currentFrame,
    required this.theme,
    required this.onSourceChanged,
    required this.onSeek,
    this.isPlaying = false,
    this.voiceFrames = 0,
    this.musicFrames = 0,
    this.musicLoops = false,
    this.backend,
    this.resolveSource,
  });

  @override
  State<EditSurface> createState() => _EditSurfaceState();
}

class _EditSurfaceState extends State<EditSurface> {
  static final double _kTrackHeight = sc(66);
  static final double _kRulerHeight = sc(30);
  static final double _kLabelWidth = sc(74);
  static final double _kPreviewHeight = sc(230);
  static const Duration _scrubInterval = Duration(milliseconds: 30);

  late String _workingSource;
  String? _selectedTrackId;
  String? _selectedClipId;
  String? _error;
  double _pixelsPerFrame = 2.0;
  bool _scrubbing = false;
  Timer? _scrubTimer;
  int? _pendingScrubFrame;
  int? _lastSeekSent;
  ValueListenable<EditPlaybackFrameState>? _playbackFrames;
  ValueListenable<EditPlaybackExactState>? _playbackExact;

  final ScrollController _horizontal = ScrollController();
  final ScrollController _vertical = ScrollController();

  @override
  void initState() {
    super.initState();
    _workingSource = widget.source;
    _lastSeekSent = widget.currentFrame;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final ValueListenable<EditPlaybackFrameState>? nextFrames =
        EditPlaybackFrameScope.maybeOf(context);
    if (!identical(nextFrames, _playbackFrames)) {
      _playbackFrames?.removeListener(_onPlaybackFrameChanged);
      _playbackFrames = nextFrames;
      nextFrames?.addListener(_onPlaybackFrameChanged);
    }

    final ValueListenable<EditPlaybackExactState>? nextExact =
        EditPlaybackFrameScope.maybeExactOf(context);
    if (!identical(nextExact, _playbackExact)) {
      _playbackExact?.removeListener(_onPlaybackExactChanged);
      _playbackExact = nextExact;
      nextExact?.addListener(_onPlaybackExactChanged);
    }
  }

  @override
  void didUpdateWidget(covariant EditSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.source != oldWidget.source && widget.source != _workingSource) {
      _workingSource = widget.source;
      _error = null;
    }
    if (widget.currentFrame != oldWidget.currentFrame) {
      _lastSeekSent = widget.currentFrame;
      if (!widget.isPlaying) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _followPlayheadPosition(widget.currentFrame.toDouble()),
        );
      }
    }
  }

  @override
  void dispose() {
    _playbackFrames?.removeListener(_onPlaybackFrameChanged);
    _playbackFrames = null;
    _playbackExact?.removeListener(_onPlaybackExactChanged);
    _playbackExact = null;
    _scrubTimer?.cancel();
    _horizontal.dispose();
    _vertical.dispose();
    super.dispose();
  }

  int get _effectiveFrame =>
      _playbackFrames?.value.frame ?? widget.currentFrame;

  double get _effectiveExactFrame =>
      _playbackExact?.value.exactFrame ?? _effectiveFrame.toDouble();

  void _onPlaybackFrameChanged() {
    final ValueListenable<EditPlaybackFrameState>? playback = _playbackFrames;
    if (playback == null || !mounted) return;
    _lastSeekSent = playback.value.frame;
  }

  void _onPlaybackExactChanged() {
    final ValueListenable<EditPlaybackExactState>? playback = _playbackExact;
    if (playback == null || !mounted) return;
    final EditPlaybackExactState state = playback.value;
    if (state.isPlaying) {
      _followPlayheadPosition(state.exactFrame);
    }
  }

  EditSurfaceDocument? _parse() {
    try {
      return EditSurfaceDocument.parse(_workingSource, widget.editId);
    } catch (error) {
      _error = '$error';
      return null;
    }
  }

  void _commit(String Function(EditSurfaceDocument document) operation) {
    final EditSurfaceDocument? document = _parse();
    if (document == null) {
      setState(() {});
      return;
    }

    try {
      final String next = operation(document);
      EditSurfaceDocument.parse(next, widget.editId);
      setState(() {
        _workingSource = next;
        _error = null;
      });
      widget.onSourceChanged(next);
    } catch (error) {
      setState(() => _error = '$error');
    }
  }

  EditSurfaceClip? _selected(EditSurfaceDocument document) {
    final String? trackId = _selectedTrackId;
    final String? clipId = _selectedClipId;
    if (trackId == null || clipId == null) return null;
    try {
      return document.clip(trackId, clipId);
    } catch (_) {
      return null;
    }
  }

  void _select(EditSurfaceClip clip) {
    setState(() {
      _selectedTrackId = clip.trackId;
      _selectedClipId = clip.id;
      _error = null;
    });
  }

  int _sourceOutFrame(EditSurfaceClip clip) {
    return clip.clip.sourceFrameAtProjectOffset(clip.durationFrames - 1);
  }

  void _trimInToPlayhead(EditSurfaceDocument document) {
    final EditSurfaceClip? selected = _selected(document);
    if (selected == null) return;
    final int frame = _effectiveFrame;
    if (frame <= selected.atFrame || frame >= selected.endFrameExclusive) {
      setState(() {
        _error = 'Park the playhead inside the selected CLIP to trim its IN.';
      });
      return;
    }

    _commit((EditSurfaceDocument current) {
      return current.trimStart(selected.trackId, selected.id, frame);
    });
  }

  void _trimOutToPlayhead(EditSurfaceDocument document) {
    final EditSurfaceClip? selected = _selected(document);
    if (selected == null) return;
    final int frame = _effectiveFrame;
    if (frame < selected.atFrame || frame >= selected.endFrameExclusive - 1) {
      setState(() {
        _error = 'Park the playhead before the selected CLIP end to trim its OUT.';
      });
      return;
    }

    _commit((EditSurfaceDocument current) {
      return current.trimEnd(selected.trackId, selected.id, frame + 1);
    });
  }

  void _splitSelected(EditSurfaceDocument document) {
    final EditSurfaceClip? selected = _selected(document);
    if (selected == null) return;
    final int frame = _effectiveFrame;
    if (frame <= selected.atFrame || frame >= selected.endFrameExclusive) {
      setState(() {
        _error = 'Park the playhead inside the selected CLIP before splitting.';
      });
      return;
    }

    _commit((EditSurfaceDocument current) {
      return current.splitClip(
        selected.trackId,
        selected.id,
        frame,
      );
    });
  }

  Future<void> _setLuma(EditSurfaceDocument document) async {
    final EditSurfaceClip? selected = _selected(document);
    if (selected == null) return;

    final TextEditingController sourceController = TextEditingController(
      text: selected.transition.kind == EditTransitionKind.luma
          ? selected.transition.lumaSource
          : '',
    );
    final TextEditingController framesController = TextEditingController(
      text: selected.transition.kind == EditTransitionKind.luma
          ? '${selected.transition.frames}'
          : '12',
    );

    final EditTransition? transition = await showDialog<EditTransition>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: R3Theme.panel,
          title: Text('Luma transition', style: widget.theme.value),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: sourceController,
                decoration: const InputDecoration(labelText: 'Mask source'),
                style: widget.theme.value,
              ),
              SizedBox(height: sc(10)),
              TextField(
                controller: framesController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Frames'),
                style: widget.theme.value,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(
                const EditTransition.none(),
              ),
              child: const Text('Clear'),
            ),
            TextButton(
              onPressed: () {
                final int? frames = int.tryParse(framesController.text.trim());
                if (frames == null || frames <= 0) return;
                Navigator.of(context).pop(
                  EditTransition.luma(sourceController.text.trim(), frames),
                );
              },
              child: const Text('Apply'),
            ),
          ],
        );
      },
    );

    sourceController.dispose();
    framesController.dispose();

    if (!mounted || transition == null) return;
    _commit((EditSurfaceDocument current) {
      return current.setTransition(
        selected.trackId,
        selected.id,
        transition,
      );
    });
  }

  int _frameFromDx(double dx, int frames) {
    return (dx / _pixelsPerFrame).floor().clamp(0, math.max(0, frames));
  }

  void _publishPendingScrub() {
    final int? frame = _pendingScrubFrame;
    _pendingScrubFrame = null;
    if (frame == null || frame == _lastSeekSent) return;
    _lastSeekSent = frame;
    widget.onSeek(frame);
  }

  void _scrubWindowElapsed() {
    _scrubTimer = null;
    if (_pendingScrubFrame == null) return;
    _publishPendingScrub();
    _scrubTimer = Timer(_scrubInterval, _scrubWindowElapsed);
  }

  void _queueScrub(int frame) {
    _pendingScrubFrame = frame;
    if (_scrubTimer != null) return;
    _publishPendingScrub();
    _scrubTimer = Timer(_scrubInterval, _scrubWindowElapsed);
  }

  void _startScrub(int frame) {
    if (!_scrubbing) setState(() => _scrubbing = true);
    _queueScrub(frame);
  }

  void _finishScrub(int frame) {
    _pendingScrubFrame = frame;
    _scrubTimer?.cancel();
    _scrubTimer = null;
    _publishPendingScrub();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrubbing) setState(() => _scrubbing = false);
    });
  }

  void _seekOnce(int frame) {
    _scrubTimer?.cancel();
    _scrubTimer = null;
    _pendingScrubFrame = null;
    _lastSeekSent = frame;
    widget.onSeek(frame);
  }

  void _followPlayheadPosition(double exactFrame) {
    if (!mounted || !_horizontal.hasClients) return;
    final ScrollPosition position = _horizontal.position;
    final double viewport = position.viewportDimension;
    if (viewport <= 0) return;

    final double x = exactFrame * _pixelsPerFrame;
    final double leftGuard = position.pixels + viewport * 0.12;
    final double rightGuard = position.pixels + viewport * 0.82;
    if (x >= leftGuard && x <= rightGuard) return;

    final double target =
        (x - viewport * 0.28).clamp(0.0, position.maxScrollExtent);
    if ((target - position.pixels).abs() > 1.0) {
      _horizontal.jumpTo(target);
    }
  }

  Widget _playheadWidget() {
    return Positioned.fill(
      child: RepaintBoundary(
        child: IgnorePointer(
          child: CustomPaint(
            painter: _EditPlayheadPainter(
              position: _playbackExact,
              fallbackFrame: widget.currentFrame.toDouble(),
              pixelsPerFrame: _pixelsPerFrame,
              color: widget.theme.accent,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final EditSurfaceDocument? document = _parse();
    if (document == null) return _buildErrorOnly();

    final List<EditSurfaceTrack> tracks = _visibleTracks(document);
    final EditSurfaceClip? selected = _selected(document);

    // This is a CUT surface. Composition-level audio beds intentionally do not
    // extend its ruler or create A1/A2 lanes.
    final int contentFrames = document.projectFrameCount;
    final double timelineContentHeight =
        _kRulerHeight + tracks.length * _kTrackHeight;

    return Column(
      children: [
        _buildToolbar(document, selected),
        if (_error != null)
          Container(
            width: double.infinity,
            padding: EdgeInsets.symmetric(horizontal: sc(12), vertical: sc(5)),
            color: R3Theme.danger.withValues(alpha: 0.12),
            child: Text(
              _error!,
              style: widget.theme.fine.copyWith(color: R3Theme.danger),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        Container(
          height: _kPreviewHeight,
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: R3Theme.hairline)),
          ),
          child: EditVideoPreview(
            source: _workingSource,
            editId: widget.editId,
            currentFrame: widget.currentFrame,
            isPlaying: widget.isPlaying,
            fastPreview: _scrubbing || widget.isPlaying,
            theme: widget.theme,
            backend: widget.backend,
            resolveSource: widget.resolveSource,
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double viewportTimelineWidth =
                  math.max(0.0, constraints.maxWidth - _kLabelWidth);
              final double timelineWidth = math.max(
                viewportTimelineWidth,
                math.max(1, contentFrames) * _pixelsPerFrame + sc(80),
              );

              return Scrollbar(
                controller: _vertical,
                thumbVisibility: timelineContentHeight > constraints.maxHeight,
                child: SingleChildScrollView(
                  controller: _vertical,
                  child: SizedBox(
                    width: constraints.maxWidth,
                    height: timelineContentHeight,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: _kLabelWidth,
                          child: _buildLabels(tracks),
                        ),
                        Expanded(
                          child: Scrollbar(
                            controller: _horizontal,
                            thumbVisibility: true,
                            child: SingleChildScrollView(
                              controller: _horizontal,
                              scrollDirection: Axis.horizontal,
                              child: SizedBox(
                                width: timelineWidth,
                                height: timelineContentHeight,
                                child: Stack(
                                  children: [
                                    RepaintBoundary(
                                      child: Column(
                                        children: [
                                          _buildRuler(
                                            timelineWidth,
                                            contentFrames,
                                          ),
                                          for (final EditSurfaceTrack track
                                              in tracks)
                                            _buildTrackLane(track),
                                        ],
                                      ),
                                    ),
                                    _playheadWidget(),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildErrorOnly() {
    return Container(
      color: R3Theme.bg,
      alignment: Alignment.center,
      padding: EdgeInsets.all(sc(24)),
      child: Text(
        _error ?? 'Unable to parse edit surface.',
        style: widget.theme.value.copyWith(color: R3Theme.danger),
        textAlign: TextAlign.center,
      ),
    );
  }

  List<EditSurfaceTrack> _visibleTracks(EditSurfaceDocument document) {
    final List<EditSurfaceTrack> preferred = <EditSurfaceTrack>[];
    for (final String id in const <String>['V2', 'V1']) {
      for (final EditSurfaceTrack track in document.tracks) {
        if (track.id == id) preferred.add(track);
      }
    }
    if (preferred.isNotEmpty) return preferred;
    return document.tracks.take(2).toList(growable: false);
  }

  Widget _buildToolbar(
    EditSurfaceDocument document,
    EditSurfaceClip? selected,
  ) {
    final int frame = _effectiveFrame;
    final int? sourceOut = selected == null ? null : _sourceOutFrame(selected);

    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(horizontal: sc(10), vertical: sc(7)),
      decoration: const BoxDecoration(
        color: R3Theme.panel,
        border: Border(bottom: BorderSide(color: R3Theme.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              R3MicroLabel(
                'EDIT ${widget.editId}',
                theme: widget.theme,
                accent: true,
              ),
              SizedBox(width: sc(12)),
              Expanded(
                child: Text(
                  selected == null
                      ? 'SELECT A CLIP TO TRIM'
                      : '${selected.id}   ${selected.source}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: selected == null
                      ? widget.theme.micro
                      : widget.theme.value,
                ),
              ),
              SizedBox(width: sc(10)),
              Text('${document.projectFrameCount}F', style: widget.theme.micro),
            ],
          ),
          if (selected != null) ...[
            SizedBox(height: sc(6)),
            Wrap(
              spacing: sc(10),
              runSpacing: sc(4),
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'SOURCE IN  F${selected.inFrame}',
                  key: const ValueKey<String>('edit-selected-source-in'),
                  style: widget.theme.microAccent,
                ),
                Text(
                  'SOURCE OUT  F$sourceOut',
                  key: const ValueKey<String>('edit-selected-source-out'),
                  style: widget.theme.microAccent,
                ),
                Text(
                  'CUT  ${selected.durationFrames}F',
                  key: const ValueKey<String>('edit-selected-cut-duration'),
                  style: widget.theme.micro.copyWith(color: R3Theme.textBright),
                ),
                Text(
                  'TRACK ${selected.trackId}   SPEED ${selected.speed}X',
                  style: widget.theme.micro,
                ),
              ],
            ),
          ],
          SizedBox(height: sc(6)),
          Wrap(
            spacing: sc(4),
            runSpacing: sc(4),
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (selected != null) ...[
                _toolButton(
                  'TRIM IN',
                  onPressed: frame > selected.atFrame &&
                          frame < selected.endFrameExclusive
                      ? () => _trimInToPlayhead(document)
                      : null,
                ),
                _toolButton(
                  'TRIM OUT',
                  onPressed: frame >= selected.atFrame &&
                          frame < selected.endFrameExclusive - 1
                      ? () => _trimOutToPlayhead(document)
                      : null,
                ),
                _toolButton(
                  'SPLIT',
                  onPressed: frame > selected.atFrame &&
                          frame < selected.endFrameExclusive
                      ? () => _splitSelected(document)
                      : null,
                ),
                _toolButton(
                  'SLIP -1',
                  onPressed: selected.inFrame > 0
                      ? () => _commit((EditSurfaceDocument current) {
                            return current.slipClip(
                              selected.trackId,
                              selected.id,
                              -1,
                            );
                          })
                      : null,
                ),
                _toolButton(
                  'SLIP +1',
                  onPressed: () => _commit((EditSurfaceDocument current) {
                    return current.slipClip(selected.trackId, selected.id, 1);
                  }),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Speed',
                  color: R3Theme.panelHi,
                  onSelected: (String value) {
                    _commit((EditSurfaceDocument current) {
                      return current.setSpeed(
                        selected.trackId,
                        selected.id,
                        ExactClipSpeed.parse(value),
                      );
                    });
                  },
                  itemBuilder: (_) => const <String>['1/4', '1/2', '1', '2', '4']
                      .map(
                        (String value) => PopupMenuItem<String>(
                          value: value,
                          child: Text('$value X'),
                        ),
                      )
                      .toList(),
                  child: _toolFace('SPEED'),
                ),
                _toolButton('LUMA', onPressed: () => _setLuma(document)),
              ],
              SizedBox(width: sc(6)),
              Text('ZOOM', style: widget.theme.micro),
              SizedBox(
                width: sc(120),
                child: Slider(
                  min: 0.35,
                  max: 8.0,
                  value: _pixelsPerFrame,
                  onChanged: (double value) {
                    setState(() => _pixelsPerFrame = value);
                    WidgetsBinding.instance.addPostFrameCallback(
                      (_) => _followPlayheadPosition(_effectiveExactFrame),
                    );
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _toolButton(String label, {required VoidCallback? onPressed}) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(3),
      child: Opacity(
        opacity: onPressed == null ? 0.35 : 1.0,
        child: _toolFace(label),
      ),
    );
  }

  Widget _toolFace(String label) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: sc(7), vertical: sc(4)),
      decoration: BoxDecoration(
        color: R3Theme.bg,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: R3Theme.hairline),
      ),
      child: Text(label, style: widget.theme.micro),
    );
  }

  Widget _buildLabels(List<EditSurfaceTrack> tracks) {
    return Container(
      color: R3Theme.panel,
      child: Column(
        children: [
          SizedBox(
            height: _kRulerHeight,
            child: Center(child: Text('TRACK', style: widget.theme.micro)),
          ),
          for (final EditSurfaceTrack track in tracks)
            Container(
              height: _kTrackHeight,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: R3Theme.hairline)),
              ),
              child: Text(track.id, style: widget.theme.value),
            ),
        ],
      ),
    );
  }

  Widget _buildRuler(double width, int frames) {
    return GestureDetector(
      key: const ValueKey<String>('edit-timeline-scrub'),
      behavior: HitTestBehavior.opaque,
      onTapDown: (TapDownDetails details) {
        _seekOnce(_frameFromDx(details.localPosition.dx, frames));
      },
      onHorizontalDragStart: (DragStartDetails details) {
        _startScrub(_frameFromDx(details.localPosition.dx, frames));
      },
      onHorizontalDragUpdate: (DragUpdateDetails details) {
        _queueScrub(_frameFromDx(details.localPosition.dx, frames));
      },
      onHorizontalDragEnd: (_) {
        _finishScrub(_pendingScrubFrame ?? _lastSeekSent ?? _effectiveFrame);
      },
      onHorizontalDragCancel: () {
        _finishScrub(_pendingScrubFrame ?? _lastSeekSent ?? _effectiveFrame);
      },
      child: SizedBox(
        height: _kRulerHeight,
        child: CustomPaint(
          size: Size(width, _kRulerHeight),
          painter: _EditRulerPainter(
            pixelsPerFrame: _pixelsPerFrame,
            frames: frames,
            theme: widget.theme,
          ),
        ),
      ),
    );
  }

  Widget _buildTrackLane(EditSurfaceTrack track) {
    return Container(
      height: _kTrackHeight,
      decoration: const BoxDecoration(
        color: R3Theme.bg,
        border: Border(top: BorderSide(color: R3Theme.hairline)),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final EditSurfaceClip clip in track.clips)
            Positioned(
              left: clip.atFrame * _pixelsPerFrame,
              top: sc(7),
              child: _EditableClipBlock(
                key: ValueKey(
                  '${track.id}:${clip.id}:${clip.atFrame}:'
                  '${clip.inFrame}:${clip.durationFrames}:${clip.speed}:'
                  '${clip.transition}:${clip.outgoingTransition}',
                ),
                clip: clip,
                pixelsPerFrame: _pixelsPerFrame,
                selected: _selectedTrackId == track.id &&
                    _selectedClipId == clip.id,
                theme: widget.theme,
                onSelect: () => _select(clip),
                onMove: (int atFrame) {
                  _commit((EditSurfaceDocument current) {
                    return current.moveClip(track.id, clip.id, atFrame);
                  });
                },
                onTrimStart: (int atFrame) {
                  _commit((EditSurfaceDocument current) {
                    return current.trimStart(track.id, clip.id, atFrame);
                  });
                },
                onTrimEnd: (int endFrame) {
                  _commit((EditSurfaceDocument current) {
                    return current.trimEnd(track.id, clip.id, endFrame);
                  });
                },
                onSetIncomingCrossfade: (int frames) {
                  _commit((EditSurfaceDocument current) {
                    return current.setTransition(
                      track.id,
                      clip.id,
                      frames <= 0
                          ? const EditTransition.none()
                          : EditTransition.crossfade(frames),
                    );
                  });
                },
                onSetOutgoingCrossfade: (int frames) {
                  _commit((EditSurfaceDocument current) {
                    return current.setOutgoingTransition(
                      track.id,
                      clip.id,
                      frames <= 0
                          ? const EditTransition.none()
                          : EditTransition.crossfade(frames),
                    );
                  });
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _EditableClipBlock extends StatefulWidget {
  final EditSurfaceClip clip;
  final double pixelsPerFrame;
  final bool selected;
  final R3Theme theme;
  final VoidCallback onSelect;
  final ValueChanged<int> onMove;
  final ValueChanged<int> onTrimStart;
  final ValueChanged<int> onTrimEnd;
  final ValueChanged<int> onSetIncomingCrossfade;
  final ValueChanged<int> onSetOutgoingCrossfade;

  const _EditableClipBlock({
    super.key,
    required this.clip,
    required this.pixelsPerFrame,
    required this.selected,
    required this.theme,
    required this.onSelect,
    required this.onMove,
    required this.onTrimStart,
    required this.onTrimEnd,
    required this.onSetIncomingCrossfade,
    required this.onSetOutgoingCrossfade,
  });

  @override
  State<_EditableClipBlock> createState() => _EditableClipBlockState();
}

enum _ClipDragMode { none, move, trimStart, trimEnd }

class _EditableClipBlockState extends State<_EditableClipBlock> {
  _ClipDragMode _mode = _ClipDragMode.none;
  int? _activePointer;
  double _pointerDownX = 0.0;
  double _dragPixels = 0.0;

  int get _deltaFrames => (_dragPixels / widget.pixelsPerFrame).round();

  int get _previewAt {
    switch (_mode) {
      case _ClipDragMode.move:
      case _ClipDragMode.trimStart:
        return math.max(0, widget.clip.atFrame + _deltaFrames);
      case _ClipDragMode.none:
      case _ClipDragMode.trimEnd:
        return widget.clip.atFrame;
    }
  }

  int get _previewDuration {
    switch (_mode) {
      case _ClipDragMode.trimStart:
        final int delta = _previewAt - widget.clip.atFrame;
        return math.max(1, widget.clip.durationFrames - delta);
      case _ClipDragMode.trimEnd:
        return math.max(1, widget.clip.durationFrames + _deltaFrames);
      case _ClipDragMode.none:
      case _ClipDragMode.move:
        return widget.clip.durationFrames;
    }
  }

  void _pointerDown(
    _ClipDragMode mode,
    PointerDownEvent event, {
    ValueChanged<Offset>? onSecondary,
  }) {
    if ((event.buttons & kSecondaryMouseButton) != 0) {
      widget.onSelect();
      onSecondary?.call(event.position);
      return;
    }
    if (_activePointer != null) return;
    widget.onSelect();
    setState(() {
      _mode = mode;
      _activePointer = event.pointer;
      _pointerDownX = event.position.dx;
      _dragPixels = 0.0;
    });
  }

  void _pointerMove(PointerMoveEvent event) {
    if (event.pointer != _activePointer || _mode == _ClipDragMode.none) return;
    setState(() {
      _dragPixels = event.position.dx - _pointerDownX;
    });
  }

  void _pointerUp(PointerUpEvent event) {
    if (event.pointer != _activePointer || _mode == _ClipDragMode.none) return;
    _finishPointer(commit: true);
  }

  void _pointerCancel(PointerCancelEvent event) {
    if (event.pointer != _activePointer) return;
    _finishPointer(commit: false);
  }

  void _finishPointer({required bool commit}) {
    final int delta = _deltaFrames;
    final _ClipDragMode mode = _mode;

    setState(() {
      _mode = _ClipDragMode.none;
      _activePointer = null;
      _pointerDownX = 0.0;
      _dragPixels = 0.0;
    });

    if (!commit || delta == 0) return;

    switch (mode) {
      case _ClipDragMode.move:
        widget.onMove(math.max(0, widget.clip.atFrame + delta));
        break;
      case _ClipDragMode.trimStart:
        widget.onTrimStart(math.max(0, widget.clip.atFrame + delta));
        break;
      case _ClipDragMode.trimEnd:
        widget.onTrimEnd(
          math.max(
            widget.clip.atFrame + 1,
            widget.clip.endFrameExclusive + delta,
          ),
        );
        break;
      case _ClipDragMode.none:
        break;
    }
  }

  Future<void> _showCrossfadeMenu({
    required bool incoming,
    required Offset globalPosition,
  }) async {
    final OverlayState overlayState = Overlay.of(context);
    final RenderObject? renderObject = overlayState.context.findRenderObject();
    if (renderObject is! RenderBox) return;

    final int currentFrames = incoming
        ? widget.clip.transition.kind == EditTransitionKind.crossfade
            ? widget.clip.transition.frames
            : 0
        : widget.clip.outgoingTransition.kind == EditTransitionKind.crossfade
            ? widget.clip.outgoingTransition.frames
            : 0;
    final String edge = incoming ? 'in' : 'out';
    final RelativeRect position = RelativeRect.fromRect(
      Rect.fromPoints(globalPosition, globalPosition),
      Offset.zero & renderObject.size,
    );

    final int? selected = await showMenu<int>(
      context: context,
      color: R3Theme.panelHi,
      position: position,
      items: <PopupMenuEntry<int>>[
        PopupMenuItem<int>(
          enabled: false,
          height: sc(30),
          child: Text(
            incoming ? 'XFADE IN' : 'XFADE OUT',
            style: widget.theme.microAccent,
          ),
        ),
        PopupMenuItem<int>(
          key: ValueKey<String>('edit-xfade-$edge-clear'),
          value: 0,
          child: Row(
            children: [
              SizedBox(
                width: sc(18),
                child: currentFrames == 0
                    ? const Icon(Icons.check, size: 14)
                    : null,
              ),
              const Text('CLEAR'),
            ],
          ),
        ),
        for (final int frames in const <int>[6, 12, 24])
          PopupMenuItem<int>(
            key: ValueKey<String>('edit-xfade-$edge-$frames'),
            value: frames,
            enabled: frames <= widget.clip.durationFrames,
            child: Row(
              children: [
                SizedBox(
                  width: sc(18),
                  child: currentFrames == frames
                      ? const Icon(Icons.check, size: 14)
                      : null,
                ),
                Text('$frames FRAMES'),
              ],
            ),
          ),
      ],
    );

    if (!mounted || selected == null) return;
    if (incoming) {
      widget.onSetIncomingCrossfade(selected);
    } else {
      widget.onSetOutgoingCrossfade(selected);
    }
  }

  Widget _pointerRegion({
    required _ClipDragMode mode,
    required Widget child,
    ValueChanged<Offset>? onSecondary,
  }) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (PointerDownEvent event) =>
          _pointerDown(mode, event, onSecondary: onSecondary),
      onPointerMove: _pointerMove,
      onPointerUp: _pointerUp,
      onPointerCancel: _pointerCancel,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final double width =
        math.max(sc(18), _previewDuration * widget.pixelsPerFrame);
    final double moveOffset =
        (_previewAt - widget.clip.atFrame) * widget.pixelsPerFrame;
    final Color border =
        widget.selected ? widget.theme.accent : R3Theme.ribbonMedia;
    final Color fill = widget.selected
        ? widget.theme.accentFaint
        : R3Theme.ribbonMedia.withValues(alpha: 0.22);
    final int sourceOut = widget.clip.clip.sourceFrameAtProjectOffset(
      widget.clip.durationFrames - 1,
    );
    final double transitionMaxWidth = math.max(0.0, width - sc(14));

    return Transform.translate(
      offset: Offset(moveOffset, 0),
      child: SizedBox(
        width: width,
        height: sc(52),
        child: Stack(
          children: [
            Positioned.fill(
              child: _pointerRegion(
                mode: _ClipDragMode.move,
                child: Container(
                  padding: EdgeInsets.fromLTRB(sc(9), sc(6), sc(9), sc(4)),
                  decoration: BoxDecoration(
                    color: fill,
                    border: Border.all(color: border),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        widget.clip.id,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: widget.theme.fine.copyWith(
                          color: widget.selected
                              ? widget.theme.accent
                              : R3Theme.textBright,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: sc(2)),
                      Text(
                        '${widget.clip.source}   IN ${widget.clip.inFrame}   '
                        'OUT $sourceOut   ${widget.clip.durationFrames}F',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: widget.theme.micro,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (!widget.clip.transition.isNone)
              Positioned(
                key: ValueKey<String>(
                  'edit-clip-${widget.clip.trackId}-${widget.clip.id}-in-transition',
                ),
                left: sc(7),
                top: 0,
                bottom: 0,
                width: math.min(
                  transitionMaxWidth,
                  math.max(
                    sc(4),
                    widget.clip.transition.frames * widget.pixelsPerFrame,
                  ),
                ),
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _TransitionPainter(
                      color: widget.clip.transition.kind ==
                              EditTransitionKind.crossfade
                          ? R3Theme.ribbonWindow
                          : R3Theme.warn,
                      reverse: false,
                    ),
                  ),
                ),
              ),
            if (!widget.clip.outgoingTransition.isNone)
              Positioned(
                key: ValueKey<String>(
                  'edit-clip-${widget.clip.trackId}-${widget.clip.id}-out-transition',
                ),
                right: sc(7),
                top: 0,
                bottom: 0,
                width: math.min(
                  transitionMaxWidth,
                  math.max(
                    sc(4),
                    widget.clip.outgoingTransition.frames *
                        widget.pixelsPerFrame,
                  ),
                ),
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: const _TransitionPainter(
                      color: R3Theme.ribbonWindow,
                      reverse: true,
                    ),
                  ),
                ),
              ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: sc(7),
              child: MouseRegion(
                key: ValueKey<String>(
                  'edit-clip-${widget.clip.trackId}-${widget.clip.id}-in-handle',
                ),
                cursor: SystemMouseCursors.resizeLeftRight,
                child: _pointerRegion(
                  mode: _ClipDragMode.trimStart,
                  onSecondary: (Offset position) {
                    unawaited(
                      _showCrossfadeMenu(
                        incoming: true,
                        globalPosition: position,
                      ),
                    );
                  },
                  child: Container(
                    color: border.withValues(
                      alpha: widget.selected ? 0.55 : 0.25,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: sc(7),
              child: MouseRegion(
                key: ValueKey<String>(
                  'edit-clip-${widget.clip.trackId}-${widget.clip.id}-out-handle',
                ),
                cursor: SystemMouseCursors.resizeLeftRight,
                child: _pointerRegion(
                  mode: _ClipDragMode.trimEnd,
                  onSecondary: (Offset position) {
                    unawaited(
                      _showCrossfadeMenu(
                        incoming: false,
                        globalPosition: position,
                      ),
                    );
                  },
                  child: Container(
                    color: border.withValues(
                      alpha: widget.selected ? 0.55 : 0.25,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EditPlayheadPainter extends CustomPainter {
  final ValueListenable<EditPlaybackExactState>? position;
  final double fallbackFrame;
  final double pixelsPerFrame;
  final Color color;

  _EditPlayheadPainter({
    required this.position,
    required this.fallbackFrame,
    required this.pixelsPerFrame,
    required this.color,
  }) : super(repaint: position);

  double get _exactFrame => position?.value.exactFrame ?? fallbackFrame;

  @override
  void paint(Canvas canvas, Size size) {
    final double x = _exactFrame * pixelsPerFrame;
    final Paint line = Paint()
      ..color = color
      ..strokeWidth = 2;
    canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);

    final Rect head = Rect.fromLTWH(
      x - sc(3.5),
      0,
      sc(7),
      sc(7),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(head, const Radius.circular(1)),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _EditPlayheadPainter oldDelegate) {
    return !identical(oldDelegate.position, position) ||
        oldDelegate.fallbackFrame != fallbackFrame ||
        oldDelegate.pixelsPerFrame != pixelsPerFrame ||
        oldDelegate.color != color;
  }
}

class _TransitionPainter extends CustomPainter {
  final Color color;
  final bool reverse;

  const _TransitionPainter({
    required this.color,
    this.reverse = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color.withValues(alpha: 0.8)
      ..strokeWidth = 1;
    for (double x = -size.height; x < size.width; x += sc(6)) {
      if (reverse) {
        canvas.drawLine(
          Offset(x, 0),
          Offset(x + size.height, size.height),
          paint,
        );
      } else {
        canvas.drawLine(
          Offset(x, size.height),
          Offset(x + size.height, 0),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _TransitionPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.reverse != reverse;
}

class _EditRulerPainter extends CustomPainter {
  final double pixelsPerFrame;
  final int frames;
  final R3Theme theme;

  const _EditRulerPainter({
    required this.pixelsPerFrame,
    required this.frames,
    required this.theme,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = R3Theme.panel);

    final int major = _majorStep(pixelsPerFrame);
    final int minor = math.max(1, major ~/ 5);
    final TextPainter text = TextPainter(
      textDirection: TextDirection.ltr,
      maxLines: 1,
    );

    for (int frame = 0; frame <= frames + major; frame += minor) {
      final double x = frame * pixelsPerFrame;
      if (x > size.width) break;
      final bool isMajor = frame % major == 0;
      final Paint tick = Paint()
        ..color = isMajor ? R3Theme.textDim : R3Theme.hairline
        ..strokeWidth = 1;
      canvas.drawLine(
        Offset(x, isMajor ? sc(10) : sc(18)),
        Offset(x, size.height),
        tick,
      );

      if (isMajor) {
        text.text = TextSpan(
          text: '$frame',
          style: theme.micro.copyWith(color: R3Theme.textDim),
        );
        text.layout();
        text.paint(canvas, Offset(x + sc(3), sc(2)));
      }
    }
  }

  static int _majorStep(double pixelsPerFrame) {
    if (pixelsPerFrame >= 6) return 10;
    if (pixelsPerFrame >= 2) return 30;
    if (pixelsPerFrame >= 1) return 60;
    return 150;
  }

  @override
  bool shouldRepaint(covariant _EditRulerPainter oldDelegate) =>
      oldDelegate.pixelsPerFrame != pixelsPerFrame ||
      oldDelegate.frames != frames ||
      oldDelegate.theme.accent != theme.accent;
}
