// ./lib/presentation_card_face_preview.dart
//
// Read-only CARD-family face preview for authoring surfaces.
//
// The preview owns no alternate card layout. It fits the canonical seated
// SIDECARD panel from the 1920x1080 reference composition into a preview slot,
// centers it, and delegates every intrinsic pixel to
// paintPresentationCardFace(). The same decoded-image cache used by structural
// Preview/BAKE supplies the optional hero image.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'card_overlay.dart';
import 'presentation_requests.dart';

const Size kPresentationCardReferenceComposition = Size(1920, 1080);

/// Fits the canonical seated CARD face inside [slotSize] without distortion.
///
/// Height commonly binds in the inspector, so the returned rect is deliberately
/// centered and may leave letterbox space on the left and right.
Rect presentationCardFacePreviewRect(
  Size slotSize, {
  double inset = 8.0,
}) {
  if (slotSize.width <= 0.0 || slotSize.height <= 0.0) return Rect.zero;

  final Rect reference = sideCardSeatedPanelRect(
    kPresentationCardReferenceComposition,
  );
  if (reference.width <= 0.0 || reference.height <= 0.0) return Rect.zero;

  final double usableW = math.max(0.0, slotSize.width - inset * 2.0);
  final double usableH = math.max(0.0, slotSize.height - inset * 2.0);
  if (usableW <= 0.0 || usableH <= 0.0) return Rect.zero;

  final double scale = math.min(
    usableW / reference.width,
    usableH / reference.height,
  );
  final Size fitted = Size(
    reference.width * scale,
    reference.height * scale,
  );
  return Rect.fromCenter(
    center: slotSize.center(Offset.zero),
    width: fitted.width,
    height: fitted.height,
  );
}

double presentationCardFacePreviewScale(
  Size slotSize, {
  double inset = 8.0,
}) {
  final Rect reference = sideCardSeatedPanelRect(
    kPresentationCardReferenceComposition,
  );
  final Rect fitted = presentationCardFacePreviewRect(
    slotSize,
    inset: inset,
  );
  if (reference.width <= 0.0 || fitted.width <= 0.0) return 0.0;
  return fitted.width / reference.width;
}

PresentationCardFaceFocusTarget? presentationCardFacePreviewFocusTargetAt({
  required Size slotSize,
  required CardRequest card,
  required ui.Image? image,
  required String inheritedFontFamily,
  required Offset position,
  double inset = 8.0,
}) {
  final Rect rect = presentationCardFacePreviewRect(
    slotSize,
    inset: inset,
  );
  final double scale = presentationCardFacePreviewScale(
    slotSize,
    inset: inset,
  );
  if (rect.isEmpty || scale <= 0.0) return null;

  return presentationCardFaceFocusTargetAt(
    rect,
    scale,
    card,
    image,
    inheritedFontFamily,
    position,
  );
}

void paintPresentationCardFacePreview({
  required Canvas canvas,
  required Size slotSize,
  required CardRequest card,
  required ui.Image? image,
  required String inheritedFontFamily,
  double inset = 8.0,
}) {
  final Rect rect = presentationCardFacePreviewRect(
    slotSize,
    inset: inset,
  );
  final double scale = presentationCardFacePreviewScale(
    slotSize,
    inset: inset,
  );
  if (rect.isEmpty || scale <= 0.0) return;

  paintPresentationCardFace(
    canvas,
    rect,
    scale,
    card,
    image,
    inheritedFontFamily,
  );
}

class PresentationCardFacePreview extends StatefulWidget {
  const PresentationCardFacePreview({
    super.key,
    required this.card,
    this.resolveSource,
    this.inheritedFontFamily = 'monospace',
    this.height = 240.0,
    this.inset = 8.0,
    this.onKickerTap,
    this.onHeadingTap,
    this.onBodyTap,
  });

  final CardRequest card;
  final String Function(String source)? resolveSource;
  final String inheritedFontFamily;
  final double height;
  final double inset;
  final VoidCallback? onKickerTap;
  final VoidCallback? onHeadingTap;
  final VoidCallback? onBodyTap;

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
    return RepaintBoundary(
      key: const ValueKey<String>('presentation-card-face-preview'),
      child: SizedBox(
        height: widget.height,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final double width =
                constraints.maxWidth.isFinite ? constraints.maxWidth : 360.0;
            final Size slotSize = Size(width, widget.height);
            final ui.Image? image = _images?.imageFor(widget.card);

            void handleTap(TapDownDetails details) {
              final PresentationCardFaceFocusTarget? target =
                  presentationCardFacePreviewFocusTargetAt(
                slotSize: slotSize,
                card: widget.card,
                image: image,
                inheritedFontFamily: widget.inheritedFontFamily,
                position: details.localPosition,
                inset: widget.inset,
              );
              switch (target) {
                case PresentationCardFaceFocusTarget.kicker:
                  widget.onKickerTap?.call();
                  return;
                case PresentationCardFaceFocusTarget.heading:
                  widget.onHeadingTap?.call();
                  return;
                case PresentationCardFaceFocusTarget.body:
                  widget.onBodyTap?.call();
                  return;
                case null:
                  return;
              }
            }

            final bool interactive =
                widget.onKickerTap != null ||
                widget.onHeadingTap != null ||
                widget.onBodyTap != null;

            final Widget paint = CustomPaint(
              key: const ValueKey<String>('presentation-card-face-preview-paint'),
              size: slotSize,
              painter: _PresentationCardFacePainter(
                card: widget.card,
                image: image,
                inheritedFontFamily: widget.inheritedFontFamily,
                slotSize: slotSize,
                inset: widget.inset,
              ),
            );

            if (!interactive) return paint;
            return MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                key: const ValueKey<String>(
                  'presentation-card-face-preview-hit-surface',
                ),
                behavior: HitTestBehavior.opaque,
                onTapDown: handleTap,
                child: paint,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _PresentationCardFacePainter extends CustomPainter {
  const _PresentationCardFacePainter({
    required this.card,
    required this.image,
    required this.inheritedFontFamily,
    required this.slotSize,
    required this.inset,
  });

  final CardRequest card;
  final ui.Image? image;
  final String inheritedFontFamily;
  final Size slotSize;
  final double inset;

  @override
  void paint(Canvas canvas, Size size) {
    paintPresentationCardFacePreview(
      canvas: canvas,
      slotSize: slotSize,
      card: card,
      image: image,
      inheritedFontFamily: inheritedFontFamily,
      inset: inset,
    );
  }

  @override
  bool shouldRepaint(covariant _PresentationCardFacePainter oldDelegate) =>
      !identical(oldDelegate.card, card) ||
      !identical(oldDelegate.image, image) ||
      oldDelegate.inheritedFontFamily != inheritedFontFamily ||
      oldDelegate.slotSize != slotSize ||
      oldDelegate.inset != inset;
}
