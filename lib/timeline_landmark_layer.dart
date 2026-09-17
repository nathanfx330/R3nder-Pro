// ./lib/timeline_landmark_layer.dart
//
// Shared zero-width landmark paint layer for TEXT and EDIT timelines.
//
// The coloured ribbon/clip bands describe intervals. MARK, CUE, clip IN, and
// clip OUT describe instants, so forcing them into minimum-width blocks would
// falsify the time axis. This painter is deliberately a separate pass above
// the bands.
//
// Authored MARK definitions keep the strongest treatment. Derived landmarks
// retain their own timing semantics visually: CUE is amber, clip IN is green,
// and clip OUT is red. IN and OUT also receive opposite sub-pixel offsets so
// an outgoing clip boundary and the next clip's incoming boundary can both be
// seen when they occupy the same exact frame.

import 'package:flutter/material.dart';

import 'timeline_markers.dart';
import 'ui_theme.dart';

final double kTimelineLandmarkLayerHeight = sc(8);

class TimelineLandmarkLayer extends StatelessWidget {
  final List<MarkerInstance> markers;
  final List<DerivedLandmark> derived;

  /// Shared timeline length. Used when [pixelsPerFrame] is null.
  final int totalFrames;

  /// Absolute EDIT timeline scale. Null means proportional fit-to-width TEXT
  /// ribbon geometry.
  final double? pixelsPerFrame;

  final R3Theme theme;
  final bool dimmed;

  /// Optional direct seek owner. TEXT uses this because the landmark strip is
  /// physically above ScriptRibbon's own GestureDetector. EDIT leaves it null
  /// because the strip sits inside the ruler's existing seek detector.
  final ValueChanged<int>? onSeek;

  const TimelineLandmarkLayer({
    super.key,
    required this.markers,
    required this.derived,
    required this.totalFrames,
    required this.theme,
    this.pixelsPerFrame,
    this.dimmed = false,
    this.onSeek,
  });

  int _frameAt(double dx, double width) {
    if (totalFrames <= 0 || width <= 0) return 0;
    final double? absolute = pixelsPerFrame;
    final int frame = absolute != null && absolute > 0
        ? (dx / absolute).round()
        : ((dx / width).clamp(0.0, 1.0) * totalFrames).round();
    return frame.clamp(0, totalFrames);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        final Widget paint = CustomPaint(
          painter: TimelineLandmarkPainter(
            markers: markers,
            derived: derived,
            totalFrames: totalFrames,
            pixelsPerFrame: pixelsPerFrame,
            theme: theme,
            dimmed: dimmed,
          ),
        );

        return SizedBox(
          height: kTimelineLandmarkLayerHeight,
          width: double.infinity,
          child: onSeek == null
              ? IgnorePointer(child: paint)
              : GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (TapDownDetails details) =>
                      onSeek!(_frameAt(details.localPosition.dx, width)),
                  onHorizontalDragUpdate: (DragUpdateDetails details) =>
                      onSeek!(_frameAt(details.localPosition.dx, width)),
                  child: paint,
                ),
        );
      },
    );
  }
}

class TimelineLandmarkPainter extends CustomPainter {
  final List<MarkerInstance> markers;
  final List<DerivedLandmark> derived;
  final int totalFrames;
  final double? pixelsPerFrame;
  final R3Theme theme;
  final bool dimmed;

  const TimelineLandmarkPainter({
    required this.markers,
    required this.derived,
    required this.totalFrames,
    required this.theme,
    this.pixelsPerFrame,
    this.dimmed = false,
  });

  double _xForFrame(int frame, Size size) {
    final double? absolute = pixelsPerFrame;
    if (absolute != null) return frame * absolute;
    if (totalFrames <= 0 || size.width <= 0) return 0;
    return frame * (size.width / totalFrames);
  }

  Color _derivedColor(DerivedLandmarkKind kind) {
    final Color base;
    switch (kind) {
      case DerivedLandmarkKind.cue:
        base = R3Theme.warn;
        break;
      case DerivedLandmarkKind.clipIn:
        base = R3Theme.okGreen;
        break;
      case DerivedLandmarkKind.clipOut:
        base = R3Theme.danger;
        break;
    }
    return dimmed ? base.withValues(alpha: 0.30) : base.withValues(alpha: 0.82);
  }

  double _derivedOffset(DerivedLandmarkKind kind) {
    switch (kind) {
      case DerivedLandmarkKind.cue:
        return 0.0;
      case DerivedLandmarkKind.clipIn:
        return sc(0.8);
      case DerivedLandmarkKind.clipOut:
        return -sc(0.8);
    }
  }

  double _derivedTop(DerivedLandmarkKind kind, double height) {
    switch (kind) {
      case DerivedLandmarkKind.cue:
        return height * 0.18;
      case DerivedLandmarkKind.clipIn:
      case DerivedLandmarkKind.clipOut:
        return height * 0.42;
    }
  }

  void _paintDerived(Canvas canvas, Size size, DerivedLandmark landmark) {
    if (landmark.frame < 0 || landmark.frame > totalFrames) return;

    final double rawX =
        _xForFrame(landmark.frame, size) + _derivedOffset(landmark.kind);
    final double x = rawX.clamp(0.0, size.width - 1.0);
    final Color color = _derivedColor(landmark.kind);
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = landmark.kind == DerivedLandmarkKind.cue ? sc(1.4) : sc(1);

    canvas.drawLine(
      Offset(x, _derivedTop(landmark.kind, size.height)),
      Offset(x, size.height),
      paint,
    );

    // The tiny boundary cap makes adjacent OUT/IN points readable even when
    // their lines are only a couple of physical pixels apart.
    if (landmark.kind == DerivedLandmarkKind.clipIn) {
      canvas.drawLine(
        Offset(x, size.height * 0.42),
        Offset((x + sc(2.2)).clamp(0.0, size.width - 1.0), size.height * 0.42),
        paint,
      );
    } else if (landmark.kind == DerivedLandmarkKind.clipOut) {
      canvas.drawLine(
        Offset(x, size.height * 0.42),
        Offset((x - sc(2.2)).clamp(0.0, size.width - 1.0), size.height * 0.42),
        paint,
      );
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0 || totalFrames < 0) return;

    final Color authoredColor = dimmed
        ? theme.accent.withValues(alpha: 0.35)
        : theme.accent;

    // Derived truth first. Authored intent is painted last so a MARK and CUE
    // on the same frame still read as an authored marker rather than one fat
    // ambiguous line.
    for (final DerivedLandmark landmark in derived) {
      _paintDerived(canvas, size, landmark);
    }

    final Paint authoredPaint = Paint()
      ..color = authoredColor
      ..strokeWidth = sc(1.5);
    final Paint authoredCap = Paint()..color = authoredColor;
    final double cap = sc(2.5);
    for (final MarkerInstance marker in markers) {
      if (marker.frame < 0 || marker.frame > totalFrames) continue;
      final double x = _xForFrame(marker.frame, size)
          .clamp(0.0, size.width - 1.0);
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        authoredPaint,
      );
      canvas.drawPath(
        Path()
          ..moveTo(x - cap, 0)
          ..lineTo(x + cap, 0)
          ..lineTo(x, cap)
          ..close(),
        authoredCap,
      );
    }
  }

  @override
  bool shouldRepaint(covariant TimelineLandmarkPainter oldDelegate) =>
      oldDelegate.totalFrames != totalFrames ||
      oldDelegate.pixelsPerFrame != pixelsPerFrame ||
      oldDelegate.theme.accent != theme.accent ||
      oldDelegate.dimmed != dimmed ||
      !identical(oldDelegate.markers, markers) ||
      !identical(oldDelegate.derived, derived);
}
