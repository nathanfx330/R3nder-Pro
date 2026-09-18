// ./lib/presentation_card_face_preview.dart
//
// Read-only CARD-family face preview for authoring surfaces.
//
// This is intentionally a client of the same painter and decoded-image cache as
// structural Preview/BAKE. It owns no alternate layout math and no persistent
// style state. The preview derives the canonical SIDECARD panel rectangle from
// the shared geometry, translates that rectangle into its local canvas, and
// asks paintPresentationCardFace() to draw the result.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'card_overlay.dart';
import 'presentation_requests.dart';

class PresentationCardFacePreview extends StatefulWidget {
  const PresentationCardFacePreview({
    super.key,
    required this.card,
    this.resolveSource,
    this.inheritedFontFamily = 'monospace',
    this.maxCardWidth = 360.0,
  });

  final CardRequest card;
  final String Function(String source)? resolveSource;
  final String inheritedFontFamily;
  final double maxCardWidth;

  @override
  State<PresentationCardFacePreview> createState() =>
      _PresentationCardFacePreviewState();
}

class _PresentationCardFacePreviewState
    extends State<PresentationCardFacePreview> {
  CardOverlayImageCache? _images;

  @override
  void initState() {
    super.initState();
    _resetCache();
    _ensureImage();
  }

  @override
  void didUpdateWidget(covariant PresentationCardFacePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool resolverChanged = oldWidget.resolveSource != widget.resolveSource;
    final bool imageChanged =
        structuralCardImageSource(oldWidget.card) !=
            structuralCardImageSource(widget.card);
    if (resolverChanged || imageChanged) {
      _resetCache();
    }
    _ensureImage();
  }

  void _resetCache() {
    _images?.dispose();
    final String Function(String source)? resolver = widget.resolveSource;
    _images = resolver == null ? null : CardOverlayImageCache(resolver);
  }

  void _ensureImage() {
    final CardOverlayImageCache? images = _images;
    if (images == null || structuralCardImageSource(widget.card).isEmpty) {
      return;
    }
    images.ensureCards(<CardRequest>[widget.card]).then((bool changed) {
      if (changed && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _images?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double available = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : widget.maxCardWidth;
        final double cardWidth = math.max(
          1.0,
          math.min(widget.maxCardWidth, available - 16.0),
        );

        // SIDECARD's panel is 30% of the reference composition width. Build an
        // equivalent 16:9 composition around the requested preview width, then
        // use the shared geometry to obtain the real panel aspect/height.
        final double compositionWidth = cardWidth / 0.30;
        final ui.Size compositionSize = ui.Size(
          compositionWidth,
          compositionWidth * 9.0 / 16.0,
        );
        final ui.Rect panelRect = sideCardSeatedPanelRect(compositionSize);
        const double margin = 8.0;
        final ui.Size previewSize = ui.Size(
          panelRect.width + margin * 2.0,
          panelRect.height + margin * 2.0,
        );

        return Align(
          alignment: Alignment.topCenter,
          child: RepaintBoundary(
            key: const ValueKey<String>('presentation-card-face-preview'),
            child: SizedBox(
              width: previewSize.width,
              height: previewSize.height,
              child: CustomPaint(
                painter: _PresentationCardFacePainter(
                  compositionSize: compositionSize,
                  panelRect: panelRect,
                  card: widget.card,
                  image: _images?.imageFor(widget.card),
                  inheritedFontFamily: widget.inheritedFontFamily,
                  margin: margin,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PresentationCardFacePainter extends CustomPainter {
  const _PresentationCardFacePainter({
    required this.compositionSize,
    required this.panelRect,
    required this.card,
    required this.image,
    required this.inheritedFontFamily,
    required this.margin,
  });

  final ui.Size compositionSize;
  final ui.Rect panelRect;
  final CardRequest card;
  final ui.Image? image;
  final String inheritedFontFamily;
  final double margin;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(
      margin - panelRect.left,
      margin - panelRect.top,
    );
    paintPresentationCardFace(
      canvas: canvas,
      compositionSize: compositionSize,
      cardRect: panelRect,
      card: card,
      image: image,
      inheritedFontFamily: inheritedFontFamily,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PresentationCardFacePainter oldDelegate) =>
      !identical(oldDelegate.card, card) ||
      !identical(oldDelegate.image, image) ||
      oldDelegate.compositionSize != compositionSize ||
      oldDelegate.panelRect != panelRect ||
      oldDelegate.inheritedFontFamily != inheritedFontFamily ||
      oldDelegate.margin != margin;
}
