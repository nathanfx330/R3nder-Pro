// ./lib/terminal_painter.dart

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'engine.dart';
import 'svg_path.dart';

part 'terminal_glyph_cache.dart';

class TerminalPainter extends CustomPainter {
  final TerminalEngine engine;
  final String fontFamily;

  TerminalPainter({
    required this.engine,
    required this.fontFamily,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 1. SCALING & ASPECT RATIO FIX
    // Protect against Size.infinite if parent provides no bounds
    double drawWidth = size.width.isInfinite ? engine.width : size.width;
    double drawHeight = size.height.isInfinite ? engine.height : size.height;

    // Use uniform scaling to maintain the 16:9 aspect ratio (or whatever the target is)
    double scale = math.min(drawWidth / engine.width, drawHeight / engine.height);

    canvas.save();

    // Fill the physical widget bounds (creates letterboxing if aspect ratios don't match)
    canvas.drawRect(
      Rect.fromLTWH(0, 0, drawWidth, drawHeight),
      Paint()..color = const Color(0xFF0A0F0A), // Very dark background for letterboxing
    );

    // Center the logical engine canvas within the physical bounds
    canvas.translate(
      (drawWidth - engine.width * scale) / 2,
      (drawHeight - engine.height * scale) / 2,
    );
    canvas.scale(scale, scale);

    // Fill the logical engine background
    canvas.drawRect(
      Rect.fromLTWH(0, 0, engine.width, engine.height),
      Paint()..color = engine.bgColor,
    );

    // SVG STENCIL SHOW: while an [SVG] / [SVGFLASH] hold is active, the
    // terminal screen IS the stencil — the text buffer was wiped on entry,
    // so we draw the vector fit-and-centered inside the margins and skip
    // the text/cursor pass entirely. DETERMINISM: which stencil and what
    // color come straight from the engine (pure functions of frame-counted
    // state), so live preview, scrubbing, and export render identically.
    final SvgDocument? svg = engine.activeSvgDocument;
    if (engine.activeSvg != null && svg != null) {
      _drawSvgStencil(canvas, svg, engine.activeSvgColor);
      canvas.restore();
      return;
    }

    // PHOTO ONION STACK: one or more [PHOTO] layers live on the terminal
    // screen. We draw the whole stack BOTTOM-TO-TOP, each layer fit-and-
    // centered and clipped to its OWN scanline progress. Off-pixels draw
    // nothing (see _drawPhotoStencil), so wherever an upper layer has no
    // phosphor, the layers beneath show straight through — a solid mesh,
    // then its wireframe scanning in over it, all in the same tint, like
    // peeling into an onion. Then, exactly like the single-photo path did,
    // we return: the photo stack owns the screen (no text/cursor over it)
    // until an explicit wipe clears it.
    //
    // Same-size source images align perfectly (they contain-fit off the
    // same box); differently-proportioned layers each center to their own
    // aspect, as a single photo always has.
    //
    // DETERMINISM: each layer's revealProgress is a pure function of its
    // frame-counted elapsed, so the whole stack renders identically live,
    // scrubbed, and baked.
    if (engine.hasPhotos) {
      for (final layer in engine.photoStack) {
        final ImgStencil? stencil = engine.photoStencilFor(layer);
        if (stencil != null) {
          _drawPhotoStencil(canvas, stencil, layer);
        }
      }
      canvas.restore();
      return;
    }

    double yOffset = engine.marginY;

    // 2. LAYOUT DIVERGENCE FIX
    // Use the pre-calculated width passed directly from the engine instead of recalculating
    double getStartX(double lineWidth, String align) {
      double maxW = engine.width - (engine.marginX * 2);
      if (align == "CENTER") {
        return engine.marginX + (maxW - lineWidth) / 2;
      } else if (align == "RIGHT") {
        return engine.width - engine.marginX - lineWidth;
      }
      return engine.marginX;
    }

    // Returns (drawFg, drawBg, skipRender) based on flash effects
    _FlashResult getFlashColors(CharData cd) {
      Color drawFg = cd.fgColor;
      Color? drawBg = cd.bgColor;
      bool skipRender = false;

      if (cd.flashStyle == "INVERT") {
        int cycle = engine.frameCount % 30;
        if (cycle < 3 || (6 <= cycle && cycle < 9)) {
          drawBg = cd.fgColor;
          drawFg = cd.bgColor ?? engine.bgColor;
        }
      } else if (cd.flashStyle == "SPIKE") {
        int cycle = engine.frameCount % 45;
        if (cycle < 3) {
          drawFg = const Color.fromARGB(255, 255, 255, 255);
          if (drawBg != null) {
            drawBg = const Color.fromARGB(255, 180, 180, 180);
          }
        } else if (cycle == 3) {
          skipRender = true;
        }
      } else if (cd.flashStyle == "RED" ||
          cd.flashStyle == "GREEN" ||
          cd.flashStyle == "YELLOW") {
        int cycle = engine.frameCount % 30;
        if (cycle < 3 || (6 <= cycle && cycle < 9)) {
          if (cd.flashStyle == "RED") {
            drawBg = const Color.fromARGB(255, 255, 50, 50);
          } else if (cd.flashStyle == "GREEN") {
            drawBg = const Color.fromARGB(255, 50, 255, 50);
          } else if (cd.flashStyle == "YELLOW") {
            drawBg = const Color.fromARGB(255, 255, 200, 50);
          }
          drawFg = const Color.fromARGB(255, 0, 0, 0);
        }
      } else if (cd.flashStyle == "WAVE") {
        int wavePhase = (engine.frameCount - cd.spatialIndex) % 60;
        if (wavePhase < 15) {
          drawBg = cd.fgColor;
          drawFg = cd.bgColor ?? engine.bgColor;
        }
      }

      return _FlashResult(drawFg, drawBg, skipRender);
    }

    // Helper: Draws a single line and returns the ending X coordinate.
    //
    // GLYPH CACHE: every character resolves to a pre-laid-out TextPainter
    // from _GlyphCache — layout() runs only on first sight of a
    // (char, family, size, color) combination. Per-glyph advance
    // (tp.width + tracking) is identical to what the engine used for
    // wrapping and alignment, so painter and engine can never diverge.
    double drawLine(List<CharData> chars, double startX, double yPos) {
      double xPos = startX;
      for (var cd in chars) {
        String drawChar = cd.char;

        // Resolve Bar progress directly from terminal-frame age.
        if (cd.barInfo != null) {
          final state = cd.barInfo!.state;
          final double progressRatio = state.progressAt(engine.frameCount);
          final int fillCount = (progressRatio * state.width).toInt();
          drawChar = (cd.barInfo!.index < fillCount) ? cd.barInfo!.fill : cd.barInfo!.empty;
        }

        final flash = getFlashColors(cd);

        final TextPainter tp =
            _GlyphCache.glyph(drawChar, fontFamily, cd.fontSize, flash.fg);

        if (!flash.skip) {
          // Draw Background Rect if present
          if (flash.bg != null) {
            // We pad the background rect slightly based on the font size to make block-tags look solid
            canvas.drawRect(
              Rect.fromLTWH(
                xPos,
                yPos,
                tp.width + engine.tracking,
                cd.fontSize * 1.2, // Rough line-height estimation
              ),
              Paint()..color = flash.bg!,
            );
          }

          // Draw the actual character
          tp.paint(canvas, Offset(xPos, yPos));
        }

        xPos += tp.width + engine.tracking;
      }
      return xPos;
    }

    // 1. Draw all finalized lines using the Engine's line width.
    // A line carrying an [IMG] band draws its tiles instead of chars.
    for (var lineData in engine.renderedLines) {
      double startX = getStartX(lineData.width, lineData.align);
      if (lineData.imgBand != null) {
        _drawImgBand(canvas, lineData.imgBand!, startX, yOffset);
      } else {
        drawLine(lineData.chars, startX, yOffset);
      }
      yOffset += lineData.spacing;
    }

    // 2. Draw the currently typing line using the Engine's current width
    double startX = getStartX(engine.currentLineWidth, engine.currentAlign);
    double xOffset = drawLine(engine.currentLine, startX, yOffset);

    // 3. Draw Scrambling Target Character (Hacker effect)
    // DETERMINISM: the glyph comes from the engine (pure function of
    // frameCount + read-head state), not wall-clock time. The same frame
    // always renders the same character — live, scrubbed, or baked.
    // The brightened color derives from the pen color, so its cardinality
    // is as bounded as the pen palette itself — cache-friendly.
    if (engine.isScrambling && engine.scrambleFramesLeft > 0) {
      final String randChar = engine.scrambleDisplayChar;

      // Slightly brighter version of the pen color for the scramble char.
      // (.r/.g/.b are 0.0-1.0 doubles; the old .red/.green/.blue are deprecated.)
      int r = math.min(255, (engine.penColor.r * 255).round() + 50);
      int g = math.min(255, (engine.penColor.g * 255).round() + 50);
      int b = math.min(255, (engine.penColor.b * 255).round() + 50);
      Color scrambleColor = Color.fromARGB(255, r, g, b);

      final TextPainter tp = _GlyphCache.glyph(
          randChar, fontFamily, engine.currentFontSize, scrambleColor);

      if (engine.penBg != null) {
        canvas.drawRect(
          Rect.fromLTWH(xOffset, yOffset, tp.width + engine.tracking, engine.currentFontSize * 1.2),
          Paint()..color = engine.penBg!,
        );
      }
      tp.paint(canvas, Offset(xOffset, yOffset));
      xOffset += tp.width + engine.tracking;
    }

    // 4. Draw the blinking terminal cursor
    //
    // METRICS FIX: the cursor is anchored to the alphabetic baseline of a
    // reference glyph laid out in the EXACT same style the text uses, so it
    // tracks whatever font fontconfig actually resolves on any distro
    // (Ubuntu Mono on Ubuntu, DejaVu on Rocky, ...). The baseline is now
    // cached per (fontFamily, fontSize) in _GlyphCache — it was previously
    // re-laid-out every blink-on frame.
    if ((engine.frameCount ~/ (engineFps ~/ 2)) % 2 == 0) {
      // Distance from the top of the line box (where tp.paint anchors) down
      // to the alphabetic baseline, in the font that ACTUALLY resolved.
      final double baseline =
          _GlyphCache.baseline(fontFamily, engine.currentFontSize);

      final double cursorX = xOffset + (5 * engine.scale);
      final double cursorW = engine.currentFontSize * 0.5;

      // Cap-height-ish block: bottom locked to the glyph baseline, height
      // proportional to the real ascent rather than the nominal font size.
      final double cursorH = baseline * 0.78;
      final double cursorTop = yOffset + baseline - cursorH;

      canvas.drawRect(
        Rect.fromLTWH(cursorX, cursorTop, cursorW, cursorH),
        Paint()..color = engine.penColor,
      );
    }

    // Restore the canvas to prevent transformation leaks
    canvas.restore();
  }

  /// Draws an [IMG] band: Programmed Symbols tile stamping.
  ///
  /// Each revealed copy is one translate + scale + drawPath. The stencil
  /// path lives in native pixel coordinates; scaling by drawScale turns
  /// each 1px-tall run rect into a hard-edged block of scaled pixels.
  ///
  /// AUTHENTICITY CONTRACT:
  ///  - isAntiAlias = false: no smoothing, no soft edges, ever. A scaled
  ///    pixel is a razor-edged rectangle, exactly like a character-cell
  ///    ROM glyph on a real tube.
  ///  - Off pixels draw NOTHING — the terminal background shows through.
  ///    No black is ever painted; only pen-tinted phosphor goes on screen.
  ///  - Copies butt together edge to edge (seamless repeating pattern) and
  ///    reveal left to right on the engine's frame-counted cadence.
  ///
  /// DETERMINISM: revealedCopies is a pure function of the shared state's
  /// elapsed counter, which the engine advances tick by tick — the same
  /// frame renders the same copies live, scrubbed, or baked.
  void _drawImgBand(
      Canvas canvas, ImgBandData band, double startX, double yPos) {
    final int revealed = band.state.revealedCopies;
    if (revealed <= 0) return;

    final Paint fill = Paint()
      ..color = band.color
      ..style = PaintingStyle.fill
      ..isAntiAlias = false;

    final double tileW = band.tileDrawW;

    // SCANLINE, single tile only. A repeating band reveals by copy, so it is
    // already animating and a clip on top would be two competing reveals on
    // one element. One tile has nothing to stagger, so the scanline is what
    // its framesPer buys.
    final double progress = band.state.scanProgress;
    if (progress <= 0.0) return;

    canvas.save();
    if (progress < 1.0) {
      canvas.clipRect(
          Rect.fromLTWH(startX, yPos, tileW, band.tileDrawH * progress));
    }

    for (int i = 0; i < revealed; i++) {
      canvas.save();
      canvas.translate(startX + i * tileW, yPos);
      canvas.scale(band.drawScale, band.drawScale);
      canvas.drawPath(band.stencil.path, fill);
      canvas.restore();
    }

    canvas.restore();
  }

  /// Draws the active SVG stencil scaled to CONTAIN inside the terminal's
  /// margin box, centered, filled with [color]. The path lives in viewBox
  /// coordinates; we map viewBox -> margin box with a uniform scale so the
  /// artwork never distorts, whatever its aspect ratio.
  ///
  /// One save/restore pair wraps the transform; the fill uses a single
  /// anti-aliased Paint. No strokes, no gradients — the stencil contract.
  void _drawSvgStencil(Canvas canvas, SvgDocument svg, Color color) {
    // Content box inside the margins (same box the text lays out in).
    final double boxLeft = engine.marginX;
    final double boxTop = engine.marginY;
    final double boxW = math.max(engine.width - engine.marginX * 2, 1.0);
    final double boxH = math.max(engine.height - engine.marginY * 2, 1.0);

    // Uniform contain-fit of the viewBox into the box.
    final double fit = math.min(boxW / svg.viewWidth, boxH / svg.viewHeight);

    // Center the fitted artwork.
    final double drawW = svg.viewWidth * fit;
    final double drawH = svg.viewHeight * fit;
    final double dx = boxLeft + (boxW - drawW) / 2;
    final double dy = boxTop + (boxH - drawH) / 2;

    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(fit, fit);
    // Shift the viewBox origin (often 0,0, but not always) to our origin.
    canvas.translate(-svg.viewLeft, -svg.viewTop);

    canvas.drawPath(
      svg.path,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill
        ..isAntiAlias = true,
    );

    canvas.restore();
  }

  /// Draws ONE [PHOTO] layer's stencil fit-and-centered inside the
  /// terminal's margin box. Uses the same ImgStencil path as IMG bands, but
  /// scales it uniformly and applies a top-to-bottom clipping rect to
  /// simulate a slow wirephoto scanline reveal.
  ///
  /// Called once per stack layer, bottom-to-top. Each call is fully
  /// self-contained (its own save/clip/transform/restore), so layers
  /// composite naturally: off-pixels paint nothing, so wherever this layer
  /// is empty the ones beneath show through — that's the onion.
  void _drawPhotoStencil(Canvas canvas, ImgStencil stencil, ActivePhotoShow photo) {
    final double boxLeft = engine.marginX;
    final double boxTop = engine.marginY;
    final double boxW = math.max(engine.width - engine.marginX * 2, 1.0);
    final double boxH = math.max(engine.height - engine.marginY * 2, 1.0);

    // Uniform contain-fit
    final double fit = math.min(boxW / stencil.pxWidth, boxH / stencil.pxHeight);
    final double drawW = stencil.pxWidth * fit;
    final double drawH = stencil.pxHeight * fit;
    final double dx = boxLeft + (boxW - drawW) / 2;
    final double dy = boxTop + (boxH - drawH) / 2;

    canvas.save();

    // SCANLINE REVEAL: Clip the canvas top-to-bottom based on elapsed frames.
    final double progress = photo.revealProgress;
    if (progress < 1.0) {
      canvas.clipRect(Rect.fromLTWH(dx, dy, drawW, drawH * progress));
    }

    canvas.translate(dx, dy);
    canvas.scale(fit, fit);

    // isAntiAlias = false guarantees the hard phosphor look just like IMG tags
    canvas.drawPath(
      stencil.path,
      Paint()
        ..color = photo.color
        ..style = PaintingStyle.fill
        ..isAntiAlias = false,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant TerminalPainter oldDelegate) {
    // In our live preview, we want to repaint every tick.
    return oldDelegate.engine.frameCount != engine.frameCount ||
           oldDelegate.fontFamily != fontFamily;
  }
}

class _FlashResult {
  final Color fg;
  final Color? bg;
  final bool skip;
  _FlashResult(this.fg, this.bg, this.skip);
}