// ./lib/edit_cue_authoring.dart
//
// Source-backed authoring operations for clip-local CARD cues.
//
// CUE is not a hidden project model and it is not a generic structural layer.
// These helpers rewrite only the selected CLIP's authored source, then reparse
// the canonical document before returning it. The trigger remains source-frame
// relative while CARD continues to own its own presentation lifetime.

import 'edit_cue.dart';
import 'edit_surface_model.dart';
import 'presentation_requests.dart';

class EditCueAuthoringException implements Exception {
  final String message;

  const EditCueAuthoringException(this.message);

  @override
  String toString() => 'EditCueAuthoringException: $message';
}

/// Exact source frame sampled by [clip] at one project frame.
///
/// The project frame must be inside the clip. This is intentionally the same
/// integer source walk used by playback, so a GUI command such as "add cue at
/// playhead" never invents a second timing conversion.
int cardCueSourceFrameAtProjectFrame(
  EditSurfaceClip clip,
  int projectFrame,
) {
  if (projectFrame < clip.atFrame || projectFrame >= clip.endFrameExclusive) {
    throw ArgumentError.value(
      projectFrame,
      'projectFrame',
      'CARD cue playhead must be inside the selected CLIP.',
    );
  }
  return clip.clip.sourceFrameAtProjectOffset(projectFrame - clip.atFrame);
}

/// Adds one CARD cue to [clipId] at the exact selected project-frame sample.
String addCardCueAtProjectFrame({
  required EditSurfaceDocument document,
  required String trackId,
  required String clipId,
  required int projectFrame,
  required CardRequest card,
}) {
  final EditSurfaceClip selected = document.clip(trackId, clipId);
  final int sourceFrame =
      cardCueSourceFrameAtProjectFrame(selected, projectFrame);
  _validateCard(card);

  final String source = document.source;
  final String lineEnding = source.contains('\r\n') ? '\r\n' : '\n';
  final String clipIndent = _lineIndentAt(source, selected.clip.block.startOffset);
  final String cueIndent = '$clipIndent  ';
  final String cardIndent = '$cueIndent  ';
  final String cue = _cueMarkup(
    sourceFrame: sourceFrame,
    card: card,
    lineEnding: lineEnding,
    firstIndent: cueIndent,
    continuationIndent: cueIndent,
    cardIndent: cardIndent,
  );

  final String insertion = '$cue$lineEnding$clipIndent';
  final String next = document.model.cst.insertBeforeClosingTag(
    selected.clip.block,
    insertion,
  );
  _validateResult(next, document.editId, trackId, clipId);
  return next;
}

/// Rewrites one existing cue in place while keeping its authored trigger frame.
String updateCardCue({
  required EditSurfaceDocument document,
  required String trackId,
  required String clipId,
  required int cueIndex,
  required CardRequest card,
}) {
  final EditSurfaceClip selected = document.clip(trackId, clipId);
  final List<EditCardCue> cues = parseClipCardCues(selected.clip);
  final EditCardCue cue = _cueAt(cues, cueIndex);
  _validateCard(card);

  final String source = document.source;
  final String lineEnding = source.contains('\r\n') ? '\r\n' : '\n';
  final String cueIndent = _lineIndentAt(source, cue.startOffset);
  final String replacement = _cueMarkup(
    sourceFrame: cue.sourceFrame,
    card: card,
    lineEnding: lineEnding,
    firstIndent: '',
    continuationIndent: cueIndent,
    cardIndent: '$cueIndent  ',
  );

  final String next = source.replaceRange(
    cue.startOffset,
    cue.endOffset,
    replacement,
  );
  _validateResult(next, document.editId, trackId, clipId);
  return next;
}

/// Removes exactly one complete authored CUE block and nothing else.
String deleteCardCue({
  required EditSurfaceDocument document,
  required String trackId,
  required String clipId,
  required int cueIndex,
}) {
  final EditSurfaceClip selected = document.clip(trackId, clipId);
  final List<EditCardCue> cues = parseClipCardCues(selected.clip);
  final EditCardCue cue = _cueAt(cues, cueIndex);
  final String next = document.source.replaceRange(
    cue.startOffset,
    cue.endOffset,
    '',
  );
  EditSurfaceDocument.parse(next, document.editId);
  return next;
}

/// Splits a clip using the existing structural split operation, then assigns
/// every CARD cue to exactly one resulting half.
///
/// The original split operation necessarily copies the opaque CLIP body to
/// both halves. That is correct for comments and most future opaque metadata,
/// but a CUE is a source-relative event and must not fire twice. A cue whose
/// trigger is before the split stays on the left; one whose trigger lands on
/// the split frame or later goes right. Dormant cues outside the current source
/// window are assigned by source coordinate so they also remain singular.
String splitClipWithCardCueOwnership({
  required EditSurfaceDocument document,
  required String trackId,
  required String clipId,
  required int projectFrame,
}) {
  final EditSurfaceClip original = document.clip(trackId, clipId);
  final List<EditCardCue> cues = parseClipCardCues(original.clip);
  if (cues.isEmpty) {
    return document.splitClip(trackId, clipId, projectFrame);
  }

  if (projectFrame <= original.atFrame ||
      projectFrame >= original.endFrameExclusive) {
    throw ArgumentError.value(
      projectFrame,
      'projectFrame',
      'Split frame must be strictly inside the CLIP.',
    );
  }

  final int splitOffset = projectFrame - original.atFrame;
  final int rightIn = original.clip.sourceFrameAtProjectOffset(splitOffset);
  final List<bool> keepLeft = <bool>[
    for (final EditCardCue cue in cues)
      _cueBelongsLeft(
        original,
        cue,
        projectFrame: projectFrame,
        rightIn: rightIn,
      ),
  ];

  final Set<String> beforeIds = document
      .track(trackId)
      .clips
      .map((EditSurfaceClip clip) => clip.id)
      .toSet();

  String current = document.splitClip(trackId, clipId, projectFrame);
  EditSurfaceDocument after =
      EditSurfaceDocument.parse(current, document.editId);
  final EditSurfaceTrack track = after.track(trackId);
  final List<EditSurfaceClip> created = track.clips
      .where((EditSurfaceClip clip) => !beforeIds.contains(clip.id))
      .toList(growable: false);
  if (created.length != 1) {
    throw const EditCueAuthoringException(
      'Unable to identify the right-hand CLIP after split.',
    );
  }
  final String rightId = created.single.id;

  // Delete from highest authored index downward so lower indexes do not shift.
  for (int i = cues.length - 1; i >= 0; i--) {
    after = EditSurfaceDocument.parse(current, document.editId);
    if (keepLeft[i]) {
      current = deleteCardCue(
        document: after,
        trackId: trackId,
        clipId: rightId,
        cueIndex: i,
      );
    } else {
      current = deleteCardCue(
        document: after,
        trackId: trackId,
        clipId: clipId,
        cueIndex: i,
      );
    }
  }

  EditSurfaceDocument.parse(current, document.editId);
  return current;
}

bool _cueBelongsLeft(
  EditSurfaceClip original,
  EditCardCue cue, {
  required int projectFrame,
  required int rightIn,
}) {
  final int? trigger = cueProjectFrame(original.clip, cue.sourceFrame);
  if (trigger != null) return trigger < projectFrame;
  return cue.sourceFrame < rightIn;
}

EditCardCue _cueAt(List<EditCardCue> cues, int cueIndex) {
  if (cueIndex < 0 || cueIndex >= cues.length) {
    throw RangeError.index(cueIndex, cues, 'cueIndex');
  }
  return cues[cueIndex];
}

String _cueMarkup({
  required int sourceFrame,
  required CardRequest card,
  required String lineEnding,
  required String firstIndent,
  required String continuationIndent,
  required String cardIndent,
}) {
  if (sourceFrame < 0) {
    throw ArgumentError.value(
      sourceFrame,
      'sourceFrame',
      'CUE source frame must be non-negative.',
    );
  }

  final int argb = card.panelColor.toARGB32();
  final int red = (argb >> 16) & 0xFF;
  final int green = (argb >> 8) & 0xFF;
  final int blue = argb & 0xFF;
  final String heading = card.heading.trim();
  final String cardHead = (StringBuffer()
        ..write('[CARD:${card.image.trim()}:${card.holdFrames}:')
        ..write('$red,$green,$blue')
        ..write(heading.isEmpty ? ']' : ':$heading]'))
      .toString();

  final StringBuffer out = StringBuffer()
    ..write('$firstIndent[CUE:$sourceFrame]$lineEnding')
    ..write('$cardIndent$cardHead$lineEnding');

  final String normalizedBody =
      card.body.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (normalizedBody.isNotEmpty) {
    final List<String> lines = normalizedBody.split('\n');
    for (final String line in lines) {
      out.write('$cardIndent  $line$lineEnding');
    }
  }

  out
    ..write('$cardIndent[/CARD]$lineEnding')
    ..write('$continuationIndent[/CUE]');
  return out.toString();
}

void _validateCard(CardRequest card) {
  final String image = card.image.trim();
  if (image.isEmpty ||
      image.contains(':') ||
      image.contains(']') ||
      image.contains('\n') ||
      image.contains('\r')) {
    throw ArgumentError.value(
      card.image,
      'card.image',
      'CARD image must be one workspace-relative path without colon or newline.',
    );
  }
  if (card.holdFrames < 0) {
    throw ArgumentError.value(
      card.holdFrames,
      'card.holdFrames',
      'CARD hold must be non-negative.',
    );
  }
  final String heading = card.heading;
  if (heading.contains(':') ||
      heading.contains(']') ||
      heading.contains('\n') ||
      heading.contains('\r')) {
    throw ArgumentError.value(
      card.heading,
      'card.heading',
      'CARD heading cannot contain colon, closing bracket, or newline.',
    );
  }
  if (card.body.contains('[/CARD]')) {
    throw ArgumentError.value(
      card.body,
      'card.body',
      'CARD body cannot contain the CARD closing tag.',
    );
  }
}

void _validateResult(
  String source,
  String editId,
  String trackId,
  String clipId,
) {
  final EditSurfaceDocument parsed = EditSurfaceDocument.parse(source, editId);
  parseClipCardCues(parsed.clip(trackId, clipId).clip);
}

String _lineIndentAt(String source, int offset) {
  final int start = source.lastIndexOf('\n', offset > 0 ? offset - 1 : 0) + 1;
  int cursor = start;
  while (cursor < offset) {
    final int code = source.codeUnitAt(cursor);
    if (code != 32 && code != 9) break;
    cursor++;
  }
  return source.substring(start, cursor);
}
