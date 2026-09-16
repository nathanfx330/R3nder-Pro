// ./lib/marker_authoring.dart
//
// Source-backed authoring for zero-time MARK definitions.
//
// MARK never becomes project database state. These helpers accept canonical
// script text and return canonical script text with one marker inserted at an
// authored ownership boundary. TEXT placement is positional in the document;
// EDIT placement is sequence-relative; CLIP placement is source-relative.
//
// Normal insertion is line-neutral on purpose. compileScript strips MARK before
// projection and before editor [LINE:n] injection, so adding a zero-time marker
// should not manufacture a new raw line and thereby invalidate an otherwise
// reusable warm simulation. A marker is metadata on an existing authored line.

import 'edit_model.dart';
import 'marker_language.dart';
import 'script_cst.dart';

/// Inserts a positional TEXT marker at the program frame represented by
/// [rawLineAtFrame].
///
/// The marker is inserted after the target line's indentation and before its
/// existing content. Stripping the tag therefore recovers the exact original
/// line bytes and line count.
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

  final int lineStart = starts[targetLine];
  final String indent = _lineIndentAt(source, lineStart);
  final int insertion = lineStart + indent.length;
  return source.replaceRange(insertion, insertion, tag);
}

/// Inserts an EDIT-sequence marker at [projectFrame].
///
/// The explicit frame is timing truth, so source order is only ownership. Put
/// the marker immediately after the EDIT opening tag: it is directly owned by
/// that EDIT and adds no physical line to the document.
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
  final String tag = formatMarkerTag(frame: projectFrame, label: label);
  return source.replaceRange(root.openEndOffset, root.openEndOffset, tag);
}

/// Inserts a source-relative marker into [clipId] at the source frame sampled
/// by [projectFrame].
///
/// Returns null when the selected project frame is outside the selected clip.
/// The marker is written directly after the CLIP opening tag, preserving the
/// document's physical line count while keeping the definition inside CLIP
/// ownership. The stored fact is source time, never transient project time.
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
  final String tag = formatMarkerTag(frame: sourceFrame, label: label);
  return source.replaceRange(
    clip.block.openEndOffset,
    clip.block.openEndOffset,
    tag,
  );
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

String _lineIndentAt(String source, int lineStart) {
  int cursor = lineStart;
  while (cursor < source.length) {
    final int code = source.codeUnitAt(cursor);
    if (code != 0x20 && code != 0x09) break;
    cursor++;
  }
  return source.substring(lineStart, cursor);
}
