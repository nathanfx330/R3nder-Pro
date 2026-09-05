// ./lib/script_pipeline.dart

import 'parser.dart';
import 'script_cst.dart';
import 'structural_sequence.dart';

// =====================================================================
// WHY THIS EXISTS
//
// Between the document you type and the string the engine runs there are
// four steps: parse out CONFIG and macro declarations, resolve macro
// instance settings, expand CALL and MENU_STATE into real markup, and
// (editor only) inject [LINE:x] markers so the engine can report which
// document line it is executing.
//
// Those four steps were spread across two files. main._setupScene did
// three of them for preview and bake; editor._resimulate did all four
// inline for the scrubber. Two implementations of one transformation,
// which is workable right up until they disagree, at which point the
// preview shows frames the bake will never produce and the trust the
// whole tool rests on is gone.
//
// It also blocked warming. Nothing outside the editor could precompute
// an editor simulation, because nothing outside the editor knew how to
// build the exact string the editor was going to run.
//
// Pure in, pure out: no widget state, no filesystem, no engine. Both
// callers get the same answer because there is only one answer.
// =====================================================================

/// A document compiled to the exact text an engine will run, plus the
/// configuration read out of it on the way through.
class CompiledScript {
  /// Macro-expanded (and optionally line-marked) text, ready to hand to
  /// SceneEngine.setup().
  final String engineText;

  /// Every [CONFIG:KEY:value] found in the raw document.
  final Map<String, String> configs;

  /// Stable serialisation of [configs], for identity comparisons.
  ///
  /// CONFIG tags are STRIPPED by preprocessing, so they never appear in
  /// [engineText]. Anything keyed on the engine text alone therefore
  /// cannot see a config change at all: two scripts differing only by
  /// [CONFIG:DESKTOP:...] compile to identical text. Every config value
  /// is nonetheless passed into setup and baked into the engine, so a
  /// warm built before a config change would be adopted and render with
  /// the old wallpaper, the old window title, or the old pane motion.
  ///
  /// Sorted, because Map iteration order follows insertion and the same
  /// document must always produce the same digest.
  String get configDigest {
    final List<String> keys = configs.keys.toList()..sort();
    return keys.map((k) => '$k=${configs[k]}').join(';');
  }

  /// Parsed macro declarations, kept because the caller may want to show
  /// them and because recomputing them means re-running the parse.
  final Map<String, List<MenuItem>> definedMenus;
  final List<MenuStateRef> menuStates;
  final Map<String, MacroConfig> menuSettings;

  const CompiledScript({
    required this.engineText,
    required this.configs,
    required this.definedMenus,
    required this.menuStates,
    required this.menuSettings,
  });

  /// [CONFIG:DESKTOP:...], or null for the classic fullscreen terminal.
  String? get desktopWallpaper => configs['DESKTOP'];

  /// [CONFIG:WINTITLE:...], or null for the painter's default.
  String? get windowTitle => configs['WINTITLE'];

  /// [CONFIG:PANELIFE:...], or null when mosaic panels should stay still.
  ///
  /// Returned raw. Parsing lives in motion.dart so preview, bake, the
  /// editor, and the warm-up cannot interpret the same string differently,
  /// which is the same reason compileScript exists at all.
  String? get paneLife => configs['PANELIFE'];

  /// [CONFIG:CAPTION:...], or null for default caption typography.
  ///
  /// Raw for the same reason as PANELIFE. Parsing lives in
  /// folder_captions.dart.
  String? get caption => configs['CAPTION'];

  /// [CONFIG:APPSWITCH:...], or null for the desktop round trip.
  String? get appSwitch => configs['APPSWITCH'];
}

/// Compiles [rawText] into engine-ready text.
///
/// EDIT / TRACK / CLIP and MOSAIC / PANE / CLIP are authored project
/// structure, not terminal content. They remain byte-for-byte in [rawText],
/// but the engine projection replaces each complete structural root with only
/// its newline characters. Keeping those newlines is what lets editor
/// [LINE:n] markers continue to refer to raw document line numbers even though
/// the source graph itself does not run in TerminalEngine.
///
/// A standalone `[STRUCT:EDIT.foo]` or `[STRUCT:MOSAIC.bar]` is different:
/// that is a main-sequence placement. After the source definitions are removed,
/// the projection replaces the placement with a PAUSE whose duration comes
/// from the referenced source. TerminalEngine therefore owns the timing while
/// the editor/render layer owns the structural pixels. The author never types a
/// second duration for the same cut.
///
/// [lineMarkers] injects an editor-only `[LINE:n]` at the head of each
/// document line so the engine reports its read position back as a line
/// number. Preview and bake pass false; the editor passes true.
///
/// IMPORTANT, and the reason marking lives here rather than in the
/// editor: markers must be injected BEFORE macro expansion, because
/// expansion rewrites line structure. Injecting after would number lines
/// that do not exist in the document the author is looking at.
CompiledScript compileScript(String rawText, {bool lineMarkers = false}) {
  final String projected = _engineProjectionSource(rawText);
  final String marked =
      lineMarkers ? injectLineMarkers(projected) : projected;

  final TemplateData data = ScriptParser.parseTemplateData(marked);

  // Every macro instance the document references gets settings: its own
  // if it declared them, defaults otherwise. Absent settings are not an
  // error, they are an unconfigured menu.
  final Map<String, MacroConfig> menuSettings = {};
  for (final state in data.menuStatesFound) {
    menuSettings[state.instanceId] =
        data.macroConfigs[state.instanceId] ?? MacroConfig();
  }

  final String expanded = ScriptParser.injectMacros(
    marked,
    data.definedMenus,
    data.menuStatesFound,
    menuSettings,
  );

  return CompiledScript(
    engineText: expanded,
    configs: data.configs,
    definedMenus: data.definedMenus,
    menuStates: data.menuStatesFound,
    menuSettings: menuSettings,
  );
}

/// Builds the terminal engine projection while preserving authored line
/// coordinates.
///
/// Source spans come from the nested CST, so this removes structural roots
/// rather than trying to match nested blocks with a regular expression. Roots
/// are replaced from right to left so every original offset remains valid.
///
/// Sequence placements are projected only AFTER source roots are gone. That is
/// what prevents a `[STRUCT:...]` accidentally written inside an EDIT/MOSAIC
/// definition from consuming main-sequence time.
String _engineProjectionSource(String rawText) {
  final bool hasStructuralRoots = RegExp(
    r'\[(?:EDIT|TRACK|MOSAIC|PANE|CLIP)(?::[^\]\r\n]*)?\]',
  ).hasMatch(rawText);

  String projected = rawText;
  if (hasStructuralRoots) {
    final ScriptCstDocument cst = ScriptCstDocument.parse(rawText);
    for (final ScriptCstBlock root in cst.roots.reversed) {
      final String owned = rawText.substring(root.startOffset, root.endOffset);
      final String blankLines = owned.replaceAll(RegExp(r'[^\r\n]'), '');
      projected = projected.replaceRange(
        root.startOffset,
        root.endOffset,
        blankLines,
      );
    }
  }

  return projectStructuralSequencePlacements(
    rawDocument: rawText,
    projectedSource: projected,
  );
}

/// Prefixes each line with `[LINE:n]`, n being its 0-based index.
///
/// SKIPS THE INTERIOR OF COMMENTS, which is not a nicety. The comment
/// pattern is lazy to the first `]`, so a marker planted at the start of
/// a comment's second line closes that comment early and everything
/// after it becomes typed text on screen. Bake does not inject markers,
/// so the result was the preview showing frames the export would never
/// produce: a determinism break, and the worst kind, because the preview
/// is the thing you trust.
///
/// A comment's interior never needs a marker anyway, since it does not
/// type. A line where a comment BEGINS still gets one, because there may
/// be real content ahead of it on that line.
String injectLineMarkers(String rawText) {
  final List<(int, int)> commentSpans = [];
  for (final m in RegExp(r'\[#.*?\]', dotAll: true).allMatches(rawText)) {
    commentSpans.add((m.start, m.end));
  }

  final List<String> lines = rawText.split('\n');
  int lineStart = 0;

  for (int i = 0; i < lines.length; i++) {
    // Capture the ORIGINAL length first. The offsets being tested come
    // from the raw buffer, so advancing by the marked length would put
    // every later line's offset out by the width of its own marker.
    final int originalLength = lines[i].length;

    bool insideComment = false;
    for (final (cs, ce) in commentSpans) {
      // Strictly inside.
      if (lineStart > cs && lineStart < ce) {
        insideComment = true;
        break;
      }
    }
    if (!insideComment) lines[i] = '[LINE:$i]${lines[i]}';

    lineStart += originalLength + 1;
  }

  return lines.join('\n');
}

/// Identity of a prepared editor simulation.
///
/// A warmed simulation is only valid for the exact inputs that produced
/// it, and "exact" is broader than the document: margins and font metrics
/// decide where lines wrap, wrapping decides how many lines there are,
/// and line count changes the frame count. A warm keyed on text alone
/// would look right and be wrong.
///
/// Serving a stale warm is strictly worse than serving none, because a
/// cold open costs a wait and a stale one shows you a ribbon for a script
/// you no longer have. So this errs toward invalidating: anything that
/// could move a frame boundary is in the key.
///
/// Uses hashCode, which is stable within a process and guaranteed nothing
/// beyond that. Fine here, and only here: a warm never outlives the run
/// that built it, so it is never compared across processes. Do not
/// persist one of these.
class ScriptWarmKey {
  final int value;

  const ScriptWarmKey(this.value);

  factory ScriptWarmKey.of({
    required String engineText,
    required String configDigest,
    required String imagesDir,
    required String spritesDir,
    required String fontFamily,
    required int fontColor,
    required int bgColor,
    required double width,
    required double height,
    required double scale,
    required double fontSize,
    required double lineSpacing,
    required double tracking,
    required double marginTop,
    required double marginSide,
    required int bedTargetFrames,
  }) {
    return ScriptWarmKey(Object.hash(
      engineText,
      // Separate from engineText because preprocessing strips CONFIG
      // before the engine ever sees it. See CompiledScript.configDigest.
      configDigest,
      imagesDir,
      spritesDir,
      fontFamily,
      // Colours move no frame boundaries, so they were left out at first.
      // That was wrong for a different reason: a warm carries a LIVE
      // ENGINE already set up with them, so adopting one built before a
      // [CONFIG:FG] change would silently render the old phosphor. The key
      // has to cover everything baked into the engine, not just everything
      // that affects timing.
      fontColor,
      bgColor,
      width,
      height,
      scale,
      fontSize,
      lineSpacing,
      tracking,
      marginTop,
      marginSide,
      bedTargetFrames,
    ));
  }

  @override
  bool operator ==(Object other) =>
      other is ScriptWarmKey && other.value == value;

  @override
  int get hashCode => value;
}
