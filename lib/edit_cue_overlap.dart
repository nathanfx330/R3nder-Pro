// ./lib/edit_cue_overlap.dart
//
// Resolver-aware projection and collision policy for clip-local CUEs.
//
// Parser/runtime tolerance is deliberately broader than GUI authoring policy.
// Existing overlapping source remains valid and deterministic. This layer only
// projects occupied ranges and reports authoring-conflict intersections so
// new edits can be rejected and the EDIT surface can warn about overlaps later
// by slip, trim, speed, or workspace asset changes.

import 'card_presentation.dart';
import 'edit_cue.dart';
import 'edit_surface_model.dart';
import 'maximize_presentation.dart';
import 'presentation_requests.dart';

typedef DossierCueDurationFramesResolver = int Function(
  DossierRequest request,
);

enum CueCollisionLane {
  presentation,
  shell,
}


/// Semantic lanes remain distinct for rendering and diagnostics, but current
/// authoring policy treats every CUE interval as mutually exclusive.
///
/// Keep this as an explicit matrix rather than collapsing the lanes: MAXIMIZE
/// is still shell geometry rather than content presentation, and a future cue
/// kind can change compatibility here without rewriting projection/UI meaning.
bool cueCollisionLanesConflict(
  CueCollisionLane first,
  CueCollisionLane second,
) {
  switch (first) {
    case CueCollisionLane.presentation:
      switch (second) {
        case CueCollisionLane.presentation:
        case CueCollisionLane.shell:
          return true;
      }
    case CueCollisionLane.shell:
      switch (second) {
        case CueCollisionLane.presentation:
        case CueCollisionLane.shell:
          return true;
      }
  }
}

enum CuePayloadKind {
  card,
  sideCard,
  dossier,
  maximize,
}

extension CuePayloadKindLabel on CuePayloadKind {
  String get label {
    switch (this) {
      case CuePayloadKind.card:
        return 'CARD';
      case CuePayloadKind.sideCard:
        return 'SIDECARD';
      case CuePayloadKind.dossier:
        return 'DOSSIER';
      case CuePayloadKind.maximize:
        return 'MAXIMIZE';
    }
  }
}

class CueOccupiedSpan {
  const CueOccupiedSpan({
    required this.lane,
    required this.kind,
    required this.trackId,
    required this.clipId,
    required this.sourceFrame,
    required this.range,
    this.sourceStartOffset,
  });

  final CueCollisionLane lane;
  final CuePayloadKind kind;
  final String trackId;
  final String clipId;
  final int sourceFrame;
  final CueOccupiedRange range;

  /// Absolute source offset of an already-authored CUE.
  ///
  /// Null for a candidate that has not been serialized yet. Existing cue
  /// offsets are unique inside one document and therefore make edit self-
  /// exclusion independent of per-family indexes.
  final int? sourceStartOffset;
}

class CueOverlapDiagnostic {
  const CueOverlapDiagnostic(this.first, this.second);

  final CueOccupiedSpan first;
  final CueOccupiedSpan second;

  String get message =>
      '${first.kind.label} ${first.range} in '
      '${first.trackId}/${first.clipId} overlaps '
      '${second.kind.label} ${second.range} in '
      '${second.trackId}/${second.clipId}.';
}

int resolvedDossierCueDurationFrames(
  DossierRequest request,
  DossierCueDurationFramesResolver? resolver,
) {
  if (resolver == null) {
    throw StateError(
      'DOSSIER cue overlap projection requires a resolved duration.',
    );
  }
  final int durationFrames = resolver(request);
  if (durationFrames <= 0) {
    throw StateError(
      'Resolved DOSSIER cue duration must be positive, got $durationFrames.',
    );
  }
  return durationFrames;
}

/// Projects every currently active CUE trigger in one authored EDIT.
///
/// Dormant cues whose source trigger is outside the current CLIP source window
/// are omitted. DOSSIER duration is injected by the caller so this layer never
/// reaches into the filesystem and remains deterministic for a given resolver.
List<CueOccupiedSpan> projectCueOccupiedSpans(
  EditSurfaceDocument document, {
  DossierCueDurationFramesResolver? dossierDurationFramesFor,
}) {
  final List<CueOccupiedSpan> spans = <CueOccupiedSpan>[];

  for (final EditSurfaceTrack track in document.tracks) {
    for (final EditSurfaceClip surfaceClip in track.clips) {
      final clip = surfaceClip.clip;

      for (final EditCardCue cue in parseClipCardCues(clip)) {
        final CueOccupiedRange? range = cueOccupiedRange(
          clip,
          cue.sourceFrame,
          CardPresentationTiming(
            holdFrames: cue.card.holdFrames,
          ).durationFrames,
        );
        if (range == null) continue;
        spans.add(
          CueOccupiedSpan(
            lane: CueCollisionLane.presentation,
            kind: cue.isSideCard
                ? CuePayloadKind.sideCard
                : CuePayloadKind.card,
            trackId: track.id,
            clipId: surfaceClip.id,
            sourceFrame: cue.sourceFrame,
            range: range,
            sourceStartOffset: cue.startOffset,
          ),
        );
      }

      for (final EditDossierCue cue in parseClipDossierCues(clip)) {
        // Do not resolve assets for an inert cue.
        if (cueProjectFrame(clip, cue.sourceFrame) == null) continue;
        final CueOccupiedRange? range = cueOccupiedRange(
          clip,
          cue.sourceFrame,
          resolvedDossierCueDurationFrames(
            cue.dossier,
            dossierDurationFramesFor,
          ),
        );
        if (range == null) continue;
        spans.add(
          CueOccupiedSpan(
            lane: CueCollisionLane.presentation,
            kind: CuePayloadKind.dossier,
            trackId: track.id,
            clipId: surfaceClip.id,
            sourceFrame: cue.sourceFrame,
            range: range,
            sourceStartOffset: cue.startOffset,
          ),
        );
      }

      for (final EditMaximizeCue cue in parseClipMaximizeCues(clip)) {
        final CueOccupiedRange? range = cueOccupiedRange(
          clip,
          cue.sourceFrame,
          MaximizePresentationTiming(
            holdFrames: cue.holdFrames,
          ).durationFrames,
        );
        if (range == null) continue;
        spans.add(
          CueOccupiedSpan(
            lane: CueCollisionLane.shell,
            kind: CuePayloadKind.maximize,
            trackId: track.id,
            clipId: surfaceClip.id,
            sourceFrame: cue.sourceFrame,
            range: range,
            sourceStartOffset: cue.startOffset,
          ),
        );
      }
    }
  }

  spans.sort((CueOccupiedSpan a, CueOccupiedSpan b) {
    final int byStart = a.range.startFrame.compareTo(b.range.startFrame);
    if (byStart != 0) return byStart;
    final int byLane = a.lane.index.compareTo(b.lane.index);
    if (byLane != 0) return byLane;
    return (a.sourceStartOffset ?? -1).compareTo(b.sourceStartOffset ?? -1);
  });
  return List<CueOccupiedSpan>.unmodifiable(spans);
}

CueOccupiedSpan? firstCueOverlap({
  required EditSurfaceDocument document,
  required CueOccupiedSpan candidate,
  DossierCueDurationFramesResolver? dossierDurationFramesFor,
  int? excludingSourceStartOffset,
}) {
  for (final CueOccupiedSpan existing in projectCueOccupiedSpans(
    document,
    dossierDurationFramesFor: dossierDurationFramesFor,
  )) {
    if (existing.sourceStartOffset == excludingSourceStartOffset) continue;
    if (!cueCollisionLanesConflict(existing.lane, candidate.lane)) continue;
    if (candidate.range.overlaps(existing.range)) return existing;
  }
  return null;
}

/// Resolver-aware diagnostics for legacy overlap and overlap introduced later by
/// clip geometry or workspace asset changes.
///
/// This is intentionally not source lint. The same script can produce a
/// different result when a DOSSIER evidence folder changes.
List<CueOverlapDiagnostic> cueOverlapDiagnostics(
  EditSurfaceDocument document, {
  DossierCueDurationFramesResolver? dossierDurationFramesFor,
}) {
  return cueOverlapDiagnosticsForSpans(
    projectCueOccupiedSpans(
      document,
      dossierDurationFramesFor: dossierDurationFramesFor,
    ),
  );
}

List<CueOverlapDiagnostic> cueOverlapDiagnosticsForSpans(
  List<CueOccupiedSpan> spans,
) {
  final List<CueOverlapDiagnostic> out = <CueOverlapDiagnostic>[];

  for (int i = 0; i < spans.length; i++) {
    final CueOccupiedSpan first = spans[i];
    for (int j = i + 1; j < spans.length; j++) {
      final CueOccupiedSpan second = spans[j];
      if (second.range.startFrame >= first.range.endFrameExclusive) {
        break;
      }
      if (!cueCollisionLanesConflict(first.lane, second.lane)) continue;
      if (!first.range.overlaps(second.range)) continue;
      out.add(CueOverlapDiagnostic(first, second));
    }
  }

  return List<CueOverlapDiagnostic>.unmodifiable(out);
}
