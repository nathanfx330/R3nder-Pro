// ./lib/edit_cue_authoring.dart
//
// Source-backed authoring operations for clip-local presentation cues.
//
// CUE is not a hidden project model and it is not a generic structural layer.
// These helpers rewrite only the selected CLIP's authored source, then reparse
// the canonical document before returning it. The trigger remains source-frame
// relative while CARD, SIDECARD, or DOSSIER owns its own presentation lifetime.

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
int cueSourceFrameAtProjectFrame(
  EditSurfaceClip clip,
  int projectFrame,
) {
  if (projectFrame < clip.atFrame || projectFrame >= clip.endFrameExclusive) {
    throw ArgumentError.value(
      projectFrame,
      'projectFrame',
      'CUE playhead must be inside the selected CLIP.',
    );
  }
  return clip.clip.sourceFrameAtProjectOffset(projectFrame - clip.atFrame);
}

/// Back-compatible CARD-named entry point retained for existing callers/tests.
int cardCueSourceFrameAtProjectFrame(
  EditSurfaceClip clip,
  int projectFrame,
) =>
    cueSourceFrameAtProjectFrame(clip, projectFrame);

/// Adds one CARD-family cue to [clipId] at the exact selected project-frame
/// sample. A [SideCardRequest] emits SIDECARD; an ordinary [CardRequest] emits
/// CARD. No separate hidden style property is introduced.
String addCardCueAtProjectFrame({
  required EditSurfaceDocument document,
  required String trackId,
  required String clipId,
  required int projectFrame,
  required CardRequest card,
}) {
  final EditSurfaceClip selected = document.clip(trackId, clipId);
  final int sourceFrame = cueSourceFrameAtProjectFrame(selected, projectFrame);
  _validateCard(card);

  final String source = document.source;
  final String lineEnding = source.contains('\r\n') ? '\r\n' : '\n';
  final String clipIndent = _lineIndentAt(source, selected.clip.block.startOffset);
  final String cueIndent = '$clipIndent  ';
  final String presentationIndent = '$cueIndent  ';
  final String cue = _cardCueMarkup(
    sourceFrame: sourceFrame,
    card: card,
    lineEnding: lineEnding,
    firstIndent: cueIndent,
    continuationIndent: cueIndent,
    presentationIndent: presentationIndent,
  );

  final String insertion = '$cue$lineEnding$clipIndent';
  final String next = document.model.cst.insertBeforeClosingTag(
    selected.clip.block,
    insertion,
  );
  _validateResult(next, document.editId, trackId, clipId);
  return next;
}

/// Adds one DOSSIER cue at the selected playhead sample.
String addDossierCueAtProjectFrame({
  required EditSurfaceDocument document,
  required String trackId,
  required String clipId,
  required int projectFrame,
  required DossierRequest dossier,
}) {
  final EditSurfaceClip selected = document.clip(trackId, clipId);
  final int sourceFrame = cueSourceFrameAtProjectFrame(selected, projectFrame);
  _validateDossier(dossier);

  final String source = document.source;
  final String lineEnding = source.contains('\r\n') ? '\r\n' : '\n';
  final String clipIndent = _lineIndentAt(source, selected.clip.block.startOffset);
  final String cueIndent = '$clipIndent  ';
  final String presentationIndent = '$cueIndent  ';
  final String cue = _dossierCueMarkup(
    sourceFrame: sourceFrame,
    dossier: dossier,
    lineEnding: lineEnding,
    firstIndent: cueIndent,
    continuationIndent: cueIndent,
    presentationIndent: presentationIndent,
  );

  final String insertion = '$cue$lineEnding$clipIndent';
  final String next = document.model.cst.insertBeforeClosingTag(
    selected.clip.block,
    insertion,
  );
  _validateResult(next, document.editId, trackId, clipId);
  return next;
}

/// Rewrites one existing CARD/SIDECARD cue in place while keeping its authored
/// trigger frame. The returned request may switch CARD <-> SIDECARD explicitly.
String updateCardCue({
  required EditSurfaceDocument document,
  required String trackId,
  required String clipId,
  required int cueIndex,
  required CardRequest card,
}) {
  final EditSurfaceClip selected = document.clip(trackId, clipId);
  final List<EditCardCue> cues = parseClipCardCues(selected.clip);
  final EditCardCue cue = _cardCueAt(cues, cueIndex);
  _validateCard(card);

  final String source = document.source;
  final String lineEnding = source.contains('\r\n') ? '\r\n' : '\n';
  final String cueIndent = _lineIndentAt(source, cue.startOffset);
  final String replacement = _cardCueMarkup(
    sourceFrame: cue.sourceFrame,
    card: card,
    lineEnding: lineEnding,
    firstIndent: '',
    continuationIndent: cueIndent,
    presentationIndent: '$cueIndent  ',
  );

  final String next = source.replaceRange(
    cue.startOffset,
    cue.endOffset,
    replacement,
  );
  _validateResult(next, document.editId, trackId, clipId);
  return next;
}

/// Rewrites one existing DOSSIER cue in place while preserving its trigger.
String updateDossierCue({
  required EditSurfaceDocument document,
  required String trackId,
  required String clipId,
  required int cueIndex,
  required DossierRequest dossier,
}) {
  final EditSurfaceClip selected = document.clip(trackId, clipId);
  final List<EditDossierCue> cues = parseClipDossierCues(selected.clip);
  final EditDossierCue cue = _dossierCueAt(cues, cueIndex);
  _validateDossier(dossier);

  final String source = document.source;
  final String lineEnding = source.contains('\r\n') ? '\r\n' : '\n';
  final String cueIndent = _lineIndentAt(source, cue.startOffset);
  final String replacement = _dossierCueMarkup(
    sourceFrame: cue.sourceFrame,
    dossier: dossier,
    lineEnding: lineEnding,
    firstIndent: '',
    continuationIndent: cueIndent,
    presentationIndent: '$cueIndent  ',
  );

  final String next = source.replaceRange(
    cue.startOffset,
    cue.endOffset,
    replacement,
  );
  _validateResult(next, document.editId, trackId, clipId);
  return next;
}

/// Removes exactly one complete authored CARD/SIDECARD CUE block.
String deleteCardCue({
  required EditSurfaceDocument document,
  required String trackId,
  required String clipId,
  required int cueIndex,
}) {
  final EditSurfaceClip selected = document.clip(trackId, clipId);
  final List<EditCardCue> cues = parseClipCardCues(selected.clip);
  final EditCardCue cue = _cardCueAt(cues, cueIndex);
  final String next = document.source.replaceRange(
    cue.startOffset,
    cue.endOffset,
    '',
  );
  EditSurfaceDocument.parse(next, document.editId);
  return next;
}

/// Removes exactly one complete authored DOSSIER CUE block.
String deleteDossierCue({
  required EditSurfaceDocument document,
  required String trackId,
  required String clipId,
  required int cueIndex,
}) {
  final EditSurfaceClip selected = document.clip(trackId, clipId);
  final List<EditDossierCue> cues = parseClipDossierCues(selected.clip);
  final EditDossierCue cue = _dossierCueAt(cues, cueIndex);
  final String next = document.source.replaceRange(
    cue.startOffset,
    cue.endOffset,
    '',
  );
  EditSurfaceDocument.parse(next, document.editId);
  return next;
}

/// Splits a clip using the existing structural split operation, then assigns
/// every presentation CUE to exactly one resulting half.
///
/// The original split operation necessarily copies the opaque CLIP body to
/// both halves. That is correct for comments and most future opaque metadata,
/// but a CUE is a source-relative event and must not fire twice. A cue whose
/// trigger is before the split stays on the left; one whose trigger lands on
/// the split frame or later goes right. Dormant cues outside the current source
/// window are assigned by source coordinate so they also remain singular.
///
/// Historical name retained because EditSurface and existing tests already call
/// it. It now owns CARD, SIDECARD, and DOSSIER rather than only CARD-family cues.
String splitClipWithCardCueOwnership({
  required EditSurfaceDocument document,
  required String trackId,
  required String clipId,
  required int projectFrame,
}) {
  final EditSurfaceClip original = document.clip(trackId, clipId);
  final List<EditCardCue> cardCues = parseClipCardCues(original.clip);
  final List<EditDossierCue> dossierCues = parseClipDossierCues(original.clip);
  if (cardCues.isEmpty && dossierCues.isEmpty) {
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
  final List<bool> cardKeepLeft = <bool>[
    for (final EditCardCue cue in cardCues)
      _cueBelongsLeft(
        original,
        cue.sourceFrame,
        projectFrame: projectFrame,
        rightIn: rightIn,
      ),
  ];
  final List<bool> dossierKeepLeft = <bool>[
    for (final EditDossierCue cue in dossierCues)
      _cueBelongsLeft(
        original,
        cue.sourceFrame,
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
  EditSurfaceDocument after = EditSurfaceDocument.parse(current, document.editId);
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

  // Family indexes are independent. Delete highest index downward so earlier
  // same-family indexes remain stable as source shrinks.
  for (int i = dossierCues.length - 1; i >= 0; i--) {
    after = EditSurfaceDocument.parse(current, document.editId);
    current = deleteDossierCue(
      document: after,
      trackId: trackId,
      clipId: dossierKeepLeft[i] ? rightId : clipId,
      cueIndex: i,
    );
  }
  for (int i = cardCues.length - 1; i >= 0; i--) {
    after = EditSurfaceDocument.parse(current, document.editId);
    current = deleteCardCue(
      document: after,
      trackId: trackId,
      clipId: cardKeepLeft[i] ? rightId : clipId,
      cueIndex: i,
    );
  }

  EditSurfaceDocument.parse(current, document.editId);
  return current;
}

bool _cueBelongsLeft(
  EditSurfaceClip original,
  int sourceFrame, {
  required int projectFrame,
  required int rightIn,
}) {
  final int? trigger = cueProjectFrame(original.clip, sourceFrame);
  if (trigger != null) return trigger < projectFrame;
  return sourceFrame < rightIn;
}

EditCardCue _cardCueAt(List<EditCardCue> cues, int cueIndex) {
  if (cueIndex < 0 || cueIndex >= cues.length) {
    throw RangeError.index(cueIndex, cues, 'cueIndex');
  }
  return cues[cueIndex];
}

EditDossierCue _dossierCueAt(List<EditDossierCue> cues, int cueIndex) {
  if (cueIndex < 0 || cueIndex >= cues.length) {
    throw RangeError.index(cueIndex, cues, 'cueIndex');
  }
  return cues[cueIndex];
}

String _cardCueMarkup({
  required int sourceFrame,
  required CardRequest card,
  required String lineEnding,
  required String firstIndent,
  required String continuationIndent,
  required String presentationIndent,
}) {
  _validateSourceFrame(sourceFrame);

  final String rgb = _rgb(card.panelColor);
  final String heading = card.heading.trim();
  final String tag = card is SideCardRequest ? 'SIDECARD' : 'CARD';
  final String head = (StringBuffer()
        ..write('[$tag:${card.image.trim()}:${card.holdFrames}:$rgb')
        ..write(heading.isEmpty ? ']' : ':$heading]'))
      .toString();

  return _wrappedCueMarkup(
    sourceFrame: sourceFrame,
    openTag: head,
    closeTag: '[/$tag]',
    body: card.body,
    lineEnding: lineEnding,
    firstIndent: firstIndent,
    continuationIndent: continuationIndent,
    presentationIndent: presentationIndent,
  );
}

String _dossierCueMarkup({
  required int sourceFrame,
  required DossierRequest dossier,
  required String lineEnding,
  required String firstIndent,
  required String continuationIndent,
  required String presentationIndent,
}) {
  _validateSourceFrame(sourceFrame);

  final String rgb = _rgb(dossier.panelColor);
  final String heading = dossier.heading.trim();
  final String mode = switch (dossier.centerMode) {
    DossierCenterMode.grid => 'GRID',
    DossierCenterMode.mosaic => 'MOSAIC',
    DossierCenterMode.sideOnly => 'SIDE_ONLY',
  };
  final String head = (StringBuffer()
        ..write('[DOSSIER:${dossier.folder.trim()}:${dossier.image.trim()}:')
        ..write('${dossier.holdSplit}:${dossier.holdFull}:')
        ..write('${dossier.cardLead}:$mode:$rgb')
        ..write(heading.isEmpty ? ']' : ':$heading]'))
      .toString();

  return _wrappedCueMarkup(
    sourceFrame: sourceFrame,
    openTag: head,
    closeTag: '[/DOSSIER]',
    body: dossier.body,
    lineEnding: lineEnding,
    firstIndent: firstIndent,
    continuationIndent: continuationIndent,
    presentationIndent: presentationIndent,
  );
}

String _wrappedCueMarkup({
  required int sourceFrame,
  required String openTag,
  required String closeTag,
  required String body,
  required String lineEnding,
  required String firstIndent,
  required String continuationIndent,
  required String presentationIndent,
}) {
  final StringBuffer out = StringBuffer()
    ..write('$firstIndent[CUE:$sourceFrame]$lineEnding')
    ..write('$presentationIndent$openTag$lineEnding');

  final String normalizedBody =
      body.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (normalizedBody.isNotEmpty) {
    for (final String line in normalizedBody.split('\n')) {
      out.write('$presentationIndent  $line$lineEnding');
    }
  }

  out
    ..write('$presentationIndent$closeTag$lineEnding')
    ..write('$continuationIndent[/CUE]');
  return out.toString();
}

String _rgb(Color color) {
  final int argb = color.toARGB32();
  final int red = (argb >> 16) & 0xFF;
  final int green = (argb >> 8) & 0xFF;
  final int blue = argb & 0xFF;
  return '$red,$green,$blue';
}

void _validateSourceFrame(int sourceFrame) {
  if (sourceFrame < 0) {
    throw ArgumentError.value(
      sourceFrame,
      'sourceFrame',
      'CUE source frame must be non-negative.',
    );
  }
}

void _validateCard(CardRequest card) {
  _validatePath(card.image, 'card.image', 'CARD image');
  if (card.holdFrames < 0) {
    throw ArgumentError.value(
      card.holdFrames,
      'card.holdFrames',
      'CARD hold must be non-negative.',
    );
  }
  _validateHeading(card.heading, 'card.heading', 'CARD heading');
  if (card.body.contains('[/CARD]') || card.body.contains('[/SIDECARD]')) {
    throw ArgumentError.value(
      card.body,
      'card.body',
      'CARD body cannot contain a CARD-family closing tag.',
    );
  }
}

void _validateDossier(DossierRequest dossier) {
  _validatePath(dossier.folder, 'dossier.folder', 'DOSSIER folder');
  _validatePath(dossier.image, 'dossier.image', 'DOSSIER image');
  if (dossier.holdSplit < 0 ||
      dossier.holdFull < 0 ||
      dossier.cardLead < 0) {
    throw ArgumentError(
      'DOSSIER split hold, full hold, and card lead must be non-negative.',
    );
  }
  _validateHeading(dossier.heading, 'dossier.heading', 'DOSSIER heading');
  if (dossier.body.contains('[/DOSSIER]')) {
    throw ArgumentError.value(
      dossier.body,
      'dossier.body',
      'DOSSIER body cannot contain a DOSSIER closing tag.',
    );
  }
}

void _validatePath(String raw, String name, String label) {
  final String value = raw.trim();
  if (value.isEmpty ||
      value.contains(':') ||
      value.contains(']') ||
      value.contains('\n') ||
      value.contains('\r')) {
    throw ArgumentError.value(
      raw,
      name,
      '$label must be one workspace-relative path without colon or newline.',
    );
  }
}

void _validateHeading(String heading, String name, String label) {
  if (heading.contains(':') ||
      heading.contains(']') ||
      heading.contains('\n') ||
      heading.contains('\r')) {
    throw ArgumentError.value(
      heading,
      name,
      '$label cannot contain colon, closing bracket, or newline.',
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
  final clip = parsed.clip(trackId, clipId).clip;
  parseClipCardCues(clip);
  parseClipDossierCues(clip);
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
