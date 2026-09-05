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

/// A structural source uses the same terminal-to-desktop and window-open
/// timing as the rest of R3nder's desktop presentations.
const int kStructuralZoomFrames = kZoomAnimFrames;
const int kStructuralWindowFrames = kWindowAnimFrames;
const int kStructuralEntryFrames =
    kStructuralZoomFrames + kStructuralWindowFrames;
const int kStructuralExitFrames =
    kStructuralWindowFrames + kStructuralZoomFrames;

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

class StructuralSequencePlacement {
  final StructuralSourceRef sourceRef;
  final int lineIndex;
  final int startOffset;
  final int endOffset;

  /// Authored source duration from EDIT/MOSAIC. This is the number of frames
  /// the structural compositor itself advances.
  final int sourceDurationFrames;

  /// Full main-sequence duration including desktop reveal/open/close/restore.
  /// This is what TerminalEngine burns as the placement's PAUSE projection.
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
/// projection can burn a single harmless frame instead of typing literal
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

/// Replaces sequence placements in an already root-stripped engine projection
/// with ordinary PAUSE tags covering the full structural presentation event.
///
/// The source itself still owns only its authored frames. The PAUSE also buys
/// the deterministic terminal zoom and window open/close frames, which keeps
/// the main sequence, narration bed, scrubber, and visible desktop transition
/// on one shared frame count.
String projectStructuralSequencePlacements({
  required String rawDocument,
  required String projectedSource,
}) {
  final EditDocumentModel? model = _tryModel(rawDocument);
  final List<RegExpMatch> matches =
      _placementLine.allMatches(projectedSource).toList(growable: false);
  if (matches.isEmpty) return projectedSource;

  String out = projectedSource;
  for (final RegExpMatch match in matches.reversed) {
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

    final int duration = sourceDuration > 0
        ? structuralSequenceDurationForSource(sourceDuration)
        : 1;

    final String indent = match.namedGroup('indent') ?? '';
    final String trail = match.namedGroup('trail') ?? '';
    out = out.replaceRange(
      match.start,
      match.end,
      '$indent[PAUSE:$duration]$trail',
    );
  }
  return out;
}
