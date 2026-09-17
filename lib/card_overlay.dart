// ./lib/card_overlay.dart
//
// Shared explicit-time CARD-family painting for structural video.
//
// A CUE does not own presentation duration or mutable playback state. Placement
// selection and lifetime projection live in card_overlay_state.dart; this file
// loads presentation images and paints the already-evaluated state. Live preview
// and program BAKE therefore consume the same placement model without making
// the painter another presentation engine.
//
// CARD is the fullscreen overlay discovered while building the first CUE path.
// SIDECARD is the original side-by-side composition: the same structural image
// is redrawn into a desktop-style video window on the left while the card enters
// on the right. No second decoder, playback clock, duration, z-order language,
// or arbitrary positioning system is introduced.
//
// There are two presentation contexts. Standalone EDIT preview has no outer
// program desktop, so it may self-stage SIDECARD here. TEXT/STRUCT preview and
// BAKE already own the real desktop and structural window, so they suppress the
// client-side SIDECARD and use the public side-card geometry/panel helpers to
// move the real outer window instead. This prevents a window-inside-window.
//
// The standalone desktop/video-window shell is public because DOSSIER authoring
// preview needs the exact same fake environment. That shell is still only an
// EDIT convenience; authoritative TEXT/STRUCT composition moves the real outer
// window instead.
//
// SIDECARD geometry and its movement curve live in sidecard_geometry.dart.
// This painter consumes that evaluated geometry; it does not own a second copy
// of the shell animation policy.
//
// Direct EDIT cues fill that EDIT's target. Cues authored directly in a MOSAIC
// pane are clipped to that pane and, for standalone SIDECARD, sample only that
// pane's corresponding structural pixels. The presentation contributes no audio.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'card_overlay_state.dart';
import 'edit_model.dart';
import 'presentation_panel_content.dart';
import 'presentation_requests.dart';
import 'sidecard_geometry.dart';

export 'card_overlay_state.dart';
export 'sidecard_geometry.dart';

/// Workspace-relative image path used by CARD and SIDECARD.
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

/// Paints CARD-family presentations over a complete structural surface.
///
/// [structuralImage] is optional for ordinary CARD but required for standalone
/// SIDECARD's moving video window. Program STRUCT suppresses SIDECARD here and
/// stages it around the real outer structural window instead.
void paintStructuralCardOverlays({
  required Canvas canvas,
  required Size size,
  required Iterable<StructuralCardOverlayPlacement> placements,
  required CardOverlayImageCache images,
  required String fontFamily,
  ui.Image? structuralImage,
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

    Rect? sourceCrop;
    if (structuralImage != null) {
      sourceCrop = Rect.fromLTRB(
        n.left * structuralImage.width,
        n.top * structuralImage.height,
        n.right * structuralImage.width,
        n.bottom * structuralImage.height,
      );
    }

    canvas.save();
    canvas.clipRect(target);
    canvas.translate(target.left, target.top);

    if (placement.isSideCard) {
      _paintSideCardComposition(
        canvas: canvas,
        engineW: target.width,
        engineH: target.height,
        slide: placement.slide,
        card: placement.card,
        cardImage: images.imageFor(placement.card),
        structuralImage: structuralImage,
        structuralSourceRect: sourceCrop,
        fontFamily: fontFamily,
      );
    } else {
      _paintCardPanel(
        canvas,
        target.width,
        target.height,
        placement.slide,
        placement.card,
        images.imageFor(placement.card),
        fontFamily,
      );
    }
    canvas.restore();
  }
}

/// Paints only the right-hand SIDECARD panel into a program render frame.
///
/// The caller owns desktop and structural video window pixels. This helper owns
/// only the existing CARD visual, so Preview and BAKE can stage the real outer
/// window without duplicating card geometry or typography.
void paintStructuralSideCardPanel({
  required Canvas canvas,
  required Size size,
  required StructuralCardOverlayPlacement placement,
  required CardOverlayImageCache images,
  required String fontFamily,
}) {
  if (!placement.isSideCard ||
      placement.slide <= 0.0 ||
      size.width <= 0.0 ||
      size.height <= 0.0) {
    return;
  }
  _paintCardAtSeatedRect(
    canvas: canvas,
    engineW: size.width,
    engineH: size.height,
    seatedRect: sideCardSeatedPanelRect(size),
    slide: placement.slide,
    card: placement.card,
    image: images.imageFor(placement.card),
    fontFamily: fontFamily,
  );
}

/// Widget wrapper for [paintStructuralSideCardPanel].
///
/// Used by StructuralSequencePreview because that widget owns the actual
/// desktop/window shell. Image loading can repaint the card but never changes
/// cue timing or structural geometry.
class StructuralSideCardPanelOverlay extends StatefulWidget {
  const StructuralSideCardPanelOverlay({
    super.key,
    required this.placement,
    required this.resolveSource,
    this.fontFamily = 'monospace',
  });

  final StructuralCardOverlayPlacement placement;
  final String Function(String source) resolveSource;
  final String fontFamily;

  @override
  State<StructuralSideCardPanelOverlay> createState() =>
      _StructuralSideCardPanelOverlayState();
}

class _StructuralSideCardPanelOverlayState
    extends State<StructuralSideCardPanelOverlay> {
  late CardOverlayImageCache _images;

  @override
  void initState() {
    super.initState();
    _images = CardOverlayImageCache(widget.resolveSource);
    _ensure();
  }

  @override
  void didUpdateWidget(covariant StructuralSideCardPanelOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resolveSource != widget.resolveSource) {
      _images.dispose();
      _images = CardOverlayImageCache(widget.resolveSource);
    }
    _ensure();
  }

  void _ensure() {
    _images.ensure(<StructuralCardOverlayPlacement>[widget.placement]).then(
      (bool changed) {
        if (changed && mounted) setState(() {});
      },
    );
  }

  @override
  void dispose() {
    _images.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _StructuralSideCardPanelPainter(
          placement: widget.placement,
          images: _images,
          fontFamily: widget.fontFamily,
        ),
      ),
    );
  }
}

class _StructuralSideCardPanelPainter extends CustomPainter {
  const _StructuralSideCardPanelPainter({
    required this.placement,
    required this.images,
    required this.fontFamily,
  });

  final StructuralCardOverlayPlacement placement;
  final CardOverlayImageCache images;
  final String fontFamily;

  @override
  void paint(Canvas canvas, Size size) {
    paintStructuralSideCardPanel(
      canvas: canvas,
      size: size,
      placement: placement,
      images: images,
      fontFamily: fontFamily,
    );
  }

  @override
  bool shouldRepaint(covariant _StructuralSideCardPanelPainter oldDelegate) =>
      oldDelegate.placement != placement ||
      !identical(oldDelegate.images, images) ||
      oldDelegate.fontFamily != fontFamily;
}

/// Live overlay widget used by EditVideoPreview.
///
/// It contains no clock. [projectFrame] is supplied by the structural preview
/// transport, and every build re-evaluates presentation state from that exact
/// frame. [renderSideCards] is true for standalone EDIT authoring preview and
/// false when an outer program STRUCT shell owns SIDECARD geometry.
class StructuralCardCueOverlay extends StatefulWidget {
  const StructuralCardCueOverlay({
    super.key,
    required this.source,
    required this.sourceRef,
    required this.projectFrame,
    required this.resolveSource,
    this.structuralImage,
    this.fontFamily = 'monospace',
    this.renderSideCards = true,
  });

  final String source;
  final String sourceRef;
  final int projectFrame;
  final String Function(String source) resolveSource;
  final ValueListenable<ui.Image?>? structuralImage;
  final String fontFamily;
  final bool renderSideCards;

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
      if (root == null ||
          root.id.isEmpty ||
          !model.containsStructuralSource(root)) {
        _model = null;
        _root = null;
        return const <StructuralCardOverlayPlacement>[];
      }
      _model = model;
      _root = root;
      _parsedSource = widget.source;
      _parsedSourceRef = widget.sourceRef;
    }

    final List<StructuralCardOverlayPlacement> placements =
        structuralCardOverlayPlacements(
      _model!,
      _root!,
      widget.projectFrame,
    );
    if (widget.renderSideCards) return placements;
    return List<StructuralCardOverlayPlacement>.unmodifiable(
      placements.where(
        (StructuralCardOverlayPlacement placement) => !placement.isSideCard,
      ),
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

    Widget painted(ui.Image? structuralImage) {
      return IgnorePointer(
        child: CustomPaint(
          painter: _StructuralCardOverlayPainter(
            placements: placements,
            images: _images,
            structuralImage: structuralImage,
            fontFamily: widget.fontFamily,
          ),
        ),
      );
    }

    final ValueListenable<ui.Image?>? structural = widget.structuralImage;
    if (structural == null) return painted(null);

    return ValueListenableBuilder<ui.Image?>(
      valueListenable: structural,
      builder: (BuildContext context, ui.Image? image, Widget? child) {
        return painted(image);
      },
    );
  }
}

class _StructuralCardOverlayPainter extends CustomPainter {
  const _StructuralCardOverlayPainter({
    required this.placements,
    required this.images,
    required this.structuralImage,
    required this.fontFamily,
  });

  final List<StructuralCardOverlayPlacement> placements;
  final CardOverlayImageCache images;
  final ui.Image? structuralImage;
  final String fontFamily;

  @override
  void paint(Canvas canvas, Size size) {
    // EditVideoPreview contains its decoded 16:9 structural image inside the
    // widget rather than stretching it. Paint into that same fitted frame.
    final Rect frame = structuralOverlayFit16x9(size);
    if (frame.width <= 0.0 || frame.height <= 0.0) return;

    canvas.save();
    canvas.translate(frame.left, frame.top);
    paintStructuralCardOverlays(
      canvas: canvas,
      size: frame.size,
      placements: placements,
      images: images,
      structuralImage: structuralImage,
      fontFamily: fontFamily,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _StructuralCardOverlayPainter oldDelegate) =>
      oldDelegate.placements != placements ||
      !identical(oldDelegate.images, images) ||
      !identical(oldDelegate.structuralImage, structuralImage) ||
      oldDelegate.fontFamily != fontFamily;
}

/// Fits the authored 16:9 structural frame inside an arbitrary preview widget.
/// CARD, SIDECARD, and DOSSIER standalone authoring overlays use this exact
/// rect so their fake desktop composition never drifts from decoded pixels.
Rect structuralOverlayFit16x9(Size size) {
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

void _paintSideCardComposition({
  required Canvas canvas,
  required double engineW,
  required double engineH,
  required double slide,
  required CardRequest card,
  required ui.Image? cardImage,
  required ui.Image? structuralImage,
  required Rect? structuralSourceRect,
  required String fontFamily,
}) {
  if (slide <= 0.0 || engineW <= 0.0 || engineH <= 0.0) return;

  final Size size = Size(engineW, engineH);
  final double raw = slide.clamp(0.0, 1.0).toDouble();
  paintStandaloneSidePresentationShell(
    canvas: canvas,
    size: size,
    slide: raw,
    structuralImage: structuralImage,
    structuralSourceRect: structuralSourceRect,
    fontFamily: fontFamily,
  );

  _paintCardAtSeatedRect(
    canvas: canvas,
    engineW: engineW,
    engineH: engineH,
    seatedRect: sideCardSeatedPanelRect(size),
    slide: raw,
    card: card,
    image: cardImage,
    fontFamily: fontFamily,
  );
}

/// Paints the fake desktop plus moving structural video window used only by
/// standalone EDIT authoring preview.
///
/// [slide] is the same explicit shell displacement consumed by the real STRUCT
/// path. SIDECARD and DOSSIER both call this helper, which keeps the convenience
/// preview visually tied to sidecard_geometry.dart instead of copying shell
/// interpolation and chrome in two presentation painters.
SideCardShellFrame paintStandaloneSidePresentationShell({
  required Canvas canvas,
  required Size size,
  required double slide,
  required ui.Image? structuralImage,
  Rect? structuralSourceRect,
  required String fontFamily,
}) {
  final double engineW = size.width;
  final double engineH = size.height;
  final Rect full = Rect.fromLTWH(0, 0, engineW, engineH);
  final double raw = slide.clamp(0.0, 1.0).toDouble();
  final SideCardShellFrame shell = sideCardShellFrameAt(
    size: size,
    preCueRect: full,
    slide: raw,
  );
  if (engineW <= 0.0 || engineH <= 0.0 || raw <= 0.0) return shell;

  final double eased = shell.motionProgress;
  final Rect videoWindow = shell.videoWindowRect;
  final double s = math.min(engineW / 1920.0, engineH / 1080.0);
  final double titleH = math.min(38.0 * s * eased, videoWindow.height);
  final double radius = 6.0 * s * eased;

  canvas.drawRect(
    full,
    Paint()..color = const Color(0xFF1B1D20),
  );
  final Rect taskbar = Rect.fromLTWH(
    0,
    engineH - 42.0 * s,
    engineW,
    42.0 * s,
  );
  canvas.drawRect(
    taskbar,
    Paint()..color = const Color(0xFF111214),
  );
  canvas.drawLine(
    taskbar.topLeft,
    taskbar.topRight,
    Paint()
      ..strokeWidth = math.max(0.5, s)
      ..color = const Color(0xFF303236),
  );
  _drawTaskbarMark(canvas, taskbar, s);

  final RRect window = RRect.fromRectAndRadius(
    videoWindow,
    Radius.circular(radius),
  );
  if (eased > 0.02) {
    canvas.drawRRect(
      window.shift(Offset(0, 12.0 * s * eased)),
      Paint()
        ..color = const Color(0x7A000000)
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          24.0 * s * eased,
        ),
    );
  }

  canvas.drawRRect(window, Paint()..color = const Color(0xFF111111));
  canvas.drawRRect(
    window,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.5, s)
      ..color = const Color(0xFF474747),
  );

  final Rect header = Rect.fromLTWH(
    videoWindow.left,
    videoWindow.top,
    videoWindow.width,
    titleH,
  );
  final Rect client = Rect.fromLTRB(
    videoWindow.left,
    header.bottom,
    videoWindow.right,
    videoWindow.bottom,
  );

  canvas.save();
  canvas.clipRRect(window);
  canvas.drawRect(client, Paint()..color = Colors.black);
  if (structuralImage != null && client.width > 0.0 && client.height > 0.0) {
    final Rect source = structuralSourceRect ??
        Rect.fromLTWH(
          0,
          0,
          structuralImage.width.toDouble(),
          structuralImage.height.toDouble(),
        );
    _drawImageContainFromSource(canvas, structuralImage, source, client);
  }

  if (header.height > 0.0) {
    canvas.drawRect(header, Paint()..color = const Color(0xFF343231));
    canvas.drawLine(
      header.bottomLeft,
      header.bottomRight,
      Paint()
        ..strokeWidth = math.max(0.5, s)
        ..color = const Color(0xFF4B4846),
    );
    _drawVideoWindowChrome(canvas, header, s, eased, fontFamily);
  }
  canvas.restore();
  return shell;
}

void _drawTaskbarMark(Canvas canvas, Rect taskbar, double s) {
  final double box = 7.0 * s;
  final double gap = 2.0 * s;
  final double total = box * 2.0 + gap;
  final double left = 18.0 * s;
  final double top = taskbar.center.dy - total / 2.0;
  final Paint paint = Paint()..color = const Color(0xFF8A8D92);
  canvas.drawRect(Rect.fromLTWH(left, top, box, box), paint);
  canvas.drawRect(Rect.fromLTWH(left + box + gap, top, box, box), paint);
  canvas.drawRect(Rect.fromLTWH(left, top + box + gap, box, box), paint);
  canvas.drawRect(
    Rect.fromLTWH(left + box + gap, top + box + gap, box, box),
    paint,
  );
}

void _drawVideoWindowChrome(
  Canvas canvas,
  Rect header,
  double s,
  double openness,
  String fontFamily,
) {
  final TextPainter title = TextPainter(
    text: TextSpan(
      text: 'Video',
      style: TextStyle(
        fontFamily: fontFamily,
        fontSize: 12.0 * s,
        color: const Color(0xFFC8C5C2).withValues(alpha: openness),
      ),
    ),
    maxLines: 1,
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: math.max(0.0, header.width * 0.55));
  title.paint(
    canvas,
    Offset(
      header.left + 14.0 * s,
      header.top + (header.height - title.height) / 2.0,
    ),
  );

  final double controlW = 38.0 * s;
  final double right = header.right;
  final Paint line = Paint()
    ..color = const Color(0xFFB4B0AC).withValues(alpha: openness)
    ..strokeWidth = math.max(0.75, s);

  final double cy = header.center.dy;
  final double xClose = right - controlW / 2.0;
  final double xMax = right - controlW * 1.5;
  final double xMin = right - controlW * 2.5;
  canvas.drawLine(
    Offset(xMin - 4.0 * s, cy + 3.0 * s),
    Offset(xMin + 4.0 * s, cy + 3.0 * s),
    line,
  );
  canvas.drawRect(
    Rect.fromCenter(
      center: Offset(xMax, cy),
      width: 8.0 * s,
      height: 7.0 * s,
    ),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.75, s)
      ..color = line.color,
  );
  canvas.drawLine(
    Offset(xClose - 4.0 * s, cy - 4.0 * s),
    Offset(xClose + 4.0 * s, cy + 4.0 * s),
    line,
  );
  canvas.drawLine(
    Offset(xClose + 4.0 * s, cy - 4.0 * s),
    Offset(xClose - 4.0 * s, cy + 4.0 * s),
    line,
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

  final double cardW = engineW * cardWidthFrac;
  final double top = engineH * cardTopFrac;
  final double bottom = engineH - engineH * cardBottomFrac;
  final double rightGap = engineW * cardRightFrac;
  final Rect seated = Rect.fromLTRB(
    engineW - rightGap - cardW,
    top,
    engineW - rightGap,
    bottom,
  );

  _paintCardAtSeatedRect(
    canvas: canvas,
    engineW: engineW,
    engineH: engineH,
    seatedRect: seated,
    slide: slide,
    card: card,
    image: image,
    fontFamily: fontFamily,
  );
}

void _paintCardAtSeatedRect({
  required Canvas canvas,
  required double engineW,
  required double engineH,
  required Rect seatedRect,
  required double slide,
  required CardRequest card,
  required ui.Image? image,
  required String fontFamily,
}) {
  if (slide <= 0.0 || seatedRect.width <= 0.0 || seatedRect.height <= 0.0) {
    return;
  }

  const double cardRadius = 16.0;
  const double cardPadFrac = 0.055;

  final PresentationPanelContent content = parsePresentationPanelContent(
    heading: card.heading,
    body: card.body,
  );
  final bool rich = content.preset != PresentationPanelPreset.simple;
  final double cardImageFrac = rich ? 0.36 : 0.42;

  final double s = math.min(engineW / 1920.0, engineH / 1080.0);
  final double rawProgress = slide.clamp(0.0, 1.0).toDouble();
  final double e = Curves.easeOutCubic.transform(rawProgress);
  final double left = engineW + (seatedRect.left - engineW) * e;
  final Rect cardRect = Rect.fromLTWH(
    left,
    seatedRect.top,
    seatedRect.width,
    seatedRect.height,
  );
  final RRect rrect = RRect.fromRectAndRadius(
    cardRect,
    Radius.circular(cardRadius * s),
  );

  canvas.save();

  final double pivotX = left + cardRect.width / 2.0;
  final double pivotY = cardRect.center.dy;
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
      Rect.fromLTWH(cardRect.left, cardRect.top, cardRect.width, imageH),
    );
  }

  final bool darkPanel = panelColor.computeLuminance() < 0.35;
  final Color headColor =
      darkPanel ? const Color(0xFFF2F0EC) : const Color(0xFF14120F);
  final Color bodyColor =
      darkPanel ? const Color(0xDDE8E5E0) : const Color(0xDD26221E);
  final Color ruleColor = headColor.withValues(alpha: 0.55);
  final double pad = cardRect.width * cardPadFrac;

  if (rich) {
    _paintRichCardContent(
      canvas: canvas,
      cardRect: cardRect,
      imageBottom: imageBottom,
      content: content,
      pad: pad,
      scale: s,
      headColor: headColor,
      bodyColor: bodyColor,
      ruleColor: ruleColor,
      fontFamily: fontFamily,
    );
  } else {
    _paintSimpleCardContent(
      canvas: canvas,
      cardRect: cardRect,
      imageBottom: imageBottom,
      content: content,
      pad: pad,
      scale: s,
      headColor: headColor,
      bodyColor: bodyColor,
      ruleColor: ruleColor,
      fontFamily: fontFamily,
    );
  }

  canvas.restore();
  canvas.restore();
}

void _paintSimpleCardContent({
  required Canvas canvas,
  required Rect cardRect,
  required double imageBottom,
  required PresentationPanelContent content,
  required double pad,
  required double scale,
  required Color headColor,
  required Color bodyColor,
  required Color ruleColor,
  required String fontFamily,
}) {
  const double cardHeadingSize = 34.0;
  const double cardBodySize = 20.0;

  final double textW = cardRect.width - pad * 2.0;
  double cursorY = imageBottom + pad * 1.1;

  if (content.heading.isNotEmpty) {
    final TextPainter heading = TextPainter(
      text: TextSpan(
        text: content.heading,
        style: TextStyle(
          fontFamily: fontFamily,
          fontFamilyFallback: const [
            'Courier',
            'Consolas',
            'Courier New',
            'monospace',
          ],
          fontSize: cardHeadingSize * scale,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.5 * scale,
          color: headColor,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    heading.layout(maxWidth: textW);
    heading.paint(canvas, Offset(cardRect.left + pad, cursorY));
    cursorY += heading.height + pad * 0.45;
    canvas.drawRect(
      Rect.fromLTWH(cardRect.left + pad, cursorY, textW * 0.42, 3 * scale),
      Paint()..color = ruleColor,
    );
    cursorY += pad * 0.65;
  }

  if (content.body.isNotEmpty) {
    final TextPainter body = TextPainter(
      text: TextSpan(
        text: content.body,
        style: TextStyle(
          fontFamily: fontFamily,
          fontFamilyFallback: const [
            'Courier',
            'Consolas',
            'Courier New',
            'monospace',
          ],
          fontSize: cardBodySize * scale,
          fontWeight: FontWeight.bold,
          height: 1.55,
          color: bodyColor,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    body.layout(maxWidth: textW);
    canvas.save();
    canvas.clipRect(
      Rect.fromLTRB(
        cardRect.left,
        imageBottom,
        cardRect.right,
        cardRect.bottom,
      ),
    );
    body.paint(canvas, Offset(cardRect.left + pad, cursorY));
    canvas.restore();
  }
}

void _paintRichCardContent({
  required Canvas canvas,
  required Rect cardRect,
  required double imageBottom,
  required PresentationPanelContent content,
  required double pad,
  required double scale,
  required Color headColor,
  required Color bodyColor,
  required Color ruleColor,
  required String fontFamily,
}) {
  final double left = cardRect.left + pad;
  final double right = cardRect.right - pad;
  final double textW = math.max(0.0, right - left);
  double cursorY = imageBottom + pad * 0.72;

  final String kicker = content.preset == PresentationPanelPreset.dossier
      ? 'DOSSIER'
      : 'PROFILE';
  final TextPainter kickerPainter = TextPainter(
    text: TextSpan(
      text: kicker,
      style: TextStyle(
        fontFamily: fontFamily,
        fontFamilyFallback: const [
          'Courier',
          'Consolas',
          'Courier New',
          'monospace',
        ],
        fontSize: 11.0 * scale,
        fontWeight: FontWeight.bold,
        letterSpacing: 2.6 * scale,
        color: ruleColor,
      ),
    ),
    maxLines: 1,
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: textW);
  kickerPainter.paint(canvas, Offset(left, cursorY));
  cursorY += kickerPainter.height + pad * 0.32;

  if (content.heading.isNotEmpty) {
    final TextPainter heading = TextPainter(
      text: TextSpan(
        text: content.heading,
        style: TextStyle(
          fontFamily: fontFamily,
          fontFamilyFallback: const [
            'Courier',
            'Consolas',
            'Courier New',
            'monospace',
          ],
          fontSize: 30.0 * scale,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8 * scale,
          height: 1.02,
          color: headColor,
        ),
      ),
      maxLines: 2,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: textW);
    heading.paint(canvas, Offset(left, cursorY));
    cursorY += heading.height + pad * 0.24;
  }

  if (content.subtitle.isNotEmpty) {
    final TextPainter subtitle = TextPainter(
      text: TextSpan(
        text: content.subtitle,
        style: TextStyle(
          fontFamily: fontFamily,
          fontFamilyFallback: const [
            'Courier',
            'Consolas',
            'Courier New',
            'monospace',
          ],
          fontSize: 15.0 * scale,
          fontWeight: FontWeight.w600,
          height: 1.18,
          color: bodyColor.withValues(alpha: 0.88),
        ),
      ),
      maxLines: 2,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: textW);
    subtitle.paint(canvas, Offset(left, cursorY));
    cursorY += subtitle.height + pad * 0.34;
  }

  canvas.drawRect(
    Rect.fromLTWH(left, cursorY, textW, math.max(1.0, 1.5 * scale)),
    Paint()..color = ruleColor.withValues(alpha: 0.72),
  );
  cursorY += pad * 0.42;

  final double rowH = math.max(27.0 * scale, cardRect.height * 0.038);
  final double labelW = textW * 0.34;
  final int maxRows = math.min(4, content.metadata.length);
  for (int i = 0; i < maxRows; i++) {
    final PresentationPanelMetadata item = content.metadata[i];
    if (cursorY + rowH > cardRect.bottom - pad * 2.2) break;

    final TextPainter label = TextPainter(
      text: TextSpan(
        text: item.label.toUpperCase(),
        style: TextStyle(
          fontFamily: fontFamily,
          fontFamilyFallback: const [
            'Courier',
            'Consolas',
            'Courier New',
            'monospace',
          ],
          fontSize: 10.0 * scale,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.25 * scale,
          color: ruleColor.withValues(alpha: 0.9),
        ),
      ),
      maxLines: 1,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(0.0, labelW - pad * 0.2));

    final TextPainter value = TextPainter(
      text: TextSpan(
        text: item.value,
        style: TextStyle(
          fontFamily: fontFamily,
          fontFamilyFallback: const [
            'Courier',
            'Consolas',
            'Courier New',
            'monospace',
          ],
          fontSize: 12.5 * scale,
          fontWeight: FontWeight.w600,
          color: headColor.withValues(alpha: 0.94),
        ),
      ),
      maxLines: 1,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(0.0, textW - labelW));

    final double baselineY = cursorY + (rowH - value.height) / 2.0;
    label.paint(
      canvas,
      Offset(left, cursorY + (rowH - label.height) / 2.0),
    );
    value.paint(canvas, Offset(left + labelW, baselineY));
    cursorY += rowH;
    canvas.drawRect(
      Rect.fromLTWH(
        left,
        cursorY,
        textW,
        math.max(0.5, scale * 0.65),
      ),
      Paint()..color = ruleColor.withValues(alpha: 0.26),
    );
  }

  if (content.metadata.isNotEmpty) {
    cursorY += pad * 0.38;
  }

  if (content.body.isNotEmpty && cursorY < cardRect.bottom - pad) {
    final TextPainter body = TextPainter(
      text: TextSpan(
        text: content.body,
        style: TextStyle(
          fontFamily: fontFamily,
          fontFamilyFallback: const [
            'Courier',
            'Consolas',
            'Courier New',
            'monospace',
          ],
          fontSize: 16.0 * scale,
          fontWeight: FontWeight.w500,
          height: 1.42,
          color: bodyColor,
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

void _drawImageContainFromSource(
  Canvas canvas,
  ui.Image image,
  Rect source,
  Rect destination,
) {
  if (source.width <= 0.0 ||
      source.height <= 0.0 ||
      destination.width <= 0.0 ||
      destination.height <= 0.0) {
    return;
  }
  final double scale = math.min(
    destination.width / source.width,
    destination.height / source.height,
  );
  final double drawW = source.width * scale;
  final double drawH = source.height * scale;
  final Rect fitted = Rect.fromLTWH(
    destination.left + (destination.width - drawW) / 2.0,
    destination.top + (destination.height - drawH) / 2.0,
    drawW,
    drawH,
  );
  canvas.drawImageRect(
    image,
    source,
    fitted,
    Paint()..filterQuality = FilterQuality.low,
  );
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