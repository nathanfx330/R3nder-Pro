// ./lib/structural_sequence_preview.dart
//
// Widget projection of one structural source placed into the main TEXT
// sequence. Source definitions remain owned by the EDIT/MOSAIC model; this
// widget is only the presentation of the sequence-side [STRUCT:...] reference.
//
// STRUCT uses deterministic desktop choreography around the persistent MLT
// structural compositor. Presentation mode belongs to the placement: the same
// source can open as a desktop window or fullscreen without changing source
// composition. Adjacent placements can chain on the desktop, and
// APPSWITCH:SLIDE can switch directly without returning through the terminal.
//
// SIDECARD and DOSSIER are owned by this outer shell while a STRUCT placement
// is live. The existing structural window itself moves left and the sibling
// presentation is painted separately on the desktop. MAXIMIZE is different: it
// paints nothing and transforms that same already-live structural window toward
// the full program frame. No second decoder or playback clock is introduced.
//
// The base STRUCT shell stage choreography is evaluated by
// structural_shell_geometry.dart for Preview and BAKE. SIDECARD/DOSSIER
// displacement remains evaluated by sidecard_geometry.dart. MAXIMIZE geometry
// is also shared through structural_shell_geometry.dart and is applied after
// the base shell. If source lifetime truncates any shell movement, STRUCT closes
// from the exact final shell rectangle so the window never snaps back first.
//
// Frame zero is predecoded while the terminal is still resizing. The structural
// window already exists at opacity zero during a normal entry, but it is not
// allowed to become visible until EditVideoPreview reports that an actual
// presentable image/texture is resident. Readiness is only a visibility gate.
// It never re-anchors or stretches authored presentation time.
//
// FIRST-FRAME PRELOAD CONTRACT
//
// A self-owned moving preview must not turn the invisible entry preload into a
// moving-target nonblocking decode before one presentable frame exists. TEXT
// can update faster than the decoder completes; if every rebuild replaces the
// requested source frame, readiness can be starved while project audio keeps
// advancing. Until the first frame is resident, TEXT therefore stays on the
// exact parked render path. ProgramPreviewSurface supplies onFirstFrameReady and
// owns its own preload/cover coordination, so its established moving path is
// deliberately unchanged.
//
// EDITOR DIRECT-HANDOFF CONTRACT
//
// Top-level PREVIEW owns separate keyed StructuralSequencePreview instances for
// adjacent STRUCT placements. The editor live preview does not: it reuses this
// same State object and updates [placement] from A to B. A seamless source
// change must therefore NOT reset the shell's readiness to false, because doing
// so produces one exact wallpaper-only frame: desktop stays opaque while the
// structural window opacity becomes zero until B resolves.
//
// For a seamless A -> B update, the shell stays live. B is mounted underneath
// the already-painted outgoing client, and the outgoing keyed EditVideoPreview
// remains on top until B reports its first presentable frame. Both clients live
// in the same Stack before and during the handoff, so Flutter can preserve A's
// decoder State instead of disposing/reopening it merely to cover the seam.
// Project time continues to advance; B is evaluated at its authored current
// frame and is never restarted at frame zero. Placement-owned title/overlay
// chrome is snapshotted with that cover so labels and picture swap atomically.
//
// When the caller supplies the live SceneEngine + terminal font, the terminal
// portion of the transition is NOT reconstructed here. ScenePainter's native
// desktop and terminal-window renderer draws it directly. That preserves the
// actual authored terminal theme, font, cursor, title, wallpaper/chroma plate,
// Yaru chrome, and exact fullscreen pixels across the hand-off.
//
// The editor preview pane is not the render frame. ScenePainter letterboxes the
// 16:9 engine canvas inside whatever space the editor gives it. Structural
// choreography lives inside that same fitted rectangle. FULL therefore means
// the fitted program frame, not the outer editor widget and not its letterbox.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'card_overlay.dart';
import 'dossier_overlay.dart';
import 'edit_model.dart';
import 'edit_video_preview.dart';
import 'maximize_shell_state.dart';
import 'media_layer.dart';
import 'scene_engine.dart';
import 'scene_painter.dart';
import 'structural_chrome.dart';
import 'structural_sequence.dart';
import 'structural_shell_geometry.dart';
import 'ui_theme.dart';

enum StructuralSequenceHandoffRole {
  none,
  incoming,
  outgoing,
}

class StructuralSequencePreview extends StatefulWidget {
  final String rawDocument;
  final StructuralSequencePlacement placement;

  /// Frame inside the complete STRUCT event, not merely inside the source.
  /// [StructuralSequencePlacement.sourceFrameAt] maps it onto source time.
  final int localFrame;
  final bool isPlaying;
  final R3Theme theme;
  final ui.Image? wallpaper;

  /// Live terminal source for a pixel-continuous hand-off. When both this and
  /// [terminalFontFamily] are present, ScenePainter draws the terminal/desktop
  /// layer and this widget never substitutes the simplified terminal ghost.
  final SceneEngine? terminalScene;
  final String? terminalFontFamily;

  /// Legacy/focused-test seam for the simplified ghost when no live terminal
  /// scene is supplied. Production PREVIEW and EDIT should supply a live scene.
  final Size? terminalCursorFraction;

  /// Optional seams used by focused widget tests and alternate decoders. The
  /// normal TEXT editor leaves both null and therefore uses the same persistent
  /// MLT backend and workspace resolver as the EDIT surface.
  final MediaDecoderBackend? backend;
  final String Function(String source)? resolveSource;

  /// Optional parent-level readiness signal. Program PREVIEW uses this to keep
  /// the outgoing seamless shell alive if an incoming preload is genuinely
  /// late, without changing project time or the incoming source-frame mapping.
  final VoidCallback? onFirstFrameReady;

  /// Parent-coordinated handoff mode used by ProgramPreviewSurface, which
  /// preserves adjacent STRUCTs as separately keyed preload instances.
  ///
  /// The editor leaves this at [StructuralSequenceHandoffRole.none] and uses
  /// the internal same-State handoff path instead.
  final StructuralSequenceHandoffRole handoffRole;
  final double handoffSlideT;

  const StructuralSequencePreview({
    super.key,
    required this.rawDocument,
    required this.placement,
    required this.localFrame,
    required this.isPlaying,
    required this.theme,
    required this.wallpaper,
    this.terminalScene,
    this.terminalFontFamily,
    this.terminalCursorFraction,
    this.backend,
    this.resolveSource,
    this.onFirstFrameReady,
    this.handoffRole = StructuralSequenceHandoffRole.none,
    this.handoffSlideT = 0.0,
  });

  @override
  State<StructuralSequencePreview> createState() =>
      _StructuralSequencePreviewState();
}

class _StructuralSequencePreviewState extends State<StructuralSequencePreview> {
  static const double _renderAspect = 16.0 / 9.0;

  bool _firstFrameReady = false;
  EditDocumentModel? _cardModel;
  String? _cardModelSource;

  String? _handoffOutgoingSource;
  String? _handoffOutgoingRawDocument;
  int _handoffOutgoingSourceFrame = 0;
  int _handoffOutgoingSourceDurationFrames = 0;
  StructuralOverlayMode _handoffOutgoingOverlayMode =
      StructuralOverlayMode.defaultOverlay;
  String _handoffOutgoingWindowTitle = '';
  String _handoffOutgoingTopOverlay = '';
  String _handoffOutgoingBottomOverlay = '';
  bool _handoffIncomingReady = false;

  void _clearHandoffCover() {
    _handoffOutgoingSource = null;
    _handoffOutgoingRawDocument = null;
    _handoffOutgoingSourceFrame = 0;
    _handoffOutgoingSourceDurationFrames = 0;
    _handoffOutgoingOverlayMode = StructuralOverlayMode.defaultOverlay;
    _handoffOutgoingWindowTitle = '';
    _handoffOutgoingTopOverlay = '';
    _handoffOutgoingBottomOverlay = '';
    _handoffIncomingReady = false;
  }

  EditDocumentModel? _modelForDocument() {
    try {
      if (_cardModel == null || _cardModelSource != widget.rawDocument) {
        _cardModel = EditDocumentModel.parse(widget.rawDocument);
        _cardModelSource = widget.rawDocument;
      }
      return _cardModel;
    } catch (_) {
      return null;
    }
  }

  StructuralSourceRef? _rootForSource(String source) {
    final StructuralSourceRef? root = StructuralSourceRef.tryParse(source);
    final EditDocumentModel? model = _modelForDocument();
    if (root == null ||
        root.id.isEmpty ||
        model == null ||
        !model.containsStructuralSource(root)) {
      return null;
    }
    return root;
  }

  StructuralCardOverlayPlacement? _activeSideCard(
    String source,
    int sourceFrame,
  ) {
    try {
      final EditDocumentModel? model = _modelForDocument();
      final StructuralSourceRef? root = _rootForSource(source);
      if (model == null || root == null) return null;
      return structuralSideCardPlacement(model, root, sourceFrame);
    } catch (_) {
      return null;
    }
  }

  StructuralCardOverlayPlacement? _sideCardAtSourceEnd(
    String source,
    int sourceDurationFrames,
  ) {
    try {
      final EditDocumentModel? model = _modelForDocument();
      final StructuralSourceRef? root = _rootForSource(source);
      if (model == null || root == null) return null;
      return structuralSideCardPlacementAtSourceEnd(
        model,
        root,
        sourceDurationFrames,
      );
    } catch (_) {
      return null;
    }
  }

  StructuralDossierOverlayPlacement? _activeDossier(
    String source,
    int sourceFrame,
  ) {
    try {
      final EditDocumentModel? model = _modelForDocument();
      final StructuralSourceRef? root = _rootForSource(source);
      if (model == null || root == null) return null;
      final resolver = widget.resolveSource ?? resolveWorkspaceMediaSource;
      return structuralDossierPlacement(
        model,
        root,
        sourceFrame,
        centerPageCountFor: (request) =>
            structuralDossierCenterPageCount(request, resolver),
      );
    } catch (_) {
      return null;
    }
  }

  StructuralDossierOverlayPlacement? _dossierAtSourceEnd(
    String source,
    int sourceDurationFrames,
  ) {
    try {
      final EditDocumentModel? model = _modelForDocument();
      final StructuralSourceRef? root = _rootForSource(source);
      if (model == null || root == null) return null;
      final resolver = widget.resolveSource ?? resolveWorkspaceMediaSource;
      return structuralDossierPlacementAtSourceEnd(
        model,
        root,
        sourceDurationFrames,
        centerPageCountFor: (request) =>
            structuralDossierCenterPageCount(request, resolver),
      );
    } catch (_) {
      return null;
    }
  }

  StructuralMaximizePlacement? _activeMaximize(
    String source,
    int sourceFrame,
  ) {
    try {
      final EditDocumentModel? model = _modelForDocument();
      final StructuralSourceRef? root = _rootForSource(source);
      if (model == null || root == null) return null;
      return structuralMaximizePlacement(model, root, sourceFrame);
    } catch (_) {
      return null;
    }
  }

  StructuralMaximizePlacement? _maximizeAtSourceEnd(
    String source,
    int sourceDurationFrames,
  ) {
    try {
      final EditDocumentModel? model = _modelForDocument();
      final StructuralSourceRef? root = _rootForSource(source);
      if (model == null || root == null) return null;
      return structuralMaximizePlacementAtSourceEnd(
        model,
        root,
        sourceDurationFrames,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  void didUpdateWidget(covariant StructuralSequencePreview oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.rawDocument != widget.rawDocument) {
      _cardModel = null;
      _cardModelSource = null;
    }

    final String oldSource = oldWidget.placement.sourceRef.canonicalSource;
    final String newSource = widget.placement.sourceRef.canonicalSource;
    final bool sourceRefChanged = oldSource != newSource;
    final bool previewInfrastructureChanged =
        oldWidget.rawDocument != widget.rawDocument ||
            oldWidget.backend != widget.backend ||
            oldWidget.resolveSource != widget.resolveSource;

    final bool seamlessSourceHandoff = sourceRefChanged &&
        !previewInfrastructureChanged &&
        oldWidget.placement.seamlessToNext &&
        widget.placement.seamlessFromPrevious &&
        _firstFrameReady;

    if (seamlessSourceHandoff) {
      _handoffOutgoingSource = oldSource;
      _handoffOutgoingRawDocument = oldWidget.rawDocument;
      _handoffOutgoingSourceFrame =
          oldWidget.placement.sourceFrameAt(oldWidget.localFrame);
      _handoffOutgoingSourceDurationFrames =
          oldWidget.placement.sourceDurationFrames;
      _handoffOutgoingOverlayMode = oldWidget.placement.overlayMode;
      _handoffOutgoingWindowTitle =
          oldWidget.placement.effectiveWindowTitle;
      _handoffOutgoingTopOverlay = oldWidget.placement.topOverlay;
      _handoffOutgoingBottomOverlay = oldWidget.placement.bottomOverlay;
      _handoffIncomingReady = false;
      return;
    }

    if (!sourceRefChanged &&
        _handoffOutgoingSource != null &&
        _handoffIncomingReady) {
      final int slideFrames = math.min(
        kStructuralSwitchSlideFrames,
        widget.placement.sourceDurationFrames,
      );
      final int sourceFrame =
          widget.placement.sourceFrameAt(widget.localFrame);
      if (slideFrames <= 1 || sourceFrame >= slideFrames - 1) {
        _clearHandoffCover();
      }
    }

    if (sourceRefChanged || previewInfrastructureChanged) {
      _clearHandoffCover();
      _firstFrameReady = false;
    }
  }

  void _handleFirstFrameReady() {
    if (!mounted) return;

    if (_handoffOutgoingSource != null) {
      final int slideFrames = math.min(
        kStructuralSwitchSlideFrames,
        widget.placement.sourceDurationFrames,
      );
      final int sourceFrame =
          widget.placement.sourceFrameAt(widget.localFrame);
      setState(() {
        _firstFrameReady = true;
        _handoffIncomingReady = true;
        if (slideFrames <= 1 || sourceFrame >= slideFrames - 1) {
          _clearHandoffCover();
        }
      });
      widget.onFirstFrameReady?.call();
      return;
    }

    if (_firstFrameReady) return;
    setState(() => _firstFrameReady = true);
    widget.onFirstFrameReady?.call();
  }

  @override
  Widget build(BuildContext context) {
    final StructuralSequencePlacement placement = widget.placement;
    final String source = placement.sourceRef.canonicalSource;
    final StructuralSequenceStage stage = placement.stageAt(widget.localFrame);
    final double linear = placement.stageProgressAt(widget.localFrame);
    final int sourceFrame = placement.sourceFrameAt(widget.localFrame);
    final bool parentOwnsReadiness = widget.onFirstFrameReady != null;

    final bool externalOutgoing =
        widget.handoffRole == StructuralSequenceHandoffRole.outgoing;

    return ColoredBox(
      color: externalOutgoing ? Colors.transparent : Colors.black,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double width = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : 1280.0;
          final double height = constraints.maxHeight.isFinite
              ? constraints.maxHeight
              : 720.0;

          final Rect renderFrame = _fittedRenderFrame(width, height);
          final SceneEngine? liveScene = widget.terminalScene;
          final String? liveFont = widget.terminalFontFamily;
          final bool useNativeTerminal =
              liveScene != null && liveFont != null && liveFont.isNotEmpty;

          final double chromeScale = useNativeTerminal
              ? _nativeChromeScale(renderFrame, liveScene!)
              : 1.0;
          final double titleHeight =
              _StructuralWindow.titleHeight * chromeScale;

          final Rect fullTerminal = renderFrame;
          final Rect terminalParkRect = _structuralTargetRect(
            renderFrame,
            titleHeight: titleHeight,
          );

          final Rect presentationRect = placement.fullscreen
              ? renderFrame
              : terminalParkRect;

          final Rect previousPresentationRect = switch (
            placement.previousPresentationMode
          ) {
            StructuralPresentationMode.fullscreen => renderFrame,
            StructuralPresentationMode.windowed => terminalParkRect,
            null => terminalParkRect,
          };

          final bool closing = stage == StructuralSequenceStage.closing;
          final StructuralDossierOverlayPlacement? truncatedDossier =
              closing && _firstFrameReady
                  ? _dossierAtSourceEnd(
                      source,
                      placement.sourceDurationFrames,
                    )
                  : null;
          final StructuralCardOverlayPlacement? truncatedSideCard =
              truncatedDossier == null && closing && _firstFrameReady
                  ? _sideCardAtSourceEnd(
                      source,
                      placement.sourceDurationFrames,
                    )
                  : null;
          final double? truncatedShellSlide = truncatedDossier != null
              ? structuralDossierShellSlide(truncatedDossier)
              : truncatedSideCard?.slide;

          // Content-bearing shell presentations own the shell over MAXIMIZE.
          // A placement authored FULL also suppresses MAXIMIZE completely: it
          // is already geometrically fullscreen and must not lose chrome as a
          // side effect of a redundant cue.
          final StructuralMaximizePlacement? truncatedMaximize =
              truncatedDossier == null &&
                      truncatedSideCard == null &&
                      !placement.fullscreen &&
                      closing &&
                      _firstFrameReady
                  ? _maximizeAtSourceEnd(
                      source,
                      placement.sourceDurationFrames,
                    )
                  : null;

          Rect closingOrigin = sideCardClosingOriginRect(
            size: renderFrame.size,
            origin: renderFrame.topLeft,
            preCueRect: presentationRect,
            truncatedSlide: truncatedShellSlide,
          );
          StructuralMaximizeGeometryFrame? truncatedMaxGeometry;
          if (truncatedMaximize != null) {
            truncatedMaxGeometry = structuralMaximizeGeometryFrameAt(
              baseRect: presentationRect,
              fullRect: renderFrame,
              amount: truncatedMaximize.amount,
            );
            closingOrigin = truncatedMaxGeometry.structuralRect;
          }

          final StructuralShellFrame baseShell = structuralShellFrameAt(
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
            contentReady: _firstFrameReady,
          );

          Rect terminalRect = baseShell.terminalRect;
          Rect structuralRect = baseShell.structuralRect;
          double desktopOpacity = baseShell.desktopOpacity;
          double terminalOpacity = baseShell.terminalOpacity;
          final double terminalChrome = baseShell.terminalChrome;
          final double structuralOpacity = baseShell.structuralOpacity;
          final bool structuralWindowPresent =
              baseShell.structuralWindowPresent;
          double structuralChrome = 1.0;

          // If source lifetime truncated MAXIMIZE, the STRUCT close starts from
          // its exact final rectangle and restores ordinary window chrome while
          // moving toward the common emergence rect. No fullscreen -> seated
          // snap is introduced at the source boundary.
          if (closing && truncatedMaxGeometry != null) {
            final double eased = Curves.easeInOutCubic.transform(
              linear.clamp(0.0, 1.0).toDouble(),
            );
            structuralChrome = ui.lerpDouble(
              truncatedMaxGeometry.windowChrome,
              1.0,
              eased,
            )!;
          }

          // MAXIMIZE is load-bearingly stage-gated here. A source-frame-zero
          // cue cannot become active during STRUCT opening because source-local
          // shell cues are evaluated only while the source is showing.
          final StructuralDossierOverlayPlacement? dossierPlacement =
              stage == StructuralSequenceStage.showing && _firstFrameReady
                  ? _activeDossier(source, sourceFrame)
                  : null;
          final StructuralCardOverlayPlacement? sideCardPlacement =
              dossierPlacement == null &&
                      stage == StructuralSequenceStage.showing &&
                      _firstFrameReady
                  ? _activeSideCard(source, sourceFrame)
                  : null;
          final StructuralMaximizePlacement? maximizePlacement =
              dossierPlacement == null &&
                      sideCardPlacement == null &&
                      !placement.fullscreen &&
                      stage == StructuralSequenceStage.showing &&
                      _firstFrameReady
                  ? _activeMaximize(source, sourceFrame)
                  : null;

          final double? shellSlide = dossierPlacement != null
              ? structuralDossierShellSlide(dossierPlacement)
              : sideCardPlacement?.slide;
          if (shellSlide != null &&
              shellSlide > 0.0 &&
              structuralWindowPresent) {
            final SideCardShellFrame sideShell = sideCardShellFrameAt(
              size: renderFrame.size,
              origin: renderFrame.topLeft,
              preCueRect: structuralRect,
              slide: shellSlide,
            );
            structuralRect = sideShell.videoWindowRect;
            desktopOpacity = sideShell.desktopOpacity;
            terminalOpacity = sideShell.terminalOpacity;
          }

          if (maximizePlacement != null && structuralWindowPresent) {
            final StructuralMaximizeGeometryFrame maximizeGeometry =
                structuralMaximizeGeometryFrameAt(
              baseRect: structuralRect,
              fullRect: renderFrame,
              amount: maximizePlacement.amount,
            );
            structuralRect = maximizeGeometry.structuralRect;
            structuralChrome = maximizeGeometry.windowChrome;
          }

          final Size cursorFraction = widget.terminalCursorFraction ??
              _TerminalGhost.fallbackCursorFraction;
          final double terminalScale = fullTerminal.width > 0.0
              ? terminalRect.width / fullTerminal.width
              : 1.0;
          final Size terminalCursorSize = Size(
            fullTerminal.width * cursorFraction.width * terminalScale,
            fullTerminal.height * cursorFraction.height * terminalScale,
          );

          final int handoffSlideFrames = math.min(
            kStructuralSwitchSlideFrames,
            placement.sourceDurationFrames,
          );
          final double handoffSlideRaw =
              _handoffOutgoingSource != null &&
                      _handoffIncomingReady &&
                      handoffSlideFrames > 1
                  ? (sourceFrame / (handoffSlideFrames - 1))
                      .clamp(0.0, 1.0)
                      .toDouble()
                  : 0.0;
          final double handoffSlideT =
              Curves.easeInOutCubic.transform(handoffSlideRaw);

          return Stack(
            fit: StackFit.expand,
            children: [
              if (!externalOutgoing && useNativeTerminal)
                Positioned.fill(
                  key: const ValueKey<String>(
                    'structural-native-terminal-positioned',
                  ),
                  child: CustomPaint(
                    key: const ValueKey<String>(
                      'structural-native-terminal-layer',
                    ),
                    painter: SceneStructuralTerminalPainter(
                      scene: liveScene!,
                      fontFamily: liveFont!,
                      terminalRect: _rectFraction(terminalRect, renderFrame),
                      desktopOpacity: desktopOpacity,
                      terminalOpacity: terminalOpacity,
                      terminalChrome: terminalChrome,
                    ),
                  ),
                )
              else if (!externalOutgoing) ...[
                Positioned.fromRect(
                  key: const ValueKey<String>('structural-desktop-positioned'),
                  rect: renderFrame,
                  child: Opacity(
                    key: const ValueKey<String>('structural-desktop-layer'),
                    opacity: desktopOpacity.clamp(0.0, 1.0),
                    child: _DesktopPlate(wallpaper: widget.wallpaper),
                  ),
                ),
                if (terminalOpacity > 0.001)
                  Positioned.fromRect(
                    key: const ValueKey<String>(
                      'structural-terminal-positioned',
                    ),
                    rect: terminalRect,
                    child: Opacity(
                      key: const ValueKey<String>('structural-terminal-opacity'),
                      opacity: terminalOpacity.clamp(0.0, 1.0),
                      child: _TerminalGhost(
                        key: const ValueKey<String>(
                          'structural-terminal-window',
                        ),
                        theme: widget.theme,
                        chrome: terminalChrome.clamp(0.0, 1.0),
                        cursorSize: terminalCursorSize,
                      ),
                    ),
                  ),
              ],

              if (structuralWindowPresent)
                Positioned.fromRect(
                  key: const ValueKey<String>('structural-window-positioned'),
                  rect: structuralRect,
                  child: Opacity(
                    key: const ValueKey<String>('structural-window-opacity'),
                    opacity: structuralOpacity.clamp(0.0, 1.0),
                    child: _StructuralWindow(
                      key: const ValueKey<String>('structural-window-frame'),
                      source: source,
                      rawDocument: widget.rawDocument,
                      sourceFrame: sourceFrame,
                      sourceDurationFrames: placement.sourceDurationFrames,
                      overlayMode: placement.overlayMode,
                      windowTitle: placement.effectiveWindowTitle,
                      topOverlay: placement.topOverlay,
                      bottomOverlay: placement.bottomOverlay,
                      isPlaying: widget.isPlaying &&
                          stage == StructuralSequenceStage.showing &&
                          _firstFrameReady,
                      fastPreview: widget.isPlaying &&
                          (parentOwnsReadiness || _firstFrameReady),
                      showVideo: stage == StructuralSequenceStage.zoomOut ||
                          stage == StructuralSequenceStage.opening ||
                          stage == StructuralSequenceStage.showing ||
                          stage == StructuralSequenceStage.closing,
                      theme: widget.theme,
                      chromeScale: chromeScale,
                      windowChrome: structuralChrome,
                      backend: widget.backend,
                      resolveSource: widget.resolveSource,
                      onFirstFrameReady: _handleFirstFrameReady,
                      outgoingSource: _handoffOutgoingSource,
                      outgoingRawDocument: _handoffOutgoingRawDocument,
                      outgoingSourceFrame: _handoffOutgoingSourceFrame,
                      outgoingSourceDurationFrames:
                          _handoffOutgoingSourceDurationFrames,
                      outgoingOverlayMode: _handoffOutgoingOverlayMode,
                      outgoingWindowTitle: _handoffOutgoingWindowTitle,
                      outgoingTopOverlay: _handoffOutgoingTopOverlay,
                      outgoingBottomOverlay: _handoffOutgoingBottomOverlay,
                      handoffSlideT: widget.handoffRole ==
                                  StructuralSequenceHandoffRole.none
                              ? handoffSlideT
                              : widget.handoffSlideT
                                  .clamp(0.0, 1.0)
                                  .toDouble(),
                      handoffRole: widget.handoffRole,
                    ),
                  ),
                ),

              if (dossierPlacement != null)
                Positioned.fromRect(
                  key: const ValueKey<String>(
                    'structural-dossier-panel-positioned',
                  ),
                  rect: renderFrame,
                  child: StructuralDossierPanelOverlay(
                    key: const ValueKey<String>('structural-dossier-panel'),
                    placement: dossierPlacement,
                    resolveSource:
                        widget.resolveSource ?? resolveWorkspaceMediaSource,
                    fontFamily: liveFont != null && liveFont.isNotEmpty
                        ? liveFont
                        : 'monospace',
                  ),
                )
              else if (sideCardPlacement != null)
                Positioned.fromRect(
                  key: const ValueKey<String>(
                    'structural-sidecard-panel-positioned',
                  ),
                  rect: renderFrame,
                  child: StructuralSideCardPanelOverlay(
                    key: const ValueKey<String>('structural-sidecard-panel'),
                    placement: sideCardPlacement,
                    resolveSource:
                        widget.resolveSource ?? resolveWorkspaceMediaSource,
                    fontFamily: liveFont != null && liveFont.isNotEmpty
                        ? liveFont
                        : 'monospace',
                  ),
                ),

              if (_firstFrameReady)
                const Positioned(
                  key: ValueKey<String>('structural-ready-positioned'),
                  left: 0,
                  top: 0,
                  child: SizedBox.shrink(
                    key: ValueKey<String>('structural-first-frame-ready'),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  static double _nativeChromeScale(Rect renderFrame, SceneEngine scene) {
    final double engineWidth = scene.width;
    if (engineWidth <= 0.0 || renderFrame.width <= 0.0) return 1.0;
    return scene.terminal.scale * renderFrame.width / engineWidth;
  }

  static Rect _rectFraction(Rect rect, Rect frame) {
    if (frame.width <= 0.0 || frame.height <= 0.0) return Rect.zero;
    return Rect.fromLTRB(
      (rect.left - frame.left) / frame.width,
      (rect.top - frame.top) / frame.height,
      (rect.right - frame.left) / frame.width,
      (rect.bottom - frame.top) / frame.height,
    );
  }

  static Rect _fittedRenderFrame(double width, double height) {
    if (width <= 0.0 || height <= 0.0) {
      return Rect.fromLTWH(
        0,
        0,
        math.max(width, 0.0),
        math.max(height, 0.0),
      );
    }

    double frameW = width;
    double frameH = frameW / _renderAspect;
    if (frameH > height) {
      frameH = height;
      frameW = frameH * _renderAspect;
    }

    return Rect.fromLTWH(
      (width - frameW) / 2.0,
      (height - frameH) / 2.0,
      frameW,
      frameH,
    );
  }

  static Rect _structuralTargetRect(
    Rect frame, {
    double titleHeight = _StructuralWindow.titleHeight,
  }) {
    final double maxW = frame.width * 0.86;
    final double maxH = frame.height * 0.78;

    double clientW = maxW;
    double clientH = clientW * 9.0 / 16.0;
    if (clientH + titleHeight > maxH) {
      clientH = math.max(1.0, maxH - titleHeight);
      clientW = clientH * 16.0 / 9.0;
    }

    final double windowW = clientW;
    final double windowH = clientH + titleHeight;
    return Rect.fromLTWH(
      frame.left + (frame.width - windowW) / 2.0,
      frame.top + (frame.height - windowH) / 2.0,
      windowW,
      windowH,
    );
  }
}

class _DesktopPlate extends StatelessWidget {
  final ui.Image? wallpaper;

  const _DesktopPlate({required this.wallpaper});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Color(0xFF101010)),
        if (wallpaper != null)
          RawImage(
            image: wallpaper,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.low,
          ),
        ColoredBox(color: Colors.black.withValues(alpha: 0.10)),
      ],
    );
  }
}

class _TerminalGhost extends StatelessWidget {
  static const double titleHeight = 38.0;
  static const Size fallbackCursorFraction = Size(0.01, 0.02);

  final R3Theme theme;
  final double chrome;
  final Size cursorSize;

  const _TerminalGhost({
    super.key,
    required this.theme,
    required this.chrome,
    required this.cursorSize,
  });

  @override
  Widget build(BuildContext context) {
    final double c = chrome.clamp(0.0, 1.0);
    final double barH = titleHeight * c;
    final double outerRadius = 5.0 * c;
    final double innerRadius = 4.0 * c;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF080909),
        borderRadius: BorderRadius.circular(outerRadius),
        border: c > 0.001
            ? Border.all(
                color: const Color(0xFF3B3938).withValues(alpha: c),
              )
            : null,
        boxShadow: c > 0.001
            ? [
                BoxShadow(
                  color: const Color(0x66000000).withValues(alpha: 0.40 * c),
                  blurRadius: 20 * c,
                  offset: Offset(0, 10 * c),
                ),
              ]
            : const [],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(innerRadius),
        child: Column(
          children: [
            if (barH > 0.01)
              ClipRect(
                child: SizedBox(
                  key: const ValueKey<String>('structural-terminal-title-bar'),
                  height: barH,
                  child: ColoredBox(
                    color: const Color(0xFF222222).withValues(alpha: c),
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 14 * c),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Opacity(
                          opacity: c,
                          child: Text(
                            'R3nder : Terminal Engine',
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                            style: theme.micro.copyWith(
                              color: const Color(0xFFBDB8B4),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            Expanded(
              child: ColoredBox(
                color: const Color(0xFF050706),
                child: Align(
                  alignment: const Alignment(-0.94, -0.88),
                  child: Container(
                    key: const ValueKey<String>('structural-terminal-cursor'),
                    width: cursorSize.width,
                    height: cursorSize.height,
                    color: theme.accent,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StructuralWindow extends StatelessWidget {
  static const double titleHeight = 38.0;

  final String source;
  final String rawDocument;
  final int sourceFrame;
  final int sourceDurationFrames;
  final StructuralOverlayMode overlayMode;
  final String windowTitle;
  final String topOverlay;
  final String bottomOverlay;
  final bool isPlaying;
  final bool fastPreview;
  final bool showVideo;
  final R3Theme theme;
  final double chromeScale;

  /// 1 = ordinary desktop window chrome, 0 = bare fullscreen client.
  final double windowChrome;

  final MediaDecoderBackend? backend;
  final String Function(String source)? resolveSource;
  final VoidCallback onFirstFrameReady;

  final String? outgoingSource;
  final String? outgoingRawDocument;
  final int outgoingSourceFrame;
  final int outgoingSourceDurationFrames;
  final StructuralOverlayMode outgoingOverlayMode;
  final String outgoingWindowTitle;
  final String outgoingTopOverlay;
  final String outgoingBottomOverlay;
  final double handoffSlideT;
  final StructuralSequenceHandoffRole handoffRole;

  const _StructuralWindow({
    super.key,
    required this.source,
    required this.rawDocument,
    required this.sourceFrame,
    required this.sourceDurationFrames,
    required this.overlayMode,
    required this.windowTitle,
    required this.topOverlay,
    required this.bottomOverlay,
    required this.isPlaying,
    required this.fastPreview,
    required this.showVideo,
    required this.theme,
    required this.chromeScale,
    required this.windowChrome,
    required this.backend,
    required this.resolveSource,
    required this.onFirstFrameReady,
    this.outgoingSource,
    this.outgoingRawDocument,
    this.outgoingSourceFrame = 0,
    this.outgoingSourceDurationFrames = 0,
    this.outgoingOverlayMode = StructuralOverlayMode.defaultOverlay,
    this.outgoingWindowTitle = '',
    this.outgoingTopOverlay = '',
    this.outgoingBottomOverlay = '',
    this.handoffSlideT = 0.0,
    this.handoffRole = StructuralSequenceHandoffRole.none,
  });

  Widget _videoPreview({
    required String previewSource,
    required String previewDocument,
    required int previewFrame,
    required bool playing,
    required StructuralOverlayMode previewOverlayMode,
    required String previewBottomOverlay,
    required VoidCallback? onReady,
  }) {
    final bool showOverlay =
        previewOverlayMode == StructuralOverlayMode.defaultOverlay ||
            (previewOverlayMode == StructuralOverlayMode.custom &&
                previewBottomOverlay.isNotEmpty);
    final String? customText =
        previewOverlayMode == StructuralOverlayMode.custom
            ? expandStructuralChromeExpressions(
                previewBottomOverlay,
                frame: previewFrame,
              )
            : null;

    return EditVideoPreview(
      key: ValueKey<String>('sequence-preview:$previewSource'),
      source: previewDocument,
      structuralSource: previewSource,
      currentFrame: previewFrame,
      theme: theme,
      isPlaying: playing,
      fastPreview: fastPreview,
      renderSideCardsInClient: false,
      renderDossiersInClient: false,
      showDiagnosticOverlay: showOverlay,
      diagnosticOverlayText: customText,
      backend: backend,
      resolveSource: resolveSource,
      onFirstFrameReady: onReady,
    );
  }

  @override
  Widget build(BuildContext context) {
    final double s = chromeScale > 0.0 ? chromeScale : 1.0;
    final double c = windowChrome.clamp(0.0, 1.0).toDouble();
    final double barH = titleHeight * s * c;
    final double outerRadius = 5.0 * s * c;
    final double innerRadius = 4.0 * s * c;
    final String? coverSource = outgoingSource;
    final String? coverDocument = outgoingRawDocument;
    final bool showingCover = coverSource != null && coverDocument != null;
    final bool externalIncoming =
        handoffRole == StructuralSequenceHandoffRole.incoming;
    final bool externalOutgoing =
        handoffRole == StructuralSequenceHandoffRole.outgoing;
    final bool overlayOnly = externalOutgoing;

    final StructuralOverlayMode visibleOverlayMode =
        showingCover ? outgoingOverlayMode : overlayMode;
    final int visibleFrame =
        showingCover ? outgoingSourceFrame : sourceFrame;
    final int visibleDuration = showingCover
        ? outgoingSourceDurationFrames
        : sourceDurationFrames;
    final String outgoingAuthoredTitle = showingCover
        ? (outgoingWindowTitle.isEmpty ? coverSource : outgoingWindowTitle)
        : windowTitle;
    final String outgoingVisibleTitle = expandStructuralChromeExpressions(
      outgoingAuthoredTitle,
      frame: visibleFrame,
    );
    final String incomingVisibleTitle = expandStructuralChromeExpressions(
      windowTitle,
      frame: sourceFrame,
    );
    final bool crossfadeTitle = showingCover &&
        outgoingVisibleTitle != incomingVisibleTitle &&
        handoffSlideT > 0.0;
    final String visibleTop =
        showingCover ? outgoingTopOverlay : topOverlay;

    final String? topText = switch (visibleOverlayMode) {
      StructuralOverlayMode.defaultOverlay =>
        'F$visibleFrame / $visibleDuration',
      StructuralOverlayMode.custom => visibleTop.isEmpty
          ? null
          : expandStructuralChromeExpressions(
              visibleTop,
              frame: visibleFrame,
            ),
      StructuralOverlayMode.none => null,
    };

    return DecoratedBox(
      decoration: BoxDecoration(
        color: overlayOnly ? Colors.transparent : const Color(0xFF171717),
        borderRadius: BorderRadius.circular(outerRadius),
        border: !overlayOnly && c > 0.001
            ? Border.all(
                color: const Color(0xFF3B3938).withValues(alpha: c),
                width: math.max(0.5, s) * c,
              )
            : null,
        boxShadow: !overlayOnly && c > 0.001
            ? [
                BoxShadow(
                  color: const Color(0x8A000000).withValues(alpha: c),
                  blurRadius: 30 * s * c,
                  spreadRadius: 2 * s * c,
                  offset: Offset(0, 16 * s * c),
                ),
              ]
            : const [],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(innerRadius),
        child: Column(
          children: [
            if (barH > 0.01)
              ClipRect(
                child: SizedBox(
                  height: barH,
                  child: Opacity(
                    opacity: c,
                    child: Container(
                      padding: EdgeInsets.symmetric(horizontal: 14 * s * c),
                      decoration: BoxDecoration(
                        color: overlayOnly
                            ? Colors.transparent
                            : const Color(0xFF222222),
                        border: overlayOnly
                            ? null
                            : Border(
                                bottom: BorderSide(
                                  color: const Color(0xFF383838),
                                  width: math.max(0.5, s) * c,
                                ),
                              ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Opacity(
                              opacity: externalIncoming
                                  ? handoffSlideT
                                  : externalOutgoing
                                      ? 1.0 - handoffSlideT
                                      : 1.0,
                              child: crossfadeTitle
                                  ? Stack(
                                      children: [
                                        Opacity(
                                          opacity: 1.0 - handoffSlideT,
                                          child: Text(
                                            outgoingVisibleTitle,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.value.copyWith(
                                              color: const Color(0xFFC7C3C0),
                                              fontSize: 12 * s,
                                            ),
                                          ),
                                        ),
                                        Opacity(
                                          opacity: handoffSlideT,
                                          child: Text(
                                            incomingVisibleTitle,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.value.copyWith(
                                              color: const Color(0xFFC7C3C0),
                                              fontSize: 12 * s,
                                            ),
                                          ),
                                        ),
                                      ],
                                    )
                                  : Text(
                                      showingCover
                                          ? outgoingVisibleTitle
                                          : incomingVisibleTitle,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.value.copyWith(
                                        color: const Color(0xFFC7C3C0),
                                        fontSize: 12 * s,
                                      ),
                                    ),
                            ),
                          ),
                          if (topText != null)
                            Opacity(
                              opacity: externalIncoming
                                  ? handoffSlideT
                                  : externalOutgoing
                                      ? 1.0 - handoffSlideT
                                      : 1.0,
                              child: Text(
                                topText,
                                key: const ValueKey<String>(
                                  'structural-top-overlay',
                                ),
                                overflow: TextOverflow.ellipsis,
                                style: theme.micro.copyWith(
                                  color: const Color(0xFF8E8884),
                                  fontSize:
                                      (theme.micro.fontSize ?? 10.5) * s,
                                  letterSpacing:
                                      (theme.micro.letterSpacing ?? 0.0) * s,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            Expanded(
              child: ColoredBox(
                color: overlayOnly ? Colors.transparent : Colors.black,
                child: showVideo
                    ? Stack(
                        fit: StackFit.expand,
                        clipBehavior: Clip.hardEdge,
                        children: [
                          FractionalTranslation(
                            key: const ValueKey<String>(
                              'structural-handoff-incoming',
                            ),
                            translation: showingCover || externalIncoming
                                ? Offset(1.0 - handoffSlideT, 0.0)
                                : externalOutgoing
                                    ? Offset(-handoffSlideT, 0.0)
                                    : Offset.zero,
                            child: _videoPreview(
                              previewSource: source,
                              previewDocument: rawDocument,
                              previewFrame: sourceFrame,
                              playing: isPlaying,
                              previewOverlayMode: overlayMode,
                              previewBottomOverlay: bottomOverlay,
                              onReady: onFirstFrameReady,
                            ),
                          ),
                          if (showingCover)
                            FractionalTranslation(
                              key: const ValueKey<String>(
                                'structural-handoff-outgoing',
                              ),
                              translation: Offset(-handoffSlideT, 0.0),
                              child: _videoPreview(
                                previewSource: coverSource,
                                previewDocument: coverDocument,
                                previewFrame: outgoingSourceFrame,
                                playing: false,
                                previewOverlayMode: outgoingOverlayMode,
                                previewBottomOverlay: outgoingBottomOverlay,
                                onReady: null,
                              ),
                            ),
                        ],
                      )
                    : const SizedBox.expand(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
