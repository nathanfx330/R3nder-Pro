// ./lib/structural_sequence_preview.dart
//
// Widget projection of one structural source placed into the main TEXT
// sequence. Source definitions remain owned by the EDIT/MOSAIC model; this
// widget is only the presentation of the sequence-side [STRUCT:...] reference.
//
// STRUCT uses deterministic desktop choreography around the persistent MLT
// structural compositor. The terminal first resizes from fullscreen directly
// to the final video-panel rectangle. The structural window then comes forward
// from inside that rectangle while the terminal fades away behind it. Geometry
// supplies the depth cue; the matched rear-plane fade makes the hand-off read
// as one window yielding to another rather than two stacked windows.
//
// Frame zero is predecoded while the terminal is still resizing. The structural
// window already exists at opacity zero during zoom-out, but it is not allowed
// to become visible until EditVideoPreview reports that an actual presentable
// image/texture is resident. Readiness is only a visibility gate. It never
// re-anchors or stretches authored presentation time: once picture is ready,
// geometry is evaluated from the current STRUCT project frame exactly as if
// decode had completed immediately. A slow machine can reveal late, but it
// cannot invent a different transition curve.
//
// When the caller supplies the live SceneEngine + terminal font, the terminal
// portion of the transition is NOT reconstructed here. ScenePainter's native
// desktop and terminal-window renderer draws it directly. That preserves the
// actual authored terminal theme, font, cursor, title, wallpaper/chroma plate,
// Yaru chrome, and exact fullscreen pixels across the hand-off. The structural
// foreground window also scales its chrome from that same engine-to-preview
// ratio, so a small editor pane does not get a 38-widget-pixel title bar while
// the real terminal beside it is using a scaled native title bar.
//
// The editor preview pane is not the render frame. ScenePainter letterboxes the
// 16:9 engine canvas inside whatever space the editor gives it. Structural
// choreography must live inside that same fitted rectangle or its "fullscreen"
// terminal grows into the editor letterbox and snaps back when ScenePainter
// takes over. R3nder's supported 1080p and 4K formats are both 16:9, so the
// fitted render frame is shared by both resolutions.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'edit_video_preview.dart';
import 'media_layer.dart';
import 'scene_engine.dart';
import 'scene_painter.dart';
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
  });

  @override
  State<StructuralSequencePreview> createState() =>
      _StructuralSequencePreviewState();
}

class _StructuralSequencePreviewState extends State<StructuralSequencePreview> {
  static const double _renderAspect = 16.0 / 9.0;

  bool _firstFrameReady = false;

  @override
  void didUpdateWidget(covariant StructuralSequencePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool sourceChanged =
        oldWidget.placement.sourceRef.canonicalSource !=
                widget.placement.sourceRef.canonicalSource ||
            oldWidget.rawDocument != widget.rawDocument ||
            oldWidget.backend != widget.backend ||
            oldWidget.resolveSource != widget.resolveSource;
    if (sourceChanged) {
      _firstFrameReady = false;
    }
  }

  void _handleFirstFrameReady() {
    if (_firstFrameReady || !mounted) return;
    setState(() => _firstFrameReady = true);
  }

  @override
  Widget build(BuildContext context) {
    final String source = widget.placement.sourceRef.canonicalSource;
    final StructuralSequenceStage stage =
        widget.placement.stageAt(widget.localFrame);
    final double linear =
        widget.placement.stageProgressAt(widget.localFrame);
    final double eased = Curves.easeInOutCubic.transform(linear);
    final int sourceFrame =
        widget.placement.sourceFrameAt(widget.localFrame);

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
          // the foreground structural window. This is load-bearing in EDIT:
          // a fixed 38 widget pixels was much larger than the native title bar
          // in a reduced preview pane and visibly broke the hand-off.
          final double chromeScale = useNativeTerminal
              ? _nativeChromeScale(renderFrame, liveScene)
              : 1.0;
          final double titleHeight = _StructuralWindow.titleHeight * chromeScale;

          final Rect fullTerminal = renderFrame;
          final Rect presentationRect = _structuralTargetRect(
            renderFrame,
            titleHeight: titleHeight,
          );
          final Rect emergenceRect = _structuralEmergenceRect(presentationRect);

          Rect terminalRect = presentationRect;
          Rect structuralRect = presentationRect;
          double desktopOpacity = 1.0;
          double terminalOpacity = 0.0;
          double terminalChrome = 1.0;
          double structuralOpacity = 0.0;
          bool structuralWindowPresent = false;

          switch (stage) {
            case StructuralSequenceStage.zoomOut:
              // Resize straight to the final panel geometry. Chrome grows in
              // with the pull-back, matching ScenePainter's native terminal
              // zoom instead of appearing at full height on the first frame.
              // The structural preview is mounted invisibly from the first
              // STRUCT frame so frame zero can decode before foreground reveal.
              terminalRect = Rect.lerp(fullTerminal, presentationRect, eased)!;
              structuralRect = emergenceRect;
              desktopOpacity = eased;
              terminalOpacity = 1.0;
              terminalChrome = eased;
              structuralOpacity = 0.0;
              structuralWindowPresent = true;
              break;

            case StructuralSequenceStage.opening:
              // Readiness may suppress the foreground, but it may not alter
              // authored time. Before picture is resident we hold the visual
              // hand-off at its frame-zero state. Once ready, the geometry
              // jumps to the deterministic authored state for THIS localFrame.
              // There is deliberately no decode-timing-derived start frame.
              final double handoffLinear = _firstFrameReady ? linear : 0.0;
              final double handoffEased =
                  Curves.easeInOutCubic.transform(handoffLinear);
              terminalRect = presentationRect;
              structuralRect = Rect.lerp(
                emergenceRect,
                presentationRect,
                handoffEased,
              )!;
              desktopOpacity = 1.0;
              terminalOpacity = 1.0 - handoffEased;
              terminalChrome = 1.0;
              structuralOpacity = _firstFrameReady
                  ? Curves.easeOutCubic.transform(
                      (handoffLinear * 2.2).clamp(0.0, 1.0),
                    )
                  : 0.0;
              structuralWindowPresent = true;
              break;

            case StructuralSequenceStage.showing:
              terminalRect = presentationRect;
              structuralRect =
                  _firstFrameReady ? presentationRect : emergenceRect;
              desktopOpacity = 1.0;
              terminalOpacity = _firstFrameReady ? 0.0 : 1.0;
              terminalChrome = 1.0;
              structuralOpacity = _firstFrameReady ? 1.0 : 0.0;
              structuralWindowPresent = true;
              break;

            case StructuralSequenceStage.closing:
              // Foreground recedes while the fully chromed parked terminal
              // returns beneath it. The following zoom-in now inherits that
              // exact chrome state and collapses it continuously to fullscreen.
              terminalRect = presentationRect;
              structuralRect =
                  Rect.lerp(presentationRect, emergenceRect, eased)!;
              desktopOpacity = 1.0;
              terminalOpacity = eased;
              terminalChrome = 1.0;
              structuralOpacity = Curves.easeInCubic.transform(
                ((1.0 - linear) * 2.2).clamp(0.0, 1.0),
              );
              structuralWindowPresent = true;
              break;

            case StructuralSequenceStage.zoomIn:
              // Native ScenePainter behavior inside the fitted render frame:
              // geometry grows to the output canvas at the same time chrome
              // collapses. It never expands into the editor's letterbox.
              terminalRect = Rect.lerp(presentationRect, fullTerminal, eased)!;
              desktopOpacity = 1.0 - eased;
              terminalOpacity = 1.0;
              terminalChrome = 1.0 - eased;
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
                      scene: liveScene,
                      fontFamily: liveFont,
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
                      sourceDurationFrames:
                          widget.placement.sourceDurationFrames,
                      isPlaying: widget.isPlaying &&
                          stage == StructuralSequenceStage.showing &&
                          _firstFrameReady,
                      showVideo: stage == StructuralSequenceStage.zoomOut ||
                          stage == StructuralSequenceStage.opening ||
                          stage == StructuralSequenceStage.showing ||
                          stage == StructuralSequenceStage.closing,
                      theme: widget.theme,
                      chromeScale: chromeScale,
                      backend: widget.backend,
                      resolveSource: widget.resolveSource,
                      onFirstFrameReady: _handleFirstFrameReady,
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
      return Rect.fromLTWH(0, 0, math.max(width, 0.0), math.max(height, 0.0));
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

  /// Final presentation rectangle inside the fitted render frame. The client
  /// area itself is 16:9, and [titleHeight] is added above it. Production uses
  /// the ScenePainter-scaled native title height; fallback widget tests retain
  /// the historical 38-widget-pixel geometry.
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
  /// second destination. It lives inside the final panel rectangle and is
  /// only the perspective cue for "coming forth": 84% scale, slightly lower.
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
                    color: const Color(0xFF33302F).withValues(alpha: c),
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
  final bool isPlaying;
  final bool showVideo;
  final R3Theme theme;
  final double chromeScale;
  final MediaDecoderBackend? backend;
  final String Function(String source)? resolveSource;
  final VoidCallback onFirstFrameReady;

  const _StructuralWindow({
    super.key,
    required this.source,
    required this.rawDocument,
    required this.sourceFrame,
    required this.sourceDurationFrames,
    required this.isPlaying,
    required this.showVideo,
    required this.theme,
    required this.chromeScale,
    required this.backend,
    required this.resolveSource,
    required this.onFirstFrameReady,
  });

  @override
  Widget build(BuildContext context) {
    final double s = chromeScale > 0.0 ? chromeScale : 1.0;
    final double barH = titleHeight * s;

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
                color: const Color(0xFF33302F),
                border: Border(
                  bottom: BorderSide(
                    color: const Color(0xFF474341),
                    width: math.max(0.5, s),
                  ),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      source,
                      overflow: TextOverflow.ellipsis,
                      style: theme.value.copyWith(
                        color: const Color(0xFFC7C3C0),
                        fontSize: 12 * s,
                      ),
                    ),
                  ),
                  Text(
                    'F$sourceFrame / $sourceDurationFrames',
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
                    ? EditVideoPreview(
                        key: ValueKey<String>('sequence-preview:$source'),
                        source: rawDocument,
                        structuralSource: source,
                        currentFrame: sourceFrame,
                        theme: theme,
                        isPlaying: isPlaying,
                        fastPreview: isPlaying,
                        backend: backend,
                        resolveSource: resolveSource,
                        onFirstFrameReady: onFirstFrameReady,
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
