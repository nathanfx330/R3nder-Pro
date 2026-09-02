// ./lib/engine.dart

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'parser.dart';
import 'svg_path.dart';
import 'presentation_requests.dart';

export 'presentation_requests.dart';

part 'engine_state.dart';
part 'engine_tick.dart';

const int engineFps = 30;
const String scrambleChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#\$%^&*()_+={}[]|:;<>,.?/~`¥";

/// Frames the engine holds on the final frame after the script exhausts,
/// with frameCount still advancing so cursor blink and FLASH/WAVE effects
/// stay alive. Owned by the engine (not bolted on by the exporter), so the
/// dry-run frame count, editor scrubber, live preview, and export all agree.
const int kEndHoldFrames = engineFps * 2;

/// Fixed seed for the scramble RNG. Re-seeded on every reset() so the engine
/// is fully deterministic: dry-run frame counts match the real render exactly,
/// and the editor's scrubber can re-simulate to any frame with identical results.
const int _scrambleSeed = 1337;

/// Hard cap on stacked [PHOTO] onion layers. Beyond this the OLDEST (bottom)
/// layer is dropped so the newest always shows and gates. Pure function of
/// the tags fired, so determinism is preserved.
const int kMaxPhotoStack = 6;

class TerminalEngine {
  bool isFinished = false;

  late String templateText;
  late Color fontColor;
  late Color bgColor;
  late double width;
  late double height;
  late double scale;

  late double marginX;
  late double marginY;
  late double baseLineSpacing;
  late double tracking;
  late double baseFontSize;
  String fontFamily = "monospace";

  // State variables
  String text = "";
  int charIndex = 0;
  int frameCount = 0;
  int globalCharIndex = 0;
  int currentRawLine = 0;

  double cursorX = 0;
  double cursorY = 0;

  List<LineData> renderedLines = [];
  List<CharData> currentLine = [];
  double currentLineWidth = 0;

  String currentAlign = "LEFT";
  double currentFontSize = 24.0;
  double currentLineSpacing = 30.0;

  int charsPerFrame = 1;

  /// The currently active terminal pause, or null while script execution is
  /// free to continue. Ordinary PAUSE tags, missing-asset timing duds, and the
  /// final engine-owned hold all share this one explicit-age state.
  PauseState? activePause;

  /// Back-compatible pause view used by diagnostics and existing callers.
  /// Reads are derived from terminal-frame age. Writes retain the historical
  /// public-field behavior for callers outside the tick loop; engine-owned
  /// pauses use [_startPause] so parser entry is anchored to the next visible
  /// terminal frame exactly as before.
  int get pauseFrames => activePause?.framesLeftAt(frameCount) ?? 0;
  set pauseFrames(int value) {
    if (value <= 0) {
      activePause = null;
      return;
    }
    activePause = PauseState(
      durationFrames: value,
      startFrame: frameCount,
    );
  }

  bool isRedacting = false;
  bool isScrambling = false;

  /// The character currently passing through SCRAMBLE, or null between
  /// characters. Its duration is chosen once by the seeded RNG and all
  /// visible timing derives from terminal-frame distance after that.
  ScrambleState? activeScramble;

  /// Back-compatible read-only views used by the painter and diagnostics.
  /// They are no longer mutable timing state.
  int get scrambleFramesLeft =>
      activeScramble?.framesLeftAt(frameCount) ?? 0;
  String get scrambleTargetChar => activeScramble?.targetChar ?? "";

  /// True once the script text has fully exhausted and the engine has entered
  /// its final hold. While the hold plays, frameCount keeps advancing (cursor
  /// blink and flash effects stay alive); isFinished flips when it expires.
  bool _endHoldStarted = false;

  /// True once the script has been fully typed and the engine is playing out
  /// its end hold.
  ///
  /// Exposed for the editor's script ribbon. During the hold, [_tick] returns
  /// before it can touch [currentRawLine], so the read head keeps reporting
  /// the last line of the script for the whole tail. Anything mapping frames
  /// to document position therefore has to be told where the script actually
  /// ended, or it attributes every hold frame (which a long audio bed can
  /// stretch to minutes) to whichever node happened to be last.
  ///
  /// A boolean rather than a frame number on purpose. [frameCount] is this
  /// engine's own timebase and stops advancing while a window presentation
  /// suspends the terminal, so it does not line up with a scene frame index.
  /// A caller watching this flag inside its own tick loop records the answer
  /// in whatever timebase it is already counting in.
  bool get inEndHold => _endHoldStarted;

  /// Length of the background audio bed in frames, or 0 when none is
  /// attached. This is the ONLY thing the engine ever learns about audio.
  ///
  /// When the script exhausts before the bed does, the end hold stretches to
  /// cover the remainder so a trailing voiceover line plays out over a live
  /// blinking cursor rather than a frozen still. Set once at setup() and
  /// never touched again, so it behaves exactly like templateText: config,
  /// not state. reset() deliberately leaves it alone.
  ///
  /// Determinism is unaffected. This is a fixed integer known before frame 0,
  /// so reset() plus N ticks still reproduces any frame, and the exporter's
  /// dry run returns the extended count without special-casing anything.
  int bedTargetFrames = 0;

  BarState? activeBar;
  String? currentRegion;

  /// Non-null only while an [IMG] band is gating typing. The rendered
  /// [LineData] owns the band's start-frame state after release, so reveal
  /// progress can continue from terminal age without a second live timing
  /// list or a mutable elapsed counter.
  ImgBandState? activeImgBand;

  late Color penColor;
  Color? penBg;
  String? flashStyle;

  /// Exactly one desktop presentation may suspend the terminal at a time.
  /// The previous implementation carried five parallel nullable fields; that
  /// duplicated the same mutual-exclusion invariant in every caller. The
  /// single channel makes the invariant structural. Typed getters/setters are
  /// retained so existing engine/scene code and external callers keep the
  /// same API.
  PresentationRequest? _pendingPresentation;

  PresentationRequest? get pendingPresentation => _pendingPresentation;
  bool get hasPendingPresentation => _pendingPresentation != null;

  GalleryRequest? get pendingGallery =>
      _pendingPresentation is GalleryRequest
          ? _pendingPresentation as GalleryRequest
          : null;
  set pendingGallery(GalleryRequest? value) {
    if (value != null) {
      _pendingPresentation = value;
    } else if (_pendingPresentation is GalleryRequest) {
      _pendingPresentation = null;
    }
  }

  AppRequest? get pendingApp => _pendingPresentation is AppRequest
      ? _pendingPresentation as AppRequest
      : null;
  set pendingApp(AppRequest? value) {
    if (value != null) {
      _pendingPresentation = value;
    } else if (_pendingPresentation is AppRequest) {
      _pendingPresentation = null;
    }
  }

  BrowserRequest? get pendingBrowser =>
      _pendingPresentation is BrowserRequest
          ? _pendingPresentation as BrowserRequest
          : null;
  set pendingBrowser(BrowserRequest? value) {
    if (value != null) {
      _pendingPresentation = value;
    } else if (_pendingPresentation is BrowserRequest) {
      _pendingPresentation = null;
    }
  }

  CardRequest? get pendingCard => _pendingPresentation is CardRequest
      ? _pendingPresentation as CardRequest
      : null;
  set pendingCard(CardRequest? value) {
    if (value != null) {
      _pendingPresentation = value;
    } else if (_pendingPresentation is CardRequest) {
      _pendingPresentation = null;
    }
  }

  DossierRequest? get pendingDossier =>
      _pendingPresentation is DossierRequest
          ? _pendingPresentation as DossierRequest
          : null;
  set pendingDossier(DossierRequest? value) {
    if (value != null) {
      _pendingPresentation = value;
    } else if (_pendingPresentation is DossierRequest) {
      _pendingPresentation = null;
    }
  }

  TimelineRequest? get pendingTimeline =>
      _pendingPresentation is TimelineRequest
          ? _pendingPresentation as TimelineRequest
          : null;
  set pendingTimeline(TimelineRequest? value) {
    if (value != null) {
      _pendingPresentation = value;
    } else if (_pendingPresentation is TimelineRequest) {
      _pendingPresentation = null;
    }
  }

  /// Non-null while an [SVG] / [SVGFLASH] show is on the terminal screen.
  /// This is NOT a suspend — the engine owns it entirely: it wiped on entry,
  /// counts the hold down here (frameCount advancing, fully deterministic),
  /// and wipes on exit before typing resumes. The painter checks this and
  /// draws the stencil instead of the text buffer.
  ActiveSvgShow? activeSvg;

  /// The live [PHOTO] onion stack, painted bottom-to-top. Empty when no
  /// photo is on screen. A classic (no-release) photo is a stack of one
  /// that tears down at the end of its hold; stack (release%) layers persist
  /// here until an explicit wipe. Each layer derives its reveal from its
  /// authored terminal start frame.
  final List<ActivePhotoShow> _photoStack = [];

  /// The layer currently blocking typing, or null once it has released.
  /// While set, tick() advances terminal frame time and checks the layer's
  /// derived age against releaseAt. Stack layers remain in [_photoStack]
  /// after release; classic layers tear down or chain at release.
  ActivePhotoShow? _photoGate;

  final Map<String, double> _charWidthCache = {};
  
  /// Preloaded sprite files. Map of Path -> List of Frames -> List of Lines
  Map<String, List<List<String>>> _spriteLibrary = {};

  /// Preloaded, parsed SVG stencils keyed by file path relative to images/.
  Map<String, SvgDocument> _svgLibrary = {};

  /// Ordered .svg file keys per folder (for [SVGFLASH]), keyed by folder
  /// name relative to images/. Sorted by filename at load time.
  Map<String, List<String>> _svgFolders = {};

  /// Preloaded [IMG] raster stencils keyed by `"<channel>:<file path>"`
  /// relative to images/ — the same file masked through R and through G is
  /// two different stencils. Built by the SceneEngine during setup(),
  /// mirroring the sprite and SVG libraries.
  Map<String, ImgStencil> _imgLibrary = {};
  
  /// Sprites currently cycling on screen
  final Map<String, _ActiveSprite> _activeSprites = {};

  // DETERMINISM: re-seeded in reset() so every simulation of the same script
  // produces identical scramble durations. Not final, because reset() replaces it.
  math.Random _random = math.Random(_scrambleSeed);

  /// The glyph the painter should show while a scramble is in flight.
  /// Derived purely from frame-counted state (no wall clock, no RNG draw),
  /// so any frame N renders the exact same character in the live preview,
  /// the editor scrubber, and every export — byte-identical bakes.
  String get scrambleDisplayChar {
    final int idx =
        (frameCount * 31 + globalCharIndex * 7 + scrambleFramesLeft * 13) %
            scrambleChars.length;
    return scrambleChars[idx];
  }

  /// Starts one engine-owned pause whose first visible frame is the frame
  /// produced by the current parser/end-hold tick. This is intentionally
  /// separate from the compatibility setter above: internal pause creation
  /// always happens before the current tick increments [frameCount].
  void _startPause(int frames) {
    if (frames <= 0) {
      activePause = null;
      return;
    }
    activePause = PauseState(
      durationFrames: frames,
      startFrame: frameCount + 1,
    );
  }
  
  void setSpriteLibrary(Map<String, List<List<String>>> library) {
    _spriteLibrary = library;
  }

  /// Installs the parsed SVG stencils and folder listings. Called by the
  /// SceneEngine during setup(), mirroring setSpriteLibrary.
  void setSvgLibrary(
      Map<String, SvgDocument> files, Map<String, List<String>> folders) {
    _svgLibrary = files;
    _svgFolders = folders;
  }

  /// Installs the thresholded [IMG] stencils, keyed `"<channel>:<file>"`.
  /// Called by the SceneEngine during setup(), mirroring setSpriteLibrary.
  void setImgLibrary(Map<String, ImgStencil> library) {
    _imgLibrary = library;
  }

  /// The stencil the painter should draw right now, or null. Resolves the
  /// active show's current step against the library.
  SvgDocument? get activeSvgDocument {
    final a = activeSvg;
    if (a == null || a.steps.isEmpty) return null;
    return _svgLibrary[a.currentKey];
  }

  /// Fill color for the active stencil.
  Color get activeSvgColor => activeSvg?.color ?? penColor;

  // -------------------------------------------------------------------
  // Photo stack accessors (for the painter)
  // -------------------------------------------------------------------

  /// The full onion stack, bottom-to-top. The painter draws each layer in
  /// order, clipped to its own scanline progress, so lower layers show
  /// through the gaps of the ones above.
  List<ActivePhotoShow> get photoStack => _photoStack;

  bool get hasPhotos => _photoStack.isNotEmpty;

  /// Resolves a layer's stencil against the [IMG] library.
  ImgStencil? photoStencilFor(ActivePhotoShow p) => _imgLibrary[p.key];

  /// BACK-COMPAT single-photo accessor: the TOP layer, or null when the
  /// stack is empty. Kept so existing call sites (the pre-stack painter)
  /// stay valid; the full renderer should walk [photoStack] instead.
  ActivePhotoShow? get activePhoto =>
      _photoStack.isEmpty ? null : _photoStack.last;

  /// BACK-COMPAT: the top layer's stencil, or null.
  ImgStencil? get activePhotoDocument {
    final p = activePhoto;
    if (p == null) return null;
    return _imgLibrary[p.key];
  }

  /// PURE LOOKAHEAD for presentation chaining. Returns true if the very next
  /// meaningful token after the read head is another presentation tag
  /// (GALLERY / VIDEO / APP / CARD / DOSSIER / TIMELINE), with nothing but whitespace,
  /// newlines, and editor-injected [LINE:x] markers between here and there.
  ///
  /// Used by the SceneEngine when a presentation's hold expires: a chain
  /// ahead means "hand off directly on the desktop" instead of zooming the
  /// terminal back up to fullscreen between presentations.
  ///
  /// No state is mutated — charIndex, frameCount, everything is untouched —
  /// so this is safe to call at any time without affecting determinism.
  ///
  /// Semantics: any real content between two presentation tags (typed text,
  /// a [PAUSE], a [COLOR] change, anything) means the writer wants the
  /// terminal back, so this returns false and the normal zoom-in plays.
  bool peekNextPresentation() {
    int i = charIndex;

    while (i < text.length) {
      final String c = text[i];

      // Skip whitespace and newlines.
      if (c == ' ' || c == '\n' || c == '\t' || c == '\r') {
        i++;
        continue;
      }

      // Anything that isn't a tag start is real content: no chain.
      if (c != '[') return false;

      final match = tagRegex.matchAsPrefix(text, i) as RegExpMatch?;
      if (match == null) return false; // Literal '[' typed as content.

      // Editor-injected line markers are transparent for chaining purposes.
      if (match.namedGroup('line') != null) {
        i += match.end - match.start;
        continue;
      }

      // The next meaningful token IS a tag: chain only if it's a
      // presentation tag.
      return match.namedGroup('galFolder') != null ||
          match.namedGroup('vidFolder') != null ||
          match.namedGroup('appFolder') != null ||
          match.namedGroup('browFolder') != null ||
          match.namedGroup('cardImg') != null ||
          match.namedGroup('dosFolder') != null ||
          match.namedGroup('tlBody') != null;
    }

    return false; // Script exhausted: nothing to chain into.
  }

  /// The layout segment of the next meaningful tag, if that tag is an APP.
  ///
  /// Null for anything else: real content ahead, a non-APP tag, or the end
  /// of the script. Consumes nothing, which is the entire point. The SLIDE
  /// app switch has to know whether the next tag is a compatible APP
  /// BEFORE it commits, because deciding afterwards would mean either
  /// tearing down a window it turns out we wanted to keep, or advancing
  /// the terminal past a tag we then have to put back.
  ///
  /// Returns the raw layout string rather than a parsed enum so this file
  /// stays free of the presentation vocabulary, the way it already is.
  /// An APP tag with no layout segment yields the empty string, which the
  /// caller resolves through the same default the request parser uses.
  String? peekNextAppLayout() {
    int i = charIndex;

    while (i < text.length) {
      final String c = text[i];

      if (c == ' ' || c == '\n' || c == '\t' || c == '\r') {
        i++;
        continue;
      }

      if (c != '[') return null;

      final match = tagRegex.matchAsPrefix(text, i) as RegExpMatch?;
      if (match == null) return null;

      if (match.namedGroup('line') != null) {
        i += match.end - match.start;
        continue;
      }

      if (match.namedGroup('appFolder') == null) return null;
      return match.namedGroup('appLayout') ?? '';
    }

    return null;
  }

  /// The scroll segment of the next meaningful tag, if that tag is a
  /// [BROWSER].
  ///
  /// The browser half of [peekNextAppLayout], and non-consuming for the
  /// identical reason: the SLIDE switch has to know before it commits,
  /// because deciding afterwards means either tearing down a window it
  /// wanted to keep or putting a consumed tag back.
  ///
  /// THIS USED TO RETURN A BOOL, and the reasoning written here for why a
  /// bool was enough is worth keeping as the record of what changed. It said
  /// a browser has no layout segment to be compatible about: every BROWSER
  /// window was the same window, the only thing differing page to page was
  /// what it pointed at, and pointing somewhere else is precisely what a
  /// navigation is for.
  ///
  /// That stopped being true when the scroll segment grew a `_FULL` suffix.
  /// Scroll itself still travels per page, so a SCROLL page followed by a
  /// FIT page is one window that scrolled and then did not, which is also
  /// what a browser does. Maximize does not: a windowed browser absorbing a
  /// full one would have to change size mid-session with no animation to
  /// carry it, which is not a navigation, it is a different window. So the
  /// caller needs the segment rather than a yes.
  ///
  /// Returns the raw segment string rather than a parsed enum, so this file
  /// stays free of the presentation vocabulary the way it already is. Null
  /// means the next tag is not a BROWSER at all; the empty string means it is
  /// one with no scroll segment, which the caller resolves through the same
  /// default the request parser uses.
  String? peekNextBrowserScroll() {
    int i = charIndex;

    while (i < text.length) {
      final String c = text[i];

      if (c == ' ' || c == '\n' || c == '\t' || c == '\r') {
        i++;
        continue;
      }

      if (c != '[') return null;

      final match = tagRegex.matchAsPrefix(text, i) as RegExpMatch?;
      if (match == null) return null;

      if (match.namedGroup('line') != null) {
        i += match.end - match.start;
        continue;
      }

      if (match.namedGroup('browFolder') == null) return null;
      return match.namedGroup('browScroll') ?? '';
    }

    return null;
  }

  void setup({
    required String templateText,
    required Color fontColor,
    required Color bgColor,
    required double width,
    required double height,
    required double scale,
    required String fontPath,
    required double fontSize,
    required double lineSpacing,
    required double tracking,
    required double marginTop,
    required double marginSide,
  }) {
    this.templateText = ScriptParser.preprocessScript(templateText);

    this.fontColor = fontColor;
    this.bgColor = bgColor;
    this.width = width;
    this.height = height;
    this.scale = scale;

    marginX = marginSide * scale;
    marginY = marginTop * scale;
    baseLineSpacing = lineSpacing * scale;
    this.tracking = tracking * scale;

    baseFontSize = fontSize * scale;
    fontFamily = fontPath;

    _charWidthCache.clear();
    reset();
  }

  void reset() {
    text = templateText;
    charIndex = 0;
    frameCount = 0;
    globalCharIndex = 0;
    currentRawLine = 0;

    cursorX = marginX;
    cursorY = marginY;

    renderedLines.clear();
    currentLine = [];
    currentLineWidth = 0;

    currentAlign = "LEFT";
    currentFontSize = baseFontSize;
    currentLineSpacing = baseLineSpacing;

    charsPerFrame = 1;
    activePause = null;

    isRedacting = false;
    isScrambling = false;
    activeScramble = null;

    _endHoldStarted = false;

    activeBar = null;
    currentRegion = null;

    activeImgBand = null;

    _pendingPresentation = null;

    activeSvg = null;
    _photoStack.clear();
    _photoGate = null;
    
    _activeSprites.clear(); // Clear running sprites

    isFinished = false;
    penColor = fontColor;
    penBg = null;
    flashStyle = null;

    // Restore the RNG to its seed so scramble timing replays identically
    // across dry-runs, exports, and editor scrubbing.
    _random = math.Random(_scrambleSeed);
  }

  /// Clears whichever desktop presentation currently owns terminal time.
  void clearPresentationRequest() {
    _pendingPresentation = null;
  }

  /// Compatibility helpers for presentation-specific callers. Each one only
  /// clears when its own request type is active, so a stale cleanup cannot
  /// accidentally cancel a newer hand-off.
  void clearGalleryRequest() => pendingGallery = null;
  void clearAppRequest() => pendingApp = null;
  void clearBrowserRequest() => pendingBrowser = null;
  void clearCardRequest() => pendingCard = null;
  void clearDossierRequest() => pendingDossier = null;
  void clearTimelineRequest() => pendingTimeline = null;

  void wipeScreen() {
    renderedLines.clear();
    currentLine = [];
    currentLineWidth = 0;
    cursorY = marginY;
    cursorX = marginX;

    currentAlign = "LEFT";
    currentFontSize = baseFontSize;
    currentLineSpacing = baseLineSpacing;
    penColor = fontColor;
    penBg = null;
    flashStyle = null;
    currentRegion = null;
    
    _activeSprites.clear(); // Screen cleared, stop cycling

    // Any revealing [IMG] band whose line just got wiped has nothing left to
    // reveal into. Clearing the gate is sufficient because the line itself
    // was the only owner of its explicit start-frame reveal state.
    activeImgBand = null;

    // The [PHOTO] onion stack is part of the terminal canvas: an explicit
    // [WIPE] (or a scroll-off / overflow wipe, or an SVG takeover, all of
    // which route through here) clears every stacked layer at once. This is
    // the ONLY teardown for persisting stack layers.
    _photoStack.clear();
    _photoGate = null;
  }

  double _getCharWidth(String char, double size) {
    final key = "${char}_$size";
    if (_charWidthCache.containsKey(key)) {
      return _charWidthCache[key]!;
    }

    final span = TextSpan(
      text: char,
      style: TextStyle(
        fontFamily: fontFamily,
        fontFamilyFallback: const ['Courier', 'Consolas', 'Courier New', 'monospace'],
        fontSize: size,
        fontWeight: FontWeight.bold,
      ),
    );
    final tp = TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    _charWidthCache[key] = tp.width;
    return tp.width;
  }

  double _getNextWordWidth(int startIdx) {
    double w = 0;
    int i = startIdx;
    bool simRedact = isRedacting;
    double simSize = currentFontSize;

    while (i < text.length) {
      String c = text[i];
      if (c == '[') {
        final match = tagRegex.matchAsPrefix(text, i) as RegExpMatch?;
        if (match != null) {
          final redactGrp = match.namedGroup('redact');
          if (redactGrp != null) {
            simRedact = !redactGrp.startsWith('/');
          }
          final sizeGrp = match.namedGroup('size');
          if (sizeGrp != null) {
            simSize = sizeGrp == 'DEFAULT' ? baseFontSize : double.parse(sizeGrp) * scale;
          }
          i += match.end - match.start;
          continue;
        }
      }
      if (c == ' ' || c == '\n') break;
      String displayC = simRedact ? '█' : c;
      w += _getCharWidth(displayC, simSize) + tracking;
      i++;
    }
    return w;
  }
  
  void _advanceSprites() {
    for (final sprite in _activeSprites.values) {
      sprite.framesSinceLast++;
      if (sprite.framesSinceLast >= sprite.holdFrames) {
        sprite.framesSinceLast = 0;
        sprite.currentFrame = (sprite.currentFrame + 1) % sprite.frames.length;
        _rewriteSpriteLines(sprite);
      }
    }
  }

  /// Pushes a stack (persisting) [PHOTO] layer onto the onion stack and makes
  /// it the gating layer. Bounds depth at [kMaxPhotoStack] by dropping the
  /// oldest (bottom) layer, so the newest layer always shows and gates.
  void _pushPhoto(ActivePhotoShow show) {
    _photoStack.add(show);
    while (_photoStack.length > kMaxPhotoStack) {
      _photoStack.removeAt(0);
    }
    _photoGate = show;
  }

  List<LineData> _buildSpriteLines(_ActiveSprite s, int frameIndex) {
    final List<LineData> out = [];
    int charOffset = 0;
    
    for (final rawLine in s.frames[frameIndex]) {
      final List<CharData> chars = [];
      double lineWidth = 0;
      
      for (int i = 0; i < rawLine.length; i++) {
        final char = rawLine[i];
        final charW = _getCharWidth(char, s.fontSize) + s.tracking;
        chars.add(CharData(
          char: char,
          fgColor: s.fgColor,
          bgColor: s.bgColor,
          flashStyle: s.flashStyle,
          spatialIndex: s.startGlobalCharIndex + charOffset, // Maintains smooth WAVE effects
          fontSize: s.fontSize,
        ));
        lineWidth += charW;
        charOffset++;
      }
      
      out.add(LineData(
        chars: chars,
        align: s.align,
        spacing: s.lineSpacing,
        width: lineWidth,
      ));
    }
    return out;
  }

  void _rewriteSpriteLines(_ActiveSprite s) {
    // Safety check: if lines were pushed off screen by scrolling, don't crash.
    if (s.startLineIdx + s.lineCount > renderedLines.length) return;
    
    final newLines = _buildSpriteLines(s, s.currentFrame);
    for (int i = 0; i < s.lineCount; i++) {
      renderedLines[s.startLineIdx + i] = newLines[i];
    }
  }

  /// Queues a desktop presentation if [match] represents one.
  /// Presentation parameter decoding lives in presentation_requests.dart;
  /// the terminal owns only the suspension point.
  bool _tryQueuePresentation(RegExpMatch match) {
    final PresentationRequest? request = presentationRequestFromMatch(match);
    if (request == null) return false;
    _pendingPresentation = request;
    return true;
  }

  // -------------------------------------------------------------------
  // SVG & Photo show helpers
  // -------------------------------------------------------------------

  ActiveSvgShow? _buildSvgShow(RegExpMatch match) {
    Color resolveColor(String? rgbStr) {
      if (rgbStr == null) return penColor;
      final parts = rgbStr.split(',');
      return Color.fromARGB(255, int.parse(parts[0]), int.parse(parts[1]),
          int.parse(parts[2]));
    }

    final String? svgFile = match.namedGroup('svgFile');
    if (svgFile != null) {
      if (!_svgLibrary.containsKey(svgFile)) return null;
      final int hold = int.parse(match.namedGroup('svgHold') ?? '60');
      return ActiveSvgShow(
        steps: [SvgStep(key: svgFile, frames: math.max(hold, 1))],
        color: resolveColor(match.namedGroup('svgRgb')),
      );
    }

    final String? folder = match.namedGroup('svgfFolder');
    if (folder != null) {
      final List<String> files = _svgFolders[folder] ?? const [];
      // Keep only keys that actually parsed into the library.
      final List<String> usable =
          files.where(_svgLibrary.containsKey).toList();
      if (usable.isEmpty) return null;

      final int framesPer =
          math.max(int.parse(match.namedGroup('svgfFrames') ?? '4'), 1);
      final int cycles =
          math.max(int.parse(match.namedGroup('svgfCycles') ?? '3'), 1);

      final List<SvgStep> steps = [];
      for (int c = 0; c < cycles; c++) {
        for (final key in usable) {
          steps.add(SvgStep(key: key, frames: framesPer));
        }
      }
      return ActiveSvgShow(
        steps: steps,
        color: resolveColor(match.namedGroup('svgfRgb')),
      );
    }

    return null;
  }

  int _svgDudFrames(RegExpMatch match) {
    if (match.namedGroup('svgFile') != null) {
      return int.parse(match.namedGroup('svgHold') ?? '60');
    }
    final int framesPer = int.parse(match.namedGroup('svgfFrames') ?? '4');
    final int cycles = int.parse(match.namedGroup('svgfCycles') ?? '3');
    // Folder size unknown when it failed to load; assume one file.
    return math.max(framesPer * cycles, 1);
  }

  /// Builds a photo LAYER from a [PHOTO] match. The presence of the release
  /// segment flips it into STACK mode (persist until wipe, early gate);
  /// without it the layer is CLASSIC (block the full hold, then tear down) —
  /// byte-identical to the pre-stack behavior. Tint = the tag's rgb override
  /// or the pen color at fire time, same rule as SVG/IMG.
  ///
  /// [startFrame] is explicit because normal parser entry becomes visible on
  /// the next terminal frame, while classic chaining creates the next PHOTO
  /// after the current tick has already advanced and therefore CUTs in at the
  /// current terminal frame.
  ActivePhotoShow? _buildPhotoShow(
    RegExpMatch match, {
    required int startFrame,
  }) {
    final String? file = match.namedGroup('photoFile');
    if (file == null) return null;

    final String channel = match.namedGroup('photoChannel') ?? 'R';
    final String key = '$channel:$file';
    
    if (!_imgLibrary.containsKey(key)) return null;

    final int hold = int.parse(match.namedGroup('photoHold') ?? '120');
    Color c = penColor;
    
    final String? rgbStr = match.namedGroup('photoRgb');
    if (rgbStr != null) {
      final parts = rgbStr.split(',');
      c = Color.fromARGB(255, int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
    }

    // Release segment present -> stack (onion) layer; absent -> classic.
    final String? relStr = match.namedGroup('photoRelease');
    final bool stack = relStr != null;
    final int releasePercent = stack ? int.parse(relStr) : 100;

    return ActivePhotoShow(
      key: key,
      holdFrames: math.max(hold, 1),
      color: c,
      startFrame: startFrame,
      persist: stack,
      releasePercent: releasePercent,
    );
  }

  /// Frames a [PHOTO] dud (missing/undecodable asset, warned at setup) should
  /// burn so the timeline holds. A stack-mode dud burns only its GATED
  /// portion (so following content lands on the same frame either way);
  /// a classic dud burns the whole hold, exactly as before.
  int _photoDudFrames(RegExpMatch match) {
    final String? relStr = match.namedGroup('photoRelease');
    if (relStr != null) {
      return ActivePhotoShow.scanGate(int.parse(relStr));
    }
    return int.parse(match.namedGroup('photoHold') ?? '120');
  }

  /// CHAINING: Consumes the next SVG, SVGFLASH, or PHOTO tag if it immediately
  /// follows. Used only by CLASSIC teardown (SVG show end / classic photo hold
  /// end) to CUT into the next fullscreen stencil/photo without a wipe flash.
  ///
  /// Stack-mode PHOTO chaining does NOT go through here — a stack layer opens
  /// its gate early and tick() simply falls through to re-parse the next
  /// PHOTO tag, pushing it onto the stack.
  bool _tryConsumeChainedShow() {
    int i = charIndex;
    int pendingRawLine = currentRawLine;

    while (i < text.length) {
      final String c = text[i];
      if (c == ' ' || c == '\n' || c == '\t' || c == '\r') {
        i++; continue;
      }
      if (c != '[') return false;

      final match = tagRegex.matchAsPrefix(text, i) as RegExpMatch?;
      if (match == null) return false;

      if (match.namedGroup('line') != null) {
        pendingRawLine = int.parse(match.namedGroup('line')!);
        i += match.end - match.start;
        continue;
      }

      if (match.namedGroup('svgFile') != null || match.namedGroup('svgfFolder') != null) {
        final ActiveSvgShow? next = _buildSvgShow(match);
        if (next == null) return false;
        charIndex = i + (match.end - match.start);
        currentRawLine = pendingRawLine;
        activeSvg = next;
        // An SVG show is a fullscreen stencil takeover: clear the photo stack.
        _photoStack.clear();
        _photoGate = null;
        return true;
      }

      if (match.namedGroup('photoFile') != null) {
        final ActivePhotoShow? next = _buildPhotoShow(
          match,
          startFrame: frameCount,
        );
        if (next == null) return false;
        charIndex = i + (match.end - match.start);
        currentRawLine = pendingRawLine;
        activeSvg = null;
        // Classic CUT: the outgoing classic photo is fullscreen and gone;
        // the next becomes the sole layer (or the base of a fresh stack if
        // it happens to be a persisting layer).
        _photoStack
          ..clear()
          ..add(next);
        _photoGate = next;
        return true;
      }

      return false;
    }
    return false;
  }

  // -------------------------------------------------------------------
  // IMG band helper
  // -------------------------------------------------------------------

  /// Commits an [IMG] band into the line flow. Forces a newline if
  /// mid-typing (same as SPRITE), clamps the repeat count so the band fits
  /// inside the margins (min 1 copy), advances the cursor by the band's
  /// drawn height, and installs reveal state anchored to the first visible
  /// terminal frame.
  ///
  /// [releasePercent] is the % of this band's reveal at which the typing
  /// gate opens so the content AFTER the tag can begin — 100 (default) means
  /// block the whole reveal, exactly as bands behaved before. After early
  /// release the rendered line itself retains the start frame, so reveal
  /// continues without a separate live timing list.
  void _commitImgBand(
      ImgStencil stencil, int repeat, int framesPer, int releasePercent) {
    // Force newline if mid-typing.
    if (currentLine.isNotEmpty) {
      renderedLines.add(LineData(
        chars: List.from(currentLine),
        align: currentAlign,
        spacing: currentLineSpacing,
        width: currentLineWidth,
      ));
      currentLine.clear();
      currentLineWidth = 0;
      cursorY += currentLineSpacing;
      if (cursorY > height - marginY) wipeScreen();
    }

    final double tileW = stencil.pxWidth * scale;
    final double tileH = stencil.pxHeight * scale;
    final double maxW = width - marginX * 2;

    // Clamp the repeat count to the margins. Tiles butt together edge to
    // edge (a repeating pattern must be seamless), so band width is a
    // simple multiple. Always at least 1 copy, even if a single tile
    // overflows — the writer will see it and resize the source.
    int copies = math.max(repeat, 1);
    if (tileW > 0 && copies * tileW > maxW) {
      copies = math.max((maxW / tileW).floor(), 1);
    }

    final ImgBandState state = ImgBandState(
      framesPer: math.max(framesPer, 1),
      copies: copies,
      startFrame: frameCount + 1,
      releasePercent: releasePercent,
    );

    renderedLines.add(LineData(
      chars: const [],
      align: currentAlign,
      // Grid-locked: the band's line advances exactly its drawn height, so
      // stacked [IMG] tags tile vertically with no seams.
      spacing: tileH,
      width: copies * tileW,
      imgBand: ImgBandData(
        stencil: stencil,
        color: penColor, // Tint = pen color at tag-fire, same rule as SVG.
        drawScale: scale,
        state: state,
      ),
    ));

    cursorY += tileH;
    if (cursorY > height - marginY) wipeScreen();

    // Register only the typing gate. If the overflow check above just wiped
    // the screen, the band's line did not survive and there is nothing to
    // gate or reveal. Otherwise LineData owns the reveal state from here on.
    if (renderedLines.isNotEmpty && renderedLines.last.imgBand?.state == state) {
      activeImgBand = state;
    }
  }

  /// Advances exactly one deterministic engine frame.
  void tick() => _TerminalEngineTicking(this)._tickDeterministic();

  void _commitChar(String char, {BarInfo? barInfo}) {
    if (isRedacting && char != ' ' && char != '\n') {
      char = '█';
    }

    if (char != ' ' && char != '\n') {
      bool isWordStart = false;
      if (currentLine.isEmpty) {
        isWordStart = true;
      } else if (currentLine.last.char == ' ') {
        isWordStart = true;
      }

      if (isWordStart && currentLineWidth > 0) {
        double wordW = _getNextWordWidth(charIndex);
        if (currentLineWidth + wordW > (width - marginX * 2)) {
          renderedLines.add(LineData(
            chars: List.from(currentLine),
            align: currentAlign,
            spacing: currentLineSpacing,
            width: currentLineWidth,
          ));
          currentLine.clear();
          currentLineWidth = 0;
          cursorY += currentLineSpacing;
          if (cursorY > height - marginY) {
            wipeScreen();
          }
        }
      }
    }

    if (char == '\n') {
      renderedLines.add(LineData(
        chars: List.from(currentLine),
        align: currentAlign,
        spacing: currentLineSpacing,
        width: currentLineWidth,
      ));
      currentLine.clear();
      currentLineWidth = 0;
      cursorY += currentLineSpacing;
      if (cursorY > height - marginY) {
        wipeScreen();
      }
    } else {
      double charW = _getCharWidth(char, currentFontSize) + tracking;

      if (currentLineWidth + charW > (width - marginX * 2) && currentLineWidth > 0) {
        renderedLines.add(LineData(
          chars: List.from(currentLine),
          align: currentAlign,
          spacing: currentLineSpacing,
          width: currentLineWidth,
        ));
        currentLine.clear();
        currentLineWidth = 0;
        cursorY += currentLineSpacing;
        if (cursorY > height - marginY) {
          wipeScreen();
        }
      }

      globalCharIndex++;
      currentLine.add(CharData(
        char: char,
        fgColor: penColor,
        bgColor: penBg,
        flashStyle: flashStyle,
        barInfo: barInfo,
        spatialIndex: globalCharIndex,
        fontSize: currentFontSize,
        regionId: currentRegion,
      ));
      currentLineWidth += charW;
    }
  }
}
