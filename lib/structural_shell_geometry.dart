// ./lib/structural_shell_geometry.dart
//
// Pure explicit-time geometry for the outer STRUCT desktop shell.
//
// Preview and BAKE both place the same structural source inside the same
// terminal/desktop choreography. The only preview-only fact is whether the
// incoming client has produced one presentable frame yet. Keeping readiness as
// an input here makes that intentional difference explicit while preventing the
// stage geometry, opacity curves, and visibility ramp from drifting between the
// two render paths.

import 'dart:ui';

import 'package:flutter/animation.dart';

import 'structural_sequence.dart';

/// Visibility ramp used while the structural app enters/leaves the desktop.
///
/// This used to be a duplicated magic 2.2 in Preview and BAKE. It is a named
/// fact now so visual tuning cannot accidentally change only one path.
const double kStructuralShellVisibilityRamp = 2.2;

/// One evaluated outer STRUCT shell frame.
class StructuralShellFrame {
  const StructuralShellFrame({
    required this.terminalRect,
    required this.structuralRect,
    required this.desktopOpacity,
    required this.terminalOpacity,
    required this.terminalChrome,
    required this.structuralOpacity,
    required this.structuralWindowPresent,
  });

  final Rect terminalRect;
  final Rect structuralRect;
  final double desktopOpacity;
  final double terminalOpacity;
  final double terminalChrome;
  final double structuralOpacity;
  final bool structuralWindowPresent;
}

/// Shared emergence rectangle used before/after the seated structural window.
///
/// Works in any coordinate space. Preview passes fitted-program pixels; BAKE
/// passes normalized output coordinates.
Rect structuralShellEmergenceRect(Rect target) {
  const double scale = 0.84;
  final double w = target.width * scale;
  final double h = target.height * scale;
  return Rect.fromLTWH(
    target.center.dx - w / 2.0,
    target.center.dy - h / 2.0 + target.height * 0.055,
    w,
    h,
  );
}

/// Evaluates the complete terminal/desktop/structural-window shell.
///
/// All rectangles must use the same coordinate space. [closingOriginRect] is
/// supplied by the caller because SIDECARD/DOSSIER source-truncation geometry
/// is presentation-specific; once that origin is known, the STRUCT close itself
/// is common.
///
/// [contentReady] is the one deliberate Preview/BAKE difference. Live Preview
/// can hold opening/showing visibility until decoded client pixels are resident;
/// BAKE always passes true because its source frame is resolved synchronously.
StructuralShellFrame structuralShellFrameAt({
  required StructuralSequenceStage stage,
  required double linearProgress,
  required Rect fullTerminalRect,
  required Rect terminalParkRect,
  required Rect presentationRect,
  required Rect previousPresentationRect,
  required Rect closingOriginRect,
  required bool seamlessFromPrevious,
  required bool chainedFromPrevious,
  required bool chainedToNext,
  required bool contentReady,
}) {
  final double linear = linearProgress.clamp(0.0, 1.0).toDouble();
  final double eased = Curves.easeInOutCubic.transform(linear);
  final Rect emergenceRect = structuralShellEmergenceRect(terminalParkRect);

  switch (stage) {
    case StructuralSequenceStage.zoomOut:
      return StructuralShellFrame(
        terminalRect: Rect.lerp(fullTerminalRect, terminalParkRect, eased)!,
        structuralRect: emergenceRect,
        desktopOpacity: eased,
        terminalOpacity: 1.0,
        terminalChrome: eased,
        structuralOpacity: 0.0,
        structuralWindowPresent: true,
      );

    case StructuralSequenceStage.opening:
      final double handoffLinear = contentReady ? linear : 0.0;
      final double handoffEased =
          Curves.easeInOutCubic.transform(handoffLinear);
      if (seamlessFromPrevious) {
        return StructuralShellFrame(
          terminalRect: terminalParkRect,
          structuralRect: Rect.lerp(
            previousPresentationRect,
            presentationRect,
            handoffEased,
          )!,
          desktopOpacity: 1.0,
          terminalOpacity: 0.0,
          terminalChrome: 1.0,
          structuralOpacity: contentReady ? 1.0 : 0.0,
          structuralWindowPresent: true,
        );
      }

      return StructuralShellFrame(
        terminalRect: terminalParkRect,
        structuralRect: Rect.lerp(
          emergenceRect,
          presentationRect,
          handoffEased,
        )!,
        desktopOpacity: 1.0,
        terminalOpacity:
            chainedFromPrevious ? 0.0 : 1.0 - handoffEased,
        terminalChrome: 1.0,
        structuralOpacity: contentReady
            ? Curves.easeOutCubic.transform(
                (handoffLinear * kStructuralShellVisibilityRamp)
                    .clamp(0.0, 1.0),
              )
            : 0.0,
        structuralWindowPresent: true,
      );

    case StructuralSequenceStage.showing:
      return StructuralShellFrame(
        terminalRect: terminalParkRect,
        structuralRect: contentReady
            ? presentationRect
            : (seamlessFromPrevious
                ? previousPresentationRect
                : emergenceRect),
        desktopOpacity: 1.0,
        terminalOpacity:
            (!contentReady && !chainedFromPrevious) ? 1.0 : 0.0,
        terminalChrome: 1.0,
        structuralOpacity: contentReady ? 1.0 : 0.0,
        structuralWindowPresent: true,
      );

    case StructuralSequenceStage.closing:
      return StructuralShellFrame(
        terminalRect: terminalParkRect,
        structuralRect:
            Rect.lerp(closingOriginRect, emergenceRect, eased)!,
        desktopOpacity: 1.0,
        terminalOpacity: chainedToNext ? 0.0 : eased,
        terminalChrome: 1.0,
        structuralOpacity: Curves.easeInCubic.transform(
          ((1.0 - linear) * kStructuralShellVisibilityRamp)
              .clamp(0.0, 1.0),
        ),
        structuralWindowPresent: true,
      );

    case StructuralSequenceStage.zoomIn:
      return StructuralShellFrame(
        terminalRect: Rect.lerp(terminalParkRect, fullTerminalRect, eased)!,
        structuralRect: presentationRect,
        desktopOpacity: 1.0 - eased,
        terminalOpacity: 1.0,
        terminalChrome: 1.0 - eased,
        structuralOpacity: 0.0,
        structuralWindowPresent: false,
      );
  }
}
