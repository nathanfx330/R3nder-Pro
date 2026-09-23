// ./lib/structural_window_painter.dart
//
// Shared structural desktop-window raster painter.
//
// Program BAKE and split-window Preview deliberately route through this exact
// painter so chrome, image contain behavior, overlays, shadows, typography,
// opacity, and clipping stay raster-identical at seated frames.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'structural_chrome.dart';
import 'structural_sequence.dart';
import 'ui_theme.dart';

void paintStructuralWindow({
  required Canvas canvas,
  required R3Theme theme,
  required double chromeScale,
  required String fontFamily,
  required int sourceFrame,
  required int sourceDurationFrames,
  required String windowTitle,
  required StructuralOverlayMode overlayMode,
  required String topOverlay,
  required String bottomOverlay,
  required String defaultBottomOverlay,
  required Rect rect,
  required ui.Image? sourceImage,
  required ui.Image? outgoingSourceImage,
  required StructuralSequencePlacement? outgoingPlacement,
  required int outgoingSourceFrame,
  required String outgoingDefaultBottomOverlay,
  required double handoffSlideT,
  required double opacity,
  required double windowChrome,
  FilterQuality imageFilterQuality = FilterQuality.low,
}) {
  if (rect.width <= 0.0 || rect.height <= 0.0 || opacity <= 0.001) {
    return;
  }

  final double s = chromeScale > 0.0 ? chromeScale : 1.0;
  final double c = windowChrome.clamp(0.0, 1.0).toDouble();
  final double barH = 38.0 * s * c;
  final double radius = 5.0 * s * c;
  final RRect window = RRect.fromRectAndRadius(
    rect,
    Radius.circular(radius),
  );
  final String renderedTitle = expandStructuralChromeExpressions(
    windowTitle,
    frame: sourceFrame,
  );
  final String renderedTop = expandStructuralChromeExpressions(
    topOverlay,
    frame: sourceFrame,
  );
  final String renderedBottom = expandStructuralChromeExpressions(
    bottomOverlay,
    frame: sourceFrame,
  );

  final bool handoffActive =
      outgoingSourceImage != null && outgoingPlacement != null;
  final double slideT = handoffSlideT.clamp(0.0, 1.0).toDouble();
  final String outgoingRenderedTitle = handoffActive
      ? expandStructuralChromeExpressions(
          outgoingPlacement!.effectiveWindowTitle,
          frame: outgoingSourceFrame,
        )
      : '';
  final String outgoingRenderedTop = handoffActive
      ? expandStructuralChromeExpressions(
          outgoingPlacement!.topOverlay,
          frame: outgoingSourceFrame,
        )
      : '';
  final String outgoingRenderedBottom = handoffActive
      ? expandStructuralChromeExpressions(
          outgoingPlacement!.bottomOverlay,
          frame: outgoingSourceFrame,
        )
      : '';

  final bool faded = opacity < 0.999;
  if (faded) {
    canvas.saveLayer(
      rect.inflate(40.0 * s),
      Paint()
        ..color = Color.fromARGB(
          (opacity.clamp(0.0, 1.0) * 255.0).round(),
          255,
          255,
          255,
        ),
    );
  }

  if (c > 0.001) {
    canvas.drawRRect(
      window.shift(Offset(0, 16.0 * s * c)),
      Paint()
        ..color = const Color(0x8A000000).withValues(alpha: c)
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          30.0 * s * c,
        ),
    );
  }

  canvas.drawRRect(window, Paint()..color = const Color(0xFF171717));
  if (c > 0.001) {
    canvas.drawRRect(
      window,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.5, s) * c
        ..color = const Color(0xFF3B3938).withValues(alpha: c),
    );
  }

  final Rect header = Rect.fromLTWH(
    rect.left,
    rect.top,
    rect.width,
    math.min(barH, rect.height),
  );
  final Rect client = Rect.fromLTRB(
    rect.left,
    header.bottom,
    rect.right,
    rect.bottom,
  );

  canvas.save();
  canvas.clipRRect(window);
  canvas.drawRect(client, Paint()..color = Colors.black);

  final String? incomingBottomText = switch (overlayMode) {
    StructuralOverlayMode.defaultOverlay =>
      defaultBottomOverlay.isEmpty ? null : defaultBottomOverlay,
    StructuralOverlayMode.custom =>
      renderedBottom.isEmpty ? null : renderedBottom,
    StructuralOverlayMode.none => null,
  };
  final String? outgoingBottomText = !handoffActive
      ? null
      : switch (outgoingPlacement!.overlayMode) {
          StructuralOverlayMode.defaultOverlay =>
            outgoingDefaultBottomOverlay.isEmpty
                ? null
                : outgoingDefaultBottomOverlay,
          StructuralOverlayMode.custom =>
            outgoingRenderedBottom.isEmpty ? null : outgoingRenderedBottom,
          StructuralOverlayMode.none => null,
        };

  if (handoffActive && client.width > 0.0 && client.height > 0.0) {
    if (sourceImage != null) {
      canvas.save();
      canvas.translate(client.width * (1.0 - slideT), 0.0);
      _drawImageContain(
        canvas,
        sourceImage,
        client,
        filterQuality: imageFilterQuality,
      );
      _paintStructuralBottomOverlay(
        canvas: canvas,
        client: client,
        text: incomingBottomText,
        fontFamily: fontFamily,
        theme: theme,
        scale: s,
      );
      canvas.restore();
    }

    canvas.save();
    canvas.translate(-client.width * slideT, 0.0);
    _drawImageContain(
      canvas,
      outgoingSourceImage!,
      client,
      filterQuality: imageFilterQuality,
    );
    _paintStructuralBottomOverlay(
      canvas: canvas,
      client: client,
      text: outgoingBottomText,
      fontFamily: fontFamily,
      theme: theme,
      scale: s,
    );
    canvas.restore();
  } else {
    if (sourceImage != null && client.width > 0.0 && client.height > 0.0) {
      _drawImageContain(
        canvas,
        sourceImage,
        client,
        filterQuality: imageFilterQuality,
      );
    }
    _paintStructuralBottomOverlay(
      canvas: canvas,
      client: client,
      text: incomingBottomText,
      fontFamily: fontFamily,
      theme: theme,
      scale: s,
    );
  }

  if (header.height > 0.01) {
    canvas.drawRect(
      header,
      Paint()..color = const Color(0xFF33302F).withValues(alpha: c),
    );
    canvas.drawLine(
      Offset(header.left, header.bottom),
      Offset(header.right, header.bottom),
      Paint()
        ..strokeWidth = math.max(0.5, s) * c
        ..color = const Color(0xFF474341).withValues(alpha: c),
    );

    final double horizontalPad = 14.0 * s * c;
    final String? incomingTopText = switch (overlayMode) {
      StructuralOverlayMode.defaultOverlay =>
        'F$sourceFrame / $sourceDurationFrames',
      StructuralOverlayMode.custom =>
        renderedTop.isEmpty ? null : renderedTop,
      StructuralOverlayMode.none => null,
    };
    final String? outgoingTopText = !handoffActive
        ? null
        : switch (outgoingPlacement!.overlayMode) {
            StructuralOverlayMode.defaultOverlay =>
              'F$outgoingSourceFrame / '
                  '${outgoingPlacement!.sourceDurationFrames}',
            StructuralOverlayMode.custom =>
              outgoingRenderedTop.isEmpty ? null : outgoingRenderedTop,
            StructuralOverlayMode.none => null,
          };

    void paintHeaderText({
      required String title,
      required String? topText,
      required double alpha,
    }) {
      if (alpha <= 0.001) return;

      TextPainter? right;
      double rightX = header.right - horizontalPad;
      if (topText != null) {
        right = TextPainter(
          text: TextSpan(
            text: topText,
            style: theme.micro.copyWith(
              fontFamily: fontFamily,
              color: const Color(0xFF8E8884).withValues(
                alpha: c * alpha,
              ),
              fontSize: (theme.micro.fontSize ?? 10.5) * s,
              letterSpacing: (theme.micro.letterSpacing ?? 0.0) * s,
            ),
          ),
          maxLines: 1,
          ellipsis: '…',
          textDirection: TextDirection.ltr,
        );
        right.layout(maxWidth: math.max(0.0, header.width * 0.42));
        rightX -= right.width;
      }

      final double labelMax = math.max(
        0.0,
        rightX -
            (header.left + horizontalPad) -
            (right == null ? 0.0 : 10.0 * s),
      );
      final TextPainter left = TextPainter(
        text: TextSpan(
          text: title,
          style: theme.value.copyWith(
            fontFamily: fontFamily,
            color: const Color(0xFFC7C3C0).withValues(
              alpha: c * alpha,
            ),
            fontSize: 12.0 * s,
          ),
        ),
        maxLines: 1,
        ellipsis: '…',
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: labelMax);

      final double leftY = header.top + (header.height - left.height) / 2.0;
      left.paint(canvas, Offset(header.left + horizontalPad, leftY));
      if (right != null) {
        final double rightY =
            header.top + (header.height - right.height) / 2.0;
        right.paint(canvas, Offset(rightX, rightY));
      }
    }

    if (handoffActive) {
      paintHeaderText(
        title: outgoingRenderedTitle,
        topText: outgoingTopText,
        alpha: 1.0 - slideT,
      );
      paintHeaderText(
        title: renderedTitle,
        topText: incomingTopText,
        alpha: slideT,
      );
    } else {
      paintHeaderText(
        title: renderedTitle,
        topText: incomingTopText,
        alpha: 1.0,
      );
    }
  }
  canvas.restore();

  if (faded) canvas.restore();
}

void _paintStructuralBottomOverlay({
  required Canvas canvas,
  required Rect client,
  required String? text,
  required String fontFamily,
  required R3Theme theme,
  required double scale,
}) {
  if (text == null ||
      text.isEmpty ||
      client.width <= 0.0 ||
      client.height <= 0.0) {
    return;
  }

  final TextPainter bottom = TextPainter(
    text: TextSpan(
      text: text,
      style: theme.micro.copyWith(
        fontFamily: fontFamily,
        color: R3Theme.textMid,
        fontSize: (theme.micro.fontSize ?? 10.5) * scale,
        letterSpacing: (theme.micro.letterSpacing ?? 0.0) * scale,
      ),
    ),
    maxLines: 1,
    ellipsis: '…',
    textDirection: TextDirection.ltr,
  );
  bottom.layout(maxWidth: math.max(0.0, client.width - 28.0 * scale));

  final double padX = 6.0 * scale;
  final double padY = 3.0 * scale;
  final Rect plate = Rect.fromLTWH(
    client.left + 8.0 * scale,
    client.bottom - 7.0 * scale - bottom.height - padY * 2.0,
    bottom.width + padX * 2.0,
    bottom.height + padY * 2.0,
  );
  canvas.drawRect(
    plate,
    Paint()..color = Colors.black.withValues(alpha: 0.72),
  );
  bottom.paint(canvas, Offset(plate.left + padX, plate.top + padY));
}

void _drawImageContain(
  Canvas canvas,
  ui.Image image,
  Rect destination, {
  required FilterQuality filterQuality,
}) {
  final double sourceWidth = image.width.toDouble();
  final double sourceHeight = image.height.toDouble();
  if (sourceWidth <= 0.0 || sourceHeight <= 0.0) return;

  final double scale = math.min(
    destination.width / sourceWidth,
    destination.height / sourceHeight,
  );
  final double drawWidth = sourceWidth * scale;
  final double drawHeight = sourceHeight * scale;
  final Rect fitted = Rect.fromLTWH(
    destination.left + (destination.width - drawWidth) / 2.0,
    destination.top + (destination.height - drawHeight) / 2.0,
    drawWidth,
    drawHeight,
  );

  canvas.drawImageRect(
    image,
    Rect.fromLTWH(0, 0, sourceWidth, sourceHeight),
    fitted,
    Paint()..filterQuality = filterQuality,
  );
}
