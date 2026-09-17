// ./test/maximize_presentation_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/maximize_presentation.dart';

void main() {
  test('authored number is fullscreen hold and transitions are fixed', () {
    const MaximizePresentationTiming timing =
        MaximizePresentationTiming(holdFrames: 180);

    expect(kMaximizeTransitionFrames, 12);
    expect(timing.holdStartFrame, 12);
    expect(timing.returnStartFrame, 192);
    expect(timing.durationFrames, 204);
  });

  test('zero hold is a coherent 24 frame punch with no invented dwell', () {
    const MaximizePresentationTiming timing =
        MaximizePresentationTiming(holdFrames: 0);

    expect(timing.durationFrames, 24);
    expect(timing.frameAt(0)!.stage, MaximizePresentationStage.entering);
    expect(timing.frameAt(0)!.amount, 0.0);
    expect(timing.frameAt(11)!.amount, closeTo(11 / 12, 1e-12));
    expect(timing.frameAt(12)!.stage, MaximizePresentationStage.returning);
    expect(timing.frameAt(12)!.amount, 1.0);
    expect(timing.frameAt(23)!.amount, closeTo(1 / 12, 1e-12));
    expect(timing.frameAt(24), isNull);
  });

  test('hold stage is exactly fullscreen', () {
    const MaximizePresentationTiming timing =
        MaximizePresentationTiming(holdFrames: 3);

    for (int frame = 12; frame < 15; frame++) {
      expect(timing.frameAt(frame)!.stage, MaximizePresentationStage.holding);
      expect(timing.frameAt(frame)!.amount, 1.0);
    }
    expect(timing.frameAt(-1), isNull);
    expect(timing.frameAt(timing.durationFrames), isNull);
  });
}
