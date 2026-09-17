// ./lib/edit_media_placement.dart
//
// Shared media-placement primitives for EDIT authoring.
//
// UI gestures decide where media belongs. This layer receives an explicit
// project frame and authors exactly one CLIP through EditSurfaceDocument.

import 'edit_media_import.dart';
import 'edit_model.dart';
import 'edit_surface_model.dart';

final RegExp _editIdPattern = RegExp(r'^[A-Za-z0-9_-]+$');

class MediaPlacementResult {
  final String document;
  final String editId;
  final String trackId;
  final String clipId;
  final int atFrame;
  final int inFrame;
  final int? requestedOutFrameExclusive;
  final int durationFrames;

  const MediaPlacementResult({
    required this.document,
    required this.editId,
    required this.trackId,
    required this.clipId,
    required this.atFrame,
    required this.inFrame,
    required this.requestedOutFrameExclusive,
    required this.durationFrames,
  });
}

String uniqueEditId(EditDocumentModel model, String preferredId) {
  if (!_editIdPattern.hasMatch(preferredId)) {
    throw ArgumentError.value(
      preferredId,
      'preferredId',
      'EDIT id must use letters, numbers, underscore, or hyphen.',
    );
  }

  final Set<String> ids = model.edits.map((EditSequence edit) => edit.id).toSet();
  if (!ids.contains(preferredId)) return preferredId;

  int suffix = 2;
  String candidate = '${preferredId}_$suffix';
  while (ids.contains(candidate)) {
    suffix++;
    candidate = '${preferredId}_$suffix';
  }
  return candidate;
}

String appendEmptyEdit({
  required String source,
  required String editId,
}) {
  if (!_editIdPattern.hasMatch(editId)) {
    throw ArgumentError.value(
      editId,
      'editId',
      'EDIT id must use letters, numbers, underscore, or hyphen.',
    );
  }

  final EditDocumentModel existing = EditDocumentModel.parse(source);
  if (existing.edits.any((EditSequence edit) => edit.id == editId)) {
    throw StateError('EDIT "$editId" already exists.');
  }

  final String newline = source.contains('\r\n') ? '\r\n' : '\n';
  final StringBuffer out = StringBuffer(source);
  if (source.isNotEmpty &&
      !source.endsWith('\n') &&
      !source.endsWith('\r')) {
    out.write(newline);
  }
  out
    ..write('[EDIT:$editId]$newline')
    ..write('[/EDIT]$newline');

  final String next = out.toString();
  EditDocumentModel.parse(next).edit(editId);
  return next;
}

int appendFrameForTrack(EditSurfaceDocument document, String trackId) {
  final EditSurfaceTrack? track = document.trackOrNull(trackId);
  if (track == null || track.clips.isEmpty) return 0;

  int end = 0;
  for (final EditSurfaceClip clip in track.clips) {
    if (clip.endFrameExclusive > end) end = clip.endFrameExclusive;
  }
  return end;
}

MediaPlacementResult placeMediaInEdit({
  required String source,
  required ImportedEditVideo media,
  required String editId,
  required String trackId,
  required int atFrame,
  int inFrame = 0,
  int? outFrameExclusive,
}) {
  if (atFrame < 0) {
    throw ArgumentError.value(atFrame, 'atFrame', 'Must be non-negative.');
  }
  if (inFrame < 0) {
    throw ArgumentError.value(inFrame, 'inFrame', 'Must be non-negative.');
  }

  final int sourceEnd = outFrameExclusive ?? media.sourceLengthFrames;
  if (sourceEnd <= inFrame) {
    throw ArgumentError.value(
      sourceEnd,
      'outFrameExclusive',
      'Source out must be greater than source in.',
    );
  }
  if (sourceEnd > media.sourceLengthFrames) {
    throw ArgumentError.value(
      sourceEnd,
      'outFrameExclusive',
      'Source out exceeds media source length ${media.sourceLengthFrames}.',
    );
  }

  final ExactClipSpeed speed = ExactClipSpeed(
    media.speedNumerator,
    media.speedDenominator,
  );
  final int durationFrames = inFrame == 0 && outFrameExclusive == null
      ? media.durationFrames
      : sourceSpanToProjectFrames(
          sourceSpanFrames: sourceEnd - inFrame,
          speed: speed,
        );

  final EditDocumentModel model = EditDocumentModel.parse(source);
  String next = source;
  if (!model.edits.any((EditSequence edit) => edit.id == editId)) {
    next = appendEmptyEdit(source: next, editId: editId);
  }

  final EditSurfaceDocument document = EditSurfaceDocument.parse(next, editId);
  final int endFrameExclusive = atFrame + durationFrames;
  final EditSurfaceTrack? existingTrack = document.trackOrNull(trackId);
  if (existingTrack != null) {
    for (final EditSurfaceClip clip in existingTrack.clips) {
      final bool overlaps =
          atFrame < clip.endFrameExclusive && clip.atFrame < endFrameExclusive;
      if (overlaps) {
        throw StateError(
          'Plain media placement [$atFrame, $endFrameExclusive) overlaps '
          'CLIP "${clip.id}" [${clip.atFrame}, ${clip.endFrameExclusive}) '
          'in TRACK "$trackId". Transitions must be authored explicitly.',
        );
      }
    }
  }

  final String clipId = document.nextClipId(trackId, media.clipBaseId);
  final String authored = document.addClip(
    trackId: trackId,
    clipId: clipId,
    mediaSource: media.authoredSource,
    atFrame: atFrame,
    inFrame: inFrame,
    durationFrames: durationFrames,
    speed: speed,
  );

  return MediaPlacementResult(
    document: authored,
    editId: editId,
    trackId: trackId,
    clipId: clipId,
    atFrame: atFrame,
    inFrame: inFrame,
    requestedOutFrameExclusive: outFrameExclusive,
    durationFrames: durationFrames,
  );
}
