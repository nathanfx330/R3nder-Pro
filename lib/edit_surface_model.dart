// ./lib/edit_surface_model.dart
//
// Source-backed editing operations for the M10 EDIT / TRACK / CLIP surface.
//
// This layer deliberately owns no project database. Every operation accepts
// authored script text and returns authored script text. The nested CST and
// EditDocumentModel remain the authority for ownership, geometry, and exact
// source spans.

import 'edit_model.dart';

enum EditTransitionKind {
  none,
  crossfade,
  luma,
}

class EditTransition {
  final EditTransitionKind kind;
  final int frames;
  final String lumaSource;

  const EditTransition._({
    required this.kind,
    required this.frames,
    required this.lumaSource,
  });

  const EditTransition.none()
      : this._(
          kind: EditTransitionKind.none,
          frames: 0,
          lumaSource: '',
        );

  const EditTransition.crossfade(int frames)
      : this._(
          kind: EditTransitionKind.crossfade,
          frames: frames,
          lumaSource: '',
        );

  const EditTransition.luma(String source, int frames)
      : this._(
          kind: EditTransitionKind.luma,
          frames: frames,
          lumaSource: source,
        );

  bool get isNone => kind == EditTransitionKind.none;

  String get directive {
    switch (kind) {
      case EditTransitionKind.none:
        return '';
      case EditTransitionKind.crossfade:
        return '[#EDIT_TRANSITION:CROSSFADE:$frames]';
      case EditTransitionKind.luma:
        return '[#EDIT_TRANSITION:LUMA:$lumaSource:$frames]';
    }
  }

  @override
  bool operator ==(Object other) =>
      other is EditTransition &&
      other.kind == kind &&
      other.frames == frames &&
      other.lumaSource == lumaSource;

  @override
  int get hashCode => Object.hash(kind, frames, lumaSource);
}

class EditSurfaceClip {
  final String editId;
  final String trackId;
  final EditClip clip;
  final EditTransition transition;

  const EditSurfaceClip({
    required this.editId,
    required this.trackId,
    required this.clip,
    required this.transition,
  });

  String get id => clip.id;
  String get source => clip.source;
  int get atFrame => clip.atFrame;
  int get inFrame => clip.inFrame;
  int get durationFrames => clip.durationFrames;
  int get endFrameExclusive => clip.endFrameExclusive;
  ExactClipSpeed get speed => clip.speed;
}

class EditSurfaceTrack {
  final String editId;
  final EditTrack track;
  final List<EditSurfaceClip> clips;

  const EditSurfaceTrack({
    required this.editId,
    required this.track,
    required this.clips,
  });

  String get id => track.id;
}

String createEditWithClip({
  required String source,
  required String editId,
  required String trackId,
  required String clipId,
  required String mediaSource,
  required int atFrame,
  required int durationFrames,
}) {
  _validateInsertedClip(
    editId: editId,
    trackId: trackId,
    clipId: clipId,
    mediaSource: mediaSource,
    atFrame: atFrame,
    durationFrames: durationFrames,
  );

  final EditDocumentModel existing = EditDocumentModel.parse(source);
  if (existing.edits.isNotEmpty) {
    throw StateError('createEditWithClip requires a document with no EDIT blocks.');
  }

  final String lineEnding = source.contains('\r\n') ? '\r\n' : '\n';
  final StringBuffer out = StringBuffer(source);
  if (source.isNotEmpty &&
      !source.endsWith('\n') &&
      !source.endsWith('\r')) {
    out.write(lineEnding);
  }

  out
    ..write('[EDIT:$editId]$lineEnding')
    ..write('  [TRACK:$trackId]$lineEnding')
    ..write('    ${_clipOpeningTagStatic(
      id: clipId,
      source: mediaSource,
      atFrame: atFrame,
      inFrame: 0,
      durationFrames: durationFrames,
      speed: ExactClipSpeed(1),
    )}$lineEnding')
    ..write('    [/CLIP]$lineEnding')
    ..write('  [/TRACK]$lineEnding')
    ..write('[/EDIT]$lineEnding');

  final String next = out.toString();
  EditSurfaceDocument.parse(next, editId);
  return next;
}

class EditSurfaceDocument {
  static final RegExp _transitionLine = RegExp(
    r'^[ \t]*\[#EDIT_TRANSITION:(CROSSFADE:\d+|LUMA:[^:\r\n\]]+:\d+)\][ \t]*(\r?\n)?',
    multiLine: true,
  );

  static final RegExp _crossfadeDirective = RegExp(
    r'\[#EDIT_TRANSITION:CROSSFADE:(\d+)\]',
  );

  static final RegExp _lumaDirective = RegExp(
    r'\[#EDIT_TRANSITION:LUMA:([^\]\r\n:]+):(\d+)\]',
  );

  final EditDocumentModel model;
  final String editId;
  final List<EditSurfaceTrack> tracks;

  EditSurfaceDocument._({
    required this.model,
    required this.editId,
    required this.tracks,
  });

  factory EditSurfaceDocument.parse(String source, String editId) {
    final EditDocumentModel model = EditDocumentModel.parse(source);
    final EditSequence edit = model.edit(editId);
    final List<EditSurfaceTrack> tracks = <EditSurfaceTrack>[];

    for (final EditTrack track in edit.tracks) {
      final List<EditSurfaceClip> clips = <EditSurfaceClip>[];
      for (final EditClip clip in track.clips) {
        clips.add(
          EditSurfaceClip(
            editId: editId,
            trackId: track.id,
            clip: clip,
            transition: _parseTransition(clip.block.innerSource),
          ),
        );
      }
      tracks.add(
        EditSurfaceTrack(
          editId: editId,
          track: track,
          clips: List<EditSurfaceClip>.unmodifiable(clips),
        ),
      );
    }

    return EditSurfaceDocument._(
      model: model,
      editId: editId,
      tracks: List<EditSurfaceTrack>.unmodifiable(tracks),
    );
  }

  String get source => model.source;

  EditSequence get edit => model.edit(editId);

  int get projectFrameCount => edit.projectFrameCount;

  EditSurfaceTrack track(String trackId) => tracks.singleWhere(
        (EditSurfaceTrack track) => track.id == trackId,
        orElse: () => throw StateError(
          'No TRACK named "$trackId" in EDIT "$editId".',
        ),
      );

  EditSurfaceTrack? trackOrNull(String trackId) {
    for (final EditSurfaceTrack track in tracks) {
      if (track.id == trackId) return track;
    }
    return null;
  }

  EditSurfaceClip clip(String trackId, String clipId) =>
      track(trackId).clips.singleWhere(
            (EditSurfaceClip clip) => clip.id == clipId,
            orElse: () => throw StateError(
              'No CLIP named "$clipId" in TRACK "$trackId".',
            ),
          );

  String nextClipId(String trackId, String baseId) {
    if (!_structuralIdPattern.hasMatch(baseId)) {
      throw ArgumentError.value(
        baseId,
        'baseId',
        'CLIP id must use letters, numbers, underscore, or hyphen.',
      );
    }

    final Set<String> ids = trackOrNull(trackId)
            ?.clips
            .map((EditSurfaceClip clip) => clip.id)
            .toSet() ??
        <String>{};
    if (!ids.contains(baseId)) return baseId;

    int suffix = 2;
    String candidate = '${baseId}_$suffix';
    while (ids.contains(candidate)) {
      suffix++;
      candidate = '${baseId}_$suffix';
    }
    return candidate;
  }

  String addClip({
    required String trackId,
    required String clipId,
    required String mediaSource,
    required int atFrame,
    required int durationFrames,
  }) {
    _validateInsertedClip(
      editId: editId,
      trackId: trackId,
      clipId: clipId,
      mediaSource: mediaSource,
      atFrame: atFrame,
      durationFrames: durationFrames,
    );

    final String opening = _clipOpeningTag(
      id: clipId,
      source: mediaSource,
      atFrame: atFrame,
      inFrame: 0,
      durationFrames: durationFrames,
      speed: ExactClipSpeed(1),
    );
    final String lineEnding = source.contains('\r\n') ? '\r\n' : '\n';
    final EditSurfaceTrack? existingTrack = trackOrNull(trackId);

    late final String next;
    if (existingTrack != null) {
      final int close = existingTrack.track.block.closeStartOffset;
      final String parentIndent = _lineIndentAt(source, close);
      final String childIndent = '$parentIndent  ';
      final String insertion = '  $opening$lineEnding'
          '$childIndent[/CLIP]$lineEnding'
          '$parentIndent';
      next = model.cst.insertBeforeClosingTag(
        existingTrack.track.block,
        insertion,
      );
    } else {
      final int close = edit.block.closeStartOffset;
      final String editIndent = _lineIndentAt(source, close);
      final String trackIndent = '$editIndent  ';
      final String clipIndent = '$trackIndent  ';
      final String insertion = '  [TRACK:$trackId]$lineEnding'
          '$clipIndent$opening$lineEnding'
          '$clipIndent[/CLIP]$lineEnding'
          '$trackIndent[/TRACK]$lineEnding'
          '$editIndent';
      next = model.cst.insertBeforeClosingTag(edit.block, insertion);
    }

    EditSurfaceDocument.parse(next, editId);
    return next;
  }

  String moveClip(String trackId, String clipId, int atFrame) {
    if (atFrame < 0) {
      throw ArgumentError.value(atFrame, 'atFrame', 'Must be non-negative.');
    }
    final EditSurfaceClip selected = clip(trackId, clipId);
    return model.rewriteClip(selected.clip, atFrame: atFrame);
  }

  String trimStart(String trackId, String clipId, int newAtFrame) {
    final EditSurfaceClip selected = clip(trackId, clipId);
    final EditClip editClip = selected.clip;
    final int delta = newAtFrame - editClip.atFrame;
    final int newDuration = editClip.durationFrames - delta;

    if (newAtFrame < 0) {
      throw ArgumentError.value(
        newAtFrame,
        'newAtFrame',
        'CLIP start must be non-negative.',
      );
    }
    if (newDuration <= 0) {
      throw ArgumentError.value(
        newAtFrame,
        'newAtFrame',
        'Trim would remove the entire CLIP.',
      );
    }

    final int sourceDelta = _floorDiv(
      delta * editClip.speed.numerator,
      editClip.speed.denominator,
    );
    final int newIn = editClip.inFrame + sourceDelta;
    if (newIn < 0) {
      throw ArgumentError.value(
        newAtFrame,
        'newAtFrame',
        'Trim would move before source frame zero.',
      );
    }

    return model.rewriteClip(
      editClip,
      atFrame: newAtFrame,
      inFrame: newIn,
      durationFrames: newDuration,
    );
  }

  String trimEnd(String trackId, String clipId, int newEndFrameExclusive) {
    final EditSurfaceClip selected = clip(trackId, clipId);
    final EditClip editClip = selected.clip;
    final int duration = newEndFrameExclusive - editClip.atFrame;
    if (duration <= 0) {
      throw ArgumentError.value(
        newEndFrameExclusive,
        'newEndFrameExclusive',
        'Trim would remove the entire CLIP.',
      );
    }
    return model.rewriteClip(editClip, durationFrames: duration);
  }

  String slipClip(String trackId, String clipId, int sourceFrameDelta) {
    final EditSurfaceClip selected = clip(trackId, clipId);
    final int nextIn = selected.clip.inFrame + sourceFrameDelta;
    if (nextIn < 0) {
      throw ArgumentError.value(
        sourceFrameDelta,
        'sourceFrameDelta',
        'Slip would move before source frame zero.',
      );
    }
    return model.rewriteClip(selected.clip, inFrame: nextIn);
  }

  String setSpeed(
    String trackId,
    String clipId,
    ExactClipSpeed speed,
  ) {
    final EditSurfaceClip selected = clip(trackId, clipId);
    return model.rewriteClip(selected.clip, speed: speed);
  }

  String setTransition(
    String trackId,
    String clipId,
    EditTransition transition,
  ) {
    final EditSurfaceClip selected = clip(trackId, clipId);
    _validateTransition(transition, selected.durationFrames);

    final String body = selected.clip.block.innerSource;
    final String cleaned = body.replaceFirst(_transitionLine, '');
    final String replacement = transition.isNone
        ? cleaned
        : _insertTransitionDirective(
            source,
            selected.clip,
            cleaned,
            transition.directive,
          );

    return model.cst.replaceInnerSource(selected.clip.block, replacement);
  }

  String splitClip(String trackId, String clipId, int projectFrame) {
    final EditSurfaceTrack selectedTrack = track(trackId);
    final EditSurfaceClip selected = clip(trackId, clipId);
    final EditClip editClip = selected.clip;

    if (projectFrame <= editClip.atFrame ||
        projectFrame >= editClip.endFrameExclusive) {
      throw ArgumentError.value(
        projectFrame,
        'projectFrame',
        'Split frame must be strictly inside the CLIP.',
      );
    }

    final int leftDuration = projectFrame - editClip.atFrame;
    final int rightDuration = editClip.durationFrames - leftDuration;
    final int rightIn = editClip.sourceFrameAtProjectOffset(leftDuration);
    final String rightId = _nextSplitId(selectedTrack, editClip.id);
    final String indent = _lineIndentAt(source, editClip.block.startOffset);

    final String leftOpening = _clipOpeningTag(
      id: editClip.id,
      source: editClip.source,
      atFrame: editClip.atFrame,
      inFrame: editClip.inFrame,
      durationFrames: leftDuration,
      speed: editClip.speed,
    );
    final String rightOpening = _clipOpeningTag(
      id: rightId,
      source: editClip.source,
      atFrame: projectFrame,
      inFrame: rightIn,
      durationFrames: rightDuration,
      speed: editClip.speed,
    );

    final String leftBody = editClip.block.innerSource;
    final String rightBody = leftBody.replaceFirst(_transitionLine, '');
    final String replacement = '$leftOpening$leftBody[/CLIP]\n'
        '$indent$rightOpening$rightBody[/CLIP]';

    return model.cst.replaceBlock(editClip.block, replacement);
  }

  static EditTransition _parseTransition(String body) {
    final RegExpMatch? crossfade = _crossfadeDirective.firstMatch(body);
    if (crossfade != null) {
      final int frames = int.parse(crossfade.group(1)!);
      return EditTransition.crossfade(frames);
    }

    final RegExpMatch? luma = _lumaDirective.firstMatch(body);
    if (luma != null) {
      final String source = luma.group(1)!;
      final int frames = int.parse(luma.group(2)!);
      return EditTransition.luma(source, frames);
    }

    return const EditTransition.none();
  }

  static void _validateTransition(EditTransition transition, int clipDuration) {
    if (transition.isNone) return;
    if (transition.frames <= 0 || transition.frames > clipDuration) {
      throw ArgumentError.value(
        transition.frames,
        'transition.frames',
        'Transition must be between 1 and the CLIP duration.',
      );
    }
    if (transition.kind == EditTransitionKind.luma) {
      final String source = transition.lumaSource.trim();
      if (source.isEmpty ||
          source.contains(':') ||
          source.contains('\n') ||
          source.contains('\r')) {
        throw ArgumentError.value(
          transition.lumaSource,
          'transition.lumaSource',
          'Luma source must be one non-empty path without colon or newline.',
        );
      }
    }
  }

  static String _insertTransitionDirective(
    String document,
    EditClip clip,
    String body,
    String directive,
  ) {
    final String childIndent = '${_lineIndentAt(document, clip.block.startOffset)}  ';
    final String lineEnding = body.contains('\r\n') ? '\r\n' : '\n';

    if (body.startsWith('\r\n')) {
      return '$lineEnding$childIndent$directive$lineEnding${body.substring(2)}';
    }
    if (body.startsWith('\n')) {
      return '$lineEnding$childIndent$directive$lineEnding${body.substring(1)}';
    }
    if (body.isEmpty) {
      return '$lineEnding$childIndent$directive$lineEnding'
          '${_lineIndentAt(document, clip.block.startOffset)}';
    }
    return '$lineEnding$childIndent$directive$lineEnding$body';
  }

  static String _nextSplitId(EditSurfaceTrack track, String baseId) {
    final Set<String> ids = track.clips
        .map((EditSurfaceClip clip) => clip.id)
        .toSet();
    int suffix = 2;
    String candidate = '${baseId}_$suffix';
    while (ids.contains(candidate)) {
      suffix++;
      candidate = '${baseId}_$suffix';
    }
    return candidate;
  }

  static String _clipOpeningTag({
    required String id,
    required String source,
    required int atFrame,
    required int inFrame,
    required int durationFrames,
    required ExactClipSpeed speed,
  }) {
    return _clipOpeningTagStatic(
      id: id,
      source: source,
      atFrame: atFrame,
      inFrame: inFrame,
      durationFrames: durationFrames,
      speed: speed,
    );
  }

  static String _lineIndentAt(String source, int offset) {
    final int start = source.lastIndexOf('\n', offset > 0 ? offset - 1 : 0) + 1;
    int cursor = start;
    while (cursor < offset) {
      final int code = source.codeUnitAt(cursor);
      if (code != 32 && code != 9) break;
      cursor++;
    }
    return source.substring(start, cursor);
  }
}

final RegExp _structuralIdPattern = RegExp(r'^[A-Za-z0-9_-]+$');

void _validateInsertedClip({
  required String editId,
  required String trackId,
  required String clipId,
  required String mediaSource,
  required int atFrame,
  required int durationFrames,
}) {
  for (final MapEntry<String, String> entry in <String, String>{
    'editId': editId,
    'trackId': trackId,
    'clipId': clipId,
  }.entries) {
    if (!_structuralIdPattern.hasMatch(entry.value)) {
      throw ArgumentError.value(
        entry.value,
        entry.key,
        'Structural ids must use letters, numbers, underscore, or hyphen.',
      );
    }
  }

  final String path = mediaSource.trim();
  if (path.isEmpty ||
      path.contains(':') ||
      path.contains('\n') ||
      path.contains('\r')) {
    throw ArgumentError.value(
      mediaSource,
      'mediaSource',
      'Media source must be one non-empty portable path without colon or newline.',
    );
  }
  if (atFrame < 0) {
    throw ArgumentError.value(atFrame, 'atFrame', 'Must be non-negative.');
  }
  if (durationFrames <= 0) {
    throw ArgumentError.value(
      durationFrames,
      'durationFrames',
      'CLIP duration must be positive.',
    );
  }
}

String _clipOpeningTagStatic({
  required String id,
  required String source,
  required int atFrame,
  required int inFrame,
  required int durationFrames,
  required ExactClipSpeed speed,
}) {
  return '[CLIP:$id:$source:$atFrame:$inFrame:$durationFrames:'
      '${speed.canonicalMarkup}]';
}

int _floorDiv(int numerator, int denominator) {
  assert(denominator > 0);
  final int quotient = numerator ~/ denominator;
  final int remainder = numerator % denominator;
  if (remainder == 0 || numerator >= 0) return quotient;
  return quotient - 1;
}
