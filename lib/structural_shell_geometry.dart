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

/// Geometry-only result of applying a MAXIMIZE shell amount to an already
/// evaluated structural window.
///
/// [windowChrome] is 1 for the ordinary desktop window and 0 at fullscreen.
/// Callers deliberately suppress this transform when the STRUCT placement is
/// authored FULL so a geometrically redundant MAXIMIZE cannot fade its chrome
/// as a side effect.
class StructuralMaximizeGeometryFrame {
  const StructuralMaximizeGeometryFrame({
    required this.structuralRect,
    required this.windowChrome,
  });

  final Rect structuralRect;
  final double windowChrome;
}

/// Applies MAXIMIZE after base STRUCT shell geometry (and, when allowed by the
/// caller, after any shell displacement).
///
/// Works in any coordinate space. Preview passes program pixels and BAKE passes
/// normalized output coordinates, so both paths consume exactly one easing and
/// rectangle interpolation policy.
StructuralMaximizeGeometryFrame structuralMaximizeGeometryFrameAt({
  required Rect baseRect,
  required Rect fullRect,
  required double amount,
}) {
  final double linear = amount.clamp(0.0, 1.0).toDouble();
  final double eased = Curves.easeInOutCubic.transform(linear);
  return StructuralMaximizeGeometryFrame(
    structuralRect: Rect.lerp(baseRect, fullRect, eased)!,
    windowChrome: 1.0 - eased,
  );
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

/// One intentional open-scale-and-fade frame used when a seamless STRUCT
/// boundary changes effective presentation shape.
///
/// Shape changes already own the existing window-animation budget. This helper
/// spends that authored time on visible geometry instead of freezing the
/// outgoing final frame. Readiness gates only opacity; geometry remains a pure
/// function of authored opening progress.
class StructuralShapeEntryFrame {
  const StructuralShapeEntryFrame({
    required this.rect,
    required this.opacity,
    required this.easedProgress,
  });

  final Rect rect;
  final double opacity;
  final double easedProgress;
}

StructuralShapeEntryFrame structuralShapeEntryFrameAt({
  required Rect targetRect,
  required double linearProgress,
  required bool contentReady,
}) {
  final double linear = linearProgress.clamp(0.0, 1.0).toDouble();
  final double eased = Curves.easeInOutCubic.transform(linear);
  final Rect emergence = structuralShellEmergenceRect(targetRect);
  return StructuralShapeEntryFrame(
    rect: Rect.lerp(emergence, targetRect, eased)!,
    opacity: contentReady
        ? Curves.easeOutCubic.transform(
            (linear * kStructuralShellVisibilityRamp)
                .clamp(0.0, 1.0),
          )
        : 0.0,
    easedProgress: eased,
  );
}

/// One standard close-scale frame for an independently seated window.
///
/// This is the exact reverse choreography used by the ordinary STRUCT shell:
/// target -> 84% emergence using the authored closing progress and the same
/// easeInOutCubic curve. Opacity remains owned by the outer shell so readiness
/// and visibility rules do not acquire a second authority here.
Rect structuralShapeExitRectAt({
  required Rect targetRect,
  required double linearProgress,
}) {
  final double linear = linearProgress.clamp(0.0, 1.0).toDouble();
  final double eased = Curves.easeInOutCubic.transform(linear);
  return Rect.lerp(
    targetRect,
    structuralShellEmergenceRect(targetRect),
    eased,
  )!;
}

/// Outgoing visibility while an incoming shape opens above it.
///
/// The outgoing presentation remains a stable cover at frame zero and fades
/// across the complete authored window budget. If incoming content is not
/// ready, callers keep the outgoing cover fully visible instead.
double structuralShapeOutgoingOpacity(double linearProgress) {
  final double linear = linearProgress.clamp(0.0, 1.0).toDouble();
  return 1.0 - Curves.easeInOutCubic.transform(linear);
}

/// Evaluates the complete terminal/desktop/structural-window shell.
///
/// All rectangles must use the same coordinate space. [closingOriginRect] is
/// supplied by the caller because source-truncation geometry can be owned by a
/// shell presentation such as SIDECARD, DOSSIER, or MAXIMIZE; once that origin
/// is known, the STRUCT close itself is common.
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
