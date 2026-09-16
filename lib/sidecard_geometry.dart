// ./lib/sidecard_geometry.dart
//
// Pure SIDECARD shell geometry.
//
// This file owns the seated desktop layout, the shared motion curve, and the
// interpolation from the pre-cue structural window into the SIDECARD layout.
// Preview, BAKE, and standalone EDIT presentation all call this same authority
// so a motion change cannot drift between paths.

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/animation.dart';

/// One evaluated SIDECARD shell frame.
///
/// The card painter remains separate. This describes only the outer structural
/// shell state owned by the desktop while a SIDECARD presentation is active.
class SideCardShellFrame {
  const SideCardShellFrame({
    required this.videoWindowRect,
    required this.motionProgress,
    required this.desktopOpacity,
    required this.terminalOpacity,
  });

  final Rect videoWindowRect;
  final double motionProgress;
  final double desktopOpacity;
  final double terminalOpacity;
}

/// Shared SIDECARD movement curve.
///
/// [slide] is the explicit-time CARD-family slide value. CARD timing owns its
/// lifetime; SIDECARD geometry only maps that value onto desktop motion.
double sideCardMotionProgress(double slide) {
  final double raw = slide.clamp(0.0, 1.0).toDouble();
  return Curves.easeOutCubic.transform(raw);
}

/// Final seated video-window geometry for SIDECARD inside [size].
///
/// The rectangle includes title-bar chrome. Its client remains the exact,
/// continuously advancing structural image.
Rect sideCardSeatedVideoWindowRect(Size size) {
  if (size.width <= 0.0 || size.height <= 0.0) return Rect.zero;
  final double s = math.min(size.width / 1920.0, size.height / 1080.0);
  final double margin = size.width * 0.035;
  final double gap = size.width * 0.024;
  final double cardW = size.width * 0.30;
  final double windowW = math.max(
    1.0,
    size.width - margin * 2.0 - gap - cardW,
  );
  final double titleH = 38.0 * s;
  final double desiredClientH = windowW * 9.0 / 16.0;
  final double maxWindowH = size.height * 0.76;
  final double windowH = math.min(maxWindowH, desiredClientH + titleH);
  return Rect.fromLTWH(
    margin,
    (size.height - windowH) / 2.0,
    windowW,
    windowH,
  );
}

/// Final seated card geometry for SIDECARD inside [size].
Rect sideCardSeatedPanelRect(Size size) {
  if (size.width <= 0.0 || size.height <= 0.0) return Rect.zero;
  final Rect video = sideCardSeatedVideoWindowRect(size);
  final double gap = size.width * 0.024;
  final double cardW = size.width * 0.30;
  return Rect.fromLTWH(
    video.right + gap,
    video.top,
    cardW,
    video.height,
  );
}

/// Evaluates the moving outer video window for one explicit SIDECARD frame.
///
/// [preCueRect] must be expressed in the same coordinate system as [origin].
/// Preview uses widget pixels plus the fitted render-frame origin. BAKE uses
/// output pixels with the default zero origin. The same curve and lerp therefore
/// serve both paths without either caller duplicating motion policy.
Rect sideCardVideoWindowRectAt({
  required Size size,
  required Rect preCueRect,
  required double slide,
  Offset origin = Offset.zero,
}) {
  if (size.width <= 0.0 || size.height <= 0.0) return preCueRect;
  final Rect seated = sideCardSeatedVideoWindowRect(size).shift(origin);
  return Rect.lerp(
    preCueRect,
    seated,
    sideCardMotionProgress(slide),
  )!;
}

/// Evaluates all shell-owned SIDECARD state from the same explicit slide.
///
/// While SIDECARD is active, the real desktop must be visible and the terminal
/// window hidden underneath the displaced structural app. Centralizing those
/// values with the moving rectangle keeps Preview and BAKE on one contract.
SideCardShellFrame sideCardShellFrameAt({
  required Size size,
  required Rect preCueRect,
  required double slide,
  Offset origin = Offset.zero,
}) {
  final double motion = sideCardMotionProgress(slide);
  final Rect seated = size.width <= 0.0 || size.height <= 0.0
      ? preCueRect
      : sideCardSeatedVideoWindowRect(size).shift(origin);
  return SideCardShellFrame(
    videoWindowRect: Rect.lerp(preCueRect, seated, motion)!,
    motionProgress: motion,
    desktopOpacity: 1.0,
    terminalOpacity: 0.0,
  );
}
