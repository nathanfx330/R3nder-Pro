// ./lib/scene_evaluator.dart
//
// ProjectTime-facing evaluation seam for the existing deterministic scene
// engine. This is intentionally a compatibility layer, not the finished
// direct-time implementation.
//
// Today SceneEngine is still a state machine advanced by tick(). This file
// gives callers the contract we actually want to keep: ask for one explicit
// ProjectTime and receive the scene evaluated as far toward that time as the
// caller's work budget allows. Forward evaluation advances the existing
// deterministic machine. Backward evaluation resets and replays. As
// individual effects become direct-time evaluators, their implementations can
// move behind this seam without changing callers again.
//
// The legacy engine is frame-discrete. A ProjectTime sampled between frames
// therefore evaluates the containing whole frame, [time.frame]. The exact
// rational phase is preserved on the request for future interpolation, but it
// does not affect scene content yet. Epoch and clock mode belong to scheduling
// and invalidation; they do not alter deterministic scene content.

import 'project_clock.dart';
import 'scene_engine.dart';

/// Result of evaluating a mutable SceneEngine toward an explicit project time.
///
/// [exact] means the engine reached the requested whole project frame. The
/// current frame-discrete scene does not yet evaluate sub-frame phase. It is
/// false when a bounded evaluation stopped before that frame, or when the
/// requested frame lies beyond the point where the scene reports finished.
class SceneEvaluationResult {
  final ProjectTime requested;
  final int reachedFrame;
  final bool finished;

  const SceneEvaluationResult({
    required this.requested,
    required this.reachedFrame,
    required this.finished,
  });

  bool get exact => reachedFrame == requested.frame;
}

/// Explicit-time evaluation contract for SceneEngine.
///
/// This extension is the migration boundary. Callers should move toward
/// [evaluate] instead of owning reset/tick loops themselves. The implementation
/// may still replay today; later direct-time evaluators and snapshot restoration
/// can replace that machinery behind the same API.
extension SceneProjectEvaluation on SceneEngine {
  SceneEvaluationResult evaluate(
    ProjectTime time, {
    int? maxForwardFrames,
  }) {
    if (time.frame < 0) {
      throw ArgumentError.value(
        time.frame,
        'time.frame',
        'Project frame must be zero or greater.',
      );
    }
    if (maxForwardFrames != null && maxForwardFrames <= 0) {
      throw ArgumentError.value(
        maxForwardFrames,
        'maxForwardFrames',
        'Forward frame budget must be greater than zero.',
      );
    }

    if (time.frame < frameCount) {
      reset();
    }

    final int remaining = time.frame - frameCount;
    final int budget = maxForwardFrames == null
        ? remaining
        : remaining.clamp(0, maxForwardFrames).toInt();

    int advanced = 0;
    while (advanced < budget && !isFinished) {
      tick();
      advanced++;
    }

    return SceneEvaluationResult(
      requested: time,
      reachedFrame: frameCount,
      finished: isFinished,
    );
  }
}
