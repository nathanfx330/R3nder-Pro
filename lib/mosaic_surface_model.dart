// ./lib/mosaic_surface_model.dart
//
// Source-backed authoring operations for MOSAIC / PANE / CLIP.
//
// There is no composition database here. Every operation reparses canonical
// script text, rewrites one exact CST span, validates the resulting structural
// model, and runs the mixed EDIT/MOSAIC graph linter before returning source.
// Authored CLIP duration remains explicit project time and is never inferred
// from a referenced EDIT or MOSAIC after the clip has been created.

import 'edit_linter.dart';
import 'edit_model.dart';

String createMosaicWithSource({
  required String source,
  required String mosaicId,
  required String paneId,
  required String clipId,
  required String structuralSource,
  int inFrame = 0,
  required int durationFrames,
}) {
  _validateId('MOSAIC', mosaicId);
  _validateId('PANE', paneId);
  _validateId('CLIP', clipId);
  if (inFrame < 0) {
    throw ArgumentError.value(
      inFrame,
      'inFrame',
      'MOSAIC source in frame must be non-negative.',
    );
  }
  if (durationFrames <= 0) {
    throw ArgumentError.value(
      durationFrames,
      'durationFrames',
      'MOSAIC source duration must be positive.',
    );
  }

  final EditDocumentModel model = EditDocumentModel.parse(source);
  if (model.mosaics.any((MosaicSequence mosaic) => mosaic.id == mosaicId)) {
    throw StateError('MOSAIC "$mosaicId" already exists.');
  }
  final StructuralSourceRef ref = _requireExistingStructuralSource(
    model,
    structuralSource,
  );
  final int sourceFrames = model.structuralSourceFrameCount(ref);
  if (inFrame >= sourceFrames || inFrame + durationFrames > sourceFrames) {
    throw ArgumentError(
      'MOSAIC source range $inFrame..${inFrame + durationFrames} exceeds '
      '${ref.canonicalSource} ($sourceFrames frames).',
    );
  }

  final String newline = source.contains('\r\n') ? '\r\n' : '\n';
  final StringBuffer out = StringBuffer(source);
  if (source.isNotEmpty &&
      !source.endsWith('\n') &&
      !source.endsWith('\r')) {
    out.write(newline);
  }
  out
    ..write('[MOSAIC:$mosaicId]$newline')
    ..write('  [PANE:$paneId]$newline')
    ..write(
      '    [CLIP:$clipId:${ref.canonicalSource}:0:$inFrame:$durationFrames:1]$newline',
    )
    ..write('    [/CLIP]$newline')
    ..write('  [/PANE]$newline')
    ..write('[/MOSAIC]$newline');

  final String next = out.toString();
  _validateRenderable(next);
  return next;
}

class MosaicSurfaceDocument {
  final EditDocumentModel model;
  final String mosaicId;
  final MosaicSequence mosaic;

  MosaicSurfaceDocument._({
    required this.model,
    required this.mosaicId,
    required this.mosaic,
  });

  factory MosaicSurfaceDocument.parse(String source, String mosaicId) {
    final EditDocumentModel model = EditDocumentModel.parse(source);
    return MosaicSurfaceDocument._(
      model: model,
      mosaicId: mosaicId,
      mosaic: model.mosaic(mosaicId),
    );
  }

  String get source => model.source;
  int get projectFrameCount => mosaic.projectFrameCount;

  MosaicPane pane(String paneId) => mosaic.pane(paneId);

  EditClip clip(String paneId, String clipId) => pane(paneId).clip(clipId);

  String nextPaneId([String base = 'pane']) {
    _validateId('PANE', base);
    final Set<String> ids = mosaic.panes.map((MosaicPane p) => p.id).toSet();
    if (!ids.contains(base)) return base;
    int suffix = 2;
    while (ids.contains('${base}_$suffix')) {
      suffix++;
    }
    return '${base}_$suffix';
  }

  String nextClipId(String paneId, [String base = 'clip']) {
    _validateId('CLIP', base);
    final Set<String> ids = pane(paneId).clips.map((EditClip c) => c.id).toSet();
    if (!ids.contains(base)) return base;
    int suffix = 2;
    while (ids.contains('${base}_$suffix')) {
      suffix++;
    }
    return '${base}_$suffix';
  }

  List<StructuralSourceRef> availableStructuralSources() {
    return List<StructuralSourceRef>.unmodifiable(<StructuralSourceRef>[
      for (final EditSequence edit in model.edits)
        StructuralSourceRef.tryParse('EDIT.${edit.id}')!,
      for (final MosaicSequence other in model.mosaics)
        if (other.id != mosaicId)
          StructuralSourceRef.tryParse('MOSAIC.${other.id}')!,
    ]);
  }

  String setClipSource(
    String paneId,
    String clipId,
    String structuralSource,
  ) {
    final EditClip selected = clip(paneId, clipId);
    final StructuralSourceRef ref = _requireExistingStructuralSource(
      model,
      structuralSource,
    );
    final String next = model.rewriteClip(
      selected,
      source: ref.canonicalSource,
    );
    _validateRenderable(next);
    return next;
  }

  String moveClip(String paneId, String clipId, int atFrame) {
    if (atFrame < 0) {
      throw ArgumentError.value(atFrame, 'atFrame', 'Must be non-negative.');
    }
    final String next = model.rewriteClip(
      clip(paneId, clipId),
      atFrame: atFrame,
    );
    _validateRenderable(next);
    return next;
  }

  String setClipDuration(String paneId, String clipId, int durationFrames) {
    if (durationFrames <= 0) {
      throw ArgumentError.value(
        durationFrames,
        'durationFrames',
        'CLIP duration must be positive.',
      );
    }
    final String next = model.rewriteClip(
      clip(paneId, clipId),
      durationFrames: durationFrames,
    );
    _validateRenderable(next);
    return next;
  }

  String addPane({
    required String paneId,
    required String clipId,
    required String structuralSource,
    required int atFrame,
    required int durationFrames,
  }) {
    if (mosaic.panes.length >= 3) {
      throw StateError('MOSAIC "$mosaicId" already has its maximum 3 panes.');
    }
    _validateId('PANE', paneId);
    _validateId('CLIP', clipId);
    if (mosaic.panes.any((MosaicPane pane) => pane.id == paneId)) {
      throw StateError('PANE "$paneId" already exists in MOSAIC "$mosaicId".');
    }
    if (atFrame < 0 || durationFrames <= 0) {
      throw ArgumentError('PANE CLIP geometry is invalid.');
    }

    final StructuralSourceRef ref = _requireExistingStructuralSource(
      model,
      structuralSource,
    );
    final String newline = source.contains('\r\n') ? '\r\n' : '\n';
    final int close = mosaic.block.closeStartOffset;
    final String indent = _lineIndentAt(source, close);
    final String paneIndent = '$indent  ';
    final String clipIndent = '$paneIndent  ';
    final String insertion = '$paneIndent[PANE:$paneId]$newline'
        '$clipIndent[CLIP:$clipId:${ref.canonicalSource}:$atFrame:0:$durationFrames:1]$newline'
        '$clipIndent[/CLIP]$newline'
        '$paneIndent[/PANE]$newline'
        '$indent';

    final String next = model.cst.insertBeforeClosingTag(mosaic.block, insertion);
    _validateRenderable(next);
    return next;
  }

  String addClip({
    required String paneId,
    required String clipId,
    required String structuralSource,
    required int atFrame,
    required int inFrame,
    required int durationFrames,
    ExactClipSpeed? speed,
  }) {
    _validateId('CLIP', clipId);
    final MosaicPane target = pane(paneId);
    if (target.clips.any((EditClip clip) => clip.id == clipId)) {
      throw StateError('CLIP "$clipId" already exists in PANE "$paneId".');
    }
    if (atFrame < 0 || inFrame < 0 || durationFrames <= 0) {
      throw ArgumentError('CLIP geometry is invalid.');
    }

    final StructuralSourceRef ref = _requireExistingStructuralSource(
      model,
      structuralSource,
    );
    final ExactClipSpeed authoredSpeed = speed ?? ExactClipSpeed(1);
    final String newline = source.contains('\r\n') ? '\r\n' : '\n';
    final int close = target.block.closeStartOffset;
    final String indent = _lineIndentAt(source, close);
    final String clipIndent = '$indent  ';
    final String insertion = '$clipIndent[CLIP:$clipId:${ref.canonicalSource}:'
        '$atFrame:$inFrame:$durationFrames:${authoredSpeed.canonicalMarkup}]$newline'
        '$clipIndent[/CLIP]$newline'
        '$indent';

    final String next = model.cst.insertBeforeClosingTag(target.block, insertion);
    _validateRenderable(next);
    return next;
  }
}

StructuralSourceRef _requireExistingStructuralSource(
  EditDocumentModel model,
  String source,
) {
  final StructuralSourceRef? ref = StructuralSourceRef.tryParse(source);
  if (ref == null || ref.id.isEmpty) {
    throw ArgumentError.value(
      source,
      'structuralSource',
      'Expected EDIT.<id> or MOSAIC.<id>.',
    );
  }
  if (!model.containsStructuralSource(ref)) {
    throw StateError('No structural source named "${ref.canonicalSource}".');
  }
  return ref;
}

void _validateRenderable(String source) {
  final EditDocumentModel parsed = EditDocumentModel.parse(source);
  final EditLintResult lint = EditGraphLinter.lint(parsed);
  if (lint.isValid) return;
  final EditLintIssue issue = lint.issues.first;
  throw StateError('${issue.message} Path: ${issue.editPath.join(' -> ')}');
}

void _validateId(String type, String id) {
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) {
    throw ArgumentError.value(
      id,
      'id',
      '$type id must use letters, numbers, underscore, or hyphen.',
    );
  }
}

String _lineIndentAt(String source, int offset) {
  final int lineStart = source.lastIndexOf('\n', offset - 1) + 1;
  int cursor = lineStart;
  while (cursor < offset) {
    final int code = source.codeUnitAt(cursor);
    if (code != 32 && code != 9) break;
    cursor++;
  }
  return source.substring(lineStart, cursor);
}
