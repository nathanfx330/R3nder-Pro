// ./lib/structural_sequence.dart
//
// Main-sequence placement for structural EDIT / MOSAIC sources.
//
// EDIT and MOSAIC blocks are reusable source definitions. They do not consume
// TerminalEngine time merely because they exist in the document. A standalone
// [STRUCT:EDIT.foo] or [STRUCT:MOSAIC.bar] line is the sequence-side reference
// that says "play this source here".
//
// The placement carries no authored duration. Its length comes from the source
// definition itself, which keeps the trim/cut layer below the main sequence and
// prevents the same shot from having two independent frame-count fields.

import 'edit_model.dart';

final RegExp _placementLine = RegExp(
  r'^(?<indent>[ \t]*)\[STRUCT:(?<source>(?:EDIT|MOSAIC)\.[A-Za-z0-9_-]+)\](?<trail>[ \t]*)$',
  multiLine: true,
);

class StructuralSequencePlacement {
  final StructuralSourceRef sourceRef;
  final int lineIndex;
  final int startOffset;
  final int endOffset;
  final int durationFrames;

  const StructuralSequencePlacement({
    required this.sourceRef,
    required this.lineIndex,
    required this.startOffset,
    required this.endOffset,
    required this.durationFrames,
  });

  bool get resolves => durationFrames > 0;
  int get effectiveDurationFrames => durationFrames > 0 ? durationFrames : 1;
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

    int duration = 0;
    if (model != null && model.containsStructuralSource(ref)) {
      try {
        duration = model.structuralSourceFrameCount(ref);
      } catch (_) {
        duration = 0;
      }
    }

    out.add(
      StructuralSequencePlacement(
        sourceRef: ref,
        lineIndex: _lineForOffset(starts, match.start),
        startOffset: match.start,
        endOffset: match.end,
        durationFrames: duration,
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
/// with ordinary PAUSE tags of the exact structural-source duration.
///
/// TerminalEngine therefore owns timing exactly as it already does for every
/// other hold, while EDIT/MOSAIC rendering remains a separate presentation
/// layer. Definitions were removed before this function is called, so a
/// placement authored inside a source block can never accidentally schedule
/// the source definition itself.
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

    int duration = 0;
    if (ref != null && ref.id.isNotEmpty && model != null) {
      if (model.containsStructuralSource(ref)) {
        try {
          duration = model.structuralSourceFrameCount(ref);
        } catch (_) {
          duration = 0;
        }
      }
    }

    if (duration <= 0) duration = 1;

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
