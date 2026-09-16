// ./lib/dossier_presentation.dart
//
// Pure explicit-time choreography for one DOSSIER presentation.
//
// DOSSIER already exists in the terminal SceneEngine. This file does not paint
// it and does not add another clock. It extracts the presentation's internal
// stage arithmetic so Preview and BAKE can ask the same question: "what exact
// DOSSIER stage owns local frame N?"
//
// The original terminal DOSSIER named its second half around a gallery moving
// into "center stage". Structural DOSSIER deliberately no longer does that:
// the live video remains seated on the left while the right-hand presentation
// evolves from biography into evidence. Existing stage enum values and the
// centerMode/centerPageCount constructor spellings remain compatibility aliases
// because SceneEngine parity tests and older callers already use them. New code
// should reason in terms of [DossierEvidenceStage], [evidenceMode], and
// [evidencePageCount]. Script tokens remain GRID / MOSAIC / SIDE_ONLY.
//
// Generic animation lengths are constructor inputs on purpose. SceneEngine owns
// those constants; this timing model consumes them rather than declaring a
// competing copy. Stage sequence, optional branches, page repetition, zero-hold
// boundary convention, and total lifetime are owned here.

import 'presentation_requests.dart';

/// Historical DOSSIER timing slots retained for exact SceneEngine parity.
///
/// The names galleryOpening / center* describe the original terminal visual.
/// Structural presentation must use [DossierPresentationStageSemantics] rather
/// than infer current product behavior from those old labels.
enum DossierPresentationStage {
  opening,
  cardLead,
  galleryOpening,
  splitShowing,
  centerTransition,
  centerShowing,
  centerPanning,
  closing,
}

/// Product-facing meaning of the historical DOSSIER timing slots.
///
/// No value here implies that evidence owns the center of the desktop. Evidence
/// remains the right-hand sibling while the continuously-playing video stays in
/// the left structural seat.
enum DossierEvidenceStage {
  /// Biography/card and structural shell enter.
  opening,

  /// Optional biography-only authored hold.
  cardLead,

  /// Legacy gallery-opening timing runway after a card lead.
  ///
  /// Structural DOSSIER intentionally keeps the biography seated during this
  /// slot. Retaining the slot preserves authored/legacy lifetime without
  /// pretending a second gallery window is opening. The actual evidence reveal
  /// begins in [evidenceTransition].
  evidencePrepare,

  /// Biography remains fully seated for the authored split hold.
  splitShowing,

  /// Biography yields to the right-hand evidence presentation.
  evidenceTransition,

  /// One GRID/MOSAIC evidence page is held on the right.
  evidenceShowing,

  /// MOSAIC only: outgoing right-hand evidence page pans to the next page.
  evidencePanning,

  /// The active right-hand presentation and shell exit.
  closing,
}

extension DossierPresentationStageSemantics on DossierPresentationStage {
  DossierEvidenceStage get evidenceStage {
    switch (this) {
      case DossierPresentationStage.opening:
        return DossierEvidenceStage.opening;
      case DossierPresentationStage.cardLead:
        return DossierEvidenceStage.cardLead;
      case DossierPresentationStage.galleryOpening:
        return DossierEvidenceStage.evidencePrepare;
      case DossierPresentationStage.splitShowing:
        return DossierEvidenceStage.splitShowing;
      case DossierPresentationStage.centerTransition:
        return DossierEvidenceStage.evidenceTransition;
      case DossierPresentationStage.centerShowing:
        return DossierEvidenceStage.evidenceShowing;
      case DossierPresentationStage.centerPanning:
        return DossierEvidenceStage.evidencePanning;
      case DossierPresentationStage.closing:
        return DossierEvidenceStage.closing;
    }
  }
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

  /// Current product-facing meaning of [stage].
  DossierEvidenceStage get evidenceStage => stage.evidenceStage;

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

  /// Historical field name retained for source compatibility.
  ///
  /// The page is actually the active right-hand evidence page in the current
  /// structural product model.
  final int? centerPageIndex;

  int? get evidencePageIndex => centerPageIndex;

  @override
  String toString() =>
      'DossierPresentationFrame(stage: $stage, evidenceStage: $evidenceStage, '
      'local: $localFrame, stageFrame: $stageFrame, '
      'duration: $stageDurationFrames, progress: $progress, '
      'page: $evidencePageIndex)';
}

/// Deterministic DOSSIER lifetime and per-frame stage state.
///
/// This excludes the terminal's outer zoom-out/zoom-in lifecycle. It begins on
/// the first visible DOSSIER opening frame and ends after DOSSIER closing, just
/// as CardPresentationTiming describes CARD independently of terminal staging.
class DossierPresentationTiming {
  const DossierPresentationTiming({
    required this.holdSplit,
    required this.holdFull,
    DossierCenterMode? evidenceMode,
    DossierCenterMode? centerMode,
    required this.cardLead,
    int? evidencePageCount,
    int? centerPageCount,
    required this.cardSlideFrames,
    required this.windowAnimFrames,
    required this.mosaicPanFrames,
  })  : evidenceMode = evidenceMode ?? centerMode ?? DossierCenterMode.grid,
        evidencePageCount = evidencePageCount ?? centerPageCount ?? 0,
        assert(holdSplit >= 0),
        assert(holdFull >= 0),
        assert(cardLead >= 0),
        assert((evidencePageCount ?? centerPageCount ?? 0) >= 0),
        assert(evidenceMode == null ||
            centerMode == null ||
            evidenceMode == centerMode),
        assert(evidencePageCount == null ||
            centerPageCount == null ||
            evidencePageCount == centerPageCount),
        assert(cardSlideFrames > 0),
        assert(windowAnimFrames > 0),
        assert(mosaicPanFrames > 0);

  factory DossierPresentationTiming.fromRequest(
    DossierRequest request, {
    int? evidencePageCount,
    int? centerPageCount,
    required int cardSlideFrames,
    required int windowAnimFrames,
    required int mosaicPanFrames,
  }) {
    return DossierPresentationTiming(
      holdSplit: request.holdSplit,
      holdFull: request.holdFull,
      evidenceMode: request.centerMode,
      cardLead: request.cardLead,
      evidencePageCount: evidencePageCount ?? centerPageCount ?? 0,
      cardSlideFrames: cardSlideFrames,
      windowAnimFrames: windowAnimFrames,
      mosaicPanFrames: mosaicPanFrames,
    );
  }

  final int holdSplit;
  final int holdFull;

  /// GRID / MOSAIC / SIDE_ONLY as evidence behavior on the right-hand side.
  final DossierCenterMode evidenceMode;

  /// Historical compatibility alias. New structural code should use
  /// [evidenceMode].
  DossierCenterMode get centerMode => evidenceMode;

  final int cardLead;

  /// Number of right-hand evidence pages available after the split.
  /// GRID resolves to one, SIDE_ONLY to zero, MOSAIC to the asset-backed count.
  final int evidencePageCount;

  /// Historical compatibility alias. New structural code should use
  /// [evidencePageCount].
  int get centerPageCount => evidencePageCount;

  /// Generic animation lengths supplied by the owning presentation system.
  final int cardSlideFrames;
  final int windowAnimFrames;
  final int mosaicPanFrames;

  bool get hasCardLead => cardLead > 0;
  bool get hasEvidenceSequence => evidenceMode != DossierCenterMode.sideOnly;

  /// Historical compatibility alias.
  bool get hasCenterStage => hasEvidenceSequence;

  int get splitShowingFrames => holdSplit < 1 ? 1 : holdSplit;
  int get evidenceShowingFrames => holdFull < 1 ? 1 : holdFull;

  /// Historical compatibility alias.
  int get centerShowingFrames => evidenceShowingFrames;

  int get resolvedEvidencePageCount {
    switch (evidenceMode) {
      case DossierCenterMode.sideOnly:
        return 0;
      case DossierCenterMode.grid:
        return 1;
      case DossierCenterMode.mosaic:
        return evidencePageCount < 1 ? 1 : evidencePageCount;
    }
  }

  /// Historical compatibility alias.
  int get resolvedCenterPageCount => resolvedEvidencePageCount;

  int get closingFrames => evidenceMode == DossierCenterMode.sideOnly
      ? cardSlideFrames
      : windowAnimFrames;

  /// Total visible DOSSIER frames, excluding terminal zoom-out/zoom-in.
  ///
  /// The evidencePrepare runway is deliberately retained when cardLead > 0.
  /// It is historical timing compatibility, not a hidden center-stage move.
  int get durationFrames {
    int total = cardSlideFrames;
    if (hasCardLead) {
      total += cardLead;
      total += windowAnimFrames; // evidence preparation runway
    }
    total += splitShowingFrames;

    if (hasEvidenceSequence) {
      total += windowAnimFrames; // biography -> evidence transition
      final int pages = resolvedEvidencePageCount;
      total += pages * evidenceShowingFrames;
      if (pages > 1) total += (pages - 1) * mosaicPanFrames;
    }

    total += closingFrames;
    return total;
  }

  /// Pure DOSSIER-local state at [localFrame]. Null means not active.
  ///
  /// Historical enum values are emitted so the old terminal parity surface
  /// remains byte-for-byte comparable. New structural consumers should read
  /// [DossierPresentationFrame.evidenceStage].
  DossierPresentationFrame? frameAt(int localFrame) {
    if (localFrame < 0 || localFrame >= durationFrames) return null;

    int cursor = 0;

    DossierPresentationFrame? take(
      DossierPresentationStage stage,
      int duration, {
      int? evidencePageIndex,
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
          centerPageIndex: evidencePageIndex,
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

    if (hasEvidenceSequence) {
      frame = take(
        DossierPresentationStage.centerTransition,
        windowAnimFrames,
      );
      if (frame != null) return frame;

      final int pages = resolvedEvidencePageCount;
      for (int page = 0; page < pages; page++) {
        frame = take(
          DossierPresentationStage.centerShowing,
          evidenceShowingFrames,
          evidencePageIndex: page,
        );
        if (frame != null) return frame;

        if (page + 1 < pages) {
          frame = take(
            DossierPresentationStage.centerPanning,
            mosaicPanFrames,
            evidencePageIndex: page,
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
      'lead: $cardLead, evidenceMode: $evidenceMode, '
      'pages: $resolvedEvidencePageCount, duration: $durationFrames)';
}
