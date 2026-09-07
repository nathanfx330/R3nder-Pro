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
// opacity zero while the current source is still playing. Hidden and visible
// layers deliberately keep the exact same IgnorePointer -> Opacity -> preview
// widget shape. Only property values change at the join, so Flutter preserves
// the incoming preview State and its decoder/readiness state instead of
// disposing the preloaded subtree when opacity becomes 1.
//
// If real decode is still late at the exact marker boundary, PREVIEW keeps the
// outgoing structural shell on its final authored frame while the incoming
// layer continues evaluating at current project time underneath. The clock does
// not pause and B does not restart at frame zero. Once B reports a presentable
// frame, the outgoing fallback is removed and B appears at the current frame.
// This prevents a slow preload from exposing the desktop between seamless apps.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'media_layer.dart';
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

  /// Focused-test seams. Production leaves both null so structural PREVIEW uses
  /// the same persistent native MLT backend and workspace resolver as before.
  final MediaDecoderBackend? structuralBackend;
  final String Function(String source)? structuralResolveSource;

  const ProgramPreviewSurface({
    super.key,
    required this.repaint,
    required this.scene,
    required this.rawDocument,
    required this.fontFamily,
    required this.theme,
    this.structuralBackend,
    this.structuralResolveSource,
  });

  @override
  State<ProgramPreviewSurface> createState() => _ProgramPreviewSurfaceState();
}

class _ProgramPreviewSurfaceState extends State<ProgramPreviewSurface> {
  late List<StructuralSequencePlacement> _placements;

  /// Readiness is only valid while the keyed preview instance is still mounted.
  /// The mounted-index set lets us reject late callbacks from disposed decoder
  /// work and prevents an old readiness result from being reused after a scrub
  /// that fully removed and later remounted the same placement.
  final Set<int> _readyPlacements = <int>{};
  final Set<int> _mountedPlacements = <int>{};

  @override
  void initState() {
    super.initState();
    _placements = parseStructuralSequencePlacements(widget.rawDocument);
  }

  @override
  void didUpdateWidget(covariant ProgramPreviewSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool previewIdentityChanged =
        oldWidget.rawDocument != widget.rawDocument ||
            oldWidget.structuralBackend != widget.structuralBackend ||
            oldWidget.structuralResolveSource != widget.structuralResolveSource;
    if (oldWidget.rawDocument != widget.rawDocument) {
      _placements = parseStructuralSequencePlacements(widget.rawDocument);
    }
    if (previewIdentityChanged) {
      _readyPlacements.clear();
      _mountedPlacements.clear();
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

  void _markPlacementReady(int placementIndex) {
    if (!mounted ||
        !_mountedPlacements.contains(placementIndex) ||
        _readyPlacements.contains(placementIndex)) {
      return;
    }
    setState(() => _readyPlacements.add(placementIndex));
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
      backend: widget.structuralBackend,
      resolveSource: widget.structuralResolveSource,
      onFirstFrameReady: () => _markPlacementReady(placementIndex),
    );

    return Positioned.fill(
      key: ValueKey<String>('program-struct-layer-$placementIndex'),
      child: IgnorePointer(
        ignoring: !visible,
        child: Opacity(
          opacity: visible ? 1.0 : 0.0,
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
        final Set<int> previouslyMounted =
            Set<int>.of(_mountedPlacements);
        final Set<int> nextMounted = <int>{};

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
          final int activeIndex = marker.placementIndex;
          final StructuralSequencePlacement? preload =
              _preloadPlacement(marker, placement);

          // Put the hidden incoming keyed layer in the tree BEFORE the visible
          // outgoing layer. On the next marker the same outer key remains at
          // the same stack position, and the wrapper shape remains identical;
          // only opacity/ignoring change. That is what actually preserves the
          // preloaded StructuralSequencePreview State across the hand-off.
          if (preload != null) {
            final int preloadIndex = activeIndex + 1;
            nextMounted.add(preloadIndex);
            layers.add(
              _structuralLayer(
                placementIndex: preloadIndex,
                placement: preload,
                localFrame: 0,
                visible: false,
              ),
            );
          }

          final bool activeReady = previouslyMounted.contains(activeIndex) &&
              _readyPlacements.contains(activeIndex);

          int? fallbackIndex;
          StructuralSequencePlacement? fallbackPlacement;
          if (placement.seamlessFromPrevious && !activeReady) {
            final int previousIndex = activeIndex - 1;
            final StructuralSequencePlacement? previous =
                _placementAt(previousIndex);
            if (previous != null &&
                previous.seamlessToNext &&
                previouslyMounted.contains(previousIndex)) {
              fallbackIndex = previousIndex;
              fallbackPlacement = previous;
            }
          }

          nextMounted.add(activeIndex);
          layers.add(
            _structuralLayer(
              placementIndex: activeIndex,
              placement: placement,
              localFrame: _localFrame(marker),
              visible: fallbackPlacement == null,
            ),
          );

          // A genuinely late seamless preload must not expose the desktop.
          // Keep the exact keyed outgoing preview alive on its final authored
          // frame until the already-mounted incoming preview reports readiness.
          // B still receives its real current local frame while hidden above.
          if (fallbackPlacement != null && fallbackIndex != null) {
            nextMounted.add(fallbackIndex);
            layers.add(
              _structuralLayer(
                placementIndex: fallbackIndex,
                placement: fallbackPlacement,
                localFrame: fallbackPlacement.effectiveDurationFrames - 1,
                visible: true,
              ),
            );
          }
        }

        _readyPlacements.removeWhere(
          (int index) => !nextMounted.contains(index),
        );
        _mountedPlacements
          ..clear()
          ..addAll(nextMounted);

        return Stack(
          fit: StackFit.expand,
          children: layers,
        );
      },
    );
  }
}
