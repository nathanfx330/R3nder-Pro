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
// Structural application planning is already baked into each placement:
// standalone terminal entry/exit, ordinary desktop chaining, APPSWITCH:SLIDE,
// and windowed/fullscreen geometry all use the same event budget Preview sees.
// Decode speed may make an export frame take longer to produce. It can never
// move project time, substitute a neighbouring media frame, shorten a source,
// or alter the structural transition curve.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'media_layer.dart';
import 'scene_engine.dart';
import 'scene_painter.dart';
import 'structural_chrome.dart';
import 'structural_sequence.dart';
import 'structural_source_export.dart';
import 'ui_theme.dart';

/// Windowed STRUCT geometry in normalized output coordinates.
///
/// Preview computes this in real render-frame pixels. Bake must do the same
/// before converting to ScenePainter's normalized 0..1 space.
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
  final Map<String, StructuralSourceFrameRenderer> _sourceRenderers =
      <String, StructuralSourceFrameRenderer>{};

  String? _cachedSource;
  int? _cachedSourceFrame;
  ui.Image? _cachedSourceImage;
  bool _disposed = false;

  ProgramStructuralFrameRenderer({
    required this.rawDocument,
    required this.width,
    required this.height,
    required this.backend,
    required this.resolveSource,
  }) : _placements = parseStructuralSequencePlacements(rawDocument) {
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

  /// Returns a complete output frame while STRUCT is active, otherwise null so
  /// SceneExporter can use its original SceneCompositor path unchanged.
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
    final _StructuralProgramVisual visual = _StructuralProgramVisual.evaluate(
      placement: placement,
      localFrame: localFrame,
      scene: scene,
      outputWidth: width,
      outputHeight: height,
    );

    ui.Image? sourceImage;
    if (visual.structuralWindowPresent && visual.structuralOpacity > 0.001) {
      sourceImage = await _imageForSourceFrame(
        placement.sourceRef.canonicalSource,
        visual.sourceFrame,
      );
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
      desktopOpacity: visual.desktopOpacity,
      terminalOpacity: visual.terminalOpacity,
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
        rect: _pixelRect(visual.structuralRect),
        sourceImage: sourceImage,
        opacity: visual.structuralOpacity,
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

  Future<ui.Image> _imageForSourceFrame(
    String source,
    int sourceFrame,
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

    final Uint8List rgba = renderer.renderFrame(sourceFrame);
    final ui.Image decoded = await _decodeRgba(rgba, width, height);

    _cachedSourceImage?.dispose();
    _cachedSourceImage = decoded;
    _cachedSource = source;
    _cachedSourceFrame = sourceFrame;
    return decoded;
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

    // DEFAULT preserves historical BAKE output: the lower-left MLT diagnostic
    // has always been a live-preview aid and was never encoded. CUSTOM is
    // explicit authored copy, so it belongs in the program and is baked.
    if (overlayMode == StructuralOverlayMode.custom &&
        renderedBottom.isNotEmpty &&
        client.width > 0.0 &&
        client.height > 0.0) {
      final TextPainter bottom = TextPainter(
        text: TextSpan(
          text: renderedBottom,
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
      rightX - (header.left + horizontalPad) -
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
          terminalOpacity = placement.chainedFromPrevious
              ? 0.0
              : 1.0 - eased;
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
        structuralRect = Rect.lerp(presentationRect, emergenceRect, eased)!;
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
