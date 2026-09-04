// ./lib/script_cst.dart
//
// Nested concrete-syntax ownership for structural script blocks.
//
// The existing ScriptNode parser is intentionally flat: it is excellent for
// lossless editing of the current tag language, but block bodies such as CARD
// and TIMELINE are opaque strings. EDIT / TRACK / CLIP and MOSAIC / PANE / CLIP
// need a different guarantee. Their nesting is structural, and editing an
// inner block must not give the writer permission to regenerate any enclosing
// bytes.
//
// This file supplies that missing layer without changing runtime parsing. It
// recognizes only structural ownership tags and records exact source spans.
// Everything else remains uninterpreted source. Mutations are source-range
// replacements, so bytes outside the selected span are preserved verbatim.
//
// Structural scanning also respects lexical ownership already established by
// the terminal language. CARD, DOSSIER, TIMELINE, DEF_MENU, and comments may
// contain bracketed text as data. A token that merely looks like EDIT, TRACK,
// MOSAIC, PANE, or CLIP inside one of those opaque spans is not structural
// source and must never enter this tree.

import 'parser.dart' show tagRegex;

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
    'MOSAIC',
    'PANE',
    'CLIP',
  };

  static final RegExp _structuralTag = RegExp(
    r'\[(?<close>/)?(?<type>EDIT|TRACK|MOSAIC|PANE|CLIP)(?<tail>:[^\]\r\n]*)?\]',
  );

  // Keep these two expressions aligned with the existing terminal parser.
  // CARD, DOSSIER, and TIMELINE come from tagRegex itself below, so their
  // exact grammar remains single-source rather than being copied here.
  static final RegExp _definitionBlock = RegExp(
    r'\[DEF_MENU:[a-zA-Z0-9_-]+\].*?\[/DEF_MENU\]',
    dotAll: true,
  );
  static final RegExp _comment = RegExp(
    r'\[#.*?\]\n?',
    dotAll: true,
  );

  final String source;
  final List<ScriptCstBlock> roots;

  ScriptCstDocument._(this.source, this.roots);

  factory ScriptCstDocument.parse(String source) {
    final List<_SourceRange> opaqueRanges = _opaqueSourceRanges(source);
    int opaqueIndex = 0;

    final List<_OpenStructuralBlock> stack = <_OpenStructuralBlock>[];
    final List<ScriptCstBlock> roots = <ScriptCstBlock>[];

    for (final RegExpMatch match in _structuralTag.allMatches(source)) {
      while (opaqueIndex < opaqueRanges.length &&
          opaqueRanges[opaqueIndex].endOffset <= match.start) {
        opaqueIndex++;
      }
      if (opaqueIndex < opaqueRanges.length &&
          opaqueRanges[opaqueIndex].contains(match.start)) {
        continue;
      }

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
    document._validateStructuralOwnership();
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
  /// This is the operation field edits use when clip geometry lives in the
  /// CLIP header. The replacement must remain the same structural type.
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

  /// Inserts source immediately before one owned block's closing tag.
  ///
  /// Container authoring uses this instead of applying a raw offset directly.
  /// The insertion is therefore anchored to the exact CST owner that granted
  /// permission to mutate that location.
  String insertBeforeClosingTag(ScriptCstBlock block, String insertion) {
    _checkOwned(block);
    return source.replaceRange(
      block.closeStartOffset,
      block.closeStartOffset,
      insertion,
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

  void _validateStructuralOwnership() {
    for (final ScriptCstBlock root in roots) {
      if (root.type != 'EDIT' && root.type != 'MOSAIC') {
        throw ScriptCstFormatException(
          '${root.type} must be nested inside EDIT or MOSAIC.',
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
          case 'MOSAIC':
            if (parent != null) {
              throw ScriptCstFormatException(
                'MOSAIC cannot be nested inside another structural block.',
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
          case 'PANE':
            if (parent?.type != 'MOSAIC') {
              throw ScriptCstFormatException(
                'PANE must be a direct child of MOSAIC.',
                block.startOffset,
              );
            }
            break;
          case 'CLIP':
            if (parent?.type != 'TRACK' && parent?.type != 'PANE') {
              throw ScriptCstFormatException(
                'CLIP must be a direct child of TRACK or PANE.',
                block.startOffset,
              );
            }
            break;
        }
      }
    }
  }

  static List<_SourceRange> _opaqueSourceRanges(String source) {
    final List<_SourceRange> ranges = <_SourceRange>[];

    // The runtime tag grammar already owns these complete blocks, including
    // their bodies. Reusing its matches avoids a second copy of their header
    // grammar here while preserving the exact source offsets.
    for (final RegExpMatch match in tagRegex.allMatches(source)) {
      final String raw = match.group(0) ?? '';
      if (raw.startsWith('[CARD:') ||
          raw.startsWith('[DOSSIER:') ||
          raw.startsWith('[TIMELINE')) {
        ranges.add(_SourceRange(match.start, match.end));
      }
    }

    // Macro definitions are intentionally outside tagRegex but are also one
    // opaque construct in ScriptNode parsing and macro preprocessing.
    for (final RegExpMatch match in _definitionBlock.allMatches(source)) {
      ranges.add(_SourceRange(match.start, match.end));
    }

    // Match the terminal preprocessor's comment ownership exactly. This also
    // protects a structural-looking token before the comment's first closing
    // bracket from being interpreted by the CST.
    for (final RegExpMatch match in _comment.allMatches(source)) {
      ranges.add(_SourceRange(match.start, match.end));
    }

    if (ranges.length < 2) {
      return List<_SourceRange>.unmodifiable(ranges);
    }

    ranges.sort((_SourceRange a, _SourceRange b) {
      final int byStart = a.startOffset.compareTo(b.startOffset);
      if (byStart != 0) return byStart;
      return a.endOffset.compareTo(b.endOffset);
    });

    final List<_SourceRange> merged = <_SourceRange>[];
    for (final _SourceRange range in ranges) {
      if (merged.isEmpty || range.startOffset > merged.last.endOffset) {
        merged.add(range);
        continue;
      }
      if (range.endOffset > merged.last.endOffset) {
        merged[merged.length - 1] = _SourceRange(
          merged.last.startOffset,
          range.endOffset,
        );
      }
    }
    return List<_SourceRange>.unmodifiable(merged);
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

class _SourceRange {
  final int startOffset;
  final int endOffset;

  const _SourceRange(this.startOffset, this.endOffset);

  bool contains(int offset) => offset >= startOffset && offset < endOffset;
}
