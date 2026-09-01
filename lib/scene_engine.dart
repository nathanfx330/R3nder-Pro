// ./lib/scene_engine.dart

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

import 'engine.dart';
import 'folder_order.dart';
import 'folder_captions.dart';
import 'parser.dart';
import 'svg_path.dart';
import 'motion.dart';
import 'diag.dart';

part 'scene_timing.dart';
part 'scene_state.dart';
part 'scene_tick.dart';

// =====================================================================
// SETUP PROFILING
//
// setup() is the whole cost of opening the editor and of every debounced
// re-simulation after an edit. Which PHASE of it is expensive is not
// something reading the code answers: it depends entirely on what a given
// script references, and a text-only script and one with thirty 4K
// gallery plates run identical code at wildly different cost.
//
// Left in deliberately. Reading this code produced three confident wrong
// answers about where the time went (a layout shift, a duplicated
// simulation pass, a cold warm-up); switching this on found the real one,
// a serial await loop over image decodes, in a single run. Flip to true
// the next time something feels slow, rather than guessing.
//
// const false, so every call site compiles away.
// =====================================================================
const bool kProfileSetup = false;

void _profile(Stopwatch sw, String label, int count) {
  if (!kProfileSetup) return;
  diag('setup', '${sw.elapsedMilliseconds}ms  $label'
      '${count >= 0 ? '  (n=$count)' : ''}');
  sw.reset();
}


/// The SceneEngine owns the whole picture: wallpaper, simulated windows,
/// gallery sequencing, and the TerminalEngine as the content of the terminal
/// window. It honors the exact same contract as TerminalEngine —
/// tick() / isFinished / reset() / frameCount — so the exporter, editor
/// scrubber, and playback all drive it unchanged.
///
/// Nothing here touches wall-clock time or unseeded randomness: every phase
/// is frame-counted, so any frame N is reproducible by reset() + N ticks.
///
/// PRESENTATION CHAINING: when one presentation tag is followed immediately
/// (whitespace only) by another, the sequences hand off directly on the desktop —
/// the outgoing panel closes, the incoming one opens, and the terminal never
/// zooms back up between them. The fiction is an AI operating a computer: it
/// opens windows one after another; it doesn't zoom for emphasis. Any real
/// content between two tags (typed text, a [PAUSE]) breaks the chain and the
/// normal zoom-in return plays.
///
/// IN-TERMINAL SVG: [SVG] / [SVGFLASH] shows are NOT presentations — they
/// never leave the terminal screen, so the SceneEngine's only involvement
/// is preloading and parsing the .svg files during setup() and handing the
/// library to the TerminalEngine, exactly like sprites.
///
/// IN-TERMINAL IMG: [IMG] bands are the same story — Programmed Symbols
/// raster stencils. The SceneEngine's only involvement is decoding each
/// referenced file ONCE during setup(), hard-thresholding the scripted
/// channel, run-merging the on-pixels into an ImgStencil path, and handing
/// the library to the TerminalEngine. The decoded pixels are discarded
/// immediately; only geometry survives, so nothing here needs disposal.
class SceneEngine {
  final TerminalEngine terminal = TerminalEngine();

  /// Global frame counter for the whole scene (terminal time + gallery time).
  int frameCount = 0;

  /// Null when the script has no [CONFIG:DESKTOP:...]; the painter then
  /// renders the terminal fullscreen with no window chrome, matching the
  /// classic R3nder behavior exactly.
  ui.Image? wallpaper;

  bool get hasDesktop => wallpaper != null;

  /// Terminal window title bar text, from [CONFIG:WINTITLE:...].
  String terminalWindowTitle = kDefaultTerminalTitle;

  /// Remembers the user's preroll choice so scrubbing backwards doesn't break.
  bool _configWithPreroll = false;

  /// See setup(): alpha describes what is NOT terminal. Read by ScenePainter
  /// to suppress the backdrop fills. Config, not state, so reset() leaves it.
  bool transparentBackdrop = false;

  /// Dynamically true ONLY during the preroll intro. Turns false afterward.
  bool inPrerollSequence = false;
  
  Color prerollColor = const Color(0xFF00FF00); // Default to Green

  ScenePhase phase = ScenePhase.terminal;

  /// True while the current closing phase is a chain hand-off: the terminal
  /// must NOT fade back in, because the next presentation opens immediately.
  /// Decided (via terminal.peekNextPresentation()) the moment the hold
  /// expires, so the painter knows from the first closing frame.
  bool _chainClosing = false;
  bool get isChainClosing => _chainClosing;

  /// True while the current opening phase was entered via a chain hand-off:
  /// the terminal is already hidden and must stay hidden, instead of the
  /// normal fade-out-from-full that a fresh opening performs.
  bool _chainOpening = false;
  bool get isChainOpening => _chainOpening;

  /// 0..1 progress through the current animated phase.
  ///
  /// Painter-facing animation age is derived from the absolute scene frame
  /// and the frame on which this phase became visible. Transition decisions
  /// use that same absolute phase age, so painting and phase boundaries share
  /// one clock.
  double get phaseProgress {
    switch (phase) {
      case ScenePhase.termZoomOut:
      case ScenePhase.termZoomIn:
        return (_phaseVisualFrames / kZoomAnimFrames).clamp(0.0, 1.0);
      case ScenePhase.viewerOpening:
      case ScenePhase.viewerClosing:
      case ScenePhase.appOpening:
      case ScenePhase.appClosing:
      case ScenePhase.browserOpening:
      case ScenePhase.browserClosing:
      case ScenePhase.dossierGalleryOpening:
      case ScenePhase.dossierTransitioning:
        return (_phaseVisualFrames / kWindowAnimFrames).clamp(0.0, 1.0);
      case ScenePhase.dossierClosing:
        return (_phaseVisualFrames /
                (dossierSideOnly ? kCardSlideFrames : kWindowAnimFrames))
            .clamp(0.0, 1.0);
      case ScenePhase.cardOpening:
      case ScenePhase.cardClosing:
      case ScenePhase.dossierOpening:
      case ScenePhase.timelineOpening:
      case ScenePhase.timelineClosing:
        return (_phaseVisualFrames / kCardSlideFrames).clamp(0.0, 1.0);
      case ScenePhase.viewerTransition:
        return (_phaseVisualFrames / kGalleryTransitionFrames).clamp(0.0, 1.0);
      case ScenePhase.browserNavigating:
        return (_phaseVisualFrames / kBrowserNavFrames).clamp(0.0, 1.0);
      case ScenePhase.appPanning:
      case ScenePhase.dossierMosaicPanning:
        return (_phaseVisualFrames / kAppPanFrames).clamp(0.0, 1.0);
      case ScenePhase.appMaximizing:
      case ScenePhase.appRestoring:
        return (_phaseVisualFrames / kAppMaximizeFrames).clamp(0.0, 1.0);
      case ScenePhase.browserMaximizing:
      case ScenePhase.browserRestoring:
        return (_phaseVisualFrames / kBrowserMaximizeFrames).clamp(0.0, 1.0);
      case ScenePhase.prerollWipe:
        return (_phaseVisualFrames / kPrerollWipeFrames).clamp(0.0, 1.0);
      default:
        return 0.0;
    }
  }

  /// Absolute scene frame on which the current phase first became visible.
  int _phaseStartFrame = 0;

  /// Frames elapsed in the current phase as seen by the painter.
  int get _phaseVisualFrames => frameCount - _phaseStartFrame;

  _ActiveGallery? _activeGallery;
  _ActiveApp? _activeApp;
  _ActiveBrowser? _activeBrowser;
  _ActiveCard? _activeCard;
  _ActiveDossier? _activeDossier;
  _ActiveTimeline? _activeTimeline;

  /// Painter accessors for the gallery viewer.
  ui.Image? get galleryCurrentImage {
    final g = _activeGallery;
    if (g == null || g.images.isEmpty) return null;
    return g.images[g.imageIndex.clamp(0, g.images.length - 1)];
  }

  ui.Image? get galleryPrevImage {
    final g = _activeGallery;
    if (g == null || g.imageIndex == 0 || g.images.isEmpty) return null;
    return g.images[g.imageIndex - 1];
  }

  String get galleryTransitionStyle => _activeGallery?.transition ?? 'CUT';

  /// Viewer window title for the gallery currently in flight.
  String get galleryTitle => _activeGallery?.title ?? kDefaultViewerTitle;

  // -------------------------------------------------------------------
  // App-window painter accessors
  // -------------------------------------------------------------------

  /// Images for the app grid currently in flight, or null when no app is up.
  List<ui.Image>? get appImages => _activeApp?.images;

  /// GRID shape. Untouched: the painter's grid path still drives off these.
  int get appGridCols => _activeApp?.gridCols ?? 0;
  int get appGridRows => _activeApp?.gridRows ?? 0;

  /// True when the window arranges its images as a Metro mosaic rather than
  /// the uniform grid. Says nothing about how big the window is.
  bool get appIsMosaic => _activeApp?.isMosaic ?? false;

  /// Pane life settings from [CONFIG:PANELIFE:...], off by default.
  ///
  /// Held on the engine rather than passed per presentation because it is
  /// a script-level default. A per-event override would want a modifier
  /// tag, which is deliberately not built: see PROPOSAL-pane-life.md.
  PaneLifeConfig paneLife = PaneLifeConfig.off;

  /// Typography for MOSAIC caption bands, from [CONFIG:CAPTION:...].
  ///
  /// Defaults are the values captions shipped with, so a script without
  /// the key renders exactly as it did before the key existed.
  CaptionConfig captionStyle = CaptionConfig.defaults;

  /// What happens between two adjacent APP tags, from
  /// [CONFIG:APPSWITCH:...]. Defaults to the desktop round trip.
  AppSwitchMode appSwitch = AppSwitchMode.desktop;

  /// True when the window maximizes out to the whole frame. Independent of
  /// the composition.
  bool get appMaximizes => _activeApp?.maximizes ?? false;

  /// Number of pages of panels. Always 1 for GRID.
  int get appPageCount => _activeApp?.pageCount ?? 0;

  /// The page being held, or the OUTGOING page during a pan.
  int get appPageIndex => _activeApp?.pageIndex ?? 0;

  /// MOSAIC panel geometry for [page] as unit rects in 0..1 space. Empty for
  /// GRID. See the layout contract on _ActiveApp.
  List<Rect> appPageRects(int page) {
    final a = _activeApp;
    if (a == null || page < 0 || page >= a.pages.length) return const [];
    return a.pages[page];
  }

  /// Source image currently displayed by MOSAIC pane [i] on [page].
  ///
  /// Pane Life can swap several authored source images through one visual
  /// pane, so the painter asks for the exact image at this frame rather than
  /// receiving a page-wide static image list.
  ui.Image? appPaneImage(int page, int i) {
    final a = _activeApp;
    if (a == null || page < 0 || page >= a.pagePanes.length) return null;
    final panes = a.pagePanes[page];
    if (i < 0 || i >= panes.length || panes[i].images.isEmpty) return null;

    final PaneFrame frame = _appPaneFrame(a, page, i);
    final int idx = frame.imageIndex.clamp(0, panes[i].images.length - 1).toInt();
    return panes[i].images[idx];
  }

  /// 0..1 linear progress of the horizontal page pan, 0 outside appPanning.
  /// The painter owns the easing, as it does for every other animation.
  double get appPanT {
    if (phase != ScenePhase.appPanning) return 0.0;
    return (_phaseVisualFrames / kAppPanFrames).clamp(0.0, 1.0);
  }

  /// Per-tile cascade opacity for panel index [i] on the current page, 0..1.
  /// During appOpening the window itself is animating in and no tiles are
  /// visible yet, so this returns 0 outside the showing and panning phases.
  /// During a pan the panels are fully opaque and the slide carries them.
  double appTileOpacity(int i) {
    final a = _activeApp;
    if (a == null) return 0.0;
    // During a pan or a restore the panels are already revealed; the slide
    // and the shrink carry them, so the cascade ramp does not apply.
    if (phase == ScenePhase.appPanning ||
        phase == ScenePhase.appRestoring) {
      return 1.0;
    }
    if (phase != ScenePhase.appShowing) return 0.0;
    return a.tileOpacityAt(i, _phaseVisualFrames);
  }

  /// Scale and drift for mosaic panel [i] on page [page].
  ///
  /// Identity whenever pane life is off, the layout is GRID, or the page
  /// is too short to move legibly, so the painter can apply it
  /// unconditionally and existing scripts render exactly as before.
  ///
  /// FREEZES RATHER THAN RELEASING. Only the held page moves, and only
  /// during appShowing, but a panel that has drifted must not snap back
  /// when that phase ends. The direct phase age restarts on every phase
  /// change, so evaluating the outgoing pane at the new phase's zero would
  /// jump every panel to centre on the exact frame a page turn begins.
  ///
  /// So during the pan, the restore, and the close, the outgoing page is
  /// evaluated at the end of the budget it just finished: exactly where it
  /// was on its last drawn frame. The slide and the shrink then carry it
  /// from a standstill, which is also the honest answer to whether drift
  /// plus pan reads as depth or as a mistake. It never happens.
  ///
  /// The INCOMING page during a pan is always at rest. Its own hold, and
  /// its own motion, begin when it becomes the held page.
  PaneMotion appPaneMotion(int page, int i) {
    final a = _activeApp;
    if (a == null) return PaneMotion.none;
    return _appPaneFrame(a, page, i).motion;
  }

  /// Caption for the image pane [i] is showing on this exact frame.
  ///
  /// Goes through the same frame lookup as the image itself, so a pane
  /// walking several photographs relabels in step with them rather than
  /// holding the first caption across the whole run. The swap is a cut:
  /// crossfading two different sentences produces a frame of unreadable
  /// overlap, and a label is either right or it is not.
  ImageCaption appPaneCaption(int page, int i) {
    final a = _activeApp;
    if (a == null) return ImageCaption.none;
    final _MosaicPane? pane = _paneAt(a, page, i);
    if (pane == null) return ImageCaption.none;
    return pane.captionAt(_appPaneFrame(a, page, i).imageIndex);
  }

  /// Whether pane [i] reserves band space at all, regardless of which of
  /// its images is currently up. Geometry is a pane-level fact; see
  /// [_MosaicPane.reservesBand].
  bool appPaneReservesBand(int page, int i) {
    final a = _activeApp;
    if (a == null) return false;
    return _paneAt(a, page, i)?.reservesBand ?? false;
  }

  PaneFrame _appPaneFrame(_ActiveApp a, int page, int i) {
    final PaneFrame f = _appPaneFrameMotion(a, page, i);
    final _MosaicPane? pane = _paneAt(a, page, i);
    if (pane == null || pane.fit == PaneFit.fill) return f;
    return PaneFrame(
      imageIndex: f.imageIndex,
      motion: f.motion.withFit(pane.fitMode),
    );
  }

  /// The pane at [page]/[i], or null when either index is out of range.
  _MosaicPane? _paneAt(_ActiveApp a, int page, int i) {
    if (page < 0 || page >= a.pagePanes.length) return null;
    final panes = a.pagePanes[page];
    if (i < 0 || i >= panes.length) return null;
    return panes[i];
  }

  /// Which image a pane shows and how it moves, before fit is applied.
  ///
  /// Split from [_appPaneFrame] so fit is stamped in exactly one place.
  /// Every branch below returns a motion for some reason of its own, and
  /// several of them return [PaneMotion.none] as a way of saying "this pane
  /// is not animating", which is a statement about motion and not about
  /// scaling. Fit is orthogonal and has to survive all of them, including
  /// the early return taken when Pane Life is off entirely.
  PaneFrame _appPaneFrameMotion(_ActiveApp a, int page, int i) {
    if (page < 0 || page >= a.pagePanes.length) {
      return const PaneFrame(imageIndex: 0, motion: PaneMotion.none);
    }
    final panes = a.pagePanes[page];
    if (i < 0 || i >= panes.length) {
      return const PaneFrame(imageIndex: 0, motion: PaneMotion.none);
    }
    final _MosaicPane pane = panes[i];
    final int first = pane.direction == PaneDirection.rightToLeft
        ? pane.images.length - 1
        : 0;

    // Incoming pages are visible during the pan but their own timeline has
    // not begun yet. Only an explicitly selected pane is allowed to prepare
    // for motion. Unstarred panes stay on their first source image; CONFIG ON
    // by itself must never make them participate.
    if (page != a.pageIndex) {
      final int selectedCount = panes.where((p) => p.hasHero).length;
      final bool canAnimate = pane.hasHero &&
          a.paneLife.enabled &&
          selectedCount > 0 &&
          a.holdFrames ~/ selectedCount >= kPaneMinPushFrames;
      return PaneFrame(
        imageIndex: canAnimate ? first : pane.staticImageIndex,
        // Parked where its walk will begin, not centred. A selected pane
        // arriving on the pan and THEN snapping its crop across half the
        // overflow would just relocate the jump to the frame the pan
        // lands on.
        //
        // Read off THIS pane's own spec, not off panePlan: the plan is
        // rebuilt per page and describes the HELD page, so asking it about
        // a pane on the incoming page returns a different pane's answer.
        motion: canAnimate ? pane.sequence.walkStartMotion : PaneMotion.none,
      );
    }

    // Pane structure and Pane Life selection are separate authored facts.
    // With CONFIG off, with no selected heroes, or with too little hold, the
    // pane renders its selected hero (if it has one) or its first image.
    if (!a.panePlan.isActive) {
      return PaneFrame(
          imageIndex: pane.staticImageIndex, motion: PaneMotion.none);
    }

    switch (phase) {
      case ScenePhase.appShowing:
        return a.paneFrameAt(i, _phaseVisualFrames);

      case ScenePhase.appPanning:
      case ScenePhase.appRestoring:
      case ScenePhase.appClosing:
        // Held at the far end of the ramp. MotionRamp clamps past its
        // duration, so any frame at or beyond the budget gives the same
        // answer as the last frame drawn.
        return a.panePlan
            .frameAt(i, a.cascadeTotalFrames + a.holdFrames);

      default:
        return PaneFrame(imageIndex: first, motion: PaneMotion.none);
    }
  }

  /// Title for the page currently held.
  ///
  /// Page-aware because a SLIDE switch puts pages from different APP tags
  /// in one window, and the title belongs to the tag rather than to the
  /// window. Every script that never switches has one title for every
  /// page and this returns exactly what it always did.
  String get appTitle =>
      _activeApp?.titleFor(_activeApp!.pageIndex) ?? kDefaultAppTitle;

  /// Title of the page sliding in, or null when it matches the outgoing
  /// one. Null is the common case and means the header needs no crossfade:
  /// dissolving identical text against itself dips to about three quarters
  /// opacity at the midpoint, which reads as a flicker in the chrome at
  /// exactly the moment the eye is on the content.
  String? get appTitleIncoming {
    final a = _activeApp;
    if (a == null || phase != ScenePhase.appPanning) return null;
    final String from = a.titleFor(a.pageIndex);
    final String to = a.titleFor(a.pageIndex + 1);
    return to == from ? null : to;
  }

  // -------------------------------------------------------------------
  // Browser-window painter accessors
  //
  // The split of labour here is the same one the mosaic uses for pane
  // motion. The engine says how far down the page we are as a fraction,
  // deterministically, from frame counts alone; the painter multiplies
  // that by the overflow the capture actually has once it knows the
  // viewport. Neither half can answer alone: the engine has no viewport
  // and the painter has no clock.
  // -------------------------------------------------------------------

  bool get hasActiveBrowser => _activeBrowser != null;

  ui.Image? get browserImage => _activeBrowser?.currentImage;

  /// The capture arriving during a navigation. Null outside one.
  ui.Image? get browserIncomingImage =>
      phase == ScenePhase.browserNavigating ? _activeBrowser?.nextImage : null;

  /// Address bar text for the page being shown.
  ///
  /// During a navigation this is already the INCOMING page's address. A
  /// browser writes the new URL into the bar the moment you commit and
  /// then loads it, so the bar leading the content by a few frames is
  /// correct rather than an error. It is also the cheapest possible way to
  /// sell the navigation: the bar changing is what tells the eye that
  /// something was clicked.
  String get browserUrl {
    final b = _activeBrowser;
    if (b == null) return '';
    final int page = phase == ScenePhase.browserNavigating
        ? b.pageIndex + 1
        : b.pageIndex;
    return b.sourceAt(page).displayUrl;
  }

  /// Tab caption for the page being shown, on the same lead as [browserUrl].
  String get browserTabTitle {
    final b = _activeBrowser;
    if (b == null) return '';
    final int page = phase == ScenePhase.browserNavigating
        ? b.pageIndex + 1
        : b.pageIndex;
    return b.sourceAt(page).displayTabTitle;
  }

  /// Window title bar text for the page currently held. Page-aware because
  /// a SLIDE switch puts pages from different BROWSER tags in one window.
  /// Window title bar text.
  ///
  /// Page-aware because a SLIDE switch puts pages from different BROWSER
  /// tags in one window, and it leads on the same frame the address bar
  /// does. The title cuts rather than crossfading: dissolving one label
  /// into another produces a frame where neither is legible, and unlike the
  /// app window's panorama there is no pan here to hide it under.
  String get browserWindowTitle {
    final b = _activeBrowser;
    if (b == null) return kDefaultBrowserTitle;
    final int page = phase == ScenePhase.browserNavigating
        ? b.pageIndex + 1
        : b.pageIndex;
    return b.titleAt(page);
  }

  BrowserScroll get browserScrollMode =>
      _activeBrowser?.currentScroll ?? BrowserScroll.scroll;

  /// True when this window fills the frame. Independent of the scroll mode
  /// even though both were authored in the same segment, which is the whole
  /// reason that segment is split the moment it is parsed.
  bool get browserMaximizes => _activeBrowser?.maximizes ?? false;

  /// 0..1 through the page's own scroll travel on this frame. Zero for
  /// TOP, for FIT, and for a hold too short to travel legibly.
  ///
  /// FROZEN, NOT RELEASED, once the page stops being shown. During the
  /// navigation and the close the outgoing capture must stay exactly where
  /// it was on its last drawn frame; snapping back to the top of the page
  /// on the frame a load bar appears is a jump at precisely the moment the
  /// eye is following something else. Same reasoning as the mosaic holding
  /// its pane motion at the end of the ramp through a page pan.
  double get browserScrollT {
    final b = _activeBrowser;
    if (b == null) return 0.0;
    if (phase == ScenePhase.browserShowing) {
      return b.scrollTAt(_phaseVisualFrames);
    }
    if (phase == ScenePhase.browserNavigating ||
        phase == ScenePhase.browserRestoring ||
        phase == ScenePhase.browserClosing) {
      // Evaluated at the end of the hold it just finished. scrollTAt clamps
      // past its travel, so asking for the whole hold gives the same answer
      // as the last frame actually drawn.
      return b.scrollTAt(b.currentHold);
    }
    return 0.0;
  }

  /// 0..1 through the load bar sweep, or 0 outside a navigation.
  double get browserLoadProgress =>
      phase == ScenePhase.browserNavigating ? phaseProgress : 0.0;

  int get browserPageIndex => _activeBrowser?.pageIndex ?? 0;
  int get browserPageCount => _activeBrowser?.pageCount ?? 0;

  // -------------------------------------------------------------------
  // Info-card painter accessors
  // -------------------------------------------------------------------

  bool get hasActiveCard => _activeCard != null;

  /// Title image for the card in flight, or null (missing image — the card
  /// still renders with the panel color running full height).
  ui.Image? get cardImage => _activeCard?.image;

  Color get cardPanelColor =>
      _activeCard?.panelColor ?? const Color.fromARGB(255, 30, 30, 38);

  String get cardHeading => _activeCard?.heading ?? '';
  String get cardBody => _activeCard?.body ?? '';

  /// 0..1 how far the card has slid ON screen. 0 = fully off the right edge,
  /// 1 = fully seated. Derived from the phase so scrubbing is exact.
  double get cardSlide {
    switch (phase) {
      case ScenePhase.cardOpening:
        return phaseProgress;
      case ScenePhase.cardShowing:
        return 1.0;
      case ScenePhase.cardClosing:
        return 1.0 - phaseProgress;
      default:
        return 0.0;
    }
  }

  // -------------------------------------------------------------------
  // Dossier painter accessors
  //
  // Per-field, the way every other presentation exposes itself. This used
  // to hand out the _ActiveDossier object whole, which made a private type
  // reachable through a public API: the painter could hold the object but
  // could not name its type, and every field on it was public surface by
  // accident rather than by decision.
  // -------------------------------------------------------------------

  bool get hasActiveDossier => _activeDossier != null;

  /// Gallery photos for the dossier in flight. Empty when none is up, so
  /// the painter can index without a null dance.
  List<ui.Image> get dossierImages => _activeDossier?.images ?? const [];

  /// Cover image at the top of the profile card, or null (missing image,
  /// and the card still renders with the panel color running full height).
  ui.Image? get dossierTitleImage => _activeDossier?.titleImage;

  Color get dossierPanelColor =>
      _activeDossier?.panelColor ?? const Color.fromARGB(255, 30, 30, 38);

  String get dossierHeading => _activeDossier?.heading ?? '';
  String get dossierBody => _activeDossier?.body ?? '';
  DossierCenterMode get dossierCenterMode =>
      _activeDossier?.centerMode ?? DossierCenterMode.grid;
  bool get dossierCenterIsMosaic =>
      dossierCenterMode == DossierCenterMode.mosaic;
  bool get dossierSideOnly =>
      dossierCenterMode == DossierCenterMode.sideOnly;

  /// Visual age used by the dossier thumbnail cascade. Showing phases read
  /// their live absolute phase age. Transition, pan, and close phases pin the
  /// completed hold so the outgoing thumbnails stay exactly where they were.
  int get dossierFramesIntoPhase {
    final d = _activeDossier;
    if (d == null) return 0;
    switch (phase) {
      case ScenePhase.dossierSplitShowing:
      case ScenePhase.dossierFullShowing:
        return _phaseVisualFrames;
      case ScenePhase.dossierTransitioning:
        return d.holdSplit;
      case ScenePhase.dossierMosaicPanning:
        return d.holdFull;
      case ScenePhase.dossierClosing:
        return d.centerMode == DossierCenterMode.sideOnly
            ? d.holdSplit
            : d.holdFull;
      default:
        return 0;
    }
  }

  int get dossierMosaicPageIndex => _activeDossier?.mosaicPageIndex ?? 0;

  List<Rect> dossierMosaicPageRects(int page) {
    final d = _activeDossier;
    if (d == null || page < 0 || page >= d.mosaicPages.length) return const [];
    return d.mosaicPages[page];
  }

  List<ui.Image> dossierMosaicPageImages(int page) {
    final d = _activeDossier;
    if (d == null || page < 0 || page >= d.mosaicPageImages.length) {
      return const [];
    }
    return d.mosaicPageImages[page];
  }

  double get dossierMosaicPanT {
    if (phase != ScenePhase.dossierMosaicPanning) return 0.0;
    return (_phaseVisualFrames / kAppPanFrames).clamp(0.0, 1.0);
  }

  /// 0..1 how far the dossier's info card has slid ON screen. Seated
  /// through the lead, gallery-opening, and split phases; slides out
  /// during the transition to full. Pure function of the phase.
  double get dossierCardSlide {
    switch (phase) {
      case ScenePhase.dossierOpening:
        return phaseProgress;
      case ScenePhase.dossierCardLead:
      case ScenePhase.dossierGalleryOpening:
      case ScenePhase.dossierSplitShowing:
        return 1.0;
      case ScenePhase.dossierTransitioning:
        return 1.0 - phaseProgress;
      case ScenePhase.dossierClosing:
        return dossierCenterMode == DossierCenterMode.sideOnly
            ? 1.0 - phaseProgress
            : 0.0;
      default:
        return 0.0;
    }
  }

  /// 0..1 open/close animation of the dossier's gallery window. With a
  /// scripted cardLead the gallery stays closed through dossierOpening and
  /// dossierCardLead, then opens in dossierGalleryOpening; with cardLead=0
  /// it opens during dossierOpening alongside the card (classic behavior).
  double get dossierGalleryOpenness {
    final d = _activeDossier;
    if (d == null) return 0.0;
    switch (phase) {
      case ScenePhase.dossierOpening:
        return d.cardLead > 0 ? 0.0 : phaseProgress;
      case ScenePhase.dossierCardLead:
        return 0.0;
      case ScenePhase.dossierGalleryOpening:
        return phaseProgress;
      case ScenePhase.dossierSplitShowing:
      case ScenePhase.dossierTransitioning:
      case ScenePhase.dossierFullShowing:
      case ScenePhase.dossierMosaicPanning:
        return 1.0;
      case ScenePhase.dossierClosing:
        return 1.0 - phaseProgress;
      default:
        return 0.0;
    }
  }

  // -------------------------------------------------------------------
  // Timeline painter accessors
  // -------------------------------------------------------------------

  bool get hasActiveTimeline => _activeTimeline != null;

  List<TimelineEvent> get timelineEvents =>
      _activeTimeline?.events ?? const [];

  Color get timelinePanelColor =>
      _activeTimeline?.panelColor ?? const Color.fromARGB(255, 30, 30, 38);

  String get timelineHeading => _activeTimeline?.heading ?? '';

  /// 0..1 progress of the spine drawing top-to-bottom. 0 outside the
  /// timelineShowing phase (during opening the panel is still sliding in;
  /// nothing has started drawing yet).
  double get timelineSpineProgress {
    final t = _activeTimeline;
    if (t == null) return 0.0;
    if (phase == ScenePhase.timelineClosing) return 1.0; // fully drawn on exit
    if (phase != ScenePhase.timelineShowing) return 0.0;
    return (_phaseVisualFrames / kTlSpineFrames).clamp(0.0, 1.0);
  }

  /// 0..1 reveal progress of event [i]. 0 outside timelineShowing, 1 during
  /// closing (events stay visible while the panel slides away).
  double timelineEventProgress(int i) {
    final t = _activeTimeline;
    if (t == null) return 0.0;
    if (phase == ScenePhase.timelineClosing) return 1.0;
    if (phase != ScenePhase.timelineShowing) return 0.0;
    final int start = kTlSpineFrames + i * kTlEventStagger;
    final int local = _phaseVisualFrames - start;
    if (local <= 0) return 0.0;
    if (local >= kTlEventFade) return 1.0;
    return local / kTlEventFade;
  }

  /// 0..1 how far the timeline panel has slid ON screen. Same contract as
  /// cardSlide, derived from the phase so scrubbing is exact.
  double get timelineSlide {
    switch (phase) {
      case ScenePhase.timelineOpening:
        return phaseProgress;
      case ScenePhase.timelineShowing:
        return 1.0;
      case ScenePhase.timelineClosing:
        return 1.0 - phaseProgress;
      default:
        return 0.0;
    }
  }

  // -------------------------------------------------------------------
  // Center-stage (contact-sheet sidecar) painter accessors
  // -------------------------------------------------------------------

  /// True when the active timeline carries a stage (at least one photo
  /// paired with an event).
  bool get hasTimelineStage =>
      (_activeTimeline?.stagePairCount ?? 0) > 0;

  /// The stage photos, in pairing order. Empty when no stage.
  List<ui.Image> get timelineStagePhotos =>
      _activeTimeline?.stagePhotos ?? const [];

  /// Number of photo<->event pairs that animate. Photos beyond this count
  /// (folder bigger than the event list) render but never activate.
  int get timelineStagePairCount => _activeTimeline?.stagePairCount ?? 0;

  /// Scripted thumbnail width in logical px @ 1080p, or null for the
  /// painter's default. From the [TIMELINE] tag's sixth segment.
  int? get timelineStageThumbW => _activeTimeline?.stageThumbW;

  /// Scripted gap between thumbnails in logical px @ 1080p, or null for default.
  int? get timelineStageGap => _activeTimeline?.stageGap;

  /// Whether the background dimming effect is active.
  bool get timelineFocusMode => _activeTimeline?.focusMode ?? false;

  /// Connector-line tip parameter in "segments travelled". 0 outside
  /// timelineShowing; parked at the last paired photo during closing so the
  /// line doesn't retract while the panel slides away.
  double get timelineStageLineT {
    final t = _activeTimeline;
    if (t == null || t.stagePairCount == 0) return 0.0;
    if (phase == ScenePhase.timelineClosing) return t.stagePairCount.toDouble();
    if (phase != ScenePhase.timelineShowing) return 0.0;

    final int n = t.stagePairCount;
    final int f = _phaseVisualFrames;
    if (f <= 0) return 0.0;
    if (f < kTlSpineFrames) return f / kTlSpineFrames;

    final int past = f - kTlSpineFrames;
    final int seg = past ~/ kTlEventStagger;
    if (seg >= n - 1) return n.toDouble();
    final double frac = (past % kTlEventStagger) / kTlEventStagger;
    return 1.0 + seg + frac;
  }

  /// 0..1 border-activation progress of stage photo [i]. Pinned to the
  /// same clock as the paired event's spine reveal — the line's arrival
  /// frame IS the activation frame — so photo and event pop together by
  /// construction. Unpaired photos (i >= pairCount) never activate.
  double timelineStagePhotoProgress(int i) {
    final t = _activeTimeline;
    if (t == null) return 0.0;
    if (i >= t.stagePairCount) return 0.0;
    if (phase == ScenePhase.timelineClosing) return 1.0;
    if (phase != ScenePhase.timelineShowing) return 0.0;
    return timelineEventProgress(i);
  }

  /// Preloaded, decoded images keyed by folder name. Gallery, video, app,
  /// and timeline-stage folders all live here — the payload is the same
  /// (an ordered image list), only the playback machinery differs.
  final Map<String, List<ui.Image>> _galleryCache = {};

  /// Captions for the images in [_galleryCache], same folder key and the
  /// SAME INDEX. Always exactly as long as its image list.
  ///
  /// Built inside the decode loop rather than looked up afterwards by
  /// filename, because a folder whose third file fails to decode produces
  /// an image list shorter than its name list. Resolving captions later
  /// against the surviving images would put every caption after the
  /// failure on the wrong photograph, and a mislabelled archival photo is
  /// a worse defect than a missing one: it is wrong rather than absent,
  /// and nothing on screen says so.
  final Map<String, List<ImageCaption>> _captionCache = {};

  /// Preloaded card title images keyed by image filename (relative to
  /// images/). Separate from _galleryCache because these are single files,
  /// not folders.
  final Map<String, ui.Image> _cardImageCache = {};

  /// Load failures recorded during setup (missing folders, bad images).
  final List<String> warnings = [];

  bool get isFinished =>
      terminal.isFinished && phase == ScenePhase.terminal;

  double get width => terminal.width;
  double get height => terminal.height;

  // -------------------------------------------------------------------
  // Setup
  // -------------------------------------------------------------------

  /// Async because all images (wallpaper + every gallery folder referenced
  /// by the script) are fully decoded here, up front. After setup returns,
  /// tick() and the painter never block on IO or decoding.
  ///
  /// [imagesDir] is the absolute path of the project's images/ folder.
  /// [desktopWallpaper] is the value of [CONFIG:DESKTOP:...], or null.
  /// [windowTitle] is the value of [CONFIG:WINTITLE:...], or null for default.
  Future<void> setup({
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
    required String imagesDir,
    required String spritesDir,
    String? desktopWallpaper,
    String? windowTitle,
    /// Raw value of [CONFIG:PANELIFE:...], or null. Parsed here rather
    /// than by the caller so preview, bake, and the editor cannot
    /// interpret it differently.
    String? paneLifeConfig,
    String? captionConfig,
    String? appSwitchConfig,
    bool withPreroll = false,
    Color? prerollBgColor,
    /// True when the bake wants a real alpha channel.
    ///
    /// Model: the terminal is a solid object and alpha describes only what
    /// is NOT terminal. The terminal keeps its own background color always,
    /// and the backdrop behind it (preroll chroma plate, letterbox fill)
    /// paints nothing instead. During the preroll reveal the transparent
    /// region shrinks as the window grows, so the terminal materializes over
    /// whatever it is composited onto.
    ///
    /// This is an explicit flag rather than something inferred from a
    /// transparent bgColor. Inferring it was the earlier approach and it
    /// knocked out the terminal's own background too, which made the parked
    /// preroll window solid while the fullscreen terminal was see-through:
    /// the two halves of the same reveal disagreed.
    ///
    /// Consequence worth knowing: a fullscreen script with no preroll has
    /// nothing outside the terminal, so it exports fully opaque. That is
    /// correct under this model, not a bug.
    bool transparentBackdrop = false,
    /// Background audio bed length in frames, 0 when none. Forwarded
    /// verbatim to the terminal engine and used for nothing else here: the
    /// scene layer has no opinion about audio, it just carries the integer.
    int bedTargetFrames = 0,
  }) async {
    final Stopwatch _sw = Stopwatch()..start();
    final Stopwatch _total = Stopwatch()..start();

    disposeImages();
    warnings.clear();
    paneLife = PaneLifeConfig.parse(paneLifeConfig);
    captionStyle = CaptionConfig.parse(captionConfig);
    appSwitch = parseAppSwitchMode(appSwitchConfig);
    _profile(_sw, 'disposeImages', -1);

    // NOTE: linting does not belong here. By the time a script reaches
    // setup it has been through injectMacros, which deletes DEF_MENU
    // blocks and MACRO_CFG lines and expands CALL into several lines. Any
    // line number computed from this text is off by however much the
    // macros moved, and points the author at the wrong place.
    //
    // The editor lints the raw buffer instead, where line numbers mean
    // what the gutter says they mean.

    _configWithPreroll = withPreroll;
    prerollColor = prerollBgColor ?? const Color(0xFF00FF00);
    this.transparentBackdrop = transparentBackdrop;

    // Config, not state: assigned before terminal.setup() and left alone by
    // every reset() from here on, same as the template text itself.
    terminal.bedTargetFrames = bedTargetFrames;

    terminalWindowTitle =
        (windowTitle != null && windowTitle.trim().isNotEmpty)
            ? windowTitle.trim()
            : kDefaultTerminalTitle;

    terminal.setup(
      templateText: templateText,
      fontColor: fontColor,
      bgColor: bgColor,
      width: width,
      height: height,
      scale: scale,
      fontPath: fontPath,
      fontSize: fontSize,
      lineSpacing: lineSpacing,
      tracking: tracking,
      marginTop: marginTop,
      marginSide: marginSide,
    );
    _profile(_sw, 'terminal.setup (text layout + preprocess)', -1);

    // Wallpaper
    if (desktopWallpaper != null && desktopWallpaper.trim().isNotEmpty) {
      final img = await _loadImage('$imagesDir/${desktopWallpaper.trim()}');
      if (img != null) {
        wallpaper = img;
      } else {
        warnings.add('Wallpaper not found: $desktopWallpaper');
      }
      _profile(_sw, 'wallpaper decode', -1);
    }

    // Scan the preprocessed script for every GALLERY, VIDEO, APP, DOSSIER, and
    // TIMELINE-stage folder (plus every CARD title image, SPRITE file, SVG
    // file, SVGFLASH folder, and IMG tile) and preload it. The
    // image-folder-based tags share the same folder-of-images payload and
    // live in the same cache; card images are single files with their own
    // cache; SVGs are parsed into vector stencils and handed to the
    // TerminalEngine, exactly like sprites; IMG tiles are thresholded into
    // raster stencils and handed over the same way. Stage-less TIMELINE
    // blocks are pure text — nothing to preload.
    final Set<String> folders = {};
    final Set<String> spritePaths = {};
    final Set<String> cardImages = {};
    final Set<String> svgFiles = {};
    final Set<String> svgFolders = {};

    /// Keys: "$channel:$file", Values: Max allowed dimension (512 or 1024)
    final Map<String, int> imgRefCaps = {}; 

    for (final match in tagRegex.allMatches(terminal.templateText)) {
      final galFolder = match.namedGroup('galFolder');
      final vidFolder = match.namedGroup('vidFolder');
      final appFolder = match.namedGroup('appFolder');
      final browFolder = match.namedGroup('browFolder');
      final dosFolder = match.namedGroup('dosFolder');
      final dosImg = match.namedGroup('dosImg');
      final tlStage = match.namedGroup('tlStage');
      final cardImg = match.namedGroup('cardImg');
      final sp = match.namedGroup('spritePath');
      final svgFile = match.namedGroup('svgFile');
      final svgfFolder = match.namedGroup('svgfFolder');
      final imgFile = match.namedGroup('imgFile');
      final photoFile = match.namedGroup('photoFile');

      if (galFolder != null) folders.add(galFolder);
      if (vidFolder != null) folders.add(vidFolder);
      if (appFolder != null) folders.add(appFolder);
      if (browFolder != null) folders.add(browFolder);
      if (dosFolder != null) folders.add(dosFolder);
      if (dosImg != null) cardImages.add(dosImg); // Dossier uses the same card cache!
      if (tlStage != null) folders.add(tlStage);
      if (cardImg != null) cardImages.add(cardImg);
      if (sp != null) spritePaths.add(sp);
      if (svgFile != null) svgFiles.add(svgFile);
      if (svgfFolder != null) svgFolders.add(svgfFolder);
      
      if (imgFile != null) {
        final key = '${match.namedGroup('imgChannel') ?? 'R'}:$imgFile';
        imgRefCaps[key] = math.max(imgRefCaps[key] ?? 0, kImgMaxDimension);
      }
      if (photoFile != null) {
        final key = '${match.namedGroup('photoChannel') ?? 'R'}:$photoFile';
        imgRefCaps[key] = math.max(imgRefCaps[key] ?? 0, kPhotoMaxDimension);
      }
    }

    _profile(_sw, 'tag scan', -1);

    int _folderImageCount = 0;
    for (final folder in folders) {
      final dir = Directory('$imagesDir/$folder');
      if (!dir.existsSync()) {
        warnings.add('Folder not found: images/$folder');
        _galleryCache[folder] = [];
        _captionCache[folder] = const [];
        continue;
      }

      // Authored order if the folder has a .r3nder_order manifest, plain
      // filename order if it does not. Either way it is a pure function of
      // what is on disk, so a dry run and an export still agree.
      final Iterable<String> onDisk = dir
          .listSync()
          .whereType<File>()
          .map((f) => f.path.split(Platform.pathSeparator).last)
          .where((n) {
            final p = n.toLowerCase();
            return p.endsWith('.png') ||
                p.endsWith('.jpg') ||
                p.endsWith('.jpeg') ||
                p.endsWith('.webp') ||
                p.endsWith('.bmp');
          });
      final List<String> names = orderedFolderNames(dir.path, onDisk);

      // Read once per folder, not once per image. The sidecar is keyed by
      // filename; alignment to the surviving image list happens below.
      final Map<String, ImageCaption> captions =
          readFolderCaptions(dir.path);

      // CONCURRENT, NOT SERIAL. Awaiting each decode in turn made the
      // whole folder cost the SUM of its images: eight plates measured at
      // 660ms this way, and that is the wait before the editor or a
      // preview can show anything. instantiateImageCodec releases the
      // isolate while it works, so issuing them together overlaps the file
      // reads and the codec work instead of queueing them.
      //
      // ORDER IS UNAFFECTED, which is the part that matters here. Future
      // .wait returns results positionally, in the order the futures were
      // created, not the order they completed. The sequence still comes
      // from orderedFolderNames, so a dry run and an export still agree
      // and the gallery still plays in authored order.
      final List<ui.Image?> decoded = await Future.wait(
        names.map((name) =>
            _loadImage('${dir.path}${Platform.pathSeparator}$name')),
      );

      final List<ui.Image> images = [];
      final List<ImageCaption> imageCaptions = [];
      for (int i = 0; i < decoded.length; i++) {
        final ui.Image? img = decoded[i];
        if (img != null) {
          images.add(img);
          // Appended in the same branch as the image, so the two lists
          // cannot drift. A skipped decode drops its caption with it
          // rather than shifting it onto the next photograph.
          imageCaptions.add(captions[names[i]] ?? ImageCaption.none);
        } else {
          warnings.add(
              'Failed to decode: ${dir.path}${Platform.pathSeparator}${names[i]}');
        }
      }
      if (images.isEmpty) {
        warnings.add('Folder empty: images/$folder');
      }
      _folderImageCount += images.length;
      _galleryCache[folder] = images;
      _captionCache[folder] = imageCaptions;
    }

    _profile(_sw, 'FOLDER IMAGE DECODE (concurrent)', _folderImageCount);

    // Preload card title images (single files inside images/).
    // Concurrent for the same reason as the folders above.
    final List<String> cardList = cardImages.toList();
    final List<ui.Image?> cardDecoded = await Future.wait(
      cardList.map((imgPath) => _loadImage('$imagesDir/$imgPath')),
    );
    for (int i = 0; i < cardList.length; i++) {
      final ui.Image? img = cardDecoded[i];
      if (img != null) {
        _cardImageCache[cardList[i]] = img;
      } else {
        warnings.add('Card image not found: images/${cardList[i]}');
      }
    }

    _profile(_sw, 'card image decode', cardList.length);

    // ---------------------------------------------------------------
    // Preload & parse SVG stencils (files and SVGFLASH folders).
    //
    // Library keys are paths relative to images/ — a folder's files get
    // keys like "bootlogos/logo_a.svg", so a file referenced both directly
    // and through its folder parses exactly once. Everything is parsed
    // here, up front: the TerminalEngine and painter never touch IO.
    // ---------------------------------------------------------------
    final Map<String, SvgDocument> loadedSvgs = {};
    final Map<String, List<String>> loadedSvgFolders = {};

    SvgDocument? parseSvgFile(String absolutePath, String key) {
      try {
        final file = File(absolutePath);
        if (!file.existsSync()) return null;
        return SvgParser.parse(file.readAsStringSync());
      } catch (_) {
        return null;
      }
    }

    // Direct [SVG:file] references.
    for (final key in svgFiles) {
      final doc = parseSvgFile('$imagesDir/$key', key);
      if (doc != null) {
        loadedSvgs[key] = doc;
      } else {
        warnings.add('SVG not found or unparsable: images/$key');
      }
    }

    // [SVGFLASH:folder] references: every .svg in the folder, sorted by
    // filename for a deterministic flicker order.
    for (final folder in svgFolders) {
      final dir = Directory('$imagesDir/$folder');
      if (!dir.existsSync()) {
        warnings.add('SVG folder not found: images/$folder');
        loadedSvgFolders[folder] = [];
        continue;
      }

      // Same manifest as image folders. A flicker sequence is an authored
      // order too, and having one folder kind honour .r3nder_order while
      // another ignored it would be the sort of inconsistency nobody
      // remembers the rule for.
      final Iterable<String> onDiskSvg = dir
          .listSync()
          .whereType<File>()
          .map((f) => f.path.split(Platform.pathSeparator).last)
          .where((n) => n.toLowerCase().endsWith('.svg'));
      final List<String> svgNames = orderedFolderNames(dir.path, onDiskSvg);

      final List<String> keys = [];
      for (final name in svgNames) {
        final String key = '$folder/$name';
        if (!loadedSvgs.containsKey(key)) {
          final String path = '${dir.path}${Platform.pathSeparator}$name';
          final doc = parseSvgFile(path, key);
          if (doc != null) {
            loadedSvgs[key] = doc;
          } else {
            warnings.add('SVG unparsable: images/$key');
            continue;
          }
        }
        keys.add(key);
      }
      if (keys.isEmpty) {
        warnings.add('SVG folder empty: images/$folder');
      }
      loadedSvgFolders[folder] = keys;
    }

    terminal.setSvgLibrary(loadedSvgs, loadedSvgFolders);

    _profile(_sw, 'SVG parse', loadedSvgs.length);

    // ---------------------------------------------------------------
    // Preload & threshold [IMG] and [PHOTO] raster stencils.
    //
    // Programmed Symbols emulation: decode the file ONCE, read the raw
    // RGBA pixels ONCE, hard-threshold the scripted channel (>= 128 = on),
    // merge each row's horizontal runs of on-pixels into single rects
    // inside one Path, then discard the decoded image. Off pixels don't
    // exist in the path — nothing is ever drawn there. The painter stamps
    // the whole tile with one drawPath per copy: no per-frame pixel reads,
    // no sampling, no filtering. Hard pixel edges by construction.
    //
    // Library keys are "<channel>:<file>" — the same file masked through
    // R and through G is two different stencils.
    // ---------------------------------------------------------------
    final Map<String, ImgStencil> loadedImgs = {};

    for (final entry in imgRefCaps.entries) {
      final String key = entry.key;
      final int maxDim = entry.value;
      if (loadedImgs.containsKey(key)) continue;

      final parts = key.split(':');
      final String channel = parts[0];
      final String file = parts.sublist(1).join(':');
      final String path = '$imagesDir/$file';

      // Cached by file contents AND by the parameters that shape the
      // result. Channel picks which colour plane is thresholded and maxDim
      // decides whether the tile is rejected outright, so the same file
      // under a different channel is a different stencil.
      //
      // This is the expensive one. A 1024x1024 [PHOTO] is a million pixel
      // tests and thousands of addRect calls, and the trace showed it
      // costing up to 789ms for two tiles. Rebuilding that on every
      // keystroke pause was most of the stall while typing.
      final String stencilKey = '${_fileKey(path)}|$channel|$maxDim';
      final ImgStencil? cachedStencil = _touchStencil(stencilKey);
      if (cachedStencil != null) {
        loadedImgs[key] = cachedStencil;
        continue;
      }

      final ui.Image? img = await _loadImage(path);
      if (img == null) {
        warnings.add('Raster tile not found or undecodable: images/$file');
        continue;
      }

      if (img.width > maxDim || img.height > maxDim) {
        warnings.add(
            'Raster tile too large (${img.width}x${img.height}, max '
            '$maxDim): images/$file — use high-contrast/coarse-dither, '
            'not fine dithering, to prevent path explosion.');
        // Our clone, so ours to release. The cache keeps the original, and
        // a [GALLERY] referencing the same file is untouched by this.
        img.dispose();
        continue;
      }

      final ImgStencil? stencil = await _buildImgStencil(img, channel);
      if (kProfileSetup) {
        diag('setup', '  stencil BUILT $key ${img.width}x${img.height}');
      }
      if (stencil != null) {
        _stencilCache[stencilKey] = stencil;
        _evictStencils();
      }

      // Pixels served their purpose; only geometry survives into the
      // engine. Releasing this clone does not evict the cached original,
      // so a re-setup still skips the decode.
      img.dispose();

      if (stencil != null) {
        loadedImgs[key] = stencil;
      } else {
        warnings.add('Raster pixel read failed: images/$file');
      }
    }

    terminal.setImgLibrary(loadedImgs);

    _profile(_sw, 'IMG/PHOTO stencil build (decode + threshold)',
        loadedImgs.length);

    // Preload Sprites
    final Map<String, List<List<String>>> loadedSprites = {};
    for (final path in spritePaths) {
      final file = File('$spritesDir/$path');
      if (!file.existsSync()) {
        warnings.add('Sprite not found: sprites/$path');
        continue;
      }
      
      final content = file.readAsStringSync();
      // Split by [FRAME] on its own line
      final rawFrames = content.split(RegExp(r'\n?\[FRAME\]\n?'));
      
      List<List<String>> processedFrames = [];
      int? expectedLines;
      bool issuedShapeWarning = false;

      for (final rawFrame in rawFrames) {
        if (rawFrame.trim().isEmpty) continue; // Skip trailing empties
        
        List<String> lines = rawFrame.split('\n');
        
        // Validation: padding/truncation
        if (expectedLines == null) {
          expectedLines = lines.length;
        } else {
          if (lines.length != expectedLines) {
            if (!issuedShapeWarning) {
               warnings.add('Shape mismatch in sprite $path. Frames must have identical line counts. Padded/Truncated to fit.');
               issuedShapeWarning = true;
            }
            if (lines.length > expectedLines) {
              lines = lines.sublist(0, expectedLines);
            } else if (lines.length < expectedLines) {
              final diff = expectedLines - lines.length;
              lines.addAll(List.filled(diff, ""));
            }
          }
        }
        processedFrames.add(lines);
      }

      if (processedFrames.isEmpty) {
        warnings.add('Sprite empty: sprites/$path');
      } else {
        loadedSprites[path] = processedFrames;
      }
    }
    
    terminal.setSpriteLibrary(loadedSprites);

    _profile(_sw, 'sprite load', loadedSprites.length);

    reset();

    if (kProfileSetup) {
      diag('setup', '===== TOTAL ${_total.elapsedMilliseconds}ms =====');
    }
  }

  // -------------------------------------------------------------------
  // DECODED ASSET CACHE
  //
  // setup() runs far more often than the assets change. Opening the
  // editor runs it, the dashboard warm-up runs it, preview and bake run
  // it, and every 250ms debounce while you TYPE runs it. Each of those
  // was decoding the entire library from scratch: measured at 400ms to
  // 1000ms on an eight-plate script, paid again on every pause in your
  // typing.
  //
  // Keyed on path plus modification time plus size, so replacing a file
  // on disk invalidates its entry without anyone having to remember to
  // say so. Editing the script does not touch the key at all, which is
  // the case that matters.
  //
  // STATIC ON PURPOSE. The warm-up builds its own SceneEngine, and
  // preview and bake use main's; sharing the cache means the decode the
  // warm already paid for is not paid again when you hit Preview.
  //
  // OWNERSHIP, VIA CLONES. The cache holds the original ui.Image and
  // hands out clone() handles. Flutter reference-counts these: disposing
  // the original does NOT invalidate outstanding clones, and the pixels
  // are freed only when the original and every clone have been disposed.
  //
  // That is what makes eviction safe. Without it, dropping an entry while
  // a warm engine, a preview engine, and the editor all held the same
  // image would tear a live texture out from under two of them, and the
  // blank gallery would show up somewhere unrelated to the cause. With
  // it, each engine owns its own handle and disposes it in
  // disposeImages() exactly as it always did.
  //
  // Insertion-ordered, which Dart's default Map is, so the first key is
  // the least recently used once _touch() re-inserts on every hit.
  static final Map<String, ui.Image> _imageCache = {};
  static final Map<String, ImgStencil> _stencilCache = {};

  /// Stencils held before the least recently used are dropped.
  ///
  /// Counted rather than measured. A stencil is a Path built from thousands
  /// of merged rects, and Path exposes no size, so any byte figure would be
  /// a guess dressed as a number. A count cap is honest and still bounded,
  /// which is the property that was missing: this cache used to be cleared
  /// only on a workspace switch, so a long session across many [IMG] and
  /// [PHOTO] references grew it without limit while the image cache beside
  /// it was carefully evicting. That asymmetry was mine and this closes it.
  ///
  /// Sized so a large script keeps its whole working set. Rebuilding one
  /// costs a decode plus a per-pixel threshold pass, measured at up to
  /// 789ms for two tiles, so evicting too eagerly is far worse than holding
  /// a few extra Paths.
  static const int kStencilCacheMaxEntries = 96;

  /// Moves [key] to the most-recently-used end, mirroring _touch for
  /// images so the two caches age by the same rule.
  static ImgStencil? _touchStencil(String key) {
    final ImgStencil? s = _stencilCache.remove(key);
    if (s != null) _stencilCache[key] = s;
    return s;
  }

  static void _evictStencils() {
    while (_stencilCache.length > kStencilCacheMaxEntries) {
      // Geometry only, no native handle, so dropping the reference is the
      // whole of the release. Nothing to dispose and nobody to invalidate:
      // engines hold their own references and keep them alive.
      _stencilCache.remove(_stencilCache.keys.first);
    }
  }

  /// Rough resident cost of [_imageCache], four bytes per pixel.
  static int _imageCacheBytes = 0;

  /// Eviction threshold. Generous, because the whole point is to survive
  /// a working session on one script, and small enough that a workspace
  /// full of 4K plates cannot grow without bound.
  static const int kImageCacheBudgetBytes = 192 * 1024 * 1024;

  static int _bytesOf(ui.Image img) => img.width * img.height * 4;

  /// Moves [key] to the most-recently-used end.
  static ui.Image? _touch(String key) {
    final ui.Image? img = _imageCache.remove(key);
    if (img != null) _imageCache[key] = img;
    return img;
  }

  /// Drops least-recently-used originals until the budget is met.
  ///
  /// Disposes as it goes, which is only safe because consumers hold
  /// clones: their handles stay valid and the pixels survive until the
  /// last one is disposed. One entry is always kept, so a single image
  /// larger than the whole budget still works rather than thrashing.
  static void _evictToBudget() {
    while (_imageCacheBytes > kImageCacheBudgetBytes &&
        _imageCache.length > 1) {
      final String oldest = _imageCache.keys.first;
      final ui.Image img = _imageCache.remove(oldest)!;
      _imageCacheBytes -= _bytesOf(img);
      img.dispose();
      // Stencils built from it are geometry, not pixels, and cheap to
      // hold. They key on the same file identity, so they stay valid.
    }
  }

  /// Identity of a file's CONTENTS: path, mtime, size. Missing files get a
  /// stable sentinel so a repeated miss does not thrash the cache.
  static String _fileKey(String path) {
    try {
      final FileStat st = File(path).statSync();
      if (st.type == FileSystemEntityType.notFound) return '$path|absent';
      return '$path|${st.modified.microsecondsSinceEpoch}|${st.size}';
    } catch (_) {
      return '$path|unstattable';
    }
  }

  /// Frees every cached image and stencil.
  ///
  /// Call on workspace switch, where the entire library is being replaced
  /// and holding the old one is pure waste. NOT called between setups:
  /// that is the whole point.
  static void clearAssetCache() {
    for (final img in _imageCache.values) {
      img.dispose();
    }
    _imageCache.clear();
    _imageCacheBytes = 0;
    _stencilCache.clear();
  }

  /// Decodes [path], or returns a clone of the cached decode.
  ///
  /// ALWAYS RETURNS A CLONE THE CALLER MUST DISPOSE. The cache keeps the
  /// original; every consumer gets its own handle. disposeImages() and
  /// the stencil builder dispose theirs, which is why they can do so
  /// freely without any regard for who else is using the same file.
  Future<ui.Image?> _loadImage(String path) async {
    final String key = _fileKey(path);

    final ui.Image? hit = _touch(key);
    if (hit != null) return hit.clone();

    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();

      // Two concurrent decodes of the same path can both land here, since
      // the folder loop issues them together. Keep whichever arrived
      // first and discard this one, or the cache would silently overwrite
      // an entry that other clones are counting against.
      final ui.Image? raced = _touch(key);
      if (raced != null) {
        frame.image.dispose();
        return raced.clone();
      }

      _imageCache[key] = frame.image;
      _imageCacheBytes += _bytesOf(frame.image);
      _evictToBudget();

      return frame.image.clone();
    } catch (_) {
      return null;
    }
  }

  /// Thresholds one channel of [img] into an ImgStencil: reads the raw RGBA
  /// pixels once, treats channel value >= 128 as ON, and merges each row's
  /// horizontal runs of on-pixels into single 1px-tall rects inside one
  /// Path (pixel coordinates, 0,0 = top-left).
  ///
  /// Run-merging matters: a solid 64px-wide stripe becomes ONE rect, not
  /// 64 — typical tiles compile to a few hundred rects at most, stamped
  /// with a single drawPath call at draw time.
  ///
  /// Returns null only if the pixel readback itself fails.
  static Future<ImgStencil?> _buildImgStencil(
      ui.Image img, String channel) async {
    final ByteData? data =
        await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;

    // rawRgba: 4 bytes per pixel, R at offset 0, G at 1, B at 2.
    final int chOffset = channel == 'G' ? 1 : (channel == 'B' ? 2 : 0);
    final Uint8List px = data.buffer.asUint8List(
        data.offsetInBytes, data.lengthInBytes);

    final int w = img.width;
    final int h = img.height;
    final Path path = Path();

    for (int y = 0; y < h; y++) {
      final int rowBase = y * w * 4;
      int runStart = -1; // -1 = not inside a run

      for (int x = 0; x < w; x++) {
        final bool on = px[rowBase + x * 4 + chOffset] >= 128;

        if (on && runStart < 0) {
          runStart = x; // Run opens.
        } else if (!on && runStart >= 0) {
          // Run closes: emit [runStart, x).
          path.addRect(Rect.fromLTWH(
              runStart.toDouble(), y.toDouble(),
              (x - runStart).toDouble(), 1.0));
          runStart = -1;
        }
      }
      // Run still open at the row's right edge.
      if (runStart >= 0) {
        path.addRect(Rect.fromLTWH(
            runStart.toDouble(), y.toDouble(),
            (w - runStart).toDouble(), 1.0));
      }
    }

    return ImgStencil(pxWidth: w, pxHeight: h, path: path);
  }

  /// Frees all decoded images. Call before a new setup() or on teardown.
  /// NOT called by reset() — images persist across resets so scrubbing
  /// backward (reset + replay) never re-decodes anything.
  ///
  /// SVG stencils and IMG stencils are plain Path geometry (no GPU-side
  /// resources), so they need no disposal — the next setup() simply
  /// replaces the libraries.
  /// Releases this engine's image handles.
  ///
  /// Disposes, as it always did, but what it disposes are now this
  /// engine's own clones rather than shared originals. Another engine
  /// holding the same file is unaffected, and the pixels survive until
  /// the cache drops the original too.
  void disposeImages() {
    wallpaper?.dispose();
    wallpaper = null;
    for (final list in _galleryCache.values) {
      for (final img in list) {
        img.dispose();
      }
    }
    _galleryCache.clear();
    // Plain data, nothing to dispose, but it must not outlive the image
    // list it is index-aligned to.
    _captionCache.clear();
    for (final img in _cardImageCache.values) {
      img.dispose();
    }
    _cardImageCache.clear();
  }

  // -------------------------------------------------------------------
  // App grid layout
  // -------------------------------------------------------------------

  /// Picks (cols, rows) for a tile count. Matches the microsoft-phone-tile
  /// feel — the grid re-flows so tiles stay proportional instead of leaving
  /// empty cells.
  ///
  /// 1 -> 1x1, 2 -> 1x2, 3 -> 1x3, 4 -> 2x2, 5..6 -> 2x3, 7..9 -> 3x3.
  static ({int cols, int rows}) _pickAppGrid(int n) {
    if (n <= 1) return (cols: 1, rows: 1);
    if (n == 2) return (cols: 2, rows: 1);
    if (n == 3) return (cols: 3, rows: 1);
    if (n == 4) return (cols: 2, rows: 2);
    if (n <= 6) return (cols: 3, rows: 2);
    return (cols: 3, rows: 3);
  }

  /// Builds the MOSAIC panel pages, in unit space. Returns empty for GRID,
  /// which stays on the painter's original tile arithmetic.
  /// [plan] is the authored panes-per-page list from the tag, or empty to
  /// chunk at [kAppMosaicPerPage] throughout, which is what every existing
  /// script gets.
  ///
  /// The plan is advisory in both directions, on purpose:
  ///
  ///  * SHORT. Once the plan is exhausted the remainder keeps chunking at
  ///    the default, so `1,3` over seven panes plays 1,3,3. Adding a pane
  ///    and forgetting to update the plan degrades rather than drops, which
  ///    is the same contract every other asset mismatch in R3nder has.
  ///  * LONG. Pages past the supply never happen, so `1,3,2` over four
  ///    panes plays 1,3. A page of nothing is not a page, and it would
  ///    otherwise show as a hold on an empty window.
  ///
  /// A page is also clamped to [kAppMosaicPerPage], because the composition
  /// is only defined for one, two, or three panels. Asking for 5 gets 3.
  static List<List<Rect>> _buildMosaicPages(int n, List<int> plan) {
    if (n <= 0) return const [];

    final List<int> sizes =
        resolvePagePlan(n, plan, perPage: kAppMosaicPerPage);

    final List<List<Rect>> pages = [];
    for (int i = 0; i < sizes.length; i++) {
      pages.add(_mosaicPage(sizes[i], i));
    }
    return pages;
  }

  /// One page of the Metro mosaic, built by recursive halving: a hero panel
  /// running full height down one side, and the remaining panels stacked
  /// beside it.
  ///
  /// The hero alternates sides on odd pages. That is what keeps a multi-page
  /// sequence from reading as the same slide three times, and because it keys
  /// off the page index it stays deterministic across preview and bake.
  static List<Rect> _mosaicPage(int count, int pageIndex) {
    const double h = kAppMosaicHeroFrac;

    List<Rect> rects;
    if (count <= 1) {
      rects = [const Rect.fromLTRB(0, 0, 1, 1)];
    } else if (count == 2) {
      rects = [
        const Rect.fromLTRB(0, 0, h, 1),
        const Rect.fromLTRB(h, 0, 1, 1),
      ];
    } else {
      // Three: hero plus a stacked pair. Pages are chunked to
      // kAppMosaicPerPage, so this is the case that actually runs.
      rects = [
        const Rect.fromLTRB(0, 0, h, 1),
        const Rect.fromLTRB(h, 0, 1, 0.5),
        const Rect.fromLTRB(h, 0.5, 1, 1),
      ];
    }

    if (pageIndex.isOdd) {
      // Mirror horizontally. Panel order is preserved, so the hero still
      // leads the cascade; it just now leads from the right.
      rects = rects
          .map((r) =>
              Rect.fromLTRB(1.0 - r.right, r.top, 1.0 - r.left, r.bottom))
          .toList();
    }

    return rects;
  }

  /// Slices [images] to match [pages], so index i of a page's rect list and
  /// its image list refer to the same panel.
  static List<List<ui.Image>> _sliceAppPages(
      List<ui.Image> images, List<List<Rect>> pages) {
    final List<List<ui.Image>> out = [];
    int at = 0;
    for (final page in pages) {
      final int end =
          (at + page.length) > images.length ? images.length : at + page.length;
      out.add(images.sublist(at, end));
      at = end;
    }
    return out;
  }

  /// Turns the ordered source images into authored visual panes. With no
  /// pane plan this deliberately produces one image per pane, preserving the
  /// legacy MOSAIC model exactly.
  static List<_MosaicPane> _buildMosaicPanes(
      List<ui.Image> images, List<AppPaneSpec> plan,
      {List<ImageCaption> captions = const [],
      List<String>? warnings,
      String folder = ''}) {
    // Silent clipping is the failure this reports. Every image lands in
    // exactly one pane, so a plan asking for more images than the folder
    // holds loses its later panes, and any @HERO authored on them goes
    // with them. The author sees a star in the contact sheet that does
    // nothing and no reason why.
    if (warnings != null && plan.isNotEmpty) {
      int declared = 0;
      for (final AppPaneSpec p in plan) {
        declared += p.imageCount < 1 ? 1 : p.imageCount;
      }
      if (declared > images.length) {
        warnings.add(
            'Pane plan for "$folder" consumes $declared images but the '
            'folder holds ${images.length}. The panes past the end are '
            'dropped, along with any hero selected on them.');
      } else if (declared < images.length) {
        // Under-run is benign and deliberate: the remainder degrades to
        // one-image unselected panes so adding an asset never silently
        // opts it into motion. Worth saying once, because it is also how
        // a star ends up on a pane the author did not mean.
        warnings.add(
            'Pane plan for "$folder" covers $declared of '
            '${images.length} images; the remaining '
            '${images.length - declared} become single static panes.');
      }
    }

    final List<AppPaneSpec> resolved =
        resolveAppPanePlan(images.length, plan);
    final List<_MosaicPane> out = [];
    int at = 0;
    for (final AppPaneSpec spec in resolved) {
      if (at >= images.length) break;
      final int end = math.min(images.length, at + spec.imageCount);
      final List<ui.Image> paneImages = images.sublist(at, end);
      if (paneImages.isNotEmpty) {
        out.add(_MosaicPane(
          images: paneImages,
          heroIndex: spec.heroIndex == null
              ? null
              : spec.heroIndex!.clamp(0, paneImages.length - 1).toInt(),
          direction: spec.direction,
          fit: spec.fit,
          holds: spec.holds,
          // Sliced by the same bounds as the images, so a pane's captions
          // stay index-aligned with the photographs it actually holds.
          // Tolerates a short caption list rather than assuming one: a
          // folder with no sidecar passes an empty list and every pane
          // simply gets no captions.
          captions: at < captions.length
              ? captions.sublist(at, math.min(captions.length, end))
              : const [],
        ));
      }
      at = end;
    }
    return out;
  }

  /// Slices authored panes to match page geometry. Page planning counts
  /// panes now; old scripts still have one image per pane, so their counts
  /// and timings are unchanged.
  static List<List<_MosaicPane>> _sliceMosaicPanePages(
      List<_MosaicPane> panes, List<List<Rect>> pages) {
    final List<List<_MosaicPane>> out = [];
    int at = 0;
    for (final page in pages) {
      final int end = math.min(panes.length, at + page.length);
      out.add(panes.sublist(at, end));
      at = end;
    }
    return out;
  }

  // -------------------------------------------------------------------
  // Simulation
  // -------------------------------------------------------------------

  void reset() {
    terminal.reset();
    frameCount = 0;
    
    inPrerollSequence = _configWithPreroll;
    phase = inPrerollSequence ? ScenePhase.prerollIdle : ScenePhase.terminal;
    
    _phaseStartFrame = 0;
    _activeGallery = null;
    _activeApp = null;
    _activeBrowser = null;
    _activeCard = null;
    _activeDossier = null;
    _activeTimeline = null;
    _chainClosing = false;
    _chainOpening = false;
  }

  /// True if ANY presentation request is currently raised on the terminal.
  bool get _terminalHasPending => terminal.hasPendingPresentation;

  /// Converts whatever pending request sits on the terminal into an active
  /// presentation object. Returns the OPENING phase that presentation should
  /// enter, or null if the request was a dud (empty gallery folder, timeline
  /// with no events) — in which case the request has been cleared and its
  /// hold burned as a pause, preserving the script's rough timing intent.
  ///
  /// Shared by the terminal phase (which then routes through termZoomOut)
  /// and the chain hand-off (which enters the opening phase directly).
  ScenePhase? _activatePendingRequest() {
    final PresentationRequest? pending = terminal.pendingPresentation;

    if (pending is GalleryRequest) {
      final GalleryRequest galReq = pending;
      final images = _galleryCache[galReq.folder] ?? [];
      if (images.isEmpty) {
        terminal.clearGalleryRequest();
        terminal.pauseFrames += galReq.holdFrames;
        return null;
      }
      final videoRate = _videoFpsRatio(galReq.sourceFps);
      _activeGallery = _ActiveGallery(
        images: images,
        holdFrames: galReq.holdFrames,
        transition: galReq.transition,
        title: galReq.title ?? kDefaultViewerTitle,
        isVideo: galReq.isVideo,
        videoFpsNumerator: videoRate.numerator,
        videoFpsDenominator: videoRate.denominator,
      );
      return ScenePhase.viewerOpening;
    }

    if (pending is BrowserRequest) {
      final BrowserRequest browReq = pending;
      final _ActiveBrowser? built = _composeBrowser(browReq);
      if (built == null) {
        // Same dud policy as every other presentation: burn the hold as a
        // pause so the piece keeps its length and simply has a hole in it,
        // rather than failing an export someone walked away from.
        terminal.clearBrowserRequest();
        terminal.pauseFrames += browReq.holdFrames;
        return null;
      }
      _activeBrowser = built;
      return ScenePhase.browserOpening;
    }

    if (pending is AppRequest) {
      final AppRequest appReq = pending;
      final fullImages = _galleryCache[appReq.folder] ?? [];
      if (fullImages.isEmpty) {
        terminal.clearAppRequest();
        terminal.pauseFrames += appReq.holdFrames;
        return null;
      }
      // Hard cap at 9. Extra images get dropped with a note.
      //
      // Captions are truncated by the SAME rule in the same branch. The
      // cache guarantees one record per decoded image, so slicing both to
      // kAppMaxTiles keeps them aligned; slicing only the images would
      // leave the tail captions in place and pointing nowhere.
      final List<ImageCaption> fullCaptions =
          _captionCache[appReq.folder] ?? const [];
      final List<ui.Image> images;
      final List<ImageCaption> imageCaptions;
      if (fullImages.length > kAppMaxTiles) {
        warnings.add(
            'App folder "${appReq.folder}" has ${fullImages.length} '
            'images; using first $kAppMaxTiles.');
        images = fullImages.sublist(0, kAppMaxTiles);
        imageCaptions = fullCaptions.length > kAppMaxTiles
            ? fullCaptions.sublist(0, kAppMaxTiles)
            : fullCaptions;
      } else {
        images = fullImages;
        imageCaptions = fullCaptions;
      }
      _activeApp = _composeApp(appReq, images, imageCaptions);

      // Silence is the failure mode to avoid here. Pane life is a config
      // set once at the top of a script, so a hold that is too short to
      // move in looks exactly like the feature not working, and the author
      // has no way to tell which. The page still runs at its scripted
      // length either way: motion is never allowed to extend a hold.
      if (paneLife.enabled && _activeApp!.isMosaic) {
        // EVERY PAGE, not just the first. Pages carry different pane
        // counts (an authored `pages` plan of 1,3,2 puts one selected pane
        // on page one and three on page two), so checking pagePanes.first
        // would clear a script whose later pages silently render still.
        //
        // Measured against each pane's REAL duration, base slot plus its
        // own authored `+N`, so a page the author has already paid to fix
        // does not keep reporting a problem that no longer exists.
        int worstSelected = 0;
        for (final page in _activeApp!.pagePanes) {
          final List<_MosaicPane> sel =
              page.where((p) => p.hasHero).toList();
          if (sel.isEmpty) continue;
          final int slot = _activeApp!.holdFrames ~/ sel.length;
          final bool tooShort =
              sel.any((p) => slot + p.totalHold < kPaneMinPushFrames);
          if (tooShort && sel.length > worstSelected) {
            worstSelected = sel.length;
          }
        }
        if (worstSelected > 0) {
          warnings.add(
              'PANELIFE: hold too short to walk the selected panes in '
              '"${appReq.folder}". Each selected pane needs at least '
              '$kPaneMinPushFrames frames, so a page with $worstSelected '
              'selected pane${worstSelected == 1 ? '' : 's'} wants a hold '
              'of at least ${worstSelected * kPaneMinPushFrames}; those '
              'heroes render still.');
        }

        // A pane cannot show more images than its slot has frames. The
        // beat arithmetic clamps each to a single frame and the tail
        // simply never appears, which looks like a pane that skips
        // pictures rather than like a timing limit being hit.
        for (final page in _activeApp!.pagePanes) {
          final int sel = page.where((p) => p.hasHero).length;
          if (sel == 0) continue;
          final int slot = _activeApp!.holdFrames ~/ sel;
          for (final pane in page) {
            final int paneSlot = slot + pane.totalHold;
            if (pane.hasHero && pane.images.length > paneSlot) {
              warnings.add(
                  'PANELIFE: a pane in "${appReq.folder}" groups '
                  '${pane.images.length} images but its slot is only '
                  '$paneSlot frames, so the last '
                  '${pane.images.length - paneSlot} never appear. Raise the '
                  'APP hold, hold an image longer with +frames, or group '
                  'fewer images.');
              break; // One report per page is enough to act on.
            }
          }
        }
      }

      return ScenePhase.appOpening;
    }

    if (pending is CardRequest) {
      final CardRequest cardReq = pending;
      // A missing title image does NOT skip the card — the text content
      // is the point. The panel just runs full height. (The load failure
      // was already recorded as a warning during setup.)
      _activeCard = _ActiveCard(
        image: _cardImageCache[cardReq.image],
        holdFrames: cardReq.holdFrames,
        panelColor: cardReq.panelColor,
        heading: cardReq.heading,
        body: cardReq.body,
      );
      return ScenePhase.cardOpening;
    }

    if (pending is DossierRequest) {
      final DossierRequest dosReq = pending;
      final images = _galleryCache[dosReq.folder] ?? [];
      if (images.isEmpty) {
        terminal.clearDossierRequest();
        // Burn the whole scripted duration, lead included, so the piece's
        // rough timing holds even when the folder is missing.
        terminal.pauseFrames += dosReq.cardLead +
            dosReq.holdSplit +
            (dosReq.centerMode == DossierCenterMode.sideOnly
                ? 0
                : dosReq.holdFull);
        return null;
      }
      final List<List<Rect>> mosaicPages =
          dosReq.centerMode == DossierCenterMode.mosaic
              // DOSSIER has no page plan of its own: its mosaic is a
              // center-stage gallery, not a paged app window.
              ? _buildMosaicPages(images.length, const [])
              : const [];
      _activeDossier = _ActiveDossier(
        images: images,
        titleImage: _cardImageCache[dosReq.image],
        holdSplit: dosReq.holdSplit,
        holdFull: dosReq.holdFull,
        centerMode: dosReq.centerMode,
        mosaicPages: mosaicPages,
        mosaicPageImages: mosaicPages.isEmpty
            ? const []
            : _sliceAppPages(images, mosaicPages),
        cardLead: dosReq.cardLead,
        panelColor: dosReq.panelColor,
        heading: dosReq.heading,
        body: dosReq.body,
      );
      return ScenePhase.dossierOpening;
    }

    if (pending is TimelineRequest) {
      final TimelineRequest tlReq = pending;
      final events = _ActiveTimeline.parseBody(tlReq.body);
      if (events.isEmpty) {
        warnings.add('Timeline block has no events; skipped.');
        terminal.clearTimelineRequest();
        terminal.pauseFrames += tlReq.holdFrames;
        return null;
      }

      // Center stage: pair photos to events in order. A missing or empty
      // folder degrades gracefully to a stage-less timeline (the load
      // failure was already warned about during setup). Count mismatches
      // are noted; only min(count) pairs animate.
      List<ui.Image> stagePhotos = const [];
      final String? stageFolder = tlReq.stageFolder;
      if (stageFolder != null) {
        List<ui.Image> photos = _galleryCache[stageFolder] ?? [];
        if (photos.length > kStageMaxPhotos) {
          warnings.add(
              'Stage folder "$stageFolder" has ${photos.length} images; '
              'using first $kStageMaxPhotos.');
          photos = photos.sublist(0, kStageMaxPhotos);
        }
        if (photos.isNotEmpty) {
          if (photos.length != events.length) {
            warnings.add(
                'Stage "$stageFolder": ${photos.length} photos vs '
                '${events.length} events; pairing first '
                '${photos.length < events.length ? photos.length : events.length}.');
          }
          stagePhotos = photos;
        }
      }

      _activeTimeline = _ActiveTimeline(
        events: events,
        holdFrames: tlReq.holdFrames,
        panelColor: tlReq.panelColor,
        heading: tlReq.heading,
        stagePhotos: stagePhotos,
        stageThumbW: tlReq.thumbW,
        stageGap: tlReq.stageGap,
        focusMode: tlReq.focusMode,
      );
      return ScenePhase.timelineOpening;
    }

    return null;
  }

  /// The chain hand-off: the outgoing presentation has finished closing with
  /// a chain ahead. Tear it down, advance the (hidden) terminal until the
  /// next presentation tag raises its request — peekNextPresentation()
  /// guaranteed only whitespace and [LINE:x] markers lie between, so this is
  /// a handful of ticks at most — then open the next presentation directly,
  /// terminal staying hidden the whole time.
  ///
  /// Fully deterministic: the same script always walks the same tick path,
  /// so dry-run, scrubbing, and export agree as always.
  /// Builds an [_ActiveApp] from a request and its already-decoded images.
  ///
  /// Factored out of the activation path so the SLIDE app switch can build
  /// the incoming window without going through it. The switch needs the
  /// pages and panes, and specifically does NOT want the side effects of
  /// activation: no phase change, no teardown of the window it is about to
  /// append to.
  _ActiveApp _composeApp(AppRequest appReq, List<ui.Image> images,
      List<ImageCaption> imageCaptions) {
    final grid = _pickAppGrid(images.length);
    final List<_MosaicPane> mosaicPanes = appReq.layout == AppLayout.mosaic
        ? _buildMosaicPanes(images, appReq.panePlan,
            captions: imageCaptions, warnings: warnings, folder: appReq.folder)
        : const <_MosaicPane>[];
    final pages = appReq.layout == AppLayout.mosaic
        ? _buildMosaicPages(mosaicPanes.length, appReq.pagePlan)
        : const <List<Rect>>[];
    return _ActiveApp(
      images: images,
      holdFrames: appReq.holdFrames,
      title: appReq.title ?? kDefaultAppTitle,
      layout: appReq.layout,
      maximizes: appReq.maximizes,
      gridCols: grid.cols,
      gridRows: grid.rows,
      pages: pages,
      pagePanes: _sliceMosaicPanePages(mosaicPanes, pages),
      paneLife: paneLife,
    );
  }

  /// Turns the next APP tag into more pages of the window already open.
  ///
  /// Returns false, having changed nothing, whenever the switch does not
  /// apply: wrong mode, not a mosaic, next tag is not an APP, or the next
  /// APP wants a different layout or a different maximize state. A slide
  /// from a maximized mosaic into a small windowed grid is not a space
  /// switch, it is a different window, and it should still open like one.
  ///
  /// The compatibility test runs against a NON-CONSUMING peek, so a
  /// rejected switch leaves the terminal exactly where it was and the
  /// normal close path runs untouched.
  /// Builds a browser window from a request, or null when the folder has
  /// nothing to show.
  ///
  /// Sources come out of the SAME cache slot as the images and are already
  /// aligned to them, because both were built in one pass in the folder
  /// decode loop. Nothing here re-reads the sidecar or looks anything up by
  /// name: a capture that failed to decode took its address with it, and a
  /// browser confidently showing the wrong URL under the right screenshot
  /// is a worse defect than one showing none.
  _ActiveBrowser? _composeBrowser(BrowserRequest req) {
    final List<ui.Image> all = _galleryCache[req.folder] ?? const [];
    if (all.isEmpty) return null;

    final List<ImageCaption> allSources =
        _captionCache[req.folder] ?? const [];

    List<ui.Image> images = all;
    List<ImageCaption> sources = allSources;
    if (all.length > kBrowserMaxPages) {
      warnings.add('Browser folder "${req.folder}" has ${all.length} '
          'captures; using first $kBrowserMaxPages.');
      images = all.sublist(0, kBrowserMaxPages);
      sources = allSources.length > kBrowserMaxPages
          ? allSources.sublist(0, kBrowserMaxPages)
          : allSources;
    }

    final int n = images.length;
    final String title = (req.title != null && req.title!.trim().isNotEmpty)
        ? req.title!.trim()
        : kDefaultBrowserTitle;

    // Silence is the failure mode worth guarding here. A folder of captures
    // with no sidecar renders a browser with an empty address bar, which
    // looks like a bug in the app rather than an unauthored folder.
    if (sources.every((s) => !s.hasSource)) {
      warnings.add('Browser folder "${req.folder}" has no URLs in '
          '$kFolderCaptionFile; the address bar will be empty.');
    }

    return _ActiveBrowser(
      images: images,
      sources: [
        for (int i = 0; i < n; i++)
          i < sources.length ? sources[i] : ImageCaption.none,
      ],
      pageHold: List<int>.filled(n, req.holdFrames, growable: true),
      pageTitle: List<String>.filled(n, title, growable: true),
      pageScroll: List<BrowserScroll>.filled(n, req.scroll, growable: true),
      maximizes: req.maximizes,
    );
  }

  /// The browser's half of `[CONFIG:APPSWITCH:SLIDE]`: the next BROWSER tag
  /// becomes more pages of the window already open.
  ///
  /// Simpler than the app window's version, but no longer free of a
  /// compatibility test. It used to be: a browser had no layout and no
  /// maximize state for two tags to disagree about, so "the next tag is a
  /// BROWSER" was the whole of it. The `_FULL` suffix ended that. Fit still
  /// travels per page and needs no agreement, but a windowed window cannot
  /// absorb a full one: there is no animation between the two sizes inside a
  /// navigation, so it would have to jump. A tag that fails the test falls
  /// back to closing this window and opening its own, which is exactly what
  /// the mismatched mosaic does.
  ///
  /// The test runs against a NON-CONSUMING lookahead, for the same reason
  /// the app switch does: deciding after the terminal has advanced means
  /// either tearing down a window that should have been kept, or putting a
  /// consumed tag back.
  ///
  /// The trap is identical too, and it is worth restating where someone will
  /// read it: the OUTGOING request must be released before the terminal is
  /// advanced. Activating a presentation does not clear the request that
  /// raised it, so a consumer that ticks without clearing first finds the
  /// request already pending, never advances, and is handed back the window
  /// currently on screen — which then absorbs itself and renders twice.
  bool _tryAbsorbNextBrowser() {
    if (appSwitch != AppSwitchMode.slide) return false;
    final _ActiveBrowser? current = _activeBrowser;
    if (current == null) return false;

    final String? scrollRaw = terminal.peekNextBrowserScroll();
    if (scrollRaw == null) return false;

    final seg =
        parseBrowserScrollSegment(scrollRaw.isEmpty ? null : scrollRaw);
    if (seg.maximizes != current.maximizes) return false;

    terminal.clearPresentationRequest();

    int guard = 0;
    while (!_terminalHasPending && !terminal.isFinished && guard < 600) {
      terminal.tick();
      guard++;
    }

    final pending = terminal.pendingPresentation;
    if (pending is! BrowserRequest) return false;

    final _ActiveBrowser? incoming = _composeBrowser(pending);
    if (incoming == null) {
      // Nothing to navigate to. Keep the window on the pages it has and
      // burn the hold, rather than sliding into a blank tab.
      terminal.clearPresentationRequest();
      terminal.pauseFrames += pending.holdFrames;
      return false;
    }

    current.absorb(incoming);
    terminal.clearPresentationRequest();
    return true;
  }

  bool _tryAbsorbNextApp() {
    if (appSwitch != AppSwitchMode.slide) return false;
    final _ActiveApp? current = _activeApp;
    if (current == null || !current.isMosaic) return false;

    final String? layoutRaw = terminal.peekNextAppLayout();
    if (layoutRaw == null) return false;

    final parsed = parseAppLayoutSegment(layoutRaw.isEmpty ? null : layoutRaw);
    if (parsed.layout != current.layout ||
        parsed.maximizes != current.maximizes) {
      return false;
    }

    // Release the OUTGOING request before advancing. Activation leaves it
    // sitting on the terminal, so without this the guard loop below sees
    // _terminalHasPending already true, never ticks, and hands back the
    // request for the window that is currently on screen. The window then
    // absorbs itself and the same APP renders twice.
    //
    // _performChainHandoff clears in exactly this position for exactly
    // this reason. Safe here because the outgoing presentation is already
    // live in [current]; the request has done its job.
    terminal.clearPresentationRequest();

    // Committed: advance to the tag we just inspected. Same guard as the
    // chain handoff, for the same reason.
    int guard = 0;
    while (!_terminalHasPending && !terminal.isFinished && guard < 600) {
      terminal.tick();
      guard++;
    }

    final pending = terminal.pendingPresentation;
    if (pending is! AppRequest) return false;

    final List<ui.Image> fullImages = _galleryCache[pending.folder] ?? [];
    if (fullImages.isEmpty) {
      // Nothing to show. Let the request drop and keep the window on its
      // existing pages rather than sliding to an empty space.
      terminal.clearPresentationRequest();
      terminal.pauseFrames += pending.holdFrames;
      return false;
    }

    final List<ImageCaption> fullCaptions =
        _captionCache[pending.folder] ?? const [];
    final List<ui.Image> images = fullImages.length > kAppMaxTiles
        ? fullImages.sublist(0, kAppMaxTiles)
        : fullImages;
    final List<ImageCaption> captions = fullCaptions.length > kAppMaxTiles
        ? fullCaptions.sublist(0, kAppMaxTiles)
        : fullCaptions;

    final _ActiveApp incoming = _composeApp(pending, images, captions);
    if (incoming.pages.isEmpty) {
      terminal.clearPresentationRequest();
      return false;
    }

    current.absorb(incoming);
    terminal.clearPresentationRequest();
    return true;
  }

  void _performChainHandoff() {
    _chainClosing = false;

    // Tear down the outgoing presentation and release its request.
    _activeGallery = null;
    _activeApp = null;
    _activeBrowser = null;
    _activeCard = null;
    _activeDossier = null;
    _activeTimeline = null;
    terminal.clearPresentationRequest();

    // Advance to the next request. The guard is pure paranoia — the peek
    // promised only whitespace ahead, but a hard cap means a logic bug can
    // never lock the app.
    int guard = 0;
    while (!_terminalHasPending && !terminal.isFinished && guard < 600) {
      terminal.tick();
      guard++;
    }

    final ScenePhase? opening = _activatePendingRequest();
    if (opening != null) {
      _chainOpening = true;
      _enterPhase(opening);
    } else {
      // Chained target turned out to be a dud (or the guard tripped):
      // fall back gracefully to the normal return path.
      _enterPhase(ScenePhase.termZoomIn);
    }
  }

  /// Advances exactly one deterministic scene frame.
  void tick() => _SceneEngineTicking(this)._tickDeterministic();

  void _enterPhase(ScenePhase next) {
    phase = next;
    // _enterPhase() runs inside the current tick. frameCount increments only
    // after the tick finishes, so the newly entered phase first becomes
    // visible at frameCount + 1 and must report visual age zero there.
    _phaseStartFrame = frameCount + 1;
    if (next == ScenePhase.viewerShowing) {
      _activeGallery?.framesIntoPhase = 0;
      _chainOpening = false;
    }
    if (next == ScenePhase.appShowing ||
        next == ScenePhase.browserShowing ||
        next == ScenePhase.cardShowing ||
        next == ScenePhase.dossierSplitShowing ||
        next == ScenePhase.dossierFullShowing ||
        next == ScenePhase.timelineShowing) {
      _chainOpening = false;
    }
  }
}
