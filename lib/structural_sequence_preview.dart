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
// The first structural frame is decoded during the opening stage and held
// still while the new window comes forward. Source time begins advancing only
// after the window has settled, so the presentation never opens onto an
// artificial black client before picture appears.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'edit_video_preview.dart';
import 'media_layer.dart';
import 'structural_sequence.dart';
import 'ui_theme.dart';

class StructuralSequencePreview extends StatelessWidget {
  final String rawDocument;
  final StructuralSequencePlacement placement;

  /// Frame inside the complete STRUCT event, not merely inside the source.
  /// [StructuralSequencePlacement.sourceFrameAt] maps it onto source time.
  final int localFrame;
  final bool isPlaying;
  final R3Theme theme;
  final ui.Image? wallpaper;

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
    this.backend,
    this.resolveSource,
  });

  @override
  Widget build(BuildContext context) {
    final String source = placement.sourceRef.canonicalSource;
    final StructuralSequenceStage stage = placement.stageAt(localFrame);
    final double linear = placement.stageProgressAt(localFrame);
    final double eased = Curves.easeInOutCubic.transform(linear);
    final int sourceFrame = placement.sourceFrameAt(localFrame);

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

          final Rect fullTerminal = Rect.fromLTWH(0, 0, width, height);
          final Rect presentationRect = _structuralTargetRect(width, height);
          final Rect emergenceRect = _structuralEmergenceRect(presentationRect);

          Rect terminalRect = presentationRect;
          Rect structuralRect = presentationRect;
          double desktopOpacity = 1.0;
          double terminalOpacity = 0.0;
          double structuralOpacity = 0.0;
          bool structuralWindowPresent = false;

          switch (stage) {
            case StructuralSequenceStage.zoomOut:
              // Resize straight to the final panel geometry. There is no
              // smaller parked-terminal waypoint for STRUCT.
              terminalRect = Rect.lerp(fullTerminal, presentationRect, eased)!;
              desktopOpacity = eased;
              terminalOpacity = 1.0;
              break;

            case StructuralSequenceStage.opening:
              // The structural window advances from the rear plane while the
              // terminal yields behind it. Both cues share the same eased
              // progress, so this reads as a single depth hand-off instead of
              // a foreground move over a stubborn second window.
              terminalRect = presentationRect;
              structuralRect =
                  Rect.lerp(emergenceRect, presentationRect, eased)!;
              desktopOpacity = 1.0;
              terminalOpacity = 1.0 - eased;
              structuralOpacity = Curves.easeOutCubic
                  .transform((linear * 2.2).clamp(0.0, 1.0));
              structuralWindowPresent = true;
              break;

            case StructuralSequenceStage.showing:
              terminalRect = presentationRect;
              structuralRect = presentationRect;
              desktopOpacity = 1.0;
              terminalOpacity = 0.0;
              structuralOpacity = 1.0;
              structuralWindowPresent = true;
              break;

            case StructuralSequenceStage.closing:
              // Exact reverse: the foreground window recedes while the rear
              // terminal returns on the same timing curve. Zoom-in therefore
              // inherits a fully restored terminal, not an abrupt replacement.
              terminalRect = presentationRect;
              structuralRect =
                  Rect.lerp(presentationRect, emergenceRect, eased)!;
              desktopOpacity = 1.0;
              terminalOpacity = eased;
              structuralOpacity = Curves.easeInCubic.transform(
                ((1.0 - linear) * 2.2).clamp(0.0, 1.0),
              );
              structuralWindowPresent = true;
              break;

            case StructuralSequenceStage.zoomIn:
              terminalRect = Rect.lerp(presentationRect, fullTerminal, eased)!;
              desktopOpacity = 1.0 - eased;
              terminalOpacity = 1.0;
              break;
          }

          return Stack(
            fit: StackFit.expand,
            children: [
              Opacity(
                opacity: desktopOpacity.clamp(0.0, 1.0),
                child: _DesktopPlate(wallpaper: wallpaper),
              ),

              if (terminalOpacity > 0.001)
                Positioned.fromRect(
                  rect: terminalRect,
                  child: Opacity(
                    key: const ValueKey<String>('structural-terminal-opacity'),
                    opacity: terminalOpacity.clamp(0.0, 1.0),
                    child: _TerminalGhost(
                      key: const ValueKey<String>('structural-terminal-window'),
                      theme: theme,
                    ),
                  ),
                ),

              if (structuralWindowPresent)
                Positioned.fromRect(
                  rect: structuralRect,
                  child: Opacity(
                    opacity: structuralOpacity.clamp(0.0, 1.0),
                    child: _StructuralWindow(
                      key: const ValueKey<String>('structural-window-frame'),
                      source: source,
                      rawDocument: rawDocument,
                      sourceFrame: sourceFrame,
                      sourceDurationFrames: placement.sourceDurationFrames,
                      isPlaying: isPlaying &&
                          stage == StructuralSequenceStage.showing,
                      showVideo: stage == StructuralSequenceStage.opening ||
                          stage == StructuralSequenceStage.showing ||
                          stage == StructuralSequenceStage.closing,
                      theme: theme,
                      backend: backend,
                      resolveSource: resolveSource,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// Final presentation rectangle. The client area itself is 16:9, and the
  /// title bar is added above it. This is both the terminal zoom target and the
  /// final structural-window geometry.
  static Rect _structuralTargetRect(double width, double height) {
    const double titleHeight = _StructuralWindow.titleHeight;
    final double maxW = width * 0.86;
    final double maxH = height * 0.78;

    double clientW = maxW;
    double clientH = clientW * 9.0 / 16.0;
    if (clientH + titleHeight > maxH) {
      clientH = math.max(1.0, maxH - titleHeight);
      clientW = clientH * 16.0 / 9.0;
    }

    final double windowW = clientW;
    final double windowH = clientH + titleHeight;
    return Rect.fromLTWH(
      (width - windowW) / 2.0,
      (height - windowH) / 2.0,
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
  final R3Theme theme;

  const _TerminalGhost({super.key, required this.theme});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF080909),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: const Color(0xFF3B3938)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 20,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Column(
          children: [
            Container(
              height: 38,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              color: const Color(0xFF33302F),
              alignment: Alignment.centerLeft,
              child: Text(
                'R3nder : Terminal Engine',
                overflow: TextOverflow.ellipsis,
                style: theme.micro.copyWith(
                  color: const Color(0xFFBDB8B4),
                ),
              ),
            ),
            Expanded(
              child: ColoredBox(
                color: const Color(0xFF050706),
                child: Align(
                  alignment: const Alignment(-0.94, -0.88),
                  child: Container(
                    width: 7,
                    height: 14,
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
