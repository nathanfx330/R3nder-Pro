// ./lib/timeline_landmark_layer.dart
//
// Shared zero-width landmark paint layer for TEXT and EDIT timelines.
//
// The coloured ribbon/clip bands describe intervals. MARK, CUE, clip IN, and
// clip OUT describe instants, so forcing them into minimum-width blocks would
// falsify the time axis. This painter is deliberately a separate pass above
// the bands.
//
// There are only two visual treatments. Authored MARK definitions are strong;
// every derived landmark shares the quieter treatment. CUE/IN/OUT remain
// semantically distinct in the model, but at ribbon density four separate
// glyph languages would be noise rather than information.

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

  const TimelineLandmarkLayer({
    super.key,
    required this.markers,
    required this.derived,
    required this.totalFrames,
    required this.theme,
    this.pixelsPerFrame,
    this.dimmed = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: kTimelineLandmarkLayerHeight,
      width: double.infinity,
      child: IgnorePointer(
        child: CustomPaint(
          painter: TimelineLandmarkPainter(
            markers: markers,
            derived: derived,
            totalFrames: totalFrames,
            pixelsPerFrame: pixelsPerFrame,
            theme: theme,
            dimmed: dimmed,
          ),
        ),
      ),
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

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0 || totalFrames < 0) return;

    final Color authoredColor = dimmed
        ? theme.accent.withValues(alpha: 0.35)
        : theme.accent;
    final Color derivedColor = dimmed
        ? R3Theme.textDim.withValues(alpha: 0.28)
        : R3Theme.textDim.withValues(alpha: 0.78);

    // Derived truth first. Authored intent is painted last so a MARK and CUE
    // on the same frame still read as an authored marker rather than one fat
    // ambiguous line.
    final Paint derivedPaint = Paint()
      ..color = derivedColor
      ..strokeWidth = sc(1);
    final double derivedTop = size.height * 0.42;
    for (final DerivedLandmark landmark in derived) {
      if (landmark.frame < 0 || landmark.frame > totalFrames) continue;
      final double x = _xForFrame(landmark.frame, size)
          .clamp(0.0, size.width - 1.0);
      canvas.drawLine(
        Offset(x, derivedTop),
        Offset(x, size.height),
        derivedPaint,
      );
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
