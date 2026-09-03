// ./lib/edit_surface.dart
//
// M10 source-backed edit surface.
//
// This widget is intentionally a view over EDIT / TRACK / CLIP source. It
// keeps only transient gesture state. Every completed edit is serialized back
// through EditSurfaceDocument and returned to the caller as script text.

import 'dart:math' as math;

import 'package:flutter/gestures.dart'
    show PointerCancelEvent, PointerDownEvent, PointerMoveEvent, PointerUpEvent;
import 'package:flutter/material.dart';

import 'edit_model.dart';
import 'edit_surface_model.dart';
import 'edit_video_preview.dart';
import 'ui_theme.dart';

class EditSurface extends StatefulWidget {
  final String source;
  final String editId;
  final int currentFrame;
  final int voiceFrames;
  final int musicFrames;
  final bool musicLoops;
  final R3Theme theme;
  final ValueChanged<String> onSourceChanged;
  final ValueChanged<int> onSeek;

  const EditSurface({
    super.key,
    required this.source,
    required this.editId,
    required this.currentFrame,
    required this.theme,
    required this.onSourceChanged,
    required this.onSeek,
    this.voiceFrames = 0,
    this.musicFrames = 0,
    this.musicLoops = false,
  });

  @override
  State<EditSurface> createState() => _EditSurfaceState();
}

class _EditSurfaceState extends State<EditSurface> {
  static final double _kTrackHeight = sc(66);
  static final double _kAudioHeight = sc(24);
  static final double _kRulerHeight = sc(30);
  static final double _kLabelWidth = sc(74);
  static final double _kPreviewHeight = sc(230);

  late String _workingSource;
  String? _selectedTrackId;
  String? _selectedClipId;
  String? _error;
  double _pixelsPerFrame = 2.0;

  final ScrollController _horizontal = ScrollController();
  final ScrollController _vertical = ScrollController();

  @override
  void initState() {
    super.initState();
    _workingSource = widget.source;
  }

  @override
  void didUpdateWidget(covariant EditSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.source != oldWidget.source && widget.source != _workingSource) {
      _workingSource = widget.source;
      _error = null;
    }
  }

  @override
  void dispose() {
    _horizontal.dispose();
    _vertical.dispose();
    super.dispose();
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

  void _splitSelected(EditSurfaceDocument document) {
    final EditSurfaceClip? selected = _selected(document);
    if (selected == null) return;
    if (widget.currentFrame <= selected.atFrame ||
        widget.currentFrame >= selected.endFrameExclusive) {
      setState(() {
        _error = 'Park the playhead inside the selected CLIP before splitting.';
      });
      return;
    }

    _commit((EditSurfaceDocument current) {
      return current.splitClip(
        selected.trackId,
        selected.id,
        widget.currentFrame,
      );
    });
  }

  void _setCrossfade(EditSurfaceDocument document, int frames) {
    final EditSurfaceClip? selected = _selected(document);
    if (selected == null) return;
    _commit((EditSurfaceDocument current) {
      return current.setTransition(
        selected.trackId,
        selected.id,
        frames <= 0
            ? const EditTransition.none()
            : EditTransition.crossfade(frames),
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

  @override
  Widget build(BuildContext context) {
    final EditSurfaceDocument? document = _parse();
    if (document == null) return _buildErrorOnly();

    final List<EditSurfaceTrack> tracks = _visibleTracks(document);
    final EditSurfaceClip? selected = _selected(document);
    final int contentFrames = math.max(
      document.projectFrameCount,
      math.max(widget.voiceFrames, widget.musicFrames),
    );
    final double timelineContentHeight = _kRulerHeight +
        tracks.length * _kTrackHeight +
        (widget.voiceFrames > 0 ? _kAudioHeight : 0) +
        (widget.musicFrames > 0 ? _kAudioHeight : 0);

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
            theme: widget.theme,
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
                              child: GestureDetector(
                                behavior: HitTestBehavior.translucent,
                                onTapDown: (TapDownDetails details) {
                                  final int frame =
                                      (details.localPosition.dx /
                                              _pixelsPerFrame)
                                          .floor()
                                          .clamp(
                                            0,
                                            math.max(0, contentFrames),
                                          );
                                  widget.onSeek(frame);
                                },
                                child: SizedBox(
                                  width: timelineWidth,
                                  height: timelineContentHeight,
                                  child: Stack(
                                    children: [
                                      Column(
                                        children: [
                                          _buildRuler(
                                            timelineWidth,
                                            contentFrames,
                                          ),
                                          for (final EditSurfaceTrack track
                                              in tracks)
                                            _buildTrackLane(track),
                                          if (widget.voiceFrames > 0)
                                            _buildAudioLane(
                                              widget.voiceFrames,
                                              'VOICE',
                                              R3Theme.ribbonWindow,
                                            ),
                                          if (widget.musicFrames > 0)
                                            _buildAudioLane(
                                              math.min(
                                                widget.musicFrames,
                                                document.projectFrameCount,
                                              ),
                                              widget.musicLoops
                                                  ? 'MUSIC LOOP'
                                                  : 'MUSIC',
                                              R3Theme.ribbonMedia,
                                            ),
                                        ],
                                      ),
                                      Positioned(
                                        left: widget.currentFrame *
                                            _pixelsPerFrame,
                                        top: 0,
                                        bottom: 0,
                                        child: IgnorePointer(
                                          child: Container(
                                            width: 1,
                                            color: widget.theme.accent,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
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
                      ? 'SELECT A CLIP'
                      : '${selected.trackId}  ${selected.id}    '
                          'AT ${selected.atFrame}   IN ${selected.inFrame}   '
                          'DUR ${selected.durationFrames}   ${selected.speed}X',
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
          SizedBox(height: sc(6)),
          Wrap(
            spacing: sc(4),
            runSpacing: sc(4),
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (selected != null) ...[
                _toolButton(
                  'SPLIT',
                  onPressed: widget.currentFrame > selected.atFrame &&
                          widget.currentFrame < selected.endFrameExclusive
                      ? () => _splitSelected(document)
                      : null,
                ),
                _toolButton(
                  'SLIP 1',
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
                PopupMenuButton<int>(
                  tooltip: 'Crossfade',
                  color: R3Theme.panelHi,
                  onSelected: (int frames) => _setCrossfade(document, frames),
                  itemBuilder: (_) => const <int>[0, 6, 12, 24]
                      .map(
                        (int frames) => PopupMenuItem<int>(
                          value: frames,
                          child: Text(
                            frames == 0 ? 'No crossfade' : '$frames frames',
                          ),
                        ),
                      )
                      .toList(),
                  child: _toolFace('XFADE'),
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
          if (widget.voiceFrames > 0) _audioLabel('A1'),
          if (widget.musicFrames > 0) _audioLabel('A2'),
        ],
      ),
    );
  }

  Widget _audioLabel(String text) {
    return Container(
      height: _kAudioHeight,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: R3Theme.hairline)),
      ),
      child: Text(text, style: widget.theme.micro),
    );
  }

  Widget _buildRuler(double width, int frames) {
    return SizedBox(
      height: _kRulerHeight,
      child: CustomPaint(
        size: Size(width, _kRulerHeight),
        painter: _EditRulerPainter(
          pixelsPerFrame: _pixelsPerFrame,
          frames: frames,
          theme: widget.theme,
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
                  '${clip.inFrame}:${clip.durationFrames}:${clip.speed}',
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
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAudioLane(int frames, String label, Color color) {
    return Container(
      height: _kAudioHeight,
      decoration: const BoxDecoration(
        color: R3Theme.bg,
        border: Border(top: BorderSide(color: R3Theme.hairline)),
      ),
      alignment: Alignment.centerLeft,
      child: Container(
        width: math.max(sc(2), frames * _pixelsPerFrame),
        height: sc(12),
        padding: EdgeInsets.symmetric(horizontal: sc(6)),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.45),
          border: Border.all(color: color.withValues(alpha: 0.8)),
          borderRadius: BorderRadius.circular(2),
        ),
        child: Text(
          label,
          style: widget.theme.micro.copyWith(color: R3Theme.textBright),
        ),
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

  void _pointerDown(_ClipDragMode mode, PointerDownEvent event) {
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

  Widget _pointerRegion({
    required _ClipDragMode mode,
    required Widget child,
  }) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (PointerDownEvent event) => _pointerDown(mode, event),
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
                        '${widget.clip.speed}X',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: widget.theme.micro,
                      ),
                    ],
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
                cursor: SystemMouseCursors.resizeLeftRight,
                child: _pointerRegion(
                  mode: _ClipDragMode.trimStart,
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
                cursor: SystemMouseCursors.resizeLeftRight,
                child: _pointerRegion(
                  mode: _ClipDragMode.trimEnd,
                  child: Container(
                    color: border.withValues(
                      alpha: widget.selected ? 0.55 : 0.25,
                    ),
                  ),
                ),
              ),
            ),
            if (!widget.clip.transition.isNone)
              Positioned(
                left: sc(7),
                top: 0,
                bottom: 0,
                width: math.min(
                  width - sc(14),
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

class _TransitionPainter extends CustomPainter {
  final Color color;

  const _TransitionPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color.withValues(alpha: 0.8)
      ..strokeWidth = 1;
    for (double x = -size.height; x < size.width; x += sc(6)) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TransitionPainter oldDelegate) =>
      oldDelegate.color != color;
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
