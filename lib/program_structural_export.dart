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
// SIDECARD and DOSSIER instead move the one real outer STRUCT window and paint
// sibling content. MAXIMIZE paints nothing: it transforms that same shell toward
// the full output frame while source decoding and audio time continue unchanged.
// Preview and BAKE share structural_shell_geometry.dart for both base shell and
// MAXIMIZE geometry.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'card_overlay.dart';
import 'dossier_overlay.dart';
import 'edit_model.dart';
import 'maximize_shell_state.dart';
import 'media_layer.dart';
import 'scene_engine.dart';
import 'scene_painter.dart';
import 'structural_chrome.dart';
import 'structural_sequence.dart';
import 'structural_shell_geometry.dart';
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

class _StructuralBakeHandoff {
  const _StructuralBakeHandoff({
    required this.outgoingPlacement,
    required this.outgoingSourceFrame,
    required this.slideT,
  });

  final StructuralSequencePlacement outgoingPlacement;
  final int outgoingSourceFrame;
  final double slideT;
}

class _RenderedStructuralSourceImage {
  const _RenderedStructuralSourceImage({
    required this.image,
    required this.diagnosticLabel,
  });

  final ui.Image image;
  final String diagnosticLabel;
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

  _StructuralBakeHandoff? _handoffFor(
    StructuralRuntimeMarker marker,
    StructuralSequencePlacement incoming,
    int incomingSourceFrame,
  ) {
    if (!incoming.seamlessFromPrevious) return null;

    final int previousIndex = marker.placementIndex - 1;
    if (previousIndex < 0 || previousIndex >= _placements.length) return null;

    final StructuralSequencePlacement outgoing = _placements[previousIndex];
    if (!outgoing.resolves || !outgoing.seamlessToNext) return null;

    final int slideFrames = math.min(
      kStructuralSwitchSlideFrames,
      incoming.sourceDurationFrames,
    );
    if (slideFrames <= 1 || incomingSourceFrame >= slideFrames - 1) {
      return null;
    }

    final int outgoingLocalFrame =
        math.max(0, outgoing.effectiveDurationFrames - 1);
    final int outgoingSourceFrame =
        outgoing.sourceFrameAt(outgoingLocalFrame);
    final double raw =
        (incomingSourceFrame / (slideFrames - 1))
            .clamp(0.0, 1.0)
            .toDouble();

    return _StructuralBakeHandoff(
      outgoingPlacement: outgoing,
      outgoingSourceFrame: outgoingSourceFrame,
      slideT: Curves.easeInOutCubic.transform(raw),
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

  StructuralMaximizePlacement? _maximizeAtSourceFrame(
    StructuralSequencePlacement placement,
    int sourceFrame,
  ) {
    if (placement.fullscreen) return null;
    final StructuralSourceRef? root = _rootFor(placement);
    if (root == null) return null;
    return structuralMaximizePlacement(_editModel, root, sourceFrame);
  }

  StructuralMaximizePlacement? _maximizeFor(
    StructuralSequencePlacement placement,
    int localFrame,
    int sourceFrame,
  ) {
    // Load-bearing gating: a source-frame-zero MAXIMIZE cannot fire during the
    // placement's opening choreography. Shell cues begin only in showing time.
    if (placement.stageAt(localFrame) != StructuralSequenceStage.showing) {
      return null;
    }
    return _maximizeAtSourceFrame(placement, sourceFrame);
  }

  StructuralMaximizePlacement? _maximizeAtSourceEnd(
    StructuralSequencePlacement placement,
  ) {
    if (placement.fullscreen) return null;
    final StructuralSourceRef? root = _rootFor(placement);
    if (root == null) return null;
    return structuralMaximizePlacementAtSourceEnd(
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
    final bool closing = stage == StructuralSequenceStage.closing;
    final StructuralDossierOverlayPlacement? truncatedDossier =
        closing ? _dossierAtSourceEnd(placement) : null;
    final StructuralCardOverlayPlacement? truncatedSideCard =
        truncatedDossier == null && closing
            ? _sideCardAtSourceEnd(placement)
            : null;
    final double? truncatedShellSlide = truncatedDossier != null
        ? structuralDossierShellSlide(truncatedDossier)
        : truncatedSideCard?.slide;
    final StructuralMaximizePlacement? truncatedMaximize =
        truncatedDossier == null && truncatedSideCard == null && closing
            ? _maximizeAtSourceEnd(placement)
            : null;

    final _StructuralProgramVisual visual = _StructuralProgramVisual.evaluate(
      placement: placement,
      localFrame: localFrame,
      scene: scene,
      outputWidth: width,
      outputHeight: height,
      truncatedShellSlide: truncatedShellSlide,
      truncatedMaximizeAmount: truncatedMaximize?.amount,
    );

    final _StructuralBakeHandoff? handoff =
        _handoffFor(marker, placement, visual.sourceFrame);

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
    final StructuralMaximizePlacement? maximize =
        dossier == null && sideCard == null
            ? _maximizeFor(
                placement,
                localFrame,
                visual.sourceFrame,
              )
            : null;

    ui.Image? sourceImage;
    ui.Image? outgoingSourceImage;
    String defaultBottomOverlay = '';
    String outgoingDefaultBottomOverlay = '';
    if (visual.structuralWindowPresent && visual.structuralOpacity > 0.001) {
      sourceImage = await _imageForSourceFrame(
        placement.sourceRef.canonicalSource,
        visual.sourceFrame,
        fontFamily,
      );
      defaultBottomOverlay = _cachedDiagnosticLabel;

      final _StructuralBakeHandoff? activeHandoff = handoff;
      if (activeHandoff != null) {
        final StructuralSequencePlacement outgoing =
            activeHandoff.outgoingPlacement;
        final _RenderedStructuralSourceImage renderedOutgoing =
            await _renderSourceFrameImage(
          outgoing.sourceRef.canonicalSource,
          activeHandoff.outgoingSourceFrame,
          fontFamily,
        );
        outgoingSourceImage = renderedOutgoing.image;
        outgoingDefaultBottomOverlay = renderedOutgoing.diagnosticLabel;
      }
    }
    if (dossier != null) {
      await _dossierImages.ensure(dossier);
    } else if (sideCard != null) {
      await _cardImages.ensure(<StructuralCardOverlayPlacement>[sideCard]);
    }

    Rect structuralRect = visual.structuralRect;
    double desktopOpacity = visual.desktopOpacity;
    double terminalOpacity = visual.terminalOpacity;
    double structuralChrome = visual.structuralWindowChrome;
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

    if (maximize != null && visual.structuralWindowPresent) {
      final StructuralMaximizeGeometryFrame maximizeGeometry =
          structuralMaximizeGeometryFrameAt(
        baseRect: structuralRect,
        fullRect: const Rect.fromLTWH(0, 0, 1, 1),
        amount: maximize.amount,
      );
      structuralRect = maximizeGeometry.structuralRect;
      structuralChrome = maximizeGeometry.windowChrome;
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
        outgoingSourceImage: outgoingSourceImage,
        outgoingPlacement: handoff?.outgoingPlacement,
        outgoingSourceFrame: handoff?.outgoingSourceFrame ?? 0,
        outgoingDefaultBottomOverlay: outgoingDefaultBottomOverlay,
        handoffSlideT: handoff?.slideT ?? 1.0,
        opacity: visual.structuralOpacity,
        windowChrome: structuralChrome,
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
      outgoingSourceImage?.dispose();
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

    final _RenderedStructuralSourceImage rendered =
        await _renderSourceFrameImage(
      source,
      sourceFrame,
      fontFamily,
    );

    _cachedSourceImage?.dispose();
    _cachedSourceImage = rendered.image;
    _cachedSource = source;
    _cachedSourceFrame = sourceFrame;
    _cachedDiagnosticLabel = rendered.diagnosticLabel;
    return rendered.image;
  }

  Future<_RenderedStructuralSourceImage> _renderSourceFrameImage(
    String source,
    int sourceFrame,
    String fontFamily,
  ) async {
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

    return _RenderedStructuralSourceImage(
      image: finalImage,
      diagnosticLabel: rendered.diagnosticLabel(source),
    );
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
    required ui.Image? outgoingSourceImage,
    required StructuralSequencePlacement? outgoingPlacement,
    required int outgoingSourceFrame,
    required String outgoingDefaultBottomOverlay,
    required double handoffSlideT,
    required double opacity,
    required double windowChrome,
  }) {
    if (rect.width <= 0.0 || rect.height <= 0.0 || opacity <= 0.001) {
      return;
    }

    final double engineWidth = scene.width > 0.0 ? scene.width : width.toDouble();
    final double chromeScale =
        scene.terminal.scale * width.toDouble() / engineWidth;
    final double s = chromeScale > 0.0 ? chromeScale : 1.0;
    final double c = windowChrome.clamp(0.0, 1.0).toDouble();
    final double barH = 38.0 * s * c;
    final double radius = 5.0 * s * c;
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

    final bool handoffActive =
        outgoingSourceImage != null && outgoingPlacement != null;
    final double slideT =
        handoffSlideT.clamp(0.0, 1.0).toDouble();
    final String outgoingRenderedTitle = handoffActive
        ? expandStructuralChromeExpressions(
            outgoingPlacement.effectiveWindowTitle,
            frame: outgoingSourceFrame,
          )
        : '';
    final String outgoingRenderedTop = handoffActive
        ? expandStructuralChromeExpressions(
            outgoingPlacement.topOverlay,
            frame: outgoingSourceFrame,
          )
        : '';
    final String outgoingRenderedBottom = handoffActive
        ? expandStructuralChromeExpressions(
            outgoingPlacement.bottomOverlay,
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

    final R3Theme theme = R3Theme.of(scene.terminal.fontColor);
    final String? incomingBottomText = switch (overlayMode) {
      StructuralOverlayMode.defaultOverlay =>
        defaultBottomOverlay.isEmpty ? null : defaultBottomOverlay,
      StructuralOverlayMode.custom =>
        renderedBottom.isEmpty ? null : renderedBottom,
      StructuralOverlayMode.none => null,
    };
    final String? outgoingBottomText = !handoffActive
        ? null
        : switch (outgoingPlacement.overlayMode) {
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
        _drawImageContain(canvas, sourceImage, client);
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
      _drawImageContain(canvas, outgoingSourceImage, client);
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
        _drawImageContain(canvas, sourceImage, client);
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
          : switch (outgoingPlacement.overlayMode) {
              StructuralOverlayMode.defaultOverlay =>
                'F$outgoingSourceFrame / '
                    '${outgoingPlacement.sourceDurationFrames}',
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
                color: const Color(0xFF8E8884)
                    .withValues(alpha: c * alpha),
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
              color: const Color(0xFFC7C3C0)
                  .withValues(alpha: c * alpha),
              fontSize: 12.0 * s,
            ),
          ),
          maxLines: 1,
          ellipsis: '…',
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: labelMax);

        final double leftY =
            header.top + (header.height - left.height) / 2.0;
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
  final double structuralWindowChrome;

  const _StructuralProgramVisual({
    required this.sourceFrame,
    required this.terminalRect,
    required this.structuralRect,
    required this.desktopOpacity,
    required this.terminalOpacity,
    required this.terminalChrome,
    required this.structuralOpacity,
    required this.structuralWindowPresent,
    required this.structuralWindowChrome,
  });

  factory _StructuralProgramVisual.evaluate({
    required StructuralSequencePlacement placement,
    required int localFrame,
    required SceneEngine scene,
    required int outputWidth,
    required int outputHeight,
    double? truncatedShellSlide,
    double? truncatedMaximizeAmount,
  }) {
    final StructuralSequenceStage stage = placement.stageAt(localFrame);
    final double linear = placement.stageProgressAt(localFrame);
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

    final Rect presentationPixels = Rect.fromLTRB(
      presentationRect.left * outputWidth,
      presentationRect.top * outputHeight,
      presentationRect.right * outputWidth,
      presentationRect.bottom * outputHeight,
    );
    final Rect sideClosingOriginPixels = sideCardClosingOriginRect(
      size: Size(outputWidth.toDouble(), outputHeight.toDouble()),
      preCueRect: presentationPixels,
      truncatedSlide: truncatedShellSlide,
    );
    Rect closingOrigin = Rect.fromLTRB(
      sideClosingOriginPixels.left / outputWidth,
      sideClosingOriginPixels.top / outputHeight,
      sideClosingOriginPixels.right / outputWidth,
      sideClosingOriginPixels.bottom / outputHeight,
    );

    StructuralMaximizeGeometryFrame? truncatedMaxGeometry;
    if (truncatedMaximizeAmount != null && !placement.fullscreen) {
      truncatedMaxGeometry = structuralMaximizeGeometryFrameAt(
        baseRect: presentationRect,
        fullRect: fullTerminal,
        amount: truncatedMaximizeAmount,
      );
      closingOrigin = truncatedMaxGeometry.structuralRect;
    }

    final StructuralShellFrame shell = structuralShellFrameAt(
      stage: stage,
      linearProgress: linear,
      fullTerminalRect: fullTerminal,
      terminalParkRect: terminalParkRect,
      presentationRect: presentationRect,
      previousPresentationRect: previousPresentationRect,
      closingOriginRect: closingOrigin,
      seamlessFromPrevious: placement.seamlessFromPrevious,
      chainedFromPrevious: placement.chainedFromPrevious,
      chainedToNext: placement.chainedToNext,
      contentReady: true,
    );

    double structuralWindowChrome = 1.0;
    if (stage == StructuralSequenceStage.closing &&
        truncatedMaxGeometry != null) {
      final double eased = Curves.easeInOutCubic.transform(
        linear.clamp(0.0, 1.0).toDouble(),
      );
      structuralWindowChrome = ui.lerpDouble(
        truncatedMaxGeometry.windowChrome,
        1.0,
        eased,
      )!;
    }

    return _StructuralProgramVisual(
      sourceFrame: sourceFrame,
      terminalRect: shell.terminalRect,
      structuralRect: shell.structuralRect,
      desktopOpacity: shell.desktopOpacity,
      terminalOpacity: shell.terminalOpacity,
      terminalChrome: shell.terminalChrome,
      structuralOpacity: shell.structuralOpacity,
      structuralWindowPresent: shell.structuralWindowPresent,
      structuralWindowChrome: structuralWindowChrome,
    );
  }
}
