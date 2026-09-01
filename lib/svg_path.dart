// ./lib/svg_path.dart

import 'dart:math' as math;
import 'dart:ui' as ui;

/// Pure-Dart SVG subset parser. Zero dependencies, matching R3nder's
/// no-external-packages philosophy.
///
/// Scope: monochrome stencils. We extract geometry ONLY — every shape is
/// compiled into a single ui.Path and filled with whatever color the
/// terminal engine resolves at draw time. Strokes, gradients, CSS classes,
/// text, transforms, groups, and defs in the source file are all ignored.
///
/// REAL-WORLD DEFENSES (the reasons a naive parser renders a solid block):
///  - Elements with fill="none" (attr or inline style) are SKIPPED. They
///    are stroke-only art; filling them makes solid silhouettes.
///  - A `<rect>` covering ~the whole viewBox is a BACKGROUND, not artwork.
///    Every exporter embeds one. Skipped.
///  - Anything inside `<defs>`, `<clipPath>`, `<mask>`, `<symbol>`, or
///    `<pattern>` is template/masking machinery, not visible artwork.
///    Skipped.
///  - A shape whose bounds cover ~the whole viewBox while OTHER, smaller
///    shapes exist is also treated as a background plate and skipped.
///  - If the merged result still has nested contours and no fill-rule was
///    declared, we flip to evenodd so counters (the hole in an O, the
///    chunk in a pac-man ring drawn as two contours) punch through.
///
/// Supported elements:  `<path d="...">`, `<rect>`, `<circle>`,
///                      `<ellipse>`, `<polygon>`, `<polyline>`
/// Supported path data: M L H V C S Q T A Z (absolute and relative),
///                      arcs converted to cubics via endpoint-to-center
///                      parameterization.
class SvgDocument {
  /// All shapes merged into one path, in viewBox coordinates.
  final ui.Path path;

  /// ViewBox origin and size. Width/height are guaranteed > 0.
  final double viewLeft;
  final double viewTop;
  final double viewWidth;
  final double viewHeight;

  SvgDocument({
    required this.path,
    required this.viewLeft,
    required this.viewTop,
    required this.viewWidth,
    required this.viewHeight,
  });
}

/// One parsed shape, held individually so background plates can be culled
/// AFTER the viewBox is known, before the final merge.
class _Shape {
  final ui.Path path;
  final ui.Rect bounds;
  final bool isRect; // Plain rectangles are the classic background plate.

  _Shape(this.path, this.isRect) : bounds = path.getBounds();
}

class SvgParser {
  /// Fraction of the viewBox a shape must cover (in both dimensions) to be
  /// considered a background plate.
  static const double _kBgCoverage = 0.95;

  /// Parses [source] (raw .svg file text) into an SvgDocument, or null if
  /// the file yields no drawable geometry. Never throws — malformed input
  /// degrades to skipping the bad shape (or returning null if nothing
  /// parses), and the caller records a warning.
  static SvgDocument? parse(String source) {
    // Strip comments so a commented-out <path> can't be picked up.
    String src = source.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');

    // Strip non-rendered containers wholesale: defs, clipPaths, masks,
    // symbols, patterns. Geometry inside them is machinery, not artwork.
    src = src.replaceAll(
        RegExp(
            r'<(defs|clipPath|mask|symbol|pattern)\b[\s\S]*?</\1\s*>',
            caseSensitive: false),
        '');

    bool declaredEvenOdd =
        RegExp(r'''fill-rule\s*[:=]\s*["']?evenodd''').hasMatch(src);

    // True if the element's own attributes say "don't fill me".
    bool isFillNone(String tag) {
      if (RegExp(r'''\bfill\s*=\s*["']\s*none\s*["']''').hasMatch(tag)) {
        return true;
      }
      // Inline style="...fill:none..."
      final styleM =
          RegExp(r'''\bstyle\s*=\s*["']([^"']*)["']''').firstMatch(tag);
      if (styleM != null &&
          RegExp(r'fill\s*:\s*none').hasMatch(styleM.group(1)!)) {
        return true;
      }
      return false;
    }

    final List<_Shape> shapes = [];

    // --- <path d="..."> ---
    for (final m in RegExp(r'''<path\b[^>]*>''').allMatches(src)) {
      final String tag = m.group(0)!;
      if (isFillNone(tag)) continue;
      final String? d = _attr(tag, 'd');
      if (d == null) continue;
      final ui.Path? p = _parsePathData(d);
      if (p != null) shapes.add(_Shape(p, false));
    }

    // --- <rect> ---
    for (final m in RegExp(r'''<rect\b[^>]*>''').allMatches(src)) {
      final String tag = m.group(0)!;
      if (isFillNone(tag)) continue;
      final double x = _num(tag, 'x') ?? 0;
      final double y = _num(tag, 'y') ?? 0;
      final double w = _num(tag, 'width') ?? 0;
      final double h = _num(tag, 'height') ?? 0;
      if (w <= 0 || h <= 0) continue;
      double rx = _num(tag, 'rx') ?? _num(tag, 'ry') ?? 0;
      rx = rx.clamp(0, math.min(w, h) / 2);
      final ui.Path p = ui.Path();
      if (rx > 0) {
        p.addRRect(ui.RRect.fromRectAndRadius(
            ui.Rect.fromLTWH(x, y, w, h), ui.Radius.circular(rx)));
      } else {
        p.addRect(ui.Rect.fromLTWH(x, y, w, h));
      }
      shapes.add(_Shape(p, true));
    }

    // --- <circle> ---
    for (final m in RegExp(r'''<circle\b[^>]*>''').allMatches(src)) {
      final String tag = m.group(0)!;
      if (isFillNone(tag)) continue;
      final double cx = _num(tag, 'cx') ?? 0;
      final double cy = _num(tag, 'cy') ?? 0;
      final double r = _num(tag, 'r') ?? 0;
      if (r <= 0) continue;
      final ui.Path p = ui.Path()
        ..addOval(ui.Rect.fromCircle(center: ui.Offset(cx, cy), radius: r));
      shapes.add(_Shape(p, false));
    }

    // --- <ellipse> ---
    for (final m in RegExp(r'''<ellipse\b[^>]*>''').allMatches(src)) {
      final String tag = m.group(0)!;
      if (isFillNone(tag)) continue;
      final double cx = _num(tag, 'cx') ?? 0;
      final double cy = _num(tag, 'cy') ?? 0;
      final double rx = _num(tag, 'rx') ?? 0;
      final double ry = _num(tag, 'ry') ?? 0;
      if (rx <= 0 || ry <= 0) continue;
      final ui.Path p = ui.Path()
        ..addOval(ui.Rect.fromCenter(
            center: ui.Offset(cx, cy), width: rx * 2, height: ry * 2));
      shapes.add(_Shape(p, false));
    }

    // --- <polygon> / <polyline> (both closed — this is a fill stencil) ---
    for (final m in
        RegExp(r'''<poly(?:gon|line)\b[^>]*>''').allMatches(src)) {
      final String tag = m.group(0)!;
      if (isFillNone(tag)) continue;
      final String? pts = _attr(tag, 'points');
      if (pts == null) continue;
      final List<double> nums = _numbers(pts);
      if (nums.length < 6) continue; // need at least 3 points
      final ui.Path poly = ui.Path()..moveTo(nums[0], nums[1]);
      for (int i = 2; i + 1 < nums.length; i += 2) {
        poly.lineTo(nums[i], nums[i + 1]);
      }
      poly.close();
      shapes.add(_Shape(poly, false));
    }

    if (shapes.isEmpty) return null;

    // --- viewBox ---
    double vl = 0, vt = 0, vw = 0, vh = 0;
    final vbMatch =
        RegExp(r'''viewBox\s*=\s*["']([^"']+)["']''').firstMatch(src);
    if (vbMatch != null) {
      final List<double> vb = _numbers(vbMatch.group(1)!);
      if (vb.length == 4 && vb[2] > 0 && vb[3] > 0) {
        vl = vb[0];
        vt = vb[1];
        vw = vb[2];
        vh = vb[3];
      }
    }
    if (vw <= 0 || vh <= 0) {
      // No usable viewBox: try width/height on the <svg> tag, else fall
      // back to the union of all shape bounds.
      final svgTag = RegExp(r'''<svg\b[^>]*>''').firstMatch(src)?.group(0);
      final double? w = svgTag != null ? _num(svgTag, 'width') : null;
      final double? h = svgTag != null ? _num(svgTag, 'height') : null;
      if (w != null && h != null && w > 0 && h > 0) {
        vw = w;
        vh = h;
      } else {
        ui.Rect union = shapes.first.bounds;
        for (final s in shapes.skip(1)) {
          union = union.expandToInclude(s.bounds);
        }
        if (union.width <= 0 || union.height <= 0) return null;
        vl = union.left;
        vt = union.top;
        vw = union.width;
        vh = union.height;
      }
    }

    // --- BACKGROUND PLATE CULL ---
    // A shape whose bounds blanket the viewBox is the exporter's page
    // background, not the logo. Only cull when OTHER shapes remain —
    // if the artwork legitimately IS one full-canvas shape, keep it.
    bool coversViewBox(_Shape s) {
      return s.bounds.width >= vw * _kBgCoverage &&
          s.bounds.height >= vh * _kBgCoverage;
    }

    List<_Shape> kept = shapes;
    // Pass 1: full-canvas plain <rect>s (the classic case) — cull even if
    // it leaves one shape, as long as SOMETHING non-rect remains.
    final List<_Shape> nonBgRects =
        kept.where((s) => !(s.isRect && coversViewBox(s))).toList();
    if (nonBgRects.isNotEmpty) kept = nonBgRects;
    // Pass 2: any other full-canvas shape (a background drawn as a path),
    // but only while smaller artwork remains after removal.
    final List<_Shape> nonBgAny =
        kept.where((s) => !coversViewBox(s)).toList();
    if (nonBgAny.isNotEmpty) kept = nonBgAny;

    // --- Merge ---
    final ui.Path merged = ui.Path();
    for (final s in kept) {
      merged.addPath(s.path, ui.Offset.zero);
    }

    // Fill rule. If the file declared evenodd, honor it. If it declared
    // nothing but the geometry has nested contours (a ring, an O), nonzero
    // may fill the holes solid depending on winding — evenodd renders the
    // holes correctly no matter how the exporter wound them, and for a
    // single-color stencil overlap-cancellation is an acceptable trade.
    bool useEvenOdd = declaredEvenOdd;
    if (!useEvenOdd && _hasNestedContours(kept)) {
      useEvenOdd = true;
    }
    merged.fillType =
        useEvenOdd ? ui.PathFillType.evenOdd : ui.PathFillType.nonZero;

    return SvgDocument(
      path: merged,
      viewLeft: vl,
      viewTop: vt,
      viewWidth: vw,
      viewHeight: vh,
    );
  }

  /// Heuristic: true if any shape's bounds sit entirely inside another
  /// shape's bounds, the signature of a counter/hole (ring inner circle,
  /// the bowl of an O). Bounds-based, so it can't see holes encoded as
  /// subpaths WITHIN one `<path>` element; those we detect per-path during
  /// data parsing (multiple closed subpaths, one containing another).
  static bool _hasNestedContours(List<_Shape> shapes) {
    for (int i = 0; i < shapes.length; i++) {
      for (int j = 0; j < shapes.length; j++) {
        if (i == j) continue;
        final a = shapes[i].bounds;
        final b = shapes[j].bounds;
        if (b.left >= a.left &&
            b.top >= a.top &&
            b.right <= a.right &&
            b.bottom <= a.bottom &&
            (b.width < a.width || b.height < a.height)) {
          return true;
        }
      }
      // Multiple closed subpaths inside one element: check metrics.
      final metrics = shapes[i].path.computeMetrics().toList();
      if (metrics.length > 1) return true;
    }
    return false;
  }

  // -------------------------------------------------------------------
  // Attribute helpers
  // -------------------------------------------------------------------

  /// Value of attribute [name] inside a single tag string, or null.
  static String? _attr(String tag, String name) {
    final m = RegExp('\\b$name\\s*=\\s*["\']([^"\']*)["\']').firstMatch(tag);
    return m?.group(1);
  }

  /// Numeric attribute; strips a trailing unit like "px". Percent values
  /// are rejected (we have no reference box to resolve them against).
  static double? _num(String tag, String name) {
    final String? v = _attr(tag, name);
    if (v == null || v.contains('%')) return null;
    return double.tryParse(
        v.trim().replaceAll(RegExp(r'[a-zA-Z]+$'), ''));
  }

  /// All floats in a string (points lists, viewBox). Handles scientific
  /// notation and comma/whitespace separation.
  static List<double> _numbers(String s) {
    return RegExp(r'[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?')
        .allMatches(s)
        .map((m) => double.parse(m.group(0)!))
        .toList();
  }

  // -------------------------------------------------------------------
  // Path data parser
  // -------------------------------------------------------------------

  static ui.Path? _parsePathData(String d) {
    final _PathTokenizer tok = _PathTokenizer(d);
    final ui.Path path = ui.Path();

    double cx = 0, cy = 0; // current point
    double sx = 0, sy = 0; // subpath start (for Z)
    double pcx = 0, pcy = 0; // previous cubic control (for S)
    double pqx = 0, pqy = 0; // previous quad control (for T)
    String prevCmd = '';
    bool drew = false;

    try {
      String? cmd = tok.nextCommand();
      if (cmd == null) return null;

      while (cmd != null) {
        final bool rel = cmd == cmd.toLowerCase();
        final String c = cmd.toUpperCase();

        // A command's parameter set may repeat; loop while numbers remain.
        bool first = true;
        do {
          switch (c) {
            case 'M':
              double x = tok.number(), y = tok.number();
              if (rel) { x += cx; y += cy; }
              if (first) {
                path.moveTo(x, y);
                sx = x; sy = y;
              } else {
                path.lineTo(x, y); // Implicit lineto after the first pair
                drew = true;
              }
              cx = x; cy = y;
              break;

            case 'L':
              double x = tok.number(), y = tok.number();
              if (rel) { x += cx; y += cy; }
              path.lineTo(x, y);
              cx = x; cy = y; drew = true;
              break;

            case 'H':
              double x = tok.number();
              if (rel) x += cx;
              path.lineTo(x, cy);
              cx = x; drew = true;
              break;

            case 'V':
              double y = tok.number();
              if (rel) y += cy;
              path.lineTo(cx, y);
              cy = y; drew = true;
              break;

            case 'C':
              double x1 = tok.number(), y1 = tok.number();
              double x2 = tok.number(), y2 = tok.number();
              double x = tok.number(), y = tok.number();
              if (rel) { x1 += cx; y1 += cy; x2 += cx; y2 += cy; x += cx; y += cy; }
              path.cubicTo(x1, y1, x2, y2, x, y);
              pcx = x2; pcy = y2;
              cx = x; cy = y; drew = true;
              break;

            case 'S':
              double x2 = tok.number(), y2 = tok.number();
              double x = tok.number(), y = tok.number();
              if (rel) { x2 += cx; y2 += cy; x += cx; y += cy; }
              // Reflect previous cubic control if the previous command was
              // a cubic; otherwise the first control is the current point.
              double x1 = cx, y1 = cy;
              if (prevCmd == 'C' || prevCmd == 'S') {
                x1 = 2 * cx - pcx;
                y1 = 2 * cy - pcy;
              }
              path.cubicTo(x1, y1, x2, y2, x, y);
              pcx = x2; pcy = y2;
              cx = x; cy = y; drew = true;
              break;

            case 'Q':
              double x1 = tok.number(), y1 = tok.number();
              double x = tok.number(), y = tok.number();
              if (rel) { x1 += cx; y1 += cy; x += cx; y += cy; }
              path.quadraticBezierTo(x1, y1, x, y);
              pqx = x1; pqy = y1;
              cx = x; cy = y; drew = true;
              break;

            case 'T':
              double x = tok.number(), y = tok.number();
              if (rel) { x += cx; y += cy; }
              double x1 = cx, y1 = cy;
              if (prevCmd == 'Q' || prevCmd == 'T') {
                x1 = 2 * cx - pqx;
                y1 = 2 * cy - pqy;
              }
              path.quadraticBezierTo(x1, y1, x, y);
              pqx = x1; pqy = y1;
              cx = x; cy = y; drew = true;
              break;

            case 'A':
              final double rx = tok.number(), ry = tok.number();
              final double rot = tok.number();
              final double largeArc = tok.flag();
              final double sweep = tok.flag();
              double x = tok.number(), y = tok.number();
              if (rel) { x += cx; y += cy; }
              _arcToCubics(path, cx, cy, x, y, rx.abs(), ry.abs(),
                  rot * math.pi / 180.0, largeArc != 0, sweep != 0);
              cx = x; cy = y; drew = true;
              break;

            case 'Z':
              path.close();
              cx = sx; cy = sy;
              break;

            default:
              return drew ? path : null; // Unknown command: stop cleanly.
          }
          first = false;
          prevCmd = c;
          // Z takes no parameters and never repeats implicitly.
          if (c == 'Z') break;
        } while (tok.hasNumber());

        cmd = tok.nextCommand();
      }
    } catch (_) {
      // Ran out of numbers mid-command (malformed data): keep whatever
      // geometry parsed cleanly before the breakage.
    }

    return drew ? path : null;
  }

  /// Converts an SVG endpoint-parameterized arc into cubic Bézier segments
  /// (max 90° each), appended to [path]. Standard implementation of the
  /// SVG 1.1 F.6 endpoint-to-center conversion, including the F.6.6
  /// out-of-range radii correction.
  static void _arcToCubics(ui.Path path, double x1, double y1, double x2,
      double y2, double rx, double ry, double phi, bool largeArc, bool sweep) {
    if (rx == 0 || ry == 0 || (x1 == x2 && y1 == y2)) {
      path.lineTo(x2, y2);
      return;
    }

    final double cosPhi = math.cos(phi), sinPhi = math.sin(phi);

    // F.6.5.1: transform to the ellipse-aligned frame.
    final double dx = (x1 - x2) / 2, dy = (y1 - y2) / 2;
    final double x1p = cosPhi * dx + sinPhi * dy;
    final double y1p = -sinPhi * dx + cosPhi * dy;

    // F.6.6: scale radii up if the endpoints can't be reached.
    final double lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if (lambda > 1) {
      final double s = math.sqrt(lambda);
      rx *= s;
      ry *= s;
    }

    // F.6.5.2: center in the primed frame.
    final double rx2 = rx * rx, ry2 = ry * ry;
    final double x1p2 = x1p * x1p, y1p2 = y1p * y1p;
    double num = rx2 * ry2 - rx2 * y1p2 - ry2 * x1p2;
    if (num < 0) num = 0;
    final double den = rx2 * y1p2 + ry2 * x1p2;
    double coef = den == 0 ? 0 : math.sqrt(num / den);
    if (largeArc == sweep) coef = -coef;
    final double cxp = coef * rx * y1p / ry;
    final double cyp = -coef * ry * x1p / rx;

    // F.6.5.3: center in the original frame.
    final double cx = cosPhi * cxp - sinPhi * cyp + (x1 + x2) / 2;
    final double cy = sinPhi * cxp + cosPhi * cyp + (y1 + y2) / 2;

    // F.6.5.5 / F.6.5.6: start and sweep angles.
    double angle(double ux, double uy, double vx, double vy) {
      final double dot = ux * vx + uy * vy;
      final double len =
          math.sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy));
      double a = math.acos((dot / len).clamp(-1.0, 1.0));
      if (ux * vy - uy * vx < 0) a = -a;
      return a;
    }

    final double ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry;
    final double vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry;
    final double theta1 = angle(1, 0, ux, uy);
    double dTheta = angle(ux, uy, vx, vy);
    if (!sweep && dTheta > 0) dTheta -= 2 * math.pi;
    if (sweep && dTheta < 0) dTheta += 2 * math.pi;

    // Split into <= 90° segments, each approximated by one cubic.
    final int segments = (dTheta.abs() / (math.pi / 2)).ceil().clamp(1, 8);
    final double delta = dTheta / segments;
    // Control-point distance factor for a circular arc segment.
    final double t = 4 / 3 * math.tan(delta / 4);

    double theta = theta1;
    double px = x1, py = y1;

    for (int i = 0; i < segments; i++) {
      final double theta2 = theta + delta;
      final double cosT1 = math.cos(theta), sinT1 = math.sin(theta);
      final double cosT2 = math.cos(theta2), sinT2 = math.sin(theta2);

      // Endpoint of this segment in the original frame.
      final double ex =
          cx + rx * cosT2 * cosPhi - ry * sinT2 * sinPhi;
      final double ey =
          cy + rx * cosT2 * sinPhi + ry * sinT2 * cosPhi;

      // Derivatives (tangents) at segment start/end, rotated by phi.
      final double d1x = -rx * sinT1 * cosPhi - ry * cosT1 * sinPhi;
      final double d1y = -rx * sinT1 * sinPhi + ry * cosT1 * cosPhi;
      final double d2x = -rx * sinT2 * cosPhi - ry * cosT2 * sinPhi;
      final double d2y = -rx * sinT2 * sinPhi + ry * cosT2 * cosPhi;

      path.cubicTo(
        px + t * d1x, py + t * d1y,
        ex - t * d2x, ey - t * d2y,
        ex, ey,
      );

      px = ex;
      py = ey;
      theta = theta2;
    }
  }
}

/// Streams SVG path-data tokens: single-letter commands and numbers.
/// Handles comma/whitespace separation and scientific notation. Arc flags
/// get a dedicated reader (flag()) because compact exporters write them
/// with NO separator ("...0 01.5.3..." where the two flags are '0' and
/// '1') — reading them with the general number regex would swallow the
/// following coordinate.
class _PathTokenizer {
  final String s;
  int i = 0;

  _PathTokenizer(this.s);

  void _skipSep() {
    while (i < s.length) {
      final int c = s.codeUnitAt(i);
      if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x2C) {
        i++;
      } else {
        break;
      }
    }
  }

  /// Next command letter, or null at end of data.
  String? nextCommand() {
    _skipSep();
    if (i >= s.length) return null;
    final String ch = s[i];
    if (RegExp(r'[a-zA-Z]').hasMatch(ch)) {
      i++;
      return ch;
    }
    return null; // Number where a command was expected — caller decides.
  }

  /// True if the next token is a number (used for implicit command repeats).
  bool hasNumber() {
    _skipSep();
    if (i >= s.length) return false;
    final String ch = s[i];
    return RegExp(r'[0-9+\-.]').hasMatch(ch);
  }

  /// Consumes and returns the next number. Throws if none — the caller
  /// catches and keeps whatever parsed cleanly.
  double number() {
    _skipSep();
    final m = RegExp(r'[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?')
        .matchAsPrefix(s, i);
    if (m == null) throw const FormatException('expected number');
    i = m.end;
    return double.parse(m.group(0)!);
  }

  /// Consumes an arc FLAG: exactly one '0' or '1' character. The SVG spec
  /// allows flags to be written with no separator before the next value
  /// ("large-arc sweep x" as "01.5"), which the general number regex would
  /// mis-read as the single number 01.5, corrupting every coordinate after
  /// it — the classic cause of arc paths exploding into garbage geometry.
  double flag() {
    _skipSep();
    if (i >= s.length) throw const FormatException('expected flag');
    final String ch = s[i];
    if (ch == '0' || ch == '1') {
      i++;
      return ch == '1' ? 1.0 : 0.0;
    }
    throw const FormatException('expected flag 0/1');
  }
}