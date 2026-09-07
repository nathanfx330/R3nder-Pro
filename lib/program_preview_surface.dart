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
// APPSWITCH:SLIDE preloads the next structural source while the current source
// is still playing. A zero-opacity preload can decode and become logically ready
// without ever painting: Flutter's opacity render object skips painting a child
// at alpha zero. For that reason readiness alone is not enough to release the
// outgoing shell. On every seamless marker hand-off the incoming shell paints
// at opacity one underneath the outgoing shell. Only after the incoming source
// is ready and has completed one active paint does PREVIEW remove the outgoing
// cover. Project time never pauses and the incoming source never restarts.

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

  /// Readiness is valid only while the keyed preview instance is still mounted.
  /// This rejects stale callbacks after a scrub/remount of the same placement.
  final Set<int> _readyPlacements = <int>{};
  final Set<int> _mountedPlacements = <int>{};

  /// A seamless incoming placement may displace its outgoing cover only after
  /// it has completed one active paint while ready. Hidden preload paints do
  /// not count because an opacity-zero subtree is not painted by Flutter.
  final Set<int> _readyPaintedPlacements = <int>{};
  final Set<int> _readyPaintCommitScheduled = <int>{};

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
      _readyPaintedPlacements.clear();
      _readyPaintCommitScheduled.clear();
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

  void _scheduleReadyPaintCommit(int placementIndex) {
    if (_readyPaintedPlacements.contains(placementIndex) ||
        _readyPaintCommitScheduled.contains(placementIndex)) {
      return;
    }

    _readyPaintCommitScheduled.add(placementIndex);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _readyPaintCommitScheduled.remove(placementIndex);
      if (!mounted || !_readyPlacements.contains(placementIndex)) return;

      final StructuralRuntimeMarker? marker =
          parseStructuralRuntimeRegion(widget.scene.terminal.currentRegion);
      if (marker == null || marker.placementIndex != placementIndex) return;
      if (!_mountedPlacements.contains(placementIndex)) return;
      if (_readyPaintedPlacements.contains(placementIndex)) return;

      setState(() => _readyPaintedPlacements.add(placementIndex));
    });
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
        final Set<int> previouslyMounted = Set<int>.of(_mountedPlacements);
        final Set<int> nextMounted = <int>{};

        final StructuralRuntimeMarker? marker =
            parseStructuralRuntimeRegion(widget.scene.terminal.currentRegion);
        final StructuralSequencePlacement? placement =
            _activePlacement(marker);
        final int? activeIndex = marker == null || placement == null
            ? null
            : marker.placementIndex;

        // A hidden preload has not completed an active paint. Clearing this for
        // every non-active index also makes a scrubbed/re-entered handoff earn a
        // fresh overlap instead of reusing an old presentation commit.
        _readyPaintedPlacements.removeWhere(
          (int index) => index != activeIndex,
        );

        final List<Widget> layers = <Widget>[
          CustomPaint(
            size: Size.infinite,
            painter: ScenePainter(
              scene: widget.scene,
              fontFamily: widget.fontFamily,
            ),
          ),
        ];

        if (marker != null && placement != null && activeIndex != null) {
          final StructuralSequencePlacement? preload =
              _preloadPlacement(marker, placement);

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
          final bool activeReadyPainted =
              _readyPaintedPlacements.contains(activeIndex);

          int? fallbackIndex;
          StructuralSequencePlacement? fallbackPlacement;
          if (placement.seamlessFromPrevious && !activeReadyPainted) {
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

          // B is always fully paintable once it becomes active. Until it has
          // completed one active ready paint, A is added afterwards and remains
          // the topmost visual cover. This is unconditional for seamless
          // handoffs, including the common case where B decoded while hidden.
          nextMounted.add(activeIndex);
          layers.add(
            _structuralLayer(
              placementIndex: activeIndex,
              placement: placement,
              localFrame: _localFrame(marker),
              visible: true,
            ),
          );

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

          if (placement.seamlessFromPrevious && activeReady) {
            _scheduleReadyPaintCommit(activeIndex);
          }
        }

        _readyPlacements.removeWhere(
          (int index) => !nextMounted.contains(index),
        );
        _readyPaintedPlacements.removeWhere(
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
