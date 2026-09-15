// ./lib/card_overlay.dart
//
// Shared explicit-time CARD overlay rendering for structural video.
//
// A CUE does not own presentation duration or mutable playback state. This
// layer asks edit_cue.dart which CARD presentations are active at one exact
// structural frame, then paints those CARDs over the caller's already-rendered
// pixels. Live preview and program BAKE both use this same Canvas routine.
//
// V1 deliberately supports the structural roots we can place without inventing
// a generic overlay stack: direct EDIT cues fill that EDIT's target, and cues
// authored directly in a MOSAIC pane are clipped to that pane. The presentation
// is pixels only; it contributes no audio.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'edit_cue.dart';
import 'edit_model.dart';
import 'presentation_requests.dart';

/// One active CARD plus the structural pixel region it owns.
class StructuralCardOverlayPlacement {
  const StructuralCardOverlayPlacement({
    required this.card,
    required this.slide,
    required this.normalizedRect,
  });

  final CardRequest card;
  final double slide;

  /// Target rectangle in 0..1 coordinates of the structural render surface.
  /// An EDIT owns the whole surface. A MOSAIC pane owns only its pane.
  final Rect normalizedRect;
}

/// CARD overlays active at [projectFrame] for one selected structural root.
///
/// Authored order is preserved. Later placements are painted later and
/// therefore appear on top, matching edit_cue.dart's deterministic v1 rule.
List<StructuralCardOverlayPlacement> structuralCardOverlayPlacements(
  EditDocumentModel model,
  StructuralSourceRef root,
  int projectFrame,
) {
  switch (root.kind) {
    case StructuralSourceKind.edit:
      final List<ActiveEditCardCue> active =
          activeCardCuesForEdit(model.edit(root.id), projectFrame);
      return List<StructuralCardOverlayPlacement>.unmodifiable(
        active.map(
          (ActiveEditCardCue cue) => StructuralCardOverlayPlacement(
            card: cue.cue.card,
            slide: cue.presentationFrame.slide,
            normalizedRect: const Rect.fromLTWH(0, 0, 1, 1),
          ),
        ),
      );

    case StructuralSourceKind.mosaic:
      final MosaicSequence mosaic = model.mosaic(root.id);
      final List<Rect> layout = _mosaicLayout(mosaic.panes.length);
      final List<StructuralCardOverlayPlacement> result =
          <StructuralCardOverlayPlacement>[];
      for (int i = 0; i < mosaic.panes.length; i++) {
        final MosaicPane pane = mosaic.panes[i];
        final Rect paneRect = layout[i];
        for (final ActiveEditCardCue cue
            in activeCardCuesForPane(pane, projectFrame)) {
          result.add(
            StructuralCardOverlayPlacement(
              card: cue.cue.card,
              slide: cue.presentationFrame.slide,
              normalizedRect: paneRect,
            ),
          );
        }
      }
      return List<StructuralCardOverlayPlacement>.unmodifiable(result);
  }
}

/// Workspace-relative image path used by CARD.
///
/// CARD historically names a file inside images/. Absolute paths remain
/// absolute for test seams and portable tools; an already-prefixed images/
/// path is not doubled.
String structuralCardImageSource(CardRequest card) {
  final String raw = card.image.trim();
  if (raw.isEmpty) return '';
  if (raw.startsWith('/') ||
      raw.startsWith('\\\\') ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(raw)) {
    return raw;
  }
  final String portable = raw.replaceAll('\\', '/');
  return portable.startsWith('images/') ? portable : 'images/$portable';
}

/// Shared decoded-image cache for preview and BAKE.
///
/// Missing CARD images are intentionally survivable, matching the existing
/// TEXT CARD contract: the colored panel still renders and its image strip
/// collapses rather than turning a presentation into an error frame.
class CardOverlayImageCache {
  CardOverlayImageCache(this.resolveSource);

  final String Function(String source) resolveSource;
  final Map<String, ui.Image> _images = <String, ui.Image>{};
  final Set<String> _failed = <String>{};
  final Set<String> _loading = <String>{};
  bool _disposed = false;

  ui.Image? imageFor(CardRequest card) {
    final String key = structuralCardImageSource(card);
    return key.isEmpty ? null : _images[key];
  }

  Future<bool> ensure(
    Iterable<StructuralCardOverlayPlacement> placements,
  ) async {
    bool changed = false;
    for (final StructuralCardOverlayPlacement placement in placements) {
      final String key = structuralCardImageSource(placement.card);
      if (key.isEmpty ||
          _images.containsKey(key) ||
          _failed.contains(key) ||
          _loading.contains(key)) {
        continue;
      }

      _loading.add(key);
      try {
        final String resolved = resolveSource(key);
        final Uint8List bytes = await File(resolved).readAsBytes();
        final ui.Codec codec = await ui.instantiateImageCodec(bytes);
        try {
          final ui.FrameInfo frame = await codec.getNextFrame();
          if (_disposed) {
            frame.image.dispose();
          } else {
            _images[key] = frame.image;
            changed = true;
          }
        } finally {
          codec.dispose();
        }
      } catch (_) {
        if (!_disposed) _failed.add(key);
      } finally {
        _loading.remove(key);
      }
    }
    return changed;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final ui.Image image in _images.values) {
      image.dispose();
    }
    _images.clear();
    _failed.clear();
    _loading.clear();
  }
}

/// Paints CARD overlays over a complete structural surface.
///
/// [size] is the actual structural render surface. The CARD choreography is
/// evaluated inside each placement's own target rectangle, so a cue inside a
/// MOSAIC pane is naturally sized and clipped to that pane instead of escaping
/// to the program frame.
void paintStructuralCardOverlays({
  required Canvas canvas,
  required Size size,
  required Iterable<StructuralCardOverlayPlacement> placements,
  required CardOverlayImageCache images,
  required String fontFamily,
}) {
  if (size.width <= 0.0 || size.height <= 0.0) return;

  for (final StructuralCardOverlayPlacement placement in placements) {
    if (placement.slide <= 0.0) continue;
    final Rect n = placement.normalizedRect;
    final Rect target = Rect.fromLTRB(
      n.left * size.width,
      n.top * size.height,
      n.right * size.width,
      n.bottom * size.height,
    );
    if (target.width <= 0.0 || target.height <= 0.0) continue;

    canvas.save();
    canvas.clipRect(target);
    canvas.translate(target.left, target.top);
    _paintCardPanel(
      canvas,
      target.width,
      target.height,
      placement.slide,
      placement.card,
      images.imageFor(placement.card),
      fontFamily,
    );
    canvas.restore();
  }
}

/// Live overlay widget used by EditVideoPreview.
///
/// It contains no clock. [projectFrame] is supplied by the structural preview
/// transport, and every build re-evaluates presentation state from that exact
/// frame. Image decode readiness may change which pixels occupy the optional
/// image strip, but never the cue trigger or CARD age.
class StructuralCardCueOverlay extends StatefulWidget {
  const StructuralCardCueOverlay({
    super.key,
    required this.source,
    required this.sourceRef,
    required this.projectFrame,
    required this.resolveSource,
    this.fontFamily = 'monospace',
  });

  final String source;
  final String sourceRef;
  final int projectFrame;
  final String Function(String source) resolveSource;
  final String fontFamily;

  @override
  State<StructuralCardCueOverlay> createState() =>
      _StructuralCardCueOverlayState();
}

class _StructuralCardCueOverlayState extends State<StructuralCardCueOverlay> {
  late CardOverlayImageCache _images;
  EditDocumentModel? _model;
  StructuralSourceRef? _root;
  String? _parsedSource;
  String? _parsedSourceRef;

  @override
  void initState() {
    super.initState();
    _images = CardOverlayImageCache(widget.resolveSource);
  }

  @override
  void didUpdateWidget(covariant StructuralCardCueOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resolveSource != widget.resolveSource) {
      _images.dispose();
      _images = CardOverlayImageCache(widget.resolveSource);
    }
    if (oldWidget.source != widget.source ||
        oldWidget.sourceRef != widget.sourceRef) {
      _model = null;
      _root = null;
      _parsedSource = null;
      _parsedSourceRef = null;
    }
  }

  @override
  void dispose() {
    _images.dispose();
    super.dispose();
  }

  List<StructuralCardOverlayPlacement> _placements() {
    if (_model == null ||
        _root == null ||
        _parsedSource != widget.source ||
        _parsedSourceRef != widget.sourceRef) {
      final EditDocumentModel model = EditDocumentModel.parse(widget.source);
      final StructuralSourceRef? root =
          StructuralSourceRef.tryParse(widget.sourceRef);
      if (root == null || root.id.isEmpty || !model.containsStructuralSource(root)) {
        _model = null;
        _root = null;
        return const <StructuralCardOverlayPlacement>[];
      }
      _model = model;
      _root = root;
      _parsedSource = widget.source;
      _parsedSourceRef = widget.sourceRef;
    }

    return structuralCardOverlayPlacements(
      _model!,
      _root!,
      widget.projectFrame,
    );
  }

  void _ensureImages(List<StructuralCardOverlayPlacement> placements) {
    if (placements.isEmpty) return;
    _images.ensure(placements).then((bool changed) {
      if (changed && mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final List<StructuralCardOverlayPlacement> placements = _placements();
    if (placements.isEmpty) return const SizedBox.expand();
    _ensureImages(placements);

    return IgnorePointer(
      child: CustomPaint(
        painter: _StructuralCardOverlayPainter(
          placements: placements,
          images: _images,
          fontFamily: widget.fontFamily,
        ),
      ),
    );
  }
}

class _StructuralCardOverlayPainter extends CustomPainter {
  const _StructuralCardOverlayPainter({
    required this.placements,
    required this.images,
    required this.fontFamily,
  });

  final List<StructuralCardOverlayPlacement> placements;
  final CardOverlayImageCache images;
  final String fontFamily;

  @override
  void paint(Canvas canvas, Size size) {
    // EditVideoPreview contains its decoded 16:9 structural image inside the
    // widget rather than stretching it. Paint into that same fitted frame.
    final Rect frame = _fit16x9(size);
    if (frame.width <= 0.0 || frame.height <= 0.0) return;

    canvas.save();
    canvas.translate(frame.left, frame.top);
    paintStructuralCardOverlays(
      canvas: canvas,
      size: frame.size,
      placements: placements,
      images: images,
      fontFamily: fontFamily,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _StructuralCardOverlayPainter oldDelegate) =>
      oldDelegate.placements != placements ||
      !identical(oldDelegate.images, images) ||
      oldDelegate.fontFamily != fontFamily;
}

Rect _fit16x9(Size size) {
  if (size.width <= 0.0 || size.height <= 0.0) return Rect.zero;
  const double aspect = 16.0 / 9.0;
  double w = size.width;
  double h = w / aspect;
  if (h > size.height) {
    h = size.height;
    w = h * aspect;
  }
  return Rect.fromLTWH(
    (size.width - w) / 2.0,
    (size.height - h) / 2.0,
    w,
    h,
  );
}

void _paintCardPanel(
  Canvas canvas,
  double engineW,
  double engineH,
  double slide,
  CardRequest card,
  ui.Image? image,
  String fontFamily,
) {
  if (slide <= 0.0) return;

  const double cardWidthFrac = 0.30;
  const double cardTopFrac = 0.045;
  const double cardBottomFrac = 0.045;
  const double cardRightFrac = 0.022;
  const double cardRadius = 16.0;
  const double cardImageFrac = 0.42;
  const double cardPadFrac = 0.055;
  const double cardHeadingSize = 34.0;
  const double cardBodySize = 20.0;

  final double s = math.min(engineW / 1920.0, engineH / 1080.0);
  final double cardW = engineW * cardWidthFrac;
  final double top = engineH * cardTopFrac;
  final double bottom = engineH - engineH * cardBottomFrac;
  final double rightGap = engineW * cardRightFrac;

  final double rawProgress = slide.clamp(0.0, 1.0);
  final double e = Curves.easeOutCubic.transform(rawProgress);
  final double seatedLeft = engineW - rightGap - cardW;
  final double left = engineW + (seatedLeft - engineW) * e;

  final Rect cardRect = Rect.fromLTRB(left, top, left + cardW, bottom);
  final RRect rrect = RRect.fromRectAndRadius(
    cardRect,
    Radius.circular(cardRadius * s),
  );

  canvas.save();

  final double pivotX = left + cardW / 2.0;
  final double pivotY = top + cardRect.height / 2.0;
  final double angle = (1.0 - rawProgress) * -0.04;
  final double scaleEffect = 0.98 + 0.02 * rawProgress;
  canvas.translate(pivotX, pivotY);
  canvas.rotate(angle);
  canvas.scale(scaleEffect, scaleEffect);
  canvas.translate(-pivotX, -pivotY);

  canvas.drawRRect(
    rrect.shift(Offset(-2 * s, 4 * s)),
    Paint()
      ..color = const Color(0x66000000)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 14 * s),
  );

  final Color panelColor = card.panelColor;
  canvas.drawRRect(rrect, Paint()..color = panelColor);

  canvas.save();
  canvas.clipRRect(rrect);

  double imageBottom = cardRect.top;
  if (image != null) {
    final double imageH = cardRect.height * cardImageFrac;
    imageBottom = cardRect.top + imageH;
    _drawImageCover(
      canvas,
      image,
      Rect.fromLTWH(cardRect.left, cardRect.top, cardW, imageH),
    );
  }

  final Rect blockRect = Rect.fromLTRB(
    cardRect.left,
    imageBottom,
    cardRect.right,
    cardRect.bottom,
  );
  final bool darkPanel = panelColor.computeLuminance() < 0.35;
  final Color headColor =
      darkPanel ? const Color(0xFFF2F0EC) : const Color(0xFF14120F);
  final Color bodyColor =
      darkPanel ? const Color(0xDDE8E5E0) : const Color(0xDD26221E);
  final Color ruleColor = headColor.withValues(alpha: 0.55);

  final double pad = cardW * cardPadFrac;
  final double textW = cardW - pad * 2.0;
  double cursorY = imageBottom + pad * 1.1;

  if (card.heading.isNotEmpty) {
    final TextPainter heading = TextPainter(
      text: TextSpan(
        text: card.heading,
        style: TextStyle(
          fontFamily: fontFamily,
          fontFamilyFallback: const [
            'Courier',
            'Consolas',
            'Courier New',
            'monospace',
          ],
          fontSize: cardHeadingSize * s,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.5 * s,
          color: headColor,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    heading.layout(maxWidth: textW);
    heading.paint(canvas, Offset(cardRect.left + pad, cursorY));
    cursorY += heading.height + pad * 0.45;
    canvas.drawRect(
      Rect.fromLTWH(cardRect.left + pad, cursorY, textW * 0.42, 3 * s),
      Paint()..color = ruleColor,
    );
    cursorY += pad * 0.65;
  }

  if (card.body.isNotEmpty) {
    final TextPainter body = TextPainter(
      text: TextSpan(
        text: card.body,
        style: TextStyle(
          fontFamily: fontFamily,
          fontFamilyFallback: const [
            'Courier',
            'Consolas',
            'Courier New',
            'monospace',
          ],
          fontSize: cardBodySize * s,
          fontWeight: FontWeight.bold,
          height: 1.55,
          color: bodyColor,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    body.layout(maxWidth: textW);
    canvas.save();
    canvas.clipRect(blockRect);
    body.paint(canvas, Offset(cardRect.left + pad, cursorY));
    canvas.restore();
  }

  canvas.restore();
  canvas.restore();
}

void _drawImageCover(Canvas canvas, ui.Image image, Rect rect) {
  final double iw = image.width.toDouble();
  final double ih = image.height.toDouble();
  if (iw <= 0.0 || ih <= 0.0 || rect.width <= 0.0 || rect.height <= 0.0) {
    return;
  }
  final double scale = math.max(rect.width / iw, rect.height / ih);
  final double w = iw * scale;
  final double h = ih * scale;
  final Rect destination = Rect.fromLTWH(
    rect.left + (rect.width - w) / 2.0,
    rect.top + (rect.height - h) / 2.0,
    w,
    h,
  );
  canvas.save();
  canvas.clipRect(rect);
  canvas.drawImageRect(
    image,
    Rect.fromLTWH(0, 0, iw, ih),
    destination,
    Paint()..filterQuality = FilterQuality.high,
  );
  canvas.restore();
}

List<Rect> _mosaicLayout(int count) {
  if (count <= 0) return const <Rect>[];
  if (count == 1) return const <Rect>[Rect.fromLTRB(0, 0, 1, 1)];
  if (count == 2) {
    return const <Rect>[
      Rect.fromLTRB(0, 0, 0.56, 1),
      Rect.fromLTRB(0.56, 0, 1, 1),
    ];
  }
  return const <Rect>[
    Rect.fromLTRB(0, 0, 0.56, 1),
    Rect.fromLTRB(0.56, 0, 1, 0.5),
    Rect.fromLTRB(0.56, 0.5, 1, 1),
  ];
}
