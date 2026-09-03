// ./lib/script_cst.dart
//
// Nested concrete-syntax ownership for structural script blocks.
//
// The existing ScriptNode parser is intentionally flat: it is excellent for
// lossless editing of the current tag language, but block bodies such as CARD
// and TIMELINE are opaque strings. EDIT / TRACK / CLIP need a different
// guarantee. Their nesting is structural, and editing an inner block must not
// give the writer permission to regenerate any enclosing bytes.
//
// This file supplies that missing layer without changing runtime parsing. It
// recognizes only structural ownership tags and records exact source spans.
// Everything else remains uninterpreted source. Mutations are source-range
// replacements, so bytes outside the selected span are preserved verbatim.

class ScriptCstFormatException implements Exception {
  final String message;
  final int offset;

  const ScriptCstFormatException(this.message, this.offset);

  @override
  String toString() => 'ScriptCstFormatException at $offset: $message';
}

class ScriptCstDocument {
  static const Set<String> structuralTypes = <String>{
    'EDIT',
    'TRACK',
    'CLIP',
  };

  static final RegExp _structuralTag = RegExp(
    r'\[(?<close>/)?(?<type>EDIT|TRACK|CLIP)(?<tail>:[^\]\r\n]*)?\]',
  );

  final String source;
  final List<ScriptCstBlock> roots;

  ScriptCstDocument._(this.source, this.roots);

  factory ScriptCstDocument.parse(String source) {
    final List<_OpenStructuralBlock> stack = <_OpenStructuralBlock>[];
    final List<ScriptCstBlock> roots = <ScriptCstBlock>[];

    for (final RegExpMatch match in _structuralTag.allMatches(source)) {
      final bool closing = match.namedGroup('close') != null;
      final String type = match.namedGroup('type')!;
      final String tail = match.namedGroup('tail') ?? '';

      if (!closing) {
        stack.add(
          _OpenStructuralBlock(
            type: type,
            openingTag: match.group(0)!,
            header: tail.isEmpty ? '' : tail.substring(1),
            startOffset: match.start,
            openEndOffset: match.end,
          ),
        );
        continue;
      }

      if (tail.isNotEmpty) {
        throw ScriptCstFormatException(
          'Closing structural tag $type cannot carry a header.',
          match.start,
        );
      }
      if (stack.isEmpty) {
        throw ScriptCstFormatException(
          'Closing tag [/$type] has no matching opening tag.',
          match.start,
        );
      }

      final _OpenStructuralBlock open = stack.removeLast();
      if (open.type != type) {
        throw ScriptCstFormatException(
          'Expected [/${open.type}] before [/$type].',
          match.start,
        );
      }

      final ScriptCstBlock block = ScriptCstBlock._(
        source: source,
        type: open.type,
        header: open.header,
        openingTag: open.openingTag,
        closingTag: match.group(0)!,
        startOffset: open.startOffset,
        openEndOffset: open.openEndOffset,
        closeStartOffset: match.start,
        endOffset: match.end,
        children: List<ScriptCstBlock>.unmodifiable(open.children),
      );

      for (final ScriptCstBlock child in open.children) {
        child._parent = block;
      }

      if (stack.isEmpty) {
        roots.add(block);
      } else {
        stack.last.children.add(block);
      }
    }

    if (stack.isNotEmpty) {
      final _OpenStructuralBlock open = stack.last;
      throw ScriptCstFormatException(
        'Opening tag [${open.type}] is not closed.',
        open.startOffset,
      );
    }

    final ScriptCstDocument document = ScriptCstDocument._(
      source,
      List<ScriptCstBlock>.unmodifiable(roots),
    );
    document._validateEditOwnership();
    return document;
  }

  Iterable<ScriptCstBlock> blocksOfType(String type) sync* {
    for (final ScriptCstBlock root in roots) {
      for (final ScriptCstBlock block in root.walk()) {
        if (block.type == type) yield block;
      }
    }
  }

  /// Replaces exactly one complete structural block.
  ///
  /// No enclosing source is regenerated. The caller may reparse the returned
  /// string to obtain fresh offsets after a length-changing edit.
  String replaceBlock(ScriptCstBlock block, String replacement) {
    _checkOwned(block);
    return source.replaceRange(block.startOffset, block.endOffset, replacement);
  }

  /// Replaces only the opening tag of one block.
  ///
  /// This is the operation M7 field edits will use when clip geometry lives in
  /// the CLIP header. The replacement must remain the same structural type.
  String replaceOpeningTag(ScriptCstBlock block, String replacement) {
    _checkOwned(block);
    final RegExpMatch? match = _structuralTag.firstMatch(replacement);
    if (match == null || match.start != 0 || match.end != replacement.length) {
      throw ArgumentError.value(
        replacement,
        'replacement',
        'Must be one complete structural opening tag.',
      );
    }
    if (match.namedGroup('close') != null) {
      throw ArgumentError.value(
        replacement,
        'replacement',
        'Must be an opening tag, not a closing tag.',
      );
    }
    if (match.namedGroup('type') != block.type) {
      throw ArgumentError.value(
        replacement,
        'replacement',
        'Opening tag type must remain ${block.type}.',
      );
    }

    return source.replaceRange(
      block.startOffset,
      block.openEndOffset,
      replacement,
    );
  }

  /// Replaces only the source between a block's opening and closing tags.
  String replaceInnerSource(ScriptCstBlock block, String replacement) {
    _checkOwned(block);
    return source.replaceRange(
      block.openEndOffset,
      block.closeStartOffset,
      replacement,
    );
  }

  void _checkOwned(ScriptCstBlock block) {
    final bool present = roots.any(
      (ScriptCstBlock root) =>
          root.walk().any((ScriptCstBlock candidate) => identical(candidate, block)),
    );
    if (!present) {
      throw ArgumentError('The structural block does not belong to this parse.');
    }
  }

  void _validateEditOwnership() {
    for (final ScriptCstBlock root in roots) {
      if (root.type != 'EDIT') {
        throw ScriptCstFormatException(
          '${root.type} must be nested inside EDIT.',
          root.startOffset,
        );
      }

      for (final ScriptCstBlock block in root.walk()) {
        final ScriptCstBlock? parent = block.parent;
        switch (block.type) {
          case 'EDIT':
            if (parent != null) {
              throw ScriptCstFormatException(
                'EDIT cannot be nested inside another structural block.',
                block.startOffset,
              );
            }
            break;
          case 'TRACK':
            if (parent?.type != 'EDIT') {
              throw ScriptCstFormatException(
                'TRACK must be a direct child of EDIT.',
                block.startOffset,
              );
            }
            break;
          case 'CLIP':
            if (parent?.type != 'TRACK') {
              throw ScriptCstFormatException(
                'CLIP must be a direct child of TRACK.',
                block.startOffset,
              );
            }
            break;
        }
      }
    }
  }
}

class ScriptCstBlock {
  final String _source;
  final String type;

  /// Header text after the first colon and before `]`, preserved verbatim.
  /// Empty means the opening tag had no header segment.
  final String header;

  final String openingTag;
  final String closingTag;

  final int startOffset;
  final int openEndOffset;
  final int closeStartOffset;
  final int endOffset;

  final List<ScriptCstBlock> children;
  ScriptCstBlock? _parent;

  ScriptCstBlock._({
    required String source,
    required this.type,
    required this.header,
    required this.openingTag,
    required this.closingTag,
    required this.startOffset,
    required this.openEndOffset,
    required this.closeStartOffset,
    required this.endOffset,
    required this.children,
  }) : _source = source;

  ScriptCstBlock? get parent => _parent;

  String get rawSource => _source.substring(startOffset, endOffset);

  String get innerSource => _source.substring(openEndOffset, closeStartOffset);

  Iterable<ScriptCstBlock> walk() sync* {
    yield this;
    for (final ScriptCstBlock child in children) {
      yield* child.walk();
    }
  }

  List<String> get ownershipPath {
    final List<String> path = <String>[];
    ScriptCstBlock? cursor = this;
    while (cursor != null) {
      path.add(cursor.type);
      cursor = cursor.parent;
    }
    return path.reversed.toList(growable: false);
  }
}

class _OpenStructuralBlock {
  final String type;
  final String header;
  final String openingTag;
  final int startOffset;
  final int openEndOffset;
  final List<ScriptCstBlock> children = <ScriptCstBlock>[];

  _OpenStructuralBlock({
    required this.type,
    required this.header,
    required this.openingTag,
    required this.startOffset,
    required this.openEndOffset,
  });
}
