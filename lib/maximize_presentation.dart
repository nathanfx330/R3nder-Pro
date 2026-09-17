// ./lib/maximize_presentation.dart
//
// Deterministic lifetime for the clip-local MAXIMIZE shell cue.
//
// MAXIMIZE is not a presentation request: it paints no content. A CUE owns the
// source-relative trigger, this file owns only the cue's explicit-time shell
// amount, and STRUCT owns the desktop/window geometry that consumes it.
//
// Nothing here is mutable. Preview and BAKE can ask frameAt(n) in any order and
// receive the same answer without introducing another playback clock.

/// Fixed v1 transition budget for both window -> fullscreen and fullscreen ->
/// window. The authored MAXIMIZE number is the fullscreen hold only.
const int kMaximizeTransitionFrames = 12;

enum MaximizePresentationStage {
  entering,
  holding,
  returning,
}

class MaximizePresentationFrame {
  const MaximizePresentationFrame({
    required this.stage,
    required this.amount,
  });

  final MaximizePresentationStage stage;

  /// Linear 0..1 shell amount. Geometry applies the shared shell easing.
  /// 0 = normal structural window, 1 = full program frame.
  final double amount;
}

class MaximizePresentationTiming {
  const MaximizePresentationTiming({required this.holdFrames});

  /// Authored fullscreen dwell. Zero is meaningful: it produces a pure
  /// 12-frame punch in followed immediately by a 12-frame return.
  final int holdFrames;

  int get safeHoldFrames => holdFrames < 0 ? 0 : holdFrames;

  int get holdStartFrame => kMaximizeTransitionFrames;

  int get returnStartFrame => kMaximizeTransitionFrames + safeHoldFrames;

  int get durationFrames =>
      kMaximizeTransitionFrames + safeHoldFrames + kMaximizeTransitionFrames;

  MaximizePresentationFrame? frameAt(int localFrame) {
    if (localFrame < 0 || localFrame >= durationFrames) return null;

    if (localFrame < holdStartFrame) {
      return MaximizePresentationFrame(
        stage: MaximizePresentationStage.entering,
        amount: amountAtStageAge(
          MaximizePresentationStage.entering,
          localFrame,
        ),
      );
    }

    if (localFrame < returnStartFrame) {
      return const MaximizePresentationFrame(
        stage: MaximizePresentationStage.holding,
        amount: 1.0,
      );
    }

    return MaximizePresentationFrame(
      stage: MaximizePresentationStage.returning,
      amount: amountAtStageAge(
        MaximizePresentationStage.returning,
        localFrame - returnStartFrame,
      ),
    );
  }

  /// Uses the same boundary convention as CARD choreography: transition ages
  /// divide by N, not N - 1. Entering therefore ends at 11/12 and the next
  /// frame is exactly fullscreen. With zero hold that exact fullscreen frame is
  /// the first returning frame, giving a coherent 24-frame in-and-out cue with
  /// no invented dwell.
  static double amountAtStageAge(
    MaximizePresentationStage stage,
    int ageInStage,
  ) {
    switch (stage) {
      case MaximizePresentationStage.entering:
        return (ageInStage / kMaximizeTransitionFrames).clamp(0.0, 1.0);
      case MaximizePresentationStage.holding:
        return 1.0;
      case MaximizePresentationStage.returning:
        return 1.0 -
            (ageInStage / kMaximizeTransitionFrames).clamp(0.0, 1.0);
    }
  }

  @override
  bool operator ==(Object other) =>
      other is MaximizePresentationTiming && other.holdFrames == holdFrames;

  @override
  int get hashCode => holdFrames.hashCode;
}
