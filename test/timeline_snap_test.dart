// ./test/timeline_snap_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/timeline_snap.dart';

void main() {
  test('crossfade overlap exposes only outer clip edges as snap anchors', () {
    final List<int> anchors = exposedTimelineSnapAnchors(
      spans: const <TimelineSnapSpan>[
        TimelineSnapSpan(id: 'a', startFrame: 0, endFrameExclusive: 80),
        TimelineSnapSpan(id: 'b', startFrame: 56, endFrameExclusive: 136),
      ],
      playheadFrame: 200,
    );

    expect(anchors, <int>[0, 136, 200]);
    expect(anchors, isNot(contains(56)));
    expect(anchors, isNot(contains(80)));
  });

  test('excluding the dragged clip removes its own edges before exposure test', () {
    final List<int> anchors = exposedTimelineSnapAnchors(
      spans: const <TimelineSnapSpan>[
        TimelineSnapSpan(id: 'moving', startFrame: 40, endFrameExclusive: 60),
        TimelineSnapSpan(id: 'base', startFrame: 100, endFrameExclusive: 140),
      ],
      playheadFrame: 10,
      excludingId: 'moving',
    );

    expect(anchors, <int>[0, 10, 100, 140]);
  });

  test('position snaps to nearby anchor and preserves distant raw frame', () {
    final TimelineSnapResult near = snapTimelinePosition(
      rawFrame: 48,
      anchors: const <int>[0, 50, 100],
      thresholdFrames: 3,
    );
    expect(near.frame, 50);
    expect(near.anchorFrame, 50);
    expect(near.snapped, isTrue);

    final TimelineSnapResult far = snapTimelinePosition(
      rawFrame: 46,
      anchors: const <int>[0, 50, 100],
      thresholdFrames: 3,
    );
    expect(far.frame, 46);
    expect(far.snapped, isFalse);
  });

  test('move can snap either leading or trailing edge', () {
    final TimelineSnapResult leading = snapTimelineMove(
      rawAtFrame: 48,
      durationFrames: 20,
      anchors: const <int>[50, 100],
      thresholdFrames: 3,
    );
    expect(leading.frame, 50);
    expect(leading.anchorFrame, 50);
    expect(leading.edge, TimelineSnapEdge.leading);

    final TimelineSnapResult trailing = snapTimelineMove(
      rawAtFrame: 32,
      durationFrames: 20,
      anchors: const <int>[50, 100],
      thresholdFrames: 3,
    );
    expect(trailing.frame, 30);
    expect(trailing.anchorFrame, 50);
    expect(trailing.edge, TimelineSnapEdge.trailing);
  });

  test('move never produces a negative at frame from trailing snap', () {
    final TimelineSnapResult result = snapTimelineMove(
      rawAtFrame: 1,
      durationFrames: 20,
      anchors: const <int>[5],
      thresholdFrames: 20,
    );
    expect(result.frame, 5);
    expect(result.edge, TimelineSnapEdge.leading);
  });

  test('equal distance prefers leading-edge alignment deterministically', () {
    final TimelineSnapResult result = snapTimelineMove(
      rawAtFrame: 40,
      durationFrames: 20,
      anchors: const <int>[39, 61],
      thresholdFrames: 2,
    );
    expect(result.frame, 39);
    expect(result.anchorFrame, 39);
    expect(result.edge, TimelineSnapEdge.leading);
  });
}
