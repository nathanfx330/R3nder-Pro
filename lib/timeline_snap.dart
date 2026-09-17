// ./lib/timeline_snap.dart
//
// Pure timeline snapping helpers. These functions do not mutate source; they
// only project a raw gesture frame onto nearby authored/playhead anchors.

enum TimelineSnapEdge { leading, trailing }

class TimelineSnapResult {
  final int frame;
  final int? anchorFrame;
  final TimelineSnapEdge? edge;

  const TimelineSnapResult({
    required this.frame,
    required this.anchorFrame,
    required this.edge,
  });

  bool get snapped => anchorFrame != null;
}

TimelineSnapResult snapTimelinePosition({
  required int rawFrame,
  required Iterable<int> anchors,
  required int thresholdFrames,
}) {
  final int frame = rawFrame < 0 ? 0 : rawFrame;
  final int threshold = thresholdFrames < 0 ? 0 : thresholdFrames;

  int? bestAnchor;
  int bestDistance = threshold + 1;
  for (final int anchor in anchors) {
    if (anchor < 0) continue;
    final int distance = (frame - anchor).abs();
    if (distance < bestDistance ||
        (distance == bestDistance &&
            bestAnchor != null &&
            anchor < bestAnchor)) {
      bestAnchor = anchor;
      bestDistance = distance;
    }
  }

  if (bestAnchor == null || bestDistance > threshold) {
    return TimelineSnapResult(frame: frame, anchorFrame: null, edge: null);
  }

  return TimelineSnapResult(
    frame: bestAnchor,
    anchorFrame: bestAnchor,
    edge: TimelineSnapEdge.leading,
  );
}

TimelineSnapResult snapTimelineMove({
  required int rawAtFrame,
  required int durationFrames,
  required Iterable<int> anchors,
  required int thresholdFrames,
}) {
  if (durationFrames <= 0) {
    throw ArgumentError.value(
      durationFrames,
      'durationFrames',
      'Must be positive.',
    );
  }

  final int raw = rawAtFrame < 0 ? 0 : rawAtFrame;
  final int threshold = thresholdFrames < 0 ? 0 : thresholdFrames;

  int bestFrame = raw;
  int? bestAnchor;
  TimelineSnapEdge? bestEdge;
  int bestDistance = threshold + 1;

  void consider({
    required int candidateFrame,
    required int anchor,
    required TimelineSnapEdge edge,
    required int distance,
  }) {
    if (candidateFrame < 0 || distance > threshold) return;
    final bool better =
        distance < bestDistance ||
        (distance == bestDistance &&
            (bestEdge == TimelineSnapEdge.trailing &&
                edge == TimelineSnapEdge.leading)) ||
        (distance == bestDistance &&
            bestEdge == edge &&
            bestAnchor != null &&
            anchor < bestAnchor!);
    if (!better) return;

    bestFrame = candidateFrame;
    bestAnchor = anchor;
    bestEdge = edge;
    bestDistance = distance;
  }

  for (final int anchor in anchors) {
    if (anchor < 0) continue;

    consider(
      candidateFrame: anchor,
      anchor: anchor,
      edge: TimelineSnapEdge.leading,
      distance: (raw - anchor).abs(),
    );

    final int trailingCandidate = anchor - durationFrames;
    consider(
      candidateFrame: trailingCandidate,
      anchor: anchor,
      edge: TimelineSnapEdge.trailing,
      distance: (raw + durationFrames - anchor).abs(),
    );
  }

  return TimelineSnapResult(
    frame: bestFrame,
    anchorFrame: bestAnchor,
    edge: bestEdge,
  );
}
