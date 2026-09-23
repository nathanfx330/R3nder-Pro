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
import 'mosaic_split_geometry.dart';
import 'scene_engine.dart';
import 'scene_painter.dart';
import 'structural_chrome.dart';
import 'structural_sequence.dart';
import 'structural_split_window_painter.dart';
import 'structural_shell_geometry.dart';
import 'structural_source_export.dart';
import 'structural_window_painter.dart';
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
    if (outgoing.splitWindow || incoming.splitWindow) return null;

    if (!structuralSwitchSlideWindowOpen(
      sourceFrame: incomingSourceFrame,
      sourceDurationFrames: incoming.sourceDurationFrames,
    )) {
      return null;
    }

    final int outgoingLocalFrame =
        math.max(0, outgoing.effectiveDurationFrames - 1);
    final int outgoingSourceFrame =
        outgoing.sourceFrameAt(outgoingLocalFrame);

    return _StructuralBakeHandoff(
      outgoingPlacement: outgoing,
      outgoingSourceFrame: outgoingSourceFrame,
      slideT: structuralSwitchSlideT(
        sourceFrame: incomingSourceFrame,
        sourceDurationFrames: incoming.sourceDurationFrames,
      ),
    );
  }

  StructuralSequencePlacement? _splitBoundaryPrevious(
    StructuralRuntimeMarker marker,
    StructuralSequencePlacement incoming,
  ) {
    if (!incoming.seamlessFromPrevious) return null;
    final int previousIndex = marker.placementIndex - 1;
    if (previousIndex < 0 || previousIndex >= _placements.length) return null;
    final StructuralSequencePlacement outgoing = _placements[previousIndex];
    if (!outgoing.resolves || !outgoing.seamlessToNext) return null;
    if (!outgoing.splitWindow && !incoming.splitWindow) return null;
    return outgoing;
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
    if (placement.splitWindow) return null;
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
    if (placement.splitWindow) return null;
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
    if (placement.splitWindow) return null;
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
    if (placement.splitWindow) return null;
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
    final StructuralSequencePlacement? splitBoundaryPrevious =
        _splitBoundaryPrevious(marker, placement);
    final bool splitShapeEntry =
        splitBoundaryPrevious != null &&
        splitBoundaryPrevious.presentationShape != placement.presentationShape &&
        stage == StructuralSequenceStage.opening;
    final StructuralSequencePlacement displayPlacement = placement;
    final StructuralSequencePlacement? shapeOutgoingPlacement =
        splitShapeEntry ? splitBoundaryPrevious : null;
    final int shapeOutgoingSourceFrame = shapeOutgoingPlacement == null
        ? 0
        : shapeOutgoingPlacement.sourceFrameAt(
            math.max(0, shapeOutgoingPlacement.effectiveDurationFrames - 1),
          );
    final double shapeEntryLinear =
        splitShapeEntry ? placement.stageProgressAt(localFrame) : 1.0;
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
    final int displaySourceFrame = visual.sourceFrame;

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
    MosaicSplitWindowGeometry? splitGeometry;
    List<_RenderedStructuralSourceImage>? splitPaneImages;
    String defaultBottomOverlay = '';
    String outgoingDefaultBottomOverlay = '';
    if (visual.structuralWindowPresent && visual.structuralOpacity > 0.001) {
      if (displayPlacement.splitWindow) {
        final double engineWidth =
            scene.width > 0.0 ? scene.width : width.toDouble();
        final double chromeScale =
            scene.terminal.scale * width.toDouble() / engineWidth;
        final double titleHeight = 38.0 * chromeScale;
        splitGeometry = mosaicSplitWindowGeometry(
          frame: Rect.fromLTWH(
            0,
            0,
            width.toDouble(),
            height.toDouble(),
          ),
          aspect: displayPlacement.splitClientAspect,
          titleHeight: titleHeight,
          maximized: displayPlacement.maximizeSplit,
        );
        if (!closing) {
          final int paneWidth =
              math.max(1, splitGeometry.clientSize.width.round());
          final int paneHeight =
              math.max(1, splitGeometry.clientSize.height.round());
          splitPaneImages = <_RenderedStructuralSourceImage>[];
          for (int paneIndex = 0; paneIndex < 2; paneIndex++) {
            splitPaneImages.add(
              await _renderSplitPaneFrameImage(
                displayPlacement.sourceRef.canonicalSource,
                paneIndex,
                displaySourceFrame,
                paneWidth,
                paneHeight,
                fontFamily,
              ),
            );
          }
        }
      } else {
        sourceImage = await _imageForSourceFrame(
          displayPlacement.sourceRef.canonicalSource,
          displaySourceFrame,
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
    }

    ui.Image? shapeOutgoingSourceImage;
    MosaicSplitWindowGeometry? shapeOutgoingSplitGeometry;
    List<_RenderedStructuralSourceImage>? shapeOutgoingSplitPaneImages;
    String shapeOutgoingDefaultBottomOverlay = '';
    final StructuralSequencePlacement? outgoingShape = shapeOutgoingPlacement;
    if (outgoingShape != null) {
      if (outgoingShape.splitWindow) {
        final double engineWidth =
            scene.width > 0.0 ? scene.width : width.toDouble();
        final double chromeScale =
            scene.terminal.scale * width.toDouble() / engineWidth;
        final double titleHeight = 38.0 * chromeScale;
        shapeOutgoingSplitGeometry = mosaicSplitWindowGeometry(
          frame: Rect.fromLTWH(
            0,
            0,
            width.toDouble(),
            height.toDouble(),
          ),
          aspect: outgoingShape.splitClientAspect,
          titleHeight: titleHeight,
          maximized: outgoingShape.maximizeSplit,
        );
        final int paneWidth = math.max(
          1,
          shapeOutgoingSplitGeometry.clientSize.width.round(),
        );
        final int paneHeight = math.max(
          1,
          shapeOutgoingSplitGeometry.clientSize.height.round(),
        );
        shapeOutgoingSplitPaneImages = <_RenderedStructuralSourceImage>[];
        for (int paneIndex = 0; paneIndex < 2; paneIndex++) {
          shapeOutgoingSplitPaneImages.add(
            await _renderSplitPaneFrameImage(
              outgoingShape.sourceRef.canonicalSource,
              paneIndex,
              shapeOutgoingSourceFrame,
              paneWidth,
              paneHeight,
              fontFamily,
            ),
          );
        }
      } else {
        final _RenderedStructuralSourceImage renderedOutgoing =
            await _renderSourceFrameImage(
          outgoingShape.sourceRef.canonicalSource,
          shapeOutgoingSourceFrame,
          fontFamily,
        );
        shapeOutgoingSourceImage = renderedOutgoing.image;
        shapeOutgoingDefaultBottomOverlay = renderedOutgoing.diagnosticLabel;
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

    final double structuralEngineWidth =
        scene.width > 0.0 ? scene.width : width.toDouble();
    final double structuralChromeScale =
        scene.terminal.scale * width.toDouble() / structuralEngineWidth;
    final R3Theme structuralTheme = R3Theme.of(scene.terminal.fontColor);

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
      final StructuralSequencePlacement? outgoingShape =
          shapeOutgoingPlacement;
      if (outgoingShape != null) {
        final double outgoingOpacity =
            structuralShapeOutgoingOpacity(shapeEntryLinear);
        final MosaicSplitWindowGeometry? outgoingGeometry =
            shapeOutgoingSplitGeometry;
        final List<_RenderedStructuralSourceImage>? outgoingPanes =
            shapeOutgoingSplitPaneImages;

        if (outgoingShape.splitWindow &&
            outgoingGeometry != null &&
            outgoingPanes != null) {
          StructuralSplitWindowPainter(
            geometry: outgoingGeometry,
            placement: outgoingShape,
            sourceFrame: shapeOutgoingSourceFrame,
            theme: structuralTheme,
            fontFamily: fontFamily,
            chromeScale: structuralChromeScale,
            images: <ui.Image?>[
              outgoingPanes[0].image,
              outgoingPanes[1].image,
            ],
            diagnosticLabels: <String>[
              outgoingPanes[0].diagnosticLabel,
              outgoingPanes[1].diagnosticLabel,
            ],
            opacity: outgoingOpacity,
          ).paint(
            canvas,
            Size(width.toDouble(), height.toDouble()),
          );
        } else if (!outgoingShape.splitWindow &&
            shapeOutgoingSourceImage != null) {
          final Rect outgoingRect =
              structuralProgramPresentationRectForOutput(
            mode: outgoingShape.presentationMode,
            outputWidth: width,
            outputHeight: height,
            titleHeight: 38.0 * structuralChromeScale,
          );
          paintStructuralWindow(
            canvas: canvas,
            theme: structuralTheme,
            chromeScale: structuralChromeScale,
            fontFamily: fontFamily,
            sourceFrame: shapeOutgoingSourceFrame,
            sourceDurationFrames: outgoingShape.sourceDurationFrames,
            windowTitle: outgoingShape.effectiveWindowTitle,
            overlayMode: outgoingShape.overlayMode,
            topOverlay: outgoingShape.topOverlay,
            bottomOverlay: outgoingShape.bottomOverlay,
            defaultBottomOverlay: shapeOutgoingDefaultBottomOverlay,
            rect: _pixelRect(outgoingRect),
            sourceImage: shapeOutgoingSourceImage,
            outgoingSourceImage: null,
            outgoingPlacement: null,
            outgoingSourceFrame: 0,
            outgoingDefaultBottomOverlay: '',
            handoffSlideT: 1.0,
            opacity: outgoingOpacity,
            windowChrome: 1.0,
          );
        }
      }

      final MosaicSplitWindowGeometry? geometry = splitGeometry;
      final List<_RenderedStructuralSourceImage>? panes = splitPaneImages;
      final bool splitBlackClose =
          displayPlacement.splitWindow &&
          stage == StructuralSequenceStage.closing;
      if (displayPlacement.splitWindow &&
          geometry != null &&
          (panes != null || splitBlackClose)) {
        final double splitProgress = stage == StructuralSequenceStage.opening
            ? placement.stageProgressAt(localFrame)
            : splitBlackClose
                ? (1.0 - placement.stageProgressAt(localFrame))
                    .clamp(0.0, 1.0)
                    .toDouble()
                : 1.0;
        final double incomingOpacity =
            splitShapeEntry || splitBlackClose
                ? structuralShapeEntryFrameAt(
                    targetRect: const Rect.fromLTWH(0, 0, 1, 1),
                    linearProgress:
                        splitShapeEntry ? shapeEntryLinear : splitProgress,
                    contentReady: true,
                  ).opacity
                : visual.structuralOpacity;
        StructuralSplitWindowPainter(
          geometry: geometry,
          placement: displayPlacement,
          sourceFrame: displaySourceFrame,
          theme: structuralTheme,
          fontFamily: fontFamily,
          chromeScale: structuralChromeScale,
          images: splitBlackClose
              ? const <ui.Image?>[null, null]
              : <ui.Image?>[
                  panes![0].image,
                  panes![1].image,
                ],
          diagnosticLabels: splitBlackClose
              ? const <String>['', '']
              : <String>[
                  panes![0].diagnosticLabel,
                  panes![1].diagnosticLabel,
                ],
          opacity: incomingOpacity,
          entryProgress: splitProgress,
          exitProgress: null,
        ).paint(
          canvas,
          Size(width.toDouble(), height.toDouble()),
        );
      } else {
        Rect displayRect = structuralRect;
        double displayOpacity = visual.structuralOpacity;
        if (splitShapeEntry) {
          final Rect targetRect =
              structuralProgramPresentationRectForOutput(
            mode: displayPlacement.presentationMode,
            outputWidth: width,
            outputHeight: height,
            titleHeight: 38.0 * structuralChromeScale,
          );
          final StructuralShapeEntryFrame entry =
              structuralShapeEntryFrameAt(
            targetRect: targetRect,
            linearProgress: shapeEntryLinear,
            contentReady: true,
          );
          displayRect = entry.rect;
          displayOpacity = entry.opacity;
        }

        paintStructuralWindow(
          canvas: canvas,
          theme: structuralTheme,
          chromeScale: structuralChromeScale,
          fontFamily: fontFamily,
          sourceFrame: displaySourceFrame,
          sourceDurationFrames: displayPlacement.sourceDurationFrames,
          windowTitle: displayPlacement.effectiveWindowTitle,
          overlayMode: displayPlacement.overlayMode,
          topOverlay: displayPlacement.topOverlay,
          bottomOverlay: displayPlacement.bottomOverlay,
          defaultBottomOverlay: defaultBottomOverlay,
          rect: _pixelRect(displayRect),
          sourceImage: sourceImage,
          outgoingSourceImage: outgoingSourceImage,
          outgoingPlacement: handoff?.outgoingPlacement,
          outgoingSourceFrame: handoff?.outgoingSourceFrame ?? 0,
          outgoingDefaultBottomOverlay: outgoingDefaultBottomOverlay,
          handoffSlideT: handoff?.slideT ?? 1.0,
          opacity: displayOpacity,
          windowChrome: structuralChrome,
        );
      }
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
      shapeOutgoingSourceImage?.dispose();
      final List<_RenderedStructuralSourceImage>? outgoingShapePanes =
          shapeOutgoingSplitPaneImages;
      if (outgoingShapePanes != null) {
        for (final _RenderedStructuralSourceImage pane in outgoingShapePanes) {
          pane.image.dispose();
        }
      }
      final List<_RenderedStructuralSourceImage>? panes = splitPaneImages;
      if (panes != null) {
        for (final _RenderedStructuralSourceImage pane in panes) {
          pane.image.dispose();
        }
      }
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

  Future<_RenderedStructuralSourceImage> _renderSplitPaneFrameImage(
    String source,
    int paneIndex,
    int sourceFrame,
    int imageWidth,
    int imageHeight,
    String fontFamily,
  ) async {
    final String rendererKey =
        '$source|split|${imageWidth}x$imageHeight';
    final StructuralSourceFrameRenderer renderer =
        _sourceRenderers.putIfAbsent(
      rendererKey,
      () => StructuralSourceFrameRenderer.create(
        source: rawDocument,
        structuralSource: source,
        width: imageWidth,
        height: imageHeight,
        backend: backend,
        resolveSource: resolveSource,
      ),
    );

    final StructuralSourceRenderedFrame rendered =
        renderer.renderMosaicPaneDetailed(paneIndex, sourceFrame);
    ui.Image image = await _decodeRgba(
      rendered.rgba,
      imageWidth,
      imageHeight,
    );

    final StructuralSourceRef? root = StructuralSourceRef.tryParse(source);
    if (root != null &&
        root.kind == StructuralSourceKind.mosaic &&
        root.id.isNotEmpty &&
        _editModel.containsStructuralSource(root)) {
      final List<StructuralCardOverlayPlacement> overlays =
          structuralCardOverlayPlacementsForMosaicPane(
        _editModel,
        root,
        paneIndex,
        sourceFrame,
      )
              .where(
                (StructuralCardOverlayPlacement placement) =>
                    !placement.isSideCard,
              )
              .toList(growable: false);
      final ui.Image? composited =
          await compositeStructuralCardOverlaysToImage(
        structuralImage: image,
        placements: overlays,
        images: _cardImages,
        fontFamily: fontFamily,
      );
      if (composited != null) {
        image.dispose();
        image = composited;
      }
    }

    return _RenderedStructuralSourceImage(
      image: image,
      diagnosticLabel:
          rendered.diagnosticLabel('$source · PANE ${paneIndex + 1}'),
    );
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
      final ui.Image? composited =
          await compositeStructuralCardOverlaysToImage(
        structuralImage: decoded,
        placements: overlays,
        images: _cardImages,
        fontFamily: fontFamily,
      );
      if (composited != null) {
        finalImage = composited;
        decoded.dispose();
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
