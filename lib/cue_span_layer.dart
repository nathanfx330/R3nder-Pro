// ./lib/cue_span_layer.dart
//
// Interactive EDIT-ruler interval layer for CUE range sliding.
//
// Occupied spans are resolved by the parent before a drag begins. The gesture
// snapshots that list and performs only pure rational/interval math while the
// pointer moves. Source mutation and fresh resolver-aware validation belong to
// the release callback.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'edit_cue.dart';
import 'edit_cue_overlap.dart';
import 'edit_cue_sliding.dart';
import 'edit_surface_model.dart';
import 'ui_theme.dart';

final double kCueSpanLayerHeight = sc(18);

typedef CueSpanCommit = bool Function(
  CueMoveBaseline baseline,
  int targetStartFrame,
);

class CueSpanLayer extends StatefulWidget {
  const CueSpanLayer({
    super.key,
    required this.document,
    required this.spans,
    required this.totalFrames,
    required this.pixelsPerFrame,
    required this.theme,
    required this.enabled,
    required this.onCommit,
    this.onInvalidRelease,
  });

  final EditSurfaceDocument document;
  final List<CueOccupiedSpan> spans;
  final int totalFrames;
  final double pixelsPerFrame;
  final R3Theme theme;
  final bool enabled;
  final CueSpanCommit onCommit;
  final ValueChanged<String>? onInvalidRelease;

  @override
  State<CueSpanLayer> createState() => _CueSpanLayerState();
}

class _CueSpanLayerState extends State<CueSpanLayer> {
  CueMoveBaseline? _baseline;
  CueMovePreview? _preview;
  List<CueOccupiedSpan>? _dragSpans;
  double _dragDx = 0;

  int? get _movingOffset => _baseline?.sourceStartOffset;

  void _start(CueOccupiedSpan span) {
    if (!widget.enabled) return;
    final EditSurfaceClip clip =
        widget.document.clip(span.trackId, span.clipId);
    final CueMoveBaseline baseline = beginCueMove(
      moving: span,
      clip: clip,
      spans: widget.spans,
    );
    setState(() {
      _baseline = baseline;
      _preview = evaluateCueMove(baseline, baseline.originalStartFrame);
      _dragSpans = List<CueOccupiedSpan>.unmodifiable(widget.spans);
      _dragDx = 0;
    });
  }

  void _update(DragUpdateDetails details) {
    final CueMoveBaseline? baseline = _baseline;
    if (baseline == null || widget.pixelsPerFrame <= 0) return;
    _dragDx += details.delta.dx;
    final int requested = baseline.originalStartFrame +
        (_dragDx / widget.pixelsPerFrame).round();
    setState(() {
      _preview = evaluateCueMove(baseline, requested);
    });
  }

  void _finish() {
    final CueMoveBaseline? baseline = _baseline;
    final CueMovePreview? preview = _preview;
    if (baseline == null || preview == null) {
      _clear();
      return;
    }

    if (!preview.canCommit) {
      widget.onInvalidRelease?.call(
        'CUE move would worsen an existing overlap. '
        'Keep dragging until the range becomes valid.',
      );
      _clear();
      return;
    }

    widget.onCommit(baseline, preview.startFrame);
    _clear();
  }

  void _clear() {
    if (!mounted) return;
    setState(() {
      _baseline = null;
      _preview = null;
      _dragSpans = null;
      _dragDx = 0;
    });
  }

  CueOccupiedRange _rangeFor(CueOccupiedSpan span) {
    if (span.sourceStartOffset == _movingOffset && _preview != null) {
      return _preview!.range;
    }
    return span.range;
  }

  Color _colorFor(CueOccupiedSpan span) {
    if (span.sourceStartOffset == _movingOffset && _preview != null) {
      switch (_preview!.state) {
        case CueMovePreviewState.valid:
          break;
        case CueMovePreviewState.invalidPassable:
          return R3Theme.danger;
        case CueMovePreviewState.blocked:
          return widget.theme.accent;
      }
    }
    return switch (span.lane) {
      CueCollisionLane.presentation => R3Theme.warn,
      CueCollisionLane.shell => R3Theme.ribbonWindow,
    };
  }

  double _rowTop(CueCollisionLane lane) => switch (lane) {
        CueCollisionLane.presentation => sc(1),
        CueCollisionLane.shell => sc(9),
      };

  @override
  Widget build(BuildContext context) {
    final double projectWidth =
        math.max(0, widget.totalFrames) * widget.pixelsPerFrame;

    return SizedBox(
      height: kCueSpanLayerHeight,
      width: double.infinity,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final CueOccupiedSpan span
              in _dragSpans ?? widget.spans)
            ..._buildSpan(span, projectWidth),
        ],
      ),
    );
  }

  List<Widget> _buildSpan(
    CueOccupiedSpan span,
    double projectWidth,
  ) {
    final CueOccupiedRange range = _rangeFor(span);
    final double rawLeft = range.startFrame * widget.pixelsPerFrame;
    final double rawRight = range.endFrameExclusive * widget.pixelsPerFrame;
    final double left = rawLeft.clamp(0.0, projectWidth);
    final double right = rawRight.clamp(0.0, projectWidth);
    final double width = math.max(sc(2), right - left);
    final double top = _rowTop(span.lane);
    final Color color = _colorFor(span);
    final bool continuesRight = rawRight > projectWidth;
    final double handleCenter = ((left + right) / 2)
        .clamp(left + sc(4), math.max(left + sc(4), right - sc(4)));
    final bool moving = span.sourceStartOffset == _movingOffset;

    return <Widget>[
      Positioned(
        key: ValueKey<String>('cue-span-${span.sourceStartOffset}'),
        left: left,
        top: top + sc(3),
        width: width,
        height: sc(3),
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(sc(1.5)),
            ),
          ),
        ),
      ),
      if (continuesRight)
        Positioned(
          left: math.max(0, projectWidth - sc(5)),
          top: top + sc(1),
          child: IgnorePointer(
            child: Icon(
              Icons.chevron_right,
              size: sc(9),
              color: color,
            ),
          ),
        ),
      Positioned(
        left: handleCenter - sc(6),
        top: top,
        width: sc(12),
        height: sc(9),
        child: MouseRegion(
          cursor: moving
              ? SystemMouseCursors.grabbing
              : widget.enabled
                  ? SystemMouseCursors.grab
                  : SystemMouseCursors.basic,
          child: GestureDetector(
            key: ValueKey<String>('cue-span-handle-${span.sourceStartOffset}'),
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart:
                widget.enabled ? (_) => _start(span) : null,
            onHorizontalDragUpdate: widget.enabled ? _update : null,
            onHorizontalDragEnd: widget.enabled ? (_) => _finish() : null,
            onHorizontalDragCancel: widget.enabled ? _clear : null,
            child: Center(
              child: Container(
                width: sc(6),
                height: sc(6),
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: R3Theme.bg,
                    width: sc(1),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ];
  }
}
