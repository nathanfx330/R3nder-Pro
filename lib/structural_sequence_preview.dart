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
// The terminal ghost also follows ScenePainter's native chrome rule: as the
// terminal pulls away from fullscreen its title bar, corners, border, and
// shadow grow in; on the return they collapse back to zero while the terminal
// expands. The parked window therefore becomes the fullscreen terminal instead
// of carrying a fixed title bar to the last frame and dropping it at the cut.
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

  /// Width/height of the live terminal cursor expressed as fractions of the
  /// terminal engine canvas. PREVIEW and EDIT can supply this so the structural
  /// terminal ghost starts with the exact cursor dimensions visible on the
  /// frame immediately before the hand-off. Null uses a proportional fallback.
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
          final Rect fullTerminal = renderFrame;
          final Rect presentationRect = _structuralTargetRect(renderFrame);
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

          // Cursor shape is part of the hand-off, not chrome. Start from the
          // cursor's exact full-terminal dimensions, then apply ONE uniform
          // scale derived from terminal width. Using the ghost client width
          // and height independently made the cursor stretch as the title bar
          // grew, and made the return snap back to ScenePainter's real cursor.
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
                  key: const ValueKey<String>('structural-terminal-positioned'),
                  rect: terminalRect,
                  child: Opacity(
                    key: const ValueKey<String>('structural-terminal-opacity'),
                    opacity: terminalOpacity.clamp(0.0, 1.0),
                    child: _TerminalGhost(
                      key: const ValueKey<String>('structural-terminal-window'),
                      theme: widget.theme,
                      chrome: terminalChrome.clamp(0.0, 1.0),
                      cursorSize: terminalCursorSize,
                    ),
                  ),
                ),

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
  /// area itself is 16:9, and the title bar is added above it. This is both
  /// the terminal zoom target and the final structural-window geometry.
  static Rect _structuralTargetRect(Rect frame) {
    const double titleHeight = _StructuralWindow.titleHeight;
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
    required this.backend,
    required this.resolveSource,
    required this.onFirstFrameReady,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF171717),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: const Color(0xFF3B3938)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x8A000000),
            blurRadius: 30,
            spreadRadius: 2,
            offset: Offset(0, 16),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Column(
          children: [
            Container(
              height: titleHeight,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: const BoxDecoration(
                color: Color(0xFF33302F),
                border: Border(
                  bottom: BorderSide(color: Color(0xFF474341)),
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
                        fontSize: 12,
                      ),
                    ),
                  ),
                  Text(
                    'F$sourceFrame / $sourceDurationFrames',
                    style: theme.micro.copyWith(
                      color: const Color(0xFF8E8884),
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
