// ./lib/dossier_presentation.dart
//
// Pure explicit-time choreography for one DOSSIER presentation.
//
// DOSSIER already exists in the terminal SceneEngine. This file does not paint
// it and does not add another clock. It extracts the presentation's internal
// stage arithmetic so any future structural compositor can ask the same
// question as Preview/BAKE: "what exact DOSSIER stage owns local frame N?"
//
// The generic desktop animation lengths are constructor inputs on purpose.
// kWindowAnimFrames and kAppPanFrames are currently owned by SceneEngine; this
// model consumes those values rather than declaring competing copies. CARD's
// slide length is supplied for the same reason. The stage sequence, optional
// branches, page repetition, zero-hold boundary convention, and total lifetime
// are owned here.

import 'presentation_requests.dart';

/// The DOSSIER-local stage visible at one explicit presentation frame.
enum DossierPresentationStage {
  /// Card enters. With cardLead == 0 the side gallery enters simultaneously,
  /// preserving the original DOSSIER behavior.
  opening,

  /// Optional card-only seated hold before any gallery appears.
  cardLead,

  /// Optional gallery-window entrance after a scripted card lead.
  galleryOpening,

  /// Card and side gallery are both seated.
  splitShowing,

  /// Card leaves while the gallery moves into center stage.
  centerTransition,

  /// Center-stage grid/mosaic page is held.
  centerShowing,

  /// MOSAIC only: outgoing center page pans to the next page.
  centerPanning,

  /// Final exit. SIDE_ONLY uses the card-slide duration; center modes use the
  /// ordinary window-animation duration, matching the existing SceneEngine.
  closing,
}

/// One visible frame of DOSSIER-local choreography.
class DossierPresentationFrame {
  const DossierPresentationFrame({
    required this.stage,
    required this.localFrame,
    required this.stageFrame,
    required this.stageDurationFrames,
    required this.progress,
    this.centerPageIndex,
  });

  final DossierPresentationStage stage;

  /// Age inside the entire DOSSIER presentation, beginning at opening frame 0.
  final int localFrame;

  /// Age inside [stage], beginning at zero on its first visible frame.
  final int stageFrame;

  /// Number of visible frames owned by this stage instance.
  final int stageDurationFrames;

  /// Linear 0..1 stage progress using the same boundary convention as CARD and
  /// SceneEngine: the final visible animation frame is (duration - 1)/duration,
  /// not 1.0. The next stage owns the next frame.
  final double progress;

  /// Center page being shown, or the outgoing page during [centerPanning].
  /// Null before/after center stage and for SIDE_ONLY.
  final int? centerPageIndex;

  @override
  String toString() =>
      'DossierPresentationFrame(stage: $stage, local: $localFrame, '
      'stageFrame: $stageFrame, duration: $stageDurationFrames, '
      'progress: $progress, page: $centerPageIndex)';
}

/// Deterministic DOSSIER lifetime and per-frame stage state.
///
/// This excludes the terminal's outer zoom-out/zoom-in lifecycle. It begins on
/// the first visible DOSSIER opening frame and ends after DOSSIER closing, just
/// as [CardPresentationTiming] describes CARD independently of terminal staging.
class DossierPresentationTiming {
  const DossierPresentationTiming({
    required this.holdSplit,
    required this.holdFull,
    required this.centerMode,
    required this.cardLead,
    required this.centerPageCount,
    required this.cardSlideFrames,
    required this.windowAnimFrames,
    required this.mosaicPanFrames,
  })  : assert(holdSplit >= 0),
        assert(holdFull >= 0),
        assert(cardLead >= 0),
        assert(centerPageCount >= 0),
        assert(cardSlideFrames > 0),
        assert(windowAnimFrames > 0),
        assert(mosaicPanFrames > 0);

  factory DossierPresentationTiming.fromRequest(
    DossierRequest request, {
    required int centerPageCount,
    required int cardSlideFrames,
    required int windowAnimFrames,
    required int mosaicPanFrames,
  }) {
    return DossierPresentationTiming(
      holdSplit: request.holdSplit,
      holdFull: request.holdFull,
      centerMode: request.centerMode,
      cardLead: request.cardLead,
      centerPageCount: centerPageCount,
      cardSlideFrames: cardSlideFrames,
      windowAnimFrames: windowAnimFrames,
      mosaicPanFrames: mosaicPanFrames,
    );
  }

  final int holdSplit;
  final int holdFull;
  final DossierCenterMode centerMode;
  final int cardLead;

  /// Number of center-stage pages available after the split.
  ///
  /// GRID always resolves to one page and SIDE_ONLY to zero. MOSAIC uses at
  /// least one page whenever center stage exists; callers may pass the actual
  /// decoded/layout page count without teaching this timing model about assets.
  final int centerPageCount;

  /// Generic animation lengths supplied by the owning presentation system.
  final int cardSlideFrames;
  final int windowAnimFrames;
  final int mosaicPanFrames;

  bool get hasCardLead => cardLead > 0;
  bool get hasCenterStage => centerMode != DossierCenterMode.sideOnly;

  int get splitShowingFrames => holdSplit < 1 ? 1 : holdSplit;
  int get centerShowingFrames => holdFull < 1 ? 1 : holdFull;

  int get resolvedCenterPageCount {
    switch (centerMode) {
      case DossierCenterMode.sideOnly:
        return 0;
      case DossierCenterMode.grid:
        return 1;
      case DossierCenterMode.mosaic:
        return centerPageCount < 1 ? 1 : centerPageCount;
    }
  }

  int get closingFrames => centerMode == DossierCenterMode.sideOnly
      ? cardSlideFrames
      : windowAnimFrames;

  /// Total visible DOSSIER frames, excluding terminal zoom-out/zoom-in.
  int get durationFrames {
    int total = cardSlideFrames;
    if (hasCardLead) {
      total += cardLead;
      total += windowAnimFrames;
    }
    total += splitShowingFrames;

    if (hasCenterStage) {
      total += windowAnimFrames; // split -> center transition
      final int pages = resolvedCenterPageCount;
      total += pages * centerShowingFrames;
      if (pages > 1) total += (pages - 1) * mosaicPanFrames;
    }

    total += closingFrames;
    return total;
  }

  /// Pure DOSSIER-local state at [localFrame]. Null means not active.
  DossierPresentationFrame? frameAt(int localFrame) {
    if (localFrame < 0 || localFrame >= durationFrames) return null;

    int cursor = 0;

    DossierPresentationFrame? take(
      DossierPresentationStage stage,
      int duration, {
      int? centerPageIndex,
    }) {
      final int end = cursor + duration;
      if (localFrame >= cursor && localFrame < end) {
        final int age = localFrame - cursor;
        return DossierPresentationFrame(
          stage: stage,
          localFrame: localFrame,
          stageFrame: age,
          stageDurationFrames: duration,
          progress: age / duration,
          centerPageIndex: centerPageIndex,
        );
      }
      cursor = end;
      return null;
    }

    DossierPresentationFrame? frame = take(
      DossierPresentationStage.opening,
      cardSlideFrames,
    );
    if (frame != null) return frame;

    if (hasCardLead) {
      frame = take(DossierPresentationStage.cardLead, cardLead);
      if (frame != null) return frame;

      frame = take(
        DossierPresentationStage.galleryOpening,
        windowAnimFrames,
      );
      if (frame != null) return frame;
    }

    frame = take(
      DossierPresentationStage.splitShowing,
      splitShowingFrames,
    );
    if (frame != null) return frame;

    if (hasCenterStage) {
      frame = take(
        DossierPresentationStage.centerTransition,
        windowAnimFrames,
      );
      if (frame != null) return frame;

      final int pages = resolvedCenterPageCount;
      for (int page = 0; page < pages; page++) {
        frame = take(
          DossierPresentationStage.centerShowing,
          centerShowingFrames,
          centerPageIndex: page,
        );
        if (frame != null) return frame;

        if (page + 1 < pages) {
          frame = take(
            DossierPresentationStage.centerPanning,
            mosaicPanFrames,
            centerPageIndex: page,
          );
          if (frame != null) return frame;
        }
      }
    }

    return take(DossierPresentationStage.closing, closingFrames);
  }

  @override
  String toString() =>
      'DossierPresentationTiming(split: $holdSplit, full: $holdFull, '
      'lead: $cardLead, mode: $centerMode, pages: $resolvedCenterPageCount, '
      'duration: $durationFrames)';
}
