// ./lib/marker_language.dart
//
// Authored timeline marker language for TEXT, EDIT, and CLIP scopes.
//
// MARK is deliberately not a terminal presentation and owns no time. Its
// enclosing authored structure determines the coordinate system:
//
//   TEXT:  [MARK:"Interview starts"]
//          Position in the document is the authored fact. Program frame is
//          derived from surrounding sequence content.
//
//   EDIT:  [MARK:420:"Act two"]
//          Frame is EDIT-sequence relative.
//
//   CLIP:  [MARK:90:"Important quote"]
//          Frame is CLIP source relative and therefore follows the footage
//          through move, trim, slip, and exact rational speed changes.
//
// MARK labels are always quoted. Colons and closing brackets are ordinary
// label characters; quote and backslash use \" and \\ escapes. Keeping this
// parser small and explicit avoids widening the terminal tag regex for syntax
// the terminal must never execute.

import 'parser.dart' show tagRegex;
import 'script_cst.dart';

class MarkerFormatException implements Exception {
  final String message;
  final int offset;

  const MarkerFormatException(this.message, this.offset);

  @override
  String toString() => 'MarkerFormatException at $offset: $message';
}

enum MarkerScope {
  text,
  edit,
  clip,
}

/// Cross-parse identity for one authored MARK.
///
/// No generated id is used. Parsing the same document twice produces the same
/// line/offset/order address, just as RibbonBlock.nodeIndex deliberately uses
/// document position instead of ScriptNode.id.
class MarkerAddress {
  final int documentOrder;
  final int lineIndex;
  final int startOffset;

  const MarkerAddress({
    required this.documentOrder,
    required this.lineIndex,
    required this.startOffset,
  });

  @override
  bool operator ==(Object other) =>
      other is MarkerAddress &&
      other.documentOrder == documentOrder &&
      other.lineIndex == lineIndex &&
      other.startOffset == startOffset;

  @override
  int get hashCode => Object.hash(documentOrder, lineIndex, startOffset);

  @override
  String toString() => 'L$lineIndex@$startOffset#$documentOrder';
}

class MarkerDefinition {
  final MarkerScope scope;
  final MarkerAddress address;
  final String label;

  /// Null only for positional TEXT markers.
  final int? localFrame;

  /// Exact source span of the marker tag.
  final int startOffset;
  final int endOffset;
  final String rawSource;

  /// Structural ownership, when present.
  ///
  /// [rootType] is EDIT or MOSAIC. [rootId] is that reusable source id.
  /// [containerId] is TRACK or PANE id for CLIP markers. [clipId] is the CLIP
  /// id. EDIT-sequence markers have only rootType/rootId.
  final String? rootType;
  final String? rootId;
  final String? containerId;
  final String? clipId;

  const MarkerDefinition({
    required this.scope,
    required this.address,
    required this.label,
    required this.localFrame,
    required this.startOffset,
    required this.endOffset,
    required this.rawSource,
    this.rootType,
    this.rootId,
    this.containerId,
    this.clipId,
  });

  bool get isText => scope == MarkerScope.text;
  bool get isEdit => scope == MarkerScope.edit;
  bool get isClip => scope == MarkerScope.clip;

  @override
  String toString() =>
      'MarkerDefinition(scope: $scope, frame: $localFrame, label: $label, '
      'address: $address, root: $rootType.$rootId, container: $containerId, '
      'clip: $clipId)';
}

class _MarkerToken {
  final int startOffset;
  final int endOffset;
  final int? frame;
  final String label;
  final String rawSource;

  const _MarkerToken({
    required this.startOffset,
    required this.endOffset,
    required this.frame,
    required this.label,
    required this.rawSource,
  });
}

class _SourceRange {
  final int start;
  final int end;

  const _SourceRange(this.start, this.end);

  bool contains(int offset) => offset >= start && offset < end;
}

final RegExp _comment = RegExp(r'\[#.*?\]\n?', dotAll: true);
final RegExp _definitionBlock = RegExp(
  r'\[DEF_MENU:[a-zA-Z0-9_-]+\].*?\[/DEF_MENU\]',
  dotAll: true,
);
final RegExp _cueBlock = RegExp(
  r'\[CUE:\d+\][\s\S]*?\[/CUE\]',
);

/// Parses every authored MARK in [source].
///
/// Presentation bodies, comments, menu definitions, and CUE bodies are opaque:
/// bracket-shaped prose inside them is data and cannot become a marker.
List<MarkerDefinition> parseMarkerDefinitions(String source) {
  final List<_SourceRange> opaque = _opaqueRanges(source);

  ScriptCstDocument? cst;
  try {
    cst = ScriptCstDocument.parse(source);
  } on ScriptCstFormatException {
    // TEXT remains a repair surface. Top-level markers can still be useful in a
    // document whose structural source is temporarily malformed. In that case
    // a token that appears lexically inside an EDIT/MOSAIC-looking span is not
    // classified here; callers working on malformed structural source already
    // cannot construct an EditDocumentModel either.
    cst = null;
  }

  final List<MarkerDefinition> out = <MarkerDefinition>[];
  int cursor = 0;
  int order = 0;

  while (cursor < source.length) {
    final int start = source.indexOf('[MARK:', cursor);
    if (start < 0) break;

    if (_insideAny(start, opaque)) {
      cursor = start + '[MARK:'.length;
      continue;
    }

    final _MarkerToken token = _parseMarkerToken(source, start);
    final ScriptCstBlock? owner = cst == null ? null : _deepestOwner(cst, start);

    late final MarkerScope scope;
    String? rootType;
    String? rootId;
    String? containerId;
    String? clipId;

    if (owner == null) {
      scope = MarkerScope.text;
      if (token.frame != null) {
        throw MarkerFormatException(
          'TEXT MARK is positional and cannot carry a frame number.',
          start,
        );
      }
    } else if (owner.type == 'EDIT') {
      scope = MarkerScope.edit;
      if (token.frame == null) {
        throw MarkerFormatException(
          'MARK directly inside EDIT requires an EDIT-sequence frame.',
          start,
        );
      }
      rootType = 'EDIT';
      rootId = owner.header.trim();
    } else if (owner.type == 'CLIP') {
      scope = MarkerScope.clip;
      if (token.frame == null) {
        throw MarkerFormatException(
          'MARK inside CLIP requires a source-relative frame.',
          start,
        );
      }

      final ScriptCstBlock? container = owner.parent;
      final ScriptCstBlock? root = container?.parent;
      if (container == null || root == null) {
        throw MarkerFormatException(
          'CLIP MARK has no structural owner.',
          start,
        );
      }
      rootType = root.type;
      rootId = root.header.trim();
      containerId = container.header.trim();
      clipId = _clipIdFromHeader(owner.header);
    } else {
      throw MarkerFormatException(
        'MARK is valid only in TEXT, directly inside EDIT, or inside CLIP. '
        'Found it inside ${owner.type}.',
        start,
      );
    }

    final int line = _lineForOffset(source, start);
    out.add(
      MarkerDefinition(
        scope: scope,
        address: MarkerAddress(
          documentOrder: order,
          lineIndex: line,
          startOffset: start,
        ),
        label: token.label,
        localFrame: token.frame,
        startOffset: start,
        endOffset: token.endOffset,
        rawSource: token.rawSource,
        rootType: rootType,
        rootId: rootId,
        containerId: containerId,
        clipId: clipId,
      ),
    );

    order++;
    cursor = token.endOffset;
  }

  return List<MarkerDefinition>.unmodifiable(out);
}

/// Serializes one MARK using the stable quoted-label grammar.
String formatMarkerTag({
  int? frame,
  String label = '',
}) {
  if (frame != null && frame < 0) {
    throw ArgumentError.value(frame, 'frame', 'MARK frame must be non-negative.');
  }
  if (label.contains('\n') || label.contains('\r')) {
    throw ArgumentError.value(label, 'label', 'MARK label cannot contain a newline.');
  }

  final String escaped = label
      .replaceAll('\\', '\\\\')
      .replaceAll('"', '\\"');
  return frame == null
      ? '[MARK:"$escaped"]'
      : '[MARK:$frame:"$escaped"]';
}

/// Removes authored MARK tokens from the engine projection.
///
/// [preserveLineCoordinates] is true for the editor's [LINE:n] simulation.
/// The tag bytes disappear but their newlines remain, so authored line numbers
/// stay aligned. Preview/Bake do not need raw-line addressing; a marker-only
/// line is therefore removed including its line break so it cannot create an
/// executable blank line or move the terminal cursor.
String stripMarkersForEngine(
  String source, {
  required bool preserveLineCoordinates,
}) {
  final List<MarkerDefinition> definitions = parseMarkerDefinitions(source);
  if (definitions.isEmpty) return source;

  String out = source;
  for (final MarkerDefinition marker in definitions.reversed) {
    int start = marker.startOffset;
    int end = marker.endOffset;

    if (!preserveLineCoordinates && _markerOwnsWholeLine(source, marker)) {
      start = _lineStartAt(source, marker.startOffset);
      end = _lineEndIncludingBreak(source, marker.endOffset);
    }

    out = out.replaceRange(start, end, '');
  }
  return out;
}

_MarkerToken _parseMarkerToken(String source, int start) {
  const String prefix = '[MARK:';
  int cursor = start + prefix.length;
  if (cursor >= source.length) {
    throw MarkerFormatException('MARK is incomplete.', start);
  }

  int? frame;
  final int frameStart = cursor;
  while (cursor < source.length) {
    final int c = source.codeUnitAt(cursor);
    if (c < 0x30 || c > 0x39) break;
    cursor++;
  }

  if (cursor > frameStart) {
    frame = int.parse(source.substring(frameStart, cursor));
    if (cursor >= source.length || source.codeUnitAt(cursor) != 0x3A) {
      throw MarkerFormatException(
        'Numbered MARK requires a quoted label after the frame.',
        cursor,
      );
    }
    cursor++;
  }

  if (cursor >= source.length || source.codeUnitAt(cursor) != 0x22) {
    throw MarkerFormatException(
      'MARK label must be quoted, for example [MARK:"Interview starts"].',
      cursor,
    );
  }
  cursor++;

  final StringBuffer label = StringBuffer();
  bool closedQuote = false;
  while (cursor < source.length) {
    final int c = source.codeUnitAt(cursor);
    if (c == 0x0A || c == 0x0D) {
      throw MarkerFormatException('MARK label cannot contain a newline.', cursor);
    }

    if (c == 0x5C) {
      if (cursor + 1 >= source.length) {
        throw MarkerFormatException('MARK label ends with an escape.', cursor);
      }
      final int next = source.codeUnitAt(cursor + 1);
      if (next == 0x22 || next == 0x5C) {
        label.writeCharCode(next);
        cursor += 2;
        continue;
      }
      throw MarkerFormatException(
        'MARK supports only \\" and \\\\ escapes.',
        cursor,
      );
    }

    if (c == 0x22) {
      cursor++;
      closedQuote = true;
      break;
    }

    label.writeCharCode(c);
    cursor++;
  }

  if (!closedQuote) {
    throw MarkerFormatException('MARK label is missing its closing quote.', start);
  }
  if (cursor >= source.length || source.codeUnitAt(cursor) != 0x5D) {
    throw MarkerFormatException(
      'MARK must end immediately after the closing label quote.',
      cursor,
    );
  }
  cursor++;

  return _MarkerToken(
    startOffset: start,
    endOffset: cursor,
    frame: frame,
    label: label.toString(),
    rawSource: source.substring(start, cursor),
  );
}

List<_SourceRange> _opaqueRanges(String source) {
  final List<_SourceRange> ranges = <_SourceRange>[];

  for (final RegExpMatch match in tagRegex.allMatches(source)) {
    final String raw = match.group(0) ?? '';
    if (raw.startsWith('[CARD:') ||
        raw.startsWith('[DOSSIER:') ||
        raw.startsWith('[TIMELINE')) {
      ranges.add(_SourceRange(match.start, match.end));
    }
  }
  for (final RegExpMatch match in _comment.allMatches(source)) {
    ranges.add(_SourceRange(match.start, match.end));
  }
  for (final RegExpMatch match in _definitionBlock.allMatches(source)) {
    ranges.add(_SourceRange(match.start, match.end));
  }
  for (final RegExpMatch match in _cueBlock.allMatches(source)) {
    ranges.add(_SourceRange(match.start, match.end));
  }

  if (ranges.length < 2) return ranges;
  ranges.sort((_SourceRange a, _SourceRange b) {
    final int byStart = a.start.compareTo(b.start);
    return byStart != 0 ? byStart : a.end.compareTo(b.end);
  });

  final List<_SourceRange> merged = <_SourceRange>[];
  for (final _SourceRange range in ranges) {
    if (merged.isEmpty || range.start > merged.last.end) {
      merged.add(range);
    } else if (range.end > merged.last.end) {
      merged[merged.length - 1] = _SourceRange(merged.last.start, range.end);
    }
  }
  return merged;
}

bool _insideAny(int offset, List<_SourceRange> ranges) {
  for (final _SourceRange range in ranges) {
    if (range.contains(offset)) return true;
    if (range.start > offset) break;
  }
  return false;
}

ScriptCstBlock? _deepestOwner(ScriptCstDocument cst, int offset) {
  ScriptCstBlock? best;
  for (final ScriptCstBlock root in cst.roots) {
    for (final ScriptCstBlock block in root.walk()) {
      if (offset < block.openEndOffset || offset >= block.closeStartOffset) {
        continue;
      }
      if (best == null ||
          (block.endOffset - block.startOffset) <
              (best.endOffset - best.startOffset)) {
        best = block;
      }
    }
  }
  return best;
}

String _clipIdFromHeader(String header) {
  final int colon = header.indexOf(':');
  return (colon < 0 ? header : header.substring(0, colon)).trim();
}

int _lineForOffset(String source, int offset) {
  int line = 0;
  for (int i = 0; i < offset && i < source.length; i++) {
    if (source.codeUnitAt(i) == 0x0A) line++;
  }
  return line;
}

int _lineStartAt(String source, int offset) {
  final int newline = source.lastIndexOf('\n', offset > 0 ? offset - 1 : 0);
  return newline < 0 ? 0 : newline + 1;
}

int _lineEndIncludingBreak(String source, int offset) {
  final int newline = source.indexOf('\n', offset);
  return newline < 0 ? source.length : newline + 1;
}

bool _markerOwnsWholeLine(String source, MarkerDefinition marker) {
  final int lineStart = _lineStartAt(source, marker.startOffset);
  final int lineEnd = source.indexOf('\n', marker.endOffset);
  final int contentEnd = lineEnd < 0 ? source.length : lineEnd;
  return source.substring(lineStart, marker.startOffset).trim().isEmpty &&
      source.substring(marker.endOffset, contentEnd).trim().isEmpty;
}
