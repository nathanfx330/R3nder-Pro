// ./lib/presentation_panel_painter.dart
//
// Semantic painting for structured CARD-family PANEL content.
//
// This file deliberately knows nothing about CUE timing, SIDECARD shell
// movement, structural windows, or source placement. card_overlay.dart owns the
// presentation surface and passes one already-parsed PresentationPanelContent
// here. The result is a richer documentary identity hierarchy without creating
// a freeform layout language.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'presentation_panel_content.dart';

const List<String> kPresentationPanelFontFallback = <String>[
  'Courier',
  'Consolas',
  'Courier New',
  'monospace',
];

String presentationPanelFontFamily(
  PresentationPanelContent content,
  String inheritedFontFamily,
) {
  final String authored = content.fontFamily.trim();
  return authored.isEmpty ? inheritedFontFamily : authored;
}

String presentationPanelKickerText(PresentationPanelContent content) {
  final String authored = content.kicker.trim();
  return authored.isEmpty
      ? presentationPanelDefaultKicker(content.preset)
      : authored;
}

Color presentationPanelAccentColor({
  required Color panelColor,
  required Color headColor,
}) {
  final bool dark = panelColor.computeLuminance() < 0.35;
  return Color.lerp(panelColor, headColor, dark ? 0.58 : 0.42)!;
}

/// Adds the photographic treatment for a rich DOCUMENTARY/DOSSIER card.
///
/// The portrait remains the authored image. This only adds a subtle lower
/// scrim, an identity kicker, and a fine accent rule so the image and textual
/// hierarchy read as one designed object rather than an image stacked over a
/// settings table.
void paintPresentationPanelPhotoTreatment({
  required Canvas canvas,
  required Rect imageRect,
  required PresentationPanelContent content,
  required Color panelColor,
  required Color headColor,
  required String inheritedFontFamily,
  required double scale,
}) {
  if (imageRect.width <= 0.0 || imageRect.height <= 0.0) return;

  final String fontFamily =
      presentationPanelFontFamily(content, inheritedFontFamily);
  final Color accent = presentationPanelAccentColor(
    panelColor: panelColor,
    headColor: headColor,
  );
  final double scrimH = imageRect.height * 0.42;
  final Rect scrimRect = Rect.fromLTWH(
    imageRect.left,
    imageRect.bottom - scrimH,
    imageRect.width,
    scrimH,
  );
  canvas.drawRect(
    scrimRect,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[
          Colors.transparent,
          panelColor.withValues(alpha: 0.84),
        ],
      ).createShader(scrimRect),
  );

  final double lineH = math.max(2.0 * scale, 1.0);
  canvas.drawRect(
    Rect.fromLTWH(
      imageRect.left,
      imageRect.bottom - lineH,
      imageRect.width,
      lineH,
    ),
    Paint()..color = accent.withValues(alpha: 0.92),
  );

  final double padX = math.max(18.0 * scale, imageRect.width * 0.055);
  final double bottom = imageRect.bottom - math.max(13.0 * scale, lineH * 3.0);
  _paintKicker(
    canvas: canvas,
    text: presentationPanelKickerText(content),
    origin: Offset(imageRect.left + padX, bottom),
    maxWidth: math.max(0.0, imageRect.width - padX * 2.0),
    fontFamily: fontFamily,
    scale: scale,
    color: headColor,
    baselineFromBottom: true,
  );
}

/// Paints the semantic content hierarchy below the portrait.
///
/// Layout roles are fixed and named: identity, role, facts, biography. The
/// authored source can choose content and preset but not arbitrary coordinates,
/// per-field type sizes, or ordering.
void paintPresentationPanelContent({
  required Canvas canvas,
  required Rect cardRect,
  required double contentTop,
  required PresentationPanelContent content,
  required double pad,
  required double scale,
  required Color panelColor,
  required Color headColor,
  required Color bodyColor,
  required String inheritedFontFamily,
  required bool showKicker,
}) {
  final String fontFamily =
      presentationPanelFontFamily(content, inheritedFontFamily);
  final Color accent = presentationPanelAccentColor(
    panelColor: panelColor,
    headColor: headColor,
  );
  final bool editorial =
      content.preset == PresentationPanelPreset.editorial;
  final double headingSize =
      content.headingSize ?? (editorial ? 32.0 : 34.0);
  final double bodySize =
      content.bodySize ?? (editorial ? 17.0 : 15.5);
  final double left = cardRect.left + pad;
  final double right = cardRect.right - pad;
  final double textW = math.max(0.0, right - left);
  double cursorY = contentTop + pad * 0.70;

  if (showKicker) {
    final String kicker = presentationPanelKickerText(content);
    if (kicker.isNotEmpty) {
      final double kickerH = editorial
          ? _paintEditorialKicker(
              canvas: canvas,
              text: kicker,
              origin: Offset(left, cursorY),
              maxWidth: textW,
              fontFamily: fontFamily,
              scale: scale,
              referenceBodySize: bodySize,
              color: accent,
            )
          : _paintKicker(
              canvas: canvas,
              text: kicker,
              origin: Offset(left, cursorY),
              maxWidth: textW,
              fontFamily: fontFamily,
              scale: scale,
              color: accent,
            );
      cursorY += kickerH + pad * 0.34;
    }
  }

  if (content.heading.isNotEmpty) {
    final TextPainter heading = TextPainter(
      text: TextSpan(
        text: content.heading,
        style: TextStyle(
          fontFamily: fontFamily,
          fontFamilyFallback: kPresentationPanelFontFallback,
          fontSize: headingSize * scale,
          fontWeight: editorial ? FontWeight.w700 : FontWeight.w800,
          letterSpacing: (editorial ? 0.0 : -0.15) * scale,
          height: editorial ? 1.08 : 1.02,
          color: headColor,
        ),
      ),
      maxLines: 2,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: textW);
    heading.paint(canvas, Offset(left, cursorY));
    cursorY += heading.height + pad * (editorial ? 0.30 : 0.18);
  }

  if (content.subtitle.isNotEmpty) {
    final TextPainter subtitle = TextPainter(
      text: TextSpan(
        text: content.subtitle,
        style: TextStyle(
          fontFamily: fontFamily,
          fontFamilyFallback: kPresentationPanelFontFallback,
          fontSize: (editorial ? bodySize * 0.85 : 14.5) * scale,
          fontWeight: editorial ? FontWeight.w500 : FontWeight.w600,
          height: editorial ? 1.28 : 1.20,
          color: accent.withValues(alpha: 0.96),
        ),
      ),
      maxLines: 2,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: textW);
    subtitle.paint(canvas, Offset(left, cursorY));
    cursorY += subtitle.height + pad * 0.42;
  } else if (content.heading.isNotEmpty) {
    cursorY += pad * 0.14;
  }

  if (content.metadata.isNotEmpty) {
    cursorY = _paintMetadataGrid(
      canvas: canvas,
      content: content,
      left: left,
      right: right,
      top: cursorY,
      cardBottom: cardRect.bottom - pad,
      fontFamily: fontFamily,
      scale: scale,
      accent: accent,
      headColor: headColor,
    );
    cursorY += pad * 0.46;
  }

  if (content.body.isNotEmpty && cursorY < cardRect.bottom - pad) {
    if (!editorial) {
      final String section = content.preset == PresentationPanelPreset.dossier
          ? 'SUBJECT NOTES'
          : 'BIOGRAPHY';
      final double labelH = _paintSectionLabel(
        canvas: canvas,
        text: section,
        origin: Offset(left, cursorY),
        maxWidth: textW,
        fontFamily: fontFamily,
        scale: scale,
        color: accent.withValues(alpha: 0.82),
      );
      cursorY += labelH + pad * 0.22;
    }

    final TextPainter body = TextPainter(
      text: TextSpan(
        text: content.body,
        style: TextStyle(
          fontFamily: fontFamily,
          fontFamilyFallback: kPresentationPanelFontFallback,
          fontSize: bodySize * scale,
          fontWeight: editorial ? FontWeight.w400 : FontWeight.w500,
          height: editorial ? 1.50 : 1.40,
          color: bodyColor.withValues(alpha: 0.94),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: textW);

    canvas.save();
    canvas.clipRect(
      Rect.fromLTRB(left, cursorY, right, cardRect.bottom - pad),
    );
    body.paint(canvas, Offset(left, cursorY));
    canvas.restore();
  }
}

double _paintEditorialKicker({
  required Canvas canvas,
  required String text,
  required Offset origin,
  required double maxWidth,
  required String fontFamily,
  required double scale,
  required double referenceBodySize,
  required Color color,
}) {
  final TextPainter painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: fontFamily,
        fontFamilyFallback: kPresentationPanelFontFallback,
        fontSize: (referenceBodySize * (10.5 / 17.0)) * scale,
        fontWeight: FontWeight.w700,
        letterSpacing: (referenceBodySize * (1.8 / 17.0)) * scale,
        color: color.withValues(alpha: 0.96),
      ),
    ),
    maxLines: 1,
    ellipsis: '…',
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: maxWidth);
  painter.paint(canvas, origin);
  return math.max(painter.height, 12.0 * scale);
}

double _paintKicker({
  required Canvas canvas,
  required String text,
  required Offset origin,
  required double maxWidth,
  required String fontFamily,
  required double scale,
  required Color color,
  bool baselineFromBottom = false,
}) {
  final double markerW = math.max(3.0 * scale, 1.0);
  final double gap = math.max(8.0 * scale, 3.0);
  final TextPainter painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: fontFamily,
        fontFamilyFallback: kPresentationPanelFontFallback,
        fontSize: 10.5 * scale,
        fontWeight: FontWeight.w700,
        letterSpacing: 2.0 * scale,
        color: color,
      ),
    ),
    maxLines: 1,
    ellipsis: '…',
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: math.max(0.0, maxWidth - markerW - gap));

  final double h = math.max(painter.height, 12.0 * scale);
  final double top = baselineFromBottom ? origin.dy - h : origin.dy;
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTWH(origin.dx, top, markerW, h),
      Radius.circular(markerW / 2.0),
    ),
    Paint()..color = color.withValues(alpha: 0.92),
  );
  painter.paint(canvas, Offset(origin.dx + markerW + gap, top));
  return h;
}

double _paintMetadataGrid({
  required Canvas canvas,
  required PresentationPanelContent content,
  required double left,
  required double right,
  required double top,
  required double cardBottom,
  required String fontFamily,
  required double scale,
  required Color accent,
  required Color headColor,
}) {
  final int count = math.min(4, content.metadata.length);
  if (count <= 0) return top;

  final double width = math.max(0.0, right - left);
  final int columns = count == 1 ? 1 : 2;
  final double gapX = math.max(9.0 * scale, width * 0.028);
  final double gapY = math.max(8.0 * scale, 4.0);
  final double cellW = columns == 1
      ? width
      : math.max(0.0, (width - gapX) / 2.0);
  final double cellH = math.max(54.0 * scale, 30.0);
  final double radius = math.max(7.0 * scale, 3.0);
  final double innerX = math.max(11.0 * scale, 6.0);
  final double innerY = math.max(8.0 * scale, 5.0);

  double bottom = top;
  for (int i = 0; i < count; i++) {
    final int column = i % columns;
    final int row = i ~/ columns;
    final double x = left + column * (cellW + gapX);
    final double y = top + row * (cellH + gapY);
    if (y + cellH > cardBottom) break;

    final Rect cell = Rect.fromLTWH(x, y, cellW, cellH);
    canvas.drawRRect(
      RRect.fromRectAndRadius(cell, Radius.circular(radius)),
      Paint()..color = headColor.withValues(alpha: 0.045),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(cell, Radius.circular(radius)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.65 * scale, 0.5)
        ..color = headColor.withValues(alpha: 0.10),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          cell.left,
          cell.top,
          math.max(2.5 * scale, 1.0),
          cell.height,
        ),
        Radius.circular(radius),
      ),
      Paint()..color = accent.withValues(alpha: 0.78),
    );

    final PresentationPanelMetadata item = content.metadata[i];
    final TextPainter label = TextPainter(
      text: TextSpan(
        text: item.label.toUpperCase(),
        style: TextStyle(
          fontFamily: fontFamily,
          fontFamilyFallback: kPresentationPanelFontFallback,
          fontSize: 8.8 * scale,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.20 * scale,
          color: accent.withValues(alpha: 0.82),
        ),
      ),
      maxLines: 1,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(0.0, cellW - innerX * 2.0));
    label.paint(canvas, Offset(cell.left + innerX, cell.top + innerY));

    final TextPainter value = TextPainter(
      text: TextSpan(
        text: item.value,
        style: TextStyle(
          fontFamily: fontFamily,
          fontFamilyFallback: kPresentationPanelFontFallback,
          fontSize: 12.5 * scale,
          fontWeight: FontWeight.w600,
          height: 1.12,
          color: headColor.withValues(alpha: 0.96),
        ),
      ),
      maxLines: 2,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(0.0, cellW - innerX * 2.0));
    value.paint(
      canvas,
      Offset(
        cell.left + innerX,
        cell.top + innerY + label.height + math.max(3.0 * scale, 2.0),
      ),
    );
    bottom = math.max(bottom, cell.bottom);
  }

  return bottom;
}

double _paintSectionLabel({
  required Canvas canvas,
  required String text,
  required Offset origin,
  required double maxWidth,
  required String fontFamily,
  required double scale,
  required Color color,
}) {
  final TextPainter painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: fontFamily,
        fontFamilyFallback: kPresentationPanelFontFallback,
        fontSize: 9.2 * scale,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.55 * scale,
        color: color,
      ),
    ),
    maxLines: 1,
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: maxWidth);
  painter.paint(canvas, origin);
  return painter.height;
}
