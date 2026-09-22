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
// at alpha zero. For that reason readiness alone cannot begin the visual switch.
// On every seamless marker hand-off the horizontal pan remains a pure function
// of authored incoming source time: outgoing client left, incoming client from
// the right, fixed shell.
//
// A cold FIRST opening is different. If its first presentable video frame is not
// resident when the authored window-opening budget begins, this surface can
// report a transport buffer request to its owner. The owner may hold wall-clock
// playback at that authored opening frame until readiness arrives, then resume
// from the same project frame. No project frames are inserted and BAKE is
// unaffected.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'media_layer.dart';
import 'scene_engine.dart';
import 'scene_painter.dart';
import 'structural_sequence.dart';
import 'structural_sequence_preview.dart';
import 'structural_shell_geometry.dart';
import 'ui_theme.dart';

@immutable
class StructuralPreviewBufferingState {
  final bool buffering;
  final int placementIndex;
  final int openingFrame;

  const StructuralPreviewBufferingState({
    required this.buffering,
    required this.placementIndex,
    required this.openingFrame,
  });

  static const StructuralPreviewBufferingState idle =
      StructuralPreviewBufferingState(
    buffering: false,
    placementIndex: -1,
    openingFrame: 0,
  );

  @override
  bool operator ==(Object other) =>
      other is StructuralPreviewBufferingState &&
      other.buffering == buffering &&
      other.placementIndex == placementIndex &&
      other.openingFrame == openingFrame;

  @override
  int get hashCode => Object.hash(buffering, placementIndex, openingFrame);
}

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

  /// Focused-test seam for delaying parent acceptance of a decoder readiness
  /// notification without changing decoder behavior. Production leaves null.
  @visibleForTesting
  final void Function(int placementIndex, VoidCallback accept)?
      structuralReadinessInterceptor;

  /// Live playback coordination seam. A cold structural source can require
  /// real wall-clock decode time before its first authored window-opening
  /// frame is paintable. When provided, PREVIEW reports that hold instead of
  /// silently spending the authored opening budget while pixels are pending.
  ///
  /// The callback owns transport policy. ProgramPreviewSurface never mutates
  /// project time itself; it only reports whether the active opening is
  /// waiting for first-frame readiness.
  final ValueChanged<StructuralPreviewBufferingState>?
      onStructuralBufferingChanged;

  const ProgramPreviewSurface({
    super.key,
    required this.repaint,
    required this.scene,
    required this.rawDocument,
    required this.fontFamily,
    required this.theme,
    this.structuralBackend,
    this.structuralResolveSource,
    this.structuralReadinessInterceptor,
    this.onStructuralBufferingChanged,
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

  /// Child preview readiness reports, independent of whether a focused test
  /// interceptor has delayed parent acceptance. This distinguishes a decoder
  /// that was genuinely late from one that was already paintable during
  /// preload but whose acceptance callback was intentionally withheld.
  final Set<int> _reportedReadyPlacements = <int>{};

  /// Tracks whether an incoming placement has completed one active paint after
  /// readiness. This remains diagnostic/state information only; authored slide
  /// geometry must never depend on it.
  final Set<int> _readyPaintedPlacements = <int>{};
  final Set<int> _readyPaintCommitScheduled = <int>{};

  /// Placements that became active before their preload had resolved.
  ///
  /// Early-ready placements retain the outgoing client for the complete
  /// authored APPSWITCH slide. Late-ready placements instead retain it only
  /// until one active-ready paint has completed, then release the cover
  /// without restarting or delaying authored source time.
  final Set<int> _lateReadyActivePlacements = <int>{};

  StructuralPreviewBufferingState _reportedBuffering =
      StructuralPreviewBufferingState.idle;
  StructuralPreviewBufferingState _pendingBuffering =
      StructuralPreviewBufferingState.idle;
  bool _bufferingReportScheduled = false;

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
            oldWidget.structuralResolveSource != widget.structuralResolveSource ||
            oldWidget.structuralReadinessInterceptor !=
                widget.structuralReadinessInterceptor;
    if (oldWidget.rawDocument != widget.rawDocument) {
      _placements = parseStructuralSequencePlacements(widget.rawDocument);
    }
    if (previewIdentityChanged) {
      _readyPlacements.clear();
      _mountedPlacements.clear();
      _reportedReadyPlacements.clear();
      _readyPaintedPlacements.clear();
      _readyPaintCommitScheduled.clear();
      _lateReadyActivePlacements.clear();
      _reportedBuffering = StructuralPreviewBufferingState.idle;
      _pendingBuffering = StructuralPreviewBufferingState.idle;
      _bufferingReportScheduled = false;
    }
  }

  void _reportStructuralBuffering(
    StructuralPreviewBufferingState next,
  ) {
    final ValueChanged<StructuralPreviewBufferingState>? callback =
        widget.onStructuralBufferingChanged;
    if (callback == null) return;

    _pendingBuffering = next;
    if (_bufferingReportScheduled) return;
    _bufferingReportScheduled = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bufferingReportScheduled = false;
      if (!mounted) return;
      final StructuralPreviewBufferingState pending = _pendingBuffering;
      if (pending == _reportedBuffering) return;
      _reportedBuffering = pending;
      callback(pending);
    });
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
    double layerOpacity = 1.0,
    StructuralSequenceHandoffRole handoffRole =
        StructuralSequenceHandoffRole.none,
    double handoffSlideT = 0.0,
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
      onFirstFrameReady: () {
        if (mounted && _mountedPlacements.contains(placementIndex)) {
          _reportedReadyPlacements.add(placementIndex);
        }
        final interceptor = widget.structuralReadinessInterceptor;
        if (interceptor == null) {
          _markPlacementReady(placementIndex);
          return;
        }
        interceptor(
          placementIndex,
          () => _markPlacementReady(placementIndex),
        );
      },
      handoffRole: handoffRole,
      handoffSlideT: handoffSlideT,
    );

    return Positioned.fill(
      key: ValueKey<String>('program-struct-layer-$placementIndex'),
      child: IgnorePointer(
        ignoring: !visible,
        child: Opacity(
          opacity: visible
              ? layerOpacity.clamp(0.0, 1.0).toDouble()
              : 0.0,
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

          final int activeLocalFrame = _localFrame(marker);
          final bool readinessResident =
              _readyPlacements.contains(activeIndex);
          final bool activeReady = previouslyMounted.contains(activeIndex) &&
              readinessResident;
          final bool coldOpening =
              placement.stageAt(activeLocalFrame) ==
                      StructuralSequenceStage.opening &&
                  !readinessResident;
          _reportStructuralBuffering(
            coldOpening
                ? StructuralPreviewBufferingState(
                    buffering: true,
                    placementIndex: activeIndex,
                    openingFrame: placement.stageFrameAt(activeLocalFrame),
                  )
                : StructuralPreviewBufferingState.idle,
          );
          final bool readinessReportedBeforeActive =
              _reportedReadyPlacements.contains(activeIndex);
          if (placement.seamlessFromPrevious &&
              !readinessReportedBeforeActive) {
            _lateReadyActivePlacements.add(activeIndex);
          }
          final bool activeReadyPainted =
              _readyPaintedPlacements.contains(activeIndex);
          final bool lateReadyActive =
              _lateReadyActivePlacements.contains(activeIndex);
          final int activeSourceFrame =
              placement.sourceFrameAt(activeLocalFrame);

          final int previousIndex = activeIndex - 1;
          final StructuralSequencePlacement? previousPlacement =
              placement.seamlessFromPrevious
                  ? _placementAt(previousIndex)
                  : null;
          final bool previousCanHandoff = previousPlacement != null &&
              previousPlacement.seamlessToNext &&
              previouslyMounted.contains(previousIndex);
          final bool splitBoundary = previousCanHandoff &&
              (previousPlacement!.splitWindow || placement.splitWindow);
          final bool splitShapeChange = splitBoundary &&
              previousPlacement!.presentationShape !=
                  placement.presentationShape;
          final bool splitEntryBudgetOpen = splitShapeChange &&
              placement.stageAt(activeLocalFrame) ==
                  StructuralSequenceStage.opening;

          final bool handoffWindowOpen = !splitBoundary &&
              placement.seamlessFromPrevious &&
              structuralSwitchSlideWindowOpen(
                sourceFrame: activeSourceFrame,
                sourceDurationFrames: placement.sourceDurationFrames,
              );
          final double handoffSlideT = handoffWindowOpen
              ? structuralSwitchSlideT(
                  sourceFrame: activeSourceFrame,
                  sourceDurationFrames: placement.sourceDurationFrames,
                )
              : 0.0;

          int? fallbackIndex;
          StructuralSequencePlacement? fallbackPlacement;
          bool fallbackIsHeldSplit = false;

          if (splitBoundary &&
              (splitEntryBudgetOpen || !activeReadyPainted)) {
            fallbackIndex = previousIndex;
            fallbackPlacement = previousPlacement;
            fallbackIsHeldSplit = true;
          } else if (handoffWindowOpen &&
              previousCanHandoff &&
              (!lateReadyActive || !activeReadyPainted)) {
            fallbackIndex = previousIndex;
            fallbackPlacement = previousPlacement;
          }

          // Split boundaries never pan one pane independently. The incoming
          // placement can paint underneath its stationary outgoing cover once
          // its authored entry budget has elapsed. Readiness controls only the
          // reveal; source time and geometry continue to follow the runtime
          // marker.
          const bool activeVisible = true;

          nextMounted.add(activeIndex);
          final Widget activeLayer = _structuralLayer(
            placementIndex: activeIndex,
            placement: placement,
            localFrame: activeLocalFrame,
            visible: activeVisible,
            handoffRole: handoffWindowOpen
                ? StructuralSequenceHandoffRole.incoming
                : StructuralSequenceHandoffRole.none,
            handoffSlideT: handoffSlideT,
          );

          if (fallbackPlacement != null && fallbackIndex != null) {
            nextMounted.add(fallbackIndex);
            final double heldOpacity =
                fallbackIsHeldSplit && splitEntryBudgetOpen && activeReady
                    ? structuralShapeOutgoingOpacity(
                        placement.stageProgressAt(activeLocalFrame),
                      )
                    : 1.0;
            final Widget fallbackLayer = _structuralLayer(
              placementIndex: fallbackIndex,
              placement: fallbackPlacement,
              localFrame: fallbackPlacement.effectiveDurationFrames - 1,
              visible: true,
              layerOpacity: heldOpacity,
              handoffRole: fallbackIsHeldSplit
                  ? StructuralSequenceHandoffRole.heldOutgoing
                  : StructuralSequenceHandoffRole.outgoing,
              handoffSlideT: handoffSlideT,
            );

            // Once the incoming shape is ready during its authored opening
            // budget, Preview matches BAKE: fading outgoing below, growing
            // incoming above. Before readiness (and for the old late-ready
            // cover path) the outgoing layer stays on top.
            if (fallbackIsHeldSplit && splitEntryBudgetOpen && activeReady) {
              layers
                ..add(fallbackLayer)
                ..add(activeLayer);
            } else {
              layers
                ..add(activeLayer)
                ..add(fallbackLayer);
            }
          } else {
            layers.add(activeLayer);
          }

          if (placement.seamlessFromPrevious && activeReady) {
            // During a split shape-entry budget the incoming presentation now
            // paints visibly underneath the authored outgoing cover. It may
            // therefore earn its one active-ready paint during the budget.
            // The cover still cannot disappear early because
            // splitEntryBudgetOpen independently keeps it mounted until the
            // authored window budget ends.
            _scheduleReadyPaintCommit(activeIndex);
          }
        }

        if (marker == null || placement == null || activeIndex == null) {
          _reportStructuralBuffering(StructuralPreviewBufferingState.idle);
        }

        _readyPlacements.removeWhere(
          (int index) => !nextMounted.contains(index),
        );
        _reportedReadyPlacements.removeWhere(
          (int index) => !nextMounted.contains(index),
        );
        _readyPaintedPlacements.removeWhere(
          (int index) => !nextMounted.contains(index),
        );
        _lateReadyActivePlacements.removeWhere(
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
