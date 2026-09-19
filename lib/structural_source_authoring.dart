// ./lib/structural_source_authoring.dart
//
// Source-backed rename operations for reusable EDIT / MOSAIC definitions.
//
// A structural source id is an authored identity, not a display label. Renaming
// it therefore has to refactor every structural reference that points at that
// identity while leaving ordinary text, comments, and placement chrome alone.
//
// The script remains canonical. This helper parses the current document,
// rewrites only CST-owned structural opening tags and parsed main-sequence
// STRUCT placements, then reparses the result before returning it.

import 'edit_model.dart';
import 'script_cst.dart';
import 'structural_sequence.dart';

final RegExp _structuralSourceIdPattern = RegExp(r'^[A-Za-z0-9_-]+$');

class _SourceReplacement {
  final int start;
  final int end;
  final String replacement;

  const _SourceReplacement(this.start, this.end, this.replacement);
}

String renameStructuralSource({
  required String source,
  required StructuralSourceRef sourceRef,
  required String newId,
}) {
  final String id = newId.trim();
  if (!_structuralSourceIdPattern.hasMatch(id)) {
    throw ArgumentError.value(
      newId,
      'newId',
      'Structural source id must use letters, numbers, underscore, or hyphen.',
    );
  }

  final EditDocumentModel model = EditDocumentModel.parse(source);
  if (!model.containsStructuralSource(sourceRef)) {
    throw StateError(
      'No structural source named ${sourceRef.canonicalSource}.',
    );
  }
  if (id == sourceRef.id) return source;

  final String prefix = switch (sourceRef.kind) {
    StructuralSourceKind.edit => 'EDIT',
    StructuralSourceKind.mosaic => 'MOSAIC',
  };
  final StructuralSourceRef renamed =
      StructuralSourceRef.tryParse('$prefix.$id')!;

  final bool collision = switch (sourceRef.kind) {
    StructuralSourceKind.edit =>
      model.edits.any((EditSequence edit) => edit.id == id),
    StructuralSourceKind.mosaic =>
      model.mosaics.any((MosaicSequence mosaic) => mosaic.id == id),
  };
  if (collision) {
    throw StateError('$prefix "$id" already exists.');
  }

  final List<_SourceReplacement> replacements = <_SourceReplacement>[];

  final ScriptCstBlock root = switch (sourceRef.kind) {
    StructuralSourceKind.edit => model.edit(sourceRef.id).block,
    StructuralSourceKind.mosaic => model.mosaic(sourceRef.id).block,
  };
  replacements.add(
    _SourceReplacement(
      root.startOffset,
      root.openEndOffset,
      _renameRootOpeningTag(root, id),
    ),
  );

  void collectClip(EditClip clip) {
    if (clip.source != sourceRef.canonicalSource) return;
    replacements.add(
      _SourceReplacement(
        clip.block.startOffset,
        clip.block.openEndOffset,
        _renameClipSource(
          clip.block,
          renamed.canonicalSource,
        ),
      ),
    );
  }

  for (final EditSequence edit in model.edits) {
    for (final EditTrack track in edit.tracks) {
      for (final EditClip clip in track.clips) {
        collectClip(clip);
      }
    }
  }
  for (final MosaicSequence mosaic in model.mosaics) {
    for (final MosaicPane pane in mosaic.panes) {
      for (final EditClip clip in pane.clips) {
        collectClip(clip);
      }
    }
  }

  for (final StructuralSequencePlacement placement
      in parseStructuralSequencePlacements(source)) {
    if (placement.sourceRef != sourceRef) continue;
    final String line =
        source.substring(placement.startOffset, placement.endOffset);
    replacements.add(
      _SourceReplacement(
        placement.startOffset,
        placement.endOffset,
        _renameStructPlacementLine(
          line,
          sourceRef.canonicalSource,
          renamed.canonicalSource,
        ),
      ),
    );
  }

  replacements.sort(
    (_SourceReplacement a, _SourceReplacement b) =>
        b.start.compareTo(a.start),
  );

  String next = source;
  for (final _SourceReplacement replacement in replacements) {
    next = next.replaceRange(
      replacement.start,
      replacement.end,
      replacement.replacement,
    );
  }

  final EditDocumentModel reparsed = EditDocumentModel.parse(next);
  if (!reparsed.containsStructuralSource(renamed)) {
    throw StateError(
      'Renaming ${sourceRef.canonicalSource} did not create '
      '${renamed.canonicalSource}.',
    );
  }
  if (reparsed.containsStructuralSource(sourceRef)) {
    throw StateError(
      'Renaming ${sourceRef.canonicalSource} left the old source definition.',
    );
  }

  for (final EditSequence edit in reparsed.edits) {
    for (final EditTrack track in edit.tracks) {
      for (final EditClip clip in track.clips) {
        if (clip.source == sourceRef.canonicalSource) {
          throw StateError(
            'Renaming ${sourceRef.canonicalSource} left a CLIP reference.',
          );
        }
      }
    }
  }
  for (final MosaicSequence mosaic in reparsed.mosaics) {
    for (final MosaicPane pane in mosaic.panes) {
      for (final EditClip clip in pane.clips) {
        if (clip.source == sourceRef.canonicalSource) {
          throw StateError(
            'Renaming ${sourceRef.canonicalSource} left a CLIP reference.',
          );
        }
      }
    }
  }
  for (final StructuralSequencePlacement placement
      in parseStructuralSequencePlacements(next)) {
    if (placement.sourceRef == sourceRef) {
      throw StateError(
        'Renaming ${sourceRef.canonicalSource} left a STRUCT reference.',
      );
    }
  }

  return next;
}

String _renameRootOpeningTag(ScriptCstBlock block, String newId) {
  final String raw = block.header;
  final int leading = raw.length - raw.trimLeft().length;
  final int trailing = raw.length - raw.trimRight().length;
  final String before = raw.substring(0, leading);
  final String after =
      trailing == 0 ? '' : raw.substring(raw.length - trailing);
  return '[${block.type}:$before$newId$after]';
}

String _renameClipSource(
  ScriptCstBlock block,
  String newCanonicalSource,
) {
  final List<String> segments = block.header.split(':');
  if (segments.length < 2) {
    throw StateError('CLIP at ${block.startOffset} has no source segment.');
  }

  final String raw = segments[1];
  final int leading = raw.length - raw.trimLeft().length;
  final int trailing = raw.length - raw.trimRight().length;
  final String before = raw.substring(0, leading);
  final String after =
      trailing == 0 ? '' : raw.substring(raw.length - trailing);
  segments[1] = '$before$newCanonicalSource$after';

  return '[CLIP:${segments.join(':')}]';
}

String _renameStructPlacementLine(
  String line,
  String oldCanonicalSource,
  String newCanonicalSource,
) {
  final int tagStart = line.indexOf('[STRUCT:');
  final int tagEnd = line.lastIndexOf(']');
  if (tagStart < 0 || tagEnd <= tagStart) {
    throw StateError('Parsed STRUCT placement no longer has a complete tag.');
  }

  final String tag = line.substring(tagStart, tagEnd + 1);
  const int sourceStart = '[STRUCT:'.length;
  int sourceEnd = tag.indexOf(':', sourceStart);
  if (sourceEnd < 0) sourceEnd = tag.length - 1;

  final String rawSource = tag.substring(sourceStart, sourceEnd);
  if (rawSource.trim() != oldCanonicalSource) {
    throw StateError(
      'Expected STRUCT source $oldCanonicalSource, found ${rawSource.trim()}.',
    );
  }

  final int leading = rawSource.length - rawSource.trimLeft().length;
  final int trailing = rawSource.length - rawSource.trimRight().length;
  final String before = rawSource.substring(0, leading);
  final String after = trailing == 0
      ? ''
      : rawSource.substring(rawSource.length - trailing);

  final String renamedTag = tag.replaceRange(
    sourceStart,
    sourceEnd,
    '$before$newCanonicalSource$after',
  );
  return line.replaceRange(tagStart, tagEnd + 1, renamedTag);
}
