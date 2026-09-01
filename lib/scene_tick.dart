// ./lib/scene_tick.dart

part of 'scene_engine.dart';

// Deterministic scene phase runner. SceneEngine keeps setup, activation, caches,
// geometry, and public painter-facing state; this part owns the frame-by-frame
// phase transitions. The public SceneEngine.tick() contract is unchanged.

extension _SceneEngineTicking on SceneEngine {
  /// Whether the current phase reaches [duration] on this tick.
  ///
  /// Phase age is derived from the absolute scene frame and the frame where
  /// this phase became visible. Adding one asks where the phase will be after
  /// the current deterministic tick completes, preserving the legacy boundary.
  bool _phaseEndsThisTick(int duration) =>
      _phaseVisualFrames + 1 >= duration;

  void _tickDeterministic() {
    if (isFinished) return;

    switch (phase) {
      case ScenePhase.prerollIdle:
        if (_phaseEndsThisTick(kPrerollIdleFrames)) {
          _enterPhase(ScenePhase.prerollWipe);
        }
        break;

      case ScenePhase.prerollWipe:
        if (_phaseEndsThisTick(kPrerollWipeFrames)) {
          // Do NOT turn off inPrerollSequence yet! The terminal still needs to
          // visually zoom in over the green background.
          _enterPhase(ScenePhase.termZoomIn);
        }
        break;

      case ScenePhase.terminal:
        terminal.tick();

        // Did the terminal just raise a presentation request?
        if (_terminalHasPending) {
          final ScenePhase? opening = _activatePendingRequest();
          if (opening != null) {
            // Presentation built; pull back to the desktop first. The
            // termZoomOut exit routes into the right opening phase by
            // checking which _active* is non-null.
            _enterPhase(ScenePhase.termZoomOut);
          }
          // null = dud request, already skipped-and-burned; stay here.
        }
        break;

      case ScenePhase.termZoomOut:
        if (_phaseEndsThisTick(kZoomAnimFrames)) {
          // Route into whichever presentation is queued. The terminal parser
          // only sets one pending request per tag, so this is really a
          // mutual-exclusion switch.
          if (_activeGallery != null) {
            _enterPhase(ScenePhase.viewerOpening);
          } else if (_activeApp != null) {
            _enterPhase(ScenePhase.appOpening);
          } else if (_activeBrowser != null) {
            _enterPhase(ScenePhase.browserOpening);
          } else if (_activeCard != null) {
            _enterPhase(ScenePhase.cardOpening);
          } else if (_activeDossier != null) {
            _enterPhase(ScenePhase.dossierOpening);
          } else if (_activeTimeline != null) {
            _enterPhase(ScenePhase.timelineOpening);
          } else {
            // Nothing queued (defensive) — go straight back.
            _enterPhase(ScenePhase.termZoomIn);
          }
        }
        break;

      case ScenePhase.viewerOpening:
        if (_phaseEndsThisTick(kWindowAnimFrames)) {
          _enterPhase(ScenePhase.viewerShowing);
        }
        break;

      case ScenePhase.viewerShowing:
        final g = _activeGallery!;

        if (g.isVideo) {
          g.framesIntoPhase++;

          // VIDEO starts with the scripted hold on source frame zero. On the
          // threshold tick we immediately enter playback, which preserves the
          // old 30-fps behavior exactly: frame 1 appears on hold tick 60 when
          // hold=60, rather than one engine tick later.
          if (!g.videoPlaybackStarted) {
            if (g.framesIntoPhase < g.holdFrames) break;

            // Legacy one-frame sequence behavior: the first-frame hold is the
            // entire presentation; there is no second final-frame hold.
            if (g.images.length == 1) {
              _chainClosing = terminal.peekNextPresentation();
              _enterPhase(ScenePhase.viewerClosing);
              break;
            }

            g.videoPlaybackStarted = true;
            g.framesIntoPhase = 0;
          } else if (g.imageIndex >= g.images.length - 1) {
            // Final source frame always sits for one R3nder second, regardless
            // of source FPS. This is scene timing, not source-video timing.
            if (g.framesIntoPhase >= engineFps) {
              _chainClosing = terminal.peekNextPresentation();
              _enterPhase(ScenePhase.viewerClosing);
            }
            break;
          }

          // Integer/rational frame-rate conversion. Each R3nder output tick
          // contributes sourceFps / engineFps source frames. Rates below 30
          // naturally repeat source images; rates above 30 naturally skip
          // them. No wall clock or floating-point time is involved.
          g.videoFrameAccumulator += g.videoFpsNumerator;
          final int threshold = engineFps * g.videoFpsDenominator;
          final int advance = g.videoFrameAccumulator ~/ threshold;
          g.videoFrameAccumulator %= threshold;

          if (advance > 0) {
            final int last = g.images.length - 1;
            final int next = g.imageIndex + advance;
            g.imageIndex = next > last ? last : next;
            g.framesIntoPhase = 0;
          }
          break;
        }

        // Ordinary still galleries use absolute scene phase age for each
        // image hold. CUT explicitly re-enters viewerShowing so the next
        // image gets a new absolute phase start frame without a side counter.
        if (_phaseEndsThisTick(g.holdFrames)) {
          if (g.imageIndex >= g.images.length - 1) {
            // Last image held: close the viewer. If another presentation
            // tag is next in the script, hand off instead of zooming in.
            _chainClosing = terminal.peekNextPresentation();
            _enterPhase(ScenePhase.viewerClosing);
          } else if (g.transition == 'CUT') {
            // Instant page turn.
            g.imageIndex++;
            _enterPhase(ScenePhase.viewerShowing);
          } else {
            // Animated page turn (FADE / FLIP).
            g.imageIndex++;
            g.framesIntoPhase = 0;
            _enterPhase(ScenePhase.viewerTransition);
          }
        }
        break;

      case ScenePhase.viewerTransition:
        if (_phaseEndsThisTick(kGalleryTransitionFrames)) {
          _activeGallery!.framesIntoPhase = 0;
          _enterPhase(ScenePhase.viewerShowing);
        }
        break;

      case ScenePhase.viewerClosing:
        if (_phaseEndsThisTick(kWindowAnimFrames)) {
          if (_chainClosing) {
            _performChainHandoff();
          } else {
            _enterPhase(ScenePhase.termZoomIn);
          }
        }
        break;

      case ScenePhase.appOpening:
        if (_phaseEndsThisTick(kWindowAnimFrames)) {
          // Only a _FULL window grows into the frame. Everything else,
          // mosaic included, stays the size it opened at.
          _enterPhase(_activeApp!.maximizes
              ? ScenePhase.appMaximizing
              : ScenePhase.appShowing);
        }
        break;

      case ScenePhase.appMaximizing:
        if (_phaseEndsThisTick(kAppMaximizeFrames)) {
          _enterPhase(ScenePhase.appShowing);
        }
        break;

      case ScenePhase.appShowing:
        final a = _activeApp!;
        a.framesIntoPhase++;
        // Wait for the cascade to finish, THEN hold for the script's
        // duration. In MOSAIC the hold is per page, so a page that still has
        // successors pans on instead of leaving.
        //
        // currentHoldFrames, not holdFrames: a page whose panes authored
        // `+N` extensions genuinely owns more time than the script's base
        // hold. This is the point at which the piece gets longer.
        if (a.framesIntoPhase >=
            a.cascadeTotalFrames + a.currentHoldFrames) {
          if (a.hasMorePages) {
            _enterPhase(ScenePhase.appPanning);
          } else if (_tryAbsorbNextApp()) {
            // APPSWITCH:SLIDE. The next APP tag became more pages of this
            // window, so the transition is the page pan that already
            // exists rather than a close and an open. Checked here, at the
            // end of the last page, because that is the only moment where
            // both "this window is finished" and "the next tag has not
            // been consumed" are true.
            _enterPhase(ScenePhase.appPanning);
          } else {
            // Peek before either exit path, so the flag is settled by the
            // time the painter needs it on the first frame of the restore.
            _chainClosing = terminal.peekNextPresentation();
            _enterPhase(a.maximizes
                ? ScenePhase.appRestoring
                : ScenePhase.appClosing);
          }
        }
        break;

      case ScenePhase.appPanning:
        if (_phaseEndsThisTick(kAppPanFrames)) {
          // The incoming page becomes the held page. _enterPhase resets
          // framesIntoPhase, so the new page starts its own hold clean.
          _activeApp!.pageIndex++;
          // New page, new panel count and no cascade, so the motion plan
          // is rebuilt against the budget this page actually owns.
          _activeApp!.rebuildPanePlan();
          _enterPhase(ScenePhase.appShowing);
        }
        break;

      case ScenePhase.appRestoring:
        if (_phaseEndsThisTick(kAppMaximizeFrames)) {
          _enterPhase(ScenePhase.appClosing);
        }
        break;

      case ScenePhase.appClosing:
        if (_phaseEndsThisTick(kWindowAnimFrames)) {
          if (_chainClosing) {
            _performChainHandoff();
          } else {
            _enterPhase(ScenePhase.termZoomIn);
          }
        }
        break;

      case ScenePhase.browserOpening:
        if (_phaseEndsThisTick(kWindowAnimFrames)) {
          // A full browser grows out of the window it just opened as, rather
          // than arriving at full frame. The mosaic does the same, and for
          // the same reason: a window that is fullscreen from the first frame
          // never reads as a window at all.
          _enterPhase(_activeBrowser!.maximizes
              ? ScenePhase.browserMaximizing
              : ScenePhase.browserShowing);
        }
        break;

      case ScenePhase.browserMaximizing:
        if (_phaseEndsThisTick(kBrowserMaximizeFrames)) {
          _enterPhase(ScenePhase.browserShowing);
        }
        break;

      case ScenePhase.browserShowing:
        final br = _activeBrowser!;
        // The browser's visual age now mirrors absolute scene phase age.
        // The field remains temporarily because the painter-facing browser
        // helper still reads it; it is no longer an accumulating clock.
        br.framesIntoPhase = _phaseVisualFrames + 1;
        // The page's own hold, which under SCROLL is also the budget the
        // travel lives inside. The scroll divides it and never extends it,
        // so a capture twenty screens tall costs the same frames as one
        // that fits — the same neutrality rule Pane Life follows, and for
        // the same reason: a look must not re-time a finished piece.
        if (_phaseEndsThisTick(br.currentHold)) {
          if (br.hasMorePages) {
            _enterPhase(ScenePhase.browserNavigating);
          } else if (_tryAbsorbNextBrowser()) {
            // APPSWITCH:SLIDE. The next BROWSER tag became more pages of
            // this window, so the join between two tags is the same
            // navigation as the join between two captures inside one.
            // Checked here, at the end of the last page, because this is
            // the only moment where both "this window is finished" and
            // "the next tag has not been consumed" are true.
            _enterPhase(ScenePhase.browserNavigating);
          } else {
            _chainClosing = terminal.peekNextPresentation();
            // A full window shrinks back to its desktop rect before it
            // closes, so the exit is the entrance played backwards. The
            // chain decision is taken HERE rather than after the restore,
            // because the restore consumes frames during which the terminal
            // must already know whether it is coming back.
            _enterPhase(br.maximizes
                ? ScenePhase.browserRestoring
                : ScenePhase.browserClosing);
          }
        }
        break;

      case ScenePhase.browserRestoring:
        if (_phaseEndsThisTick(kBrowserMaximizeFrames)) {
          _enterPhase(ScenePhase.browserClosing);
        }
        break;

      case ScenePhase.browserNavigating:
        if (_phaseEndsThisTick(kBrowserNavFrames)) {
          // The incoming page becomes the held page. _enterPhase resets
          // framesIntoPhase, so the new page starts its own hold — and
          // therefore its own scroll — from zero.
          _activeBrowser!.pageIndex++;
          _enterPhase(ScenePhase.browserShowing);
        }
        break;

      case ScenePhase.browserClosing:
        if (_phaseEndsThisTick(kWindowAnimFrames)) {
          if (_chainClosing) {
            _performChainHandoff();
          } else {
            _enterPhase(ScenePhase.termZoomIn);
          }
        }
        break;

      case ScenePhase.cardOpening:
        if (_phaseEndsThisTick(kCardSlideFrames)) {
          _enterPhase(ScenePhase.cardShowing);
        }
        break;

      case ScenePhase.cardShowing:
        final c = _activeCard!;
        if (_phaseEndsThisTick(c.holdFrames)) {
          _chainClosing = terminal.peekNextPresentation();
          _enterPhase(ScenePhase.cardClosing);
        }
        break;

      case ScenePhase.cardClosing:
        if (_phaseEndsThisTick(kCardSlideFrames)) {
          if (_chainClosing) {
            _performChainHandoff();
          } else {
            _enterPhase(ScenePhase.termZoomIn);
          }
        }
        break;

      case ScenePhase.dossierOpening:
        if (_phaseEndsThisTick(kCardSlideFrames)) {
          // With a scripted lead the card is now seated alone; count the
          // lead down before the gallery joins. Classic (lead = 0) goes
          // straight to the split, gallery having opened alongside.
          if (_activeDossier!.cardLead > 0) {
            _enterPhase(ScenePhase.dossierCardLead);
          } else {
            _enterPhase(ScenePhase.dossierSplitShowing);
          }
        }
        break;

      case ScenePhase.dossierCardLead:
        if (_phaseEndsThisTick(_activeDossier!.cardLead)) {
          _enterPhase(ScenePhase.dossierGalleryOpening);
        }
        break;

      case ScenePhase.dossierGalleryOpening:
        if (_phaseEndsThisTick(kWindowAnimFrames)) {
          _enterPhase(ScenePhase.dossierSplitShowing);
        }
        break;

      case ScenePhase.dossierSplitShowing:
        _activeDossier!.framesIntoPhase++;
        if (_activeDossier!.framesIntoPhase >= _activeDossier!.holdSplit) {
          if (_activeDossier!.centerMode == DossierCenterMode.sideOnly) {
            _chainClosing = terminal.peekNextPresentation();
            _enterPhase(ScenePhase.dossierClosing);
          } else {
            _enterPhase(ScenePhase.dossierTransitioning);
          }
        }
        break;

      case ScenePhase.dossierTransitioning:
        if (_phaseEndsThisTick(kWindowAnimFrames)) {
          _enterPhase(ScenePhase.dossierFullShowing);
        }
        break;

      case ScenePhase.dossierFullShowing:
        _activeDossier!.framesIntoPhase++;
        if (_activeDossier!.framesIntoPhase >= _activeDossier!.holdFull) {
          if (_activeDossier!.hasMoreMosaicPages) {
            _enterPhase(ScenePhase.dossierMosaicPanning);
          } else {
            _chainClosing = terminal.peekNextPresentation();
            _enterPhase(ScenePhase.dossierClosing);
          }
        }
        break;

      case ScenePhase.dossierMosaicPanning:
        if (_phaseEndsThisTick(kAppPanFrames)) {
          _activeDossier!.mosaicPageIndex++;
          _enterPhase(ScenePhase.dossierFullShowing);
        }
        break;

      case ScenePhase.dossierClosing:
        final int closeFrames = _activeDossier!.centerMode ==
                DossierCenterMode.sideOnly
            ? kCardSlideFrames
            : kWindowAnimFrames;
        if (_phaseEndsThisTick(closeFrames)) {
          if (_chainClosing) {
            _performChainHandoff();
          } else {
            _enterPhase(ScenePhase.termZoomIn);
          }
        }
        break;

      case ScenePhase.timelineOpening:
        if (_phaseEndsThisTick(kCardSlideFrames)) {
          _enterPhase(ScenePhase.timelineShowing);
        }
        break;

      case ScenePhase.timelineShowing:
        final t = _activeTimeline!;
        t.framesIntoPhase++;
        // Wait for the full reveal (spine + event cascade), THEN hold.
        if (t.framesIntoPhase >= t.revealTotalFrames + t.holdFrames) {
          _chainClosing = terminal.peekNextPresentation();
          _enterPhase(ScenePhase.timelineClosing);
        }
        break;

      case ScenePhase.timelineClosing:
        if (_phaseEndsThisTick(kCardSlideFrames)) {
          if (_chainClosing) {
            _performChainHandoff();
          } else {
            _enterPhase(ScenePhase.termZoomIn);
          }
        }
        break;

      case ScenePhase.termZoomIn:
        if (_phaseEndsThisTick(kZoomAnimFrames)) {
          // Shared exit: whichever kind of presentation was up gets torn
          // down and whichever pending request is set on the terminal gets
          // cleared.
          _activeGallery = null;
          _activeApp = null;
          _activeCard = null;
          _activeDossier = null;
          _activeTimeline = null;
          terminal.clearPresentationRequest();
          // The window has successfully landed back at pure fullscreen black.
          // NOW we can safely turn off the preroll flag. Future zooms will
          // reveal the normal desktop wallpaper.
          inPrerollSequence = false;
          _enterPhase(ScenePhase.terminal);
        }
        break;
    }

    frameCount++;
  }
}
