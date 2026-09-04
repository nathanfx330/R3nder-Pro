// ./lib/script_lint.dart

import 'parser.dart';
import 'presentation_requests.dart';

// =====================================================================
// WHY THIS EXISTS
//
// The tag grammar is one large alternation, and a construct it does not
// match is not an error: it falls through and types literally on screen.
// That failure mode is silent in the worst way, because the script looks
// fine, the build succeeds, and the mistake only shows up as stray text
// in a frame you might not scrub past.
//
// Three things produce it:
//
//   1. A tag name that does not exist. [CYAN] is the classic, since cyan
//      is a phosphor preset in the menu but not a text color token.
//   2. A real tag with malformed parameters. The positional tails are the
//      usual culprit: TIMELINE's stage requires a heading, PHOTO's release
//      requires a tint, and skipping one strands the rest.
//   3. A body tag opened and never closed.
//
// The linter finds all three by asking the ACTUAL grammar, not a copy of
// it, so it cannot drift from the parser the way a second regex would.
// =====================================================================

/// One problem found in a script, with the line the author will see in
/// the editor gutter.
class LintFinding {
  /// 1-based, counted in the raw document so it matches the editor.
  final int line;

  /// The offending text, truncated for display.
  final String snippet;

  final String message;

  const LintFinding({
    required this.line,
    required this.snippet,
    required this.message,
  });

  /// Formatted for the editor's warning strip.
  String get label => 'Line $line: $message  ($snippet)';

  @override
  String toString() => label;
}

class ScriptLinter {
  /// Bracketed constructs that are real R3nder markup but deliberately
  /// live outside [tagRegex]. The preprocessor, structural CST, or another
  /// source layer expands, strips, or owns these before the terminal parser
  /// ever runs, so an unmatched one is not automatically a terminal mistake.
  ///
  /// FRAME belongs to sprite text files rather than scripts, but it turns
  /// up in prose often enough that flagging it would be noise.
  static const Set<String> _nonGrammarKeywords = {
    'DEF_MENU', '/DEF_MENU',
    'ITEM', '/ITEM',
    'MACRO_CFG',
    'CALL',
    'MENU_STATE',
    'NEEDS',
    'FRAME',
    'EDIT', '/EDIT',
    'TRACK', '/TRACK',
    'CLIP', '/CLIP',
    'MOSAIC', '/MOSAIC',
    'PANE', '/PANE',
  };

  /// Every tag keyword the grammar knows.
  ///
  /// Two consumers, for different reasons. The linter uses it to tell "you
  /// misspelled a tag" apart from "this tag's parameters are wrong", which
  /// changes the message but not whether something is reported. The
  /// editor's ADD NODE palette checks itself against it, so a tag that
  /// exists in the grammar with no way to insert it is caught rather than
  /// quietly missing.
  ///
  /// This list duplicates knowledge that lives in the grammar, and it is
  /// the one place that is acceptable. For the linter, going out of date
  /// makes a message less specific rather than making the linter wrong: an
  /// unlisted name still gets reported, just as "unknown tag". For the
  /// palette the consequence is louder by design, which is the point: a
  /// debug assertion fires the moment the two disagree.
  static const Set<String> knownTags = {
    'WIPE', 'LINE', 'PAUSE', 'SPEED',
    'SIZE', 'LEAD', 'VPAD', 'ALIGN',
    'RED', 'GREEN', 'BLUE', 'YELLOW', 'WHITE', 'BLACK', 'NORMAL',
    'FLASH', 'SCRAMBLE', 'INVERT', 'REDACT', '/REDACT',
    'BAR',
    'REGION', '/REGION', 'SELECT',
    'CONFIG',
    'GALLERY', 'VIDEO', 'APP', 'BROWSER',
    'CARD', '/CARD',
    'DOSSIER', '/DOSSIER',
    'TIMELINE', '/TIMELINE',
    'SVG', 'SVGFLASH', 'PHOTO', 'IMG',
    'SPRITE', 'SPRITE_OFF',
  };

  /// Body tags, which are matched by the grammar as one unit including
  /// their closer. An unclosed one therefore fails to match at all, and
  /// deserves a more useful message than "malformed parameters".
  static const Set<String> _bodyTags = {'CARD', 'DOSSIER', 'TIMELINE'};

  /// A bracketed run that looks like it was meant to be a tag: an opening
  /// bracket, an optional leading slash, then a bare identifier followed
  /// by either the closing bracket or a colon.
  ///
  /// The shape test is what keeps prose out of the report. `[1, 2, 3, 4]`
  /// starts with a digit and `["WIPE", "SPEED"]` starts with a quote, so
  /// neither is tag-shaped and neither is flagged. ASCII art rarely is
  /// either. The cost of the heuristic is that a genuinely mangled tag
  /// like `[PAUSE 30]` reads as prose and slips through; the benefit is
  /// that the report stays trustworthy enough to act on.
  static final RegExp _tagShaped = RegExp(r'\[(/?[A-Za-z_][A-Za-z0-9_]*)\s*(:|\])');

  /// Comment spans, matched exactly as the preprocessor matches them so
  /// the linter skips precisely what the engine will delete.
  static final RegExp _comment = RegExp(r'\[#.*?\]', dotAll: true);

  /// Validates the APP `panes` tail.
  ///
  /// The main scan above only reports constructs tagRegex FAILED to match,
  /// and the panes group is `[^\]]+`, so any string at all matches and a
  /// malformed pane token never reaches it. parseAppPanePlan then drops
  /// what it cannot read and carries on, which keeps a typo from failing a
  /// render and also keeps the author from ever finding out.
  ///
  /// So the tokens are checked here against the same pattern the parser
  /// uses, plus the two range errors the parser silently absorbs: a
  /// one-based hero of 0, and a hero past the end of its own pane.
  static List<LintFinding> _lintAppPanes(
    String rawText,
    int Function(int) lineOf,
    bool Function(int) inSkipSpan,
  ) {
    final List<LintFinding> out = [];

    for (final RegExpMatch m in tagRegex.allMatches(rawText)) {
      if (inSkipSpan(m.start)) continue;
      final String? panes = m.namedGroup('appPanes');
      if (panes == null || panes.trim().isEmpty) continue;

      final int line = lineOf(m.start);

      // Pane structure only means anything to MOSAIC. GRID lays out a
      // uniform tile grid and never consults the plan, so an authored tail
      // there is a no-op the author will read as a broken feature. The
      // node workspace can produce this: the panes field is not gated on
      // the layout dropdown.
      final String layout = (m.namedGroup('appLayout') ?? 'GRID').toUpperCase();
      if (!layout.startsWith('MOSAIC')) {
        out.add(LintFinding(
          line: line,
          snippet: panes.trim(),
          message: 'Pane structure is ignored on a $layout layout. '
              'Set the APP layout to MOSAIC for grouping and Pane Life',
        ));
      }

      // A plan that over-runs the folder is clipped, dropping its later
      // panes and any hero on them. That check lives in the engine rather
      // than here: the linter never touches disk, and a finding that fired
      // on every valid pane plan would teach the author to ignore the
      // strip.

      for (final String piece in panes.split(';')) {
        final String tok = piece.trim();
        if (tok.isEmpty) continue;

        final RegExpMatch? pm = kAppPaneToken.firstMatch(tok);
        if (pm == null) {
          out.add(LintFinding(
            line: line,
            snippet: tok,
            message: 'Malformed pane token "$tok", ignored. '
                'Expected IMAGES[@HERO][-LR|-RL][-FIT|-FITW][+FRAMES], '
                'e.g. 3@2-LR-FITW+45',
          ));
          continue;
        }

        final int count = int.tryParse(pm.group(1)!) ?? 0;
        if (count <= 0) {
          out.add(LintFinding(
            line: line,
            snippet: tok,
            message: 'Pane "$tok" holds no images, ignored',
          ));
          continue;
        }

        final String? heroRaw = pm.group(2);
        if (heroRaw == null) continue;

        final int hero = int.tryParse(heroRaw) ?? 0;
        if (hero < 1) {
          out.add(LintFinding(
            line: line,
            snippet: tok,
            message: 'Hero index is one-based, so "$tok" selects image 1. '
                'Write @1 if that is what you meant',
          ));
        } else if (hero > count) {
          out.add(LintFinding(
            line: line,
            snippet: tok,
            message: 'Pane "$tok" has only $count image'
                '${count == 1 ? '' : 's'}, so the hero falls back to '
                'image $count',
          ));
        }
      }
    }

    return out;
  }

  /// Scans [rawText] and returns everything suspicious, in document order.
  ///
  /// Takes the RAW script rather than the preprocessed one so line numbers
  /// line up with what the author sees in the editor. Comment and CONFIG
  /// spans are skipped here rather than stripped, for the same reason.
  static List<LintFinding> lint(String rawText) {
    final List<LintFinding> findings = [];

    // Offsets the preprocessor will remove. Anything starting inside one
    // of these is not the author's problem.
    final List<(int, int)> skipSpans = [];
    for (final m in _comment.allMatches(rawText)) {
      skipSpans.add((m.start, m.end));
    }
    for (final m in RegExp(r'\[CONFIG:.*?\]').allMatches(rawText)) {
      skipSpans.add((m.start, m.end));
    }

    bool inSkipSpan(int i) {
      for (final (s, e) in skipSpans) {
        if (i >= s && i < e) return true;
      }
      return false;
    }

    // Newline offsets, for turning an offset into a line number without
    // rescanning the document every time.
    final List<int> lineStarts = [0];
    for (int i = 0; i < rawText.length; i++) {
      if (rawText.codeUnitAt(i) == 10) lineStarts.add(i + 1);
    }
    int lineOf(int offset) {
      int lo = 0;
      int hi = lineStarts.length - 1;
      while (lo < hi) {
        final int mid = (lo + hi + 1) ~/ 2;
        if (lineStarts[mid] <= offset) {
          lo = mid;
        } else {
          hi = mid - 1;
        }
      }
      return lo + 1;
    }

    int i = 0;
    while (i < rawText.length) {
      if (rawText.codeUnitAt(i) != 91) {
        // '['
        i++;
        continue;
      }

      if (inSkipSpan(i)) {
        i++;
        continue;
      }

      // Ask the real grammar first. A match consumes the whole construct,
      // including a body tag's body and closer.
      final Match? ok = tagRegex.matchAsPrefix(rawText, i);
      if (ok != null) {
        i = ok.end;
        continue;
      }

      // matchAsPrefix against the whole string at an offset, rather than
      // substring(i), which would copy the tail of the document once per
      // bracket and turn this into an O(n^2) scan on a long script.
      final Match? shaped = _tagShaped.matchAsPrefix(rawText, i);
      if (shaped == null) {
        // Not tag-shaped: prose, ASCII art, code samples. Leave it alone.
        i++;
        continue;
      }

      final String word = shaped.group(1)!.toUpperCase();
      if (_nonGrammarKeywords.contains(word)) {
        i++;
        continue;
      }

      // Pull a readable snippet: to the closing bracket if there is one
      // reasonably close, otherwise a fixed window.
      final int closeAt = rawText.indexOf(']', i);
      final int close = (closeAt < 0) ? -1 : closeAt - i;

      final String snippet;
      if (close >= 0 && close < 60) {
        snippet = rawText.substring(i, i + close + 1);
      } else {
        final int end = (i + 40 < rawText.length) ? i + 40 : rawText.length;
        snippet = '${rawText.substring(i, end)}...';
      }

      final String message;
      if (!knownTags.contains(word)) {
        message = 'Unknown tag "$word", will type as literal text';
      } else if (_bodyTags.contains(word) &&
          rawText.indexOf('[/$word]', i) < 0) {
        message = '$word is never closed, add [/$word]';
      } else {
        message = 'Malformed $word, check the parameter order';
      }

      findings.add(LintFinding(
        line: lineOf(i),
        snippet: snippet.replaceAll('\n', ' '),
        message: message,
      ));

      // Step past this construct so one bad tag does not cascade.
      i += (close >= 0) ? close + 1 : 1;
    }

    findings.addAll(_lintAppPanes(rawText, lineOf, inSkipSpan));
    findings.sort((a, b) => a.line.compareTo(b.line));

    return findings;
  }
}
