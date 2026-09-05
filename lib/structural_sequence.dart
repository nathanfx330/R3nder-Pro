// ./lib/structural_sequence.dart
//
// Main-sequence placement for structural EDIT / MOSAIC sources.
//
// EDIT and MOSAIC blocks are reusable source definitions. They do not consume
// TerminalEngine time merely because they exist in the document. A standalone
// [STRUCT:EDIT.foo] or [STRUCT:MOSAIC.bar] line is the sequence-side reference
// that says "play this source here".
//
// The placement carries no authored duration. Its source hold comes from the
// definition itself. The main-sequence event also owns the same deterministic
// desktop reveal/open/close/restore budget used by the simulated window
// manager, so a STRUCT placement behaves like a presentation instead of a
// silent pause with a widget swapped on top of it.

import 'edit_model.dart';
import 'scene_engine.dart';

final RegExp _placementLine = RegExp(
  r'^(?<indent>[ \t]*)\[STRUCT:(?<source>(?:EDIT|MOSAIC)\.[A-Za-z0-9_-]+)\](?<trail>[ \t]*)$',
  multiLine: true,
);

final RegExp _runtimeRegionPattern = RegExp(
  r'^STRUCTSEQ_(?<index>\d+)_(?<duration>\d+)$',
);

/// A structural source uses the same terminal-to-desktop and window-open
/// timing as the rest of R3nder's desktop presentations.
const int kStructuralZoomFrames = kZoomAnimFrames;
const int kStructuralWindowFrames = kWindowAnimFrames;
const int kStructuralEntryFrames =
    kStructuralZoomFrames + kStructuralWindowFrames;
const int kStructuralExitFrames =
    kStructuralWindowFrames + kStructuralZoomFrames;

/// A standalone `[PAUSE:N]` line occupies two scene ticks beyond N in the
/// editor line-map execution path: entering the pause and advancing past the
/// line. STRUCT owns an exact presentation budget, so its projected PAUSE
/// argument compensates for those framing ticks instead of silently stretching
/// every structural call by two frames.
const int kStructuralProjectionFramingFrames = 2;

/// Prefix reserved for the engine-internal region used by real Preview/Bake.
/// It fits the existing REGION grammar, so no author-visible tag is added.
const String kStructuralRuntimeRegionPrefix = 'STRUCTSEQ_';

enum StructuralSequenceStage {
  zoomOut,
  opening,
  showing,
  closing,
  zoomIn,
}

int structuralSequenceDurationForSource(int sourceFrames) {
  if (sourceFrames <= 0) return 0;
  return kStructuralEntryFrames + sourceFrames + kStructuralExitFrames;
}

int _projectedPauseFramesForEvent(int eventFrames) {
  if (eventFrames <= 0) return 1;
  final int pauseFrames = eventFrames - kStructuralProjectionFramingFrames;
  return pauseFrames > 0 ? pauseFrames : 1;
}

/// Engine-visible identity for one live structural placement.
///
/// Preview/Bake compilation writes this into an internal REGION id before the
/// timing PAUSE. The terminal already exposes currentRegion, so the top-level
/// Preview can discover the active placement without a second line-map clock.
class StructuralRuntimeMarker {
  final int placementIndex;
  final int durationFrames;

  const StructuralRuntimeMarker({
    required this.placementIndex,
    required this.durationFrames,
  });

  String get regionId =>
      '$kStructuralRuntimeRegionPrefix${placementIndex}_$durationFrames';
}

StructuralRuntimeMarker? parseStructuralRuntimeRegion(String? regionId) {
  if (regionId == null) return null;
  final RegExpMatch? match = _runtimeRegionPattern.firstMatch(regionId);
  if (match == null) return null;

  final int? index = int.tryParse(match.namedGroup('index') ?? '');
  final int? duration = int.tryParse(match.namedGroup('duration') ?? '');
  if (index == null || index < 0 || duration == null || duration <= 0) {
    return null;
  }

  return StructuralRuntimeMarker(
    placementIndex: index,
    durationFrames: duration,
  );
}

/// Resolves the authored STRUCT local frame from terminal pause state.
///
/// Runtime projection is deliberately two deterministic parser phases:
///
///   frame 0  REGION marker
///   frame 1  PAUSE entry
///   frame 2+ explicit pause age
///
/// The REGION is kept through the tick that completes the pause, so the final
/// authored structural frame remains visible. On the next free terminal tick
/// engine_tick.dart clears the reserved region before ordinary script content
/// resumes.
int structuralRuntimeLocalFrame({
  required StructuralRuntimeMarker marker,
  required int pauseFramesRemaining,
  required bool awaitingPauseTag,
}) {
  final int duration = marker.durationFrames;
  if (duration <= 1) return 0;

  // Immediately after the REGION marker has been parsed, the internal PAUSE
  // is still the next token. That exact frame is authored local frame zero.
  if (awaitingPauseTag) return 0;

  if (pauseFramesRemaining > 0) {
    final int pauseBudget = _projectedPauseFramesForEvent(duration);
    return (1 + (pauseBudget - pauseFramesRemaining))
        .clamp(0, duration - 1)
        .toInt();
  }

  // The pause-completion tick intentionally keeps the structural REGION alive
  // for one paint. That is the final authored frame, not a stale extra hold.
  return duration - 1;
}

class StructuralSequencePlacement {
  final StructuralSourceRef sourceRef;
  final int lineIndex;
  final int startOffset;
  final int endOffset;

  /// Authored source duration from EDIT/MOSAIC. This is the number of frames
  /// the structural compositor itself advances.
  final int sourceDurationFrames;

  /// Full main-sequence duration including desktop reveal/open/close/restore.
  /// This is the exact scene-time budget of the STRUCT event.
  final int durationFrames;

  const StructuralSequencePlacement({
    required this.sourceRef,
    required this.lineIndex,
    required this.startOffset,
    required this.endOffset,
    required this.sourceDurationFrames,
    required this.durationFrames,
  });

  bool get resolves => sourceDurationFrames > 0;
  int get effectiveDurationFrames => durationFrames > 0 ? durationFrames : 1;

  int get contentStartFrame => kStructuralEntryFrames;
  int get contentEndFrameExclusive => contentStartFrame + sourceDurationFrames;

  StructuralSequenceStage stageAt(int sequenceFrame) {
    final int f = sequenceFrame
        .clamp(0, durationFrames > 0 ? durationFrames - 1 : 0)
        .toInt();
    if (f < kStructuralZoomFrames) return StructuralSequenceStage.zoomOut;
    if (f < kStructuralEntryFrames) return StructuralSequenceStage.opening;
    if (f < contentEndFrameExclusive) return StructuralSequenceStage.showing;
    if (f < contentEndFrameExclusive + kStructuralWindowFrames) {
      return StructuralSequenceStage.closing;
    }
    return StructuralSequenceStage.zoomIn;
  }

  int stageFrameAt(int sequenceFrame) {
    final int f = sequenceFrame
        .clamp(0, durationFrames > 0 ? durationFrames - 1 : 0)
        .toInt();
    switch (stageAt(f)) {
      case StructuralSequenceStage.zoomOut:
        return f;
      case StructuralSequenceStage.opening:
        return f - kStructuralZoomFrames;
      case StructuralSequenceStage.showing:
        return f - contentStartFrame;
      case StructuralSequenceStage.closing:
        return f - contentEndFrameExclusive;
      case StructuralSequenceStage.zoomIn:
        return f - contentEndFrameExclusive - kStructuralWindowFrames;
    }
  }

  double stageProgressAt(int sequenceFrame) {
    final StructuralSequenceStage stage = stageAt(sequenceFrame);
    final int frames = switch (stage) {
      StructuralSequenceStage.zoomOut || StructuralSequenceStage.zoomIn =>
        kStructuralZoomFrames,
      StructuralSequenceStage.opening || StructuralSequenceStage.closing =>
        kStructuralWindowFrames,
      StructuralSequenceStage.showing => sourceDurationFrames,
    };
    if (frames <= 1) return 1.0;
    return (stageFrameAt(sequenceFrame) / (frames - 1)).clamp(0.0, 1.0);
  }

  int sourceFrameAt(int sequenceFrame) {
    if (sourceDurationFrames <= 0) return 0;
    return (sequenceFrame - contentStartFrame)
        .clamp(0, sourceDurationFrames - 1)
        .toInt();
  }
}

List<int> _lineStarts(String source) {
  final List<int> starts = <int>[0];
  for (int i = 0; i < source.length; i++) {
    if (source.codeUnitAt(i) == 10) starts.add(i + 1);
  }
  return starts;
}

int _lineForOffset(List<int> starts, int offset) {
  int lo = 0;
  int hi = starts.length - 1;
  while (lo < hi) {
    final int mid = (lo + hi + 1) ~/ 2;
    if (starts[mid] <= offset) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo;
}

EditDocumentModel? _tryModel(String rawDocument) {
  try {
    return EditDocumentModel.parse(rawDocument);
  } catch (_) {
    return null;
  }
}

/// Returns every standalone structural placement in raw document order.
///
/// Invalid or temporarily incomplete structural source definitions do not make
/// the text editor crash while the author is typing. Their placements remain
/// visible with duration 0 so diagnostics can report them and the engine
/// projection can burn a small harmless fallback instead of typing literal
/// markup onto screen.
List<StructuralSequencePlacement> parseStructuralSequencePlacements(
  String rawDocument,
) {
  final EditDocumentModel? model = _tryModel(rawDocument);
  final List<int> starts = _lineStarts(rawDocument);
  final List<StructuralSequencePlacement> out = <StructuralSequencePlacement>[];

  for (final RegExpMatch match in _placementLine.allMatches(rawDocument)) {
    final StructuralSourceRef? ref =
        StructuralSourceRef.tryParse(match.namedGroup('source') ?? '');
    if (ref == null || ref.id.isEmpty) continue;

    int sourceDuration = 0;
    if (model != null && model.containsStructuralSource(ref)) {
      try {
        sourceDuration = model.structuralSourceFrameCount(ref);
      } catch (_) {
        sourceDuration = 0;
      }
    }

    out.add(
      StructuralSequencePlacement(
        sourceRef: ref,
        lineIndex: _lineForOffset(starts, match.start),
        startOffset: match.start,
        endOffset: match.end,
        sourceDurationFrames: sourceDuration,
        durationFrames: structuralSequenceDurationForSource(sourceDuration),
      ),
    );
  }

  return List<StructuralSequencePlacement>.unmodifiable(out);
}

/// Appends one structural source as the next event in the main TEXT sequence.
///
/// Source definitions remain where they already live. The sequence receives
/// only a lightweight reference and derives its duration from the selected
/// EDIT/MOSAIC definition. This is the serializer used by the EDIT workspace's
/// ADD TO SEQUENCE button, so the GUI never has to invent or duplicate frame
/// counts.
String appendStructuralSequencePlacement({
  required String rawDocument,
  required StructuralSourceRef sourceRef,
}) {
  final EditDocumentModel model = EditDocumentModel.parse(rawDocument);
  if (!model.containsStructuralSource(sourceRef)) {
    throw StateError('No structural source named ${sourceRef.canonicalSource}.');
  }

  final int duration = model.structuralSourceFrameCount(sourceRef);
  if (duration <= 0) {
    throw StateError('${sourceRef.canonicalSource} has no authored frames.');
  }

  final String newline = rawDocument.contains('\r\n') ? '\r\n' : '\n';
  final StringBuffer out = StringBuffer(rawDocument);
  if (rawDocument.isNotEmpty &&
      !rawDocument.endsWith('\n') &&
      !rawDocument.endsWith('\r')) {
    out.write(newline);
  }
  out.write('[STRUCT:${sourceRef.canonicalSource}]$newline');
  return out.toString();
}

/// Replaces sequence placements in an already root-stripped engine projection.
///
/// Editor line-map compilation uses a plain compensated PAUSE so its authored
/// line continues to own exactly the STRUCT event budget. Real Preview/Bake
/// compilation can request [runtimeMarkers], which writes an internal REGION
/// immediately before the same compensated PAUSE:
///
///   [REGION:STRUCTSEQ_0_383][PAUSE:381]
///
/// engine_tick.dart treats that reserved REGION as a one-frame structural
/// entry marker and clears it immediately after the pause completes. That
/// gives the top-level Preview an engine-owned active placement and local time
/// without changing author syntax, adding a second clock, or teaching MLT to
/// own sequence time.
///
/// Sequence placements are projected only after source definitions are gone,
/// so a `[STRUCT:...]` accidentally written inside a definition cannot schedule
/// itself into main program time.
String projectStructuralSequencePlacements({
  required String rawDocument,
  required String projectedSource,
  bool runtimeMarkers = false,
}) {
  final EditDocumentModel? model = _tryModel(rawDocument);
  final List<RegExpMatch> matches =
      _placementLine.allMatches(projectedSource).toList(growable: false);
  if (matches.isEmpty) return projectedSource;

  String out = projectedSource;
  for (int index = matches.length - 1; index >= 0; index--) {
    final RegExpMatch match = matches[index];
    final StructuralSourceRef? ref =
        StructuralSourceRef.tryParse(match.namedGroup('source') ?? '');

    int sourceDuration = 0;
    if (ref != null && ref.id.isNotEmpty && model != null) {
      if (model.containsStructuralSource(ref)) {
        try {
          sourceDuration = model.structuralSourceFrameCount(ref);
        } catch (_) {
          sourceDuration = 0;
        }
      }
    }

    final int eventDuration = sourceDuration > 0
        ? structuralSequenceDurationForSource(sourceDuration)
        : 0;
    final int pauseFrames = _projectedPauseFramesForEvent(eventDuration);

    final String indent = match.namedGroup('indent') ?? '';
    final String trail = match.namedGroup('trail') ?? '';

    String replacement;
    if (runtimeMarkers && eventDuration > 0) {
      final StructuralRuntimeMarker runtime = StructuralRuntimeMarker(
        placementIndex: index,
        durationFrames: eventDuration,
      );
      replacement =
          '$indent[REGION:${runtime.regionId}][PAUSE:$pauseFrames]$trail';
    } else {
      replacement = '$indent[PAUSE:$pauseFrames]$trail';
    }

    out = out.replaceRange(
      match.start,
      match.end,
      replacement,
    );
  }
  return out;
}
