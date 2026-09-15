// ./lib/card_presentation.dart
//
// The CARD object's own presentation choreography, expressed as a pure
// function of authored hold plus an explicit local frame.
//
// This library deliberately knows nothing about SceneEngine, ScenePhase, the
// terminal, the desktop, or the zoom lifecycle that currently surrounds a CARD
// in TEXT. Those belong to whoever is presenting the card, not to the card.
// TEXT wraps this in terminal zoom-out, a parked terminal and a bare desktop;
// a structural CUE can later composite the panel over continuously advancing
// video. Both consume the same arithmetic, so neither can drift from the other.
//
// Nothing here is mutable and nothing accumulates. frameAt(n) is answerable in
// any order, which is what lets a CARD be scrubbed, re-evaluated at an
// arbitrary structural frame, and rendered identically in Preview and Bake.

/// Info-card slide timing: frames for the panel to slide in from (and back
/// out to) the right edge. The hold duration comes from the [CARD] tag.
///
/// This is the single authority for card slide length. SceneEngine imports this
/// library rather than declaring its own copy. TIMELINE also reuses this slide
/// duration for its panel open and close choreography.
const int kCardSlideFrames = 16;

/// Where a CARD is within its own presentation, independent of how the caller
/// stages it.
enum CardPresentationStage {
  /// Panel travelling in from the right edge.
  opening,

  /// Panel fully seated, counting down the authored hold.
  showing,

  /// Panel travelling back out to the right edge.
  closing,
}

/// The visual state of a CARD at one visible local frame.
class CardPresentationFrame {
  const CardPresentationFrame({
    required this.stage,
    required this.slide,
  });

  final CardPresentationStage stage;

  /// 0..1 how far the panel has slid ON screen. 0 = fully off the right edge,
  /// 1 = fully seated.
  ///
  /// The boundary convention is inherited from the existing SceneEngine phase
  /// runner and is load-bearing. Opening runs 0/kCardSlideFrames through
  /// (kCardSlideFrames - 1)/kCardSlideFrames and therefore never reports 1.0.
  /// Exactly 1.0 appears on the first showing frame. Closing ends at
  /// 1/kCardSlideFrames and therefore never reports 0.0; on the next frame the
  /// presentation is simply absent. Normalising either ramp by (n - 1) would
  /// move every motion frame relative to the structural video underneath it.
  final double slide;

  @override
  String toString() =>
      'CardPresentationFrame(stage: $stage, slide: $slide)';
}

/// Deterministic lifetime and per-frame state for one authored CARD.
class CardPresentationTiming {
  const CardPresentationTiming({required this.holdFrames});

  /// The authored hold exactly as written in the [CARD] tag. The grammar
  /// accepts zero and the presentation request preserves it unchanged.
  final int holdFrames;

  /// Visible frames in the showing stage.
  ///
  /// SceneEngine advances a phase when `_phaseVisualFrames + 1 >= duration`.
  /// A zero-duration showing phase therefore still has its age-zero frame
  /// drawn before the transition fires. Preserve that historical one-frame
  /// seated CARD rather than silently shortening existing `[CARD:...:0]` tags.
  int get showingFrames => holdFrames < 1 ? 1 : holdFrames;

  /// Total visible CARD frames, excluding the TEXT-only terminal zoom out and
  /// zoom in lifecycle around it.
  int get durationFrames =>
      kCardSlideFrames + showingFrames + kCardSlideFrames;

  int get showingStartFrame => kCardSlideFrames;

  int get closingStartFrame => kCardSlideFrames + showingFrames;

  /// Visual state at [localFrame], measured from the first opening frame.
  ///
  /// Null means the CARD is not active. Returning null before frame zero is
  /// intentional: a future structural compositor will naturally evaluate
  /// project frames before a cue trigger, and that is absence rather than an
  /// exceptional condition or a hidden pre-roll state.
  CardPresentationFrame? frameAt(int localFrame) {
    if (localFrame < 0 || localFrame >= durationFrames) return null;

    if (localFrame < showingStartFrame) {
      return CardPresentationFrame(
        stage: CardPresentationStage.opening,
        slide: slideAtStageAge(
          CardPresentationStage.opening,
          localFrame,
        ),
      );
    }

    if (localFrame < closingStartFrame) {
      return const CardPresentationFrame(
        stage: CardPresentationStage.showing,
        slide: 1.0,
      );
    }

    final int ageInClosing = localFrame - closingStartFrame;
    return CardPresentationFrame(
      stage: CardPresentationStage.closing,
      slide: slideAtStageAge(
        CardPresentationStage.closing,
        ageInClosing,
      ),
    );
  }

  /// Slide for a stage and an age measured from that stage's first visible
  /// frame.
  ///
  /// This second coordinate entry point exists for SceneEngine, which already
  /// tracks the active phase and its age. [frameAt] and the phase-driven TEXT
  /// path therefore share one arithmetic implementation without adding a
  /// second mutable CARD clock.
  static double slideAtStageAge(
    CardPresentationStage stage,
    int ageInStage,
  ) {
    switch (stage) {
      case CardPresentationStage.opening:
        return (ageInStage / kCardSlideFrames).clamp(0.0, 1.0);
      case CardPresentationStage.showing:
        return 1.0;
      case CardPresentationStage.closing:
        return 1.0 -
            (ageInStage / kCardSlideFrames).clamp(0.0, 1.0);
    }
  }

  @override
  bool operator ==(Object other) =>
      other is CardPresentationTiming && other.holdFrames == holdFrames;

  @override
  int get hashCode => holdFrames.hashCode;

  @override
  String toString() =>
      'CardPresentationTiming(hold: $holdFrames, duration: $durationFrames)';
}
