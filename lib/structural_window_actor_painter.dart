// ./lib/structural_window_actor_painter.dart
//
// Persistent structural-window actor projection.
//
// This layer binds semantic window actors to the existing
// paintStructuralWindow() raster primitive. MosaicLayoutFrame owns geometry,
// opacity, chrome, presence, and z-order; actor visuals own only source imagery
// and structural chrome text/overlay metadata. Preview and BAKE can therefore
// share the same actor frame without independently inferring presentation.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'mosaic_layout_program.dart';
import 'structural_chrome.dart';
import 'structural_window_painter.dart';
import 'ui_theme.dart';

class StructuralWindowActorVisual {
  final ui.Image? sourceImage;
  final int sourceFrame;
  final int sourceDurationFrames;
  final String windowTitle;
  final StructuralOverlayMode overlayMode;
  final String topOverlay;
  final String bottomOverlay;
  final String defaultBottomOverlay;

  const StructuralWindowActorVisual({
    required this.sourceImage,
    required this.sourceFrame,
    required this.sourceDurationFrames,
    required this.windowTitle,
    required this.overlayMode,
    required this.topOverlay,
    required this.bottomOverlay,
    required this.defaultBottomOverlay,
  });

  @override
  bool operator ==(Object other) {
    return other is StructuralWindowActorVisual &&
        other.sourceImage == sourceImage &&
        other.sourceFrame == sourceFrame &&
        other.sourceDurationFrames == sourceDurationFrames &&
        other.windowTitle == windowTitle &&
        other.overlayMode == overlayMode &&
        other.topOverlay == topOverlay &&
        other.bottomOverlay == bottomOverlay &&
        other.defaultBottomOverlay == defaultBottomOverlay;
  }

  @override
  int get hashCode => Object.hash(
        sourceImage,
        sourceFrame,
        sourceDurationFrames,
        windowTitle,
        overlayMode,
        topOverlay,
        bottomOverlay,
        defaultBottomOverlay,
      );
}

void paintStructuralWindowActor({
  required Canvas canvas,
  required R3Theme theme,
  required double chromeScale,
  required String fontFamily,
  required Rect rect,
  required double opacity,
  required double windowChrome,
  required StructuralWindowActorVisual visual,
}) {
  paintStructuralWindow(
    canvas: canvas,
    theme: theme,
    chromeScale: chromeScale,
    fontFamily: fontFamily,
    sourceFrame: visual.sourceFrame,
    sourceDurationFrames: visual.sourceDurationFrames,
    windowTitle: visual.windowTitle,
    overlayMode: visual.overlayMode,
    topOverlay: visual.topOverlay,
    bottomOverlay: visual.bottomOverlay,
    defaultBottomOverlay: visual.defaultBottomOverlay,
    rect: rect,
    sourceImage: visual.sourceImage,
    outgoingSourceImage: null,
    outgoingPlacement: null,
    outgoingSourceFrame: 0,
    outgoingDefaultBottomOverlay: '',
    handoffSlideT: 1.0,
    opacity: opacity,
    windowChrome: windowChrome,
  );
}

class MosaicLayoutWindowPainter extends CustomPainter {
  final MosaicLayoutFrame layoutFrame;
  final Map<MosaicLayoutActorId, StructuralWindowActorVisual> visuals;
  final R3Theme theme;
  final String fontFamily;
  final double chromeScale;

  const MosaicLayoutWindowPainter({
    required this.layoutFrame,
    required this.visuals,
    required this.theme,
    required this.fontFamily,
    required this.chromeScale,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final MosaicLayoutActorFrame actor in layoutFrame.paintActors) {
      final StructuralWindowActorVisual? visual = visuals[actor.actorId];
      if (visual == null) continue;

      paintStructuralWindowActor(
        canvas: canvas,
        theme: theme,
        chromeScale: chromeScale,
        fontFamily: fontFamily,
        rect: actor.rect,
        opacity: actor.opacity,
        windowChrome: actor.chrome,
        visual: visual,
      );
    }
  }

  @override
  bool shouldRepaint(covariant MosaicLayoutWindowPainter oldDelegate) {
    return oldDelegate.layoutFrame != layoutFrame ||
        oldDelegate.theme != theme ||
        oldDelegate.fontFamily != fontFamily ||
        oldDelegate.chromeScale != chromeScale ||
        !_visualMapsEqual(oldDelegate.visuals, visuals);
  }
}

bool _visualMapsEqual(
  Map<MosaicLayoutActorId, StructuralWindowActorVisual> a,
  Map<MosaicLayoutActorId, StructuralWindowActorVisual> b,
) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final MapEntry<MosaicLayoutActorId, StructuralWindowActorVisual> entry
      in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
