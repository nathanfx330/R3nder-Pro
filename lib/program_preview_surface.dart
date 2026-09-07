// ./lib/program_preview_surface.dart
//
// Top-level PREVIEW surface.
//
// ScenePainter remains the base program image. StructuralSequencePreview is a
// sibling layer that appears only while the engine-internal STRUCT runtime
// region is active. This is intentionally the same structural presentation
// widget used by EditorScreen; PREVIEW does not get a second compositor or a
// second timing model.
//
// During a STRUCT event the structural widget receives this same live
// SceneEngine and font family. Its terminal/desktop transition therefore uses
// ScenePainter's native renderer instead of a reconstructed ghost, preserving
// terminal themes and exact hand-off pixels.
//
// APPSWITCH:SLIDE adds one lifecycle requirement: the next structural source
// must be resident before the current one yields. When a placement plans a
// seamless hand-off, the next keyed StructuralSequencePreview is mounted at
// opacity zero while the current source is still playing. Flutter therefore
// keeps that exact subtree and decoder state when it later becomes the visible
// placement. Readiness can still delay visibility, but the common path switches
// with frame zero already decoded instead of opening a new decoder at the join.

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

  StructuralSequencePlacement? _placementAt(int index) {
    if (index < 0 || index >= _placements.length) return null;
    final StructuralSequencePlacement placement = _placements[index];
    return placement.resolves ? placement : null;
  }

  StructuralSequencePlacement? _activePlacement(
    StructuralRuntimeMarker? marker,
  ) {
    if (marker == null) return null;
    final StructuralSequencePlacement? placement =
        _placementAt(marker.placementIndex);
    if (placement == null) return null;
    if (placement.durationFrames != marker.durationFrames) return null;
    return placement;
  }

  StructuralSequencePlacement? _preloadPlacement(
    StructuralRuntimeMarker marker,
    StructuralSequencePlacement active,
  ) {
    if (!active.seamlessToNext) return null;
    final StructuralSequencePlacement? next =
        _placementAt(marker.placementIndex + 1);
    if (next == null || !next.seamlessFromPrevious) return null;
    return next;
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

  Widget _structuralLayer({
    required int placementIndex,
    required StructuralSequencePlacement placement,
    required int localFrame,
    required bool visible,
  }) {
    final Widget preview = StructuralSequencePreview(
      key: ValueKey<String>(
        'program-struct-$placementIndex-'
        '${placement.sourceRef.canonicalSource}',
      ),
      rawDocument: widget.rawDocument,
      placement: placement,
      localFrame: localFrame,
      isPlaying: true,
      theme: widget.theme,
      wallpaper: widget.scene.wallpaper,
      terminalScene: widget.scene,
      terminalFontFamily: widget.fontFamily,
    );

    return Positioned.fill(
      key: ValueKey<String>('program-struct-layer-$placementIndex'),
      child: visible
          ? preview
          : IgnorePointer(
              child: Opacity(
                opacity: 0.0,
                child: preview,
              ),
            ),
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

        final List<Widget> layers = <Widget>[
          CustomPaint(
            size: Size.infinite,
            painter: ScenePainter(
              scene: widget.scene,
              fontFamily: widget.fontFamily,
            ),
          ),
        ];

        if (marker != null && placement != null) {
          final StructuralSequencePlacement? preload =
              _preloadPlacement(marker, placement);

          // Put the hidden incoming keyed layer in the tree BEFORE the visible
          // outgoing layer. On the next marker it is re-ordered rather than
          // remounted, preserving the decoder/readiness state we just warmed.
          if (preload != null) {
            layers.add(
              _structuralLayer(
                placementIndex: marker.placementIndex + 1,
                placement: preload,
                localFrame: 0,
                visible: false,
              ),
            );
          }

          layers.add(
            _structuralLayer(
              placementIndex: marker.placementIndex,
              placement: placement,
              localFrame: _localFrame(marker),
              visible: true,
            ),
          );
        }

        return Stack(
          fit: StackFit.expand,
          children: layers,
        );
      },
    );
  }
}
