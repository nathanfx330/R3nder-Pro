// ./lib/marker_authoring.dart
//
// Source-backed authoring for zero-time MARK definitions.
//
// MARK never becomes project database state. These helpers accept canonical
// script text and return canonical script text with one marker inserted at an
// authored ownership boundary. TEXT placement is positional in the document;
// EDIT placement is sequence-relative; CLIP placement is source-relative.

import 'edit_model.dart';
import 'marker_language.dart';
import 'script_cst.dart';

/// Inserts a positional TEXT marker at the program frame represented by
/// [rawLineAtFrame].
///
/// The marker is written as its own line immediately before the authored line
/// that owns [programFrame]. This gives the zero-time definition a stable
/// source position while the next simulation is free to rebuild every derived
/// frame mapping from source again.
String addTextMarkerAtProgramFrame({
  required String source,
  required List<int> rawLineAtFrame,
  required int programFrame,
  String label = '',
}) {
  if (programFrame < 0) {
    throw ArgumentError.value(
      programFrame,
      'programFrame',
      'Program frame must be non-negative.',
    );
  }

  final String tag = formatMarkerTag(label: label);
  if (rawLineAtFrame.isEmpty) {
    return _appendTopLevelLine(source, tag);
  }

  final int sample = programFrame.clamp(0, rawLineAtFrame.length - 1);
  int targetLine = rawLineAtFrame[sample];

  if (targetLine < 0) {
    // Presentation tail frames may briefly have no authored read-head line.
    // Search backward first because the marker was requested at this point in
    // already-visible program time; the last authored line is the least
    // surprising source anchor. If no earlier line exists, search forward.
    for (int i = sample - 1; i >= 0; i--) {
      if (rawLineAtFrame[i] >= 0) {
        targetLine = rawLineAtFrame[i];
        break;
      }
    }
    if (targetLine < 0) {
      for (int i = sample + 1; i < rawLineAtFrame.length; i++) {
        if (rawLineAtFrame[i] >= 0) {
          targetLine = rawLineAtFrame[i];
          break;
        }
      }
    }
  }

  if (targetLine < 0) return _appendTopLevelLine(source, tag);

  final List<int> starts = _lineStarts(source);
  if (targetLine >= starts.length) return _appendTopLevelLine(source, tag);

  final int offset = starts[targetLine];
  final String indent = _lineIndentAt(source, offset);
  final String newline = _lineEnding(source);
  return source.replaceRange(
    offset,
    offset,
    '$indent$tag$newline',
  );
}

/// Inserts an EDIT-sequence marker at [projectFrame].
///
/// Its source location inside the EDIT is not its timing truth, so it is
/// appended directly before the root closing tag. The explicit authored frame
/// remains authoritative through later source rearrangement.
String addEditMarkerAtProjectFrame({
  required String source,
  required String editId,
  required int projectFrame,
  String label = '',
}) {
  if (projectFrame < 0) {
    throw ArgumentError.value(
      projectFrame,
      'projectFrame',
      'EDIT marker frame must be non-negative.',
    );
  }

  final ScriptCstDocument cst = ScriptCstDocument.parse(source);
  final ScriptCstBlock root = _editRoot(cst, editId);
  final String newline = _lineEnding(source);
  final String indent = '${_lineIndentAt(source, root.closeStartOffset)}  ';
  final String insertion =
      '$indent${formatMarkerTag(frame: projectFrame, label: label)}$newline'
      '${_lineIndentAt(source, root.closeStartOffset)}';
  return cst.insertBeforeClosingTag(root, insertion);
}

/// Inserts a source-relative marker into [clipId] at the source frame sampled
/// by [projectFrame].
///
/// Returns null when the selected project frame is outside the selected clip.
/// This is the authoring-side counterpart of marker/CUE projection: the stored
/// fact is source time, never the transient project position.
String? addClipMarkerAtProjectFrame({
  required String source,
  required String editId,
  required String trackId,
  required String clipId,
  required int projectFrame,
  String label = '',
}) {
  final EditDocumentModel model = EditDocumentModel.parse(source);
  final EditSequence edit = model.edit(editId);
  final EditTrack track = edit.track(trackId);
  final EditClip clip = track.clip(clipId);

  if (projectFrame < clip.atFrame ||
      projectFrame >= clip.endFrameExclusive) {
    return null;
  }

  final int projectOffset = projectFrame - clip.atFrame;
  final int sourceFrame = clip.sourceFrameAtProjectOffset(projectOffset);
  final String newline = _lineEnding(source);
  final String closingIndent = _lineIndentAt(source, clip.block.closeStartOffset);
  final String childIndent = '$closingIndent  ';
  final String insertion =
      '$childIndent${formatMarkerTag(frame: sourceFrame, label: label)}$newline'
      '$closingIndent';
  return model.cst.insertBeforeClosingTag(clip.block, insertion);
}

ScriptCstBlock _editRoot(ScriptCstDocument cst, String editId) {
  for (final ScriptCstBlock root in cst.roots) {
    if (root.type == 'EDIT' && root.header.trim() == editId) return root;
  }
  throw StateError('No EDIT named "$editId".');
}

String _appendTopLevelLine(String source, String tag) {
  final String newline = _lineEnding(source);
  if (source.isEmpty) return '$tag$newline';
  if (source.endsWith('\n') || source.endsWith('\r')) {
    return '$source$tag$newline';
  }
  return '$source$newline$tag$newline';
}

String _lineEnding(String source) => source.contains('\r\n') ? '\r\n' : '\n';

List<int> _lineStarts(String source) {
  final List<int> starts = <int>[0];
  for (int i = 0; i < source.length; i++) {
    if (source.codeUnitAt(i) == 0x0A) starts.add(i + 1);
  }
  return starts;
}

String _lineIndentAt(String source, int offset) {
  final int start = source.lastIndexOf('\n', offset > 0 ? offset - 1 : 0) + 1;
  int cursor = start;
  while (cursor < source.length && cursor < offset) {
    final int code = source.codeUnitAt(cursor);
    if (code != 0x20 && code != 0x09) break;
    cursor++;
  }
  return source.substring(start, cursor);
}
