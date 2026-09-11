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
// Frame zero is predecoded while the terminal is still resizing. The structural
// window already exists at opacity zero during a normal entry, but it is not
// allowed to become visible until EditVideoPreview reports that an actual
// presentable image/texture is resident. Readiness is only a visibility gate.
// It never re-anchors or stretches authored presentation time.
//
// FIRST-FRAME PRELOAD CONTRACT
//
// A moving parent transport must not turn the invisible entry preload into a
// moving-target nonblocking decode before one presentable frame exists. TEXT
// can update faster than the decoder completes; if every rebuild replaces the
// requested source frame, readiness can be starved while project audio keeps
// advancing. Until the first frame is resident, the client therefore stays on
// the exact parked render path. Once readiness is reported, normal fast moving
// preview resumes without changing authored project time.
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

import 'edit_video_preview.dart';
import 'media_layer.dart';
import 'scene_engine.dart';
import 'scene_painter.dart';
import 'structural_chrome.dart';
import 'structural_sequence.dart';
import 'ui_theme.dart';

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
  });

  @override
  State<StructuralSequencePreview> createState() =>
      _StructuralSequencePreviewState();
}

class _StructuralSequencePreviewState extends State<StructuralSequencePreview> {
  static const double _renderAspect = 16.0 / 9.0;

  bool _firstFrameReady = false;

  /// Editor live preview reuses this State across adjacent STRUCT placements.
  /// During a seamless source switch, keep the already-painted outgoing client
  /// above the incoming client until the incoming one resolves. These values
  /// are snapshots of A's last authored frame and chrome, not a second time
  /// source.
  String? _handoffOutgoingSource;
  String? _handoffOutgoingRawDocument;
  int _handoffOutgoingSourceFrame = 0;
  int _handoffOutgoingSourceDurationFrames = 0;
  StructuralOverlayMode _handoffOutgoingOverlayMode =
      StructuralOverlayMode.defaultOverlay;
  String _handoffOutgoingWindowTitle = '';
  String _handoffOutgoingTopOverlay = '';
  String _handoffOutgoingBottomOverlay = '';

  void _clearHandoffCover() {
    _handoffOutgoingSource = null;
    _handoffOutgoingRawDocument = null;
    _handoffOutgoingSourceFrame = 0;
    _handoffOutgoingSourceDurationFrames = 0;
    _handoffOutgoingOverlayMode = StructuralOverlayMode.defaultOverlay;
    _handoffOutgoingWindowTitle = '';
    _handoffOutgoingTopOverlay = '';
    _handoffOutgoingBottomOverlay = '';
  }

  @override
  void didUpdateWidget(covariant StructuralSequencePreview oldWidget) {
    super.didUpdateWidget(oldWidget);

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
      // The presentation shell is already resident. Do not turn it transparent
      // merely because the client composition changed. Snapshot A's exact last
      // evaluated source frame and its authored chrome, then keep its keyed
      // preview as the visual cover while B resolves underneath at current
      // project time.
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
      return;
    }

    if (sourceRefChanged || previewInfrastructureChanged) {
      _clearHandoffCover();
      _firstFrameReady = false;
    }
  }

  void _handleFirstFrameReady() {
    if (!mounted) return;

    if (_handoffOutgoingSource != null) {
      // This callback now belongs to incoming B. The shell never went away;
      // releasing A swaps client pixels and placement chrome together inside
      // that already-live shell.
      setState(() {
        _clearHandoffCover();
        _firstFrameReady = true;
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
    final double eased = Curves.easeInOutCubic.transform(linear);
    final int sourceFrame = placement.sourceFrameAt(widget.localFrame);

    return ColoredBox(
      color: Colors.black,
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

          // ScenePainter expresses chrome in logical engine pixels and then
          // applies the engine-to-widget fit. Reuse that exact conversion for
          // the foreground structural window.
          final double chromeScale = useNativeTerminal
              ? _nativeChromeScale(renderFrame, liveScene!)
              : 1.0;
          final double titleHeight =
              _StructuralWindow.titleHeight * chromeScale;

          final Rect fullTerminal = renderFrame;

          // The terminal always parks as the normal desktop terminal window.
          // FULL is a property of the structural app, not of the terminal.
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

          // Normal open/close originates from the desktop window plane even
          // when the destination is FULL. That lets a fullscreen structural
          // source read as an application window growing into the frame rather
          // than a full-frame image materialising from nowhere.
          final Rect emergenceRect =
              _structuralEmergenceRect(terminalParkRect);

          Rect terminalRect = terminalParkRect;
          Rect structuralRect = presentationRect;
          double desktopOpacity = 1.0;
          double terminalOpacity = 0.0;
          double terminalChrome = 1.0;
          double structuralOpacity = 0.0;
          bool structuralWindowPresent = false;

          switch (stage) {
            case StructuralSequenceStage.zoomOut:
              // Only a chain root owns this stage. Pull the real terminal back
              // to its parked desktop geometry while frame zero predecodes in
              // an invisible structural subtree.
              terminalRect =
                  Rect.lerp(fullTerminal, terminalParkRect, eased)!;
              structuralRect = emergenceRect;
              desktopOpacity = eased;
              terminalOpacity = 1.0;
              terminalChrome = eased;
              structuralOpacity = 0.0;
              structuralWindowPresent = true;
              break;

            case StructuralSequenceStage.opening:
              // Two different things can own an opening stage:
              //
              // 1. ordinary desktop open: emerge from the desktop plane;
              // 2. seamless mode change: morph the already-live shell from the
              //    previous window/fullscreen geometry into this one.
              //
              // Same-mode APPSWITCH:SLIDE has no opening stage at all.
              final double handoffLinear = _firstFrameReady ? linear : 0.0;
              final double handoffEased =
                  Curves.easeInOutCubic.transform(handoffLinear);
              terminalRect = terminalParkRect;
              desktopOpacity = 1.0;
              terminalChrome = 1.0;
              structuralWindowPresent = true;

              if (placement.seamlessFromPrevious) {
                structuralRect = Rect.lerp(
                  previousPresentationRect,
                  presentationRect,
                  handoffEased,
                )!;
                terminalOpacity = 0.0;
                structuralOpacity = _firstFrameReady ? 1.0 : 0.0;
              } else {
                structuralRect = Rect.lerp(
                  emergenceRect,
                  presentationRect,
                  handoffEased,
                )!;
                terminalOpacity = placement.chainedFromPrevious
                    ? 0.0
                    : 1.0 - handoffEased;
                structuralOpacity = _firstFrameReady
                    ? Curves.easeOutCubic.transform(
                        (handoffLinear * 2.2).clamp(0.0, 1.0),
                      )
                    : 0.0;
              }
              break;

            case StructuralSequenceStage.showing:
              terminalRect = terminalParkRect;
              structuralRect = _firstFrameReady
                  ? presentationRect
                  : (placement.seamlessFromPrevious
                      ? previousPresentationRect
                      : emergenceRect);
              desktopOpacity = 1.0;
              // A chained structural app must never resurrect the terminal
              // merely because its decoder is late. A genuinely late chain
              // degrades to desktop, never to a false terminal flash.
              terminalOpacity =
                  (!_firstFrameReady && !placement.chainedFromPrevious)
                      ? 1.0
                      : 0.0;
              terminalChrome = 1.0;
              structuralOpacity = _firstFrameReady ? 1.0 : 0.0;
              structuralWindowPresent = true;
              break;

            case StructuralSequenceStage.closing:
              // Normal adjacency closes the structural app to the desktop but
              // leaves the terminal hidden so the next app can open directly.
              // A standalone close brings the parked terminal back underneath
              // the receding structural window before zoom-in takes over.
              terminalRect = terminalParkRect;
              structuralRect =
                  Rect.lerp(presentationRect, emergenceRect, eased)!;
              desktopOpacity = 1.0;
              terminalOpacity = placement.chainedToNext ? 0.0 : eased;
              terminalChrome = 1.0;
              structuralOpacity = Curves.easeInCubic.transform(
                ((1.0 - linear) * 2.2).clamp(0.0, 1.0),
              );
              structuralWindowPresent = true;
              break;

            case StructuralSequenceStage.zoomIn:
              // Only a chain tail owns this stage. The structural app is gone;
              // the parked terminal expands through the same fitted program
              // frame and its chrome collapses continuously to fullscreen.
              terminalRect =
                  Rect.lerp(terminalParkRect, fullTerminal, eased)!;
              structuralRect = presentationRect;
              desktopOpacity = 1.0 - eased;
              terminalOpacity = 1.0;
              terminalChrome = 1.0 - eased;
              structuralOpacity = 0.0;
              structuralWindowPresent = false;
              break;
          }

          // Fallback ghost only. Production passes the real SceneEngine and
          // therefore never needs to approximate cursor metrics or theme.
          final Size cursorFraction = widget.terminalCursorFraction ??
              _TerminalGhost.fallbackCursorFraction;
          final double terminalScale = fullTerminal.width > 0.0
              ? terminalRect.width / fullTerminal.width
              : 1.0;
          final Size terminalCursorSize = Size(
            fullTerminal.width * cursorFraction.width * terminalScale,
            fullTerminal.height * cursorFraction.height * terminalScale,
          );

          return Stack(
            fit: StackFit.expand,
            children: [
              if (useNativeTerminal)
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
              else ...[
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
                      key: const ValueKey<String>(
                        'structural-terminal-opacity',
                      ),
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
                      // Before the first presentable frame exists, keep the
                      // invisible entry client on EditVideoPreview's exact
                      // parked render path. A moving nonblocking request can be
                      // superseded every TEXT rebuild and never become ready.
                      // Once frame zero is resident, switch to the normal fast
                      // moving profile without changing project time.
                      fastPreview: widget.isPlaying && _firstFrameReady,
                      showVideo: stage == StructuralSequenceStage.zoomOut ||
                          stage == StructuralSequenceStage.opening ||
                          stage == StructuralSequenceStage.showing ||
                          stage == StructuralSequenceStage.closing,
                      theme: widget.theme,
                      chromeScale: chromeScale,
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
                    ),
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

  /// Native chrome is specified in logical engine pixels. This converts one
  /// logical style pixel into widget pixels using the exact ScenePainter fit.
  /// 1080p uses terminal.scale=1; 4K uses terminal.scale=2, so both produce
  /// the same apparent chrome size at the same preview dimensions.
  static double _nativeChromeScale(Rect renderFrame, SceneEngine scene) {
    final double engineWidth = scene.width;
    if (engineWidth <= 0.0 || renderFrame.width <= 0.0) return 1.0;
    return scene.terminal.scale * renderFrame.width / engineWidth;
  }

  /// Maps a widget-space rectangle onto the fitted engine frame as 0..1
  /// coordinates. SceneStructuralTerminalPainter converts this back into the
  /// live SceneEngine's logical pixels before invoking the native renderer.
  static Rect _rectFraction(Rect rect, Rect frame) {
    if (frame.width <= 0.0 || frame.height <= 0.0) return Rect.zero;
    return Rect.fromLTRB(
      (rect.left - frame.left) / frame.width,
      (rect.top - frame.top) / frame.height,
      (rect.right - frame.left) / frame.width,
      (rect.bottom - frame.top) / frame.height,
    );
  }

  /// Fits the 16:9 engine canvas into the editor preview without stretching.
  /// The surrounding space remains the outer black ColoredBox, exactly like
  /// ScenePainter's preview letterbox.
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

  /// Final windowed presentation rectangle inside the fitted render frame. The
  /// client area itself is 16:9, and [titleHeight] is added above it.
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

  /// The foreground window's rear-plane geometry. It is deliberately not a
  /// second destination. It lives inside the normal desktop window rectangle
  /// and is only the perspective cue for "coming forth".
  static Rect _structuralEmergenceRect(Rect target) {
    const double scale = 0.84;
    final double w = target.width * scale;
    final double h = target.height * scale;
    final double x = target.center.dx - w / 2.0;
    final double y = target.center.dy - h / 2.0 + target.height * 0.055;
    return Rect.fromLTWH(x, y, w, h);
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
  final MediaDecoderBackend? backend;
  final String Function(String source)? resolveSource;
  final VoidCallback onFirstFrameReady;

  /// Optional outgoing client retained only during an editor-style seamless
  /// source update. The window/chrome are the current shell; the outgoing
  /// picture and its informational chrome remain the visible cover until B is
  /// presentable, then all of them swap together.
  final String? outgoingSource;
  final String? outgoingRawDocument;
  final int outgoingSourceFrame;
  final int outgoingSourceDurationFrames;
  final StructuralOverlayMode outgoingOverlayMode;
  final String outgoingWindowTitle;
  final String outgoingTopOverlay;
  final String outgoingBottomOverlay;

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
    final double barH = titleHeight * s;
    final String? coverSource = outgoingSource;
    final String? coverDocument = outgoingRawDocument;
    final bool showingCover = coverSource != null && coverDocument != null;

    final StructuralOverlayMode visibleOverlayMode =
        showingCover ? outgoingOverlayMode : overlayMode;
    final int visibleFrame =
        showingCover ? outgoingSourceFrame : sourceFrame;
    final int visibleDuration = showingCover
        ? outgoingSourceDurationFrames
        : sourceDurationFrames;
    final String authoredVisibleTitle = showingCover
        ? (outgoingWindowTitle.isEmpty ? coverSource : outgoingWindowTitle)
        : windowTitle;
    final String visibleTitle = expandStructuralChromeExpressions(
      authoredVisibleTitle,
      frame: visibleFrame,
    );
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
        color: const Color(0xFF171717),
        borderRadius: BorderRadius.circular(5 * s),
        border: Border.all(
          color: const Color(0xFF3B3938),
          width: math.max(0.5, s),
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0x8A000000),
            blurRadius: 30 * s,
            spreadRadius: 2 * s,
            offset: Offset(0, 16 * s),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4 * s),
        child: Column(
          children: [
            Container(
              height: barH,
              padding: EdgeInsets.symmetric(horizontal: 14 * s),
              decoration: BoxDecoration(
                color: const Color(0xFF222222),
                border: Border(
                  bottom: BorderSide(
                    color: const Color(0xFF383838),
                    width: math.max(0.5, s),
                  ),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      visibleTitle,
                      overflow: TextOverflow.ellipsis,
                      style: theme.value.copyWith(
                        color: const Color(0xFFC7C3C0),
                        fontSize: 12 * s,
                      ),
                    ),
                  ),
                  if (topText != null)
                    Text(
                      topText,
                      key: const ValueKey<String>('structural-top-overlay'),
                      overflow: TextOverflow.ellipsis,
                      style: theme.micro.copyWith(
                        color: const Color(0xFF8E8884),
                        fontSize: (theme.micro.fontSize ?? 10.5) * s,
                        letterSpacing: (theme.micro.letterSpacing ?? 0.0) * s,
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: ColoredBox(
                color: Colors.black,
                child: showVideo
                    ? Stack(
                        fit: StackFit.expand,
                        children: [
                          // Incoming/current client is always mounted first so
                          // it can resolve at current project time underneath.
                          _videoPreview(
                            previewSource: source,
                            previewDocument: rawDocument,
                            previewFrame: sourceFrame,
                            playing: isPlaying,
                            previewOverlayMode: overlayMode,
                            previewBottomOverlay: bottomOverlay,
                            onReady: onFirstFrameReady,
                          ),
                          if (showingCover)
                            // The exact outgoing keyed child already existed in
                            // this Stack on the previous frame. Keeping the same
                            // key preserves its decoder State while it covers B.
                            _videoPreview(
                              previewSource: coverSource,
                              previewDocument: coverDocument,
                              previewFrame: outgoingSourceFrame,
                              playing: false,
                              previewOverlayMode: outgoingOverlayMode,
                              previewBottomOverlay: outgoingBottomOverlay,
                              onReady: null,
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
