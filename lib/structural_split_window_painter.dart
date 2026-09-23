// ./lib/structural_split_window_painter.dart
//
// One seated two-window STRUCT painter shared by live Preview and Program BAKE.
//
// W1 owns geometry. W2 owns placement/title/aspect semantics. This class owns
// only the final two-window raster projection and delegates each individual
// desktop window to structural_window_painter.dart.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'mosaic_split_geometry.dart';
import 'structural_sequence.dart';
import 'structural_shell_geometry.dart';
import 'structural_window_painter.dart';
import 'ui_theme.dart';

class StructuralSplitWindowPainter extends CustomPainter {
  final MosaicSplitWindowGeometry geometry;
  final StructuralSequencePlacement placement;
  final int sourceFrame;
  final R3Theme theme;
  final String fontFamily;
  final double chromeScale;
  final List<ui.Image?> images;
  final List<String> diagnosticLabels;
  final double opacity;

  /// Authored open progress for the split-window shell.
  ///
  /// 1.0 is the ordinary seated raster. Values below 1.0 apply the same
  /// emergence -> target easing used by a standard STRUCT window opening to
  /// each split window independently. This covers both normal desktop entry
  /// and split/non-split shape-change entry.
  final double entryProgress;

  /// Authored close progress. Null means this is not a closing frame.
  final double? exitProgress;

  /// Temporary Rocky close diagnostic. When enabled, stamps the authored
  /// source frame into each pane so stale display-list replay can be
  /// distinguished from wrong image-texture content.
  final bool showSourceFrameProbe;

  /// During live close, paint the seated window once and transform the whole
  /// finished surface instead of changing drawImageRect destination geometry.
  final bool closeAsSurfaceTransform;

  const StructuralSplitWindowPainter({
    required this.geometry,
    required this.placement,
    required this.sourceFrame,
    required this.theme,
    required this.fontFamily,
    required this.chromeScale,
    required this.images,
    required this.diagnosticLabels,
    this.opacity = 1.0,
    this.entryProgress = 1.0,
    this.exitProgress,
    this.showSourceFrameProbe = false,
    this.closeAsSurfaceTransform = false,
  })  : assert(images.length == 2),
        assert(diagnosticLabels.length == 2);

  @override
  void paint(Canvas canvas, Size size) {
    final double progress = entryProgress.clamp(0.0, 1.0).toDouble();
    final double? closing = exitProgress?.clamp(0.0, 1.0).toDouble();
    for (int paneIndex = 0; paneIndex < 2; paneIndex++) {
      final Rect target = geometry.windowRects[paneIndex];
      final Rect rect = closing != null
          ? structuralShapeExitRectAt(
              targetRect: target,
              linearProgress: closing,
            )
          : progress >= 0.999999
              ? target
              : structuralShapeEntryFrameAt(
                  targetRect: target,
                  linearProgress: progress,
                  contentReady: true,
                ).rect;
      final Rect paintRect =
          closeAsSurfaceTransform ? target : rect;

      if (closeAsSurfaceTransform) {
        final double sx = target.width <= 0.0 ? 1.0 : rect.width / target.width;
        final double sy =
            target.height <= 0.0 ? 1.0 : rect.height / target.height;
        canvas.save();
        canvas.translate(rect.left, rect.top);
        canvas.scale(sx, sy);
        canvas.translate(-target.left, -target.top);
      }

      paintStructuralWindow(
        canvas: canvas,
        theme: theme,
        chromeScale: chromeScale,
        fontFamily: fontFamily,
        sourceFrame: sourceFrame,
        sourceDurationFrames: placement.sourceDurationFrames,
        windowTitle: placement.splitWindowTitleForPane(paneIndex),
        overlayMode: placement.overlayMode,
        topOverlay: placement.topOverlay,
        bottomOverlay: placement.bottomOverlay,
        defaultBottomOverlay: diagnosticLabels[paneIndex],
        rect: paintRect,
        sourceImage: images[paneIndex],
        outgoingSourceImage: null,
        outgoingPlacement: null,
        outgoingSourceFrame: 0,
        outgoingDefaultBottomOverlay: '',
        handoffSlideT: 1.0,
        opacity: opacity,
        windowChrome: 1.0,
        imageFilterQuality:
            showSourceFrameProbe ? FilterQuality.none : FilterQuality.low,
      );
      if (showSourceFrameProbe) {
        final TextPainter probe = TextPainter(
          text: TextSpan(
            text: 'SF $sourceFrame  IMG '
                '${images[paneIndex] == null ? "null" : identityHashCode(images[paneIndex])}',
            style: TextStyle(
              fontFamily: fontFamily,
              fontSize: math.max(14.0, 22.0 * chromeScale),
              fontWeight: FontWeight.w700,
              color: Colors.yellow,
              backgroundColor: Colors.black,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        probe.paint(
          canvas,
          Offset(
            paintRect.left + 10.0 * chromeScale,
            paintRect.top + 48.0 * chromeScale,
          ),
        );
      }

      if (closeAsSurfaceTransform) {
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(covariant StructuralSplitWindowPainter oldDelegate) {
    return oldDelegate.geometry != geometry ||
        oldDelegate.placement != placement ||
        oldDelegate.sourceFrame != sourceFrame ||
        oldDelegate.theme != theme ||
        oldDelegate.fontFamily != fontFamily ||
        oldDelegate.chromeScale != chromeScale ||
        oldDelegate.opacity != opacity ||
        oldDelegate.entryProgress != entryProgress ||
        oldDelegate.exitProgress != exitProgress ||
        oldDelegate.showSourceFrameProbe != showSourceFrameProbe ||
        oldDelegate.closeAsSurfaceTransform != closeAsSurfaceTransform ||
        oldDelegate.images[0] != images[0] ||
        oldDelegate.images[1] != images[1] ||
        oldDelegate.diagnosticLabels[0] != diagnosticLabels[0] ||
        oldDelegate.diagnosticLabels[1] != diagnosticLabels[1];
  }
}
