// ./lib/program_preview_surface.dart
//
// Top-level PREVIEW surface.
//
// ScenePainter remains the base program image. StructuralSequencePreview is a
// sibling layer that appears only while the engine-internal STRUCT runtime
// region is active. This is intentionally the same structural presentation
// widget used by EditorScreen; PREVIEW does not get a second compositor or a
// second timing model.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'scene_engine.dart';
import 'scene_painter.dart';
import 'structural_sequence.dart';
import 'structural_sequence_preview.dart';
import 'ui_theme.dart';

class ProgramPreviewSurface extends StatefulWidget {
  final Listenable repaint;
  final SceneEngine scene;
  final String rawDocument;
  final String fontFamily;
  final R3Theme theme;

  const ProgramPreviewSurface({
    super.key,
    required this.repaint,
    required this.scene,
    required this.rawDocument,
    required this.fontFamily,
    required this.theme,
  });

  @override
  State<ProgramPreviewSurface> createState() => _ProgramPreviewSurfaceState();
}

class _ProgramPreviewSurfaceState extends State<ProgramPreviewSurface> {
  static const List<String> _terminalFontFallbacks = <String>[
    'Courier',
    'Consolas',
    'Courier New',
    'monospace',
  ];

  /// Same baseline measurement used by TerminalPainter's glyph cache. The
  /// structural hand-off is a different widget, but it must not invent a
  /// different cursor rectangle on the frame where it takes over.
  static final Map<(String, double), double> _cursorBaselines =
      <(String, double), double>{};

  late List<StructuralSequencePlacement> _placements;

  @override
  void initState() {
    super.initState();
    _placements = parseStructuralSequencePlacements(widget.rawDocument);
  }

  @override
  void didUpdateWidget(covariant ProgramPreviewSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rawDocument != widget.rawDocument) {
      _placements = parseStructuralSequencePlacements(widget.rawDocument);
    }
  }

  StructuralSequencePlacement? _activePlacement(
    StructuralRuntimeMarker? marker,
  ) {
    if (marker == null) return null;
    final int index = marker.placementIndex;
    if (index < 0 || index >= _placements.length) return null;

    final StructuralSequencePlacement placement = _placements[index];
    if (!placement.resolves) return null;
    if (placement.durationFrames != marker.durationFrames) return null;
    return placement;
  }

  int _localFrame(StructuralRuntimeMarker marker) {
    final terminal = widget.scene.terminal;
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

  Size _terminalCursorFraction() {
    final terminal = widget.scene.terminal;
    final double fontSize = terminal.currentFontSize;
    final (String, double) key = (widget.fontFamily, fontSize);

    double? baseline = _cursorBaselines[key];
    if (baseline == null) {
      final TextPainter ref = TextPainter(
        text: TextSpan(
          text: 'M',
          style: TextStyle(
            fontFamily: widget.fontFamily,
            fontFamilyFallback: _terminalFontFallbacks,
            fontSize: fontSize,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      ref.layout();
      baseline = ref.computeDistanceToActualBaseline(TextBaseline.alphabetic);
      ref.dispose();
      _cursorBaselines[key] = baseline;
    }

    final double engineWidth = terminal.width > 0.0 ? terminal.width : 1.0;
    final double engineHeight = terminal.height > 0.0 ? terminal.height : 1.0;

    // Must mirror TerminalPainter exactly:
    //   width  = currentFontSize * 0.5
    //   height = resolved alphabetic baseline * 0.78
    return Size(
      (fontSize * 0.5) / engineWidth,
      (baseline * 0.78) / engineHeight,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.repaint,
      builder: (BuildContext context, Widget? child) {
        final StructuralRuntimeMarker? marker =
            parseStructuralRuntimeRegion(widget.scene.terminal.currentRegion);
        final StructuralSequencePlacement? placement =
            _activePlacement(marker);

        return Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(
              size: Size.infinite,
              painter: ScenePainter(
                scene: widget.scene,
                fontFamily: widget.fontFamily,
              ),
            ),
            if (marker != null && placement != null)
              Positioned.fill(
                child: StructuralSequencePreview(
                  key: ValueKey<String>(
                    'program-struct-${marker.placementIndex}-'
                    '${placement.sourceRef.canonicalSource}',
                  ),
                  rawDocument: widget.rawDocument,
                  placement: placement,
                  localFrame: _localFrame(marker),
                  isPlaying: true,
                  theme: widget.theme,
                  wallpaper: widget.scene.wallpaper,
                  terminalCursorFraction: _terminalCursorFraction(),
                ),
              ),
          ],
        );
      },
    );
  }
}
