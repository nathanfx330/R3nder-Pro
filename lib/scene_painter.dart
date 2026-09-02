// ./lib/scene_painter.dart

import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

import 'scene_engine.dart';
import 'motion.dart';
import 'folder_captions.dart';
// Dart imports are not transitive: scene_engine.dart imports (and engine.dart
// re-exports) this library, but that makes BrowserScroll visible to THEM, not
// to us. Named directly rather than relied on second-hand.
import 'presentation_requests.dart';
import 'terminal_painter.dart';

part 'scene_painter_style.dart';

class ScenePainter extends CustomPainter {
  final SceneEngine scene;
  final String fontFamily;

  ScenePainter({required this.scene, required this.fontFamily});

  /// True when the bake wants a real alpha channel.
  ///
  /// Under this model the terminal is a solid object: it keeps its own
  /// background color, and alpha describes only the region outside it. Two
  /// backdrop fills must be suppressed or that region comes out opaque: the
  /// letterbox fill, and the chroma plate in _drawDesktopBackground.
  ///
  /// TerminalPainter deliberately does NOT consult this. The terminal always
  /// fills, whether it is drawn fullscreen or nested inside the parked
  /// preroll window, which is what keeps the reveal seamless as the window
  /// grows into the frame.
  bool get _transparentBg => scene.transparentBackdrop;

  @override
  void paint(Canvas canvas, Size size) {
    // ------------------------------------------------------------------
    // CLASSIC PATH: no desktop configured -> pure delegate.
    // Renders exactly as R3nder always has, fullscreen, no chrome.
    // We only take this fast path if we are NOT in a preroll phase.
    // ------------------------------------------------------------------
    if (!scene.hasDesktop && scene.phase == ScenePhase.terminal) {
      TerminalPainter(engine: scene.terminal, fontFamily: fontFamily)
          .paint(canvas, size);
      return;
    }

    // ------------------------------------------------------------------
    // DESKTOP & PREROLL PATH
    //
    // At rest (ScenePhase.terminal) the terminal fills the frame with no
    // chrome — visually identical to classic mode. The desktop only exists
    // during a gallery sequence or during the preroll wipe reveal.
    //
    // CHAINING: when scene.isChainClosing / scene.isChainOpening are set,
    // the closing and opening phases keep the terminal at zero opacity —
    // presentations hand off directly on the desktop with no terminal
    // fade between them.
    // ------------------------------------------------------------------
    final double engineW = scene.width;
    final double engineH = scene.height;
    final double s = scene.terminal.scale;

    double drawWidth = size.width.isInfinite ? engineW : size.width;
    double drawHeight = size.height.isInfinite ? engineH : size.height;

    // Uniform scale + centering into physical bounds (same approach as
    // TerminalPainter, so preview and export can never diverge).
    final double fit = math.min(drawWidth / engineW, drawHeight / engineH);

    canvas.save();

    // See the matching note in TerminalPainter. This full-canvas fill is a
    // preview letterbox, and painting it during an alpha export made every
    // frame opaque before a single glyph was drawn.
    if (!_transparentBg) {
      canvas.drawRect(
        Rect.fromLTWH(0, 0, drawWidth, drawHeight),
        Paint()..color = const Color(0xFF000000),
      );
    }
    canvas.translate(
      (drawWidth - engineW * fit) / 2,
      (drawHeight - engineH * fit) / 2,
    );
    canvas.scale(fit, fit);
    canvas.clipRect(Rect.fromLTWH(0, 0, engineW, engineH));

    final Rect fullRect = Rect.fromLTWH(0, 0, engineW, engineH);
    final Rect parkedRect = _terminalParkedRect(engineW, engineH);

    // Terminal opacity during transitional phases, chain-aware:
    // - Opening from a chain: previous presentation just left, terminal is
    //   already hidden and stays hidden.
    // - Closing into a chain: next presentation is coming, terminal stays
    //   hidden instead of fading back in.
    final double openingTermOpacity =
        scene.isChainOpening ? 0.0 : 1.0 - scene.phaseProgress;
    final double closingTermOpacity =
        scene.isChainClosing ? 0.0 : scene.phaseProgress;

    // --- Calculate Focus Dimming (Vignette Fade Timing) ---
    double timelineDim = 0.0;
    if (scene.hasActiveTimeline && scene.timelineFocusMode) {
      final double maxDim = 0.90; // Stronger max dim to account for the center falloff
      if (scene.phase == ScenePhase.timelineOpening) {
        // Smooth ease over the whole slide, reaching 100% right before panel stops
        double p = (scene.phaseProgress / 0.9).clamp(0.0, 1.0);
        timelineDim = Curves.easeInOut.transform(p) * maxDim;
      } else if (scene.phase == ScenePhase.timelineShowing) {
        timelineDim = maxDim;
      } else if (scene.phase == ScenePhase.timelineClosing) {
        // Start clearing immediately, finish clearing by the time the panel is 80% out
        double p = (scene.phaseProgress / 0.8).clamp(0.0, 1.0);
        timelineDim = (1.0 - Curves.easeInOut.transform(p)) * maxDim;
      }
    }

    switch (scene.phase) {
      case ScenePhase.prerollIdle:
        _drawDesktopBackground(canvas, engineW, engineH);
        break;

      case ScenePhase.prerollWipe:
        _drawDesktopBackground(canvas, engineW, engineH);
        _drawWipeAnimation(canvas, parkedRect, scene.phaseProgress, () {
          _drawTerminalWindowAt(canvas, parkedRect, engineW, s, chrome: 1.0);
        });
        break;

      case ScenePhase.terminal:
        // Fullscreen terminal, no chrome, no wallpaper. The classic look.
        TerminalPainter(engine: scene.terminal, fontFamily: fontFamily)
            .paint(canvas, Size(engineW, engineH));
        break;

      case ScenePhase.termZoomOut:
        _drawZoomReveal(canvas, fullRect, parkedRect, engineW, engineH, s,
            t: scene.phaseProgress);
        break;

      case ScenePhase.termZoomIn:
        _drawZoomReveal(canvas, fullRect, parkedRect, engineW, engineH, s,
            t: 1.0 - scene.phaseProgress);
        break;

      case ScenePhase.viewerOpening:
        // Terminal fades OUT as the viewer opens (stays hidden if chained).
        _drawDesktopWithParkedTerminal(canvas, parkedRect, engineW, engineH, s,
            terminalOpacity: openingTermOpacity);
        _drawViewerWindow(canvas, engineW, engineH, s,
            openness: scene.phaseProgress);
        break;

      case ScenePhase.viewerShowing:
        // Terminal is completely hidden while the viewer is showing
        _drawDesktopWithParkedTerminal(canvas, parkedRect, engineW, engineH, s,
            terminalOpacity: 0.0);
        _drawViewerWindow(canvas, engineW, engineH, s, openness: 1.0);
        break;

      case ScenePhase.viewerTransition:
        // Terminal is completely hidden during transitions
        _drawDesktopWithParkedTerminal(canvas, parkedRect, engineW, engineH, s,
            terminalOpacity: 0.0);
        _drawViewerWindow(canvas, engineW, engineH, s,
            openness: 1.0, transitionProgress: scene.phaseProgress);
        break;

      case ScenePhase.viewerClosing:
        // Terminal fades back IN as the viewer closes (unless chaining —
        // then it stays hidden and the next presentation opens directly).
        _drawDesktopWithParkedTerminal(canvas, parkedRect, engineW, engineH, s,
            terminalOpacity: closingTermOpacity);
        _drawViewerWindow(canvas, engineW, engineH, s,
            openness: 1.0 - scene.phaseProgress);
        break;

      case ScenePhase.appOpening:
        // Terminal fades OUT as the app opens (stays hidden if chained).
        _drawDesktopWithParkedTerminal(canvas, parkedRect, engineW, engineH, s,
            terminalOpacity: openingTermOpacity);
        _drawAppWindow(canvas, engineW, engineH, s,
            openness: scene.phaseProgress);
        break;

      case ScenePhase.appShowing:
        // Terminal fully hidden, app fully open, tiles cascade in.
        _drawDesktopWithParkedTerminal(canvas, parkedRect, engineW, engineH, s,
            terminalOpacity: 0.0);
        _drawAppWindow(canvas, engineW, engineH, s, openness: 1.0);
        break;

      case ScenePhase.appPanning:
        // MOSAIC only. The window is stationary and fully open; the panel
        // surface inside it slides to the next page.
        _drawDesktopWithParkedTerminal(canvas, parkedRect, engineW, engineH, s,
            terminalOpacity: 0.0);
        _drawAppWindow(canvas, engineW, engineH, s, openness: 1.0);
        break;

      case ScenePhase.appMaximizing:
      case ScenePhase.appRestoring:
        // MOSAIC only. The window itself is growing into or shrinking out of
        // the frame; the terminal stays hidden behind it either way.
        _drawDesktopWithParkedTerminal(canvas, parkedRect, engineW, engineH, s,
            terminalOpacity: 0.0);
        _drawAppWindow(canvas, engineW, engineH, s, openness: 1.0);
        break;

      case ScenePhase.appClosing:
        // Terminal fades back IN as the app closes (unless chaining).
        _drawDesktopWithParkedTerminal(canvas, parkedRect, engineW, engineH, s,
            terminalOpacity: closingTermOpacity);
        _drawAppWindow(canvas, engineW, engineH, s,
            openness: 1.0 - scene.phaseProgress);
        break;

      case ScenePhase.browserOpening:
        // Terminal fades OUT as the browser opens (stays hidden if chained).
        _drawDesktopWithParkedTerminal(canvas, parkedRect, engineW, engineH, s,
            terminalOpacity: openingTermOpacity);
        _drawBrowserWindow(canvas, engineW, engineH, s,
            openness: scene.phaseProgress);
        break;

      case ScenePhase.browserShowing:
      case ScenePhase.browserNavigating:
        // The window is stationary and fully open either way. A navigation
        // happens inside it: the address bar has already cut, the load bar
        // sweeps, and the capture is replaced. Nothing about the window
        // itself moves, which is the point of not making this a page pan.
        _drawDesktopWithParkedTerminal(canvas, parkedRect, engineW, engineH, s,
            terminalOpacity: 0.0);
        _drawBrowserWindow(canvas, engineW, engineH, s, openness: 1.0);
        break;

      case ScenePhase.browserMaximizing:
      case ScenePhase.browserRestoring:
        // FULL only. The window is growing into or shrinking out of the
        // frame; the terminal stays hidden behind it either way. The same
        // treatment the maximizing mosaic gets, and the geometry that makes
        // the two differ lives in _drawBrowserWindow rather than here.
        _drawDesktopWithParkedTerminal(canvas, parkedRect, engineW, engineH, s,
            terminalOpacity: 0.0);
        _drawBrowserWindow(canvas, engineW, engineH, s, openness: 1.0);
        break;

      case ScenePhase.browserClosing:
        // Terminal fades back IN as the browser closes (unless chaining).
        _drawDesktopWithParkedTerminal(canvas, parkedRect, engineW, engineH, s,
            terminalOpacity: closingTermOpacity);
        _drawBrowserWindow(canvas, engineW, engineH, s,
            openness: 1.0 - scene.phaseProgress);
        break;

      case ScenePhase.cardOpening:
        // Terminal fades OUT as the card slides in (stays hidden if chained).
        _drawDesktopWithParkedTerminal(canvas, parkedRect, engineW, engineH, s,
            terminalOpacity: openingTermOpacity);
        _drawCardPanel(canvas, engineW, engineH, s, slide: scene.cardSlide);
        break;

      case ScenePhase.cardShowing:
        // Card alone on the bare desktop — exclusive presentation.
        _drawDesktopWithParkedTerminal(canvas, parkedRect, engineW, engineH, s,
            terminalOpacity: 0.0);
        _drawCardPanel(canvas, engineW, engineH, s, slide: 1.0);
        break;

      case ScenePhase.cardClosing:
        // Terminal fades back IN as the card slides out (unless chaining).
        _drawDesktopWithParkedTerminal(canvas, parkedRect, engineW, engineH, s,
            terminalOpacity: closingTermOpacity);
        _drawCardPanel(canvas, engineW, engineH, s, slide: scene.cardSlide);
        break;

      // ----------------------------------------------------------------
      // DOSSIER: all card-slide and gallery-open values come from the
      // engine's dossierCardSlide / dossierGalleryOpenness accessors,
      // which own the cardLead choreography (card alone -> gallery joins).
      // The painter just draws what they say.
      // ----------------------------------------------------------------
      case ScenePhase.dossierOpening:
        _drawDesktopWithParkedTerminal(canvas, parkedRect, engineW, engineH, s,
            terminalOpacity: openingTermOpacity);
        _drawDossierPanel(canvas, engineW, engineH, s,
            slide: scene.dossierCardSlide);
        _drawDossierGallery(canvas, engineW, engineH, s,
            openProgress: scene.dossierGalleryOpenness, transitionT: 0.0);
        break;

      case ScenePhase.dossierCardLead:
        // Card seated alone on the bare desktop, counting down its lead.
        // dossierGalleryOpenness is 0 here, so the gallery draw no-ops.
        _drawDesktopWithParkedTerminal(canvas, parkedRect, engineW, engineH, s,
            terminalOpacity: 0.0);
        _drawDossierPanel(canvas, engineW, engineH, s,
            slide: scene.dossierCardSlide);
        break;

      case ScenePhase.dossierGalleryOpening:
        // Gallery window animates open beside the already-seated card.
        _drawDesktopWithParkedTerminal(canvas, parkedRect, engineW, engineH, s,
            terminalOpacity: 0.0);
        _drawDossierPanel(canvas, engineW, engineH, s,
            slide: scene.dossierCardSlide);
        _drawDossierGallery(canvas, engineW, engineH, s,
            openProgress: scene.dossierGalleryOpenness, transitionT: 0.0);
        break;

      case ScenePhase.dossierSplitShowing:
        _drawDesktopWithParkedTerminal(canvas, parkedRect, engineW, engineH, s,
            terminalOpacity: 0.0);
        _drawDossierPanel(canvas, engineW, engineH, s,
            slide: scene.dossierCardSlide);
        _drawDossierGallery(canvas, engineW, engineH, s,
            openProgress: scene.dossierGalleryOpenness, transitionT: 0.0);
        break;

      case ScenePhase.dossierTransitioning:
        _drawDesktopWithParkedTerminal(canvas, parkedRect, engineW, engineH, s,
            terminalOpacity: 0.0);
        // Card slides out while gallery transitions
        _drawDossierPanel(canvas, engineW, engineH, s,
            slide: scene.dossierCardSlide);
        _drawDossierGallery(canvas, engineW, engineH, s,
            openProgress: scene.dossierGalleryOpenness,
            transitionT: Curves.easeInOutCubic.transform(scene.phaseProgress));
        break;

      case ScenePhase.dossierFullShowing:
        _drawDesktopWithParkedTerminal(canvas, parkedRect, engineW, engineH, s,
            terminalOpacity: 0.0);
        _drawDossierGallery(canvas, engineW, engineH, s,
            openProgress: scene.dossierGalleryOpenness, transitionT: 1.0);
        break;

      case ScenePhase.dossierMosaicPanning:
        _drawDesktopWithParkedTerminal(canvas, parkedRect, engineW, engineH, s,
            terminalOpacity: 0.0);
        _drawDossierGallery(canvas, engineW, engineH, s,
            openProgress: scene.dossierGalleryOpenness, transitionT: 1.0);
        break;

      case ScenePhase.dossierClosing:
        _drawDesktopWithParkedTerminal(canvas, parkedRect, engineW, engineH, s,
            terminalOpacity: closingTermOpacity);
        if (scene.dossierSideOnly) {
          _drawDossierPanel(canvas, engineW, engineH, s,
              slide: scene.dossierCardSlide);
        }
        _drawDossierGallery(canvas, engineW, engineH, s,
            openProgress: scene.dossierGalleryOpenness,
            transitionT: scene.dossierSideOnly ? 0.0 : 1.0);
        break;

      case ScenePhase.timelineOpening:
        // Terminal fades OUT as the timeline slides in (stays hidden if
        // chained). The stage window fades in with the slide.
        _drawDesktopWithParkedTerminal(canvas, parkedRect, engineW, engineH, s,
            terminalOpacity: openingTermOpacity, dimOpacity: timelineDim);
        _drawTimelineStage(canvas, engineW, engineH, s,
            slide: scene.timelineSlide);
        _drawTimelinePanel(canvas, engineW, engineH, s,
            slide: scene.timelineSlide);
        break;

      case ScenePhase.timelineShowing:
        // Timeline alone on the bare desktop — exclusive presentation.
        // Stage (if any) runs its snaking connector line in lockstep with
        // the spine event reveals.
        _drawDesktopWithParkedTerminal(canvas, parkedRect, engineW, engineH, s,
            terminalOpacity: 0.0, dimOpacity: timelineDim);
        _drawTimelineStage(canvas, engineW, engineH, s, slide: 1.0);
        _drawTimelinePanel(canvas, engineW, engineH, s, slide: 1.0);
        break;

      case ScenePhase.timelineClosing:
        // Terminal fades back IN as the timeline slides out (unless chaining).
        // Stage window fades out with the slide.
        _drawDesktopWithParkedTerminal(canvas, parkedRect, engineW, engineH, s,
            terminalOpacity: closingTermOpacity, dimOpacity: timelineDim);
        _drawTimelineStage(canvas, engineW, engineH, s,
            slide: scene.timelineSlide);
        _drawTimelinePanel(canvas, engineW, engineH, s,
            slide: scene.timelineSlide);
        break;
    }

    canvas.restore();
  }

  // --------------------------------------------------------------------
  // Shared Desktop & Preroll Helpers
  // --------------------------------------------------------------------

  /// Renders the wallpaper if available, otherwise pure chroma-key color!
  void _drawDesktopBackground(Canvas canvas, double engineW, double engineH, {double opacity = 1.0, double dimOpacity = 0.0}) {
    // If we are actively rendering a preroll sequence for keying, we force 
    // the solid chroma key color and COMPLETELY ignore the wallpaper image.
    if (scene.wallpaper != null && !scene.inPrerollSequence) {
      _drawImageCover(canvas, scene.wallpaper!, Rect.fromLTWH(0, 0, engineW, engineH), opacity: opacity);
    } else if (!_transparentBg) {
      // Draw dynamic chroma key background
      final Paint keyPaint = Paint()..color = scene.prerollColor.withValues(alpha: opacity);
      canvas.drawRect(Rect.fromLTWH(0, 0, engineW, engineH), keyPaint);
    }
    // Under an alpha format the plate is deliberately omitted. The chroma
    // color exists so you can key it away; an alpha channel already carries
    // what the key was standing in for, so painting it would just make the
    // frame opaque and throw away the transparency you asked for. The wipe
    // and zoom-up still play in full, revealing over nothing instead of
    // over green.

    // --- FOCUS OVERLAY (Radial Vignette) ---
    if (dimOpacity > 0.0) {
      final Paint vignettePaint = Paint()
        ..shader = ui.Gradient.radial(
          Offset(engineW / 2, engineH / 2),
          engineW * 0.75, // Extends slightly past the edges for a smooth falloff
          [
            Colors.black.withValues(alpha: dimOpacity * 0.3), // Center dims slightly
            Colors.black.withValues(alpha: dimOpacity),       // Edges fall into deep shadow
          ],
          [0.2, 1.0], // Fade starts a bit out from the exact center
        );
      canvas.drawRect(
        Rect.fromLTWH(0, 0, engineW, engineH),
        vignettePaint,
      );
    }
  }

  /// Geometric left-to-right wipe masking box
  void _drawWipeAnimation(Canvas canvas, Rect winRect, double progress, VoidCallback body) {
    // Sharp ease in/out for a robotic terminal wipe
    final double e = Curves.easeInOutCubic.transform(progress.clamp(0.0, 1.0));
    final Rect clip = Rect.fromLTRB(
      winRect.left,
      winRect.top,
      winRect.left + winRect.width * e, // Wipes rightward
      winRect.bottom,
    );
    canvas.save();
    canvas.clipRect(clip);
    body();
    canvas.restore();
  }

  // --------------------------------------------------------------------
  // Zoom reveal
  // --------------------------------------------------------------------

  Rect _terminalParkedRect(double engineW, double engineH) {
    // The window is sized so its CONTENT area (everything below the title
    // bar) matches the engine aspect exactly.
    //
    // Previously this inset the window from the screen edges and left it at
    // that, but _drawTerminalWindowAt then subtracts the title bar from the
    // height only. That made the content box wider than 16:9, and since
    // TerminalPainter fits itself uniformly into whatever box it is handed,
    // the surplus width became letterbox bars: 72px down each side at 1080p.
    // They were invisible while everything around them was opaque, and
    // obvious the moment the backdrop went transparent.
    //
    // Deriving the window from the content instead of the other way round
    // removes them at every scale. It also holds through the whole zoom:
    // _drawZoomReveal lerps between this rect and the full frame while the
    // title bar grows with chrome, and because both the width and the
    // content height are affine in the same parameter with the aspect ratio
    // as their slope ratio, the content stays exactly 16:9 on every
    // intermediate frame rather than growing bars mid-animation.
    final double s = scene.terminal.scale;
    final double barH = _kTitleBarHeight * s;

    final double inset = engineW * _kWindowMarginFrac;
    final double maxW = engineW - inset * 2;
    final double maxContentH = (engineH - inset * 0.75 * 2) - barH;

    final double aspect = engineW / engineH;

    double contentW = maxW;
    double contentH = contentW / aspect;
    if (contentH > maxContentH) {
      contentH = maxContentH;
      contentW = contentH * aspect;
    }

    final double winW = contentW;
    final double winH = contentH + barH;
    return Rect.fromLTWH(
        (engineW - winW) / 2, (engineH - winH) / 2, winW, winH);
  }

  /// t = 0: fullscreen terminal, no chrome, no desktop.
  /// t = 1: terminal parked as a chromed window on the wallpaper.
  void _drawZoomReveal(Canvas canvas, Rect fullRect, Rect parkedRect,
      double engineW, double engineH, double s, {required double t}) {
    final double e = Curves.easeInOut.transform(t.clamp(0.0, 1.0));

    // Wallpaper (or green screen) appears as the terminal pulls away from the edges.
    _drawDesktopBackground(canvas, engineW, engineH, opacity: e.clamp(0.0, 1.0));

    // Interpolated window rect.
    final Rect winRect = Rect.lerp(fullRect, parkedRect, e)!;

    // Chrome (title bar, shadow, corners) grows in with the pull-back.
    _drawTerminalWindowAt(canvas, winRect, engineW, s, chrome: e);
  }

  void _drawDesktopWithParkedTerminal(Canvas canvas, Rect parkedRect,
      double engineW, double engineH, double s, {double terminalOpacity = 1.0, double dimOpacity = 0.0}) {
    _drawDesktopBackground(canvas, engineW, engineH, opacity: 1.0, dimOpacity: dimOpacity);
    
    // Only draw the parked terminal if it has some opacity
    if (terminalOpacity > 0.0) {
      _drawTerminalWindowAt(canvas, parkedRect, engineW, s, chrome: 1.0, opacity: terminalOpacity);
    }
  }

  // --------------------------------------------------------------------
  // Terminal window
  // --------------------------------------------------------------------

  /// Draws the terminal into [winRect]. [chrome] 0..1 scales the title bar
  /// height, corner rounding, and shadow. [opacity] 0..1 globally fades it.
  void _drawTerminalWindowAt(Canvas canvas, Rect winRect, double engineW,
      double s, {required double chrome, double opacity = 1.0}) {
    
    if (opacity <= 0.0) return;

    // If we need to fade the terminal globally, wrap the entire drawing in a saveLayer
    final bool needsFadeLayer = opacity < 1.0;
    if (needsFadeLayer) {
      canvas.saveLayer(
        winRect.inflate(60), // inflate enough to include the drop shadow
        Paint()..color = Color.fromARGB((opacity * 255).round(), 255, 255, 255)
      );
    }

    final double barH = _kTitleBarHeight * s * chrome;
    final double radius = _kWindowCornerRadius * s * chrome;
    final RRect rrect =
        RRect.fromRectAndRadius(winRect, Radius.circular(radius));

    // Shadow — tight and flat, Yaru-style — fades in with the chrome.
    if (chrome > 0.01) {
      canvas.drawRRect(
        rrect.shift(Offset(0, 3 * s)),
        Paint()
          ..color = Color.fromARGB((chrome * 110).round(), 0, 0, 0)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 10 * s),
      );
    }

    // Window body (GNOME Terminal purple shows at any letterbox edges).
    canvas.drawRRect(rrect, Paint()..color = _kTerminalBody);

    // Terminal content below the (growing) header bar.
    final Rect content = Rect.fromLTRB(
        winRect.left, winRect.top + barH, winRect.right, winRect.bottom);

    canvas.save();
    canvas.clipRRect(rrect);
    canvas.save();
    canvas.clipRect(content);
    canvas.translate(content.left, content.top);
    // TerminalPainter scales & letterboxes itself into whatever size it's
    // given, so the terminal layout engine is completely untouched.
    TerminalPainter(engine: scene.terminal, fontFamily: fontFamily)
        .paint(canvas, Size(content.width, math.max(content.height, 1)));
    canvas.restore();

    // Header bar over the top strip.
    if (barH > 0.5) {
      _drawYaruHeaderBar(canvas,
          Rect.fromLTWH(winRect.left, winRect.top, winRect.width, barH), s,
          title: scene.terminalWindowTitle, opacity: chrome);
    }
    canvas.restore();

    if (needsFadeLayer) {
      canvas.restore();
    }
  }

  // --------------------------------------------------------------------
  // Image viewer window
  // --------------------------------------------------------------------

  void _drawViewerWindow(Canvas canvas, double engineW, double engineH,
      double s, {required double openness, double? transitionProgress}) {
    if (openness <= 0.0) return;

    final ui.Image? current = scene.galleryCurrentImage;
    if (current == null) return;

    final double inset = engineW * _kViewerMarginFrac;
    final Rect winRect = Rect.fromLTRB(
        inset, inset * 0.75, engineW - inset, engineH - inset * 0.75);

    _withWindowAnimation(canvas, winRect, openness, () {
      final double barH = _kTitleBarHeight * s;
      final RRect rrect = RRect.fromRectAndRadius(
          winRect, Radius.circular(_kWindowCornerRadius * s));

      // Shadow
      canvas.drawRRect(
        rrect.shift(Offset(0, 3 * s)),
        Paint()
          ..color = const Color(0x6E000000)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 10 * s),
      );

      // Body
      canvas.drawRRect(rrect, Paint()..color = _kViewerBody);

      final Rect content = Rect.fromLTRB(
          winRect.left, winRect.top + barH, winRect.right, winRect.bottom);

      canvas.save();
      canvas.clipRRect(rrect);
      canvas.save();
      canvas.clipRect(content);

      if (transitionProgress == null) {
        _drawImageContain(canvas, current, content, opacity: 1.0);
      } else {
        final ui.Image? prev = scene.galleryPrevImage;
        final String style = scene.galleryTransitionStyle;

        if (style == 'FADE') {
          if (prev != null) {
            _drawImageContain(canvas, prev, content,
                opacity: 1.0 - transitionProgress);
          }
          _drawImageContain(canvas, current, content,
              opacity: transitionProgress);
        } else {
          // FLIP: page collapses horizontally, then the next expands.
          final double cx = content.center.dx;
          if (transitionProgress < 0.5 && prev != null) {
            final double sx = 1.0 - (transitionProgress * 2.0);
            canvas.save();
            canvas.translate(cx, 0);
            canvas.scale(math.max(sx, 0.001), 1.0);
            canvas.translate(-cx, 0);
            _drawImageContain(canvas, prev, content, opacity: 1.0);
            canvas.restore();
          } else {
            final double sx = ((transitionProgress - 0.5) * 2.0);
            canvas.save();
            canvas.translate(cx, 0);
            canvas.scale(math.max(sx, 0.001), 1.0);
            canvas.translate(-cx, 0);
            _drawImageContain(canvas, current, content, opacity: 1.0);
            canvas.restore();
          }
        }
      }
      canvas.restore();

      // Header bar (title comes from the [GALLERY:...] tag's title segment).
      _drawYaruHeaderBar(canvas,
          Rect.fromLTWH(winRect.left, winRect.top, winRect.width, barH), s,
          title: scene.galleryTitle, opacity: 1.0);
      canvas.restore();
    });
  }

  // --------------------------------------------------------------------
  // Browser window
  // --------------------------------------------------------------------

  /// Draws the browser: chrome, viewport, capture, scrollbar.
  ///
  /// THE DIVISION OF LABOUR. The engine says how far through the page's
  /// travel this frame is, as a fraction, from frame counts alone. This
  /// method turns that into pixels, because only here is the viewport known.
  /// A page shorter than its viewport reports the same travel and simply has
  /// no overflow to spend it on, which is why nothing upstream has to know
  /// how tall any capture is — and why the frame count cannot depend on it.
  void _drawBrowserWindow(Canvas canvas, double engineW, double engineH,
      double s, {required double openness}) {
    if (openness <= 0.0) return;
    if (!scene.hasActiveBrowser) return;

    final double inset = engineW * _kBrowserMarginFrac;
    final Rect deskRect = Rect.fromLTRB(
        inset, inset * 0.7, engineW - inset, engineH - inset * 0.7);
    final double cr = _kWindowCornerRadius * s;

    // A browser that does not maximize never leaves its desktop rect. This
    // is the whole of the windowed path and none of the geometry below
    // applies to it.
    if (!scene.browserMaximizes) {
      _withWindowAnimation(canvas, deskRect, openness,
          () => _paintBrowserWindow(canvas, deskRect, cr, s));
      return;
    }

    final Rect frame = Rect.fromLTWH(0, 0, engineW, engineH);

    late final Rect rect;
    late final double radius;
    bool windowAnim = false;

    switch (scene.phase) {
      case ScenePhase.browserMaximizing:
        final double t = Curves.easeInOutCubic.transform(scene.phaseProgress);
        rect = Rect.lerp(deskRect, frame, t)!;
        radius = cr * (1.0 - t);
        break;

      case ScenePhase.browserRestoring:
        final double t = Curves.easeInOutCubic.transform(scene.phaseProgress);
        rect = Rect.lerp(frame, deskRect, t)!;
        radius = cr * t;
        break;

      case ScenePhase.browserShowing:
      case ScenePhase.browserNavigating:
        rect = frame;
        radius = 0.0;
        break;

      default: // browserOpening, browserClosing: a window on the desktop.
        rect = deskRect;
        radius = cr;
        windowAnim = true;
        break;
    }

    void body() => _paintBrowserWindow(canvas, rect, radius, s);

    if (windowAnim) {
      _withWindowAnimation(canvas, rect, openness, body);
    } else {
      body();
    }
  }

  /// Paints the browser at its current geometry.
  ///
  /// NOTE WHAT IS MISSING COMPARED TO THE MOSAIC: there is no `chrome`
  /// parameter. The maximizing mosaic fades its title bar out and lets the
  /// panels grow into the vacated height, because there the bar is dressing
  /// and the panels are the content. A browser's tab strip and address bar
  /// are not dressing. They are what makes the window read as a browser at
  /// all, and a full-frame capture with no chrome above it is a photograph
  /// of a webpage rather than a browser showing one. So both bars keep full
  /// height at every size, and maximizing gives up only the shadow, the
  /// corner radius, and the desktop around them — which is also what a real
  /// window manager does when you maximize a browser.
  ///
  /// The shadow is dropped rather than faded because there is nothing left
  /// for it to fall on: at full frame the window has no edge that is not the
  /// screen edge, and a blur drawn under it is only ever clipped away.
  void _paintBrowserWindow(
      Canvas canvas, Rect rect, double radius, double s) {
    final RRect rrect =
        RRect.fromRectAndRadius(rect, Radius.circular(radius));

    if (radius > 0.0) {
      canvas.drawRRect(
        rrect.shift(Offset(0, 3 * s)),
        Paint()
          ..color = const Color(0x6E000000)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 10 * s),
      );
    }

    canvas.drawRRect(rrect, Paint()..color = _kBrowserTabBar);

    canvas.save();
    canvas.clipRRect(rrect);

    final double tabH = _kBrowserTabBarHeight * s;
    final double barH = _kBrowserToolbarHeight * s;
    final Rect tabRect =
        Rect.fromLTWH(rect.left, rect.top, rect.width, tabH);
    final Rect toolRect =
        Rect.fromLTWH(rect.left, rect.top + tabH, rect.width, barH);
    final Rect viewport = Rect.fromLTRB(
        rect.left, toolRect.bottom, rect.right, rect.bottom);

    _drawBrowserTabStrip(canvas, tabRect, s);
    _drawBrowserToolbar(canvas, toolRect, s);
    _drawBrowserViewport(canvas, viewport, s);

    canvas.restore();
  }

  void _drawBrowserTabStrip(Canvas canvas, Rect bar, double s) {
    canvas.drawRect(bar, Paint()..color = _kBrowserTabBar);

    // One tab. Not a strip of them: extra tabs would be a claim about a
    // browsing session the script never authored, and an empty tab someone
    // reads as a second source is worse than no tab at all.
    final double tabW = bar.width * _kBrowserTabWidthFrac;
    final double pad = 12 * s;
    final Rect tab = Rect.fromLTWH(
        bar.left + pad, bar.top + 6 * s, tabW, bar.height - 6 * s);

    // Top corners only. A tab rounded on all four floats; rounded on two it
    // is attached to the toolbar beneath it, which is the whole visual idea.
    canvas.drawRRect(
      RRect.fromRectAndCorners(tab,
          topLeft: Radius.circular(_kBrowserTabRadius * s),
          topRight: Radius.circular(_kBrowserTabRadius * s)),
      Paint()..color = _kBrowserTabActive,
    );

    // Favicon: a plain rounded square. Anything more specific would be
    // somebody's mark.
    final double fav = 12 * s;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(tab.left + 11 * s, tab.center.dy - fav / 2, fav, fav),
        Radius.circular(2.5 * s),
      ),
      Paint()..color = _kBrowserTabTextDim,
    );

    final double textLeft = tab.left + 11 * s + fav + 9 * s;
    final double closeX = tab.right - 14 * s;
    _drawBrowserText(
      canvas,
      scene.browserTabTitle,
      Rect.fromLTRB(textLeft, tab.top, closeX - 8 * s, tab.bottom),
      size: _kBrowserTabTextSize * s,
      color: _kBrowserTabText,
    );

    // Tab close ✕, then the new-tab +.
    final Paint glyph = Paint()
      ..color = _kBrowserTabTextDim
      ..strokeWidth = 1.4 * s
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final double g = 4 * s;
    canvas.drawLine(Offset(closeX - g, tab.center.dy - g),
        Offset(closeX + g, tab.center.dy + g), glyph);
    canvas.drawLine(Offset(closeX + g, tab.center.dy - g),
        Offset(closeX - g, tab.center.dy + g), glyph);

    final double plusX = tab.right + 18 * s;
    canvas.drawLine(Offset(plusX - g, tab.center.dy),
        Offset(plusX + g, tab.center.dy), glyph);
    canvas.drawLine(Offset(plusX, tab.center.dy - g),
        Offset(plusX, tab.center.dy + g), glyph);

    _drawWindowControls(canvas, bar, s, 255);
  }

  void _drawBrowserToolbar(Canvas canvas, Rect bar, double s) {
    canvas.drawRect(bar, Paint()..color = _kBrowserToolbar);

    final Paint glyph = Paint()
      ..color = _kBrowserGlyph
      ..strokeWidth = 1.9 * s
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final double cy = bar.center.dy;
    final double step = 30 * s;
    double x = bar.left + 22 * s;

    // Back, forward: chevrons. Forward is dimmed, because nothing has been
    // navigated away from yet, which is true of every page this window shows.
    void chevron(double cx, bool left, Paint p) {
      final double a = 5 * s;
      final Path path = Path()
        ..moveTo(cx + (left ? a : -a), cy - a * 1.3)
        ..lineTo(cx + (left ? -a : a), cy)
        ..lineTo(cx + (left ? a : -a), cy + a * 1.3);
      canvas.drawPath(path, p);
    }

    chevron(x, true, glyph);
    x += step;
    chevron(
        x,
        false,
        Paint()
          ..color = _kBrowserGlyph.withAlpha(90)
          ..strokeWidth = 1.9 * s
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round);
    x += step;

    // NO RELOAD. It was here and it is deliberately gone. Two reasons, and
    // the second is the one that generalises. It drew as an arc with a
    // three-point arrowhead, which at the size this chrome is actually seen
    // resolved into a broken circle with a wart on it rather than into a
    // reload; and a reload says something about the session that no script
    // here authors. These pages are visited once, in order, and never
    // returned to. Back, forward, address, menu is the furniture that
    // carries the meaning. Anything past that is detail the eye has to
    // resolve in four seconds and gains nothing by resolving.

    // Menu: three dots on the right edge.
    final double menuX = bar.right - 22 * s;
    for (int i = -1; i <= 1; i++) {
      canvas.drawCircle(Offset(menuX, cy + i * 5.5 * s), 1.6 * s,
          Paint()..color = _kBrowserGlyph);
    }

    // Address pill.
    final Rect pill = Rect.fromLTRB(
        x + 6 * s, bar.top + 8 * s, menuX - 18 * s, bar.bottom - 8 * s);
    if (pill.width <= 0) return;
    canvas.drawRRect(
      RRect.fromRectAndRadius(pill, Radius.circular(_kBrowserUrlRadius * s)),
      Paint()..color = _kBrowserUrlPill,
    );

    // Padlock: shackle plus body. Drawn only when there is an address to
    // secure — a lock over an empty bar claims something about nothing.
    final String url = scene.browserUrl;
    double textLeft = pill.left + 14 * s;
    if (url.isNotEmpty) {
      final double lx = pill.left + 15 * s;
      final double bw = 8 * s;
      final double bh = 6 * s;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(lx - bw / 2, cy - bh / 2 + 1 * s, bw, bh),
          Radius.circular(1.5 * s),
        ),
        Paint()..color = _kBrowserGlyph,
      );
      canvas.drawArc(
        Rect.fromCircle(center: Offset(lx, cy - bh / 2 + 1 * s), radius: 2.6 * s),
        math.pi,
        math.pi,
        false,
        Paint()
          ..color = _kBrowserGlyph
          ..strokeWidth = 1.5 * s
          ..style = PaintingStyle.stroke,
      );
      textLeft = lx + bw;
    }

    _drawBrowserText(
      canvas,
      url,
      Rect.fromLTRB(textLeft, pill.top, pill.right - 12 * s, pill.bottom),
      size: _kBrowserUrlTextSize * s,
      color: _kBrowserUrlText,
    );
  }

  void _drawBrowserViewport(Canvas canvas, Rect viewport, double s) {
    canvas.save();
    canvas.clipRect(viewport);
    canvas.drawRect(viewport, Paint()..color = _kBrowserPageBack);

    final double load = scene.browserLoadProgress;
    final ui.Image? incoming = scene.browserIncomingImage;

    // During a navigation the outgoing capture is replaced at the midpoint
    // of the sweep, not crossfaded. A browser does not dissolve one document
    // into another; the old page is there until the new one paints.
    final bool showIncoming = incoming != null && load >= 0.5;
    final ui.Image? img = showIncoming ? incoming : scene.browserImage;

    if (img != null) {
      // A newly arrived page is at the top of itself. The outgoing one holds
      // wherever its own scroll left it, which is what scene.browserScrollT
      // reports through the navigation.
      _drawBrowserPage(canvas, img, viewport, s,
          scrollT: showIncoming ? 0.0 : scene.browserScrollT,
          mode: scene.browserScrollMode);
    }

    if (load > 0.0 && load < 1.0) {
      // Load bar. Sweeps to the right edge and is gone; it does not sit at
      // 100% waiting, because a bar that completes and lingers reads as a
      // page that failed to render.
      final double w = viewport.width * Curves.easeOut.transform(load);
      canvas.drawRect(
        Rect.fromLTWH(viewport.left, viewport.top, w,
            _kBrowserLoadBarHeight * s),
        Paint()..color = _kBrowserAccent,
      );
    }

    canvas.restore();
  }

  /// Draws one capture into the viewport under [mode], scrolled to [scrollT].
  void _drawBrowserPage(Canvas canvas, ui.Image img, Rect viewport, double s,
      {required double scrollT, required BrowserScroll mode}) {
    if (mode == BrowserScroll.fit) {
      _drawImageContain(canvas, img, viewport, opacity: 1.0);
      return;
    }

    final double iw = img.width.toDouble();
    final double ih = img.height.toDouble();
    if (iw <= 0 || ih <= 0) return;

    // Fit the WIDTH, always. This is what makes it a browser rather than an
    // image viewer: a page is authored to a width and is as long as it is,
    // and a capture squeezed to fit its height would be a picture of a page
    // rather than a page.
    final double scale = viewport.width / iw;
    final double drawH = ih * scale;
    final double overflow = math.max(0.0, drawH - viewport.height);
    final double offset = overflow * scrollT.clamp(0.0, 1.0);

    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, iw, ih),
      Rect.fromLTWH(viewport.left, viewport.top - offset, viewport.width, drawH),
      Paint()..filterQuality = FilterQuality.medium,
    );

    if (overflow <= 0.0) return;

    // Scrollbar. Drawn only against real overflow, so its thumb is an
    // honest report of how much page is left rather than decoration.
    final double trackW = _kBrowserScrollbarWidth * s;
    final Rect track = Rect.fromLTWH(
        viewport.right - trackW, viewport.top, trackW, viewport.height);
    canvas.drawRect(track, Paint()..color = _kBrowserScrollTrack);

    final double frac = viewport.height / drawH;
    final double thumbH = math.max(
        _kBrowserScrollbarMinThumb * s, viewport.height * frac);
    final double thumbY = viewport.top +
        (viewport.height - thumbH) * scrollT.clamp(0.0, 1.0);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(track.left + 1.5 * s, thumbY, trackW - 3 * s, thumbH),
        Radius.circular(trackW),
      ),
      Paint()..color = _kBrowserScrollThumb,
    );
  }

  /// One line of chrome text, clipped to its slot and ellipsized.
  ///
  /// Uses the script's font like every other label in the simulated desktop.
  /// A URL set in the same face as the terminal is part of what makes the
  /// window read as belonging to this machine rather than pasted onto it.
  void _drawBrowserText(Canvas canvas, String text, Rect slot,
      {required double size, required Color color}) {
    if (text.isEmpty || slot.width <= 0) return;
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: fontFamily,
          fontFamilyFallback: const [
            'Courier',
            'Consolas',
            'Courier New',
            'monospace'
          ],
          fontSize: size,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '\u2026',
    );
    tp.layout(maxWidth: slot.width);
    tp.paint(canvas, Offset(slot.left, slot.center.dy - tp.height / 2));
  }

  // --------------------------------------------------------------------
  // App window (Wii-style rounded-rect tile grid)
  // --------------------------------------------------------------------

  /// Draws the app window: chromed frame + adaptive rounded-rect tile grid.
  /// [openness] drives the open/close scale+fade (0..1). Per-tile cascade
  /// opacity comes from scene.appTileOpacity(i), which is 0 unless we're in
  /// the appShowing phase — so the tiles are correctly invisible while the
  /// window is scaling in.
  void _drawAppWindow(Canvas canvas, double engineW, double engineH, double s,
      {required double openness}) {
    if (openness <= 0.0) return;

    final List<ui.Image>? images = scene.appImages;
    if (images == null || images.isEmpty) return;

    // MOSAIC is still a window; it just does not stay one. It opens on the
    // desktop with chrome, maximizes into the frame, and restores on exit.
    if (scene.appIsMosaic) {
      _drawAppMosaicWindow(canvas, engineW, engineH, s, openness: openness);
      return;
    }

    final int cols = scene.appGridCols;
    final int rows = scene.appGridRows;
    if (cols <= 0 || rows <= 0) return;

    final double inset = engineW * _kAppMarginFrac;
    final Rect winRect = Rect.fromLTRB(
        inset, inset * 0.75, engineW - inset, engineH - inset * 0.75);

    _withWindowAnimation(canvas, winRect, openness, () {
      final double barH = _kTitleBarHeight * s;
      final RRect rrect = RRect.fromRectAndRadius(
          winRect, Radius.circular(_kWindowCornerRadius * s));

      // Shadow
      canvas.drawRRect(
        rrect.shift(Offset(0, 3 * s)),
        Paint()
          ..color = const Color(0x6E000000)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 10 * s),
      );

      // Body
      canvas.drawRRect(rrect, Paint()..color = _kAppBody);

      final Rect content = Rect.fromLTRB(
          winRect.left, winRect.top + barH, winRect.right, winRect.bottom);

      canvas.save();
      canvas.clipRRect(rrect);
      canvas.save();
      canvas.clipRect(content);

      _drawAppTileGrid(canvas, content, images, cols, rows, s);
      canvas.restore();

      // Header bar (title comes from the [APP:...] tag's title segment).
      _drawYaruHeaderBar(canvas,
          Rect.fromLTWH(winRect.left, winRect.top, winRect.width, barH), s,
          title: scene.appTitle, opacity: 1.0);
      canvas.restore();
    });
  }

  /// Lays out the tiles inside [content] as a `cols x rows` grid with fixed
  /// gap and inset. Each tile is a rounded rect clipping a COVER-scaled image,
  /// faded by its cascade opacity from scene.appTileOpacity(i).
  void _drawAppTileGrid(Canvas canvas, Rect content, List<ui.Image> images,
      int cols, int rows, double s) {
    final double engineW = scene.width;

    final double pad = engineW * _kAppGridPadFrac;
    final double gap = engineW * _kAppTileGapFrac;
    final double radius = _kAppTileRadius * s;

    final Rect gridRect = Rect.fromLTRB(
      content.left + pad,
      content.top + pad,
      content.right - pad,
      content.bottom - pad,
    );

    final double totalGapX = gap * (cols - 1);
    final double totalGapY = gap * (rows - 1);
    final double tileW = (gridRect.width - totalGapX) / cols;
    final double tileH = (gridRect.height - totalGapY) / rows;

    // Only place as many tiles as we have images — a 3x3 grid holding 7
    // images just leaves the last two cells empty in row-major order.
    final int tileCount = images.length;

    for (int i = 0; i < tileCount; i++) {
      final int row = i ~/ cols;
      final int col = i % cols;

      final double x = gridRect.left + col * (tileW + gap);
      final double y = gridRect.top + row * (tileH + gap);
      final Rect tileRect = Rect.fromLTWH(x, y, tileW, tileH);

      final double op = scene.appTileOpacity(i);
      if (op <= 0.0) continue;

      _drawAppTile(canvas, tileRect, radius, images[i], op, s);
    }
  }

  /// A single rounded-rect tile: subtle shadow behind, dark placeholder body
  /// so the frame reads even before the image finishes fading in, then the
  /// image itself COVER-scaled and clipped to the rounded rect. Everything
  /// wraps in a saveLayer so the whole tile fades as one unit.
  void _drawAppTile(Canvas canvas, Rect tileRect, double radius, ui.Image img,
      double opacity, double s) {
    final RRect rrect =
        RRect.fromRectAndRadius(tileRect, Radius.circular(radius));

    // saveLayer so the shadow, body, and image all fade together.
    canvas.saveLayer(
      tileRect.inflate(20),
      Paint()..color = Color.fromARGB((opacity * 255).round(), 255, 255, 255),
    );

    // Soft tile shadow (Wii-style — the tiles feel like they float slightly).
    canvas.drawRRect(
      rrect.shift(Offset(0, 2 * s)),
      Paint()
        ..color = const Color(0x66000000)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 6 * s),
    );

    // Body — a dark placeholder underneath so the rounded frame is visible
    // even at low tile-opacity mid-cascade.
    canvas.drawRRect(rrect, Paint()..color = const Color(0xFF2A2523));

    // Image (COVER, clipped to the rounded rect).
    canvas.save();
    canvas.clipRRect(rrect);
    _drawImageCover(canvas, img, tileRect, opacity: 1.0);
    canvas.restore();

    canvas.restore(); // saveLayer
  }

  // --------------------------------------------------------------------
  // App window: MOSAIC layout (Metro panels, maximizing, paged)
  // --------------------------------------------------------------------

  /// A MOSAIC is still a window. It opens on the desktop with chrome like
  /// any other, then maximizes into the frame, and restores back again on
  /// the way out. Fullscreen is a state the window passes through, not a
  /// separate archetype.
  ///
  /// Everything here is a pure function of the phase and its progress, so
  /// scrubbing backwards lands on exactly the same geometry.
  void _drawAppMosaicWindow(
      Canvas canvas, double engineW, double engineH, double s,
      {required double openness}) {
    final double inset = engineW * _kAppMarginFrac;
    final Rect deskRect = Rect.fromLTRB(
        inset, inset * 0.75, engineW - inset, engineH - inset * 0.75);
    final double cr = _kWindowCornerRadius * s;

    // A mosaic that does not maximize never leaves its desktop rect: it is
    // an ordinary chromed window that happens to hold unequal panels. This
    // is the whole of the windowed path, and none of the geometry below
    // applies to it.
    if (!scene.appMaximizes) {
      _withWindowAnimation(canvas, deskRect, openness,
          () => _paintMosaicWindow(canvas, deskRect, cr, 1.0, s));
      return;
    }

    final Rect frame = Rect.fromLTWH(0, 0, engineW, engineH);

    late final Rect rect;
    late final double chrome; // 1 = full window dressing, 0 = bare frame
    late final double radius;
    bool windowAnim = false;

    switch (scene.phase) {
      case ScenePhase.appMaximizing:
        final double t = Curves.easeInOutCubic.transform(scene.phaseProgress);
        rect = Rect.lerp(deskRect, frame, t)!;
        chrome = 1.0 - t;
        radius = cr * (1.0 - t);
        break;

      case ScenePhase.appRestoring:
        final double t = Curves.easeInOutCubic.transform(scene.phaseProgress);
        rect = Rect.lerp(frame, deskRect, t)!;
        chrome = t;
        radius = cr * t;
        break;

      case ScenePhase.appShowing:
      case ScenePhase.appPanning:
        rect = frame;
        chrome = 0.0;
        radius = 0.0;
        break;

      default: // appOpening, appClosing: an ordinary window on the desktop.
        rect = deskRect;
        chrome = 1.0;
        radius = cr;
        windowAnim = true;
        break;
    }

    void body() => _paintMosaicWindow(canvas, rect, radius, chrome, s);

    if (windowAnim) {
      _withWindowAnimation(canvas, rect, openness, body);
    } else {
      body();
    }
  }

  /// Paints the mosaic window at its current geometry. [chrome] 0..1 fades
  /// the shadow and the header bar, and also drives how much vertical room
  /// the bar takes: as it fades out the panel area grows into the space,
  /// so maximizing is one continuous move rather than a jump.
  void _paintMosaicWindow(
      Canvas canvas, Rect rect, double radius, double chrome, double s) {
    final RRect rrect =
        RRect.fromRectAndRadius(rect, Radius.circular(radius));
    final double barH = _kTitleBarHeight * s * chrome;

    if (chrome > 0.0) {
      canvas.drawRRect(
        rrect.shift(Offset(0, 3 * s)),
        Paint()
          ..color = Color.fromARGB((chrome * 110).round(), 0, 0, 0)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 10 * s),
      );
    }

    canvas.drawRRect(rrect, Paint()..color = _kAppMosaicBack);

    final Rect content = Rect.fromLTRB(
        rect.left, rect.top + barH, rect.right, rect.bottom);

    canvas.save();
    canvas.clipRRect(rrect);

    // Panels appear once the window is on its way to (or back from) full
    // frame. During the open and the maximize the window is still arriving,
    // and content sliding around inside a moving window reads as chaos.
    final ScenePhase p = scene.phase;
    final bool showPanels = p == ScenePhase.appShowing ||
        p == ScenePhase.appPanning ||
        p == ScenePhase.appRestoring ||
        p == ScenePhase.appClosing;

    if (showPanels && content.width > 0 && content.height > 0) {
      // On the way out the panels are already revealed; the shrink and the
      // fade carry them, so the cascade ramp no longer applies.
      final bool leaving = p == ScenePhase.appRestoring ||
          p == ScenePhase.appClosing;

      final double t = Curves.easeInOutCubic.transform(scene.appPanT);
      final int page = scene.appPageIndex;
      final double span =
          content.width + scene.width * _kAppMosaicGapFrac * 2;

      canvas.save();
      canvas.clipRect(content);
      _drawMosaicPage(canvas, content, page, -t * span, s,
          forceOpaque: leaving);
      if (t > 0.0) {
        _drawMosaicPage(canvas, content, page + 1, (1.0 - t) * span, s,
            forceOpaque: true);
      }
      canvas.restore();
    }

    if (chrome > 0.0) {
      final Rect barRect =
          Rect.fromLTWH(rect.left, rect.top, rect.width, barH);
      final String? incoming = scene.appTitleIncoming;

      if (incoming == null) {
        _drawYaruHeaderBar(canvas, barRect, s,
            title: scene.appTitle, opacity: chrome);
      } else {
        // Plate first at full chrome, then both titles over it.
        _drawYaruHeaderBar(canvas, barRect, s, title: '', opacity: chrome);
        // Two APP tags with different titles, sliding into one another.
        // The title crosses over rather than cutting: a header that snaps
        // mid-pan puts the eye on the chrome at the one moment it should
        // be on the photographs. Only reached when the titles actually
        // differ, so identical titles never dissolve against themselves.
        final double t = Curves.easeInOutCubic.transform(scene.appPanT);
        _drawYaruHeaderBar(canvas, barRect, s,
            title: scene.appTitle,
            opacity: chrome * (1.0 - t),
            textOnly: true);
        _drawYaruHeaderBar(canvas, barRect, s,
            title: incoming, opacity: chrome * t, textOnly: true);
      }
    }

    canvas.restore();
  }

  /// Maps one page's unit rects into [area], offset horizontally by [dx].
  ///
  /// Two rules make this fill its area the way a Start screen does rather
  /// than float like a card:
  ///
  ///  - The gap is applied only to INTERIOR edges. An edge sitting on the
  ///    area boundary gets no inset, so the composition runs to all four
  ///    sides with no letterboxing.
  ///  - A corner is squared only where BOTH of its edges are on the
  ///    boundary, which is to say only at the corners of the area itself.
  ///    Everything interior keeps its rounding. While the window still has
  ///    a corner radius the clip rounds those corners back off anyway.
  ///
  /// [forceOpaque] is set for the incoming page during a pan and for every
  /// panel on the way out: in both cases the cascade opacities belong to
  /// some other moment.
  void _drawMosaicPage(
      Canvas canvas, Rect area, int page, double dx, double s,
      {required bool forceOpaque}) {
    final List<Rect> rects = scene.appPageRects(page);
    if (rects.isEmpty) return;

    final double gap = scene.width * _kAppMosaicGapFrac;
    final double radius = _kAppMosaicRadius * s;
    final double rise = _kAppMosaicRiseFrac * area.height;

    const double eps = 0.0001;

    canvas.save();
    canvas.translate(dx, 0);

    for (int i = 0; i < rects.length; i++) {
      final ui.Image? img = scene.appPaneImage(page, i);
      if (img == null) continue;
      final Rect u = rects[i];

      final bool atLeft = u.left <= eps;
      final bool atRight = u.right >= 1.0 - eps;
      final bool atTop = u.top <= eps;
      final bool atBottom = u.bottom >= 1.0 - eps;

      final Rect panel = Rect.fromLTRB(
        area.left + u.left * area.width + (atLeft ? 0 : gap / 2),
        area.top + u.top * area.height + (atTop ? 0 : gap / 2),
        area.left + u.right * area.width - (atRight ? 0 : gap / 2),
        area.top + u.bottom * area.height - (atBottom ? 0 : gap / 2),
      );
      if (panel.width <= 0 || panel.height <= 0) continue;

      final double op = forceOpaque ? 1.0 : scene.appTileOpacity(i);
      if (op <= 0.0) continue;

      // Metro's signature arrival: each panel rises the last of the way in
      // as it fades. Driven by the same opacity ramp, so it stays locked to
      // the cascade and stays deterministic.
      final double dy = forceOpaque ? 0.0 : (1.0 - op) * rise;

      final Radius r = Radius.circular(radius);
      const Radius sq = Radius.zero;
      final RRect rrect = RRect.fromRectAndCorners(
        panel.shift(Offset(0, dy)),
        topLeft: (atLeft && atTop) ? sq : r,
        topRight: (atRight && atTop) ? sq : r,
        bottomLeft: (atLeft && atBottom) ? sq : r,
        bottomRight: (atRight && atBottom) ? sq : r,
      );

      // Not gated on forceOpaque. That flag means "the cascade opacities
      // belong to some other moment", which is true on the way out and for
      // an incoming page, but motion has its own rule: the engine freezes
      // the outgoing page at the end of its ramp and returns identity for
      // the incoming one. Zeroing it here as well would reintroduce the
      // snap-to-centre on the first frame of every page turn.
      final PaneMotion motion = scene.appPaneMotion(page, i);

      _drawMosaicPanel(
        canvas,
        rrect,
        img,
        op,
        motion,
        caption: scene.appPaneCaption(page, i),
        reserveBand: scene.appPaneReservesBand(page, i),
        // Type is sized on s, the same basis as the window chrome, so
        // every label in the mosaic comes out the same size regardless of
        // which panel it landed in.
        s: s,
      );
    }

    canvas.restore();
  }

  /// A single mosaic panel: flat plate, photo fitted and clipped to
  /// the rounded rect, hairline on the inside edge. No drop shadow, by
  /// design. Everything wraps in a saveLayer so the panel fades as one unit.
  ///
  /// The plate is drawn before the photo, so a FIT pane holding a source
  /// taller than the panel letterboxes against the plate. That is the whole
  /// treatment: no blurred backdrop of the same image, no mirrored edges.
  /// This window is a contact sheet, and the honest bar is the one that
  /// says the photograph is this shape.
  ///
  /// A caption band works the same way: it is not a scrim laid over the
  /// picture, it is the photo rect deflated so the plate shows through
  /// beneath it. Nothing is covered, no new fill is needed, and the clip,
  /// the corners, and the hairline still belong to the whole panel, so the
  /// label sits inside the same outline as the image.
  ///
  /// [reserveBand] comes from the PANE and not from this image, so a pane
  /// walking several photographs holds its geometry steady while only the
  /// words change. A pane where nothing is captioned passes false and
  /// renders exactly as it did before captions existed.
  void _drawMosaicPanel(Canvas canvas, RRect rrect, ui.Image img,
      double opacity, PaneMotion motion,
      {ImageCaption caption = ImageCaption.none,
      bool reserveBand = false,
      double s = 1.0}) {
    final Rect rect = rrect.outerRect;

    canvas.saveLayer(
      rect.inflate(2),
      Paint()
        ..color = Color.fromARGB(
            (opacity.clamp(0.0, 1.0) * 255).round(), 255, 255, 255),
    );

    canvas.drawRRect(rrect, Paint()..color = _kAppMosaicPlate);

    // Measure before committing to any geometry. Whether the band fits is
    // a fact about the laid-out text, not about the panel alone: a caption
    // that wraps to two lines on a narrow panel is taller than the same
    // caption on a wide one.
    final _CaptionBand? band =
        reserveBand ? _layoutCaptionBand(caption, rect, s) : null;

    final Rect photoRect = band == null
        ? rect
        : Rect.fromLTRB(rect.left, rect.top, rect.right, rect.bottom - band.height);

    canvas.save();
    canvas.clipRRect(rrect);
    // The clip is on the untouched rrect, so the plate, the hairline, and
    // the rounded corners hold still while only the photo inside moves.
    _drawImageCover(canvas, img, photoRect, opacity: 1.0, motion: motion);
    canvas.restore();

    if (band != null) band.paint(canvas, photoRect.bottom);

    canvas.drawRRect(
      rrect.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..color = _kAppMosaicEdge,
    );

    canvas.restore(); // saveLayer
  }

  /// Lays out a caption band for [rect], or returns null if it should not
  /// be drawn at all.
  ///
  /// Order matters here: measure, then decide, then shed. Type size is
  /// fixed against the window, so a small panel cannot buy legibility by
  /// shrinking the label; it either affords the band or goes without one.
  /// Suppressed rather than scaled down, because a caption too small to
  /// read is worse than no caption: it occupies the space, admits there
  /// was something to say, and does not say it.
  ///
  /// The credit is shed first and independently. Losing a collection line
  /// on a small panel costs provenance that the film's end credits can
  /// still carry; losing the caption costs the subject of the photograph,
  /// which nothing else recovers.
  _CaptionBand? _layoutCaptionBand(ImageCaption caption, Rect rect, double s) {
    final String text = caption.caption.trim();
    if (!caption.hasBand || text.isEmpty) return null;
    if (rect.width <= 0 || rect.height <= 0) return null;

    // Size and alignment are authored per script; the constant is only the
    // fallback for a script that never set [CONFIG:CAPTION:...].
    final CaptionConfig style = scene.captionStyle;
    final double size = style.sizePx * s;
    if (size <= 0) return null;
    final double pad = size * _kAppCaptionPadFrac;
    final double maxTextWidth = rect.width - pad * 2;
    if (maxTextWidth <= size) return null;

    final double ceiling = rect.height * _kAppCaptionMaxBandFrac;

    final TextAlign align = style.align == CaptionAlign.center
        ? TextAlign.center
        : (style.align == CaptionAlign.right ? TextAlign.right : TextAlign.left);

    // A named family that did not load falls back to the script's global
    // font rather than to nothing. Flutter resolves an unknown family
    // silently, so the fallback stack below is what actually catches it.
    final String family =
        (style.fontFamily != null && style.fontFamily!.trim().isNotEmpty)
            ? style.fontFamily!.trim()
            : fontFamily;

    TextPainter make(String body, double px, Color color, int maxLines) {
      final tp = TextPainter(
        text: TextSpan(
          text: body,
          style: TextStyle(
            fontFamily: family,
            fontFamilyFallback: [
              fontFamily,
              'Courier',
              'Consolas',
              'Courier New',
              'monospace',
            ],
            fontSize: px,
            height: 1.2,
            color: color,
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: align,
        maxLines: maxLines,
        ellipsis: '\u2026',
      );
      // Laid out at the FULL available width even when ranged left, so a
      // centred line has a box to centre inside. Painting then always
      // starts at the same x and the alignment happens within the layout,
      // which is also why the band needs no per-line offset arithmetic.
      tp.layout(minWidth: maxTextWidth, maxWidth: maxTextWidth);
      return tp;
    }

    final TextPainter head = make(text, size, _kAppCaptionText, 2);

    TextPainter? credit;
    final String creditText = caption.credit.trim();
    if (creditText.isNotEmpty) {
      credit = make(creditText, size * _kAppCaptionCreditScale,
          _kAppCaptionCredit, 1);
    }

    double heightWith(TextPainter? c) =>
        pad + head.height + (c == null ? 0 : pad * 0.35 + c.height) + pad;

    double h = heightWith(credit);
    if (h > ceiling && credit != null) {
      credit = null;
      h = heightWith(null);
    }
    if (h > ceiling) return null;

    return _CaptionBand(
      height: h,
      pad: pad,
      gap: pad * 0.35,
      head: head,
      credit: credit,
      left: rect.left + pad,
    );
  }

  // --------------------------------------------------------------------
  // Info card (Watch-Dogs style floating card)
  // --------------------------------------------------------------------

  /// Draws the right-anchored floating info card. [slide] 0..1: 0 = fully
  /// off the right edge, 1 = seated with a small gap off the right edge.
  /// The card is a rounded rect inset from the top and bottom of the screen
  /// — a card, not a side panel. Title image COVER-cropped into the top
  /// portion, programmable color block below carrying the H1 heading + body copy. Everything clips to the rounded rect.
  ///
  /// Pure presentation: no window chrome, no controls.
  void _drawCardPanel(Canvas canvas, double engineW, double engineH, double s,
      {required double slide}) {
    if (slide <= 0.0) return;
    if (!scene.hasActiveCard) return;

    final double cardW = engineW * _kCardWidthFrac;
    final double top = engineH * _kCardTopFrac;
    final double bottom = engineH - engineH * _kCardBottomFrac;
    final double rightGap = engineW * _kCardRightFrac;

    // The original easing curve
    final double rawProgress = slide.clamp(0.0, 1.0);
    final double e = Curves.easeOutCubic.transform(rawProgress);
    final double seatedLeft = engineW - rightGap - cardW;
    final double left = engineW + (seatedLeft - engineW) * e;

    final Rect cardRect = Rect.fromLTRB(left, top, left + cardW, bottom);
    final double radius = _kCardRadius * s;
    final RRect rrect = RRect.fromRectAndRadius(cardRect, Radius.circular(radius));

    canvas.save(); // Save canvas before applying card-level transforms

    // --- Subtle 2D Rotation ---
    // Pivot at dead center of the card
    final double pivotX = left + (cardW / 2); 
    final double pivotY = top + (cardRect.height / 2);
    
    // Negative angle: Nose (left side) points DOWN towards the floor.
    // Extremely subtle (-0.04 radians is barely ~2 degrees).
    final double angle = (1.0 - rawProgress) * -0.04; 
    
    // Very subtle scale in (98% to 100%)
    final double scaleEffect = 0.98 + (0.02 * rawProgress); 

    canvas.translate(pivotX, pivotY);
    canvas.rotate(angle);
    canvas.scale(scaleEffect, scaleEffect);
    canvas.translate(-pivotX, -pivotY);

    // Floating shadow — soft, slightly dropped, spilling on all sides.
    canvas.drawRRect(
      rrect.shift(Offset(-2 * s, 4 * s)),
      Paint()
        ..color = const Color(0x66000000)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 14 * s),
    );

    final ui.Image? img = scene.cardImage;
    final Color panelColor = scene.cardPanelColor;

    // Card body in the panel color first, so the rounded corners read even
    // where the image doesn't reach; everything clips to the rounded rect.
    canvas.drawRRect(rrect, Paint()..color = panelColor);

    canvas.save();
    canvas.clipRRect(rrect);

    // --- Title image strip (top of the CARD) ---
    // A missing image collapses the strip: the color block runs full height.
    double imageBottom = cardRect.top;
    if (img != null) {
      final double imageH = cardRect.height * _kCardImageFrac;
      imageBottom = cardRect.top + imageH;
      final Rect imgRect =
          Rect.fromLTWH(cardRect.left, cardRect.top, cardW, imageH);
      _drawImageCover(canvas, img, imgRect, opacity: 1.0);
    }

    // --- Programmable color block (below the image, holds all text) ---
    // Already painted as the card body; blockRect just scopes the text clip.
    final Rect blockRect = Rect.fromLTRB(
        cardRect.left, imageBottom, cardRect.right, cardRect.bottom);

    // Text color: auto contrast against the panel color, so a scripted
    // pale-yellow block gets near-black text and a deep red gets white.
    final bool darkPanel = panelColor.computeLuminance() < 0.35;
    final Color headColor =
        darkPanel ? const Color(0xFFF2F0EC) : const Color(0xFF14120F);
    final Color bodyColor =
        darkPanel ? const Color(0xDDE8E5E0) : const Color(0xDD26221E);

    // Accent rule under the heading, tinted from the text color.
    final Color ruleColor = headColor.withValues(alpha: 0.55);

    final double pad = cardW * _kCardPadFrac;
    final double textW = cardW - pad * 2;
    double cursorY = imageBottom + pad * 1.1;

    // --- H1 heading ---
    final String heading = scene.cardHeading;
    if (heading.isNotEmpty) {
      final headTp = TextPainter(
        text: TextSpan(
          text: heading,
          style: TextStyle(
            fontFamily: fontFamily,
            fontFamilyFallback: const [
              'Courier', 'Consolas', 'Courier New', 'monospace'
            ],
            fontSize: _kCardHeadingSize * s,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.5 * s,
            color: headColor,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      headTp.layout(maxWidth: textW);
      headTp.paint(canvas, Offset(cardRect.left + pad, cursorY));
      cursorY += headTp.height + pad * 0.45;

      // Accent rule.
      canvas.drawRect(
        Rect.fromLTWH(cardRect.left + pad, cursorY, textW * 0.42, 3 * s),
        Paint()..color = ruleColor,
      );
      cursorY += pad * 0.65;
    }

    // --- Body copy ---
    final String body = scene.cardBody;
    if (body.isNotEmpty) {
      final bodyTp = TextPainter(
        text: TextSpan(
          text: body,
          style: TextStyle(
            fontFamily: fontFamily,
            fontFamilyFallback: const [
              'Courier', 'Consolas', 'Courier New', 'monospace'
            ],
            fontSize: _kCardBodySize * s,
            fontWeight: FontWeight.bold,
            height: 1.55,
            color: bodyColor,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      bodyTp.layout(maxWidth: textW);

      // Clip to the block so an overlong body can't spill past the card.
      canvas.save();
      canvas.clipRect(blockRect);
      bodyTp.paint(canvas, Offset(cardRect.left + pad, cursorY));
      canvas.restore();
    }

    canvas.restore(); // rounded-rect clip
    canvas.restore(); // restore from the 2D rotation transform
  }

  // --------------------------------------------------------------------
  // Dossier Presentation (Browsing Strip -> Dynamic Layout Morphing)
  // --------------------------------------------------------------------

  void _drawDossierPanel(Canvas canvas, double engineW, double engineH, double s, {required double slide}) {
    if (slide <= 0.0 || !scene.hasActiveDossier) return;
    
    // Exactly the same slide geometry as _drawCardPanel
    final double cardW = engineW * _kCardWidthFrac;
    final double top = engineH * _kCardTopFrac;
    final double bottom = engineH - engineH * _kCardBottomFrac;
    final double rightGap = engineW * _kCardRightFrac;
    final double e = Curves.easeOutCubic.transform(slide.clamp(0.0, 1.0));
    final double seatedLeft = engineW - rightGap - cardW;
    final double left = engineW + (seatedLeft - engineW) * e;

    final Rect cardRect = Rect.fromLTRB(left, top, left + cardW, bottom);
    final RRect rrect = RRect.fromRectAndRadius(cardRect, Radius.circular(_kCardRadius * s));

    canvas.save();
    
    // --- Subtle 2D Rotation (matches CARD) ---
    final double rawProgress = slide.clamp(0.0, 1.0);
    final double pivotX = left + (cardW / 2); 
    final double pivotY = top + (cardRect.height / 2);
    final double angle = (1.0 - rawProgress) * -0.04; 
    final double scaleEffect = 0.98 + (0.02 * rawProgress); 

    canvas.translate(pivotX, pivotY);
    canvas.rotate(angle);
    canvas.scale(scaleEffect, scaleEffect);
    canvas.translate(-pivotX, -pivotY);
    
    canvas.drawRRect(
      rrect.shift(Offset(-2 * s, 4 * s)),
      Paint()..color = const Color(0x66000000)..maskFilter = MaskFilter.blur(BlurStyle.normal, 14 * s),
    );

    final Color panelColor = scene.dossierPanelColor;
    canvas.drawRRect(rrect, Paint()..color = panelColor);
    
    // Auto-contrast Text
    final bool darkPanel = panelColor.computeLuminance() < 0.35;
    final Color headColor = darkPanel ? const Color(0xFFF2F0EC) : const Color(0xFF14120F);
    final Color bodyColor = darkPanel ? const Color(0xDDE8E5E0) : const Color(0xDD26221E);
    
    final double pad = cardW * _kCardPadFrac;
    double cursorY = cardRect.top + pad * 1.5;

    canvas.save();
    canvas.clipRRect(rrect);
    
    // --- Title image strip (top of the CARD) ---
    double imageBottom = cardRect.top;
    final ui.Image? img = scene.dossierTitleImage;
    if (img != null) {
      final double imageH = cardRect.height * _kCardImageFrac;
      imageBottom = cardRect.top + imageH;
      final Rect imgRect = Rect.fromLTWH(cardRect.left, cardRect.top, cardW, imageH);
      _drawImageCover(canvas, img, imgRect, opacity: 1.0);
      cursorY = imageBottom + pad * 1.1;
    }
    
    final String heading = scene.dossierHeading;
    if (heading.isNotEmpty) {
      final headTp = TextPainter(
        text: TextSpan(text: heading, style: TextStyle(fontFamily: fontFamily, fontSize: _kCardHeadingSize * s, fontWeight: FontWeight.bold, color: headColor)),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: cardW - pad * 2);
      headTp.paint(canvas, Offset(cardRect.left + pad, cursorY));
      cursorY += headTp.height + pad * 0.5;
      canvas.drawRect(Rect.fromLTWH(cardRect.left + pad, cursorY, (cardW - pad * 2) * 0.42, 3 * s), Paint()..color = headColor.withValues(alpha: 0.55));
      cursorY += pad;
    }

    final String body = scene.dossierBody;
    if (body.isNotEmpty) {
      final bodyTp = TextPainter(
        text: TextSpan(text: body, style: TextStyle(fontFamily: fontFamily, fontSize: _kCardBodySize * s, fontWeight: FontWeight.bold, height: 1.55, color: bodyColor)),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: cardW - pad * 2);
      bodyTp.paint(canvas, Offset(cardRect.left + pad, cursorY));
    }
    
    canvas.restore();
    canvas.restore();
  }

  /// Deterministic paged-scroll offset for the dossier split strip, in
  /// "tiles scrolled" (continuous). Pure function of [frames]:
  ///
  ///   page k: rests for _kDossierScrollHoldFrames, then eases up one tile
  ///   over _kDossierScrollAnimFrames. Monotonic; clamped to [maxSteps].
  ///
  /// During dossierSplitShowing, [frames] is the live absolute phase age.
  /// During dossierTransitioning, SceneEngine pins dossierFramesIntoPhase to
  /// the completed split hold, so the hand-off inherits the exact scrolled
  /// position without carrying a mutable dossier clock.
  static double _dossierScrollOffset(int frames, int maxSteps) {
    if (maxSteps <= 0) return 0.0;
    const int cycle = _kDossierScrollHoldFrames + _kDossierScrollAnimFrames;

    final int completed = frames ~/ cycle;
    if (completed >= maxSteps) return maxSteps.toDouble();

    final int local = frames % cycle;
    if (local < _kDossierScrollHoldFrames) {
      return completed.toDouble(); // Resting on this two-and-a-half-up view.
    }
    final double t =
        (local - _kDossierScrollHoldFrames) / _kDossierScrollAnimFrames;
    return completed + Curves.easeInOutCubic.transform(t.clamp(0.0, 1.0));
  }

  /// Draws the dossier gallery window.
  ///
  /// SPLIT MODE (transitionT = 0): a single-column strip showing two full
  /// large tiles plus roughly half of the next tile as a continuation cue.
  /// The strip scrolls upward one tile at a time, so even three images create
  /// one visible browse move before the final two settle fully into view.
  /// Off-strip tiles are clipped by the window.
  ///
  /// TRANSITION (0 < transitionT < 1): the window bounds lerp to the full
  /// app-window rect while every tile lerps from its scrolled strip position
  /// (on-screen or off) to its slot in the full grid — visible tiles glide
  /// into place, off-screen ones fly in as the growing clip reveals them.
  ///
  /// FULL MODE (transitionT = 1): the landscape-dominant grid, as before.
  void _drawDossierGallery(Canvas canvas, double engineW, double engineH, double s, {required double openProgress, required double transitionT}) {
    if (openProgress <= 0.0 || !scene.hasActiveDossier) return;
    
    final List<ui.Image> images = scene.dossierImages;
    final int count = images.length;
    if (count == 0) return;
    
    // STATE A: Split window bounds
    final double panelW = engineW * _kCardWidthFrac;
    final double panelLeft = engineW - (engineW * _kCardRightFrac) - panelW;
    final double winALeft = engineW * _kStageMarginFrac;
    final double winARight = panelLeft - (engineW * _kStagePanelGapFrac);
    final double winATop = engineH * _kCardTopFrac;
    final double winABottom = engineH - engineH * _kCardBottomFrac;
    final Rect rectA = Rect.fromLTRB(winALeft, winATop, winARight, winABottom);

    // STATE B: Full window bounds
    final double insetB = engineW * _kAppMarginFrac;
    final Rect rectB = Rect.fromLTRB(insetB, insetB * 0.75, engineW - insetB, engineH - insetB * 0.75);

    // Smooth ease-out-cubic for the bounds Lerp so it "snaps" cleanly into center
    final double easedTransition = Curves.easeOutCubic.transform(transitionT);
    final Rect winRect = Rect.lerp(rectA, rectB, easedTransition)!;

    _withWindowAnimation(canvas, winRect, openProgress, () {
      final double barH = _kTitleBarHeight * s;
      final RRect rrect = RRect.fromRectAndRadius(winRect, Radius.circular(_kWindowCornerRadius * s));

      canvas.drawRRect(
        rrect.shift(Offset(0, 3 * s)),
        Paint()..color = const Color(0x6E000000)..maskFilter = MaskFilter.blur(BlurStyle.normal, 10 * s),
      );
      canvas.drawRRect(rrect, Paint()..color = _kAppBody);

      final Rect content = Rect.fromLTRB(winRect.left, winRect.top + barH, winRect.right, winRect.bottom);
      
      canvas.save();
      canvas.clipRRect(rrect);
      canvas.save();
      canvas.clipRect(content);

      final double pad = engineW * _kAppGridPadFrac;
      final double gap = engineW * _kAppTileGapFrac;

      // ---------------------------------------------------------------
      // STATE A LAYOUT: the browsing strip. One column, two full tiles plus
      // half of the next visible as a continuation cue. Every tile gets a
      // strip position, shifted by the paged scroll. Off-screen positions
      // are valid rects and become the launch points for the center morph.
      // ---------------------------------------------------------------
      final Rect contentA = Rect.fromLTRB(
          rectA.left, rectA.top + barH, rectA.right, rectA.bottom);
      final double stripPadL = contentA.left + pad;
      final double stripPadT = contentA.top + pad;
      final double stripW = contentA.width - pad * 2;
      final double stripVisH = contentA.height - pad * 2;
      // Two and a half tiles plus the two intervening gaps fill the viewport.
      final double stripTileH =
          math.max((stripVisH - gap * 2.0) / 2.5, 1.0);
      final double stripStep = stripTileH + gap;

      // The partial third tile is a continuation cue, not a final slot. Stop
      // with the last two images fully seated so the sequence never ends on
      // a clipped final image. Three images therefore guarantee one scroll.
      final int maxSteps = math.max(count - 2, 0);
      final double scroll = _dossierScrollOffset(
          scene.dossierFramesIntoPhase, maxSteps);

      final List<Rect> rectsA = List.generate(count, (i) {
        final double y = stripPadT + (i - scroll) * stripStep;
        return Rect.fromLTWH(stripPadL, y, stripW, stripTileH);
      });

      // ---------------------------------------------------------------
      // STATE B LAYOUT: center stage. GRID is the legacy exact-fit layout.
      // MOSAIC maps the first three images into the same Metro geometry as
      // APP:MOSAIC; additional images live on later pages and pan in while
      // the center stage is holding.
      // ---------------------------------------------------------------
      final Rect contentB = Rect.fromLTRB(
          rectB.left, rectB.top + barH, rectB.right, rectB.bottom);
      final bool centerMosaic = scene.dossierCenterIsMosaic;

      late final List<Rect> rectsB;
      int firstMosaicCount = 0;
      if (centerMosaic) {
        final List<Rect> unit = scene.dossierMosaicPageRects(0);
        firstMosaicCount = unit.length;
        rectsB = List.generate(count, (i) {
          if (i < unit.length) {
            return _dossierMosaicPanelRect(contentB, unit[i], engineW);
          }
          // Later-page images leave the first composition during the morph;
          // they return deterministically when their page pans in.
          final double w = math.max(contentB.width * 0.22, 1.0);
          final double h = math.max(contentB.height * 0.22, 1.0);
          return Rect.fromLTWH(
            contentB.right + gap + (i - unit.length) * gap,
            contentB.center.dy - h / 2,
            w,
            h,
          );
        });
      } else {
        ({int cols, int rows}) pickFullGrid(int n) {
          if (n <= 1) return (cols: 1, rows: 1);
          if (n == 2) return (cols: 2, rows: 1);
          if (n == 3) return (cols: 3, rows: 1);
          if (n == 4) return (cols: 2, rows: 2);
          if (n <= 6) return (cols: 3, rows: 2);
          if (n <= 8) return (cols: 4, rows: 2);
          return (cols: 3, rows: 3);
        }
        final gridB = pickFullGrid(count);
        final double bTileW =
            (contentB.width - pad * 2 - gap * (gridB.cols - 1)) / gridB.cols;
        final double bTileH =
            (contentB.height - pad * 2 - gap * (gridB.rows - 1)) / gridB.rows;

        rectsB = List.generate(count, (i) {
          final int c = i % gridB.cols;
          final int r = i ~/ gridB.cols;
          return Rect.fromLTWH(
            contentB.left + pad + c * (bTileW + gap),
            contentB.top + pad + r * (bTileH + gap),
            bTileW,
            bTileH,
          );
        });
      }

      // Once MOSAIC reaches center stage it owns the surface, including
      // page-to-page pans. Before that point the first page is reached by
      // the same strip -> center morph the GRID path already uses.
      if (centerMosaic && easedTransition >= 0.999) {
        _drawDossierMosaicSurface(canvas, contentB, s);
      } else {
        // -------------------------------------------------------------
        // Draw: lerp every tile between its strip position and center slot.
        // In pure split mode, skip tiles fully outside the visible strip.
        // -------------------------------------------------------------
        for (int i = 0; i < count; i++) {
          final Rect currentTile =
              Rect.lerp(rectsA[i], rectsB[i], easedTransition)!;

          if (easedTransition <= 0.0 &&
              (currentTile.bottom < contentA.top ||
                  currentTile.top > contentA.bottom)) {
            continue;
          }

          final double opacity = centerMosaic && i >= firstMosaicCount
              ? 1.0 - easedTransition
              : 1.0;
          if (opacity <= 0.0) continue;

          final RRect tileRRect = RRect.fromRectAndRadius(
              currentTile, Radius.circular(_kAppTileRadius * s));
          canvas.drawRRect(
              tileRRect, Paint()..color = const Color(0xFF2A2523));
          canvas.save();
          canvas.clipRRect(tileRRect);
          _drawImageCover(canvas, images[i], currentTile, opacity: opacity);
          canvas.restore();
        }
      }

      canvas.restore();
      
      _drawYaruHeaderBar(canvas, Rect.fromLTWH(winRect.left, winRect.top, winRect.width, barH), s, title: 'Dossier Files', opacity: 1.0);
      
      canvas.restore();
    });
  }

  /// Maps one APP-style MOSAIC unit rect into the dossier center-stage area.
  /// Interior edges receive the Metro gap; outer edges run flush to the
  /// surface just like APP:MOSAIC.
  Rect _dossierMosaicPanelRect(Rect area, Rect unit, double engineW) {
    final double gap = engineW * _kAppMosaicGapFrac;
    const double eps = 0.0001;
    final bool atLeft = unit.left <= eps;
    final bool atRight = unit.right >= 1.0 - eps;
    final bool atTop = unit.top <= eps;
    final bool atBottom = unit.bottom >= 1.0 - eps;
    return Rect.fromLTRB(
      area.left + unit.left * area.width + (atLeft ? 0 : gap / 2),
      area.top + unit.top * area.height + (atTop ? 0 : gap / 2),
      area.left + unit.right * area.width - (atRight ? 0 : gap / 2),
      area.top + unit.bottom * area.height - (atBottom ? 0 : gap / 2),
    );
  }

  void _drawDossierMosaicSurface(
      Canvas canvas, Rect area, double s) {
    final int page = scene.dossierMosaicPageIndex;
    final double t = Curves.easeInOutCubic.transform(scene.dossierMosaicPanT);
    final double span = area.width + scene.width * _kAppMosaicGapFrac * 2;

    _drawDossierMosaicPage(canvas, area, page, -t * span, s);
    if (t > 0.0) {
      _drawDossierMosaicPage(canvas, area, page + 1, (1.0 - t) * span, s);
    }
  }

  void _drawDossierMosaicPage(
      Canvas canvas, Rect area, int page, double dx, double s) {
    final List<Rect> rects = scene.dossierMosaicPageRects(page);
    final List<ui.Image> imgs = scene.dossierMosaicPageImages(page);
    if (rects.isEmpty || imgs.isEmpty) return;

    canvas.save();
    canvas.translate(dx, 0);
    final int n = rects.length < imgs.length ? rects.length : imgs.length;
    for (int i = 0; i < n; i++) {
      final Rect panel = _dossierMosaicPanelRect(area, rects[i], scene.width);
      if (panel.width <= 0 || panel.height <= 0) continue;

      final RRect rr = RRect.fromRectAndRadius(
          panel, Radius.circular(_kAppMosaicRadius * s));
      canvas.drawRRect(rr, Paint()..color = _kAppMosaicBack);
      canvas.save();
      canvas.clipRRect(rr);
      _drawImageCover(canvas, imgs[i], panel, opacity: 1.0);
      canvas.restore();
    }
    canvas.restore();
  }

  // --------------------------------------------------------------------
  // Timeline panel (vertical dossier-style timeline)
  // --------------------------------------------------------------------

  /// Draws the right-anchored vertical timeline panel. [slide] 0..1, same
  /// contract as the card: 0 = fully off the right edge, 1 = seated. Reuses
  /// the card's slide easing and subtle rotation so both presentations feel
  /// like the same design language.
  ///
  /// Inside: H1 heading with accent rule (same treatment as CARD), then a
  /// vertical spine that draws top-to-bottom (scene.timelineSpineProgress),
  /// with events revealing one at a time (scene.timelineEventProgress(i)) —
  /// date label left of the node, wrapped text right of it, each fading in
  /// while sliding a few pixels out from the spine.
  ///
  /// Everything is driven by scene accessors that are pure functions of
  /// frame count, so scrubbing and export match exactly.
  void _drawTimelinePanel(Canvas canvas, double engineW, double engineH,
      double s, {required double slide}) {
    if (slide <= 0.0) return;
    if (!scene.hasActiveTimeline) return;

    final List<TimelineEvent> events = scene.timelineEvents;
    if (events.isEmpty) return;

    final double panelW = engineW * _kTlWidthFrac;
    final double top = engineH * _kCardTopFrac;
    final double bottom = engineH - engineH * _kCardBottomFrac;
    final double rightGap = engineW * _kCardRightFrac;

    // Slide-in easing + subtle rotation, identical language to the card.
    final double rawProgress = slide.clamp(0.0, 1.0);
    final double e = Curves.easeOutCubic.transform(rawProgress);
    final double seatedLeft = engineW - rightGap - panelW;
    final double left = engineW + (seatedLeft - engineW) * e;

    final Rect panelRect = Rect.fromLTRB(left, top, left + panelW, bottom);
    final double radius = _kTlRadius * s;
    final RRect rrect =
        RRect.fromRectAndRadius(panelRect, Radius.circular(radius));

    canvas.save();

    final double pivotX = left + (panelW / 2);
    final double pivotY = top + (panelRect.height / 2);
    final double angle = (1.0 - rawProgress) * -0.04;
    final double scaleEffect = 0.98 + (0.02 * rawProgress);

    canvas.translate(pivotX, pivotY);
    canvas.rotate(angle);
    canvas.scale(scaleEffect, scaleEffect);
    canvas.translate(-pivotX, -pivotY);

    // Floating shadow.
    canvas.drawRRect(
      rrect.shift(Offset(-2 * s, 4 * s)),
      Paint()
        ..color = const Color(0x66000000)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 14 * s),
    );

    final Color panelColor = scene.timelinePanelColor;
    canvas.drawRRect(rrect, Paint()..color = panelColor);

    canvas.save();
    canvas.clipRRect(rrect);

    // Auto-contrast text colors, same rule as the card.
    final bool darkPanel = panelColor.computeLuminance() < 0.35;
    final Color headColor =
        darkPanel ? const Color(0xFFF2F0EC) : const Color(0xFF14120F);
    final Color bodyColor =
        darkPanel ? const Color(0xDDE8E5E0) : const Color(0xDD26221E);
    final Color ruleColor = headColor.withValues(alpha: 0.55);

    // Spine and nodes pick up the heading color at reduced strength so they
    // read as structure, not content.
    final Color spineColor = headColor.withValues(alpha: 0.45);
    final Color nodeColor = headColor;

    final double pad = panelW * _kTlPadFrac;
    double cursorY = panelRect.top + pad * 1.1;

    // --- H1 heading (same treatment as CARD) ---
    final String heading = scene.timelineHeading;
    if (heading.isNotEmpty) {
      final headTp = TextPainter(
        text: TextSpan(
          text: heading,
          style: TextStyle(
            fontFamily: fontFamily,
            fontFamilyFallback: const [
              'Courier', 'Consolas', 'Courier New', 'monospace'
            ],
            fontSize: _kTlHeadingSize * s,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.5 * s,
            color: headColor,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      headTp.layout(maxWidth: panelW - pad * 2);
      headTp.paint(canvas, Offset(panelRect.left + pad, cursorY));
      cursorY += headTp.height + pad * 0.45;

      canvas.drawRect(
        Rect.fromLTWH(
            panelRect.left + pad, cursorY, (panelW - pad * 2) * 0.42, 3 * s),
        Paint()..color = ruleColor,
      );
      cursorY += pad * 0.9;
    }

    // --- Timeline geometry ---
    // Date column left of the spine, event text right of it.
    final double dateColW = panelW * _kTlDateColFrac;
    final double spineX = panelRect.left + pad + dateColW + pad * 0.6;
    final double textX = spineX + pad * 0.8;
    final double textW = panelRect.right - pad - textX;

    final double spineTop = cursorY + pad * 0.3;
    final double spineBottom = panelRect.bottom - pad * 1.1;
    final double spineH = math.max(spineBottom - spineTop, 1.0);

    // Event rows distributed evenly down the spine. Node sits at the row's
    // first-line center so date, node, and text top-align visually.
    final int n = events.length;
    final double rowGap = n > 1 ? spineH / n : 0.0;
    final double firstNodeY = spineTop + (n > 1 ? rowGap * 0.5 : spineH * 0.5);

    // --- Spine draws top-to-bottom ---
    final double spineProg = scene.timelineSpineProgress;
    if (spineProg > 0.0) {
      final double drawnBottom =
          spineTop + spineH * Curves.easeInOutCubic.transform(spineProg);
      canvas.drawLine(
        Offset(spineX, spineTop),
        Offset(spineX, drawnBottom),
        Paint()
          ..color = spineColor
          ..strokeWidth = _kTlSpineWidth * s
          ..strokeCap = StrokeCap.round,
      );
    }

    // --- Events reveal in order ---
    for (int i = 0; i < n; i++) {
      final double prog = scene.timelineEventProgress(i);
      if (prog <= 0.0) continue;

      final double eased = Curves.easeOutCubic.transform(prog);
      final double nodeY = firstNodeY + rowGap * i;
      final double slidePx = (1.0 - eased) * _kTlEventSlidePx * s;
      final int alpha = (eased * 255).round().clamp(0, 255);

      // Node dot: pops on slightly larger then settles (tiny overshoot feel
      // achieved by scaling radius with the eased curve, capped at full).
      final double nodeR = _kTlNodeRadius * s * eased;
      canvas.drawCircle(
        Offset(spineX, nodeY),
        nodeR,
        Paint()..color = nodeColor.withAlpha(alpha),
      );
      // Punch a panel-colored inner dot so the node reads as a ring.
      canvas.drawCircle(
        Offset(spineX, nodeY),
        nodeR * 0.45,
        Paint()..color = panelColor.withAlpha(alpha),
      );

      // Date label: right-aligned against the spine, slides in from the left.
      final TimelineEvent ev = events[i];
      if (ev.date.isNotEmpty) {
        final dateTp = TextPainter(
          text: TextSpan(
            text: ev.date,
            style: TextStyle(
              fontFamily: fontFamily,
              fontFamilyFallback: const [
                'Courier', 'Consolas', 'Courier New', 'monospace'
              ],
              fontSize: _kTlDateSize * s,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5 * s,
              color: headColor.withAlpha(alpha),
            ),
          ),
          textDirection: TextDirection.ltr,
        );
        dateTp.layout(maxWidth: dateColW);
        dateTp.paint(
          canvas,
          Offset(
            spineX - pad * 0.8 - dateTp.width - slidePx,
            nodeY - dateTp.height / 2,
          ),
        );
      }

      // Event text: wrapped, top anchored to the node line, slides in from
      // the right (mirroring the date's motion away from the spine).
      if (ev.text.isNotEmpty) {
        final textTp = TextPainter(
          text: TextSpan(
            text: ev.text,
            style: TextStyle(
              fontFamily: fontFamily,
              fontFamilyFallback: const [
                'Courier', 'Consolas', 'Courier New', 'monospace'
              ],
              fontSize: _kTlTextSize * s,
              fontWeight: FontWeight.bold,
              height: 1.45,
              color: bodyColor.withAlpha(alpha),
            ),
          ),
          textDirection: TextDirection.ltr,
        );
        textTp.layout(maxWidth: math.max(textW, 1.0));

        // Clip each row's text to its band so an overlong event can't run
        // into the next row.
        final double bandBottom = (i < n - 1)
            ? firstNodeY + rowGap * (i + 1) - rowGap * 0.12
            : panelRect.bottom - pad * 0.6;
        canvas.save();
        canvas.clipRect(Rect.fromLTRB(
            textX, nodeY - rowGap * 0.4, panelRect.right, bandBottom));
        textTp.paint(
          canvas,
          Offset(textX + slidePx, nodeY - (_kTlTextSize * s * 1.45) / 2),
        );
        canvas.restore();
      }
    }

    canvas.restore(); // rounded-rect clip
    canvas.restore(); // rotation transform
  }

  // --------------------------------------------------------------------
  // Center stage (contact-sheet sidecar, synced to the timeline)
  // --------------------------------------------------------------------

  /// Draws the center stage as a Yaru-chromed "Photos" window in the desktop
  /// space LEFT of the timeline panel: a contact sheet of small portrait
  /// thumbnails, a white connector line snaking BEHIND them, and per-photo
  /// activation (border + year plate) synced to the spine events.
  ///
  /// [slide] 0..1 fades the whole window in/out with the panel's slide, so
  /// stage and panel always feel like one presentation.
  void _drawTimelineStage(Canvas canvas, double engineW, double engineH,
      double s, {required double slide}) {
    if (slide <= 0.0) return;
    if (!scene.hasTimelineStage) return;

    final List<ui.Image> photos = scene.timelineStagePhotos;
    final List<TimelineEvent> events = scene.timelineEvents;
    final int n = photos.length;
    if (n == 0) return;

    // --- Dynamic Height Calculation ---
    final double panelW = engineW * _kTlWidthFrac;
    final double panelLeft = engineW - engineW * _kCardRightFrac - panelW;
    final double winLeft = engineW * _kStageMarginFrac;
    final double winRight = panelLeft - engineW * _kStagePanelGapFrac;
    
    final double pad = engineW * _kStageGridPadFrac;
    final int? scriptedGap = scene.timelineStageGap;
    final double gap = scriptedGap != null 
        ? scriptedGap.toDouble() * s 
        : engineW * _kStageTileGapFrac;
    
    final double maxSheetW = (winRight - winLeft) - pad * 2;
    final int? scripted = scene.timelineStageThumbW;
    double tileW = (scripted != null ? scripted.toDouble() : _kStageDefaultThumbW) * s;
    tileW = tileW.clamp(8.0, maxSheetW);
    double tileH = tileW / _kStagePhotoAspect;
    
    final double barH = _kTitleBarHeight * s;
    final double maxWinH = engineH - engineH * _kCardTopFrac - engineH * _kCardBottomFrac;
    
    // We base our anchor line roughly off the timeline's top margin, but slightly lower
    // so it aligns nicely with the start of the actual content in the panel.
    final double timelineTop = engineH * _kCardTopFrac;
    
    // Updated anchoring logic: Push the top of the window down slightly.
    // 0.12 pushes it lower on the timeline, rather than pinning it high up.
    final double anchorTop = timelineTop + (engineH * 0.12); 
    
    // Scale down if a single tile is taller than the max possible window
    final double maxSheetH = maxWinH - barH - pad * 2;
    if (tileH > maxSheetH) {
      tileH = maxSheetH;
      tileW = tileH * _kStagePhotoAspect;
    }
    
    final int cols = math.max(1, ((maxSheetW + gap) / (tileW + gap)).floor());
    final int rows = (n / cols).ceil();
    
    // Updated footer logic: 0.6 tile heights (tight but breathing room)
    final double contentH = pad * 2 + (rows * tileH) + math.max(0, rows - 1) * gap;
    final double footerH = tileH * 0.6; 
    
    // Calculate final window height, making sure it never clips through the bottom of the screen
    final double desiredWinH = barH + contentH + footerH;
    final double maxAvailableH = engineH - anchorTop - (engineH * _kCardBottomFrac);
    final double winH = math.min(desiredWinH, maxAvailableH);
    
    final Rect winRect = Rect.fromLTRB(
      winLeft,
      anchorTop,
      winRight,
      anchorTop + winH,
    );

    if (winRect.width <= 10 || winRect.height <= 10) return;

    // Fade the whole window with the panel slide, reusing the same open/close
    // language as the viewer and app windows.
    _withWindowAnimation(canvas, winRect, slide, () {
      final RRect rrect = RRect.fromRectAndRadius(
          winRect, Radius.circular(_kWindowCornerRadius * s));

      // Shadow (punched out so it doesn't ghost through the glassy body)
      final Path shadowPath = Path()
        ..addRect(winRect.inflate(100 * s)) // Outer bound for blur
        ..addRRect(rrect)                   // Inner bound to punch out
        ..fillType = PathFillType.evenOdd;

      canvas.save();
      canvas.clipPath(shadowPath);
      canvas.drawRRect(
        rrect.shift(Offset(0, 3 * s)),
        Paint()
          ..color = const Color(0x6E000000)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 10 * s),
      );
      canvas.restore();

      // Body (translucent glassy surface with exact background blur reconstruction).
      canvas.save();
      canvas.clipRRect(rrect);

      // 1. Draw the wallpaper, blurred.
      if (scene.wallpaper != null && !scene.inPrerollSequence) {
        _drawImageCover(
          canvas, 
          scene.wallpaper!, 
          Rect.fromLTWH(0, 0, engineW, engineH), 
          opacity: 1.0, 
          blurSigma: _kStageWindowBlurSigma * s
        );
      } else if (!_transparentBg) {
        canvas.drawRect(Rect.fromLTWH(0, 0, engineW, engineH), Paint()..color = scene.prerollColor);
      }

      // 2. Draw the tint overlay
      canvas.drawRect(winRect, Paint()..color = _kViewerBody.withValues(alpha: _kStageWindowOpacity));
      canvas.restore();

      final Rect content = Rect.fromLTRB(
          winRect.left, winRect.top + barH, winRect.right, winRect.bottom);

      canvas.save();
      canvas.clipRRect(rrect);
      canvas.save();
      canvas.clipRect(content);

      _drawStageContactSheet(canvas, content, photos, events, engineW, s);

      canvas.restore();

      // Header bar.
      _drawYaruHeaderBar(canvas,
          Rect.fromLTWH(winRect.left, winRect.top, winRect.width, barH), s,
          title: _kStageWindowTitle, opacity: _kStageWindowOpacity);
      canvas.restore();
    });
  }

  /// The contact sheet inside the stage window's content area.
  ///
  /// Layout: thumbnails at the scripted width (TIMELINE tag's sixth segment,
  /// default _kStageDefaultThumbW) fill left-to-right from the sheet's
  /// TOP-LEFT and wrap to a new row when the next thumb would cross the
  /// sheet's right edge — so the scripted size directly controls the grid
  /// shape. Rows fill in a standard "typewriter" layout (left-to-right,
  /// then carriage return to the left).
  ///
  /// The connector line's origin is the FIRST thumb's center (top-left of
  /// the sheet); during the spine draw it "charges up" there, then travels
  /// photo-to-photo. Arrival at photo i is the exact frame event i pops on
  /// the spine (scene.timelineStageLineT owns the timing).
  ///
  /// Draw order: connector line FIRST (renders behind), then photos over
  /// it, then activated borders + year plates on top.
  void _drawStageContactSheet(Canvas canvas, Rect content,
      List<ui.Image> photos, List<TimelineEvent> events, double engineW,
      double s) {
    final int n = photos.length;
    final double pad = engineW * _kStageGridPadFrac;

    // --- GAP LOGIC ---
    final int? scriptedGap = scene.timelineStageGap;
    final double gap = scriptedGap != null 
        ? scriptedGap.toDouble() * s 
        : engineW * _kStageTileGapFrac;
    // -----------------

    final Rect sheetRect = Rect.fromLTRB(
      content.left + pad,
      content.top + pad,
      content.right - pad,
      content.bottom - pad,
    );
    if (sheetRect.width <= 10 || sheetRect.height <= 10) return;

    // --- Thumb size: scripted (logical px @ 1080p * scale), clamped so a
    // single thumb can never exceed the sheet itself.
    final int? scripted = scene.timelineStageThumbW;
    double tileW = (scripted != null ? scripted.toDouble() : _kStageDefaultThumbW) * s;
    tileW = tileW.clamp(8.0, sheetRect.width);
    double tileH = tileW / _kStagePhotoAspect;
    
    // We purposefully do NOT clamp tileH to sheetRect.height here anymore.
    // If there are many rows, the window clamps to maxWinH and naturally clips the overflow!

    // --- Wrap: columns = how many thumbs fit before hitting the right edge.
    final int cols =
        math.max(1, ((sheetRect.width + gap) / (tileW + gap)).floor());
    final int actualCols = math.min(n, cols);

    // Center the grid horizontally inside the sheetRect
    final double gridW = actualCols * tileW + math.max(0, actualCols - 1) * gap;
    final double startX = sheetRect.left + (sheetRect.width - gridW) / 2.0;

    // --- Typewriter placement centered horizontally ---
    Rect tileRectOf(int i) {
      final int r = i ~/ cols;
      final int c = i % cols;
      final double x = startX + c * (tileW + gap);
      final double y = sheetRect.top + r * (tileH + gap);
      return Rect.fromLTWH(x, y, tileW, tileH);
    }

    final List<Rect> tiles = List.generate(n, tileRectOf);
    final List<Offset> centers = tiles.map((r) => r.center).toList();

    // --- Connector path logic ---
    final double lineT = scene.timelineStageLineT; // segments travelled
    if (lineT > 0.0) {
      final Path linePath = Path()..moveTo(centers[0].dx, centers[0].dy);
      
      // Helper: Draws an orthogonal route if points are on different rows.
      List<Offset> getRoute(Offset a, Offset b, double gapMidY) {
        if ((a.dy - b.dy).abs() < 1.0) {
          return [a, b];
        } else {
          // Carriage return: Down into gap -> Left across channel -> Down to next row
          return [a, Offset(a.dx, gapMidY), Offset(b.dx, gapMidY), b];
        }
      }

      // Helper: Interpolates physical distance along a polyline route.
      void addRoute(List<Offset> route, double frac) {
        if (frac >= 1.0) {
          for (int i = 1; i < route.length; i++) {
            linePath.lineTo(route[i].dx, route[i].dy);
          }
          return;
        }
        double totalDist = 0;
        List<double> segDists = [];
        for (int i = 0; i < route.length - 1; i++) {
          double d = (route[i+1] - route[i]).distance;
          totalDist += d;
          segDists.add(d);
        }
        double targetDist = totalDist * frac;
        double distTraveled = 0;
        for (int i = 0; i < route.length - 1; i++) {
          if (distTraveled + segDists[i] >= targetDist) {
            double segFrac = (targetDist - distTraveled) / segDists[i];
            Offset tip = Offset.lerp(route[i], route[i+1], segFrac)!;
            linePath.lineTo(tip.dx, tip.dy);
            break;
          } else {
            linePath.lineTo(route[i+1].dx, route[i+1].dy);
            distTraveled += segDists[i];
          }
        }
      }

      final int currentSeg = lineT.floor();
      final double frac = lineT - currentSeg;

      // Draw all fully completed photo-to-photo segments.
      for (int k = 1; k < currentSeg; k++) {
        if (k >= n) break;
        final Offset a = centers[k-1];
        final Offset b = centers[k];
        final double gapMidY = a.dy + (tileH / 2) + (gap / 2);
        addRoute(getRoute(a, b, gapMidY), 1.0);
      }

      // Draw the fractional remainder of the current segment.
      if (frac > 0.0 && currentSeg >= 1 && currentSeg < n) {
        final Offset a = centers[currentSeg-1];
        final Offset b = centers[currentSeg];
        final double gapMidY = a.dy + (tileH / 2) + (gap / 2);
        addRoute(getRoute(a, b, gapMidY), frac);
      }

      canvas.drawPath(
        linePath,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = _kStageLineWidth * s
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round, // Rounds out the 90 degree turns beautifully!
      );
    }

    // --- 2. Thumbnails over the line (fade in when activated) ---
    final double tileRadius = _kStageTileRadius * s;
    for (int i = 0; i < n; i++) {
      final Rect rect = tiles[i];
      final RRect rrect =
          RRect.fromRectAndRadius(rect, Radius.circular(tileRadius));
      final double prog = scene.timelineStagePhotoProgress(i);
      final double eased = Curves.easeOutCubic.transform(prog);

      // Opaque body first so the line can never ghost through the photo.
      // This also serves as the "off" state background.
      canvas.drawRRect(rrect, Paint()..color = const Color(0xFF2A2523));

      if (eased > 0.0) {
        canvas.save();
        canvas.clipRRect(rrect);
        _drawImageCover(canvas, photos[i], rect, opacity: eased);
        canvas.restore();
      }
    }

    // --- 3. Activated borders + year plates on top ---
    final double yearSize = _kStageYearSize * s;
    for (int i = 0; i < n; i++) {
      final double prog = scene.timelineStagePhotoProgress(i);
      if (prog <= 0.0) continue;
      final double eased = Curves.easeOutCubic.transform(prog);
      final int alpha = (eased * 255).round().clamp(0, 255);

      final Rect rect = tiles[i];
      final RRect rrect =
          RRect.fromRectAndRadius(rect, Radius.circular(tileRadius));

      // White border grows in stroke width as it activates.
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = Colors.white.withAlpha(alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = _kStageBorderWidth * s * eased,
      );

      // Year plate: white tab on the border's bottom edge, black text.
      final String year = (i < events.length) ? events[i].date : '';
      if (year.isNotEmpty) {
        final yearTp = TextPainter(
          text: TextSpan(
            text: year,
            style: TextStyle(
              fontFamily: fontFamily,
              fontFamilyFallback: const [
                'Courier', 'Consolas', 'Courier New', 'monospace'
              ],
              fontSize: yearSize,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0 * s,
              color: Color.fromARGB(alpha, 20, 18, 15),
            ),
          ),
          textDirection: TextDirection.ltr,
        );
        yearTp.layout();

        final double plateW = yearTp.width + 14 * s;
        final double plateH = yearTp.height + 6 * s;
        final Rect plateRect = Rect.fromCenter(
          center: Offset(rect.center.dx, rect.bottom),
          width: plateW,
          height: plateH,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(plateRect, Radius.circular(3 * s)),
          Paint()..color = Colors.white.withAlpha(alpha),
        );
        yearTp.paint(
          canvas,
          Offset(plateRect.center.dx - yearTp.width / 2,
              plateRect.center.dy - yearTp.height / 2),
        );
      }
    }
  }

  // --------------------------------------------------------------------
  // Yaru chrome
  // --------------------------------------------------------------------

  /// Ubuntu-style header bar: warm dark grey, centered title, and the three
  /// window controls on the RIGHT as grey circles with ─ □ ✕ glyphs.
  /// [textOnly] draws the title and window controls without the bar behind
  /// them, for the second pass of a title crossfade. Painting the plate
  /// twice at complementary alphas would leave a visible dip in the bar
  /// itself at the midpoint, which is the one part of the chrome that must
  /// hold perfectly still while the content slides underneath it.
  void _drawYaruHeaderBar(Canvas canvas, Rect barRect, double s,
      {required String title,
      required double opacity,
      bool textOnly = false}) {
    final int a = (opacity.clamp(0.0, 1.0) * 255).round();

    if (!textOnly) {
      canvas.drawRect(barRect, Paint()..color = _kHeaderBar.withAlpha(a));

      // Hairline separator under the bar.
      canvas.drawRect(
        Rect.fromLTWH(
            barRect.left, barRect.bottom - 1 * s, barRect.width, 1 * s),
        Paint()..color = Color.fromARGB((a * 0.5).round(), 0, 0, 0),
      );
    }

    // Centered title.
    final tp = TextPainter(
      text: TextSpan(
        text: title,
        style: TextStyle(
          fontFamily: fontFamily,
          fontFamilyFallback: const ['Courier', 'Consolas', 'Courier New', 'monospace'],
          fontSize: 14 * s,
          fontWeight: FontWeight.bold,
          color: _kHeaderText.withAlpha(a),
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    tp.layout(maxWidth: barRect.width * 0.6);
    tp.paint(
      canvas,
      Offset(barRect.center.dx - tp.width / 2, barRect.center.dy - tp.height / 2),
    );

    _drawWindowControls(canvas, barRect, s, a);
  }

  /// The three Yaru circles: minimize, maximize, close.
  ///
  /// Split out of [_drawYaruHeaderBar] when the browser arrived. A browser's
  /// controls sit in its tab strip rather than in a title bar of their own,
  /// which is a different bar with a different height and its own contents —
  /// but they are the same three controls, and two copies of them would have
  /// drifted the first time one palette moved.
  void _drawWindowControls(Canvas canvas, Rect barRect, double s, int a) {
    final double r = barRect.height * 0.30; // control circle radius
    final double cy = barRect.center.dy;
    final double gap = r * 2.9;
    final double closeX = barRect.right - 14 * s - r;
    final double maxX = closeX - gap;
    final double minX = maxX - gap;

    final Paint circlePaint = Paint()..color = _kControlCircle.withAlpha(a);
    final Paint glyphPaint = Paint()
      ..color = _kControlGlyph.withAlpha(a)
      ..strokeWidth = 1.6 * s
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final double g = r * 0.52; // glyph half-extent

    // Minimize: ─
    canvas.drawCircle(Offset(minX, cy), r, circlePaint);
    canvas.drawLine(
        Offset(minX - g, cy + g * 0.6), Offset(minX + g, cy + g * 0.6), glyphPaint);

    // Maximize: □
    canvas.drawCircle(Offset(maxX, cy), r, circlePaint);
    canvas.drawRect(
        Rect.fromCenter(center: Offset(maxX, cy), width: g * 2, height: g * 2),
        glyphPaint);

    // Close: ✕
    canvas.drawCircle(Offset(closeX, cy), r, circlePaint);
    canvas.drawLine(
        Offset(closeX - g, cy - g), Offset(closeX + g, cy + g), glyphPaint);
    canvas.drawLine(
        Offset(closeX + g, cy - g), Offset(closeX - g, cy + g), glyphPaint);
  }

  // --------------------------------------------------------------------
  // Shared helpers
  // --------------------------------------------------------------------

  /// Applies open/close scale+fade around the window center, runs [body]
  /// inside a saveLayer so the whole window fades as a single unit.
  void _withWindowAnimation(
      Canvas canvas, Rect winRect, double openness, VoidCallback body) {
    final double eased = Curves.easeInOut.transform(openness.clamp(0.0, 1.0));
    final double scale = 0.85 + 0.15 * eased;
    final int alpha = (eased * 255).round().clamp(0, 255);

    // Inflate the layer bounds slightly so the drop shadow isn't clipped.
    final Rect layerBounds = winRect.inflate(60);

    canvas.saveLayer(layerBounds, Paint()..color = Color.fromARGB(alpha, 255, 255, 255));
    canvas.translate(winRect.center.dx, winRect.center.dy);
    canvas.scale(scale, scale);
    canvas.translate(-winRect.center.dx, -winRect.center.dy);

    body();

    canvas.restore();
  }

  /// Draws [img] scaled to COVER [rect] (fills, crops overflow). Wallpaper.
  /// COVER-fits [img] into [rect].
  ///
  /// [motion] applies pane life: a scale multiplier plus a bounded
  /// horizontal crop focus on the cover fit.
  /// Identity by default, so every existing call site renders exactly as
  /// it did.
  ///
  /// Applied to the DESTINATION rect rather than via a canvas transform.
  /// A canvas scale would also scale the clip and the rounded corners with
  /// it, and the panel frame must stay perfectly still while its contents
  /// move: a frame that breathes with the photo is a wobble, not a push.
  ///
  /// Scaling UP from cover fit can never expose an edge, since cover
  /// already crops to fill. Horizontal focus is clamped to the crop overflow
  /// that exists after fitting, so LR/RL travel cannot expose one
  /// either. A legacy panel at rest stays centred.
  ///
  /// [PaneMotion.fit] swaps the base scale away from COVER to one edge.
  /// `height` uses `rect.height / imgH`, `width` uses `rect.width / imgW`,
  /// whatever the source aspect. For a source wider than the rect, height
  /// IS the cover scale, so fitting an edge is not a new look for the
  /// images that already fitted; for a source the other way round it
  /// letterboxes against whatever the caller drew underneath (the mosaic
  /// plate) instead of throwing the ends away. The two clamps below then do
  /// the rest unchanged: a letterboxed source has zero horizontal overflow,
  /// so focusX becomes a no-op on its own rather than needing a guard, and
  /// the fitted edge stays flush or overflows because the zoom floor
  /// is 100%.
  ///
  /// Note the asymmetry, which is geometry and not a bug. A `height` pane
  /// holding a wide source has crop overflow at rest and so can travel; a
  /// `width` pane is exactly flush horizontally at rest and gains travel
  /// only once the push scales it past 1.0.
  void _drawImageCover(Canvas canvas, ui.Image img, Rect rect,
      {double opacity = 1.0,
      double blurSigma = 0.0,
      PaneMotion motion = PaneMotion.none}) {
    final double imgW = img.width.toDouble();
    final double imgH = img.height.toDouble();
    final double baseScale;
    switch (motion.fit) {
      case PaneFitMode.height:
        baseScale = rect.height / imgH;
        break;
      case PaneFitMode.width:
        baseScale = rect.width / imgW;
        break;
      case PaneFitMode.fill:
        baseScale = math.max(rect.width / imgW, rect.height / imgH);
        break;
    }
    final double scale = baseScale * motion.scale;
    final double w = imgW * scale;
    final double h = imgH * scale;
    final double overflowX = math.max(0.0, w - rect.width);
    final double focusX = motion.focusX.clamp(-1.0, 1.0);
    final Rect dst = Rect.fromLTWH(
      rect.left + (rect.width - w) / 2 - focusX * overflowX / 2,
      rect.top + (rect.height - h) / 2,
      w,
      h,
    );
    canvas.save();
    canvas.clipRect(rect);
    
    final Paint paint = Paint()
      ..filterQuality = FilterQuality.high
      ..color = Color.fromARGB(
          (opacity.clamp(0.0, 1.0) * 255).round(), 255, 255, 255);
          
    if (blurSigma > 0.0) {
      paint.imageFilter = ui.ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma);
    }
    
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, imgW, imgH),
      dst,
      paint,
    );
    canvas.restore();
  }

  /// Draws [img] scaled to CONTAIN within [rect] (letterboxed). Gallery pages.
  void _drawImageContain(Canvas canvas, ui.Image img, Rect rect,
      {required double opacity}) {
    final double imgW = img.width.toDouble();
    final double imgH = img.height.toDouble();
    final double scale = math.min(rect.width / imgW, rect.height / imgH);
    final double w = imgW * scale;
    final double h = imgH * scale;
    final Rect dst = Rect.fromLTWH(
      rect.left + (rect.width - w) / 2,
      rect.top + (rect.height - h) / 2,
      w,
      h,
    );
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, imgW, imgH),
      dst,
      Paint()
        ..filterQuality = FilterQuality.high
        ..color = Color.fromARGB((opacity.clamp(0.0, 1.0) * 255).round(), 255, 255, 255),
    );
  }

  @override
  bool shouldRepaint(covariant ScenePainter oldDelegate) => true;
}
/// A laid-out caption band, ready to paint.
///
/// Separate from the panel draw because measuring is where all the
/// decisions are: whether the band fits, whether the credit survives, and
/// how tall the photo rect must therefore become. Splitting it keeps the
/// panel routine describing what a panel IS rather than arithmetic about
/// what will fit.
///
/// Holds laid-out TextPainters rather than strings, so nothing is measured
/// twice and the height the panel deflated by is exactly the height that
/// gets painted.
class _CaptionBand {
  final double height;
  final double pad;
  final double gap;
  final TextPainter head;
  final TextPainter? credit;
  final double left;

  const _CaptionBand({
    required this.height,
    required this.pad,
    required this.gap,
    required this.head,
    required this.credit,
    required this.left,
  });

  /// Paints from [top], which is the bottom of the photo rect.
  ///
  /// Alignment is baked into the laid-out TextPainters rather than applied
  /// here, so both lines are ranged the same way with no arithmetic and no
  /// chance of the credit drifting out of step with the caption.
  ///
  /// The two readings are worth knowing when you choose: ranged left, the
  /// band is a catalogue entry; centred, with the credit centred under it,
  /// it is a museum label. Centred suits the blocky plate.
  void paint(Canvas canvas, double top) {
    double y = top + pad;
    head.paint(canvas, Offset(left, y));
    final TextPainter? c = credit;
    if (c != null) {
      y += head.height + gap;
      c.paint(canvas, Offset(left, y));
    }
  }
}