// ./lib/editor_warmup.dart

import 'dart:ui' show Color;

import 'engine.dart' show engineFps;
import 'scene_engine.dart';
import 'script_nodes.dart';
import 'script_pipeline.dart';
import 'script_ribbon.dart';

// =====================================================================
// WHY THIS EXISTS
//
// Opening the editor used to mean waiting: decode every referenced
// asset, then tick the whole script to measure it, and only then paint
// anything with a length in it. That wait happened at the one moment the
// user was least willing to spend it, having just clicked EDIT.
//
// The dashboard, meanwhile, sits idle. The document is already loaded,
// the render settings are already chosen, and nothing is competing for
// the isolate. So the simulation happens THERE, against time that was
// going to be spent reading the menu anyway, and the editor opens with
// the answer already in hand.
//
// THE HARD PART IS NOT THE WARMING, IT IS THE MATCHING.
//
// A warm is only usable if it is bit-for-bit the simulation the editor
// would have run itself. Two code paths computing "the same" simulation
// is precisely the arrangement that works until it quietly does not, and
// the failure mode is the worst available: a ribbon and a frame count
// that look authoritative and describe a script you no longer have.
//
// So there is exactly one simulation function, [runEditorSimulation],
// and both sides call it. Not a shared helper that each side wraps
// differently: the whole of setup plus pass one, including the ribbon
// construction, lives here. Main cannot warm something the editor would
// not have produced, because main does not know how to produce anything
// else.
//
// And the result carries a key. See [EditorSimRequest.warmKey].
// =====================================================================

// Warm-up tracing.
//
// A warm that never lands is INVISIBLE: the fallback is exactly the old
// behaviour, so a broken warm and an absent warm look identical from the
// outside. That is what hid a key mismatch (the font list loading
// asynchronously, after the first warm had already been built against
// "monospace") through several rounds of looking in the wrong place.
//
// So the adopt/discard decision reports itself, with both keys and the
// fields most likely to differ. Flip to true if the editor ever starts
// opening cold again.
const bool kProfileWarm = false;

/// Hard cap on simulated length: twenty minutes at the engine frame rate.
///
/// A runaway script (a chained presentation that never terminates, say)
/// would otherwise tick forever with the UI blocked behind it. Twenty
/// minutes is far past any real motion-graphics cue and near enough to
/// instant to bound the damage.
const int kMaxSimFrames = engineFps * 60 * 20;

/// Every input that determines an editor simulation.
///
/// Built identically by main and by the editor. That is the whole point:
/// a key comparison between two objects assembled from different field
/// lists would be a comparison of two different questions.
class EditorSimRequest {
  final String docText;

  final Color fontColor;
  final Color bgColor;
  final double engineWidth;
  final double engineHeight;
  final double engineScale;
  final String fontFamily;
  final double fontSize;
  final double lineSpacing;
  final double tracking;
  final double marginTop;
  final double marginSide;

  final String imagesDir;
  final String spritesDir;

  /// Bed length in frames. Affects the engine's end hold, so it moves the
  /// total frame count and therefore belongs in the key.
  final int bedTargetFrames;

  const EditorSimRequest({
    required this.docText,
    required this.fontColor,
    required this.bgColor,
    required this.engineWidth,
    required this.engineHeight,
    required this.engineScale,
    required this.fontFamily,
    required this.fontSize,
    required this.lineSpacing,
    required this.tracking,
    required this.marginTop,
    required this.marginSide,
    required this.imagesDir,
    required this.spritesDir,
    required this.bedTargetFrames,
  });

  /// Compiles the document exactly as the editor will run it.
  ///
  /// Line markers always on. The editor is the only consumer of a warm,
  /// and the editor always simulates marked text.
  CompiledScript compile() => compileScript(docText, lineMarkers: true);

  /// Identity of the simulation these inputs produce.
  ///
  /// Keyed on the COMPILED text rather than the raw document, so that an
  /// edit which compiles to the same thing (a comment reworded, macro
  /// settings that resolve identically) correctly keeps its warm.
  ///
  /// Everything else in here moves frame boundaries. Margins and font
  /// metrics decide where lines wrap; wrapping decides line count; line
  /// count decides frame count. The asset directories are in for a
  /// blunter reason: the same document against a different workspace
  /// resolves to different assets and therefore different timing.
  ///
  /// Erring toward invalidation is correct and cheap. A key that changes
  /// too readily costs a cold open, which is what every open cost before
  /// any of this existed. A key that changes too rarely serves a
  /// confident lie.
  ScriptWarmKey warmKey(CompiledScript compiled) => ScriptWarmKey.of(
        engineText: compiled.engineText,
        configDigest: compiled.configDigest,
        imagesDir: imagesDir,
        spritesDir: spritesDir,
        fontFamily: fontFamily,
        // toARGB32 rather than the Color object: Color.hashCode is stable,
        // but pinning the key to the integer channel value keeps it
        // independent of how Flutter chooses to represent a colour.
        fontColor: fontColor.toARGB32(),
        bgColor: bgColor.toARGB32(),
        width: engineWidth,
        height: engineHeight,
        scale: engineScale,
        fontSize: fontSize,
        lineSpacing: lineSpacing,
        tracking: tracking,
        marginTop: marginTop,
        marginSide: marginSide,
        bedTargetFrames: bedTargetFrames,
      );
}

/// What one simulation pass yields, beyond the engine state itself.
class EditorSimResult {
  /// Simulated length, bed tail included.
  final int totalFrames;

  /// Frame index to document line. Drives the typing-line highlight and
  /// click-to-jump.
  final List<int> rawLineAtFrame;

  /// Timeline strip contents. Built here rather than in build(), because
  /// it is a full pass over frames and this way it happens once per
  /// simulation instead of once per repaint.
  ///
  /// Always a fresh list, never a mutated one: the ribbon painter decides
  /// whether to repaint by comparing block lists by identity.
  final List<RibbonBlock> ribbonBlocks;

  const EditorSimResult({
    required this.totalFrames,
    required this.rawLineAtFrame,
    required this.ribbonBlocks,
  });
}

/// Sets up [scene] for [req] and ticks it to the end, measuring as it goes.
///
/// Leaves the scene PARKED AT THE FINAL FRAME. That is not incidental: it
/// is the state the editor opens in, so a caller targeting the end needs
/// no replay at all, and a caller targeting an earlier frame resets and
/// ticks forward from a known position.
///
/// The single definition of "an editor simulation". Both the warm builder
/// on the dashboard and the editor's own re-simulate call this and
/// nothing else.
Future<EditorSimResult> runEditorSimulation(
  SceneEngine scene,
  EditorSimRequest req, {
  CompiledScript? compiled,
}) async {
  // Callers that already compiled (to compute a key, usually) pass it in
  // rather than paying for the parse twice.
  final CompiledScript script = compiled ?? req.compile();

  await scene.setup(
    templateText: script.engineText,
    fontColor: req.fontColor,
    bgColor: req.bgColor,
    width: req.engineWidth,
    height: req.engineHeight,
    scale: req.engineScale,
    fontPath: req.fontFamily,
    fontSize: req.fontSize,
    lineSpacing: req.lineSpacing,
    tracking: req.tracking,
    marginTop: req.marginTop,
    marginSide: req.marginSide,
    imagesDir: req.imagesDir,
    spritesDir: req.spritesDir,
    desktopWallpaper: script.desktopWallpaper,
    windowTitle: script.windowTitle,
    paneLifeConfig: script.paneLife,
    captionConfig: script.caption,
    appSwitchConfig: script.appSwitch,
    // The editor never previews the preroll, so the bed sits at frame 0
    // here. Passing the length still matters: without it the scrubber
    // would stop short of where the bake actually ends whenever the bed
    // outruns the script.
    bedTargetFrames: req.bedTargetFrames,
  );

  // Measure, recording the frame -> read-head map as we go.
  final List<int> lineMap = [];
  int total = 0;

  // Where the script stops and the engine-owned end hold begins, in THIS
  // loop's frame index. The engine exposes a flag rather than a frame
  // number because the terminal's own frameCount stops while a window
  // presentation suspends it, so the two never lined up.
  int endHoldStart = -1;

  while (!scene.isFinished && total < kMaxSimFrames) {
    scene.tick();
    lineMap.add(scene.terminal.currentRawLine);
    if (endHoldStart < 0 && scene.terminal.inEndHold) endHoldStart = total;
    total++;
  }

  // Ribbon blocks off the map just built. Parsed from the RAW document,
  // not the compiled text: the strip addresses document lines, which is
  // what the author is looking at and what click-to-jump navigates.
  final List<ScriptNode> ribbonNodes = parseScriptToNodes(req.docText);
  assignNodeLineSpans(ribbonNodes);

  return EditorSimResult(
    totalFrames: total,
    rawLineAtFrame: lineMap,
    ribbonBlocks: buildRibbonBlocks(
      ribbonNodes,
      lineMap,
      endHoldStartFrame: endHoldStart,
    ),
  );
}

/// A finished simulation, prepared ahead of time, waiting to be handed to
/// an editor.
///
/// OWNERSHIP TRANSFERS EXACTLY ONCE. The bundle holds a live SceneEngine
/// with a fully decoded asset library, which is the expensive thing and
/// the thing that leaks if nobody takes responsibility for it. So:
///
///   - main builds it and holds it,
///   - main hands it to EditorScreen and drops its own reference in the
///     same breath,
///   - the editor calls [adopt] (taking the engine) or [dispose]
///     (releasing it), unconditionally, on its first frame.
///
/// This is deliberately the OPPOSITE of the audio bed player's rule,
/// where main keeps ownership and the editor only ever stops it. A player
/// is a shared singleton backend that must outlive any one screen; this
/// is a disposable computation that happens to hold a decoded library.
/// Applying the bed's rule here would leak an asset library per open;
/// applying this rule to the bed would kill the sound on the menu.
///
/// [isSpent] exists so that mistake is loud rather than silent.
class EditorWarmup {
  /// Inputs this was built from. A warm is valid only against a request
  /// that produces the same key.
  final ScriptWarmKey key;

  final EditorSimResult result;

  SceneEngine? _scene;
  bool _taken = false;

  EditorWarmup({
    required this.key,
    required this.result,
    required SceneEngine scene,
  }) : _scene = scene;

  int get totalFrames => result.totalFrames;
  List<int> get rawLineAtFrame => result.rawLineAtFrame;
  List<RibbonBlock> get ribbonBlocks => result.ribbonBlocks;

  /// True once the engine has been taken or released. A spent bundle is
  /// inert and must not be adopted: it no longer owns anything.
  bool get isSpent => _taken || _scene == null;

  /// Takes the engine, parked at the final frame. Callable once.
  SceneEngine adopt() {
    final SceneEngine? s = _scene;
    if (s == null || _taken) {
      throw StateError(
          'EditorWarmup already spent. Check isSpent before adopting: a '
          'bundle can be handed to exactly one editor.');
    }
    _taken = true;
    _scene = null;
    return s;
  }

  /// Releases the engine and its decoded assets without adopting.
  ///
  /// The normal path whenever inputs moved after the warm was built, which
  /// on an actively edited document is most of the time. Safe to call more
  /// than once, and safe to call after [adopt], where it does nothing
  /// because ownership has already gone elsewhere.
  void dispose() {
    _scene?.disposeImages();
    _scene = null;
  }
}