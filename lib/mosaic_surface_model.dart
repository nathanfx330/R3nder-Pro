// ./lib/mosaic_surface_model.dart
//
// Source-backed authoring operations for MOSAIC / PANE / CLIP.
//
// There is no composition database here. Every operation reparses canonical
// script text, rewrites one exact CST span, validates the resulting structural
// model, and runs the mixed EDIT/MOSAIC graph linter before returning source.
// Authored CLIP duration remains explicit project time and is never inferred
// from a referenced EDIT or MOSAIC after the clip has been created.
//
// M17 keeps the original pane-assignment API for compatibility, while adding
// real pane-timeline operations: a pane may append multiple already-trimmed
// EDIT cuts, move and trim those cuts in project time, and author a crossfade
// directly between adjacent cuts. Crossfade overlap is canonical CLIP time,
// never hidden GUI state.

import 'edit_linter.dart';
import 'edit_model.dart';
import 'mosaic_layout_cue.dart';

String createEmptyMosaic({
  required String source,
  required String mosaicId,
}) {
  _validateId('MOSAIC', mosaicId);

  final EditDocumentModel model = EditDocumentModel.parse(source);
  if (model.mosaics.any((MosaicSequence mosaic) => mosaic.id == mosaicId)) {
    throw StateError('MOSAIC "$mosaicId" already exists.');
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
    ..write('  [PANE:pane1]$newline')
    ..write('  [/PANE]$newline')
    ..write('[/MOSAIC]$newline');

  final String next = out.toString();
  _validateRenderable(next);
  return next;
}

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
  static final RegExp _incomingTransitionLine = RegExp(
    r'^[ \t]*\[#EDIT_TRANSITION:CROSSFADE:\d+\][ \t]*(\r?\n)?',
    multiLine: true,
  );

  static final RegExp _incomingCrossfadeDirective = RegExp(
    r'\[#EDIT_TRANSITION:CROSSFADE:(\d+)\]',
  );

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

  List<MosaicLayoutCue> get layoutCues => parseMosaicLayoutCues(
        source: source,
        mosaic: mosaic,
      );

  MosaicLayoutValidationResult get layoutValidation =>
      validateMosaicLayoutCues(
        mosaic: mosaic,
        cues: layoutCues,
      );

  String addLayoutCue({
    required int frame,
    required MosaicLayoutState state,
    int durationFrames = kDefaultMosaicLayoutTransitionFrames,
  }) {
    final MosaicLayoutCue cue = MosaicLayoutCue(
      frame: frame,
      state: _explicitLayoutState(state),
      durationFrames: durationFrames,
    );
    final List<MosaicLayoutCue> existing = layoutCues;
    if (existing.any((MosaicLayoutCue item) => item.frame == frame)) {
      throw StateError('A LAYOUT cue already exists at frame $frame.');
    }

    final List<MosaicLayoutCue> candidate = <MosaicLayoutCue>[
      ...existing,
      cue,
    ];
    _throwLayoutErrors(
      validateMosaicLayoutCues(mosaic: mosaic, cues: candidate),
    );

    final String newline = source.contains('\r\n') ? '\r\n' : '\n';
    final String indent = existing.isNotEmpty
        ? (existing.first.sourceSpan?.indent ?? '')
        : mosaic.panes.isNotEmpty
            ? _lineIndentAt(source, mosaic.panes.first.block.startOffset)
            : '${_lineIndentAt(source, mosaic.block.startOffset)}  ';

    int insertionOffset;
    final List<MosaicLayoutCue> after = existing
        .where((MosaicLayoutCue item) => item.frame > frame)
        .toList()
      ..sort((MosaicLayoutCue a, MosaicLayoutCue b) => a.frame.compareTo(b.frame));
    if (after.isNotEmpty) {
      insertionOffset = after.first.sourceSpan!.startOffset;
    } else if (mosaic.panes.isNotEmpty) {
      insertionOffset = _lineStartAt(source, mosaic.panes.first.block.startOffset);
    } else {
      insertionOffset = _lineStartAt(source, mosaic.block.closeStartOffset);
    }

    final String next = source.replaceRange(
      insertionOffset,
      insertionOffset,
      '$indent${cue.formatTag()}$newline',
    );
    _validateMosaicLayoutRenderable(next, mosaicId);
    return next;
  }

  String updateLayoutCue(
    int existingFrame, {
    int? frame,
    MosaicLayoutState? state,
    int? durationFrames,
  }) {
    final List<MosaicLayoutCue> existing = layoutCues;
    final MosaicLayoutCue selected = existing.singleWhere(
      (MosaicLayoutCue cue) => cue.frame == existingFrame,
      orElse: () => throw StateError(
        'No LAYOUT cue exists at frame $existingFrame.',
      ),
    );
    final MosaicLayoutCue replacement = MosaicLayoutCue(
      frame: frame ?? selected.frame,
      state: _explicitLayoutState(state ?? selected.state),
      durationFrames: durationFrames ?? selected.durationFrames,
    );

    final List<MosaicLayoutCue> candidate = <MosaicLayoutCue>[
      for (final MosaicLayoutCue cue in existing)
        if (identical(cue, selected)) replacement else cue,
    ];
    _throwLayoutErrors(
      validateMosaicLayoutCues(mosaic: mosaic, cues: candidate),
    );

    final MosaicLayoutSourceSpan span = selected.sourceSpan!;
    final String next = source.replaceRange(
      span.startOffset,
      span.endOffset,
      '${span.indent}${replacement.formatTag()}${span.lineEnding}',
    );
    _validateMosaicLayoutRenderable(next, mosaicId);
    return next;
  }

  String removeLayoutCue(int frame) {
    final MosaicLayoutCue selected = layoutCues.singleWhere(
      (MosaicLayoutCue cue) => cue.frame == frame,
      orElse: () => throw StateError('No LAYOUT cue exists at frame $frame.'),
    );
    final MosaicLayoutSourceSpan span = selected.sourceSpan!;
    final String next = source.replaceRange(span.startOffset, span.endOffset, '');
    _validateMosaicLayoutRenderable(next, mosaicId);
    return next;
  }

  /// Renames one pane and atomically rewrites every explicit LAYOUT reference.
  ///
  /// Bare TWOUP deliberately remains bare: its meaning is authored pane order.
  String renamePane(String oldId, String newId) {
    _validateId('PANE', newId);
    final MosaicPane target = pane(oldId);
    if (mosaic.panes.any(
      (MosaicPane candidate) =>
          candidate.id == newId && candidate.id != target.id,
    )) {
      throw StateError('PANE "$newId" already exists in MOSAIC "$mosaicId".');
    }
    if (oldId == newId) return source;

    final List<_SourceReplacement> replacements = <_SourceReplacement>[
      _SourceReplacement(
        startOffset: target.block.startOffset,
        endOffset: target.block.openEndOffset,
        replacement: '[PANE:$newId]',
      ),
    ];

    for (final MosaicLayoutCue cue in layoutCues) {
      if (!cue.state.referencesPane(oldId)) continue;
      final MosaicLayoutSourceSpan span = cue.sourceSpan!;
      final MosaicLayoutCue renamed = cue.copyWith(
        state: cue.state.renamePane(oldId, newId),
        clearSourceSpan: true,
      );
      replacements.add(
        _SourceReplacement(
          startOffset: span.startOffset,
          endOffset: span.endOffset,
          replacement:
              '${span.indent}${renamed.formatTag()}${span.lineEnding}',
        ),
      );
    }

    replacements.sort(
      (_SourceReplacement a, _SourceReplacement b) =>
          b.startOffset.compareTo(a.startOffset),
    );
    String next = source;
    for (final _SourceReplacement replacement in replacements) {
      next = next.replaceRange(
        replacement.startOffset,
        replacement.endOffset,
        replacement.replacement,
      );
    }

    _validateMosaicLayoutRenderable(next, mosaicId);
    return next;
  }

  MosaicLayoutState _explicitLayoutState(MosaicLayoutState state) {
    if (!state.isBareTwoUp) return state;
    return state.resolveBareTwoUp(
      mosaic.panes.map((MosaicPane pane) => pane.id).toList(growable: false),
    );
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

  String setPaneCount(int count) {
    if (count < 1 || count > 3) {
      throw ArgumentError.value(
        count,
        'count',
        'MOSAIC pane count must be 1, 2, or 3.',
      );
    }
    if (count == mosaic.panes.length) return source;

    String next = source;

    while (MosaicSurfaceDocument.parse(next, mosaicId).mosaic.panes.length >
        count) {
      final MosaicSurfaceDocument current =
          MosaicSurfaceDocument.parse(next, mosaicId);
      final MosaicPane remove = current.mosaic.panes.last;
      final int remainingPaneCount = current.mosaic.panes.length - 1;
      final List<MosaicLayoutCue> blocking = current.layoutCues
          .where(
            (MosaicLayoutCue cue) =>
                cue.state.referencesPane(remove.id) ||
                (cue.state.isBareTwoUp && remainingPaneCount < 2),
          )
          .toList(growable: false);
      if (blocking.isNotEmpty) {
        throw StateError(
          'Cannot remove PANE "${remove.id}" while LAYOUT cues still '
          'reference it or require two panes.',
        );
      }
      next = current.model.cst.replaceBlock(remove.block, '');
      _validateMosaicLayoutRenderable(next, mosaicId);
    }

    while (MosaicSurfaceDocument.parse(next, mosaicId).mosaic.panes.length <
        count) {
      final MosaicSurfaceDocument current =
          MosaicSurfaceDocument.parse(next, mosaicId);
      final int ordinal = current.mosaic.panes.length + 1;
      String paneId = 'pane$ordinal';
      if (current.mosaic.panes.any((MosaicPane p) => p.id == paneId)) {
        paneId = current.nextPaneId('pane');
      }

      final String newline = next.contains('\r\n') ? '\r\n' : '\n';
      final int close = current.mosaic.block.closeStartOffset;
      final String indent = _lineIndentAt(next, close);
      final String paneIndent = '$indent  ';
      final String insertion = '$paneIndent[PANE:$paneId]$newline'
          '$paneIndent[/PANE]$newline'
          '$indent';
      next = current.model.cst.insertBeforeClosingTag(
        current.mosaic.block,
        insertion,
      );
      _validateRenderable(next);
    }

    return next;
  }

  /// Compatibility operation used by older callers. Replaces the pane with
  /// exactly one cut at frame zero.
  String assignCut(String paneId, EditClip cut) {
    final MosaicPane target = pane(paneId);
    _validateId('CLIP', cut.id);

    final String newline = source.contains('\r\n') ? '\r\n' : '\n';
    final String paneIndent = _lineIndentAt(source, target.block.closeStartOffset);
    final String clipIndent = '$paneIndent  ';
    final String body = '$newline'
        '$clipIndent[CLIP:${cut.id}:${cut.source}:0:${cut.inFrame}:'
        '${cut.durationFrames}:${cut.speed.canonicalMarkup}]$newline'
        '$clipIndent[/CLIP]$newline'
        '$paneIndent';

    final String next = model.cst.replaceInnerSource(target.block, body);
    _validateRenderable(next);
    return next;
  }

  /// Appends an already-authored EDIT cut after the last visible pane frame.
  String appendCut(String paneId, EditClip cut) {
    final MosaicPane target = pane(paneId);
    final String clipId = nextClipId(paneId, cut.id);
    final int atFrame = target.clips.fold<int>(
      0,
      (int end, EditClip item) =>
          item.endFrameExclusive > end ? item.endFrameExclusive : end,
    );
    final String newline = source.contains('\r\n') ? '\r\n' : '\n';
    final int close = target.block.closeStartOffset;
    final String paneIndent = _lineIndentAt(source, close);
    final String clipIndent = '$paneIndent  ';
    final String insertion = '$clipIndent[CLIP:$clipId:${cut.source}:$atFrame:'
        '${cut.inFrame}:${cut.durationFrames}:${cut.speed.canonicalMarkup}]$newline'
        '$clipIndent[/CLIP]$newline'
        '$paneIndent';

    final String next = model.cst.insertBeforeClosingTag(target.block, insertion);
    _validateRenderable(next);
    return next;
  }

  int incomingCrossfadeFrames(String paneId, String clipId) {
    final RegExpMatch? match = _incomingCrossfadeDirective.firstMatch(
      clip(paneId, clipId).block.innerSource,
    );
    return match == null ? 0 : int.parse(match.group(1)!);
  }

  /// Authors a transition BETWEEN two adjacent pane cuts.
  ///
  /// The right cut owns the incoming transition. Unlike the earlier card UI,
  /// this operation cannot assume the cuts are still at hard-cut geometry:
  /// authors may have dragged or trimmed them on the pane timeline. Therefore
  /// the requested transition normalizes the right cut to
  /// `left.end - frames`, then shifts every later cut by the same amount so
  /// downstream timing remains continuous. Clearing returns the pair to a
  /// hard-cut boundary at `left.end`.
  String setCrossfadeBetween(
    String paneId,
    String leftClipId,
    String rightClipId,
    int frames,
  ) {
    if (frames < 0) {
      throw ArgumentError.value(frames, 'frames', 'Must be non-negative.');
    }

    final MosaicPane target = pane(paneId);
    final List<EditClip> ordered = List<EditClip>.from(target.clips)
      ..sort((EditClip a, EditClip b) {
        final int time = a.atFrame.compareTo(b.atFrame);
        if (time != 0) return time;
        return a.id.compareTo(b.id);
      });
    final int leftIndex = ordered.indexWhere((EditClip c) => c.id == leftClipId);
    final int rightIndex = ordered.indexWhere((EditClip c) => c.id == rightClipId);
    if (leftIndex < 0 || rightIndex != leftIndex + 1) {
      throw StateError(
        'Crossfade endpoints must be adjacent cuts in PANE "$paneId".',
      );
    }

    final EditClip left = ordered[leftIndex];
    final EditClip right = ordered[rightIndex];
    if (frames > left.durationFrames || frames > right.durationFrames) {
      throw ArgumentError.value(
        frames,
        'frames',
        'Crossfade cannot exceed either adjacent cut duration.',
      );
    }

    final int targetRightAt = left.endFrameExclusive - frames;
    if (targetRightAt < 0) {
      throw StateError('Crossfade would move CLIP "$rightClipId" before frame zero.');
    }
    final int shift = targetRightAt - right.atFrame;
    String shifted = source;

    if (shift != 0) {
      for (int index = rightIndex; index < ordered.length; index++) {
        final String id = ordered[index].id;
        final MosaicSurfaceDocument current =
            MosaicSurfaceDocument.parse(shifted, mosaicId);
        final EditClip currentClip = current.clip(paneId, id);
        final int nextAt = currentClip.atFrame + shift;
        if (nextAt < 0) {
          throw StateError('Crossfade would move CLIP "$id" before frame zero.');
        }
        shifted = current.model.rewriteClip(currentClip, atFrame: nextAt);
      }
    }

    final MosaicSurfaceDocument shiftedDocument =
        MosaicSurfaceDocument.parse(shifted, mosaicId);
    final EditClip shiftedRight = shiftedDocument.clip(paneId, rightClipId);
    final String body = shiftedRight.block.innerSource;
    final String cleaned = body.replaceFirst(_incomingTransitionLine, '');

    final String replacement = frames == 0
        ? cleaned
        : _insertIncomingCrossfade(
            shifted,
            shiftedRight,
            cleaned,
            frames,
          );

    final String next = shiftedDocument.model.cst.replaceInnerSource(
      shiftedRight.block,
      replacement,
    );
    _validateRenderable(next);
    return next;
  }

  /// Removes one complete CLIP block, including its incoming crossfade and cues.
  ///
  /// Surrounding source and surviving clip timing remain untouched. Removing
  /// the last clip leaves the PANE in place; higher-level operations such as
  /// trim-to-shortest must enforce their own populated-pane requirements.
  String removeClip(String paneId, String clipId) {
    final EditClip selected = clip(paneId, clipId);
    final String next = model.cst.replaceBlock(selected.block, '');
    _validateRenderable(next);
    return next;
  }

  String clearPane(String paneId) {
    final MosaicPane target = pane(paneId);
    final String newline = source.contains('\r\n') ? '\r\n' : '\n';
    final String paneIndent = _lineIndentAt(source, target.block.closeStartOffset);
    final String next = model.cst.replaceInnerSource(
      target.block,
      '$newline$paneIndent',
    );
    _validateRenderable(next);
    return next;
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

  /// Trims the left edge in project time while preserving sampled source time.
  /// Extending left is allowed while the resulting source IN remains >= 0.
  String trimClipStart(String paneId, String clipId, int newAtFrame) {
    final EditClip selected = clip(paneId, clipId);
    final int delta = newAtFrame - selected.atFrame;
    final int newDuration = selected.durationFrames - delta;

    if (newAtFrame < 0) {
      throw ArgumentError.value(newAtFrame, 'newAtFrame', 'Must be non-negative.');
    }
    if (newDuration <= 0) {
      throw ArgumentError.value(
        newAtFrame,
        'newAtFrame',
        'Trim would remove the entire CLIP.',
      );
    }

    final int sourceDelta = _floorDiv(
      delta * selected.speed.numerator,
      selected.speed.denominator,
    );
    final int newIn = selected.inFrame + sourceDelta;
    if (newIn < 0) {
      throw ArgumentError.value(
        newAtFrame,
        'newAtFrame',
        'Trim would move before source frame zero.',
      );
    }

    final int transitionFrames = incomingCrossfadeFrames(paneId, clipId);
    if (transitionFrames > newDuration) {
      throw StateError(
        'Trim would make the ${transitionFrames}F incoming crossfade longer '
        'than CLIP "$clipId".',
      );
    }

    final String next = model.rewriteClip(
      selected,
      atFrame: newAtFrame,
      inFrame: newIn,
      durationFrames: newDuration,
    );
    _validateRenderable(next);
    return next;
  }

  String trimClipEnd(String paneId, String clipId, int newEndFrameExclusive) {
    final EditClip selected = clip(paneId, clipId);
    final int duration = newEndFrameExclusive - selected.atFrame;
    if (duration <= 0) {
      throw ArgumentError.value(
        newEndFrameExclusive,
        'newEndFrameExclusive',
        'Trim would remove the entire CLIP.',
      );
    }

    final int transitionFrames = incomingCrossfadeFrames(paneId, clipId);
    if (transitionFrames > duration) {
      throw StateError(
        'Trim would make the ${transitionFrames}F incoming crossfade longer '
        'than CLIP "$clipId".',
      );
    }

    final String next = model.rewriteClip(
      selected,
      durationFrames: duration,
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
    final ExactClipSpeed authoredSpeed = speed ?? ExactClipSpeed.unity;
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

  static String _insertIncomingCrossfade(
    String document,
    EditClip clip,
    String body,
    int frames,
  ) {
    final String childIndent = '${_lineIndentAt(document, clip.block.startOffset)}  ';
    final String lineEnding = body.contains('\r\n') ? '\r\n' : '\n';
    final String directive = '[#EDIT_TRANSITION:CROSSFADE:$frames]';

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
}

class _SourceReplacement {
  final int startOffset;
  final int endOffset;
  final String replacement;

  const _SourceReplacement({
    required this.startOffset,
    required this.endOffset,
    required this.replacement,
  });
}

void _throwLayoutErrors(MosaicLayoutValidationResult validation) {
  final List<MosaicLayoutIssue> errors =
      validation.errors.toList(growable: false);
  if (errors.isEmpty) return;
  throw StateError(errors.first.message);
}

void _validateMosaicLayoutRenderable(String source, String mosaicId) {
  _validateRenderable(source);
  final EditDocumentModel parsed = EditDocumentModel.parse(source);
  final MosaicSequence mosaic = parsed.mosaic(mosaicId);
  final List<MosaicLayoutCue> cues = parseMosaicLayoutCues(
    source: source,
    mosaic: mosaic,
  );
  _throwLayoutErrors(
    validateMosaicLayoutCues(
      mosaic: mosaic,
      cues: cues,
    ),
  );
}

int _lineStartAt(String source, int offset) =>
    source.lastIndexOf('\n', offset - 1) + 1;

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

int _floorDiv(int numerator, int denominator) {
  assert(denominator > 0);
  final int quotient = numerator ~/ denominator;
  final int remainder = numerator % denominator;
  if (remainder == 0 || numerator >= 0) return quotient;
  return quotient - 1;
}
