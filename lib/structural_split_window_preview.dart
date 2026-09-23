// ./lib/structural_split_window_preview.dart
//
// Live two-window MOSAIC preview surface.
//
// This widget owns one MediaLayer/EditVideoCompositor for both authored panes.
// Each pane therefore uses the compositor-level renderMosaicPaneAvailable path,
// preserving nested structural resolution and a shared decoder/cache lifetime.
// Window raster is delegated to structural_window_painter.dart, the same painter
// used by Program BAKE.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'card_overlay.dart';
import 'edit_model.dart';
import 'edit_video_compositor.dart';
import 'edit_video_preview.dart';
import 'media_layer.dart';
import 'mosaic_split_geometry.dart';
import 'project_clock.dart';
import 'structural_sequence.dart';
import 'structural_split_window_painter.dart';
import 'ui_theme.dart';

class StructuralSplitWindowPreview extends StatefulWidget {
  final String rawDocument;
  final StructuralSequencePlacement placement;
  final int sourceFrame;
  final R3Theme theme;
  final String fontFamily;
  final double chromeScale;
  final double entryProgress;
  final double? exitProgress;
  final bool moving;
  final bool closing;
  final bool preloadCloseFrame;
  final bool closeAsSurfaceTransform;
  final bool showSourceFrameProbe;

  /// Freeze the exact currently resident pane rasters.
  ///
  /// Closing choreography changes only geometry. If both pane images are
  /// already resident, no new source request is allowed while this is true.
  /// A direct scrub/mount into a held frame with no resident raster may render
  /// the requested frame once so the surface is not blank.
  final bool holdRaster;

  final MediaDecoderBackend? backend;
  final String Function(String source)? resolveSource;
  final VoidCallback? onFirstFrameReady;

  const StructuralSplitWindowPreview({
    super.key,
    required this.rawDocument,
    required this.placement,
    required this.sourceFrame,
    required this.theme,
    required this.fontFamily,
    required this.chromeScale,
    this.entryProgress = 1.0,
    this.exitProgress,
    required this.moving,
    this.closing = false,
    this.preloadCloseFrame = false,
    this.closeAsSurfaceTransform = false,
    this.showSourceFrameProbe = false,
    this.holdRaster = false,
    this.backend,
    this.resolveSource,
    this.onFirstFrameReady,
  });

  @override
  State<StructuralSplitWindowPreview> createState() =>
      _StructuralSplitWindowPreviewState();
}

class _StructuralSplitWindowPreviewState
    extends State<StructuralSplitWindowPreview> {
  static const int _movingDecodePixelBudget = 480 * 270;
  static const bool _verifyClosePreloadImage =
      bool.fromEnvironment('R3_SPLIT_PRELOAD_VERIFY');
  static const bool _paintOpaqueCloseProbe =
      bool.fromEnvironment('R3_SPLIT_CLOSE_OPAQUE_PROBE');
  static const bool _paintImageCloseProbe =
      bool.fromEnvironment('R3_SPLIT_CLOSE_IMAGE_PROBE');
  static const bool _paintRgbaCloseProbe =
      bool.fromEnvironment('R3_SPLIT_CLOSE_RGBA_PROBE');

  MediaLayer? _layer;
  EditVideoCompositor? _compositor;
  MediaLayer? _closePreloadLayer;
  EditVideoCompositor? _closePreloadCompositor;
  String? _runtimeDocument;
  String? _runtimeSource;
  MediaDecoderBackend? _ownedBackend;
  EditDocumentModel? _runtimeModel;
  CardOverlayImageCache? _cardImages;
  CardOverlayImageCache? _closePreloadCardImages;

  final List<ui.Image?> _images = <ui.Image?>[null, null];
  final List<ui.Image?> _closePreloadImages = <ui.Image?>[null, null];
  final List<String> _diagnosticLabels = <String>['', ''];
  ui.Image? _closeImageProbe;
  ui.Image? _closeRgbaProbe;
  ui.Size? _closeRgbaProbeSize;
  bool _closeRgbaProbeInFlight = false;

  ui.Size? _paneRenderSize;
  ui.Size? _closePreloadSize;
  int _serial = 0;
  int _closePreloadGeneration = 0;
  bool _renderScheduled = false;
  bool _closePreloadScheduled = false;
  bool _closePreloadInFlight = false;
  bool _readyReported = false;
  bool _closeBoundaryReported = false;

  void _reportRenderError(Object error, StackTrace stack, String phase) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'structural split window preview',
        context: ErrorDescription(phase),
      ),
    );
  }


  @override
  void initState() {
    super.initState();
    if (_paintImageCloseProbe) {
      unawaited(_createCloseImageProbe());
    }
    _scheduleRender();
  }

  Future<void> _createCloseImageProbe() async {
    const int size = 64;
    const int cells = 8;
    const double cell = size / cells;
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas canvas = ui.Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
      ui.Paint()..color = const Color(0xFFFF00FF),
    );
    for (int y = 0; y < cells; y++) {
      for (int x = 0; x < cells; x++) {
        if ((x + y).isEven) {
          canvas.drawRect(
            Rect.fromLTWH(x * cell, y * cell, cell, cell),
            ui.Paint()..color = const Color(0xFF00FF00),
          );
        }
      }
    }
    final ui.Picture picture = recorder.endRecording();
    try {
      final ui.Image image = await picture.toImage(size, size);
      if (!mounted) {
        image.dispose();
        return;
      }
      _closeImageProbe?.dispose();
      _closeImageProbe = image;
      setState(() {});
    } finally {
      picture.dispose();
    }
  }

  @override
  void didUpdateWidget(covariant StructuralSplitWindowPreview oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (!widget.closing && oldWidget.closing) {
      _closeBoundaryReported = false;
    }

    final bool runtimeChanged =
        oldWidget.rawDocument != widget.rawDocument ||
        oldWidget.placement.sourceRef.canonicalSource !=
            widget.placement.sourceRef.canonicalSource ||
        oldWidget.backend != widget.backend ||
        oldWidget.resolveSource != widget.resolveSource;

    if (runtimeChanged) {
      _disposeRuntime();
      _disposeClosePreload();
      _replaceImage(0, null);
      _replaceImage(1, null);
      _diagnosticLabels[0] = '';
      _diagnosticLabels[1] = '';
      _readyReported = false;
    }

    if (!runtimeChanged &&
        (oldWidget.preloadCloseFrame != widget.preloadCloseFrame ||
            oldWidget.chromeScale != widget.chromeScale ||
            oldWidget.fontFamily != widget.fontFamily ||
            oldWidget.placement.maximizeSplit !=
                widget.placement.maximizeSplit ||
            oldWidget.placement.splitClientAspect !=
                widget.placement.splitClientAspect)) {
      _resetClosePreload();
    }

    final bool hasResidentPair =
        _images[0] != null && _images[1] != null;

    if (widget.holdRaster && !runtimeChanged && hasResidentPair) {
      // Entering/remaining in closing choreography must preserve the exact
      // already-painted pane pair. Invalidate any async decode that started
      // during the final showing frame, then let only painter geometry update.
      _serial++;
      return;
    }

    if (runtimeChanged ||
        oldWidget.sourceFrame != widget.sourceFrame ||
        oldWidget.moving != widget.moving ||
        oldWidget.holdRaster != widget.holdRaster ||
        oldWidget.chromeScale != widget.chromeScale ||
        oldWidget.fontFamily != widget.fontFamily ||
        oldWidget.placement.maximizeSplit !=
            widget.placement.maximizeSplit ||
        oldWidget.placement.splitClientAspect !=
            widget.placement.splitClientAspect) {
      _serial++;
      _scheduleRender();
    }
  }

  @override
  void dispose() {
    _serial++;
    _disposeRuntime();
    _disposeClosePreload();
    _replaceImage(0, null);
    _replaceImage(1, null);
    _closeImageProbe?.dispose();
    _closeImageProbe = null;
    _closeRgbaProbe?.dispose();
    _closeRgbaProbe = null;
    _closeRgbaProbeSize = null;
    super.dispose();
  }

  void _disposeRuntime() {
    _compositor?.dispose();
    _compositor = null;
    _layer?.dispose();
    _layer = null;
    _runtimeDocument = null;
    _runtimeSource = null;
    _runtimeModel = null;
    _cardImages?.dispose();
    _cardImages = null;
  }

  void _disposeClosePreload() {
    _closePreloadGeneration++;
    _closePreloadScheduled = false;
    _closePreloadInFlight = false;
    _closePreloadCompositor?.dispose();
    _closePreloadCompositor = null;
    _closePreloadLayer?.dispose();
    _closePreloadLayer = null;
    _closePreloadCardImages?.dispose();
    _closePreloadCardImages = null;
    _closePreloadSize = null;
    for (int paneIndex = 0; paneIndex < 2; paneIndex++) {
      final ui.Image? image = _closePreloadImages[paneIndex];
      _closePreloadImages[paneIndex] = null;
      image?.dispose();
    }
  }

  void _resetClosePreload() {
    _disposeClosePreload();
    if (!widget.preloadCloseFrame) return;
    final ui.Size? size = _paneRenderSize;
    if (size != null) _scheduleClosePreload(size);
  }

  void _replaceClosePreloadImage(int paneIndex, ui.Image? next) {
    final ui.Image? old = _closePreloadImages[paneIndex];
    if (identical(old, next)) return;
    _closePreloadImages[paneIndex] = next;
    old?.dispose();
  }

  void _replaceImage(int paneIndex, ui.Image? next) {
    final ui.Image? old = _images[paneIndex];
    if (identical(old, next)) return;
    _images[paneIndex] = next;
    old?.dispose();
  }

  EditVideoCompositor _ensureCompositor() {
    final String source = widget.placement.sourceRef.canonicalSource;
    final MediaDecoderBackend backend =
        widget.backend ?? (_ownedBackend ??= NativeMltMediaBackend());
    final String Function(String source) resolver =
        widget.resolveSource ?? resolveWorkspaceMediaSource;

    final EditVideoCompositor? existing = _compositor;
    if (existing != null &&
        _runtimeDocument == widget.rawDocument &&
        _runtimeSource == source) {
      return existing;
    }

    _disposeRuntime();

    final EditDocumentModel model =
        EditDocumentModel.parse(widget.rawDocument);
    final StructuralSourceRef? selected = StructuralSourceRef.tryParse(source);
    if (selected == null ||
        selected.kind != StructuralSourceKind.mosaic ||
        selected.id.isEmpty ||
        !model.containsStructuralSource(selected)) {
      throw StateError(
        'Split preview requires a valid MOSAIC structural source: "$source".',
      );
    }

    final MediaLayer layer = MediaLayer(
      editDocument: model,
      backend: backend,
      resolveSource: resolver,
    );
    final EditVideoCompositor compositor = EditVideoCompositor.forModel(
      model: model,
      mediaLayer: layer,
      backend: backend,
      resolveSource: resolver,
    );

    _layer = layer;
    _compositor = compositor;
    _runtimeDocument = widget.rawDocument;
    _runtimeSource = source;
    _runtimeModel = model;
    _cardImages = CardOverlayImageCache(resolver);
    return compositor;
  }

  EditVideoCompositor _ensureClosePreloadCompositor() {
    final EditVideoCompositor? existing = _closePreloadCompositor;
    if (existing != null) return existing;

    final String source = widget.placement.sourceRef.canonicalSource;
    final MediaDecoderBackend backend =
        widget.backend ?? (_ownedBackend ??= NativeMltMediaBackend());
    final String Function(String source) resolver =
        widget.resolveSource ?? resolveWorkspaceMediaSource;
    final EditDocumentModel model =
        EditDocumentModel.parse(widget.rawDocument);

    final StructuralSourceRef? selected = StructuralSourceRef.tryParse(source);
    if (selected == null ||
        selected.kind != StructuralSourceKind.mosaic ||
        selected.id.isEmpty ||
        !model.containsStructuralSource(selected)) {
      throw StateError(
        'Split close preload requires a valid MOSAIC structural source: "$source".',
      );
    }

    final MediaLayer layer = MediaLayer(
      editDocument: model,
      backend: backend,
      resolveSource: resolver,
    );
    final EditVideoCompositor compositor = EditVideoCompositor.forModel(
      model: model,
      mediaLayer: layer,
      backend: backend,
      resolveSource: resolver,
    );

    _closePreloadLayer = layer;
    _closePreloadCompositor = compositor;
    _closePreloadCardImages = CardOverlayImageCache(resolver);
    return compositor;
  }

  void _scheduleClosePreload(ui.Size paneSize) {
    if (!widget.preloadCloseFrame) return;
    if (_closePreloadImages[0] != null &&
        _closePreloadImages[1] != null &&
        _closePreloadSize == paneSize) {
      return;
    }

    if (_closePreloadSize != null && _closePreloadSize != paneSize) {
      _disposeClosePreload();
    }
    _closePreloadSize = paneSize;

    if (_closePreloadScheduled || _closePreloadInFlight) return;
    _closePreloadScheduled = true;
    final int generation = _closePreloadGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _closePreloadScheduled = false;
      if (!mounted ||
          generation != _closePreloadGeneration ||
          !widget.preloadCloseFrame) {
        return;
      }
      _closePreloadInFlight = true;
      unawaited(_preloadCloseFrame(paneSize, generation));
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _preloadCloseFrame(
    ui.Size paneSize,
    int generation,
  ) async {
    try {
      await _preloadCloseFrameOnce(paneSize, generation);
    } finally {
      if (generation == _closePreloadGeneration) {
        _closePreloadInFlight = false;
      }
    }
  }

  Future<void> _preloadCloseFrameOnce(
    ui.Size paneSize,
    int generation,
  ) async {
    final EditVideoCompositor compositor;
    try {
      compositor = _ensureClosePreloadCompositor();
    } catch (error, stack) {
      if (!mounted || generation != _closePreloadGeneration) return;
      _reportRenderError(
        error,
        stack,
        'while creating the isolated split close preload compositor',
      );
      return;
    }

    final String source = widget.placement.sourceRef.canonicalSource;
    final int finalSourceFrame =
        math.max(0, widget.placement.sourceDurationFrames - 1);
    final ProjectTime time = ProjectTime(
      frame: finalSourceFrame,
      mode: ProjectClockMode.scrub,
    );
    final List<EditVideoCompositeResult> results =
        <EditVideoCompositeResult>[];

    try {
      for (int paneIndex = 0; paneIndex < 2; paneIndex++) {
        results.add(
          compositor.renderMosaicPaneAvailable(
            source,
            paneIndex,
            time,
            paneSize,
          ),
        );
      }
    } catch (error, stack) {
      if (!mounted || generation != _closePreloadGeneration) return;
      _reportRenderError(
        error,
        stack,
        'while preloading the final split close frame',
      );
      return;
    }

    if (!mounted || generation != _closePreloadGeneration) return;

    if (results.any((EditVideoCompositeResult result) => result.hasPending) ||
        results.any((EditVideoCompositeResult result) => result.rgba == null)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            generation != _closePreloadGeneration ||
            !widget.preloadCloseFrame) {
          return;
        }
        _closePreloadInFlight = false;
        _scheduleClosePreload(paneSize);
      });
      return;
    }

    final List<ui.Image?> decoded = <ui.Image?>[null, null];
    try {
      for (int paneIndex = 0; paneIndex < 2; paneIndex++) {
        final EditVideoCompositeResult result = results[paneIndex];
        decoded[paneIndex] = await _decodeRgba(
          result.rgba!,
          result.width,
          result.height,
          result.stride,
        );
      }

      final EditDocumentModel model =
          EditDocumentModel.parse(widget.rawDocument);
      final StructuralSourceRef root =
          StructuralSourceRef.tryParse(source)!;
      final CardOverlayImageCache? cardImages = _closePreloadCardImages;
      if (cardImages != null) {
        for (int paneIndex = 0; paneIndex < 2; paneIndex++) {
          final ui.Image? base = decoded[paneIndex];
          if (base == null) continue;
          final List<StructuralCardOverlayPlacement> overlays =
              structuralCardOverlayPlacementsForMosaicPane(
            model,
            root,
            paneIndex,
            finalSourceFrame,
          )
                  .where(
                    (StructuralCardOverlayPlacement placement) =>
                        !placement.isSideCard,
                  )
                  .toList(growable: false);
          final ui.Image? composited =
              await compositeStructuralCardOverlaysToImage(
            structuralImage: base,
            placements: overlays,
            images: cardImages,
            fontFamily: widget.fontFamily,
          );
          if (composited != null) {
            base.dispose();
            decoded[paneIndex] = composited;
          }
        }
      }

      // Detach the exact final pane pixels from the decode-backed image
      // resource. Closing paints only these independently rasterized images.
      for (int paneIndex = 0; paneIndex < 2; paneIndex++) {
        final ui.Image? base = decoded[paneIndex];
        if (base == null) continue;
        final ui.Image detached = await _detachImage(base);
        base.dispose();
        decoded[paneIndex] = detached;
      }
    } catch (error, stack) {
      for (final ui.Image? image in decoded) {
        image?.dispose();
      }
      if (!mounted || generation != _closePreloadGeneration) return;
      _reportRenderError(
        error,
        stack,
        'while decoding the isolated split close preload',
      );
      return;
    }

    if (!mounted || generation != _closePreloadGeneration) {
      for (final ui.Image? image in decoded) {
        image?.dispose();
      }
      return;
    }

    if (_closePreloadImages[0] != null && _closePreloadImages[1] != null) {
      for (final ui.Image? image in decoded) {
        image?.dispose();
      }
      return;
    }

    _replaceClosePreloadImage(0, decoded[0]);
    _replaceClosePreloadImage(1, decoded[1]);
    _closePreloadSize = paneSize;

    String imageSig0 = 'disabled';
    String imageSig1 = 'disabled';
    if (_verifyClosePreloadImage) {
      imageSig0 = await _imageSignature(_closePreloadImages[0]);
      imageSig1 = await _imageSignature(_closePreloadImages[1]);
      if (!mounted || generation != _closePreloadGeneration) return;
    }

    debugPrint(
      '[split-close-preload] READY '
      'sf=$finalSourceFrame '
      'sig0=${_rgbaSignature(results[0].rgba)} '
      'sig1=${_rgbaSignature(results[1].rgba)} '
      'imageSig0=$imageSig0 '
      'imageSig1=$imageSig1 '
      'leaf0=${_leafFrameSummary(results[0])} '
      'leaf1=${_leafFrameSummary(results[1])}',
    );
    if (mounted) setState(() {});
  }

  void _scheduleRgbaCloseProbe(ui.Size paneSize) {
    if (!_paintRgbaCloseProbe || _closeRgbaProbeInFlight) return;
    if (_closeRgbaProbe != null && _closeRgbaProbeSize == paneSize) return;

    _closeRgbaProbeInFlight = true;
    unawaited(_createRgbaCloseProbe(paneSize));
  }

  Future<void> _createRgbaCloseProbe(ui.Size paneSize) async {
    final int width =
        paneSize.width.round().clamp(1, 1 << 30).toInt();
    final int height =
        paneSize.height.round().clamp(1, 1 << 30).toInt();
    final Uint8List rgba = Uint8List(width * height * 4);
    const int cell = 24;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final bool green = ((x ~/ cell) + (y ~/ cell)).isEven;
        final int offset = (y * width + x) * 4;
        rgba[offset] = green ? 0 : 255;
        rgba[offset + 1] = green ? 255 : 0;
        rgba[offset + 2] = green ? 0 : 255;
        rgba[offset + 3] = 255;
      }
    }

    ui.Image? image;
    try {
      image = await _decodeRgba(
        rgba,
        width,
        height,
        width * 4,
      );
      if (!mounted) {
        image.dispose();
        return;
      }

      _closeRgbaProbe?.dispose();
      _closeRgbaProbe = image;
      _closeRgbaProbeSize = paneSize;
      image = null;
      setState(() {});
    } finally {
      image?.dispose();
      _closeRgbaProbeInFlight = false;
    }
  }

  void _scheduleRender() {
    if (_renderScheduled) return;
    _renderScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _renderScheduled = false;
      if (!mounted) return;
      if (widget.holdRaster && _images[0] != null && _images[1] != null) {
        return;
      }
      final ui.Size? size = _paneRenderSize;
      if (size == null || size.width <= 0.0 || size.height <= 0.0) {
        return;
      }
      _render(size);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _render(ui.Size paneSize) async {
    if (widget.holdRaster && _images[0] != null && _images[1] != null) {
      return;
    }

    final int serial = ++_serial;
    final EditVideoCompositor compositor;
    try {
      compositor = _ensureCompositor();
    } catch (error, stack) {
      if (!mounted || serial != _serial) return;
      _reportRenderError(
        error,
        stack,
        'while creating the split-window compositor',
      );
      if (!_readyReported) {
        _readyReported = true;
        widget.onFirstFrameReady?.call();
      }
      return;
    }

    final String source = widget.placement.sourceRef.canonicalSource;
    final List<EditVideoCompositeResult> results =
        <EditVideoCompositeResult>[];

    try {
      for (int paneIndex = 0; paneIndex < 2; paneIndex++) {
        final bool moving = widget.moving && !widget.holdRaster;
        final ProjectTime time = ProjectTime(
          frame: widget.sourceFrame,
          mode: moving
              ? ProjectClockMode.monotonic
              : ProjectClockMode.scrub,
        );
        results.add(
          moving
              ? compositor.renderMosaicPaneAvailable(
                  source,
                  paneIndex,
                  time,
                  paneSize,
                )
              : compositor.renderMosaicPane(
                  source,
                  paneIndex,
                  time,
                  paneSize,
                ),
        );
      }
    } catch (error, stack) {
      if (!mounted || serial != _serial) return;
      _reportRenderError(
        error,
        stack,
        'while compositing split-window panes',
      );
      if (!_readyReported) {
        _readyReported = true;
        widget.onFirstFrameReady?.call();
      }
      return;
    }

    if (!mounted || serial != _serial) return;

    if (results.any((EditVideoCompositeResult result) => result.hasPending)) {
      // Native/nonblocking decoders may remain pending while authored opening
      // geometry advances without changing sourceFrame. Poll again through the
      // existing coalesced scheduler instead of waiting for a widget/source
      // update that may not occur until the opening budget has already ended.
      //
      // This retries presentation readiness only. It does not advance project
      // time, source time, or restart entry progress, and the pair remains
      // hidden until both panes resolve.
      _scheduleRender();
      return;
    }

    for (int paneIndex = 0; paneIndex < 2; paneIndex++) {
      final EditVideoCompositeResult result = results[paneIndex];
      if (result.rgba == null &&
          result.mediaFrames.any((MediaFrame frame) => frame.isDecoded)) {
        _reportRenderError(
          StateError(
            'Pane ${paneIndex + 1} had decoded media frames but no composed '
            'RGBA at source frame ${widget.sourceFrame}.',
          ),
          StackTrace.current,
          'while validating split-window compositor output',
        );
      }
    }

    final List<ui.Image?> decoded = <ui.Image?>[null, null];
    try {
      for (int paneIndex = 0; paneIndex < 2; paneIndex++) {
        final EditVideoCompositeResult result = results[paneIndex];
        final Uint8List? rgba = result.rgba;
        if (rgba != null) {
          decoded[paneIndex] = await _decodeRgba(
            rgba,
            result.width,
            result.height,
            result.stride,
          );
        }
      }
    } catch (error, stack) {
      for (final ui.Image? image in decoded) {
        image?.dispose();
      }
      if (!mounted || serial != _serial) return;
      _reportRenderError(
        error,
        stack,
        'while converting split-window RGBA to ui.Image',
      );
      if (!_readyReported) {
        _readyReported = true;
        widget.onFirstFrameReady?.call();
      }
      return;
    }

    if (!mounted || serial != _serial) {
      for (final ui.Image? image in decoded) {
        image?.dispose();
      }
      return;
    }

    final EditDocumentModel? model = _runtimeModel;
    final CardOverlayImageCache? cardImages = _cardImages;
    final StructuralSourceRef? root = StructuralSourceRef.tryParse(source);
    if (model != null &&
        cardImages != null &&
        root != null &&
        root.kind == StructuralSourceKind.mosaic &&
        root.id.isNotEmpty &&
        model.containsStructuralSource(root)) {
      for (int paneIndex = 0; paneIndex < 2; paneIndex++) {
        final ui.Image? base = decoded[paneIndex];
        if (base == null) continue;
        final List<StructuralCardOverlayPlacement> overlays =
            structuralCardOverlayPlacementsForMosaicPane(
          model,
          root,
          paneIndex,
          widget.sourceFrame,
        )
                .where(
                  (StructuralCardOverlayPlacement placement) =>
                      !placement.isSideCard,
                )
                .toList(growable: false);
        final ui.Image? composited =
            await compositeStructuralCardOverlaysToImage(
          structuralImage: base,
          placements: overlays,
          images: cardImages,
          fontFamily: widget.fontFamily,
        );
        if (composited != null) {
          base.dispose();
          decoded[paneIndex] = composited;
        }
      }
    }

    if (!mounted || serial != _serial) {
      for (final ui.Image? image in decoded) {
        image?.dispose();
      }
      return;
    }

    for (int paneIndex = 0; paneIndex < 2; paneIndex++) {
      _replaceImage(paneIndex, decoded[paneIndex]);
      _diagnosticLabels[paneIndex] =
          _diagnosticLabel(results[paneIndex], paneIndex);
    }

    final int tailStart = math.max(
      0,
      widget.placement.sourceDurationFrames - 6,
    );
    if (widget.sourceFrame >= tailStart) {
      debugPrint(
        '[split-boundary] PRESENT '
        'closing=${widget.closing} '
        'sf=${widget.sourceFrame} '
        'sig0=${_rgbaSignature(results[0].rgba)} '
        'sig1=${_rgbaSignature(results[1].rgba)} '
        'leaf0=${_leafFrameSummary(results[0])} '
        'leaf1=${_leafFrameSummary(results[1])} '
        'img0=${_images[0] == null ? "null" : identityHashCode(_images[0])} '
        'img1=${_images[1] == null ? "null" : identityHashCode(_images[1])}',
      );
    }

    if (mounted) {
      setState(() {});
    }

    if (!_readyReported) {
      _readyReported = true;
      widget.onFirstFrameReady?.call();
    }
  }

  Future<ui.Image> _detachImage(ui.Image source) async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas canvas = ui.Canvas(recorder);
    canvas.drawImage(source, ui.Offset.zero, ui.Paint());
    final ui.Picture picture = recorder.endRecording();
    try {
      return await picture.toImage(source.width, source.height);
    } finally {
      picture.dispose();
    }
  }

  Future<String> _imageSignature(ui.Image? image) async {
    if (image == null) return 'null';
    final ByteData? data =
        await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return 'null';
    return _rgbaSignature(data.buffer.asUint8List());
  }

  String _rgbaSignature(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) return 'null';
    int hash = 0x811C9DC5;
    for (final int byte in bytes) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  String _leafFrameSummary(EditVideoCompositeResult result) {
    final List<String> leaves = result.mediaFrames
        .where((MediaFrame frame) => frame.isDecoded)
        .map(
          (MediaFrame frame) =>
              '${frame.source}:${frame.requestedSourceFrame}/'
              '${frame.actualSourceFrame ?? -1}',
        )
        .toList(growable: false);
    return leaves.isEmpty ? 'none' : leaves.join(',');
  }

  String _diagnosticLabel(
    EditVideoCompositeResult result,
    int paneIndex,
  ) {
    final MediaFrame? frame = result.topFrame;
    if (frame == null) return '';
    final String source = frame.source.trim();
    if (source.isEmpty) return 'PANE ${paneIndex + 1}';
    return source;
  }

  ui.Size _decodePaneSize(
    ui.Size displaySize, {
    required bool moving,
  }) {
    if (!moving) return displaySize;

    final double pixels = displaySize.width * displaySize.height;
    if (pixels <= _movingDecodePixelBudget) return displaySize;

    final double scale =
        math.sqrt(_movingDecodePixelBudget / pixels);
    return ui.Size(
      math.max(1, (displaySize.width * scale).round()).toDouble(),
      math.max(1, (displaySize.height * scale).round()).toDouble(),
    );
  }

  Future<ui.Image> _decodeRgba(
    Uint8List rgba,
    int width,
    int height,
    int stride,
  ) {
    final Completer<ui.Image> completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
      rowBytes: stride,
    );
    return completer.future;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 0.0;
        final double height =
            constraints.maxHeight.isFinite ? constraints.maxHeight : 0.0;

        if (width <= 0.0 || height <= 0.0) {
          return const SizedBox.shrink();
        }

        final MosaicSplitWindowGeometry geometry =
            mosaicSplitWindowGeometry(
          frame: Rect.fromLTWH(0, 0, width, height),
          aspect: widget.placement.splitClientAspect,
          titleHeight: 38.0 * widget.chromeScale,
          maximized: widget.placement.maximizeSplit,
        );
        final ui.Size displayPaneSize = ui.Size(
          geometry.clientSize.width.round().clamp(1, 1 << 30).toDouble(),
          geometry.clientSize.height.round().clamp(1, 1 << 30).toDouble(),
        );
        final bool hasResidentPair =
            _images[0] != null && _images[1] != null;
        final bool freezeResidentRaster =
            widget.holdRaster && hasResidentPair && _paneRenderSize != null;
        final bool moving = widget.moving && !widget.holdRaster;
        final ui.Size nextPaneSize = freezeResidentRaster
            ? _paneRenderSize!
            : _decodePaneSize(displayPaneSize, moving: moving);

        if (_paneRenderSize != nextPaneSize) {
          _paneRenderSize = nextPaneSize;
          _serial++;
          _scheduleRender();
        }

        if (widget.preloadCloseFrame) {
          _scheduleClosePreload(nextPaneSize);
        }
        if (_paintRgbaCloseProbe) {
          _scheduleRgbaCloseProbe(nextPaneSize);
        }

        final bool closePreloadReady =
            _closePreloadImages[0] != null &&
            _closePreloadImages[1] != null &&
            _closePreloadSize == nextPaneSize;
        final List<ui.Image?> paintImages =
            widget.closing && closePreloadReady
                ? _closePreloadImages
                : _images;

        if (widget.closing && !_closeBoundaryReported) {
          _closeBoundaryReported = true;
          debugPrint(
            '[split-boundary] CLOSE_ENTER '
            'sf=${widget.sourceFrame} '
            'entry=${widget.entryProgress.toStringAsFixed(6)} '
            'using=${closePreloadReady ? "PRELOAD" : "LIVE"} '
            'img0=${paintImages[0] == null ? "null" : identityHashCode(paintImages[0])} '
            'img1=${paintImages[1] == null ? "null" : identityHashCode(paintImages[1])}',
          );
        }

        return RepaintBoundary(
          key: const ValueKey<String>('structural-split-raster'),
          child: CustomPaint(
            key: const ValueKey<String>('structural-split-window-frame'),
            painter: StructuralSplitWindowPainter(
              geometry: geometry,
              placement: widget.placement,
              sourceFrame: widget.sourceFrame,
              theme: widget.theme,
              fontFamily: widget.fontFamily,
              chromeScale: widget.chromeScale,
              images: List<ui.Image?>.unmodifiable(paintImages),
              diagnosticLabels:
                  List<String>.unmodifiable(_diagnosticLabels),
              entryProgress: widget.entryProgress,
              exitProgress: widget.exitProgress,
              showSourceFrameProbe: widget.showSourceFrameProbe,
              closeAsSurfaceTransform: widget.closeAsSurfaceTransform,
              paintOpaqueCloseProbe:
                  widget.closing && _paintOpaqueCloseProbe,
              closeImageProbe:
                  widget.closing && _paintRgbaCloseProbe
                      ? _closeRgbaProbe
                      : widget.closing && _paintImageCloseProbe
                          ? _closeImageProbe
                          : null,
            ),
            child: const SizedBox.expand(),
          ),
        );
      },
    );
  }
}

