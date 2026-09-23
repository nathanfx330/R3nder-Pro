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

  /// During close, paint detached copies of the final resident pane images.
  /// This removes the live video image resources from the animated exit path.
  final bool useCloseSnapshot;

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
    this.useCloseSnapshot = false,
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

  MediaLayer? _layer;
  EditVideoCompositor? _compositor;
  String? _runtimeDocument;
  String? _runtimeSource;
  MediaDecoderBackend? _ownedBackend;
  EditDocumentModel? _runtimeModel;
  CardOverlayImageCache? _cardImages;

  final List<ui.Image?> _images = <ui.Image?>[null, null];
  final List<ui.Image?> _closeSnapshots = <ui.Image?>[null, null];
  final List<String> _diagnosticLabels = <String>['', ''];

  ui.Size? _paneRenderSize;
  int _serial = 0;
  bool _renderScheduled = false;
  bool _readyReported = false;

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
    _scheduleRender();
  }

  @override
  void didUpdateWidget(covariant StructuralSplitWindowPreview oldWidget) {
    super.didUpdateWidget(oldWidget);

    final bool runtimeChanged =
        oldWidget.rawDocument != widget.rawDocument ||
        oldWidget.placement.sourceRef.canonicalSource !=
            widget.placement.sourceRef.canonicalSource ||
        oldWidget.backend != widget.backend ||
        oldWidget.resolveSource != widget.resolveSource;

    if (runtimeChanged) {
      _disposeRuntime();
      _replaceImage(0, null);
      _replaceImage(1, null);
      _replaceCloseSnapshot(0, null);
      _replaceCloseSnapshot(1, null);
      _diagnosticLabels[0] = '';
      _diagnosticLabels[1] = '';
      _readyReported = false;
    }

    final int finalSourceFrame =
        math.max(0, widget.placement.sourceDurationFrames - 1);
    if (oldWidget.sourceFrame == finalSourceFrame &&
        widget.sourceFrame != finalSourceFrame) {
      _replaceCloseSnapshot(0, null);
      _replaceCloseSnapshot(1, null);
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
    _replaceImage(0, null);
    _replaceImage(1, null);
    _replaceCloseSnapshot(0, null);
    _replaceCloseSnapshot(1, null);
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

  void _replaceImage(int paneIndex, ui.Image? next) {
    final ui.Image? old = _images[paneIndex];
    if (identical(old, next)) return;
    _images[paneIndex] = next;
    old?.dispose();
  }

  void _replaceCloseSnapshot(int paneIndex, ui.Image? next) {
    final ui.Image? old = _closeSnapshots[paneIndex];
    if (identical(old, next)) return;
    _closeSnapshots[paneIndex] = next;
    old?.dispose();
  }

  Future<ui.Image> _detachImage(ui.Image source) async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    final Rect bounds = Rect.fromLTWH(
      0.0,
      0.0,
      source.width.toDouble(),
      source.height.toDouble(),
    );
    canvas.drawImageRect(
      source,
      bounds,
      bounds,
      Paint()..filterQuality = FilterQuality.low,
    );
    final ui.Picture picture = recorder.endRecording();
    try {
      return await picture.toImage(source.width, source.height);
    } finally {
      picture.dispose();
    }
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

    final bool finalSourceFrame =
        widget.sourceFrame ==
            math.max(0, widget.placement.sourceDurationFrames - 1);
    if (finalSourceFrame &&
        (_closeSnapshots[0] == null || _closeSnapshots[1] == null)) {
      final List<ui.Image?> detached = <ui.Image?>[null, null];
      try {
        for (int paneIndex = 0; paneIndex < 2; paneIndex++) {
          final ui.Image? image = decoded[paneIndex];
          if (image != null) {
            detached[paneIndex] = await _detachImage(image);
          }
        }
      } catch (error, stack) {
        for (final ui.Image? image in detached) {
          image?.dispose();
        }
        if (mounted && serial == _serial) {
          _reportRenderError(
            error,
            stack,
            'while detaching final split pane snapshots',
          );
        }
      }

      if (!mounted || serial != _serial) {
        for (final ui.Image? image in detached) {
          image?.dispose();
        }
      } else if (detached[0] != null && detached[1] != null) {
        _replaceCloseSnapshot(0, detached[0]);
        _replaceCloseSnapshot(1, detached[1]);
      } else {
        for (final ui.Image? image in detached) {
          image?.dispose();
        }
      }
    }

    for (int paneIndex = 0; paneIndex < 2; paneIndex++) {
      _replaceImage(paneIndex, decoded[paneIndex]);
      _diagnosticLabels[paneIndex] =
          _diagnosticLabel(results[paneIndex], paneIndex);
    }

    if (mounted) {
      setState(() {});
    }

    if (!_readyReported) {
      _readyReported = true;
      widget.onFirstFrameReady?.call();
    }
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

        final bool useDetachedClose =
            widget.useCloseSnapshot &&
            _closeSnapshots[0] != null &&
            _closeSnapshots[1] != null;
        final List<ui.Image?> paintImages = useDetachedClose
            ? _closeSnapshots
            : _images;

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
            ),
            child: const SizedBox.expand(),
          ),
        );
      },
    );
  }
}

