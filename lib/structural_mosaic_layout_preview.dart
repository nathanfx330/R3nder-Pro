// ./lib/structural_mosaic_layout_preview.dart
//
// Live frame-dependent MOSAIC layout preview.
//
// MosaicLayoutProgram owns authored source-time layout semantics. This widget
// owns only Preview residency: one persistent compositor, actor image caches,
// and future-pane lookahead. Layout timing never waits on decode readiness.
// The outer STRUCT stage composes around the exact evaluated MOSAIC frame.

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
import 'mosaic_layout_program.dart';
import 'project_clock.dart';
import 'structural_mosaic_layout.dart';
import 'structural_sequence.dart';
import 'structural_window_actor_painter.dart';
import 'ui_theme.dart';

class StructuralMosaicLayoutPreview extends StatefulWidget {
  final String rawDocument;
  final StructuralSequencePlacement placement;
  final MosaicLayoutProgram program;
  final int sourceFrame;
  final StructuralSequenceStage stage;
  final double stageProgress;
  final double shellOpacity;
  final R3Theme theme;
  final String fontFamily;
  final double chromeScale;
  final bool moving;
  final MediaDecoderBackend? backend;
  final String Function(String source)? resolveSource;
  final VoidCallback? onFirstFrameReady;

  const StructuralMosaicLayoutPreview({
    super.key,
    required this.rawDocument,
    required this.placement,
    required this.program,
    required this.sourceFrame,
    required this.stage,
    required this.stageProgress,
    required this.shellOpacity,
    required this.theme,
    required this.fontFamily,
    required this.chromeScale,
    required this.moving,
    this.backend,
    this.resolveSource,
    this.onFirstFrameReady,
  });

  @override
  State<StructuralMosaicLayoutPreview> createState() =>
      _StructuralMosaicLayoutPreviewState();
}

class _StructuralMosaicLayoutPreviewState
    extends State<StructuralMosaicLayoutPreview> {
  static const int _movingDecodePixelBudget = 480 * 270;
  static const int _lookAheadFrames = 24;

  MediaLayer? _layer;
  EditVideoCompositor? _compositor;
  EditDocumentModel? _runtimeModel;
  CardOverlayImageCache? _cardImages;
  MediaDecoderBackend? _ownedBackend;
  String? _runtimeDocument;
  String? _runtimeSource;

  MosaicResolvedLayoutProgram? _resolved;
  MosaicLayoutEvaluationContext? _resolvedContext;

  final Map<MosaicLayoutActorId, ui.Image?> _images =
      <MosaicLayoutActorId, ui.Image?>{};
  final Map<MosaicLayoutActorId, int> _imageFrames =
      <MosaicLayoutActorId, int>{};
  final Map<MosaicLayoutActorId, String> _diagnosticLabels =
      <MosaicLayoutActorId, String>{};

  ui.Size? _programRenderSize;
  MosaicLayoutFrame? _currentLayoutFrame;
  int _serial = 0;
  bool _renderScheduled = false;
  bool _readyReported = false;

  @override
  void initState() {
    super.initState();
    _scheduleRender();
  }

  @override
  void didUpdateWidget(covariant StructuralMosaicLayoutPreview oldWidget) {
    super.didUpdateWidget(oldWidget);

    final bool runtimeChanged =
        oldWidget.rawDocument != widget.rawDocument ||
        oldWidget.placement.sourceRef.canonicalSource !=
            widget.placement.sourceRef.canonicalSource ||
        oldWidget.backend != widget.backend ||
        oldWidget.resolveSource != widget.resolveSource;

    final bool programChanged =
        oldWidget.program != widget.program ||
        oldWidget.placement.fullscreen != widget.placement.fullscreen ||
        oldWidget.placement.splitWindow != widget.placement.splitWindow ||
        oldWidget.placement.maximizeSplit != widget.placement.maximizeSplit ||
        oldWidget.placement.splitClientAspect !=
            widget.placement.splitClientAspect;

    if (runtimeChanged) {
      _disposeRuntime();
      _clearImages();
      _readyReported = false;
    }
    if (runtimeChanged || programChanged) {
      _resolved = null;
      _resolvedContext = null;
    }

    if (runtimeChanged ||
        programChanged ||
        oldWidget.sourceFrame != widget.sourceFrame ||
        oldWidget.moving != widget.moving ||
        oldWidget.chromeScale != widget.chromeScale ||
        oldWidget.fontFamily != widget.fontFamily) {
      _serial++;
      _scheduleRender();
    }
  }

  @override
  void dispose() {
    _serial++;
    _disposeRuntime();
    _clearImages();
    super.dispose();
  }

  void _disposeRuntime() {
    _compositor?.dispose();
    _compositor = null;
    _layer?.dispose();
    _layer = null;
    _runtimeModel = null;
    _runtimeDocument = null;
    _runtimeSource = null;
    _cardImages?.dispose();
    _cardImages = null;
  }

  void _clearImages() {
    for (final ui.Image? image in _images.values) {
      image?.dispose();
    }
    _images.clear();
    _imageFrames.clear();
    _diagnosticLabels.clear();
  }

  void _evictImage(MosaicLayoutActorId actorId) {
    final ui.Image? image = _images.remove(actorId);
    image?.dispose();
    _imageFrames.remove(actorId);
    _diagnosticLabels.remove(actorId);
  }

  void _evictUnrequestedHiddenImages({
    required Set<MosaicLayoutActorId> visibleIds,
    required Set<MosaicLayoutActorId> requestedIds,
  }) {
    final List<MosaicLayoutActorId> cachedIds =
        _images.keys.toList(growable: false);
    for (final MosaicLayoutActorId actorId in cachedIds) {
      if (!visibleIds.contains(actorId) && !requestedIds.contains(actorId)) {
        _evictImage(actorId);
      }
    }
  }

  ui.Image? _residentImageFor(MosaicLayoutActorId actorId) {
    final ui.Image? image = _images[actorId];
    final int? residentFrame = _imageFrames[actorId];
    if (image == null || residentFrame == null) return null;
    if (residentFrame == widget.sourceFrame) return image;

    // Resident hold is tied to one continuous authored visibility run, not to
    // a frame-age budget. A decoder may legitimately lag several frames under
    // load; painting black during that lag is worse than holding the last good
    // picture. Hidden/recalled actors remain safe because the resolved layout
    // records every inclusion change, including intervals skipped by a direct
    // scrub or playback jump.
    final MosaicResolvedLayoutProgram? resolved = _resolved;
    if (resolved == null ||
        !resolved.actorStayedIncludedAcross(
          actorId,
          frameA: residentFrame,
          frameB: widget.sourceFrame,
        )) {
      return null;
    }
    return image;
  }

  void _replaceImage(
    MosaicLayoutActorId actorId,
    ui.Image? next,
    int sourceFrame,
  ) {
    final ui.Image? old = _images[actorId];
    if (!identical(old, next)) {
      _images[actorId] = next;
      old?.dispose();
    }
    _imageFrames[actorId] = sourceFrame;
  }

  void _reportRenderError(Object error, StackTrace stack, String phase) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'structural mosaic layout preview',
        context: ErrorDescription(phase),
      ),
    );
  }

  EditVideoCompositor _ensureCompositor() {
    final String source = widget.placement.sourceRef.canonicalSource;
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
        'MOSAIC layout Preview requires a valid MOSAIC source: "$source".',
      );
    }

    final MediaDecoderBackend backend =
        widget.backend ?? (_ownedBackend ??= NativeMltMediaBackend());
    final String Function(String source) resolver =
        widget.resolveSource ?? resolveWorkspaceMediaSource;
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
    _runtimeModel = model;
    _runtimeDocument = widget.rawDocument;
    _runtimeSource = source;
    _cardImages = CardOverlayImageCache(resolver);
    return compositor;
  }

  MosaicResolvedLayoutProgram _ensureResolved(ui.Size size) {
    final MosaicLayoutEvaluationContext context =
        structuralMosaicLayoutContext(
      programRect: Rect.fromLTWH(0, 0, size.width, size.height),
      placement: widget.placement,
      program: widget.program,
      chromeScale: widget.chromeScale,
    );

    final MosaicResolvedLayoutProgram? existing = _resolved;
    if (existing != null && _resolvedContext == context) return existing;

    final MosaicResolvedLayoutProgram resolved = widget.program.resolve(context);
    _resolved = resolved;
    _resolvedContext = context;
    return resolved;
  }

  void _scheduleRender() {
    if (_renderScheduled) return;
    _renderScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _renderScheduled = false;
      if (!mounted) return;
      final ui.Size? size = _programRenderSize;
      if (size == null || size.width <= 0.0 || size.height <= 0.0) return;
      _render(size);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _render(ui.Size size) async {
    final int serial = ++_serial;
    final EditVideoCompositor compositor;
    final MosaicResolvedLayoutProgram resolved;
    try {
      compositor = _ensureCompositor();
      resolved = _ensureResolved(size);
    } catch (error, stack) {
      if (!mounted || serial != _serial) return;
      _reportRenderError(error, stack, 'while creating layout Preview runtime');
      _reportReady();
      return;
    }

    final int sourceFrame = widget.sourceFrame;
    final MosaicLayoutFrame layoutFrame = resolved.evaluate(sourceFrame);
    final Set<MosaicLayoutActorId> visibleIds = layoutFrame.paintActors
        .map((MosaicLayoutActorFrame actor) => actor.actorId)
        .toSet();
    final Set<MosaicLayoutActorId> requestedIds =
        <MosaicLayoutActorId>{...visibleIds};

    if (widget.moving && widget.program.projectFrameCount > 0) {
      final int throughFrame = math.min(
        widget.program.projectFrameCount - 1,
        sourceFrame + _lookAheadFrames,
      );
      final Set<String> returning = resolved.paneIdsEnteringBetween(
        afterFrame: sourceFrame,
        throughFrame: throughFrame,
      );
      for (final String paneId in returning) {
        final int ordinal = widget.program.paneIds.indexOf(paneId);
        if (ordinal >= 0) {
          requestedIds.add(MosaicLayoutActorId.pane(paneId, ordinal + 1));
        }
      }
    }

    final String source = widget.placement.sourceRef.canonicalSource;
    final ProjectTime time = ProjectTime(
      frame: sourceFrame,
      mode: widget.moving
          ? ProjectClockMode.monotonic
          : ProjectClockMode.scrub,
    );

    bool retryPending = false;
    for (final MosaicLayoutActorId actorId in requestedIds) {
      if (!mounted || serial != _serial) return;

      final MosaicLayoutActorFrame? currentActor =
          _actorFromFrame(layoutFrame, actorId);
      final MosaicLayoutActorFrame sizingActor = currentActor ??
          _lookAheadActor(
            resolved: resolved,
            actorId: actorId,
            sourceFrame: sourceFrame,
          );
      final ui.Size decodeSize = _decodeSizeForActor(
        sizingActor,
        moving: widget.moving,
      );

      final EditVideoCompositeResult result;
      try {
        if (actorId.kind == MosaicLayoutActorKind.composite) {
          result = widget.moving
              ? compositor.renderSourceAvailable(source, time, decodeSize)
              : compositor.renderSource(source, time, decodeSize);
        } else {
          final int paneIndex =
              widget.program.paneIds.indexOf(actorId.paneId!);
          if (paneIndex < 0) continue;
          result = widget.moving
              ? compositor.renderMosaicPaneAvailable(
                  source,
                  paneIndex,
                  time,
                  decodeSize,
                )
              : compositor.renderMosaicPane(
                  source,
                  paneIndex,
                  time,
                  decodeSize,
                );
        }
      } catch (error, stack) {
        if (!mounted || serial != _serial) return;
        _reportRenderError(error, stack, 'while compositing layout actor');
        if (visibleIds.contains(actorId)) {
          _replaceImage(actorId, null, sourceFrame);
        }
        continue;
      }

      if (result.hasPending) {
        retryPending = true;
        continue;
      }

      ui.Image? decoded;
      final Uint8List? rgba = result.rgba;
      if (rgba != null) {
        try {
          decoded = await _decodeRgba(
            rgba,
            result.width,
            result.height,
            result.stride,
          );
        } catch (error, stack) {
          if (!mounted || serial != _serial) return;
          _reportRenderError(
            error,
            stack,
            'while converting layout actor RGBA to ui.Image',
          );
        }
      }

      if (!mounted || serial != _serial) {
        decoded?.dispose();
        return;
      }

      if (decoded != null) {
        decoded = await _compositeActorCards(
          actorId: actorId,
          base: decoded,
          sourceFrame: sourceFrame,
        );
      }

      if (!mounted || serial != _serial) {
        decoded?.dispose();
        return;
      }

      _replaceImage(actorId, decoded, sourceFrame);
      _diagnosticLabels[actorId] = _diagnosticLabel(result, actorId);
    }

    if (!mounted || serial != _serial) return;
    _evictUnrequestedHiddenImages(
      visibleIds: visibleIds,
      requestedIds: requestedIds,
    );
    setState(() {});

    final bool currentResolved = visibleIds.every(
      (MosaicLayoutActorId actorId) =>
          _imageFrames[actorId] == sourceFrame,
    );
    if (currentResolved) _reportReady();
    if (retryPending) _scheduleRender();
  }

  MosaicLayoutActorFrame? _actorFromFrame(
    MosaicLayoutFrame frame,
    MosaicLayoutActorId actorId,
  ) {
    for (final MosaicLayoutActorFrame actor in frame.actors) {
      if (actor.actorId == actorId) return actor;
    }
    return null;
  }

  MosaicLayoutActorFrame _lookAheadActor({
    required MosaicResolvedLayoutProgram resolved,
    required MosaicLayoutActorId actorId,
    required int sourceFrame,
  }) {
    final String paneId = actorId.paneId!;
    final int? appearance =
        resolved.nextAppearanceFrame(paneId, afterFrame: sourceFrame);
    if (appearance == null) {
      return resolved.evaluate(sourceFrame).pane(paneId);
    }
    return resolved.evaluate(appearance).pane(paneId);
  }

  ui.Size _decodeSizeForActor(
    MosaicLayoutActorFrame actor, {
    required bool moving,
  }) {
    final MosaicLayoutActiveSegment? segment = actor.activeSegment;
    final Rect anchor = segment?.anchorRect ?? actor.rect;
    final double targetChrome = segment?.targetChrome ?? actor.chrome;
    final double barHeight = 38.0 * widget.chromeScale * targetChrome;
    final ui.Size displaySize = ui.Size(
      math.max(1.0, anchor.width.roundToDouble()),
      math.max(1.0, (anchor.height - barHeight).roundToDouble()),
    );
    if (!moving) return displaySize;

    final double pixels = displaySize.width * displaySize.height;
    if (pixels <= _movingDecodePixelBudget) return displaySize;
    final double scale = math.sqrt(_movingDecodePixelBudget / pixels);
    return ui.Size(
      math.max(1.0, (displaySize.width * scale).roundToDouble()),
      math.max(1.0, (displaySize.height * scale).roundToDouble()),
    );
  }

  Future<ui.Image?> _compositeActorCards({
    required MosaicLayoutActorId actorId,
    required ui.Image base,
    required int sourceFrame,
  }) async {
    final EditDocumentModel? model = _runtimeModel;
    final CardOverlayImageCache? images = _cardImages;
    final StructuralSourceRef? root = StructuralSourceRef.tryParse(
      widget.placement.sourceRef.canonicalSource,
    );
    if (model == null ||
        images == null ||
        root == null ||
        root.kind != StructuralSourceKind.mosaic ||
        !model.containsStructuralSource(root)) {
      return base;
    }

    final List<StructuralCardOverlayPlacement> placements;
    if (actorId.kind == MosaicLayoutActorKind.composite) {
      placements = structuralCardOverlayPlacements(
        model,
        root,
        sourceFrame,
      )
          .where(
            (StructuralCardOverlayPlacement placement) =>
                !placement.isSideCard,
          )
          .toList(growable: false);
    } else {
      final int paneIndex =
          widget.program.paneIds.indexOf(actorId.paneId!);
      if (paneIndex < 0) return base;
      placements = structuralCardOverlayPlacementsForMosaicPane(
        model,
        root,
        paneIndex,
        sourceFrame,
      )
          .where(
            (StructuralCardOverlayPlacement placement) =>
                !placement.isSideCard,
          )
          .toList(growable: false);
    }

    final ui.Image? composited =
        await compositeStructuralCardOverlaysToImage(
      structuralImage: base,
      placements: placements,
      images: images,
      fontFamily: widget.fontFamily,
    );
    if (composited == null) return base;
    base.dispose();
    return composited;
  }

  String _diagnosticLabel(
    EditVideoCompositeResult result,
    MosaicLayoutActorId actorId,
  ) {
    final MediaFrame? frame = result.topFrame;
    final String source = frame?.source.trim() ?? '';
    if (source.isNotEmpty) return source;
    return actorId.kind == MosaicLayoutActorKind.composite
        ? widget.placement.sourceRef.canonicalSource
        : (actorId.paneId ?? '');
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

  void _reportReady() {
    if (_readyReported) return;
    _readyReported = true;
    widget.onFirstFrameReady?.call();
  }

  Map<MosaicLayoutActorId, StructuralWindowActorVisual> _visualsFor(
    MosaicLayoutFrame frame,
  ) {
    final Map<MosaicLayoutActorId, StructuralWindowActorVisual> out =
        <MosaicLayoutActorId, StructuralWindowActorVisual>{};
    final Map<MosaicLayoutActorId, String> titles =
        structuralMosaicLayoutWindowTitles(
      frame: frame,
      placement: widget.placement,
    );
    for (final MosaicLayoutActorFrame actor in frame.paintActors) {
      final MosaicLayoutActorId actorId = actor.actorId;
      // Residency is deliberately independent from authored time, but the hold
      // is intentionally short. While a nonblocking decoder works on the next
      // nearby frame, keep painting the actor's recent resident image. A pane
      // recalled after a long hidden interval paints empty until a current or
      // near-current image is resident; it must never flash its stale pre-exit
      // picture. Geometry, opacity, chrome, and z still come from the exact
      // current MosaicLayoutFrame.
      final ui.Image? image = _residentImageFor(actorId);
      out[actorId] = StructuralWindowActorVisual(
        sourceImage: image,
        sourceFrame: widget.sourceFrame,
        sourceDurationFrames: widget.placement.sourceDurationFrames,
        windowTitle: titles[actorId] ?? widget.placement.effectiveWindowTitle,
        overlayMode: widget.placement.overlayMode,
        topOverlay: widget.placement.topOverlay,
        bottomOverlay: widget.placement.bottomOverlay,
        defaultBottomOverlay: _diagnosticLabels[actorId] ?? '',
      );
    }
    return out;
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

        final ui.Size size = ui.Size(width, height);
        final MosaicResolvedLayoutProgram resolved = _ensureResolved(size);
        final MosaicLayoutFrame layoutFrame =
            resolved.evaluate(widget.sourceFrame);
        final MosaicLayoutFrame displayFrame =
            structuralMosaicLayoutOuterFrame(
          frame: layoutFrame,
          stage: widget.stage,
          stageProgress: widget.stageProgress,
          shellOpacity: widget.shellOpacity,
        );

        final bool requestChanged =
            _programRenderSize != size ||
            _currentLayoutFrame != layoutFrame;
        if (requestChanged) {
          _programRenderSize = size;
          _currentLayoutFrame = layoutFrame;
          _serial++;
          _scheduleRender();
        }

        return RepaintBoundary(
          key: const ValueKey<String>('structural-mosaic-layout-raster'),
          child: CustomPaint(
            key: const ValueKey<String>('structural-mosaic-layout-frame'),
            painter: MosaicLayoutWindowPainter(
              layoutFrame: displayFrame,
              visuals: _visualsFor(layoutFrame),
              theme: widget.theme,
              fontFamily: widget.fontFamily,
              chromeScale: widget.chromeScale,
            ),
            child: const SizedBox.expand(),
          ),
        );
      },
    );
  }
}
