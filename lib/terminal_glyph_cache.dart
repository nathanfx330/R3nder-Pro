// ./lib/terminal_glyph_cache.dart

part of 'terminal_painter.dart';

// Process-wide text layout cache used by TerminalPainter. It is rendering
// infrastructure rather than drawing logic, so it lives beside the painter.

/// Process-wide cache of laid-out TextPainters, keyed by everything that
/// affects a glyph's rendering: the character, the font family, the font
/// size, and the fill color.
///
/// WHY THIS EXISTS: TerminalPainter is constructed fresh every frame (by
/// ScenePainter and by the editor preview), so an instance-level cache
/// would never survive long enough to get a hit. The engine's
/// _charWidthCache solves widths for LAYOUT; this solves the far more
/// expensive TextPainter.layout() call for PAINTING, which was previously
/// running once per character per frame — thousands of layouts per second
/// on a dense screen.
///
/// WHY THIS IS SAFE: a TextPainter is immutable once laid out, and
/// paint() can be called any number of times. The glyph set is naturally
/// bounded — pen colors come from the named tag palette plus the config FG
/// color, flash effects use a small fixed palette, and scramble colors are
/// derived from pen colors — so the cache converges to a small working set
/// after the first second of playback. A hard cap guards against a
/// pathological script anyway: on overflow the cache is disposed and
/// cleared wholesale, costing one frame of re-layout.
///
/// DETERMINISM: untouched. The cached painter is laid out from the exact
/// same TextSpan the old per-frame code built, so widths, baselines, and
/// pixels are identical — the work just isn't repeated.
class _GlyphCache {
  static final Map<(String, String, double, int), TextPainter> _glyphs = {};

  /// (fontFamily, fontSize) -> alphabetic baseline distance of a reference
  /// glyph, for cursor positioning. Tiny; never needs eviction.
  static final Map<(String, double), double> _baselines = {};

  static const int _maxEntries = 8192;

  static const List<String> _fallbacks = [
    'Courier',
    'Consolas',
    'Courier New',
    'monospace',
  ];

  /// Returns a laid-out TextPainter for [char] in the given style,
  /// building and caching it on first sight.
  static TextPainter glyph(
      String char, String fontFamily, double fontSize, Color color) {
    final key = (char, fontFamily, fontSize, color.toARGB32());
    final TextPainter? hit = _glyphs[key];
    if (hit != null) return hit;

    if (_glyphs.length >= _maxEntries) {
      // Pathological color/size churn: reset wholesale. One frame of
      // re-layout, and TextPainter.dispose releases the native paragraphs.
      for (final tp in _glyphs.values) {
        tp.dispose();
      }
      _glyphs.clear();
    }

    final tp = TextPainter(
      text: TextSpan(
        text: char,
        style: TextStyle(
          fontFamily: fontFamily,
          fontFamilyFallback: _fallbacks,
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    _glyphs[key] = tp;
    return tp;
  }

  /// Alphabetic-baseline distance for the resolved font at [fontSize],
  /// measured off a reference 'M' — used to anchor the cursor to the same
  /// baseline the glyphs actually sit on (see the cursor metrics fix).
  static double baseline(String fontFamily, double fontSize) {
    final key = (fontFamily, fontSize);
    final double? hit = _baselines[key];
    if (hit != null) return hit;

    final refTp = TextPainter(
      text: TextSpan(
        text: 'M',
        style: TextStyle(
          fontFamily: fontFamily,
          fontFamilyFallback: _fallbacks,
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    refTp.layout();
    final double b =
        refTp.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    refTp.dispose();

    _baselines[key] = b;
    return b;
  }
}