// ./lib/edit_cue_sliding.dart
//
// Pure cue-range drag geometry.
//
// A drag snapshots the occupied spans that exist when the gesture begins.
// Pointer movement never resolves assets and never mutates source. Hard walls
// come only from conflicting spans that were not overlapping the moving cue at
// drag start. Legacy starting partners remain passable so tolerated source can
// be repaired instead of trapped.

import 'edit_cue.dart';
import 'edit_cue_overlap.dart';
import 'edit_model.dart';
import 'edit_surface_model.dart';

enum CueMovePreviewState {
  valid,
  invalidPassable,
  blocked,
}

class CueMoveBaseline {
  CueMoveBaseline({
    required this.sourceStartOffset,
    required this.trackId,
    required this.clipId,
    required this.lane,
    required this.kind,
    required this.originalStartFrame,
    required this.durationFrames,
    required this.clipAtFrame,
    required this.clipDurationFrames,
    required this.speed,
    required Set<int> startingPartnerStartOffsets,
    required this.startingTotalOverlapFrames,
    required this.minimumStartFrame,
    required this.maximumStartFrame,
    required List<CueOccupiedSpan> snapshotConflictSpans,
  })  : startingPartnerStartOffsets =
            Set<int>.unmodifiable(startingPartnerStartOffsets),
        snapshotConflictSpans =
            List<CueOccupiedSpan>.unmodifiable(snapshotConflictSpans);

  final int sourceStartOffset;
  final String trackId;
  final String clipId;
  final CueCollisionLane lane;
  final CuePayloadKind kind;
  final int originalStartFrame;
  final int durationFrames;
  final int clipAtFrame;
  final int clipDurationFrames;
  final ExactClipSpeed speed;
  final Set<int> startingPartnerStartOffsets;
  final int startingTotalOverlapFrames;
  final int minimumStartFrame;
  final int maximumStartFrame;
  final List<CueOccupiedSpan> snapshotConflictSpans;
}

class CueMovePreview {
  const CueMovePreview({
    required this.requestedStartFrame,
    required this.startFrame,
    required this.range,
    required this.state,
    required this.partnerStartOffsets,
    required this.totalOverlapFrames,
  });

  final int requestedStartFrame;
  final int startFrame;
  final CueOccupiedRange range;
  final CueMovePreviewState state;
  final Set<int> partnerStartOffsets;
  final int totalOverlapFrames;

  /// BLOCKED means the pointer pushed through a hard wall, but the rendered
  /// range itself is clamped to a legal boundary and may still be committed.
  bool get canCommit => state != CueMovePreviewState.invalidPassable;
}

class CueMoveCommitValidation {
  const CueMoveCommitValidation({
    required this.isLegal,
    required this.partnerStartOffsets,
    required this.totalOverlapFrames,
    this.message,
  });

  final bool isLegal;
  final Set<int> partnerStartOffsets;
  final int totalOverlapFrames;
  final String? message;
}

CueMoveBaseline beginCueMove({
  required CueOccupiedSpan moving,
  required EditSurfaceClip clip,
  required List<CueOccupiedSpan> spans,
}) {
  final int? sourceStartOffset = moving.sourceStartOffset;
  if (sourceStartOffset == null) {
    throw ArgumentError('Authored CUE span requires sourceStartOffset.');
  }
  if (moving.trackId != clip.trackId || moving.clipId != clip.id) {
    throw ArgumentError('Moving CUE span does not belong to the supplied CLIP.');
  }

  final List<CueOccupiedSpan> conflicts = spans
      .where(
        (CueOccupiedSpan span) =>
            span.sourceStartOffset != sourceStartOffset &&
            cueCollisionLanesConflict(span.lane, moving.lane),
      )
      .toList(growable: false);

  final Set<int> startingPartners = <int>{};
  int startingTotalOverlapFrames = 0;
  for (final CueOccupiedSpan other in conflicts) {
    final int overlap = moving.range.intersectionFrames(other.range);
    if (overlap <= 0) continue;
    final int? otherOffset = other.sourceStartOffset;
    if (otherOffset == null) continue;
    startingPartners.add(otherOffset);
    startingTotalOverlapFrames += overlap;
  }

  int leftWall = clip.atFrame;
  final int clipMaximumOffset = reachableCueProjectOffsetAtOrBefore(
    clip.clip.speed,
    clip.durationFrames - 1,
  );
  int rightWall = clip.atFrame + clipMaximumOffset;

  for (final CueOccupiedSpan other in conflicts) {
    final int? otherOffset = other.sourceStartOffset;
    if (otherOffset != null && startingPartners.contains(otherOffset)) {
      continue;
    }

    if (other.range.endFrameExclusive <= moving.range.startFrame) {
      if (other.range.endFrameExclusive > leftWall) {
        leftWall = other.range.endFrameExclusive;
      }
      continue;
    }

    if (other.range.startFrame >= moving.range.endFrameExclusive) {
      final int candidate =
          other.range.startFrame - moving.range.endFrameExclusive +
              moving.range.startFrame;
      if (candidate < rightWall) rightWall = candidate;
      continue;
    }

    throw StateError(
      'Non-partner conflicting CUE unexpectedly intersects the moving CUE.',
    );
  }

  final int minimumStartFrame = clip.atFrame +
      reachableCueProjectOffsetAtOrAfter(
        clip.clip.speed,
        leftWall - clip.atFrame,
      );
  final int maximumStartFrame = clip.atFrame +
      reachableCueProjectOffsetAtOrBefore(
        clip.clip.speed,
        rightWall - clip.atFrame,
      );

  if (minimumStartFrame > moving.range.startFrame ||
      maximumStartFrame < moving.range.startFrame ||
      minimumStartFrame > maximumStartFrame) {
    throw StateError(
      'CUE drag hard-wall interval does not contain its authored trigger.',
    );
  }

  return CueMoveBaseline(
    sourceStartOffset: sourceStartOffset,
    trackId: clip.trackId,
    clipId: clip.id,
    lane: moving.lane,
    kind: moving.kind,
    originalStartFrame: moving.range.startFrame,
    durationFrames: moving.range.endFrameExclusive - moving.range.startFrame,
    clipAtFrame: clip.atFrame,
    clipDurationFrames: clip.durationFrames,
    speed: clip.clip.speed,
    startingPartnerStartOffsets: startingPartners,
    startingTotalOverlapFrames: startingTotalOverlapFrames,
    minimumStartFrame: minimumStartFrame,
    maximumStartFrame: maximumStartFrame,
    snapshotConflictSpans: conflicts,
  );
}

CueMovePreview evaluateCueMove(
  CueMoveBaseline baseline,
  int requestedStartFrame,
) {
  final int bounded = requestedStartFrame.clamp(
    baseline.minimumStartFrame,
    baseline.maximumStartFrame,
  );
  final int localRequested = bounded - baseline.clipAtFrame;
  int projected = baseline.clipAtFrame +
      nearestReachableCueProjectOffset(
        baseline.speed,
        localRequested,
      );
  if (projected < baseline.minimumStartFrame) {
    projected = baseline.minimumStartFrame;
  } else if (projected > baseline.maximumStartFrame) {
    projected = baseline.maximumStartFrame;
  }

  final CueOccupiedRange range = CueOccupiedRange(
    startFrame: projected,
    endFrameExclusive: projected + baseline.durationFrames,
  );
  final _CuePartnerMeasure measure = _measurePartners(
    lane: baseline.lane,
    movingSourceStartOffset: baseline.sourceStartOffset,
    range: range,
    spans: baseline.snapshotConflictSpans,
  );

  final bool hasNewPartner = measure.partnerStartOffsets.any(
    (int offset) => !baseline.startingPartnerStartOffsets.contains(offset),
  );
  final bool pushedHardWall =
      requestedStartFrame < baseline.minimumStartFrame ||
          requestedStartFrame > baseline.maximumStartFrame;

  final CueMovePreviewState state;
  if (pushedHardWall || hasNewPartner) {
    state = CueMovePreviewState.blocked;
  } else if (measure.totalOverlapFrames >
      baseline.startingTotalOverlapFrames) {
    state = CueMovePreviewState.invalidPassable;
  } else {
    state = CueMovePreviewState.valid;
  }

  return CueMovePreview(
    requestedStartFrame: requestedStartFrame,
    startFrame: projected,
    range: range,
    state: state,
    partnerStartOffsets:
        Set<int>.unmodifiable(measure.partnerStartOffsets),
    totalOverlapFrames: measure.totalOverlapFrames,
  );
}

CueMoveCommitValidation validateCueMoveCommit({
  required CueMoveBaseline baseline,
  required CueOccupiedSpan candidate,
  required List<CueOccupiedSpan> freshSpans,
}) {
  final _CuePartnerMeasure measure = _measurePartners(
    lane: candidate.lane,
    movingSourceStartOffset: baseline.sourceStartOffset,
    range: candidate.range,
    spans: freshSpans,
  );
  final Set<int> newPartners = measure.partnerStartOffsets
      .where(
        (int offset) => !baseline.startingPartnerStartOffsets.contains(offset),
      )
      .toSet();

  if (newPartners.isNotEmpty) {
    return CueMoveCommitValidation(
      isLegal: false,
      partnerStartOffsets:
          Set<int>.unmodifiable(measure.partnerStartOffsets),
      totalOverlapFrames: measure.totalOverlapFrames,
      message: 'CUE move would introduce a new conflicting overlap.',
    );
  }
  if (measure.totalOverlapFrames > baseline.startingTotalOverlapFrames) {
    return CueMoveCommitValidation(
      isLegal: false,
      partnerStartOffsets:
          Set<int>.unmodifiable(measure.partnerStartOffsets),
      totalOverlapFrames: measure.totalOverlapFrames,
      message: 'CUE move would worsen an existing overlap.',
    );
  }

  return CueMoveCommitValidation(
    isLegal: true,
    partnerStartOffsets: Set<int>.unmodifiable(measure.partnerStartOffsets),
    totalOverlapFrames: measure.totalOverlapFrames,
  );
}

class _CuePartnerMeasure {
  const _CuePartnerMeasure(
    this.partnerStartOffsets,
    this.totalOverlapFrames,
  );

  final Set<int> partnerStartOffsets;
  final int totalOverlapFrames;
}

_CuePartnerMeasure _measurePartners({
  required CueCollisionLane lane,
  required int movingSourceStartOffset,
  required CueOccupiedRange range,
  required Iterable<CueOccupiedSpan> spans,
}) {
  final Set<int> partners = <int>{};
  int total = 0;

  for (final CueOccupiedSpan other in spans) {
    if (!cueCollisionLanesConflict(other.lane, lane) ||
        other.sourceStartOffset == movingSourceStartOffset) {
      continue;
    }
    final int overlap = range.intersectionFrames(other.range);
    if (overlap <= 0) continue;
    final int? otherOffset = other.sourceStartOffset;
    if (otherOffset == null) continue;
    partners.add(otherOffset);
    total += overlap;
  }

  return _CuePartnerMeasure(partners, total);
}
