// ./lib/program_structural_export.dart
//
// Whole-program STRUCT frame compositor for SceneExporter.
//
// The terminal SceneEngine remains the only main-sequence clock. This layer
// observes the engine-internal STRUCT runtime REGION after SceneEngine has
// evaluated an explicit ProjectTime, resolves that placement's exact local
// frame, asks the existing blocking StructuralSourceFrameRenderer for the
// exact EDIT/MOSAIC pixels, and composites the same authored desktop/window
// choreography used by live Preview.
//
// Fullscreen CARD CUE presentation is composited into the structural client
// image before that client is placed into desktop/window choreography.
// SIDECARD and DOSSIER instead keep the raw structural client inside the one
// real outer STRUCT window, move that window into the shared left seat, and
// paint their sibling presentation on the desktop. DOSSIER evolves that sibling
// from biography card into evidence grid/mosaic while the same video clock keeps
// advancing. Preview and BAKE share sidecard_geometry.dart shell evaluation and
// dossier_overlay.dart panel painting.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'card_overlay.dart';
import 'dossier_overlay.dart';
import 'edit_model.dart';
import 'media_layer.dart';
import 'scene_engine.dart';
import 'scene_painter.dart';
import 'structural_chrome.dart';
import 'structural_sequence.dart';
import 'structural_source_export.dart';
import 'ui_theme.dart';

Rect structuralProgramTargetRectForOutput({
  required int outputWidth,
  required int outputHeight,
  required double titleHeight,
}) {
  if (outputWidth <= 0 || outputHeight <= 0) return Rect.zero;

  final double width = outputWidth.toDouble();
  final double height = outputHeight.toDouble();
  final double maxW = width * 0.86;
  final double maxH = height * 0.78;

  double clientW = maxW;
  double clientH = clientW * 9.0 / 16.0;
  if (clientH + titleHeight > maxH) {
    clientH = math.max(1.0, maxH - titleHeight);
    clientW = clientH * 16.0 / 9.0;
  }

  final double windowH = clientH + titleHeight;
  final Rect pixelRect = Rect.fromLTWH(
    (width - clientW) / 2.0,
    (height - windowH) / 2.0,
    clientW,
    windowH,
  );

  return Rect.fromLTRB(
    pixelRect.left / width,
    pixelRect.top / height,
    pixelRect.right / width,
    pixelRect.bottom / height,
  );
}

Rect structuralProgramPresentationRectForOutput({
  required StructuralPresentationMode mode,
  required int outputWidth,
  required int outputHeight,
  required double titleHeight,
}) {
  if (mode == StructuralPresentationMode.fullscreen) {
    return const Rect.fromLTWH(0, 0, 1, 1);
  }
  return structuralProgramTargetRectForOutput(
    outputWidth: outputWidth,
    outputHeight: outputHeight,
    titleHeight: titleHeight,
  );
}

class ProgramStructuralFrameRenderer {
  final String rawDocument;
  final int width;
  final int height;
  final MediaDecoderBackend backend;
  final String Function(String source) resolveSource;

  final List<StructuralSequencePlacement> _placements;
  final EditDocumentModel _editModel;
  final CardOverlayImageCache _cardImages;
  final DossierOverlayImageCache _dossierImages;
  final Map<String, StructuralSourceFrameRenderer> _sourceRenderers =
      <String, StructuralSourceFrameRenderer>{};

  String? _cachedSource;
  int? _cachedSourceFrame;
  ui.Image? _cachedSourceImage;
  String _cachedDiagnosticLabel = '';
  bool _disposed = false;

  ProgramStructuralFrameRenderer({
    required this.rawDocument,
    required this.width,
    required this.height,
    required this.backend,
    required this.resolveSource,
  })  : _placements = parseStructuralSequencePlacements(rawDocument),
        _editModel = EditDocumentModel.parse(rawDocument),
        _cardImages = CardOverlayImageCache(resolveSource),
        _dossierImages = DossierOverlayImageCache(resolveSource) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('Program structural render size must be positive.');
    }
  }

  bool get hasPlacements => _placements.any(
        (StructuralSequencePlacement placement) => placement.resolves,
      );

  StructuralSequencePlacement? _placementFor(
    StructuralRuntimeMarker marker,
  ) {
    final int index = marker.placementIndex;
    if (index < 0 || index >= _placements.length) return null;

    final StructuralSequencePlacement placement = _placements[index];
    if (!placement.resolves) return null;
    if (placement.durationFrames != marker.durationFrames) return null;
    return placement;
  }

  int _localFrame(
    SceneEngine scene,
    StructuralRuntimeMarker marker,
  ) {
    final terminal = scene.terminal;
    final bool awaitingPauseTag = terminal.activePause == null &&
        terminal.charIndex >= 0 &&
        terminal.charIndex < terminal.text.length &&
        terminal.text.startsWith('[PAUSE:', terminal.charIndex);

    return structuralRuntimeLocalFrame(
      marker: marker,
      pauseFramesRemaining: terminal.pauseFrames,
      awaitingPauseTag: awaitingPauseTag,
    );
  }

  StructuralSourceRef? _rootFor(StructuralSequencePlacement placement) {
    final StructuralSourceRef? root =
        StructuralSourceRef.tryParse(placement.sourceRef.canonicalSource);
    if (root == null ||
        root.id.isEmpty ||
        !_editModel.containsStructuralSource(root)) {
      return null;
    }
    return root;
  }

  int _dossierPageCount(request) =>
      structuralDossierCenterPageCount(request, resolveSource);

  StructuralDossierOverlayPlacement? _dossierAtSourceFrame(
    StructuralSequencePlacement placement,
    int sourceFrame,
  ) {
    final StructuralSourceRef? root = _rootFor(placement);
    if (root == null) return null;
    return structuralDossierPlacement(
      _editModel,
      root,
      sourceFrame,
      centerPageCountFor: _dossierPageCount,
    );
  }

  StructuralDossierOverlayPlacement? _dossierFor(
    StructuralSequencePlacement placement,
    int localFrame,
    int sourceFrame,
  ) {
    if (placement.stageAt(localFrame) != StructuralSequenceStage.showing) {
      return null;
    }
    return _dossierAtSourceFrame(placement, sourceFrame);
  }

  StructuralDossierOverlayPlacement? _dossierAtSourceEnd(
    StructuralSequencePlacement placement,
  ) {
    final StructuralSourceRef? root = _rootFor(placement);
    if (root == null) return null;
    return structuralDossierPlacementAtSourceEnd(
      _editModel,
      root,
      placement.sourceDurationFrames,
      centerPageCountFor: _dossierPageCount,
    );
  }

  StructuralCardOverlayPlacement? _sideCardAtSourceFrame(
    StructuralSequencePlacement placement,
    int sourceFrame,
  ) {
    final StructuralSourceRef? root = _rootFor(placement);
    if (root == null) return null;
    return structuralSideCardPlacement(_editModel, root, sourceFrame);
  }

  StructuralCardOverlayPlacement? _sideCardFor(
    StructuralSequencePlacement placement,
    int localFrame,
    int sourceFrame,
  ) {
    if (placement.stageAt(localFrame) != StructuralSequenceStage.showing) {
      return null;
    }
    return _sideCardAtSourceFrame(placement, sourceFrame);
  }

  StructuralCardOverlayPlacement? _sideCardAtSourceEnd(
    StructuralSequencePlacement placement,
  ) {
    final StructuralSourceRef? root = _rootFor(placement);
    if (root == null) return null;
    return structuralSideCardPlacementAtSourceEnd(
      _editModel,
      root,
      placement.sourceDurationFrames,
    );
  }

  Future<ui.Image?> renderIfActive({
    required SceneEngine scene,
    required String fontFamily,
  }) async {
    _checkAlive();

    final StructuralRuntimeMarker? marker =
        parseStructuralRuntimeRegion(scene.terminal.currentRegion);
    if (marker == null) return null;

    final StructuralSequencePlacement? placement = _placementFor(marker);
    if (placement == null) return null;

    final int localFrame = _localFrame(scene, marker);
    final StructuralSequenceStage stage = placement.stageAt(localFrame);
    final StructuralDossierOverlayPlacement? truncatedDossier =
        stage == StructuralSequenceStage.closing
            ? _dossierAtSourceEnd(placement)
            : null;
    final StructuralCardOverlayPlacement? truncatedSideCard =
        truncatedDossier == null && stage == StructuralSequenceStage.closing
            ? _sideCardAtSourceEnd(placement)
            : null;
    final double? truncatedShellSlide = truncatedDossier != null
        ? structuralDossierShellSlide(truncatedDossier)
        : truncatedSideCard?.slide;

    final _StructuralProgramVisual visual = _StructuralProgramVisual.evaluate(
      placement: placement,
      localFrame: localFrame,
      scene: scene,
      outputWidth: width,
      outputHeight: height,
      truncatedShellSlide: truncatedShellSlide,
    );

    final StructuralDossierOverlayPlacement? dossier = _dossierFor(
      placement,
      localFrame,
      visual.sourceFrame,
    );
    final StructuralCardOverlayPlacement? sideCard = dossier == null
        ? _sideCardFor(
            placement,
            localFrame,
            visual.sourceFrame,
          )
        : null;

    ui.Image? sourceImage;
    String defaultBottomOverlay = '';
    if (visual.structuralWindowPresent && visual.structuralOpacity > 0.001) {
      sourceImage = await _imageForSourceFrame(
        placement.sourceRef.canonicalSource,
        visual.sourceFrame,
        fontFamily,
      );
      defaultBottomOverlay = _cachedDiagnosticLabel;
    }
    if (dossier != null) {
      await _dossierImages.ensure(dossier);
    } else if (sideCard != null) {
      await _cardImages.ensure(<StructuralCardOverlayPlacement>[sideCard]);
    }

    Rect structuralRect = visual.structuralRect;
    double desktopOpacity = visual.desktopOpacity;
    double terminalOpacity = visual.terminalOpacity;
    final double? shellSlide = dossier != null
        ? structuralDossierShellSlide(dossier)
        : sideCard?.slide;
    if (shellSlide != null &&
        shellSlide > 0.0 &&
        visual.structuralWindowPresent) {
      final SideCardShellFrame sideShell = sideCardShellFrameAt(
        size: Size(width.toDouble(), height.toDouble()),
        preCueRect: _pixelRect(structuralRect),
        slide: shellSlide,
      );
      structuralRect = _normalizedRect(sideShell.videoWindowRect);
      desktopOpacity = sideShell.desktopOpacity;
      terminalOpacity = sideShell.terminalOpacity;
    }

    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    );

    SceneStructuralTerminalPainter(
      scene: scene,
      fontFamily: fontFamily,
      terminalRect: visual.terminalRect,
      desktopOpacity: desktopOpacity,
      terminalOpacity: terminalOpacity,
      terminalChrome: visual.terminalChrome,
    ).paint(canvas, Size(width.toDouble(), height.toDouble()));

    if (visual.structuralWindowPresent && visual.structuralOpacity > 0.001) {
      _paintStructuralWindow(
        canvas: canvas,
        scene: scene,
        fontFamily: fontFamily,
        sourceFrame: visual.sourceFrame,
        sourceDurationFrames: placement.sourceDurationFrames,
        windowTitle: placement.effectiveWindowTitle,
        overlayMode: placement.overlayMode,
        topOverlay: placement.topOverlay,
        bottomOverlay: placement.bottomOverlay,
        defaultBottomOverlay: defaultBottomOverlay,
        rect: _pixelRect(structuralRect),
        sourceImage: sourceImage,
        opacity: visual.structuralOpacity,
      );
    }

    if (dossier != null) {
      paintStructuralDossierPanel(
        canvas: canvas,
        size: Size(width.toDouble(), height.toDouble()),
        placement: dossier,
        images: _dossierImages,
        fontFamily: fontFamily,
      );
    } else if (sideCard != null) {
      paintStructuralSideCardPanel(
        canvas: canvas,
        size: Size(width.toDouble(), height.toDouble()),
        placement: sideCard,
        images: _cardImages,
        fontFamily: fontFamily,
      );
    }

    final ui.Picture picture = recorder.endRecording();
    try {
      return await picture.toImage(width, height);
    } finally {
      picture.dispose();
    }
  }

  Rect _pixelRect(Rect normalized) => Rect.fromLTRB(
        normalized.left * width,
        normalized.top * height,
        normalized.right * width,
        normalized.bottom * height,
      );

  Rect _normalizedRect(Rect pixel) => Rect.fromLTRB(
        pixel.left / width,
        pixel.top / height,
        pixel.right / width,
        pixel.bottom / height,
      );

  Future<ui.Image> _imageForSourceFrame(
    String source,
    int sourceFrame,
    String fontFamily,
  ) async {
    final ui.Image? cached = _cachedSourceImage;
    if (cached != null &&
        _cachedSource == source &&
        _cachedSourceFrame == sourceFrame) {
      return cached;
    }

    final StructuralSourceFrameRenderer renderer =
        _sourceRenderers.putIfAbsent(
      source,
      () => StructuralSourceFrameRenderer.create(
        source: rawDocument,
        structuralSource: source,
        width: width,
        height: height,
        backend: backend,
        resolveSource: resolveSource,
      ),
    );

    final StructuralSourceRenderedFrame rendered =
        renderer.renderFrameDetailed(sourceFrame);
    final ui.Image decoded = await _decodeRgba(rendered.rgba, width, height);

    ui.Image finalImage = decoded;
    final StructuralSourceRef? root = StructuralSourceRef.tryParse(source);
    if (root != null &&
        root.id.isNotEmpty &&
        _editModel.containsStructuralSource(root)) {
      final List<StructuralCardOverlayPlacement> overlays =
          structuralCardOverlayPlacements(_editModel, root, sourceFrame)
              .where(
                (StructuralCardOverlayPlacement placement) =>
                    !placement.isSideCard,
              )
              .toList(growable: false);
      if (overlays.any((StructuralCardOverlayPlacement p) => p.slide > 0.0)) {
        await _cardImages.ensure(overlays);
        final ui.PictureRecorder recorder = ui.PictureRecorder();
        final Canvas canvas = Canvas(
          recorder,
          Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        );
        canvas.drawImage(decoded, Offset.zero, Paint());
        paintStructuralCardOverlays(
          canvas: canvas,
          size: Size(width.toDouble(), height.toDouble()),
          placements: overlays,
          images: _cardImages,
          structuralImage: decoded,
          fontFamily: fontFamily,
        );
        final ui.Picture picture = recorder.endRecording();
        try {
          finalImage = await picture.toImage(width, height);
        } finally {
          picture.dispose();
          decoded.dispose();
        }
      }
    }

    _cachedSourceImage?.dispose();
    _cachedSourceImage = finalImage;
    _cachedSource = source;
    _cachedSourceFrame = sourceFrame;
    _cachedDiagnosticLabel = rendered.diagnosticLabel(source);
    return finalImage;
  }

  Future<ui.Image> _decodeRgba(
    Uint8List rgba,
    int imageWidth,
    int imageHeight,
  ) {
    final Completer<ui.Image> completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      imageWidth,
      imageHeight,
      ui.PixelFormat.rgba8888,
      completer.complete,
      rowBytes: imageWidth * 4,
    );
    return completer.future;
  }

  void _paintStructuralWindow({
    required Canvas canvas,
    required SceneEngine scene,
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
    required double opacity,
  }) {
    if (rect.width <= 0.0 || rect.height <= 0.0 || opacity <= 0.001) {
      return;
    }

    final double engineWidth = scene.width > 0.0 ? scene.width : width.toDouble();
    final double chromeScale =
        scene.terminal.scale * width.toDouble() / engineWidth;
    final double s = chromeScale > 0.0 ? chromeScale : 1.0;
    final double barH = 38.0 * s;
    final double radius = 5.0 * s;
    final RRect window =
        RRect.fromRectAndRadius(rect, Radius.circular(radius));
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

    canvas.drawRRect(
      window.shift(Offset(0, 16.0 * s)),
      Paint()
        ..color = const Color(0x8A000000)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 30.0 * s),
    );

    canvas.drawRRect(window, Paint()..color = const Color(0xFF171717));
    canvas.drawRRect(
      window,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.5, s)
        ..color = const Color(0xFF3B3938),
    );

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

    if (sourceImage != null && client.width > 0.0 && client.height > 0.0) {
      _drawImageContain(canvas, sourceImage, client);
    }

    final R3Theme theme = R3Theme.of(scene.terminal.fontColor);

    final String? bottomText = switch (overlayMode) {
      StructuralOverlayMode.defaultOverlay =>
        defaultBottomOverlay.isEmpty ? null : defaultBottomOverlay,
      StructuralOverlayMode.custom =>
        renderedBottom.isEmpty ? null : renderedBottom,
      StructuralOverlayMode.none => null,
    };

    if (bottomText != null &&
        client.width > 0.0 &&
        client.height > 0.0) {
      final TextPainter bottom = TextPainter(
        text: TextSpan(
          text: bottomText,
          style: theme.micro.copyWith(
            fontFamily: fontFamily,
            color: R3Theme.textMid,
            fontSize: (theme.micro.fontSize ?? 10.5) * s,
            letterSpacing: (theme.micro.letterSpacing ?? 0.0) * s,
          ),
        ),
        maxLines: 1,
        ellipsis: '…',
        textDirection: TextDirection.ltr,
      );
      bottom.layout(maxWidth: math.max(0.0, client.width - 28.0 * s));
      final double padX = 6.0 * s;
      final double padY = 3.0 * s;
      final Rect plate = Rect.fromLTWH(
        client.left + 8.0 * s,
        client.bottom - 7.0 * s - bottom.height - padY * 2.0,
        bottom.width + padX * 2.0,
        bottom.height + padY * 2.0,
      );
      canvas.drawRect(
        plate,
        Paint()..color = Colors.black.withValues(alpha: 0.72),
      );
      bottom.paint(canvas, Offset(plate.left + padX, plate.top + padY));
    }

    canvas.drawRect(header, Paint()..color = const Color(0xFF33302F));
    canvas.drawLine(
      Offset(header.left, header.bottom),
      Offset(header.right, header.bottom),
      Paint()
        ..strokeWidth = math.max(0.5, s)
        ..color = const Color(0xFF474341),
    );

    final double horizontalPad = 14.0 * s;
    final TextPainter left = TextPainter(
      text: TextSpan(
        text: renderedTitle,
        style: theme.value.copyWith(
          fontFamily: fontFamily,
          color: const Color(0xFFC7C3C0),
          fontSize: 12.0 * s,
        ),
      ),
      maxLines: 1,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    );

    final String? topText = switch (overlayMode) {
      StructuralOverlayMode.defaultOverlay =>
        'F$sourceFrame / $sourceDurationFrames',
      StructuralOverlayMode.custom =>
        renderedTop.isEmpty ? null : renderedTop,
      StructuralOverlayMode.none => null,
    };

    TextPainter? right;
    double rightX = header.right - horizontalPad;
    if (topText != null) {
      right = TextPainter(
        text: TextSpan(
          text: topText,
          style: theme.micro.copyWith(
            fontFamily: fontFamily,
            color: const Color(0xFF8E8884),
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
    left.layout(maxWidth: labelMax);

    final double leftY = header.top + (header.height - left.height) / 2.0;
    left.paint(canvas, Offset(header.left + horizontalPad, leftY));
    if (right != null) {
      final double rightY = header.top + (header.height - right.height) / 2.0;
      right.paint(canvas, Offset(rightX, rightY));
    }
    canvas.restore();

    if (faded) canvas.restore();
  }

  void _drawImageContain(Canvas canvas, ui.Image image, Rect destination) {
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
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  void _checkAlive() {
    if (_disposed) {
      throw StateError('ProgramStructuralFrameRenderer has been disposed.');
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cachedSourceImage?.dispose();
    _cachedSourceImage = null;
    _cachedDiagnosticLabel = '';
    _cardImages.dispose();
    _dossierImages.dispose();
    for (final StructuralSourceFrameRenderer renderer
        in _sourceRenderers.values) {
      renderer.dispose();
    }
    _sourceRenderers.clear();
  }
}

class _StructuralProgramVisual {
  final int sourceFrame;
  final Rect terminalRect;
  final Rect structuralRect;
  final double desktopOpacity;
  final double terminalOpacity;
  final double terminalChrome;
  final double structuralOpacity;
  final bool structuralWindowPresent;

  const _StructuralProgramVisual({
    required this.sourceFrame,
    required this.terminalRect,
    required this.structuralRect,
    required this.desktopOpacity,
    required this.terminalOpacity,
    required this.terminalChrome,
    required this.structuralOpacity,
    required this.structuralWindowPresent,
  });

  factory _StructuralProgramVisual.evaluate({
    required StructuralSequencePlacement placement,
    required int localFrame,
    required SceneEngine scene,
    required int outputWidth,
    required int outputHeight,
    double? truncatedShellSlide,
  }) {
    final StructuralSequenceStage stage = placement.stageAt(localFrame);
    final double linear = placement.stageProgressAt(localFrame);
    final double eased = Curves.easeInOutCubic.transform(linear);
    final int sourceFrame = placement.sourceFrameAt(localFrame);

    final double engineWidth =
        scene.width > 0.0 ? scene.width : outputWidth.toDouble();
    final double chromeScale =
        scene.terminal.scale * outputWidth.toDouble() / engineWidth;
    final double titleHeight = 38.0 * chromeScale;

    final Rect fullTerminal = const Rect.fromLTWH(0, 0, 1, 1);
    final Rect terminalParkRect = structuralProgramTargetRectForOutput(
      outputWidth: outputWidth,
      outputHeight: outputHeight,
      titleHeight: titleHeight,
    );
    final Rect presentationRect = structuralProgramPresentationRectForOutput(
      mode: placement.presentationMode,
      outputWidth: outputWidth,
      outputHeight: outputHeight,
      titleHeight: titleHeight,
    );
    final Rect previousPresentationRect =
        structuralProgramPresentationRectForOutput(
      mode: placement.previousPresentationMode ??
          StructuralPresentationMode.windowed,
      outputWidth: outputWidth,
      outputHeight: outputHeight,
      titleHeight: titleHeight,
    );
    final Rect emergenceRect = _emergenceRect(terminalParkRect);

    Rect terminalRect = terminalParkRect;
    Rect structuralRect = presentationRect;
    double desktopOpacity = 1.0;
    double terminalOpacity = 0.0;
    double terminalChrome = 1.0;
    double structuralOpacity = 0.0;
    bool structuralWindowPresent = false;

    switch (stage) {
      case StructuralSequenceStage.zoomOut:
        terminalRect = Rect.lerp(fullTerminal, terminalParkRect, eased)!;
        structuralRect = emergenceRect;
        desktopOpacity = eased;
        terminalOpacity = 1.0;
        terminalChrome = eased;
        structuralOpacity = 0.0;
        structuralWindowPresent = true;
        break;

      case StructuralSequenceStage.opening:
        terminalRect = terminalParkRect;
        desktopOpacity = 1.0;
        terminalChrome = 1.0;
        structuralWindowPresent = true;

        if (placement.seamlessFromPrevious) {
          structuralRect = Rect.lerp(
            previousPresentationRect,
            presentationRect,
            eased,
          )!;
          terminalOpacity = 0.0;
          structuralOpacity = 1.0;
        } else {
          structuralRect = Rect.lerp(
            emergenceRect,
            presentationRect,
            eased,
          )!;
          terminalOpacity = placement.chainedFromPrevious ? 0.0 : 1.0 - eased;
          structuralOpacity = Curves.easeOutCubic.transform(
            (linear * 2.2).clamp(0.0, 1.0),
          );
        }
        break;

      case StructuralSequenceStage.showing:
        terminalRect = terminalParkRect;
        structuralRect = presentationRect;
        desktopOpacity = 1.0;
        terminalOpacity = 0.0;
        terminalChrome = 1.0;
        structuralOpacity = 1.0;
        structuralWindowPresent = true;
        break;

      case StructuralSequenceStage.closing:
        terminalRect = terminalParkRect;
        final Rect presentationPixels = Rect.fromLTRB(
          presentationRect.left * outputWidth,
          presentationRect.top * outputHeight,
          presentationRect.right * outputWidth,
          presentationRect.bottom * outputHeight,
        );
        final Rect closingOriginPixels = sideCardClosingOriginRect(
          size: Size(outputWidth.toDouble(), outputHeight.toDouble()),
          preCueRect: presentationPixels,
          truncatedSlide: truncatedShellSlide,
        );
        final Rect closingOrigin = Rect.fromLTRB(
          closingOriginPixels.left / outputWidth,
          closingOriginPixels.top / outputHeight,
          closingOriginPixels.right / outputWidth,
          closingOriginPixels.bottom / outputHeight,
        );
        structuralRect = Rect.lerp(closingOrigin, emergenceRect, eased)!;
        desktopOpacity = 1.0;
        terminalOpacity = placement.chainedToNext ? 0.0 : eased;
        terminalChrome = 1.0;
        structuralOpacity = Curves.easeInCubic.transform(
          ((1.0 - linear) * 2.2).clamp(0.0, 1.0),
        );
        structuralWindowPresent = true;
        break;

      case StructuralSequenceStage.zoomIn:
        terminalRect = Rect.lerp(terminalParkRect, fullTerminal, eased)!;
        structuralRect = presentationRect;
        desktopOpacity = 1.0 - eased;
        terminalOpacity = 1.0;
        terminalChrome = 1.0 - eased;
        structuralOpacity = 0.0;
        structuralWindowPresent = false;
        break;
    }

    return _StructuralProgramVisual(
      sourceFrame: sourceFrame,
      terminalRect: terminalRect,
      structuralRect: structuralRect,
      desktopOpacity: desktopOpacity,
      terminalOpacity: terminalOpacity,
      terminalChrome: terminalChrome,
      structuralOpacity: structuralOpacity,
      structuralWindowPresent: structuralWindowPresent,
    );
  }

  static Rect _emergenceRect(Rect target) {
    const double scale = 0.84;
    final double w = target.width * scale;
    final double h = target.height * scale;
    return Rect.fromLTWH(
      target.center.dx - w / 2.0,
      target.center.dy - h / 2.0 + target.height * 0.055,
      w,
      h,
    );
  }
}
