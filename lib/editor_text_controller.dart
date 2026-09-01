// ./lib/editor_text_controller.dart

import 'package:flutter/material.dart';

/// A colour literal found in the document, and the range that paints as a
/// clickable swatch.
class SwatchSpan {
  /// First character of the digits, just past the opening colon.
  final int start;

  /// One past the last digit. The trailing `:` or `]` is matched by
  /// lookahead and deliberately not included.
  final int end;

  final Color color;

  const SwatchSpan(this.start, this.end, this.color);
}

/// A custom text controller that allows us to highlight a specific line
/// dynamically based on the engine's playback head, highlight search results,
/// and provide interactive RGB color swatches inline.
class EditorTextController extends TextEditingController {
  int highlightedLine = -1;
  // Transparent enough that the cursor shines through; neutral so it sits
  // on the design system's darker editor surface.
  Color highlightColor = const Color(0x552E2E44);

  String searchQuery = "";
  int currentSearchIndex = 0;

  /// Character ranges of tags whose asset reference does not resolve on
  /// disk, as (start, end) pairs. Painted amber so a broken reference is
  /// visible at a glance instead of only in the asset manager.
  ///
  /// Amber rather than the linter's red on purpose: a malformed tag will
  /// type garbage onto the screen, while a missing asset is a tag that is
  /// perfectly well formed and simply has nothing to point at yet. Two
  /// different problems should not look like the same problem.
  List<(int, int)> assetProblems = const [];

  void updateAssetProblems(List<(int, int)> ranges) {
    assetProblems = ranges;
    notifyListeners();
  }

  EditorTextController({super.text});

  // -------------------------------------------------------------------
  // Colour swatches
  //
  // These used to carry a TapGestureRecognizer on their TextSpan, which
  // is how Flutter does tappable rich text. It is also unsupported inside
  // an editable field: RenderEditable asserts `readOnly && !obscureText`
  // when it finds a recognizer while building its semantics, and the
  // throw takes the whole render subtree down with it. Release strips the
  // assert, so the editor worked for months and only ever broke under
  // `flutter run`, which is a bad place for a fault to hide.
  //
  // So the tap is handled by the TextField instead. The field already
  // resolves a click to a caret offset; the editor asks this controller
  // whether that offset lands on a swatch. Same hit target, same picker,
  // no recognizers, and the range data has one definition used by both
  // the painting and the hit test rather than two that can drift.
  // -------------------------------------------------------------------

  /// Matches `:R,G,B` immediately followed by `:` or `]`. The terminator
  /// is lookahead so it stays outside the highlighted range.
  static final RegExp _colorPattern =
      RegExp(r':(\d{1,3},\d{1,3},\d{1,3})(?=:|\])');

  /// Every valid colour literal in the current text.
  ///
  /// Recomputed rather than cached: it is one regex pass over a document
  /// measured in kilobytes, and a cache would need invalidating on every
  /// keystroke, which is exactly the bookkeeping that produces a hit test
  /// disagreeing with what is on screen.
  List<SwatchSpan> swatchSpans() {
    final List<SwatchSpan> out = [];
    for (final m in _colorPattern.allMatches(text)) {
      final List<String> parts = m.group(1)!.split(',');
      final int r = int.parse(parts[0]);
      final int g = int.parse(parts[1]);
      final int b = int.parse(parts[2]);
      // Three digits can exceed 255; those are not colours, just numbers.
      if (r > 255 || g > 255 || b > 255) continue;
      out.add(SwatchSpan(m.start + 1, m.end, Color.fromARGB(255, r, g, b)));
    }
    return out;
  }

  /// The swatch under [offset], or null.
  ///
  /// [end] is inclusive because a click on the right half of the last
  /// digit places the caret just past it, and refusing that would make
  /// the last character of every swatch feel dead.
  SwatchSpan? swatchAt(int offset) {
    if (offset < 0) return null;

    // Search highlighting wins, matching what the painting does below: a
    // search hit repaints over the swatch, and opening a colour picker
    // from something that no longer looks like a swatch would be a
    // surprise.
    if (searchQuery.isNotEmpty) {
      for (final m in RegExp(RegExp.escape(searchQuery), caseSensitive: false)
          .allMatches(text)) {
        if (offset >= m.start && offset < m.end) return null;
      }
    }

    for (final s in swatchSpans()) {
      if (offset >= s.start && offset <= s.end) return s;
    }
    return null;
  }

  void updateHighlight(int line) {
    if (highlightedLine != line) {
      highlightedLine = line;
      notifyListeners();
    }
  }

  void updateSearch(String query, int index) {
    searchQuery = query;
    currentSearchIndex = index;
    notifyListeners();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final int len = text.length;
    if (len == 0) return TextSpan(style: style, text: "");

    // We use a character-by-character styling array to elegantly handle
    // overlapping highlights (e.g. search intersecting with a color swatch).
    List<Color?> bgColors = List.filled(len, null);
    List<Color?> fgColors = List.filled(len, null);
    List<FontWeight?> fontWeights = List.filled(len, null);
    List<bool> problems = List.filled(len, false);

    // 1. Line Highlight
    int globalOffset = 0;
    final List<String> lines = text.split('\n');
    for (int i = 0; i < lines.length; i++) {
      int lineLen = lines[i].length + (i < lines.length - 1 ? 1 : 0);
      if (i == highlightedLine) {
        for (int j = 0; j < lineLen; j++) {
          if (globalOffset + j < len) bgColors[globalOffset + j] = highlightColor;
        }
      }
      globalOffset += lineLen;
    }

    // 1.5 Unresolved asset references.
    //
    // Sits before the swatches deliberately: a tag can carry both a missing
    // folder and an RGB value, and the swatch is still worth showing. The
    // amber underline survives underneath it.
    for (final (start, end) in assetProblems) {
      for (int j = start; j < end && j < len; j++) {
        if (j >= 0) {
          fgColors[j] = const Color(0xFFE8A33D);
          problems[j] = true;
        }
      }
    }

    // 2. Interactive Color Swatches (e.g., :180,40,50: or :180,40,50])
    //
    // Painted from the same swatchSpans() the tap handler hit-tests
    // against, so what looks clickable and what IS clickable cannot
    // disagree.
    for (final s in swatchSpans()) {
      // Auto-contrast text color against the background swatch
      final bool isDark = s.color.computeLuminance() < 0.35;
      final Color textColor = isDark ? Colors.white : Colors.black;

      for (int j = s.start; j < s.end && j < len; j++) {
        bgColors[j] = s.color;
        fgColors[j] = textColor;
        fontWeights[j] = FontWeight.w900; // Bold it so it feels like a button
      }
    }

    // 3. Search Matches (Search overrides color swatches visually)
    if (searchQuery.isNotEmpty) {
      final matches = RegExp(RegExp.escape(searchQuery), caseSensitive: false)
          .allMatches(text)
          .toList();
      for (int mIdx = 0; mIdx < matches.length; mIdx++) {
        final m = matches[mIdx];
        bool isActive = mIdx == currentSearchIndex;
        Color sBg =
            isActive ? Colors.orange : Colors.yellow.withValues(alpha: 0.4);
        Color sFg = isActive ? Colors.black : (style?.color ?? Colors.white);

        for (int j = m.start; j < m.end; j++) {
          if (j < len) {
            bgColors[j] = sBg;
            fgColors[j] = sFg;
            fontWeights[j] = null;
          }
        }
      }
    }

    // 4. Build contiguous TextSpans
    List<InlineSpan> spans = [];
    int currentSpanStart = 0;
    Color? currentBg = bgColors[0];
    Color? currentFg = fgColors[0];
    FontWeight? currentWeight = fontWeights[0];
    bool currentProblem = problems[0];

    for (int i = 1; i <= len; i++) {
      bool changed = i == len ||
          bgColors[i] != currentBg ||
          fgColors[i] != currentFg ||
          fontWeights[i] != currentWeight ||
          problems[i] != currentProblem;

      if (changed) {
        TextStyle spanStyle = style ?? const TextStyle();
        if (currentBg != null) spanStyle = spanStyle.copyWith(backgroundColor: currentBg);
        if (currentFg != null) spanStyle = spanStyle.copyWith(color: currentFg);
        if (currentWeight != null) spanStyle = spanStyle.copyWith(fontWeight: currentWeight);
        if (currentProblem) {
          spanStyle = spanStyle.copyWith(
            decoration: TextDecoration.underline,
            decorationStyle: TextDecorationStyle.dotted,
            decorationColor: const Color(0xFFE8A33D),
          );
        }

        // NO `recognizer:` HERE. See the swatch section above: a
        // recognizer on a span inside an editable field is what brought
        // the whole render tree down under a debug build.
        spans.add(TextSpan(
          text: text.substring(currentSpanStart, i),
          style: spanStyle,
        ));

        if (i < len) {
          currentSpanStart = i;
          currentBg = bgColors[i];
          currentFg = fgColors[i];
          currentWeight = fontWeights[i];
          currentProblem = problems[i];
        }
      }
    }

    return TextSpan(style: style, children: spans);
  }
}