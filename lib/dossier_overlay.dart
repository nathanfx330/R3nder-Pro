// ./lib/dossier_overlay.dart
//
// Shared structural DOSSIER asset loading and right-hand panel painting.
//
// The authoritative outer video window remains owned by STRUCT and
// sidecard_geometry.dart. TEXT/STRUCT preview and BAKE paint only DOSSIER's
// sibling presentation here: biography card first, then evidence grid/mosaic.
//
// Standalone EDIT authoring has no outer program desktop. For that one context
// this file can stage the same fake desktop/video-window shell used by SIDECARD,
// then paint the exact same DOSSIER panel on top. It is an authoring projection,
// not another decoder, clock, or structural geometry authority.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'card_overlay.dart';
import 'dossier_overlay_state.dart';
import 'edit_cue.dart';
import 'edit_model.dart';
import 'folder_order.dart';
import 'presentation_requests.dart';

export 'dossier_overlay_state.dart';

const int kStructuralDossierImagesPerMosaicPage = 3;

/// Ordered evidence image sources, respecting the same .r3nder_order manifest
/// used by terminal DOSSIER/APP/GALLERY loading.
List<String> structuralDossierImageSources(
  DossierRequest request,
  String Function(String source) resolveSource,
) {
  final String folder = request.folder.trim().replaceAll('\\', '/');
  if (folder.isEmpty) return const <String>[];
  final String workspaceFolder =
      folder.startsWith('images/') ? folder : 'images/$folder';

  try {
    final String dirPath = resolveSource(workspaceFolder);
    final Directory dir = Directory(dirPath);
    if (!dir.existsSync()) return const <String>[];
    final Iterable<String> onDisk = dir
        .listSync()
        .whereType<File>()
        .map((File file) => file.path.split(Platform.pathSeparator).last)
        .where((String name) {
      final String lower = name.toLowerCase();
      return lower.endsWith('.png') ||
          lower.endsWith('.jpg') ||
          lower.endsWith('.jpeg') ||
          lower.endsWith('.webp') ||
          lower.endsWith('.bmp');
    });
    return <String>[
      for (final String name in orderedFolderNames(dirPath, onDisk))
        '$workspaceFolder/$name',
    ];
  } catch (_) {
    return const <String>[];
  }
}

/// Exact center-page count implied by the current evidence folder.
int structuralDossierCenterPageCount(
  DossierRequest request,
  String Function(String source) resolveSource,
) {
  switch (request.centerMode) {
    case DossierCenterMode.sideOnly:
      return 0;
    case DossierCenterMode.grid:
      return 1;
    case DossierCenterMode.mosaic:
      final int count = structuralDossierImageSources(request, resolveSource).length;
      return math.max(
        1,
        (count + kStructuralDossierImagesPerMosaicPage - 1) ~/
            kStructuralDossierImagesPerMosaicPage,
      );
  }
}

/// Pure visual decomposition of one structural DOSSIER frame.
class StructuralDossierPanelFrame {
  const StructuralDossierPanelFrame({
    required this.shellSlide,
    required this.cardSlide,
    required this.evidenceVisibility,
    required this.centerPageIndex,
    required this.pagePan,
  });

  final double shellSlide;
  final double cardSlide;
  final double evidenceVisibility;
  final int centerPageIndex;
  final double pagePan;
}

StructuralDossierPanelFrame structuralDossierPanelFrame(
  StructuralDossierOverlayPlacement placement,
) {
  final frame = placement.presentationFrame;
  double card = 0.0;
  double evidence = 0.0;
  double pan = 0.0;

  switch (frame.stage) {
    case DossierPresentationStage.opening:
      card = frame.progress;
      break;
    case DossierPresentationStage.cardLead:
    case DossierPresentationStage.galleryOpening:
    case DossierPresentationStage.splitShowing:
      card = 1.0;
      break;
    case DossierPresentationStage.centerTransition:
      card = 1.0 - frame.progress;
      evidence = frame.progress;
      break;
    case DossierPresentationStage.centerShowing:
      evidence = 1.0;
      break;
    case DossierPresentationStage.centerPanning:
      evidence = 1.0;
      pan = frame.progress;
      break;
    case DossierPresentationStage.closing:
      final double leaving = 1.0 - frame.progress;
      if (placement.dossier.centerMode == DossierCenterMode.sideOnly) {
        card = leaving;
      } else {
        evidence = leaving;
      }
      break;
  }

  return StructuralDossierPanelFrame(
    shellSlide: structuralDossierShellSlide(placement),
    cardSlide: card.clamp(0.0, 1.0).toDouble(),
    evidenceVisibility: evidence.clamp(0.0, 1.0).toDouble(),
    centerPageIndex: frame.centerPageIndex ?? 0,
    pagePan: pan.clamp(0.0, 1.0).toDouble(),
  );
}

StructuralCardOverlayPlacement _dossierCardPlacement(
  StructuralDossierOverlayPlacement placement,
  double slide,
) {
  final DossierRequest request = placement.dossier;
  return StructuralCardOverlayPlacement(
    card: SideCardRequest(
      image: request.image,
      holdFrames: request.holdSplit,
      panelColor: request.panelColor,
      heading: request.heading,
      body: request.body,
    ),
    slide: slide,
    normalizedRect: const Rect.fromLTWH(0, 0, 1, 1),
  );
}

class DossierOverlayImageCache {
  DossierOverlayImageCache(this.resolveSource)
      : cardImages = CardOverlayImageCache(resolveSource);

  final String Function(String source) resolveSource;
  final CardOverlayImageCache cardImages;
  final Map<String, List<ui.Image>> _folderImages = <String, List<ui.Image>>{};
  final Set<String> _loadingFolders = <String>{};
  final Set<String> _failedFolders = <String>{};
  bool _disposed = false;

  List<ui.Image> evidenceFor(DossierRequest request) =>
      _folderImages[request.folder] ?? const <ui.Image>[];

  Future<bool> ensure(StructuralDossierOverlayPlacement placement) async {
    bool changed = await cardImages.ensure(
      <StructuralCardOverlayPlacement>[
        _dossierCardPlacement(placement, 1.0),
      ],
    );

    final String folder = placement.dossier.folder;
    if (_folderImages.containsKey(folder) ||
        _loadingFolders.contains(folder) ||
        _failedFolders.contains(folder)) {
      return changed;
    }

    _loadingFolders.add(folder);
    try {
      final List<String> sources =
          structuralDossierImageSources(placement.dossier, resolveSource);
      final List<ui.Image> decoded = <ui.Image>[];
      for (final String source in sources) {
        try {
          final Uint8List bytes = await File(resolveSource(source)).readAsBytes();
          final ui.Codec codec = await ui.instantiateImageCodec(bytes);
          try {
            final ui.FrameInfo frame = await codec.getNextFrame();
            if (_disposed) {
              frame.image.dispose();
            } else {
              decoded.add(frame.image);
            }
          } finally {
            codec.dispose();
          }
        } catch (_) {
          // One bad evidence image does not erase the rest of the dossier.
        }
      }
      if (_disposed) {
        for (final ui.Image image in decoded) {
          image.dispose();
        }
      } else {
        _folderImages[folder] = decoded;
        changed = decoded.isNotEmpty || changed;
      }
    } catch (_) {
      if (!_disposed) _failedFolders.add(folder);
    } finally {
      _loadingFolders.remove(folder);
    }
    return changed;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cardImages.dispose();
    for (final List<ui.Image> images in _folderImages.values) {
      for (final ui.Image image in images) {
        image.dispose();
      }
    }
    _folderImages.clear();
    _loadingFolders.clear();
    _failedFolders.clear();
  }
}

void paintStructuralDossierPanel({
  required Canvas canvas,
  required Size size,
  required StructuralDossierOverlayPlacement placement,
  required DossierOverlayImageCache images,
  required String fontFamily,
}) {
  if (size.width <= 0.0 || size.height <= 0.0) return;
  final StructuralDossierPanelFrame visual =
      structuralDossierPanelFrame(placement);

  if (visual.cardSlide > 0.0) {
    paintStructuralSideCardPanel(
      canvas: canvas,
      size: size,
      placement: _dossierCardPlacement(placement, visual.cardSlide),
      images: images.cardImages,
      fontFamily: fontFamily,
    );
  }

  if (visual.evidenceVisibility <= 0.0) return;
  _paintEvidencePanel(
    canvas: canvas,
    size: size,
    placement: placement,
    evidence: images.evidenceFor(placement.dossier),
    visibility: visual.evidenceVisibility,
    pageIndex: visual.centerPageIndex,
    pagePan: visual.pagePan,
    fontFamily: fontFamily,
  );
}

/// Standalone EDIT authoring composition for DOSSIER.
///
/// The real program path never calls this. It moves the actual STRUCT window
/// and calls [paintStructuralDossierPanel] as a sibling. EDIT has no such shell,
/// so it draws the same convenience desktop/video window that SIDECARD uses,
/// then reuses the exact DOSSIER panel painter.
void paintStandaloneStructuralDossierComposition({
  required Canvas canvas,
  required Size size,
  required StructuralDossierOverlayPlacement placement,
  required DossierOverlayImageCache images,
  required ui.Image? structuralImage,
  required String fontFamily,
}) {
  if (size.width <= 0.0 || size.height <= 0.0) return;
  final StructuralDossierPanelFrame visual =
      structuralDossierPanelFrame(placement);
  if (visual.shellSlide <= 0.0) return;

  paintStandaloneSidePresentationShell(
    canvas: canvas,
    size: size,
    slide: visual.shellSlide,
    structuralImage: structuralImage,
    fontFamily: fontFamily,
  );
  paintStructuralDossierPanel(
    canvas: canvas,
    size: size,
    placement: placement,
    images: images,
    fontFamily: fontFamily,
  );
}

void _paintEvidencePanel({
  required Canvas canvas,
  required Size size,
  required StructuralDossierOverlayPlacement placement,
  required List<ui.Image> evidence,
  required double visibility,
  required int pageIndex,
  required double pagePan,
  required String fontFamily,
}) {
  final Rect seated = sideCardSeatedPanelRect(size);
  if (seated.width <= 0.0 || seated.height <= 0.0) return;

  final double t = Curves.easeOutCubic.transform(visibility.clamp(0.0, 1.0));
  final double x = seated.left + seated.width * 0.16 * (1.0 - t);
  final Rect panel = Rect.fromLTWH(x, seated.top, seated.width, seated.height);

  canvas.saveLayer(
    panel.inflate(20),
    Paint()..color = Colors.white.withValues(alpha: t),
  );
  final RRect rr = RRect.fromRectAndRadius(panel, const Radius.circular(10));
  canvas.drawRRect(rr, Paint()..color = const Color(0xFF17191D));
  canvas.drawRRect(
    rr,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = const Color(0xFF555A61),
  );
  canvas.save();
  canvas.clipRRect(rr);

  final double pad = panel.width * 0.055;
  final double titleH = math.max(34.0, panel.height * 0.095);
  final Rect titleRect = Rect.fromLTWH(
    panel.left,
    panel.top,
    panel.width,
    titleH,
  );
  canvas.drawRect(titleRect, Paint()..color = const Color(0xFF23262B));

  final TextPainter title = TextPainter(
    text: TextSpan(
      text: placement.dossier.heading.isEmpty
          ? 'EVIDENCE'
          : 'EVIDENCE  ·  ${placement.dossier.heading}',
      style: TextStyle(
        fontFamily: fontFamily,
        color: const Color(0xFFE3E5E8),
        fontSize: math.max(11.0, titleH * 0.30),
        fontWeight: FontWeight.w600,
        letterSpacing: 0.8,
      ),
    ),
    maxLines: 1,
    ellipsis: '…',
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: math.max(0.0, titleRect.width - pad * 2));
  title.paint(
    canvas,
    Offset(
      titleRect.left + pad,
      titleRect.top + (titleRect.height - title.height) / 2.0,
    ),
  );

  final Rect content = Rect.fromLTRB(
    panel.left + pad,
    titleRect.bottom + pad,
    panel.right - pad,
    panel.bottom - pad,
  );

  if (evidence.isEmpty) {
    final TextPainter empty = TextPainter(
      text: TextSpan(
        text: 'NO EVIDENCE IMAGES',
        style: TextStyle(
          fontFamily: fontFamily,
          color: const Color(0xFF8F949B),
          fontSize: math.max(10.0, content.height * 0.035),
          letterSpacing: 1.1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: content.width);
    empty.paint(
      canvas,
      Offset(
        content.center.dx - empty.width / 2.0,
        content.center.dy - empty.height / 2.0,
      ),
    );
  } else if (placement.dossier.centerMode == DossierCenterMode.mosaic) {
    final int outgoing = pageIndex.clamp(0, math.max(0, placement.centerPageCount - 1));
    if (pagePan > 0.0 && outgoing + 1 < placement.centerPageCount) {
      final double pan = Curves.easeInOutCubic.transform(pagePan);
      _paintMosaicPage(
        canvas,
        content.shift(Offset(-content.width * pan, 0)),
        evidence,
        outgoing,
      );
      _paintMosaicPage(
        canvas,
        content.shift(Offset(content.width * (1.0 - pan), 0)),
        evidence,
        outgoing + 1,
      );
    } else {
      _paintMosaicPage(canvas, content, evidence, outgoing);
    }
  } else {
    _paintGrid(canvas, content, evidence);
  }

  canvas.restore();
  canvas.restore();
}

void _paintGrid(Canvas canvas, Rect rect, List<ui.Image> images) {
  final int count = math.min(images.length, 9);
  if (count <= 0) return;
  final int cols = count <= 2 ? count : (count <= 4 ? 2 : 3);
  final int rows = (count + cols - 1) ~/ cols;
  final double gap = math.min(rect.width, rect.height) * 0.025;
  final double cellW = (rect.width - gap * (cols - 1)) / cols;
  final double cellH = (rect.height - gap * (rows - 1)) / rows;

  for (int i = 0; i < count; i++) {
    final int col = i % cols;
    final int row = i ~/ cols;
    final Rect cell = Rect.fromLTWH(
      rect.left + col * (cellW + gap),
      rect.top + row * (cellH + gap),
      cellW,
      cellH,
    );
    _paintImageTile(canvas, images[i], cell);
  }
}

void _paintMosaicPage(
  Canvas canvas,
  Rect rect,
  List<ui.Image> images,
  int pageIndex,
) {
  final int start = pageIndex * kStructuralDossierImagesPerMosaicPage;
  if (start >= images.length) return;
  final int count = math.min(
    kStructuralDossierImagesPerMosaicPage,
    images.length - start,
  );
  final List<Rect> cells = _mosaicCells(count, pageIndex);
  final double gap = math.min(rect.width, rect.height) * 0.018;
  for (int i = 0; i < count; i++) {
    final Rect n = cells[i];
    final Rect cell = Rect.fromLTRB(
      rect.left + n.left * rect.width,
      rect.top + n.top * rect.height,
      rect.left + n.right * rect.width,
      rect.top + n.bottom * rect.height,
    ).deflate(gap / 2.0);
    _paintImageTile(canvas, images[start + i], cell);
  }
}

List<Rect> _mosaicCells(int count, int pageIndex) {
  const double hero = 0.56;
  List<Rect> rects;
  if (count <= 1) {
    rects = const <Rect>[Rect.fromLTRB(0, 0, 1, 1)];
  } else if (count == 2) {
    rects = const <Rect>[
      Rect.fromLTRB(0, 0, hero, 1),
      Rect.fromLTRB(hero, 0, 1, 1),
    ];
  } else {
    rects = const <Rect>[
      Rect.fromLTRB(0, 0, hero, 1),
      Rect.fromLTRB(hero, 0, 1, 0.5),
      Rect.fromLTRB(hero, 0.5, 1, 1),
    ];
  }
  if (pageIndex.isOdd) {
    rects = rects
        .map((Rect r) =>
            Rect.fromLTRB(1.0 - r.right, r.top, 1.0 - r.left, r.bottom))
        .toList(growable: false);
  }
  return rects;
}

void _paintImageTile(Canvas canvas, ui.Image image, Rect rect) {
  if (rect.width <= 0.0 || rect.height <= 0.0) return;
  canvas.drawRRect(
    RRect.fromRectAndRadius(rect, const Radius.circular(6)),
    Paint()..color = const Color(0xFF090A0C),
  );
  canvas.save();
  canvas.clipRRect(RRect.fromRectAndRadius(rect, const Radius.circular(6)));
  final double srcW = image.width.toDouble();
  final double srcH = image.height.toDouble();
  final double scale = math.max(rect.width / srcW, rect.height / srcH);
  final double drawW = srcW * scale;
  final double drawH = srcH * scale;
  final Rect dst = Rect.fromLTWH(
    rect.center.dx - drawW / 2.0,
    rect.center.dy - drawH / 2.0,
    drawW,
    drawH,
  );
  canvas.drawImageRect(
    image,
    Rect.fromLTWH(0, 0, srcW, srcH),
    dst,
    Paint()..filterQuality = FilterQuality.low,
  );
  canvas.restore();
  canvas.drawRRect(
    RRect.fromRectAndRadius(rect, const Radius.circular(6)),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = const Color(0xFF5B6068),
  );
}

class StructuralDossierPanelOverlay extends StatefulWidget {
  const StructuralDossierPanelOverlay({
    super.key,
    required this.placement,
    required this.resolveSource,
    this.fontFamily = 'monospace',
  });

  final StructuralDossierOverlayPlacement placement;
  final String Function(String source) resolveSource;
  final String fontFamily;

  @override
  State<StructuralDossierPanelOverlay> createState() =>
      _StructuralDossierPanelOverlayState();
}

class _StructuralDossierPanelOverlayState
    extends State<StructuralDossierPanelOverlay> {
  late DossierOverlayImageCache _images;

  @override
  void initState() {
    super.initState();
    _images = DossierOverlayImageCache(widget.resolveSource);
    _ensure();
  }

  @override
  void didUpdateWidget(covariant StructuralDossierPanelOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resolveSource != widget.resolveSource) {
      _images.dispose();
      _images = DossierOverlayImageCache(widget.resolveSource);
    }
    _ensure();
  }

  void _ensure() {
    _images.ensure(widget.placement).then((bool changed) {
      if (changed && mounted) setState(() {});
    });
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
        painter: _StructuralDossierPanelPainter(
          placement: widget.placement,
          images: _images,
          fontFamily: widget.fontFamily,
        ),
      ),
    );
  }
}

class _StructuralDossierPanelPainter extends CustomPainter {
  const _StructuralDossierPanelPainter({
    required this.placement,
    required this.images,
    required this.fontFamily,
  });

  final StructuralDossierOverlayPlacement placement;
  final DossierOverlayImageCache images;
  final String fontFamily;

  @override
  void paint(Canvas canvas, Size size) {
    paintStructuralDossierPanel(
      canvas: canvas,
      size: size,
      placement: placement,
      images: images,
      fontFamily: fontFamily,
    );
  }

  @override
  bool shouldRepaint(covariant _StructuralDossierPanelPainter oldDelegate) =>
      oldDelegate.placement != placement ||
      !identical(oldDelegate.images, images) ||
      oldDelegate.fontFamily != fontFamily;
}

/// Live standalone authoring overlay used by EditVideoPreview.
///
/// It contains no clock and owns no source pixels. [projectFrame] comes from
/// EditVideoPreview's existing transport; [structuralImage] is the exact image
/// that preview already decoded. The widget only projects a clip-local DOSSIER
/// request into the fake authoring desktop shell.
class StructuralDossierCueOverlay extends StatefulWidget {
  const StructuralDossierCueOverlay({
    super.key,
    required this.source,
    required this.sourceRef,
    required this.projectFrame,
    required this.resolveSource,
    this.structuralImage,
    this.fontFamily = 'monospace',
  });

  final String source;
  final String sourceRef;
  final int projectFrame;
  final String Function(String source) resolveSource;
  final ValueListenable<ui.Image?>? structuralImage;
  final String fontFamily;

  @override
  State<StructuralDossierCueOverlay> createState() =>
      _StructuralDossierCueOverlayState();
}

class _StructuralDossierCueOverlayState
    extends State<StructuralDossierCueOverlay> {
  late DossierOverlayImageCache _images;
  EditDocumentModel? _model;
  StructuralSourceRef? _root;
  String? _parsedSource;
  String? _parsedSourceRef;

  @override
  void initState() {
    super.initState();
    _images = DossierOverlayImageCache(widget.resolveSource);
  }

  @override
  void didUpdateWidget(covariant StructuralDossierCueOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resolveSource != widget.resolveSource) {
      _images.dispose();
      _images = DossierOverlayImageCache(widget.resolveSource);
    }
    if (oldWidget.source != widget.source ||
        oldWidget.sourceRef != widget.sourceRef ||
        oldWidget.resolveSource != widget.resolveSource) {
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

  StructuralDossierOverlayPlacement? _placement() {
    try {
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
          return null;
        }
        _model = model;
        _root = root;
        _parsedSource = widget.source;
        _parsedSourceRef = widget.sourceRef;
      }

      return structuralDossierPlacement(
        _model!,
        _root!,
        widget.projectFrame,
        centerPageCountFor: (DossierRequest request) =>
            structuralDossierCenterPageCount(request, widget.resolveSource),
      );
    } catch (_) {
      return null;
    }
  }

  void _ensureImages(StructuralDossierOverlayPlacement placement) {
    _images.ensure(placement).then((bool changed) {
      if (changed && mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final StructuralDossierOverlayPlacement? placement = _placement();
    if (placement == null || structuralDossierShellSlide(placement) <= 0.0) {
      return const SizedBox.expand();
    }
    _ensureImages(placement);

    Widget painted(ui.Image? structuralImage) {
      return IgnorePointer(
        child: CustomPaint(
          key: const ValueKey<String>('edit-dossier-cue-overlay-paint'),
          painter: _StructuralDossierCuePainter(
            placement: placement,
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

class _StructuralDossierCuePainter extends CustomPainter {
  const _StructuralDossierCuePainter({
    required this.placement,
    required this.images,
    required this.structuralImage,
    required this.fontFamily,
  });

  final StructuralDossierOverlayPlacement placement;
  final DossierOverlayImageCache images;
  final ui.Image? structuralImage;
  final String fontFamily;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect frame = structuralOverlayFit16x9(size);
    if (frame.width <= 0.0 || frame.height <= 0.0) return;
    canvas.save();
    canvas.translate(frame.left, frame.top);
    paintStandaloneStructuralDossierComposition(
      canvas: canvas,
      size: frame.size,
      placement: placement,
      images: images,
      structuralImage: structuralImage,
      fontFamily: fontFamily,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _StructuralDossierCuePainter oldDelegate) =>
      oldDelegate.placement != placement ||
      !identical(oldDelegate.images, images) ||
      !identical(oldDelegate.structuralImage, structuralImage) ||
      oldDelegate.fontFamily != fontFamily;
}
