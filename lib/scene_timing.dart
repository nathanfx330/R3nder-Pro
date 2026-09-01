// ./lib/scene_timing.dart

part of 'scene_engine.dart';

// Deterministic scene timings, phase definitions, and tiny timing helpers.
// Keeping these together makes the motion contract easy to audit.

/// Frame counts for the simulated window manager. All deterministic.
const int kZoomAnimFrames = 18; // fullscreen <-> windowed terminal zoom
const int kWindowAnimFrames = 12; // viewer open/close scale+fade
const int kGalleryTransitionFrames = 10; // FADE / FLIP between images

/// Converts the VIDEO dropdown label into an exact rational source rate.
/// NTSC-family labels use their conventional 1000/1001 rates while the
/// engine itself remains locked to [engineFps]. Integer-only accumulation in
/// the frame loop keeps preview, scrub, dry-run, and export deterministic.
({int numerator, int denominator}) _videoFpsRatio(String fps) {
  switch (fps) {
    case '23.976':
      return (numerator: 24000, denominator: 1001);
    case '24':
      return (numerator: 24, denominator: 1);
    case '25':
      return (numerator: 25, denominator: 1);
    case '29.97':
      return (numerator: 30000, denominator: 1001);
    case '50':
      return (numerator: 50, denominator: 1);
    case '59.94':
      return (numerator: 60000, denominator: 1001);
    case '60':
      return (numerator: 60, denominator: 1);
    case '30':
    default:
      return (numerator: 30, denominator: 1);
  }
}

/// Preroll animation timings
const int kPrerollIdleFrames = 30; // 1 second of solid desktop/green screen
const int kPrerollWipeFrames = 20; // 20 frames for the wipe-on reveal

/// App-window (Wii-style tile grid) timings.
/// The cascade reveals tiles one at a time; total cascade length is
/// (tileCount - 1) * kAppCascadeStagger + kAppCascadeTileFade.
const int kAppCascadeStagger = 6;   // frames between each tile starting its fade
const int kAppCascadeTileFade = 14; // frames each individual tile takes to fade in

/// Browser navigation: frames for one page turn inside an open browser
/// window. The address bar cuts to the new URL on frame 0, a load bar
/// sweeps the top of the viewport, and the capture arrives at the midpoint.
///
/// This is the only transition a browser has, and it is deliberately short.
/// A page load that takes half a second reads as a browser; one that takes
/// two reads as a slideshow with a progress bar drawn on it.
const int kBrowserNavFrames = 14;

/// Frames for a FULL browser to grow from its desktop rect to the whole
/// frame, and to shrink back on the way out.
///
/// The same value as [kAppMaximizeFrames] and deliberately its own constant
/// rather than a reference to it. They are the same move at the same speed
/// today because that is what makes two different windows on one desktop
/// read as one machine, but they are separate decisions: a mosaic maximizing
/// is content taking the screen, a browser maximizing is a window being
/// resized. Aliasing them would mean tuning one silently retimes the other.
const int kBrowserMaximizeFrames = 16;

/// Fraction of a scrolling page's hold spent at rest, top and bottom, before
/// and after the travel.
///
/// Without it the scroll starts on the frame the page lands and stops on the
/// frame it leaves, which reads as the window being dragged rather than as
/// somebody reading. Taken from both ends so the pause before scrolling and
/// the pause at the foot of the page are the same length.
const double kBrowserScrollDwellFrac = 0.16;

/// Least travel worth animating. A page whose hold cannot afford this after
/// its dwell is served static at the top instead, exactly as Pane Life
/// skips a page too short to walk rather than buying itself frames.
const int kBrowserMinScrollFrames = 24;

/// Info-card slide timing: frames for the panel to slide in from (and back
/// out to) the right edge. The hold duration comes from the [CARD] tag.
const int kCardSlideFrames = 16;

/// Timeline panel timings. The panel reuses the card slide for open/close;
/// once seated, the reveal sequence runs: spine draws top-to-bottom, then
/// events fade in one at a time. Total reveal length is
/// kTlSpineFrames + (eventCount - 1) * kTlEventStagger + kTlEventFade.
const int kTlSpineFrames = 20;   // spine drawing top-to-bottom
const int kTlEventStagger = 12;  // frames between each event starting its reveal
const int kTlEventFade = 14;     // frames each event takes to fade/slide in

/// Center-stage (contact-sheet sidecar) hard cap on photos. Extra images are
/// ignored with a warning; extra events simply have no photo.
const int kStageMaxPhotos = 12;

/// Hard cap on [IMG] tile dimensions (either axis, native pixels). These are
/// Programmed Symbols tiles — small stamps authored in GIMP — not photos. A
/// full-resolution photograph pushed through the run-merger would explode
/// into millions of rects; reject it early with a warning instead. Oversized
/// files play as duds (timing burned as a pause), same as a missing file.
const int kImgMaxDimension = 512;

/// Hard cap on [PHOTO] crude scans (either axis, native pixels). Allows larger
/// images than IMG, but highly encourages coarse dithering/posterization.
const int kPhotoMaxDimension = 1024;

/// Default titles when the script doesn't specify them.
const String kDefaultTerminalTitle = 'operator@field-terminal: ~';
const String kDefaultViewerTitle = 'Image Viewer';
const String kDefaultAppTitle = 'App';
const String kDefaultBrowserTitle = 'Web Browser';

/// Hard cap on the number of tiles in an app window. Extra images are ignored
/// with a warning. Layout is picked adaptively from this count.
///
/// In GRID this fills a 3x3. In MOSAIC it is three full pages of panels.
const int kAppMaxTiles = 9;

/// MOSAIC panels per page. Three is the composition the layout is tuned for:
/// a hero panel down one side and two stacked panels beside it.
const int kAppMosaicPerPage = 3;

/// Frames for a MOSAIC window to maximize from its desktop rect out to the
/// full frame, and to restore back again on the way out. Slightly longer
/// than the open/close animation: it is a bigger move and reads better with
/// a little more time in it.
const int kAppMaximizeFrames = 16;

/// Frames for the horizontal pan from one MOSAIC page to the next.
const int kAppPanFrames = 22;

/// How far the oversized heading travels relative to the panels during a pan.
/// Less than 1 means the heading lags behind, which is the parallax that
/// reads as a Metro panorama rather than a slide transition.
const double kAppHeadingParallax = 0.34;

/// Fraction of the content width taken by the MOSAIC hero panel. Deliberately
/// off from 0.5: equal halves read as a split screen, not a composition.
const double kAppMosaicHeroFrac = 0.56;

/// What the scene is currently doing. The painter switches on this.
enum ScenePhase {
  /// Desktop only (pure green background or wallpaper)
  prerollIdle,

  /// Terminal parked window wipes on horizontally
  prerollWipe,

  /// Terminal fills the frame. In desktop mode this is a fullscreen black
  /// terminal — the wallpaper is hidden until a gallery pulls the view back.
  terminal,

  /// The reveal: the view pulls back from fullscreen, and the terminal turns
  /// out to be a window sitting on the desktop. Chrome fades in as it shrinks.
  termZoomOut,

  /// Image viewer window animating open (terminal stays parked behind it).
  viewerOpening,

  /// An image is held on screen in the viewer.
  viewerShowing,

  /// Transitioning between two images (FADE / FLIP only; CUT is instant).
  viewerTransition,

  /// Image viewer animating closed. If a chain is ahead (isChainClosing),
  /// the terminal stays hidden and the next presentation opens directly.
  viewerClosing,

  /// App window animating open (terminal stays parked behind it).
  appOpening,

  /// MOSAIC only: the window has finished opening on the desktop and is now
  /// growing from its desktop rect out to the full frame, chrome fading as
  /// it goes. Panels do not appear until it is seated.
  appMaximizing,

  /// App window is fully open: tiles cascade-fade in Wii-home-menu style,
  /// then hold for the script-specified duration.
  appShowing,

  /// MOSAIC only: the panel surface slides horizontally to the next page of
  /// panels. The outgoing page exits left, the incoming page enters from the
  /// right. GRID never enters this phase because it is always one page.
  appPanning,

  /// MOSAIC only: the reverse of [appMaximizing]. The window shrinks back to
  /// its desktop rect and the chrome fades in, so the exit is the same move
  /// as the entrance played backwards.
  appRestoring,

  /// App window animating closed. Chains like viewerClosing.
  appClosing,

  /// Browser window animating open (terminal stays parked behind it).
  browserOpening,

  /// FULL only: the window has finished opening on the desktop and is now
  /// growing from its desktop rect out to the full frame. The mirror of
  /// [appMaximizing], with one deliberate difference: the chrome does not
  /// collapse. A mosaic's title bar is dressing and its panels are the
  /// content, so the bar can fade and let the panels grow into the space. A
  /// browser's tab strip and address bar ARE the content in the sense that
  /// matters, since they are what makes the window read as a browser at all.
  /// So both bars keep full height and only the shadow, the corner radius,
  /// and the desktop around them are given up.
  ///
  /// The capture is already loaded and shown while this runs. Unlike the
  /// mosaic, which hides its panels until the window is seated because
  /// content sliding inside a moving window reads as chaos, a browser is
  /// showing one image that simply gets bigger, which is what a window
  /// growing looks like.
  browserMaximizing,

  /// A page is loaded and held. Under [BrowserScroll.scroll] the viewport
  /// pans down through the capture inside this phase; the travel divides the
  /// hold rather than extending it, so a browser page runs exactly as long
  /// whether its capture is one screen tall or twenty.
  browserShowing,

  /// Navigating to the next page: address bar has already cut to the new
  /// URL, the load bar sweeps, and the capture arrives at the midpoint. The
  /// window itself does not move — a browser navigates rather than pans,
  /// which is the whole reason this is not the app window's page pan.
  browserNavigating,

  /// FULL only: the reverse of [browserMaximizing]. The window shrinks back
  /// to its desktop rect before it closes, so the exit is the entrance
  /// played backwards.
  browserRestoring,

  /// Browser window animating closed. Chains like viewerClosing.
  browserClosing,

  /// Info card sliding in from the right edge (terminal fades out
  /// simultaneously — the card sits on the bare desktop, exclusive).
  cardOpening,

  /// Info card fully on screen, holding.
  cardShowing,

  /// Info card sliding back out to the right (terminal fades back in,
  /// unless a chain is ahead — then it stays hidden).
  cardClosing,

  /// Dossier sequence: Card sliding in on the right. If the tag scripted a
  /// cardLead, the gallery does NOT open during this phase — the card
  /// arrives alone. With cardLead = 0 (classic), the gallery opens
  /// simultaneously, exactly as before.
  dossierOpening,

  /// Dossier sequence: card seated alone, counting down the scripted
  /// cardLead frames before the gallery joins. Only entered when the tag
  /// scripted a cardLead > 0. Introduce the subject, then the evidence.
  dossierCardLead,

  /// Dossier sequence: gallery window animating open beside the already
  /// seated card. Only entered when the tag scripted a cardLead > 0.
  dossierGalleryOpening,

  /// Dossier sequence: Side-by-side mode holding.
  dossierSplitShowing,

  /// Dossier sequence: Card sliding out, gallery stretching to center stage.
  dossierTransitioning,

  /// Dossier sequence: Gallery holding center stage.
  dossierFullShowing,

  /// Dossier MOSAIC only: center-stage panels pan to the next page. The
  /// existing app mosaic timing is reused so the two presentations speak
  /// the same motion language.
  dossierMosaicPanning,

  /// Dossier sequence: Gallery closing, zooming back to terminal.
  dossierClosing,

  /// Timeline panel sliding in from the right edge (terminal fades out
  /// simultaneously — the panel sits on the bare desktop, exclusive).
  /// If a stage is attached, the "Photos" window fades in alongside it.
  timelineOpening,

  /// Timeline panel fully on screen: spine draws, events reveal in order,
  /// then holds for the script-specified duration. A stage, if present,
  /// runs its snaking connector line in lockstep with the event reveals.
  timelineShowing,

  /// Timeline panel sliding back out to the right (terminal fades back in,
  /// unless a chain is ahead — then it stays hidden).
  timelineClosing,

  /// The terminal window zooms back up to fullscreen; chrome fades out.
  /// Shared exit path for gallery, app, card, and timeline sequences —
  /// but ONLY when no chain is ahead. Chained presentations hand off to
  /// each other directly on the desktop and never pass through here.
  termZoomIn,
}