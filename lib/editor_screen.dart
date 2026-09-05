// ./lib/editor_screen.dart

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'engine.dart';
import 'parser.dart';
import 'scene_engine.dart';
import 'scene_painter.dart';
import 'ui_theme.dart';
import 'audio_bed.dart';
import 'editor_node_workspace.dart';
import 'script_nodes.dart';
import 'script_ribbon.dart';
import 'script_pipeline.dart';
import 'editor_warmup.dart';
import 'diag.dart';
import 'editor_text_controller.dart';
import 'editor_tag_menu.dart'; // Added import for the tag menu
import 'script_lint.dart';
import 'edit_workspace.dart';
import 'structural_sequence.dart';
import 'structural_sequence_preview.dart';

/// Wraps ScenePainter for the editor preview. ScenePainter already always
/// repaints, but the editor keeps its own delegate so preview-specific
/// behavior stays contained to this file.
class _EditorPreviewPainter extends CustomPainter {
  final SceneEngine scene;
  final String fontFamily;

  _EditorPreviewPainter({required this.scene, required this.fontFamily});

  @override
  void paint(Canvas canvas, Size size) {
    ScenePainter(scene: scene, fontFamily: fontFamily).paint(canvas, size);
  }

  @override
  bool shouldRepaint(covariant _EditorPreviewPainter oldDelegate) => true;
}

class EditorScreen extends StatefulWidget {
  final String templatePath;
  final String initialText;
  final String fontFamily;

  /// Font families registered at startup from the workspace fonts folder.
  ///
  /// Passed down so the node panel's caption controls can offer a real
  /// dropdown instead of a free-text family name nobody can spell from
  /// memory. The editor itself does not use it.
  final List<String> availableFonts;

  final Color fontColor;
  final Color bgColor;
  final double engineWidth;
  final double engineHeight;
  final double engineScale;
  final double fontSize;
  final double lineSpacing;
  final double tracking;
  final double marginTop;
  final double marginSide;

  /// Absolute path of the project's images/ folder (wallpapers + galleries).
  final String imagesDir;

  /// Absolute path of the project's sprites/ folder.
  final String spritesDir;

  // --- Audio bed ---
  //
  // The editor borrows main's player rather than creating its own: two
  // players would mean two subprocess pipelines racing for the same sink,
  // and the sink would arbitrate by interleaving them. Ownership stays with
  // main, which is why this screen stops the bed but never disposes it.

  /// Null when no playback backend exists on this machine.
  final AudioBedPlayer? bedPlayer;

  /// Absolute path to the bed, or null when none is attached.
  final String? bedPath;

  final double bedGainDb;
  final PlaybackDevice? bedDevice;

  /// Music bed path, or null when no score is attached.
  ///
  /// Carried purely so the editor auditions the same mix the bake produces.
  /// It has no say in [bedTargetFrames] and never will: music is trimmed to
  /// picture rather than holding for it, so it cannot move a frame boundary
  /// and cannot invalidate a warm-up.
  final String? musicPath;

  /// Music gain in dB, applied before the sum. See audio_mix.dart for why
  /// the sum does not renormalize.
  final double musicGainDb;

  /// Music length in frames, for the ribbon's second audio lane. Reported,
  /// never used to decide a duration.
  final int musicFrames;

  /// Repeat the score until the picture ends.
  ///
  /// Fills, never extends: playback is still trimmed at picture end, so this
  /// changes what is heard under a short score and changes no frame count.
  final bool musicLoop;

  /// Music length in seconds, needed only to keep a running loop in phase
  /// while scrubbing. Zero when there is no score or the probe failed.
  ///
  /// Seconds rather than frames because the phase is handed to ffmpeg, and
  /// rounding a loop point to the frame grid would drift it a little further
  /// out of step on every repeat.
  final double musicDurationSec;

  /// Bed length in frames, forwarded to the engine so the simulated length
  /// here matches the bake exactly, tail included.
  final int bedTargetFrames;

  /// Called when the user leaves the editor. Passes the latest document text
  /// so the caller (main) can refresh its own parsed state.
  final void Function(String latestText) onClose;

  /// A simulation main prepared while the dashboard was idle, or null.
  ///
  /// OWNERSHIP TRANSFERS ON CONSTRUCTION, which is the opposite of the
  /// bedPlayer rule directly above and deliberately so. The player is a
  /// shared singleton backend that must outlive this screen. This is a
  /// disposable computation that happens to hold a decoded asset library,
  /// and if nobody takes responsibility for it, every open leaks one.
  ///
  /// So initState adopts it or disposes it, unconditionally, on the first
  /// frame. It is adopted only when its key matches what this screen
  /// computes from its own props; a mismatch means the document or the
  /// render settings moved after it was built. A stale warm is worse than
  /// no warm, because it would show a confident ribbon and frame count for
  /// a script that no longer exists.
  final EditorWarmup? warmup;

  const EditorScreen({
    super.key,
    required this.templatePath,
    required this.initialText,
    required this.fontFamily,
    this.availableFonts = const <String>[],
    required this.fontColor,
    required this.bgColor,
    required this.engineWidth,
    required this.engineHeight,
    required this.engineScale,
    required this.fontSize,
    required this.lineSpacing,
    required this.tracking,
    required this.marginTop,
    required this.marginSide,
    required this.imagesDir,
    required this.spritesDir,
    this.bedPlayer,
    this.bedPath,
    this.bedGainDb = 0.0,
    this.bedDevice,
    this.bedTargetFrames = 0,
    this.musicPath,
    this.musicGainDb = 0.0,
    this.musicFrames = 0,
    this.musicLoop = false,
    this.musicDurationSec = 0.0,
    this.warmup,
    required this.onClose,
  });

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final EditorTextController _textController;
  final ScrollController _scrollController = ScrollController();

  /// Either freshly constructed or adopted from a warm bundle, which is
  /// why it is not final. Assigned exactly once, in initState.
  late final SceneEngine _scene;

  final FocusNode _editorFocusNode = FocusNode();

  /// Keyboard owner while the preview is full frame.
  ///
  /// WHY ITS OWN NODE. Full frame removes the script TextField from the
  /// tree, and its FocusNode goes with it. Focus does not fall back to an
  /// ancestor on its own, and the root Focus is autofocus, which fires once
  /// at mount and never again. Without something surviving to hold focus,
  /// F11 would be one way: into full frame, and no key would come back out.
  final FocusNode _previewFocusNode = FocusNode();

  Timer? _debounce;
  Timer? _playTimer;

  /// Wall clock for playback. Frame position is derived from elapsed time
  /// rather than counted per callback, so the picture stays locked to the
  /// bed instead of sliding off it whenever a frame overruns.
  Stopwatch? _playClock;

  /// Frame playback resumed from, since the clock restarts at zero on every
  /// play and the current frame is rarely zero.
  int _playStartFrame = 0;

  int _totalFrames = 0;
  int _currentFrame = 0;
  bool _isPlaying = false;
  bool _isDirty = false;
  bool _isSimulating = false;
  String? _saveFlash; // Transient "Saved" / error message

  // --- Editor view state ---
  bool _isNodeMode = false;
  bool _isEditMode = false;

  /// The EDIT surface needs a playhead even before its media layer is wired
  /// into the terminal preview transport. This is transient authoring state,
  /// never project state, and it is deliberately not clamped to the terminal
  /// engine's [_totalFrames].
  int _editFrame = 0;

  bool get _isTextMode => !_isNodeMode && !_isEditMode;

  /// Preview fills the workspace, script pane hidden. Text mode only.
  ///
  /// The ribbon and transport deliberately stay: they live in the parent
  /// Column outside the workspace, so full frame is a decision about the
  /// workspace alone. Watching a cut without being able to scrub it or see
  /// how it is blocked out would be a worse view, not a bigger one.
  bool _isPreviewFull = false;

  /// Design system built from the phosphor of the script being edited.
  R3Theme get _t => R3Theme.of(widget.fontColor);

  /// Editor text metrics — shared by the TextField style and the
  /// scroll-to-match math so they can never drift apart.
  static final double _editorFontSize = sc(14.0);
  static const double _editorLineHeightMult = 1.4;

  /// The structural terminal ghost must inherit the same cursor rectangle as
  /// the real TerminalPainter. This is the same font fallback stack and the
  /// same baseline cache used by top-level PREVIEW's hand-off calculation.
  static const List<String> _terminalFontFallbacks = <String>[
    'Courier',
    'Consolas',
    'Courier New',
    'monospace',
  ];
  static final Map<(String, double), double> _terminalCursorBaselines =
      <(String, double), double>{};

  /// 0-based lines the linter flagged, refreshed with every simulation.
  Set<int> _lintLines = {};

  /// Full findings, so the warning strip can name the problem and jump to it.
  List<LintFinding> _lintFindings = const [];

  /// One document layout shared by the gutter and the jump-to-line math, so
  /// the two can never disagree about where a line sits.
  final _EditorLineLayout _lineLayout = _EditorLineLayout();

  /// The editing field's real content width, read from its RenderBox after
  /// layout. Computing it as (pane - gutter - gap) was close but not exact,
  /// and "close" is fatal here: a few pixels of difference changes where a
  /// line wraps, which puts the gutter a whole row out and compounds down
  /// the document. Measuring converges after one frame and then holds.
  final GlobalKey _fieldKey = GlobalKey();
  double _fieldWidth = 0;

  /// Workspace contents, scanned once when the editor opens. Drives the
  /// amber marking of tags whose asset does not exist. Reuses the same
  /// library and the same resolution rules the node workspace uses, so the
  /// two views cannot disagree about whether a reference is good.
  late NodeAssetLibrary _assets;

  void _syncFieldWidth() {
    final ctx = _fieldKey.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    if ((box.size.width - _fieldWidth).abs() > 0.5) {
      setState(() => _fieldWidth = box.size.width);
    }
  }

  // --- Search State ---
  bool _isSearching = false;
  String _searchQuery = "";
  int _matchCount = 0;
  int _currentSearchIndex = 0;
  final FocusNode _searchFocusNode = FocusNode();

  // --- Nuke-Style Tag Palette State ---
  bool _isTagMenuOpen = false;
  final FocusNode _tagSearchFocusNode = FocusNode();
  final GlobalKey<EditorTagMenuState> _tagMenuKey = GlobalKey<EditorTagMenuState>();

  /// Guards against stale async simulations: each _resimulate call bumps
  /// this, and any in-flight run whose generation no longer matches simply
  /// discards its result instead of clobbering a newer one.
  int _simGeneration = 0;

  /// Snapshot of the controller's text as of the last handled change,
  /// used to distinguish real edits from selection-only (click) changes.
  late String _lastText;

  /// The document line the cursor was last on. A click that changes the
  /// line triggers a preview jump; clicking around within a line does not.
  int _lastCursorLine = -1;

  /// _rawLineAtFrame[i] = the raw document line index that the engine
  /// is executing at frame i. Makes highlighting and click-to-jump exact.
  List<int> _rawLineAtFrame = [];

  /// Node blocks for the ribbon under the scrubber, rebuilt with each
  /// simulation. Replaced wholesale rather than mutated: the ribbon painter
  /// compares lists by identity to decide whether to repaint.
  List<RibbonBlock> _ribbonBlocks = const [];

  /// Node a double-tap on the ribbon asked to open, by document index.
  /// Consumed by the node workspace on mount and then held so the strip can
  /// draw it in accent while you are working on it.
  ///
  /// An index rather than an id, because ScriptNode ids come from a global
  /// counter: this screen's parse and the node workspace's parse of the
  /// same text produce disjoint id sets, so an id would never resolve on
  /// the other side.
  int? _ribbonSelectedNodeIndex;

  /// Safety cap: 20 minutes at engineFps. A malformed [PAUSE:huge] or
  /// runaway script can't lock the UI during re-simulation.
  // Simulation cap moved to editor_warmup.dart as kMaxSimFrames, so the
  // warm builder and this screen bound runaway scripts identically.

  static const Duration _debounceDelay = Duration(milliseconds: 250);

  @override
  void initState() {
    super.initState();
    _assets = NodeAssetLibrary.scan(widget.imagesDir, widget.spritesDir);
    _textController = EditorTextController(text: widget.initialText);
    _lastText = widget.initialText;

    _textController.addListener(_onControllerChanged);

    // ADOPT OR DISCARD. Main handed ownership over and dropped its own
    // reference, so exactly one of these branches must run. The discard
    // has to be unconditional on mismatch, or every open against a moved
    // document leaks a decoded asset library.
    final EditorWarmup? warm = widget.warmup;
    final EditorSimRequest req = _request(widget.initialText);
    final CompiledScript compiled = req.compile();

    final ScriptWarmKey want = req.warmKey(compiled);
    if (kProfileWarm) {
      if (warm == null) {
        diag('warm', 'editor: none offered -> cold open');
      } else if (warm.isSpent) {
        diag('warm', 'editor: offered bundle already spent');
      } else if (warm.key != want) {
        diag('warm', 'editor: KEY MISMATCH have=${warm.key.value} '
            'want=${want.value} font=${widget.fontFamily} '
            'bed=${widget.bedTargetFrames}');
      } else {
        diag('warm', 'editor: ADOPTED key=${want.value} '
            'frames=${warm.totalFrames}');
      }
    }

    if (warm != null && !warm.isSpent && warm.key == want) {
      _scene = warm.adopt();
      _totalFrames = warm.totalFrames;
      _rawLineAtFrame = warm.rawLineAtFrame;
      _ribbonBlocks = warm.ribbonBlocks;

      // runEditorSimulation left the engine parked at the final frame,
      // which is exactly where the editor opens. No replay and no await:
      // the first frame paints the last frame with the ribbon already
      // populated, which is the entire point of the exercise.
      _currentFrame = _totalFrames;
      _isSimulating = false;
      _updateHighlight();

      // Diagnostics are the only product of _resimulate a warm does not
      // carry, because they belong to the text buffer rather than to the
      // engine. Cheap regex passes, run inline.
      _refreshDiagnostics(widget.initialText);
    } else {
      warm?.dispose();
      _scene = SceneEngine();
      _resimulate(targetFrame: kMaxSimFrames); // Open parked on the final frame
    }
  }

  /// Bundles this screen's render settings with [docText].
  ///
  /// One constructor for the request means the warm key and the setup call
  /// are always computed from the same values. Main assembles the
  /// identical object from its own state, which is what makes comparing
  /// keys meaningful rather than hopeful.
  EditorSimRequest _request(String docText) => EditorSimRequest(
        docText: docText,
        fontColor: widget.fontColor,
        bgColor: widget.bgColor,
        engineWidth: widget.engineWidth,
        engineHeight: widget.engineHeight,
        engineScale: widget.engineScale,
        fontFamily: widget.fontFamily,
        fontSize: widget.fontSize,
        lineSpacing: widget.lineSpacing,
        tracking: widget.tracking,
        marginTop: widget.marginTop,
        marginSide: widget.marginSide,
        imagesDir: widget.imagesDir,
        spritesDir: widget.spritesDir,
        bedTargetFrames: widget.bedTargetFrames,
      );

  /// Gutter markers: lint findings and unresolved asset references.
  ///
  /// Split out of _resimulate because a warm open needs these without
  /// needing a simulation, and because they are pure functions of the text
  /// rather than of the engine.
  void _refreshDiagnostics(String docText) {
    _textController.updateAssetProblems(_computeAssetProblems(docText));

    final List<LintFinding> findings = ScriptLinter.lint(docText);
    _lintFindings = findings;
    // Findings are 1-based; gutter rows are 0-based.
    _lintLines = findings.map((f) => f.line - 1).toSet();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _playTimer?.cancel();
    // Stop, never dispose: the player belongs to main and outlives this
    // screen. Disposing it here would leave the menu with a dead backend.
    _stopBed();
    _searchFocusNode.dispose();
    _tagSearchFocusNode.dispose();
    _editorFocusNode.dispose();
    _previewFocusNode.dispose();
    _scrollController.dispose();
    _textController.removeListener(_onControllerChanged);
    _textController.dispose();
    // Owned outright, whether constructed here or adopted from a warm
    // bundle: ownership transferred on construction, so releasing it is
    // this screen's job either way.
    _scene.disposeImages();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Color Picker Dialog
  // ---------------------------------------------------------------------

  /// Color channels are doubles in current Flutter, but the tag grammar
  /// stores 0-255 integers and the sliders step in integers. Converting
  /// once on the way in keeps the picker working in the units it writes,
  /// instead of round-tripping through doubles at fifteen call sites.
  static int _chan255(double v) => (v * 255.0).round().clamp(0, 255);

  Future<void> _showColorPicker(int start, int end, Color initialColor) async {
    int red = _chan255(initialColor.r);
    int green = _chan255(initialColor.g);
    int blue = _chan255(initialColor.b);
    final t = _t;

    final bool? apply = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final Color selectedColor = Color.fromARGB(255, red, green, blue);
            return AlertDialog(
              title: Text("EDIT COLOR", style: t.value.copyWith(letterSpacing: 2)),
              content: SizedBox(
                width: sc(300),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: double.infinity,
                      height: sc(60),
                      decoration: BoxDecoration(
                        color: selectedColor,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: R3Theme.hairline, width: 1),
                      ),
                    ),
                    SizedBox(height: sc(6)),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        "$red,$green,$blue",
                        style: t.fine,
                      ),
                    ),
                    SizedBox(height: sc(14)),
                    _buildChannelSlider(t, "R", red, const Color(0xFFFF5555),
                        (v) {
                      setDialogState(() => red = v);
                    }),
                    _buildChannelSlider(t, "G", green, const Color(0xFF55FF88),
                        (v) {
                      setDialogState(() => green = v);
                    }),
                    _buildChannelSlider(t, "B", blue, const Color(0xFF5599FF),
                        (v) {
                      setDialogState(() => blue = v);
                    }),
                  ],
                ),
              ),
              actions: [
                R3Button("Cancel", theme: t, compact: true,
                    onPressed: () => Navigator.pop(ctx, false)),
                R3Button("Apply", theme: t, compact: true,
                    kind: R3ButtonKind.primary,
                    onPressed: () => Navigator.pop(ctx, true)),
              ],
            );
          },
        );
      },
    );

    if (apply == true) {
      final String newRgb = "$red,$green,$blue";
      final String currentText = _textController.text;
      final String newText = currentText.replaceRange(start, end, newRgb);

      _textController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: start + newRgb.length),
      );
    }
  }

  Widget _buildChannelSlider(R3Theme t, String label, int val,
      Color channelColor, ValueChanged<int> onChanged) {
    final double frac = (val / 255).clamp(0.0, 1.0);

    return Padding(
      padding: EdgeInsets.symmetric(vertical: sc(7)),
      child: Row(
        children: [
          SizedBox(
            width: sc(18),
            child: Text(label,
                style: t.value.copyWith(color: channelColor)),
          ),
          SizedBox(width: sc(8)),
          Expanded(
            child: LayoutBuilder(builder: (ctx, constraints) {
              final double w = constraints.maxWidth;

              void setFromDx(double dx) {
                final double nt = (dx / w).clamp(0.0, 1.0);
                onChanged((nt * 255).round());
              }

              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (d) => setFromDx(d.localPosition.dx),
                onTapDown: (d) => setFromDx(d.localPosition.dx),
                child: SizedBox(
                  height: sc(20),
                  child: Center(
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(height: 2, color: R3Theme.hairline),
                        FractionallySizedBox(
                          widthFactor: frac == 0 ? 0.001 : frac,
                          child: Container(
                              height: 2,
                              color: channelColor.withValues(alpha: 0.6)),
                        ),
                        Positioned(
                          left: (frac * w - 1).clamp(0.0, w - 2),
                          top: sc(-3),
                          child: Container(
                              width: 2, height: sc(8), color: channelColor),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
          SizedBox(width: sc(10)),
          SizedBox(
            width: sc(34),
            child: Text(val.toString(),
                textAlign: TextAlign.right, style: t.value),
          ),
        ],
      ),
    );
  }

  void _togglePreviewFull() {
    if (!_isTextMode) return;

    final bool goingFull = !_isPreviewFull;

    if (goingFull) {
      if (_isTagMenuOpen) _isTagMenuOpen = false;
      if (_isSearching) {
        _isSearching = false;
        _searchQuery = "";
        _matchCount = 0;
        _currentSearchIndex = 0;
        _textController.updateSearch("", 0);
      }
    }

    setState(() => _isPreviewFull = goingFull);

    if (goingFull) {
      _previewFocusNode.requestFocus();
    } else {
      _editorFocusNode.requestFocus();
    }
  }

  void _toggleSearch() {
    setState(() {
      _isSearching = !_isSearching;
      if (!_isSearching) {
        _searchQuery = "";
        _matchCount = 0;
        _currentSearchIndex = 0;
        _textController.updateSearch("", 0);
      }
    });
    if (_isSearching) {
      _searchFocusNode.requestFocus();
    }
  }

  void _onSearchChanged(String val) {
    setState(() {
      _searchQuery = val;
      if (_searchQuery.isEmpty) {
        _matchCount = 0;
      } else {
        _matchCount = RegExp(RegExp.escape(_searchQuery), caseSensitive: false)
            .allMatches(_textController.text)
            .length;
      }
      _currentSearchIndex = 0;
    });
    _textController.updateSearch(_searchQuery, _currentSearchIndex);
    _scrollToMatch();
  }

  void _nextSearchMatch() {
    if (_matchCount == 0) return;
    setState(() {
      _currentSearchIndex = (_currentSearchIndex + 1) % _matchCount;
    });
    _textController.updateSearch(_searchQuery, _currentSearchIndex);
    _scrollToMatch();
  }

  void _prevSearchMatch() {
    if (_matchCount == 0) return;
    setState(() {
      _currentSearchIndex =
          (_currentSearchIndex - 1 + _matchCount) % _matchCount;
    });
    _textController.updateSearch(_searchQuery, _currentSearchIndex);
    _scrollToMatch();
  }

  void _scrollToMatch() {
    if (_matchCount == 0 || _searchQuery.isEmpty) return;
    final matches = RegExp(RegExp.escape(_searchQuery), caseSensitive: false)
        .allMatches(_textController.text)
        .toList();

    if (_currentSearchIndex < matches.length) {
      final m = matches[_currentSearchIndex];
      _textController.selection = TextSelection(
        baseOffset: m.start,
        extentOffset: m.end,
      );

      if (_scrollController.hasClients) {
        final int line = _lineOfOffset(_textController.text, m.start);
        final double lineHeight = _editorFontSize * _editorLineHeightMult;
        double targetOffset = (line * lineHeight) - sc(80);
        if (targetOffset < 0) targetOffset = 0;

        final double maxScroll = _scrollController.position.maxScrollExtent;
        if (targetOffset > maxScroll) targetOffset = maxScroll;

        _scrollController.animateTo(
          targetOffset,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
        );
      }
    }
  }

  void _openTagMenu() {
    setState(() {
      _isTagMenuOpen = true;
    });
    _tagSearchFocusNode.requestFocus();
  }

  void _closeTagMenu() {
    setState(() {
      _isTagMenuOpen = false;
    });
    _editorFocusNode.requestFocus();
  }

  void _insertTag(TagSnippet snippet) {
    if (snippet.action != null) {
      _runTagAction(snippet.action!);
      _closeTagMenu();
      return;
    }

    final text = _textController.text;
    final selection = _textController.selection;
    final int start = selection.isValid && selection.start >= 0 ? selection.start : text.length;
    final int end = selection.isValid && selection.end >= 0 ? selection.end : text.length;
    final String newText = text.replaceRange(start, end, snippet.insertText);

    int nextCursor = start + snippet.insertText.length;
    TextSelection nextSelection = TextSelection.collapsed(offset: nextCursor);

    if (snippet.placeholder != null) {
      final int pIndex = snippet.insertText.indexOf(snippet.placeholder!);
      if (pIndex != -1) {
        nextSelection = TextSelection(
          baseOffset: start + pIndex,
          extentOffset: start + pIndex + snippet.placeholder!.length,
        );
      }
    }

    _textController.value = TextEditingValue(
      text: newText,
      selection: nextSelection,
    );

    _closeTagMenu();
  }

  void _runTagAction(TagAction action) {
    switch (action) {
      case TagAction.pauseToPlayhead:
        _pauseToPlayhead();
        break;
      case TagAction.splitPauseAtPlayhead:
        _splitPauseAtPlayhead();
        break;
    }
  }

  int? _frameAtLine(int line) {
    for (int f = 0; f < _rawLineAtFrame.length; f++) {
      if (_rawLineAtFrame[f] >= line) return f;
    }
    return null;
  }

  int _lineAtOffset(String text, int offset) {
    final int end = offset.clamp(0, text.length);
    int line = 0;
    for (int i = 0; i < end; i++) {
      if (text.codeUnitAt(i) == 0x0A) line++;
    }
    return line;
  }

  void _pauseToPlayhead() {
    if (_isSimulating || _totalFrames <= 0) {
      _toast('Still simulating');
      return;
    }

    final String text = _textController.text;
    final TextSelection sel = _textController.selection;
    final int caret = sel.isValid ? sel.start : text.length;

    final int line = _lineAtOffset(text, caret);
    final int? arrival = _frameAtLine(line);
    if (arrival == null) {
      _toast('The script never reaches this line');
      return;
    }

    final int frames = _currentFrame - arrival;
    if (frames <= 0) {
      _toast('Playhead is at $_currentFrame, this line already starts at '
          '$arrival. Move the playhead later.');
      return;
    }

    final String tag = '[PAUSE:$frames]';
    _textController.value = TextEditingValue(
      text: text.replaceRange(caret, caret, tag),
      selection: TextSelection.collapsed(offset: caret + tag.length),
    );
    _toast('Held $frames frames to reach the playhead');
  }

  RibbonBlock? _splittablePause() {
    if (_isSimulating || _totalFrames <= 0) return null;
    for (final RibbonBlock b in _ribbonBlocks) {
      if (b.type != 'PAUSE') continue;
      if (_currentFrame < b.startFrame || _currentFrame >= b.endFrame) {
        continue;
      }
      if (_currentFrame - b.startFrame < 1) return null;
      if (b.endFrame - _currentFrame < 1) return null;
      return b;
    }
    return null;
  }

  void _splitPauseAtPlayhead() {
    if (_isSimulating || _totalFrames <= 0) {
      _toast('Still simulating');
      return;
    }

    final RibbonBlock? hit = _splittablePause();
    if (hit == null) {
      _toast('No PAUSE under the playhead to split');
      return;
    }

    final int before = _currentFrame - hit.startFrame;
    final int after = hit.endFrame - _currentFrame;

    final List<ScriptNode> nodes = parseScriptToNodes(_textController.text);
    if (hit.nodeIndex < 0 || hit.nodeIndex >= nodes.length) {
      _toast('Document moved since the last simulation, try again');
      return;
    }

    int offset = 0;
    for (int i = 0; i < hit.nodeIndex; i++) {
      offset += nodes[i].rawText.length;
    }

    final ScriptNode node = nodes[hit.nodeIndex];
    final RegExp pauseTag = RegExp(r'\[PAUSE:\d+\]');
    final RegExpMatch? m = pauseTag.firstMatch(node.rawText);
    if (m == null) {
      _toast('Could not find the pause tag to split');
      return;
    }

    final String head = '[PAUSE:$before]';
    final String tail = '[PAUSE:$after]';
    final String replacement = '$head\n\n$tail';

    final int tagStart = offset + m.start;
    final int tagEnd = offset + m.end;

    _textController.value = TextEditingValue(
      text: _textController.text.replaceRange(tagStart, tagEnd, replacement),
      selection:
          TextSelection.collapsed(offset: tagStart + head.length + 1),
    );
    _toast('Split into $before and $after frames');
  }

  void _toast(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        duration: const Duration(milliseconds: 2200),
      ));
  }

  List<(int, int)> _computeAssetProblems(String text) {
    final List<(int, int)> out = [];

    for (final m in tagRegex.allMatches(text)) {
      String? g(String name) {
        try {
          return m.namedGroup(name);
        } catch (_) {
          return null;
        }
      }

      bool bad = false;
      void check(String? value, AssetSlot slot) {
        if (bad) return;
        final String v = (value ?? '').trim();
        if (v.isEmpty) return;
        if (!_assets.resolves(slot, v)) bad = true;
      }

      check(g('galFolder'), AssetSlot.imageFolder);
      check(g('vidFolder'), AssetSlot.imageFolder);
      check(g('appFolder'), AssetSlot.imageFolder);
      check(g('browFolder'), AssetSlot.imageFolder);
      check(g('dosFolder'), AssetSlot.imageFolder);
      check(g('tlStage'), AssetSlot.imageFolder);
      check(g('svgfFolder'), AssetSlot.svgFolder);

      check(g('cardImg'), AssetSlot.rasterFile);
      check(g('dosImg'), AssetSlot.rasterFile);
      check(g('imgFile'), AssetSlot.rasterFile);
      check(g('photoFile'), AssetSlot.rasterFile);
      check(g('svgFile'), AssetSlot.svgFile);

      check(g('spritePath'), AssetSlot.spriteFile);
      check(g('spriteOff'), AssetSlot.spriteFile);

      if ((g('configKey') ?? '').toUpperCase() == 'DESKTOP') {
        check(g('configVal'), AssetSlot.rasterFile);
      }

      if (!bad) continue;

      final int close = text.indexOf(']', m.start);
      out.add((m.start, close < 0 ? m.end : close + 1));
    }

    return out;
  }

  void _jumpToLine(int line) {
    if (!_scrollController.hasClients) return;

    final double y = _lineLayout.yForLine(line);
    final double viewport = _scrollController.position.viewportDimension;
    final double target = (y - viewport / 3)
        .clamp(0.0, _scrollController.position.maxScrollExtent);

    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );

    final List<int> starts = [0];
    final String text = _textController.text;
    for (int i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 10) starts.add(i + 1);
    }
    if (line >= 0 && line < starts.length) {
      _textController.selection =
          TextSelection.collapsed(offset: starts[line]);
    }
  }

  Future<void> _resimulate({required int targetFrame}) async {
    if (_isPlaying) _stopPlayback();

    final int gen = ++_simGeneration;
    final String docText = _textController.text;
    _refreshDiagnostics(docText);

    setState(() => _isSimulating = true);

    final EditorSimResult sim =
        await runEditorSimulation(_scene, _request(docText));

    if (gen != _simGeneration || !mounted) return;

    final int total = sim.totalFrames;
    _totalFrames = total;
    _rawLineAtFrame = sim.rawLineAtFrame;
    _ribbonBlocks = sim.ribbonBlocks;

    final int clamped = targetFrame.clamp(0, _totalFrames);
    if (clamped != total) {
      _scene.reset();
      for (int i = 0; i < clamped; i++) {
        _scene.tick();
      }
    }
    _currentFrame = clamped;
    _updateHighlight();

    if (_isSearching && _searchQuery.isNotEmpty) {
      _matchCount = RegExp(RegExp.escape(_searchQuery), caseSensitive: false)
          .allMatches(_textController.text)
          .length;
    }

    if (mounted) setState(() => _isSimulating = false);
  }

  void _updateHighlight() {
    if (_rawLineAtFrame.isEmpty || _currentFrame >= _rawLineAtFrame.length) {
      _textController.updateHighlight(-1);
      return;
    }
    _textController.updateHighlight(_rawLineAtFrame[_currentFrame]);
  }

  void _seek(int frame) {
    if (_isSimulating) return;
    final int target = frame.clamp(0, _totalFrames);
    if (target < _currentFrame) {
      _scene.reset();
      _currentFrame = 0;
    }
    while (_currentFrame < target) {
      _scene.tick();
      _currentFrame++;
    }
    _updateHighlight();
    setState(() {});
  }

  void _jumpToCursorLine(int lineIdx) {
    if (_isSimulating || _rawLineAtFrame.isEmpty) return;

    int targetFrame = -1;

    for (int i = 0; i < _rawLineAtFrame.length; i++) {
      if (_rawLineAtFrame[i] == lineIdx) {
        targetFrame = i;
        break;
      }
    }

    if (targetFrame == -1) {
      for (int i = 0; i < _rawLineAtFrame.length; i++) {
        if (_rawLineAtFrame[i] > lineIdx) {
          targetFrame = i;
          break;
        }
      }
    }

    if (targetFrame != -1) {
      _stopPlayback();
      _seek(targetFrame);
    }
  }

  void _startBedAt(int frame) {
    final AudioBedPlayer? player = widget.bedPlayer;
    final String? bed = widget.bedPath;
    final String? music = widget.musicPath;
    if (player == null) return;

    final String? primary = bed ?? music;
    if (primary == null) return;
    final bool bedIsPrimary = bed != null;

    final int remaining = _totalFrames - frame;

    unawaited(player
        .play(primary,
            startSec: frame / engineFps,
            gainDb: bedIsPrimary ? widget.bedGainDb : widget.musicGainDb,
            loop: bedIsPrimary ? false : widget.musicLoop,
            device: widget.bedDevice,
            musicPath: bedIsPrimary ? music : null,
            musicGainDb: widget.musicGainDb,
            musicLoop: widget.musicLoop,
            musicSeekSec: widget.musicLoop
                ? loopedSeek(frame / engineFps, widget.musicDurationSec)
                : null,
            durationSec: remaining > 0 ? remaining / engineFps : null)
        .catchError((_) {}));
  }

  void _stopBed() {
    widget.bedPlayer?.stop();
  }

  void _togglePlay() {
    if (_isPlaying) {
      _stopPlayback();
      return;
    }
    if (_isSimulating) return;

    if (_currentFrame >= _totalFrames) {
      _scene.reset();
      _currentFrame = 0;
      _updateHighlight();
    }

    _isPlaying = true;
    _playStartFrame = _currentFrame;
    _playClock = Stopwatch()..start();

    _startBedAt(_currentFrame);

    _playTimer = Timer.periodic(const Duration(milliseconds: 8), (_) {
      if (!mounted) return;

      final Stopwatch? clock = _playClock;
      if (clock == null) return;

      final int target = _playStartFrame +
          (clock.elapsedMicroseconds * engineFps) ~/
              Duration.microsecondsPerSecond;

      if (target >= _totalFrames) {
        while (_currentFrame < _totalFrames) {
          _scene.tick();
          _currentFrame++;
        }
        _updateHighlight();
        _stopPlayback();
        return;
      }

      int behind = target - _currentFrame;
      if (behind <= 0) return;
      if (behind > engineFps) behind = engineFps;

      for (int i = 0; i < behind; i++) {
        _scene.tick();
        _currentFrame++;
      }
      _updateHighlight();
      if (mounted) setState(() {});
    });

    setState(() {});
  }

  void _stopPlayback() {
    _playTimer?.cancel();
    _playTimer = null;
    _playClock = null;
    _isPlaying = false;
    _stopBed();
    if (mounted) setState(() {});
  }

  void _onAssetsChanged() {
    _debounce?.cancel();
    _debounce = Timer(_debounceDelay, () {
      if (!mounted) return;
      _resimulate(targetFrame: _currentFrame);
    });
  }

  void _openNodeFromRibbon(int nodeIndex) {
    _stopPlayback();
    setState(() {
      _ribbonSelectedNodeIndex = nodeIndex;
      _isNodeMode = true;
      _isEditMode = false;
      _isPreviewFull = false;
    });
  }

  void _onControllerChanged() {
    final String text = _textController.text;

    if (text != _lastText) {
      _lastText = text;
      _isDirty = true;
      _saveFlash = null;
      _stopPlayback();
      _debounce?.cancel();
      _debounce = Timer(_debounceDelay, () {
        _resimulate(targetFrame: kMaxSimFrames);
      });
      _lastCursorLine = _lineOfOffset(text, _textController.selection.baseOffset);
      return;
    }

    final int offset = _textController.selection.baseOffset;
    if (offset < 0) return;
    final int line = _lineOfOffset(text, offset);
    if (line != _lastCursorLine) {
      _lastCursorLine = line;
      _jumpToCursorLine(line);
    }
  }

  int _lineOfOffset(String text, int offset) {
    if (offset <= 0) return 0;
    final int end = offset.clamp(0, text.length);
    int count = 0;
    for (int i = 0; i < end; i++) {
      if (text.codeUnitAt(i) == 10) count++;
    }
    return count;
  }

  void _save() {
    try {
      File(widget.templatePath).writeAsStringSync(_textController.text);
      setState(() {
        _isDirty = false;
        _saveFlash = 'Saved';
      });
    } catch (e) {
      setState(() => _saveFlash = 'Save failed: $e');
    }
  }

  void _close() {
    _stopPlayback();
    widget.onClose(_textController.text);
  }

  void _setEditorView(String label) {
    final bool nodeMode = label == 'NODES';
    final bool editMode = label == 'EDIT';
    final bool alreadyActive =
        (label == 'TEXT' && _isTextMode) ||
        (nodeMode && _isNodeMode) ||
        (editMode && _isEditMode);
    if (alreadyActive) return;

    _stopPlayback();
    final bool clearSearch = _isSearching;

    setState(() {
      _isNodeMode = nodeMode;
      _isEditMode = editMode;
      _isPreviewFull = false;
      _isTagMenuOpen = false;
      if (_isSearching) {
        _isSearching = false;
        _searchQuery = '';
        _matchCount = 0;
        _currentSearchIndex = 0;
      }
    });

    if (clearSearch) _textController.updateSearch('', 0);

    if (label == 'TEXT') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _editorFocusNode.requestFocus();
      });
    }
  }

  Widget _buildViewToggle(String label, bool isActive) {
    return InkWell(
      onTap: () => _setEditorView(label),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: sc(12), vertical: sc(4)),
        color: isActive ? _t.accentDim : Colors.transparent,
        child: Text(
          label,
          style: _t.micro.copyWith(
            color: isActive ? _t.accent : R3Theme.textDim,
          ),
        ),
      ),
    );
  }

  Widget _buildEditWorkspace() {
    return EditWorkspace(
      source: _textController.text,
      currentFrame: _editFrame,
      voiceFrames: widget.bedTargetFrames,
      musicFrames: widget.musicFrames,
      musicLoops: widget.musicLoop,
      theme: _t,
      onSourceChanged: (String newText) {
        if (_textController.text == newText) return;
        _textController.text = newText;
        if (mounted) {
          setState(() {
            _isDirty = true;
            _saveFlash = null;
          });
        }
      },
      onSeek: (int frame) {
        if (!mounted) return;
        setState(() => _editFrame = frame);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    final String fileName = widget.templatePath.split(Platform.pathSeparator).last;

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.f11) {
            _togglePreviewFull();
            return KeyEventResult.handled;
          }

          if (event.logicalKey == LogicalKeyboardKey.tab &&
              _isTextMode &&
              !_isPreviewFull) {
            if (!_isTagMenuOpen) {
              _openTagMenu();
            } else {
              _tagMenuKey.currentState?.cycleSelection();
            }
            return KeyEventResult.handled;
          }

          if (event.logicalKey == LogicalKeyboardKey.escape) {
            if (_isTagMenuOpen) {
              _closeTagMenu();
            } else if (_isSearching) {
              _toggleSearch();
            } else if (_isPreviewFull) {
              _togglePreviewFull();
            } else {
              _close();
            }
            return KeyEventResult.handled;
          }

          if (event.logicalKey == LogicalKeyboardKey.keyF &&
              (HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed)) {
            if (_isPreviewFull) _togglePreviewFull();
            if (_isTextMode && !_isSearching) {
              _toggleSearch();
            } else if (_isTextMode) {
              _searchFocusNode.requestFocus();
            }
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: Column(
        children: [
          Container(
            padding: EdgeInsets.symmetric(horizontal: sc(14), vertical: sc(8)),
            decoration: const BoxDecoration(
              color: R3Theme.panel,
              border: Border(bottom: BorderSide(color: R3Theme.hairline)),
            ),
            child: Row(
              children: [
                R3MicroLabel("Editor", theme: t, accent: true),
                SizedBox(width: sc(10)),
                Container(width: 1, height: sc(16), color: R3Theme.hairline),
                SizedBox(width: sc(10)),
                Text(fileName, style: t.value),
                if (_isDirty) ...[
                  SizedBox(width: sc(8)),
                  const R3Tally(state: R3TallyState.warn),
                ],

                SizedBox(width: sc(20)),
                Container(
                  decoration: BoxDecoration(
                    color: R3Theme.bg,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: R3Theme.hairline),
                  ),
                  child: Row(
                    children: [
                      _buildViewToggle("TEXT", _isTextMode),
                      _buildViewToggle("NODES", _isNodeMode),
                      _buildViewToggle("EDIT", _isEditMode),
                    ],
                  ),
                ),

                SizedBox(width: sc(14)),
                if (_saveFlash != null)
                  Text(
                    _saveFlash!.toUpperCase(),
                    style: t.micro.copyWith(
                      color: _saveFlash == 'Saved' ? R3Theme.okGreen : R3Theme.danger,
                    ),
                  ),

                if (_saveFlash == null &&
                    (_lintFindings.isNotEmpty || _scene.warnings.isNotEmpty))
                  Expanded(
                    child: Builder(builder: (ctx) {
                      final bool isLint = _lintFindings.isNotEmpty;
                      final String msg = isLint
                          ? _lintFindings.first.label
                          : _scene.warnings.first;
                      final String suffix = (isLint && _lintFindings.length > 1)
                          ? '  (+${_lintFindings.length - 1} more)'
                          : '';

                      final Widget label = Text(
                        '$msg$suffix',
                        overflow: TextOverflow.ellipsis,
                        style: t.fine.copyWith(
                          color: isLint ? R3Theme.danger : R3Theme.warn,
                          decoration:
                              isLint ? TextDecoration.underline : null,
                        ),
                      );

                      if (!isLint || !_isTextMode) return label;
                      return MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: () => _jumpToLine(_lintFindings.first.line - 1),
                          child: Tooltip(
                            message: 'Jump to line ${_lintFindings.first.line}',
                            child: label,
                          ),
                        ),
                      );
                    }),
                  ),

                if (_saveFlash != null ||
                    (_lintFindings.isEmpty && _scene.warnings.isEmpty))
                  const Spacer(),

                if (_isSimulating && _isTextMode)
                  Padding(
                    padding: EdgeInsets.only(right: sc(14)),
                    child: SizedBox(
                      width: sc(13),
                      height: sc(13),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: t.accentDim,
                      ),
                    ),
                  ),

                if (_isTextMode && !_isPreviewFull)
                  InkWell(
                    onTap: _toggleSearch,
                    borderRadius: BorderRadius.circular(3),
                    child: Tooltip(
                      message: "Find (Ctrl+F)",
                      child: Padding(
                        padding: EdgeInsets.all(sc(5)),
                        child: Icon(Icons.search, size: sc(17), color: R3Theme.textMid),
                      ),
                    ),
                  ),

                if (_isTextMode)
                  InkWell(
                    onTap: _togglePreviewFull,
                    borderRadius: BorderRadius.circular(3),
                    child: Tooltip(
                      message: _isPreviewFull
                          ? "Show script (F11)"
                          : "Full preview (F11)",
                      child: Padding(
                        padding: EdgeInsets.all(sc(5)),
                        child: Icon(
                          _isPreviewFull
                              ? Icons.fullscreen_exit
                              : Icons.fullscreen,
                          size: sc(17),
                          color: _isPreviewFull ? t.accent : R3Theme.textMid,
                        ),
                      ),
                    ),
                  ),

                SizedBox(width: sc(8)),
                R3Button(
                  "Save",
                  theme: t,
                  compact: true,
                  kind: R3ButtonKind.primary,
                  onPressed: _isDirty ? _save : null,
                ),
                SizedBox(width: sc(8)),
                R3Button("Back (Esc)", theme: t, compact: true, onPressed: _close),
              ],
            ),
          ),

          Expanded(
            child: _isEditMode
                ? _buildEditWorkspace()
                : _isNodeMode
                    ? EditorNodeWorkspace(
                        initialText: _textController.text,
                        theme: t,
                        highlightedLine: _textController.highlightedLine,
                        imagesDir: widget.imagesDir,
                        spritesDir: widget.spritesDir,
                        availableFonts: widget.availableFonts,
                        onAssetsChanged: _onAssetsChanged,
                        initialSelectedNodeIndex: _ribbonSelectedNodeIndex,
                        onTextChanged: (newText) {
                          if (_textController.text != newText) {
                            _textController.text = newText;
                            _isDirty = true;
                          }
                        },
                      )
                    : _buildTextWorkspace(),
          ),

          if (_isTextMode)
            Container(
              padding: EdgeInsets.symmetric(horizontal: sc(14), vertical: sc(8)),
              decoration: const BoxDecoration(
                color: R3Theme.panel,
                border: Border(top: BorderSide(color: R3Theme.hairline)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ScriptRibbon(
                    blocks: _ribbonBlocks,
                    currentFrame: _currentFrame,
                    totalFrames: _totalFrames,
                    theme: t,
                    selectedNodeIndex: _ribbonSelectedNodeIndex,
                    bedFrames: widget.bedTargetFrames,
                    musicFrames: widget.musicFrames,
                    musicLoops: widget.musicLoop,
                    simulating: _isSimulating || _totalFrames <= 0,
                    onSeek: (f) {
                      _stopPlayback();
                      _seek(f);
                    },
                    onOpenNode: _openNodeFromRibbon,
                  ),
                  SizedBox(height: sc(8)),
                  Row(
                    children: [
                      InkWell(
                        onTap: (_totalFrames > 0 && !_isSimulating) ? _togglePlay : null,
                        borderRadius: BorderRadius.circular(3),
                        child: Container(
                          padding: EdgeInsets.all(sc(5)),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(3),
                            border: Border.all(
                              color: _isPlaying ? t.accentDim : R3Theme.hairline,
                            ),
                            color: _isPlaying ? t.accentFaint : Colors.transparent,
                          ),
                          child: Icon(
                            _isPlaying ? Icons.pause : Icons.play_arrow,
                            size: sc(17),
                            color: (_totalFrames > 0 && !_isSimulating)
                                ? (_isPlaying ? t.accent : R3Theme.textMid)
                                : R3Theme.textDim,
                          ),
                        ),
                      ),
                      SizedBox(width: sc(6)),
                      _buildSplitPauseButton(t),
                      SizedBox(width: sc(12)),
                      Expanded(child: _buildScrubber(t)),
                      SizedBox(width: sc(12)),
                      _buildBedReadout(t),
                      Text("$_currentFrame / $_totalFrames", style: t.value),
                      SizedBox(width: sc(8)),
                      Text(
                        "${(_currentFrame / engineFps).toStringAsFixed(1)}S",
                        style: t.micro,
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  StructuralSequencePlacement? _activeStructuralPlacement() {
    if (_rawLineAtFrame.isEmpty ||
        _currentFrame < 0 ||
        _currentFrame >= _rawLineAtFrame.length) {
      return null;
    }

    final int line = _rawLineAtFrame[_currentFrame];
    final List<StructuralSequencePlacement> placements =
        parseStructuralSequencePlacements(_textController.text);
    for (final StructuralSequencePlacement placement in placements) {
      if (placement.lineIndex == line && placement.resolves) {
        return placement;
      }
    }
    return null;
  }

  int _structuralLocalFrame(StructuralSequencePlacement placement) {
    if (_rawLineAtFrame.isEmpty || _currentFrame >= _rawLineAtFrame.length) {
      return 0;
    }

    int first = _currentFrame;
    while (first > 0 &&
        _rawLineAtFrame[first - 1] == placement.lineIndex) {
      first--;
    }

    return (_currentFrame - first)
        .clamp(0, placement.durationFrames - 1)
        .toInt();
  }

  Size _terminalCursorFraction() {
    final terminal = _scene.terminal;
    final double fontSize = terminal.currentFontSize;
    final (String, double) key = (widget.fontFamily, fontSize);

    double? baseline = _terminalCursorBaselines[key];
    if (baseline == null) {
      final TextPainter ref = TextPainter(
        text: TextSpan(
          text: 'M',
          style: TextStyle(
            fontFamily: widget.fontFamily,
            fontFamilyFallback: _terminalFontFallbacks,
            fontSize: fontSize,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      ref.layout();
      baseline = ref.computeDistanceToActualBaseline(TextBaseline.alphabetic);
      ref.dispose();
      _terminalCursorBaselines[key] = baseline;
    }

    final double engineWidth = terminal.width > 0.0 ? terminal.width : 1.0;
    final double engineHeight = terminal.height > 0.0 ? terminal.height : 1.0;

    // Mirror TerminalPainter exactly. StructuralSequencePreview then applies
    // one uniform geometric scale as the terminal pulls back, so neither the
    // initial hand-off nor the animated cursor can change aspect.
    return Size(
      (fontSize * 0.5) / engineWidth,
      (baseline * 0.78) / engineHeight,
    );
  }

  Widget _buildPreviewPane() {
    final StructuralSequencePlacement? placement =
        _activeStructuralPlacement();
    if (placement != null) {
      return StructuralSequencePreview(
        rawDocument: _textController.text,
        placement: placement,
        localFrame: _structuralLocalFrame(placement),
        isPlaying: _isPlaying,
        theme: _t,
        wallpaper: _scene.wallpaper,
        terminalCursorFraction: _terminalCursorFraction(),
      );
    }

    return Container(
      color: Colors.black,
      child: CustomPaint(
        size: Size.infinite,
        painter:
            _EditorPreviewPainter(scene: _scene, fontFamily: widget.fontFamily),
      ),
    );
  }

  Widget _buildTextWorkspace() {
    final t = _t;

    if (_isPreviewFull) {
      return Focus(
        focusNode: _previewFocusNode,
        child: _buildPreviewPane(),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 2,
          child: Container(
            color: R3Theme.bg,
            child: Column(
              children: [
                if (_isSearching)
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: sc(10), vertical: sc(4)),
                    decoration: const BoxDecoration(
                      color: R3Theme.panel,
                      border: Border(bottom: BorderSide(color: R3Theme.hairline)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.search, size: sc(14), color: R3Theme.textDim),
                        SizedBox(width: sc(10)),
                        Expanded(
                          child: TextField(
                            focusNode: _searchFocusNode,
                            onChanged: _onSearchChanged,
                            decoration: const InputDecoration(
                              isDense: true,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              filled: false,
                              hintText: "Search...",
                            ),
                            style: t.value,
                          ),
                        ),
                        if (_searchQuery.isNotEmpty)
                          Text(
                            _matchCount == 0
                                ? "NO RESULTS"
                                : "${_currentSearchIndex + 1} OF $_matchCount",
                            style: t.micro,
                          ),
                        SizedBox(width: sc(4)),
                        InkWell(
                          onTap: _prevSearchMatch,
                          child: Padding(
                            padding: EdgeInsets.all(sc(4)),
                            child: Icon(
                              Icons.keyboard_arrow_up,
                              size: sc(17),
                              color: R3Theme.textMid,
                            ),
                          ),
                        ),
                        InkWell(
                          onTap: _nextSearchMatch,
                          child: Padding(
                            padding: EdgeInsets.all(sc(4)),
                            child: Icon(
                              Icons.keyboard_arrow_down,
                              size: sc(17),
                              color: R3Theme.textMid,
                            ),
                          ),
                        ),
                        InkWell(
                          onTap: _toggleSearch,
                          child: Padding(
                            padding: EdgeInsets.all(sc(4)),
                            child: Icon(
                              Icons.close,
                              size: sc(15),
                              color: R3Theme.textMid,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                Expanded(
                  child: Stack(
                    children: [
                      Padding(
                        padding: EdgeInsets.all(sc(10)),
                        child: LayoutBuilder(
                          builder: (ctx, constraints) {
                            final TextStyle editorStyle = TextStyle(
                              fontFamily: 'monospace',
                              fontFamilyFallback: R3Theme.monoStack,
                              fontSize: _editorFontSize,
                              height: _editorLineHeightMult,
                              color: const Color(0xFFD0D0DA),
                            );

                            final int lineCount =
                                '\n'.allMatches(_textController.text).length + 1;
                            final double gutterW =
                                sc(18) + sc(8.0) * '$lineCount'.length;
                            final double gap = sc(10);
                            final double estimate =
                                constraints.maxWidth - gutterW - gap;
                            final double textW =
                                _fieldWidth > 0 ? _fieldWidth : estimate;

                            WidgetsBinding.instance
                                .addPostFrameCallback((_) => _syncFieldWidth());

                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                SizedBox(
                                  width: gutterW,
                                  child: AnimatedBuilder(
                                    animation: _scrollController,
                                    builder: (_, _) => CustomPaint(
                                      painter: _GutterPainter(
                                        layout: _lineLayout,
                                        text: _textController.text,
                                        scrollOffset:
                                            _scrollController.hasClients
                                                ? _scrollController.offset
                                                : 0.0,
                                        textWidth: textW,
                                        style: editorStyle,
                                        lineHeight: _editorFontSize *
                                            _editorLineHeightMult,
                                        activeLine:
                                            _textController.highlightedLine,
                                        problemLines: _lintLines,
                                        accent: t.accent,
                                      ),
                                    ),
                                  ),
                                ),
                                SizedBox(width: gap),
                                Expanded(
                                  child: TextField(
                                    key: _fieldKey,
                                    focusNode: _editorFocusNode,
                                    controller: _textController,
                                    scrollController: _scrollController,
                                    cursorColor: t.accent,
                                    cursorWidth: 2.5,
                                    cursorRadius: const Radius.circular(2),
                                    maxLines: null,
                                    expands: true,
                                    onTap: () {
                                      final SwatchSpan? hit =
                                          _textController.swatchAt(
                                              _textController
                                                  .selection.baseOffset);
                                      if (hit != null) {
                                        _showColorPicker(
                                            hit.start, hit.end, hit.color);
                                      }
                                    },
                                    textAlignVertical: TextAlignVertical.top,
                                    keyboardType: TextInputType.multiline,
                                    style: editorStyle,
                                    decoration: const InputDecoration(
                                      border: InputBorder.none,
                                      enabledBorder: InputBorder.none,
                                      focusedBorder: InputBorder.none,
                                      filled: false,
                                      isDense: true,
                                      contentPadding: EdgeInsets.zero,
                                      hintText:
                                          'Type your script here... (Hit TAB for tags)',
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                      if (_isTagMenuOpen)
                        Positioned.fill(
                          child: GestureDetector(
                            onTap: _closeTagMenu,
                            behavior: HitTestBehavior.opaque,
                            child: Container(
                              color: Colors.black.withValues(alpha: 0.4),
                              alignment: Alignment.topCenter,
                              padding: EdgeInsets.only(top: sc(30)),
                              child: GestureDetector(
                                onTap: () {},
                                child: EditorTagMenu(
                                  key: _tagMenuKey,
                                  theme: t,
                                  searchFocusNode: _tagSearchFocusNode,
                                  onTagSelected: _insertTag,
                                  onClose: _closeTagMenu,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Container(width: 1, color: R3Theme.hairline),
        Expanded(
          flex: 3,
          child: _buildPreviewPane(),
        ),
      ],
    );
  }

  Widget _buildBedReadout(R3Theme t) {
    final int bed = widget.bedTargetFrames;
    if (bed <= 0) return const SizedBox.shrink();

    final bool known = _totalFrames > 0;
    final int overhang = _totalFrames - bed;
    final bool bedDrivesLength = overhang <= 0;
    final bool short = overhang < kEndHoldFrames;

    final String label = !known
        ? ""
        : (bedDrivesLength
            ? "VO OVERRUNS SCRIPT"
            : "+${(overhang / engineFps).toStringAsFixed(1)}S AFTER VO");

    final Color color = !known
        ? R3Theme.hairline
        : (bedDrivesLength
            ? R3Theme.danger
            : (short ? t.accent : R3Theme.textDim));

    return SizedBox(
      width: sc(150),
      child: Padding(
        padding: EdgeInsets.only(right: sc(12)),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            Icon(Icons.graphic_eq, size: sc(13), color: color),
            SizedBox(width: sc(5)),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: t.micro.copyWith(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSplitPauseButton(R3Theme t) {
    final RibbonBlock? target = _splittablePause();
    final bool enabled = target != null;

    final String tip = enabled
        ? 'Split this pause at the playhead '
            '(${_currentFrame - target.startFrame} / '
            '${target.endFrame - _currentFrame})'
        : 'Park the playhead inside a PAUSE to split it';

    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: enabled ? _splitPauseAtPlayhead : null,
        borderRadius: BorderRadius.circular(3),
        child: Container(
          padding: EdgeInsets.all(sc(5)),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(3),
            border: Border.all(
                color: enabled ? t.accentDim : R3Theme.hairline),
            color: Colors.transparent,
          ),
          child: Icon(
            Icons.content_cut,
            size: sc(17),
            color: enabled ? R3Theme.textMid : R3Theme.textDim,
          ),
        ),
      ),
    );
  }

  static final double _kPlayheadW = sc(4);

  Widget _buildScrubber(R3Theme t) {
    final bool enabled = _totalFrames > 0 && !_isSimulating;
    final double frac = _totalFrames > 0
        ? (_currentFrame / _totalFrames).clamp(0.0, 1.0)
        : 0.0;

    return LayoutBuilder(builder: (ctx, constraints) {
      final double w = constraints.maxWidth;
      void seekFromDx(double dx) {
        if (!enabled) return;
        final double nt = (dx / w).clamp(0.0, 1.0);
        _seek((nt * _totalFrames).round());
      }

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) {
          _stopPlayback();
          seekFromDx(d.localPosition.dx);
        },
        onHorizontalDragStart: (_) => _stopPlayback(),
        onHorizontalDragUpdate: (d) => seekFromDx(d.localPosition.dx),
        child: SizedBox(
          height: sc(24),
          child: Center(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(height: 2, color: R3Theme.hairline),
                FractionallySizedBox(
                  widthFactor: frac == 0 ? 0.001 : frac,
                  child: Container(
                    height: 2,
                    color: enabled ? t.accentDim : R3Theme.hairline,
                  ),
                ),
                Positioned(
                  left: (frac * w - _kPlayheadW / 2)
                      .clamp(0.0, w - _kPlayheadW),
                  top: sc(-7),
                  child: Container(
                    width: _kPlayheadW,
                    height: sc(16),
                    decoration: BoxDecoration(
                      color: enabled ? t.accent : R3Theme.textDim,
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }
}

class _EditorLineLayout {
  String _text = '';
  double _width = -1;
  TextPainter? _painter;
  List<int> _lineStarts = const [];

  static List<int> _computeLineStarts(String text) {
    final List<int> starts = [0];
    for (int i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 10) starts.add(i + 1);
    }
    return starts;
  }

  void update(String text, double width, TextStyle style) {
    if (text == _text && width == _width && _painter != null) return;

    _text = text;
    _width = width;
    _lineStarts = _computeLineStarts(text);

    _painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: null,
    )..layout(maxWidth: width > 0 ? width : double.infinity);
  }

  int get lineCount => _lineStarts.length;

  double yForLine(int line) {
    final TextPainter? p = _painter;
    if (p == null || line < 0 || line >= _lineStarts.length) return 0;
    return p
        .getOffsetForCaret(
            TextPosition(offset: _lineStarts[line]), Rect.zero)
        .dy;
  }

  double get height => _painter?.height ?? 0;
}

class _GutterPainter extends CustomPainter {
  final _EditorLineLayout layout;
  final String text;
  final double scrollOffset;
  final double textWidth;
  final TextStyle style;
  final double lineHeight;
  final int activeLine;
  final Set<int> problemLines;
  final Color accent;

  const _GutterPainter({
    required this.layout,
    required this.text,
    required this.scrollOffset,
    required this.textWidth,
    required this.style,
    required this.lineHeight,
    required this.activeLine,
    required this.problemLines,
    required this.accent,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (textWidth <= 0) return;

    layout.update(text, textWidth, style);

    final TextStyle numStyle = style.copyWith(height: 1.0);

    for (int i = 0; i < layout.lineCount; i++) {
      final double y = layout.yForLine(i) - scrollOffset;

      if (y > size.height) break;
      if (y + lineHeight < 0) continue;

      final bool isActive = i == activeLine;
      final bool isProblem = problemLines.contains(i);

      if (isActive) {
        canvas.drawRect(
          Rect.fromLTWH(0, y, size.width, lineHeight),
          Paint()..color = accent.withValues(alpha: 0.10),
        );
      }

      final Color color = isProblem
          ? R3Theme.danger
          : (isActive ? accent : R3Theme.textDim);

      final tp = TextPainter(
        text: TextSpan(
          text: '${i + 1}',
          style: numStyle.copyWith(
            color: color,
            fontWeight: isActive || isProblem ? FontWeight.w600 : null,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      tp.paint(
        canvas,
        Offset(size.width - tp.width - sc(6), y + (lineHeight - tp.height) / 2),
      );

      if (isProblem) {
        canvas.drawCircle(
          Offset(sc(4), y + lineHeight / 2),
          sc(2.5),
          Paint()..color = R3Theme.danger,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _GutterPainter old) =>
      old.text != text ||
      old.scrollOffset != scrollOffset ||
      old.textWidth != textWidth ||
      old.activeLine != activeLine ||
      old.problemLines != problemLines ||
      old.accent != accent;
}
