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
// Standalone EDIT also needs a stable fake window when an EDIT owns MAXIMIZE
// cues. Without that baseline, the raw client itself already fills the preview:
// MAXIMIZE can appear to go fullscreen but has nowhere visible to return. The
// fake shell therefore remains seated before and after MAXIMIZE and consumes the
// same shared maximize geometry as TEXT/STRUCT. It is still authoring-only; the
// real program path continues to move the real STRUCT window.
//
// The standalone desktop/video-window shell is public because DOSSIER authoring
// preview needs the exact same fake environment. That shell is still only an
// EDIT convenience; authoritative TEXT/STRUCT composition moves the real outer
// window instead.
//
// SIDECARD geometry and its movement curve live in sidecard_geometry.dart.
// MAXIMIZE movement lives in structural_shell_geometry.dart. This painter
// consumes those evaluated geometries; it does not own a second timing model.
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
import 'edit_cue.dart';
import 'edit_model.dart';
import 'maximize_shell_state.dart';
import 'presentation_panel_content.dart';
import 'presentation_panel_painter.dart';
import 'presentation_requests.dart';
import 'sidecard_geometry.dart';
import 'structural_shell_geometry.dart';

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

/// True when a direct EDIT source contains at least one clip-local MAXIMIZE.
///
/// Standalone EDIT authoring uses this to keep a stable fake desktop/window
/// context across the whole EDIT. Program STRUCT callers never need this helper
/// because they already own the real outer shell. MOSAIC panes deliberately do
/// not promote a pane-local cue into outer shell geometry.
bool structuralSourceHasMaximizeCues(
  EditDocumentModel model,
  StructuralSourceRef root,
) {
  if (root.kind != StructuralSourceKind.edit || root.id.isEmpty) return false;
  try {
    final EditSequence edit = model.edit(root.id);
    for (final EditTrack track in edit.tracks) {
      for (final EditClip clip in track.clips) {
        if (parseClipMaximizeCues(clip).isNotEmpty) return true;
      }
    }
  } catch (_) {
    return false;
  }
  return false;
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
Rect? paintStructuralSideCardPanel({
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
    return null;
  }
  return _paintCardAtSeatedRect(
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
/// false when an outer program STRUCT shell owns SIDECARD/MAXIMIZE geometry.
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

  bool _ensureParsed() {
    if (_model != null &&
        _root != null &&
        _parsedSource == widget.source &&
        _parsedSourceRef == widget.sourceRef) {
      return true;
    }

    final EditDocumentModel model = EditDocumentModel.parse(widget.source);
    final StructuralSourceRef? root =
        StructuralSourceRef.tryParse(widget.sourceRef);
    if (root == null ||
        root.id.isEmpty ||
        !model.containsStructuralSource(root)) {
      _model = null;
      _root = null;
      _parsedSource = widget.source;
      _parsedSourceRef = widget.sourceRef;
      return false;
    }

    _model = model;
    _root = root;
    _parsedSource = widget.source;
    _parsedSourceRef = widget.sourceRef;
    return true;
  }

  List<StructuralCardOverlayPlacement> _placements() {
    if (!_ensureParsed()) return const <StructuralCardOverlayPlacement>[];

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

  bool _hasStandaloneMaximizeShell() {
    if (!widget.renderSideCards || !_ensureParsed()) return false;
    return structuralSourceHasMaximizeCues(_model!, _root!);
  }

  StructuralMaximizePlacement? _activeMaximize() {
    if (!_ensureParsed()) return null;
    try {
      return structuralMaximizePlacement(
        _model!,
        _root!,
        widget.projectFrame,
      );
    } catch (_) {
      return null;
    }
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
    final bool shellContext = _hasStandaloneMaximizeShell();
    final bool cardOwnsSurface = placements.any(
      (StructuralCardOverlayPlacement placement) => !placement.isSideCard,
    );
    final bool sideCardOwnsShell = placements.any(
      (StructuralCardOverlayPlacement placement) => placement.isSideCard,
    );
    final bool paintStandaloneMaximizeShell =
        shellContext && !cardOwnsSurface && !sideCardOwnsShell;
    final StructuralMaximizePlacement? maximize =
        paintStandaloneMaximizeShell ? _activeMaximize() : null;

    if (placements.isEmpty && !paintStandaloneMaximizeShell) {
      return const SizedBox.expand();
    }
    _ensureImages(placements);

    Widget painted(ui.Image? structuralImage) {
      return IgnorePointer(
        child: CustomPaint(
          key: paintStandaloneMaximizeShell
              ? const ValueKey<String>('edit-standalone-maximize-shell')
              : null,
          painter: _StructuralCardOverlayPainter(
            placements: placements,
            images: _images,
            structuralImage: structuralImage,
            fontFamily: widget.fontFamily,
            standaloneMaximizeAmount:
                paintStandaloneMaximizeShell ? (maximize?.amount ?? 0.0) : null,
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
    required this.standaloneMaximizeAmount,
  });

  final List<StructuralCardOverlayPlacement> placements;
  final CardOverlayImageCache images;
  final ui.Image? structuralImage;
  final String fontFamily;
  final double? standaloneMaximizeAmount;

  @override
  void paint(Canvas canvas, Size size) {
    // EditVideoPreview contains its decoded 16:9 structural image inside the
    // widget rather than stretching it. Paint into that same fitted frame.
    final Rect frame = structuralOverlayFit16x9(size);
    if (frame.width <= 0.0 || frame.height <= 0.0) return;

    canvas.save();
    canvas.translate(frame.left, frame.top);

    final double? maximizeAmount = standaloneMaximizeAmount;
    if (maximizeAmount != null) {
      paintStandaloneMaximizeShell(
        canvas: canvas,
        size: frame.size,
        amount: maximizeAmount,
        structuralImage: structuralImage,
        fontFamily: fontFamily,
      );
    }

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
      oldDelegate.fontFamily != fontFamily ||
      oldDelegate.standaloneMaximizeAmount != standaloneMaximizeAmount;
}

/// Fits the authored 16:9 structural frame inside an arbitrary preview widget.
/// CARD, SIDECARD, DOSSIER, and MAXIMIZE standalone authoring overlays use this
/// exact rect so their fake desktop composition never drifts from decoded pixels.
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

/// Seated fake structural window used only by standalone EDIT MAXIMIZE preview.
///
/// This intentionally follows the same broad 86%/78% window proportions as the
/// real STRUCT shell, scaled to the compact authoring preview chrome.
Rect standaloneMaximizeBaseWindowRect(Size size) {
  if (size.width <= 0.0 || size.height <= 0.0) return Rect.zero;
  final double s = math.min(size.width / 1920.0, size.height / 1080.0);
  final double titleH = 38.0 * s;
  final double maxW = size.width * 0.86;
  final double maxH = size.height * 0.78;

  double clientW = maxW;
  double clientH = clientW * 9.0 / 16.0;
  if (clientH + titleH > maxH) {
    clientH = math.max(1.0, maxH - titleH);
    clientW = clientH * 16.0 / 9.0;
  }

  final double windowH = clientH + titleH;
  return Rect.fromLTWH(
    (size.width - clientW) / 2.0,
    (size.height - windowH) / 2.0,
    clientW,
    windowH,
  );
}

/// Shared MAXIMIZE geometry projected into the standalone EDIT fake shell.
StructuralMaximizeGeometryFrame standaloneMaximizeShellFrameAt({
  required Size size,
  required double amount,
}) {
  return structuralMaximizeGeometryFrameAt(
    baseRect: standaloneMaximizeBaseWindowRect(size),
    fullRect: Offset.zero & size,
    amount: amount,
  );
}

/// Paints the stable standalone EDIT window used around MAXIMIZE cues.
///
/// The shell remains seated even when no MAXIMIZE is currently active. That is
/// the important authoring invariant: once an EDIT contains MAXIMIZE, the cue
/// expands from a visible window and returns to that same visible window instead
/// of falling through to the raw full-frame client after its lifetime ends.
void paintStandaloneMaximizeShell({
  required Canvas canvas,
  required Size size,
  required double amount,
  required ui.Image? structuralImage,
  required String fontFamily,
}) {
  if (size.width <= 0.0 || size.height <= 0.0) return;
  final StructuralMaximizeGeometryFrame shell =
      standaloneMaximizeShellFrameAt(size: size, amount: amount);
  _paintStandaloneStructuralWindowShell(
    canvas: canvas,
    size: size,
    videoWindow: shell.structuralRect,
    windowChrome: shell.windowChrome,
    structuralImage: structuralImage,
    fontFamily: fontFamily,
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

  _paintStandaloneStructuralWindowShell(
    canvas: canvas,
    size: size,
    videoWindow: shell.videoWindowRect,
    windowChrome: shell.motionProgress,
    structuralImage: structuralImage,
    structuralSourceRect: structuralSourceRect,
    fontFamily: fontFamily,
  );
  return shell;
}

void _paintStandaloneStructuralWindowShell({
  required Canvas canvas,
  required Size size,
  required Rect videoWindow,
  required double windowChrome,
  required ui.Image? structuralImage,
  Rect? structuralSourceRect,
  required String fontFamily,
}) {
  final double engineW = size.width;
  final double engineH = size.height;
  if (engineW <= 0.0 || engineH <= 0.0 ||
      videoWindow.width <= 0.0 || videoWindow.height <= 0.0) {
    return;
  }

  final Rect full = Rect.fromLTWH(0, 0, engineW, engineH);
  final double chrome = windowChrome.clamp(0.0, 1.0).toDouble();
  final double s = math.min(engineW / 1920.0, engineH / 1080.0);
  final double titleH = math.min(38.0 * s * chrome, videoWindow.height);
  final double radius = 6.0 * s * chrome;

  canvas.drawRect(full, Paint()..color = const Color(0xFF1B1D20));
  final Rect taskbar = Rect.fromLTWH(
    0,
    engineH - 42.0 * s,
    engineW,
    42.0 * s,
  );
  canvas.drawRect(taskbar, Paint()..color = const Color(0xFF111214));
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
  if (chrome > 0.02) {
    canvas.drawRRect(
      window.shift(Offset(0, 12.0 * s * chrome)),
      Paint()
        ..color = const Color(0x7A000000).withValues(alpha: 0.48 * chrome)
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          24.0 * s * chrome,
        ),
    );
  }

  canvas.drawRRect(window, Paint()..color = const Color(0xFF111111));
  if (chrome > 0.001) {
    canvas.drawRRect(
      window,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.5, s)
        ..color = const Color(0xFF474747).withValues(alpha: chrome),
    );
  }

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
    canvas.drawRect(
      header,
      Paint()..color = const Color(0xFF343231).withValues(alpha: chrome),
    );
    canvas.drawLine(
      header.bottomLeft,
      header.bottomRight,
      Paint()
        ..strokeWidth = math.max(0.5, s)
        ..color = const Color(0xFF4B4846).withValues(alpha: chrome),
    );
    _drawVideoWindowChrome(canvas, header, s, chrome, fontFamily);
  }
  canvas.restore();
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

RRect _presentationCardFaceRRect(Rect rect, double scale) {
  const double cardRadius = 16.0;
  return RRect.fromRectAndRadius(
    rect,
    Radius.circular(cardRadius * scale),
  );
}

/// Paints the intrinsic CARD-family face inside [rect].
///
/// Placement, motion, pivot transforms, and the environmental drop shadow are
/// caller-owned. Everything intrinsic to the card surface lives here: rounded
/// clipping, panel treatment, image treatment, typography, and content
/// placement. [scale] is the uniform 1920x1080 reference-composition scale
/// chosen by the caller; this painter deliberately knows nothing about engine
/// dimensions or image caches.
void paintPresentationCardFace(
  Canvas canvas,
  Rect rect,
  double scale,
  CardRequest card,
  ui.Image? image,
  String inheritedFontFamily,
) {
  if (rect.width <= 0.0 || rect.height <= 0.0 || scale <= 0.0) return;

  const double cardPadFrac = 0.055;

  final PresentationPanelContent content = parsePresentationPanelContent(
    heading: card.heading,
    body: card.body,
  );
  final bool rich = content.preset != PresentationPanelPreset.simple;
  final bool editorial =
      content.preset == PresentationPanelPreset.editorial;
  final bool photoRich =
      content.preset == PresentationPanelPreset.documentary ||
      content.preset == PresentationPanelPreset.dossier;
  final double defaultImageFrac = editorial ? 0.38 : (rich ? 0.34 : 0.42);
  final double cardImageFrac = content.imageFraction ?? defaultImageFrac;
  final RRect rrect = _presentationCardFaceRRect(rect, scale);

  final Color panelColor = card.panelColor;
  final bool darkPanel = panelColor.computeLuminance() < 0.35;
  final Color headColor =
      darkPanel ? const Color(0xFFF2F0EC) : const Color(0xFF14120F);
  final Color bodyColor =
      darkPanel ? const Color(0xDDE8E5E0) : const Color(0xDD26221E);
  final Color ruleColor = headColor.withValues(alpha: 0.55);

  if (photoRich) {
    final Color surfaceTop = darkPanel
        ? Color.lerp(panelColor, Colors.white, 0.045)!
        : Color.lerp(panelColor, Colors.white, 0.16)!;
    final Color surfaceBottom = darkPanel
        ? Color.lerp(panelColor, Colors.black, 0.16)!
        : Color.lerp(panelColor, Colors.black, 0.06)!;
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[surfaceTop, surfaceBottom],
        ).createShader(rect),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.8 * scale, 0.6)
        ..color = headColor.withValues(alpha: 0.15),
    );
  } else {
    canvas.drawRRect(rrect, Paint()..color = panelColor);
  }

  canvas.save();
  canvas.clipRRect(rrect);

  double imageBottom = rect.top;
  Rect? imageRect;
  if (image != null) {
    final double imageH = rect.height * cardImageFrac;
    imageBottom = rect.top + imageH;
    imageRect = Rect.fromLTWH(
      rect.left,
      rect.top,
      rect.width,
      imageH,
    );
    _drawImageCover(canvas, image, imageRect);
  }

  if (photoRich && imageRect != null) {
    paintPresentationPanelPhotoTreatment(
      canvas: canvas,
      imageRect: imageRect,
      content: content,
      panelColor: panelColor,
      headColor: headColor,
      inheritedFontFamily: inheritedFontFamily,
      scale: scale,
    );
  }

  final double pad = rect.width * cardPadFrac;

  if (rich) {
    paintPresentationPanelContent(
      canvas: canvas,
      cardRect: rect,
      contentTop: imageBottom,
      content: content,
      pad: pad,
      scale: scale,
      panelColor: panelColor,
      headColor: headColor,
      bodyColor: bodyColor,
      inheritedFontFamily: inheritedFontFamily,
      showKicker: editorial || imageRect == null,
    );
  } else {
    _paintSimpleCardContent(
      canvas: canvas,
      cardRect: rect,
      imageBottom: imageBottom,
      content: content,
      pad: pad,
      scale: scale,
      headColor: headColor,
      bodyColor: bodyColor,
      ruleColor: ruleColor,
      fontFamily: inheritedFontFamily,
    );
  }

  canvas.restore();
}

Rect? _paintCardAtSeatedRect({
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
    return null;
  }

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
  final RRect shadowShape = _presentationCardFaceRRect(cardRect, s);

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
    shadowShape.shift(Offset(-2 * s, 4 * s)),
    Paint()
      ..color = const Color(0x66000000)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 14 * s),
  );

  paintPresentationCardFace(
    canvas,
    cardRect,
    s,
    card,
    image,
    fontFamily,
  );

  canvas.restore();
  return cardRect;
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
  final String selectedFontFamily = presentationPanelFontFamily(
    content,
    fontFamily,
  );

  final double textW = cardRect.width - pad * 2.0;
  double cursorY = imageBottom + pad * 1.1;

  if (content.heading.isNotEmpty) {
    final TextPainter heading = TextPainter(
      text: TextSpan(
        text: content.heading,
        style: TextStyle(
          fontFamily: selectedFontFamily,
          fontFamilyFallback: kPresentationPanelFontFallback,
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
          fontFamily: selectedFontFamily,
          fontFamilyFallback: kPresentationPanelFontFallback,
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
