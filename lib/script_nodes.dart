// ./lib/script_nodes.dart

// Pure script-node model, lossless parser, and serializer.
//
// This file intentionally contains no widget state. Both the node workspace
// and the script ribbon can depend on it without depending on each other.

import 'parser.dart';
import 'script_cst.dart';

// =====================================================================
// ROUND-TRIP CONTRACT
//
// The node list covers 100% of the document buffer with no gaps and no
// overlaps. Every ordinary node holds the verbatim source slice it was parsed
// from in [ScriptNode.rawText] and emits that slice unchanged until the user
// actually edits it (dirty == false means "emit rawText").
//
// Because coverage is total and text nodes carry their own newlines, the
// composer joins with the EMPTY string, never '\n'. Consequence: opening
// node mode and touching nothing produces a byte-identical document, and
// editing one ordinary node rewrites exactly that node's span. Frame counts
// and typed layout cannot drift out from under the writer.
//
// Whitespace-only slices between tags become hidden SPACER nodes. They
// are never shown in the graph and never regenerated, so blank lines and
// indentation survive verbatim.
//
// EDIT and MOSAIC roots are different. ScriptCstDocument owns their nested
// bytes, but M16 makes the roots visible in NODES as protected structural
// cards. Each card still serializes the exact CST-owned root source rather
// than allowing the generic node form to reinterpret TRACK / PANE / CLIP.
// The visible card is therefore a view of structural source, not a second
// structural database.
//
// STRUCT placements are different again: they are main-sequence references to
// those protected roots. They are ordinary reorderable nodes because moving a
// placement changes sequence order, not the EDIT/MOSAIC source definition.
// =====================================================================

/// Node type for a whitespace-only run between two tags. Hidden from the
/// graph, always emitted verbatim, never editable.
const String kSpacer = 'SPACER';

/// Legacy structural marker retained for old callers/tests. New parses expose
/// protected roots using their real visible type, EDIT or MOSAIC, while
/// [ScriptNode.isStructural] is keyed by the protected-source metadata below.
const String kStructural = 'STRUCTURAL';

/// Node type for markup the tag grammar does not model: comments, menu
/// definitions, MACRO_CFG lines. Edited as raw text, round-trips exactly.
const String kRaw = 'RAW';

const String _kStructuralSource = '__structural_source';
const String _kStructuralOwner = '__structural_owner';

int _nodeSeq = 0;

/// Bracketed constructs that are real markup but live outside [tagRegex].
/// They are stripped or expanded by the preprocessor rather than typed, so
/// presenting them as "typing text" would be a lie.
/// Macro markup, which lives outside [tagRegex] because the preprocessor
/// expands it before the parser ever runs.
///
/// The patterns mirror the ones in ScriptParser.parseTemplateData exactly.
/// They have to: if the node editor and the template parser disagree about
/// what a menu looks like, the editor will happily write something the
/// dashboard cannot read back.
///
/// STRUCT is included in the same non-terminal pass even though it is not a
/// macro: script_pipeline projects it into main-sequence timing before the
/// TerminalEngine ever sees the document.
final RegExp _macroRegex = RegExp(
  r'\[DEF_MENU:(?<menuId>[a-zA-Z0-9_-]+)\](?<menuBody>.*?)\[/DEF_MENU\]'
  r'|\[CALL:(?<callId>[a-zA-Z0-9_-]+)\]'
  r'|\[MENU_STATE:(?<msMenu>[a-zA-Z0-9_-]+):(?<msInstance>[a-zA-Z0-9_-]+)\]'
  r'|\[MACRO_CFG:(?<cfgId>[a-zA-Z0-9_-]+):(?<cfgItem>[a-zA-Z0-9_-]+|NONE)'
  r':(?<cfgRgb>\d+,\d+,\d+):(?<cfgBlink>\d+)\]'
  r'|\[STRUCT:(?<structSource>(?:EDIT|MOSAIC)\.[a-zA-Z0-9_-]+)\]',
  dotAll: true,
);

final RegExp _nonGrammarMarkup =
    RegExp(r'^\[(#|/?DEF_MENU|/?ITEM|MACRO_CFG|CALL|MENU_STATE|STRUCT)');

final RegExp _structuralRootOpening =
    RegExp(r'\[(?:EDIT|MOSAIC)(?::[^\]\r\n]*)?\]');

// ---------------------------------------------------------------------
// Positional-optional tag emitter
// ---------------------------------------------------------------------

/// One optional, positional tag segment.
///
/// R3nder's grammar is positional: a segment can only be omitted if every
/// segment after it is also omitted. [_emitTag] enforces that by finding
/// the last segment that differs from its default, then back-filling every
/// earlier segment with its default value.
class _Opt {
  final String value;
  final String def;

  /// Emitted when this segment must appear (something later is set) but
  /// both value and default are empty. An empty segment would produce
  /// "::" which the grammar rejects, so any segment that can be followed
  /// by another declares a non-empty fallback.
  final String fallback;

  _Opt(this.value, this.def, {String? fallback}) : fallback = fallback ?? def;
}

/// Builds a tag from a required head segment plus positional optionals.
String _emitTag(
  String name, {
  String? head,
  List<_Opt> opts = const [],
  String? body,
  String? closer,
}) {
  final StringBuffer b = StringBuffer('[$name');
  if (head != null) b.write(':$head');

  int last = -1;
  for (int i = 0; i < opts.length; i++) {
    final String v = opts[i].value.trim();
    if (v.isNotEmpty && v != opts[i].def) last = i;
  }

  for (int i = 0; i <= last; i++) {
    String v = opts[i].value.trim();
    if (v.isEmpty) v = opts[i].def;
    if (v.isEmpty) v = opts[i].fallback;

    // A SEGMENT THAT CANNOT RESOLVE BREAKS THE TAG SILENTLY.
    //
    // Positional grammar means reaching segment N requires emitting every
    // segment before it. If one of those resolves to nothing we write a
    // bare "::", which tagRegex rejects, so the whole construct stops
    // matching and types onto the screen as literal text. The document
    // still round-trips, the node panel still looks right, and the damage
    // only shows up in the render.
    //
    // [APP] is seven segments deep now and `panes` sits at the end, so any
    // future tail makes this more likely, not less. An assert turns a
    // silent grammar break into a failure at the moment the offending
    // _Opt is written, which is the only moment anyone can act on it.
    assert(
      v.isNotEmpty,
      'Tag "$name" segment $i must emit a value: something after it is '
      'set, and positional grammar cannot skip it. Give that _Opt a '
      'non-empty def or fallback.',
    );

    b.write(':$v');
  }

  b.write(']');

  if (body != null && closer != null) {
    b.write(body);
    b.write('[/$closer]');
  }
  return b.toString();
}

// ---------------------------------------------------------------------
// Node data model
// ---------------------------------------------------------------------

class ScriptNode {
  final String id = 'n${_nodeSeq++}';

  String type;

  /// The verbatim source slice this ordinary node was parsed from. Structural
  /// cards use this as their compact graph summary; their canonical bytes live
  /// in [_kStructuralSource] and always win serialization.
  String rawText;

  /// TEXT nodes only: whitespace peeled off the front and back of the slice
  /// so the editable body reads cleanly in the form. Reassembled on emit,
  /// so blank lines around a paragraph survive exactly.
  String prefix = '';
  String suffix = '';

  Map<String, String> params = {};
  String body = '';

  /// False until the user edits this node. Gates verbatim emission for normal
  /// nodes. Protected structural cards ignore dirty and emit CST-owned source.
  bool dirty = false;

  /// Document line span, recomputed after every change. STRUCTURAL nodes use
  /// -1/-1 because their source lines exist in the document but own no
  /// TerminalEngine frames.
  int startLine = 0;
  int endLine = 0;

  /// Exact character span in the current emitted document. [startOffset] is
  /// inclusive and [endOffset] is exclusive, matching String.substring.
  /// These are recomputed metadata, never serialization state.
  int startOffset = 0;
  int endOffset = 0;

  ScriptNode({required this.type, required this.rawText});

  bool get isSpacer => type == kSpacer;

  /// True for either the old opaque marker or an M16 visible protected root.
  bool get isStructural =>
      type == kStructural || params.containsKey(_kStructuralSource);

  /// Structural roots are now visible in the node workspace. Their -1 runtime
  /// line ownership still keeps them off the script timing ribbon.
  bool get isVisible => !isSpacer;

  String param(String k, [String fallback = '']) => params[k] ?? fallback;

  void set(String k, String v) {
    // The generic node form is not an owner of nested structural syntax.
    if (isStructural) return;
    params[k] = v;
    dirty = true;
  }

  /// Rebuilds this node's markup. Untouched ordinary nodes short-circuit to
  /// their original slice. Structural cards always emit the exact root source
  /// captured from CST, even if generic node UI tries to mark them dirty.
  String toMarkup() {
    if (isStructural) {
      final String source = param(_kStructuralSource, rawText);
      final String owner = param(_kStructuralOwner, id);
      // Generic duplicate creates a new node id while copying params. It must
      // not clone a canonical root with the same structural id. Treat that
      // accidental duplicate as no source rather than manufacturing an invalid
      // second EDIT/MOSAIC root.
      if (owner != id && params.containsKey(_kStructuralSource)) return '';
      return source;
    }

    if (!dirty) return rawText;

    switch (type) {
      case kSpacer:
        return rawText;

      case 'TEXT':
        return '$prefix$body$suffix';

      // --- Core typing controls -----------------------------------
      case 'WIPE':
        return '[WIPE]';
      case 'PAUSE':
        return '[PAUSE:${param('frames', '30')}]';
      case 'SPEED':
        return '[SPEED:${param('speed', '1')}]';

      // --- Text formatting ----------------------------------------
      case 'SIZE':
        return '[SIZE:${param('size', 'DEFAULT')}]';
      case 'LEAD':
        return '[LEAD:${param('lead', 'DEFAULT')}]';
      case 'VPAD':
        return '[VPAD:${param('vpad', '40')}]';
      case 'ALIGN':
        return '[ALIGN:${param('align', 'LEFT')}]';

      // --- Color and effects --------------------------------------
      case 'COLOR':
        return '[${param('color', 'NORMAL')}]';
      case 'FLASH':
        return '[FLASH:${param('flash', 'OFF')}]';
      case 'SCRAMBLE':
        return '[SCRAMBLE:${param('scramble', 'on')}]';
      case 'INVERT':
        return '[INVERT:${param('invert', 'on')}]';
      case 'REDACT':
        return '[${param('redact', 'REDACT')}]';

      // --- Progress bar -------------------------------------------
      // Always emitted in full form. bFill and bEmpty accept the empty
      // string as a legal value, so the "omit when default" rule cannot be
      // applied to them without ambiguity.
      case 'BAR':
        return '[BAR:${param('width', '20')}:${param('frames', '60')}'
            ':${param('fill', '█')}:${param('empty', ' ')}'
            ':${param('brackets', '[]')}]';

      // --- Regions and selection ----------------------------------
      case 'REGION':
        return '[REGION:${param('id', 'region')}]';
      case 'REGION_END':
        return '[/REGION]';
      case 'SELECT':
        return _emitTag('SELECT',
            head: param('id', 'NONE'), opts: [_Opt(param('rgb'), '')]);

      // --- Config -------------------------------------------------
      case 'CONFIG':
        return '[CONFIG:${param('key', 'SIZE')}:${param('value')}]';

      // --- Desktop presentations ----------------------------------
      case 'GALLERY':
        return _emitTag('GALLERY', head: param('folder'), opts: [
          _Opt(param('hold'), '90'),
          _Opt(param('transition'), 'CUT'),
          _Opt(param('title'), '', fallback: 'Image Viewer'),
        ]);

      case 'BROWSER':
        return _emitTag('BROWSER', head: param('folder'), opts: [
          _Opt(param('hold'), '150'),
          // Fallback rather than default: the scroll mode sits behind the
          // title, so changing scroll on a title-less BROWSER node must
          // back-fill the runtime's own default rather than emit nothing
          // and break the tag into literal text.
          _Opt(param('title'), '', fallback: 'Web Browser'),
          _Opt(param('scroll'), 'SCROLL'),
        ]);

      case 'VIDEO':
        return _emitTag('VIDEO', head: param('folder'), opts: [
          _Opt(param('hold'), '60'),
          // FPS is positional after the title. If the user changes FPS on an
          // old title-less VIDEO node, back-fill the title with the runtime's
          // existing default so changing FPS does not also rename the window.
          _Opt(param('title'), '', fallback: 'Image Viewer'),
          _Opt(param('fps'), '30'),
        ]);

      case 'APP':
        return _emitTag('APP', head: param('folder'), opts: [
          _Opt(param('hold'), '90'),
          _Opt(param('title'), '', fallback: 'App'),
          _Opt(param('layout'), 'GRID'),
          // No default: an absent page plan means default chunking, and
          // emitting one would put a value on every APP tag in every
          // document the first time it was touched.
          // If authored pane structure follows it, back-fill with the
          // existing implicit default of three panes per page so positional
          // grammar stays legal without changing the shot.
          _Opt(param('pages'), '', fallback: '3'),
          // Empty preserves the legacy one-image-per-pane behavior.
          _Opt(param('panes'), ''),
        ]);

      case 'CARD':
        return _emitTag('CARD',
            head: param('image'),
            opts: [
              _Opt(param('hold'), '240'),
              _Opt(param('rgb'), '30,30,38'),
              _Opt(param('heading'), '', fallback: 'CARD'),
            ],
            body: body,
            closer: 'CARD');

      case 'DOSSIER':
        final bool sideOnly = param('centerMode', 'GRID') == 'SIDE_ONLY';
        return _emitTag('DOSSIER',
            head: '${param('folder')}:${param('image')}',
            opts: [
              _Opt(param('hold1'), '120'),
              _Opt(sideOnly ? '0' : param('hold2'), sideOnly ? '0' : '120'),
              _Opt(param('cardLead'), '0'),
              _Opt(param('centerMode'), 'GRID'),
              _Opt(param('rgb'), '30,30,38'),
              _Opt(param('heading'), '', fallback: 'DOSSIER'),
            ],
            body: body,
            closer: 'DOSSIER');

      case 'TIMELINE':
        return _emitTag('TIMELINE',
            opts: [
              _Opt(param('hold'), '240'),
              _Opt(param('rgb'), '30,30,38'),
              _Opt(param('heading'), '', fallback: 'TIMELINE'),
              // NONE, not empty. tlStage is [a-zA-Z0-9_\-/]+ in the
              // grammar, so it cannot match nothing: emitting an empty
              // segment to reach thumbW or gap writes "::" and the whole
              // TIMELINE stops matching, typing onto the screen as literal
              // text. The engine treats an unresolvable stage folder as
              // absent, which is what an author leaving it blank meant.
              _Opt(param('stage'), '', fallback: 'NONE'),
              _Opt(param('thumbW'), '150'),
              _Opt(param('gap'), '40'),
              _Opt(param('focus'), ''),
            ],
            body: body,
            closer: 'TIMELINE');

      // --- In-terminal stencils -----------------------------------
      case 'SVG':
        return _emitTag('SVG', head: param('file'), opts: [
          _Opt(param('hold'), '60'),
          _Opt(param('rgb'), ''),
        ]);

      case 'SVGFLASH':
        return _emitTag('SVGFLASH', head: param('folder'), opts: [
          _Opt(param('framesPer'), '4'),
          _Opt(param('cycles'), '3'),
          _Opt(param('rgb'), ''),
        ]);

      case 'PHOTO':
        return _emitTag('PHOTO', head: param('file'), opts: [
          _Opt(param('hold'), '120'),
          _Opt(param('channel'), 'R'),
          // Same trap as TIMELINE stage: photoRgb is \d+,\d+,\d+ and
          // cannot be empty, so reaching `release` past an unset tint used
          // to emit "::" and break the tag. 0,0,0 is not a neutral colour,
          // so the fallback is the engine's own default pen tint, which is
          // what an author who never set one is already seeing.
          _Opt(param('rgb'), '', fallback: '0,255,0'),
          _Opt(param('release'), ''),
        ]);

      case 'IMG':
        return _emitTag('IMG', head: param('file'), opts: [
          _Opt(param('repeat'), '1'),
          _Opt(param('channel'), 'R'),
          _Opt(param('framesPer'), '2'),
          _Opt(param('release'), '100'),
        ]);

      case 'SPRITE':
        return _emitTag('SPRITE',
            head: param('file'), opts: [_Opt(param('hold'), '30')]);

      case 'SPRITE_OFF':
        return '[SPRITE_OFF:${param('file')}]';

      // --- Macro menus --------------------------------------------
      case 'DEF_MENU':
        return '[DEF_MENU:${param('id', 'menu')}]$body[/DEF_MENU]';

      case 'CALL':
        return '[CALL:${param('menu')}]';

      case 'MENU_STATE':
        return '[MENU_STATE:${param('menu')}:${param('instance')}]';

      case 'MACRO_CFG':
        return '[MACRO_CFG:${param('instance')}:${param('item', 'NONE')}'
            ':${param('rgb', '0,255,0')}:${param('blink', '0')}]';

      default:
        return rawText;
    }
  }
}

class _NodeParseHit {
  final int start;
  final int end;
  final int priority;
  final RegExpMatch? match;
  final bool macro;
  final ScriptCstBlock? structuralBlock;

  const _NodeParseHit._({
    required this.start,
    required this.end,
    required this.priority,
    required this.match,
    required this.macro,
    required this.structuralBlock,
  });

  bool get structural => structuralBlock != null;

  factory _NodeParseHit.structural(ScriptCstBlock block) => _NodeParseHit._(
        start: block.startOffset,
        end: block.endOffset,
        priority: 0,
        match: null,
        macro: false,
        structuralBlock: block,
      );

  factory _NodeParseHit.tag(RegExpMatch match) => _NodeParseHit._(
        start: match.start,
        end: match.end,
        priority: 1,
        match: match,
        macro: false,
        structuralBlock: null,
      );

  factory _NodeParseHit.macro(RegExpMatch match) => _NodeParseHit._(
        start: match.start,
        end: match.end,
        priority: 2,
        match: match,
        macro: true,
        structuralBlock: null,
      );
}

List<ScriptCstBlock> _structuralRootsForNodeParsing(String text) {
  if (!_structuralRootOpening.hasMatch(text)) {
    return const <ScriptCstBlock>[];
  }

  try {
    return ScriptCstDocument.parse(text).roots;
  } on ScriptCstFormatException {
    // Node mode is also a repair surface. A malformed structural block must
    // remain byte-for-byte editable as ordinary source instead of preventing
    // the document from opening. Runtime/model validation can still report the
    // structural error through its normal path.
    return const <ScriptCstBlock>[];
  }
}

String _structuralSummary(ScriptCstBlock root) {
  final String id = root.header.trim();

  if (root.type == 'EDIT') {
    final List<ScriptCstBlock> tracks = root.children
        .where((ScriptCstBlock child) => child.type == 'TRACK')
        .toList(growable: false);
    int cuts = 0;
    final List<String> trackIds = <String>[];
    final List<String> clipIds = <String>[];
    for (final ScriptCstBlock track in tracks) {
      trackIds.add(track.header.trim());
      for (final ScriptCstBlock child in track.children) {
        if (child.type != 'CLIP') continue;
        cuts++;
        final String header = child.header.trim();
        final int colon = header.indexOf(':');
        clipIds.add(colon < 0 ? header : header.substring(0, colon));
      }
    }
    final String tracksLabel = trackIds.isEmpty ? 'NO TRACKS' : trackIds.join(' + ');
    final String cutsLabel = cuts == 1 ? '1 CUT' : '$cuts CUTS';
    final String clips = clipIds.isEmpty ? '' : ' · ${clipIds.take(3).join(', ')}';
    return '$id · $tracksLabel · $cutsLabel$clips';
  }

  final List<ScriptCstBlock> panes = root.children
      .where((ScriptCstBlock child) => child.type == 'PANE')
      .toList(growable: false);
  int assigned = 0;
  final List<String> paneAssignments = <String>[];
  for (final ScriptCstBlock pane in panes) {
    final List<ScriptCstBlock> clips = pane.children
        .where((ScriptCstBlock child) => child.type == 'CLIP')
        .toList(growable: false);
    assigned += clips.length;
    final String paneId = pane.header.trim();
    if (clips.isEmpty) {
      paneAssignments.add('$paneId empty');
    } else {
      final String header = clips.first.header.trim();
      final int colon = header.indexOf(':');
      final String clipId = colon < 0 ? header : header.substring(0, colon);
      paneAssignments.add('$paneId ← $clipId');
    }
  }
  final String paneLabel = panes.length == 1 ? '1 PANE' : '${panes.length} PANES';
  final String assignmentLabel = assigned == 1 ? '1 ASSIGNED' : '$assigned ASSIGNED';
  final String detail = paneAssignments.isEmpty ? '' : ' · ${paneAssignments.join(' · ')}';
  return '$id · $paneLabel · $assignmentLabel$detail';
}

ScriptNode _nodeFromStructuralRoot(ScriptCstBlock root) {
  final ScriptNode node = ScriptNode(
    type: root.type,
    rawText: _structuralSummary(root),
  );
  node.params[_kStructuralSource] = root.rawSource;
  node.params[_kStructuralOwner] = node.id;
  node.params['id'] = root.header.trim();
  return node;
}

// =====================================================================
// SCRIPT PARSING
//
// Top level and pure: text in, nodes out, no widget state touched. Two
// consumers need it. The node workspace turns the decomposition into a
// form; the script ribbon in text mode turns it into blocks on a time
// axis. Making the second one mount a node workspace it never renders,
// or keeping a second copy of the parser, would both be worse than a
// function that never needed to be a method in the first place.
//
// Every character of the input lands in exactly one node, which is what
// makes the round trip lossless and what lets the ribbon assume its
// blocks tile the document without gaps.
//
// Structural roots participate in that tiling as one protected hit each. They
// dominate any tag or macro-looking text nested inside their owned source,
// which keeps the generic node grammar from taking ownership away from CST.
// =====================================================================

List<ScriptNode> parseScriptToNodes(String text) {
  final List<ScriptNode> result = [];
  int lastEnd = 0;

  void addTextSlice(String slice) {
    if (slice.isEmpty) return;

    final ScriptNode n = ScriptNode(type: 'TEXT', rawText: slice);

    if (slice.trim().isEmpty) {
      // Pure whitespace: a spacer. Hidden, never regenerated.
      n.type = kSpacer;
      result.add(n);
      return;
    }

    // Peel the surrounding whitespace off so the editable body reads
    // cleanly, and keep it for reassembly on emit.
    int s = 0;
    int e = slice.length;
    while (s < e && _isWs(slice.codeUnitAt(s))) {
      s++;
    }
    while (e > s && _isWs(slice.codeUnitAt(e - 1))) {
      e--;
    }
    n.prefix = slice.substring(0, s);
    n.body = slice.substring(s, e);
    n.suffix = slice.substring(e);

    // Bracketed constructs outside the tag grammar are markup, not typed
    // copy. Label them RAW so the form does not imply they will type.
    if (_nonGrammarMarkup.hasMatch(n.body)) n.type = kRaw;

    result.add(n);
  }

  final List<_NodeParseHit> hits = <_NodeParseHit>[
    for (final ScriptCstBlock root in _structuralRootsForNodeParsing(text))
      _NodeParseHit.structural(root),
    for (final RegExpMatch match in tagRegex.allMatches(text))
      _NodeParseHit.tag(match),
    for (final RegExpMatch match in _macroRegex.allMatches(text))
      _NodeParseHit.macro(match),
  ];

  hits.sort((_NodeParseHit a, _NodeParseHit b) {
    final int byStart = a.start.compareTo(b.start);
    if (byStart != 0) return byStart;
    final int byPriority = a.priority.compareTo(b.priority);
    if (byPriority != 0) return byPriority;
    return b.end.compareTo(a.end);
  });

  for (final _NodeParseHit hit in hits) {
    // A structural root wins ownership over any generic tag or macro match in
    // its body. Once its exact span has been emitted, nested hits fall here.
    if (hit.start < lastEnd) continue;

    if (hit.start > lastEnd) {
      addTextSlice(text.substring(lastEnd, hit.start));
    }

    if (hit.structural) {
      result.add(_nodeFromStructuralRoot(hit.structuralBlock!));
    } else {
      final RegExpMatch match = hit.match!;
      result.add(
        hit.macro ? _nodeFromMacroMatch(match) : _nodeFromMatch(match),
      );
    }
    lastEnd = hit.end;
  }

  if (lastEnd < text.length) {
    addTextSlice(text.substring(lastEnd));
  }

  return result;
}

/// Maps one macro construct onto a typed node.
ScriptNode _nodeFromMacroMatch(RegExpMatch m) {
  final ScriptNode n = ScriptNode(type: kRaw, rawText: m.group(0) ?? '');

  String? g(String name) {
    try {
      return m.namedGroup(name);
    } catch (_) {
      return null;
    }
  }

  if (g('menuId') != null) {
    n.type = 'DEF_MENU';
    n.params['id'] = g('menuId')!;
    n.body = g('menuBody') ?? '';
  } else if (g('callId') != null) {
    n.type = 'CALL';
    n.params['menu'] = g('callId')!;
  } else if (g('msMenu') != null) {
    n.type = 'MENU_STATE';
    n.params['menu'] = g('msMenu')!;
    n.params['instance'] = g('msInstance')!;
  } else if (g('cfgId') != null) {
    n.type = 'MACRO_CFG';
    n.params['instance'] = g('cfgId')!;
    n.params['item'] = g('cfgItem') ?? 'NONE';
    n.params['rgb'] = g('cfgRgb') ?? '0,255,0';
    n.params['blink'] = g('cfgBlink') ?? '0';
  } else if (g('structSource') != null) {
    n.type = 'STRUCT';
    n.params['source'] = g('structSource')!;
  }

  return n;
}

bool _isWs(int c) => c == 32 || c == 9 || c == 10 || c == 13;

/// Maps one tag match onto a typed node. Every named group in the tag
/// grammar is covered; anything unrecognized falls through to RAW, which
/// stays editable as markup and round-trips verbatim.
ScriptNode _nodeFromMatch(RegExpMatch m) {
  final ScriptNode n = ScriptNode(type: kRaw, rawText: m.group(0) ?? '');

  String? g(String name) {
    try {
      return m.namedGroup(name);
    } catch (_) {
      return null;
    }
  }

  void p(String k, String? v, [String fallback = '']) {
    n.params[k] = v ?? fallback;
  }

  // --- Core typing controls -------------------------------------
  if (g('wipe') != null) {
    n.type = 'WIPE';
  } else if (g('line') != null) {
    // Editor-injected playback marker. It should never reach a saved
    // document, but if one does, keep it hidden and verbatim.
    n.type = kSpacer;
  } else if (g('pause') != null) {
    n.type = 'PAUSE';
    p('frames', g('pause'), '30');
  } else if (g('speed') != null) {
    n.type = 'SPEED';
    p('speed', g('speed'), '1');
  }

  // --- Text formatting ------------------------------------------
  else if (g('size') != null) {
    n.type = 'SIZE';
    p('size', g('size'), 'DEFAULT');
  } else if (g('lead') != null) {
    n.type = 'LEAD';
    p('lead', g('lead'), 'DEFAULT');
  } else if (g('vpad') != null) {
    n.type = 'VPAD';
    p('vpad', g('vpad'), '40');
  } else if (g('align') != null) {
    n.type = 'ALIGN';
    p('align', g('align'), 'LEFT');
  }

  // --- Color and effects ----------------------------------------
  else if (g('color') != null) {
    n.type = 'COLOR';
    p('color', g('color'), 'NORMAL');
  } else if (g('flash') != null) {
    n.type = 'FLASH';
    p('flash', g('flash'), 'OFF');
  } else if (g('scramble') != null) {
    n.type = 'SCRAMBLE';
    p('scramble', g('scramble'), 'on');
  } else if (g('invert') != null) {
    n.type = 'INVERT';
    p('invert', g('invert'), 'on');
  } else if (g('redact') != null) {
    n.type = 'REDACT';
    p('redact', g('redact'), 'REDACT');
  }

  // --- Progress bar ---------------------------------------------
  else if (g('bW') != null) {
    n.type = 'BAR';
    p('width', g('bW'), '20');
    p('frames', g('bF'), '60');
    p('fill', g('bFill'), '█');
    p('empty', g('bEmpty'), ' ');
    p('brackets', g('bBrack'), '[]');
  }

  // --- Regions and selection ------------------------------------
  else if (g('regionId') != null) {
    n.type = 'REGION';
    p('id', g('regionId'), 'region');
  } else if (g('regionEnd') != null) {
    n.type = 'REGION_END';
  } else if (g('selId') != null) {
    n.type = 'SELECT';
    p('id', g('selId'), 'NONE');
    p('rgb', g('selBg'));
  }

  // --- Config ----------------------------------------------------
  else if (g('configKey') != null) {
    n.type = 'CONFIG';
    p('key', g('configKey'), 'SIZE');
    p('value', g('configVal'));
  }

  // --- Desktop presentations -------------------------------------
  else if (g('galFolder') != null) {
    n.type = 'GALLERY';
    p('folder', g('galFolder'));
    p('hold', g('galHold'), '90');
    p('transition', g('galTrans'), 'CUT');
    p('title', g('galTitle'));
  } else if (g('vidFolder') != null) {
    n.type = 'VIDEO';
    p('folder', g('vidFolder'));
    p('hold', g('vidHold'), '60');
    p('title', g('vidTitle'));
    p('fps', g('vidFps'), '30');
  } else if (g('browFolder') != null) {
    n.type = 'BROWSER';
    p('folder', g('browFolder'));
    p('hold', g('browHold'), '150');
    p('title', g('browTitle'));
    p('scroll', g('browScroll'), 'SCROLL');
  } else if (g('appFolder') != null) {
    n.type = 'APP';
    p('folder', g('appFolder'));
    p('hold', g('appHold'), '90');
    p('title', g('appTitle'));
    p('layout', g('appLayout'), 'GRID');
    p('pages', g('appPages'));
    p('panes', g('appPanes'));
  } else if (g('cardImg') != null) {
    n.type = 'CARD';
    p('image', g('cardImg'));
    p('hold', g('cardHold'), '240');
    p('rgb', g('cardRgb'), '30,30,38');
    p('heading', g('cardHead'));
    n.body = g('cardBody') ?? '';
  } else if (g('dosFolder') != null) {
    n.type = 'DOSSIER';
    p('folder', g('dosFolder'));
    p('image', g('dosImg'));
    p('hold1', g('dosHold1'), '120');
    p('hold2', g('dosHold2'), '120');
    p('cardLead', g('dosLead'), '0');
    p('centerMode', g('dosCenterMode'), 'GRID');
    p('rgb', g('dosRgb'), '30,30,38');
    p('heading', g('dosHead'));
    n.body = g('dosBody') ?? '';
  } else if (g('tlBody') != null) {
    n.type = 'TIMELINE';
    p('hold', g('tlHold'), '240');
    p('rgb', g('tlRgb'), '30,30,38');
    p('heading', g('tlHead'));
    p('stage', g('tlStage'));
    p('thumbW', g('tlThumbW'), '150');
    p('gap', g('tlGap'), '40');
    p('focus', g('tlFocus'));
    n.body = g('tlBody') ?? '';
  }

  // --- In-terminal stencils --------------------------------------
  else if (g('svgfFolder') != null) {
    n.type = 'SVGFLASH';
    p('folder', g('svgfFolder'));
    p('framesPer', g('svgfFrames'), '4');
    p('cycles', g('svgfCycles'), '3');
    p('rgb', g('svgfRgb'));
  } else if (g('svgFile') != null) {
    n.type = 'SVG';
    p('file', g('svgFile'));
    p('hold', g('svgHold'), '60');
    p('rgb', g('svgRgb'));
  } else if (g('photoFile') != null) {
    n.type = 'PHOTO';
    p('file', g('photoFile'));
    p('hold', g('photoHold'), '120');
    p('channel', g('photoChannel'), 'R');
    p('rgb', g('photoRgb'));
    p('release', g('photoRelease'));
  } else if (g('imgFile') != null) {
    n.type = 'IMG';
    p('file', g('imgFile'));
    p('repeat', g('imgRepeat'), '1');
    p('channel', g('imgChannel'), 'R');
    p('framesPer', g('imgFrames'), '2');
    p('release', g('imgRelease'), '100');
  } else if (g('spritePath') != null) {
    n.type = 'SPRITE';
    p('file', g('spritePath'));
    p('hold', g('spriteHold'), '30');
  } else if (g('spriteOff') != null) {
    n.type = 'SPRITE_OFF';
    p('file', g('spriteOff'));
  }

  return n;
}

/// Stamps each node with the document line range its markup occupies.
///
/// Must run after any edit and before anything asks a node where it lives.
/// The spans are what tie the three views together: the panel scrolls to a
/// line, the ribbon maps frames to lines to nodes, and click-to-jump goes
/// the other way.
///
/// STRUCTURAL nodes advance the document line counter but receive -1/-1.
/// Their authored lines are real source coordinates, yet compileScript removes
/// those roots before TerminalEngine runs, so no runtime frame may belong to
/// them. This also prevents a structural root later on the same physical line
/// from stealing frame attribution from a preceding PAUSE or presentation tag.
///
/// [endLine] is inclusive, and a node whose markup ends on a newline does
/// not claim the line after it. Getting that off by one would put every
/// later node's span one line out, which reads as the ribbon highlighting
/// the block next to the one you are actually on.
void assignNodeLineSpans(List<ScriptNode> nodes) {
  int line = 0;
  for (final n in nodes) {
    final String m = n.toMarkup();

    int total = 0;
    for (int i = 0; i < m.length; i++) {
      if (m.codeUnitAt(i) == 10) total++;
    }

    if (n.isStructural) {
      n.startLine = -1;
      n.endLine = -1;
    } else {
      n.startLine = line;
      final bool endsOnBreak =
          m.isNotEmpty && m.codeUnitAt(m.length - 1) == 10;
      n.endLine = line + (endsOnBreak ? total - 1 : total);
    }

    line += total;
  }
}

/// Stamps every node with its exact character range in the current emitted
/// document. The spans tile the document with no gaps or overlaps and use the
/// same start-inclusive, end-exclusive convention as String.substring.
///
/// This deliberately derives from [toMarkup] after edits instead of retaining
/// stale parse offsets. Changing one node's authored length therefore shifts
/// every following node to its new exact source position without rewriting
/// any of them.
void assignNodeSourceSpans(List<ScriptNode> nodes) {
  int offset = 0;
  for (final ScriptNode node in nodes) {
    final String markup = node.toMarkup();
    node.startOffset = offset;
    offset += markup.length;
    node.endOffset = offset;
  }
}
