// ./lib/presentation_requests.dart

// Presentation request models shared by the terminal and scene engines.
//
// These are deliberately state-free DTOs: TerminalEngine raises them and
// SceneEngine consumes them. Keeping them out of engine.dart makes the
// hand-off boundary explicit without changing the public API.

import 'package:flutter/material.dart';

/// Marker base for every deterministic terminal-to-scene hand-off.
///
/// TerminalEngine can therefore own exactly one pending presentation at a
/// time while callers still use the typed accessors for each presentation.
abstract class PresentationRequest {}

/// Raised by a [GALLERY:folder:hold:transition:title] tag. The engine suspends
/// itself (tick() becomes a no-op) until the owning SceneEngine consumes
/// this request, plays the gallery sequence, and calls clearGalleryRequest().
class GalleryRequest extends PresentationRequest {
  final String folder;
  final int holdFrames;
  final String transition; // CUT | FADE | FLIP

  /// Viewer window title bar text (e.g. a fake document filename like
  /// "Evidence_Scan_0447.pdf"). Null means the painter uses its default.
  final String? title;

  /// True if this is a video sequence (alters hold-frame logic in playback).
  final bool isVideo;

  /// Source frame rate for an extracted VIDEO image sequence. The scene still
  /// renders at the fixed engine frame rate; this value only controls which source frame is
  /// shown on each deterministic engine tick.
  final String sourceFps;

  GalleryRequest({
    required this.folder,
    required this.holdFrames,
    required this.transition,
    this.title,
    this.isVideo = false,
    this.sourceFps = '30',
  });
}

/// Raised by an [APP:folder:hold:title] tag. Same suspend-and-hand-off
/// pattern as GalleryRequest, but the SceneEngine plays out a very different
/// sequence: zoom terminal to parked, open a fullscreen app window with an
/// adaptive rounded-rect image grid, cascade-fade the tiles in Wii-home-menu
/// style, hold, then close and zoom back.
/// How an app window arranges its images.
///
/// Composition only. Whether the window maximizes is a separate axis,
/// carried by [AppRequest.maximizes], because "which shape" and "how big a
/// window" are unrelated questions and welding them together is what made
/// MOSAIC mean two things at once.
///
/// The enum lives here rather than in the SceneEngine because the request
/// is raised during the terminal tick, upstream of any scene state.
enum AppLayout {
  /// The original adaptive uniform grid: 1x1 / 1x2 / 1x3 / 2x2 / 2x3 / 3x3
  /// by image count, every tile the same size, revealed in reading order.
  grid,

  /// Metro-style unequal panels built by recursive halving, three to a page,
  /// panning horizontally to reach the rest.
  mosaic;
}

/// Reading direction for the images authored inside one MOSAIC pane.
///
/// This is intentionally script data rather than painter state. A pane can
/// contain more than one source image, and the direction tells the
/// deterministic Pane Life sequence which end of that ordered run to visit
/// first. The folder manifest still owns the underlying image order.
/// What happens between two adjacent APP tags.
///
/// `desktop` is the original behaviour and stays the default: the window
/// un-maximizes, shrinks away, and the next one grows back out. `slide`
/// keeps the window and treats the next tag's pages as more pages of this
/// one, so the transition is the horizontal page pan that MOSAIC already
/// uses, the way switching workspaces slides rather than closing anything.
///
/// Not the default, deliberately. It changes both the look and the length
/// of every script with adjacent APP tags, and a piece already cut against
/// the old timing should keep it until its author says otherwise.
enum AppSwitchMode { desktop, slide }

AppSwitchMode parseAppSwitchMode(String? raw) {
  switch ((raw ?? '').trim().toUpperCase()) {
    case 'SLIDE':
      return AppSwitchMode.slide;
    default:
      return AppSwitchMode.desktop;
  }
}

enum PaneDirection { leftToRight, rightToLeft }

/// How a pane's source image is scaled into the pane rect.
///
/// This is NOT the usual cover/contain pair. [fitHeight] fits the vertical
/// edge unconditionally: `rect.height / imgH`, whatever the source aspect.
/// For a source wider than the pane that is identical to [fill], so nothing
/// authored before this existed can change; for a source taller than the
/// pane it letterboxes against the plate instead of cropping the top and
/// bottom away, which is the case that has no answer today.
///
/// Fitting the edge rather than choosing the smaller of two scales is what
/// keeps this compatible with Pane Life. The horizontal walk clamps focusX
/// to whatever crop overflow exists, so a wide source in a fitHeight pane
/// still travels and a narrow one simply has nowhere to go and rests
/// centred. The push is safe for the same reason it always was: the zoom
/// floor is 100%, so a vertically flush image only ever scales up and can
/// never expose the plate above or below.
enum PaneFit {
  /// COVER: `max(rect.w / imgW, rect.h / imgH)`. Always crops, never
  /// letterboxes. Every pane authored before FIT existed is this.
  fill,

  /// Fit the vertical edge: `rect.h / imgH`. Letterboxes a tall source
  /// left and right.
  fitHeight,

  /// Fit the horizontal edge: `rect.w / imgW`. Letterboxes a wide source
  /// above and below.
  ///
  /// The mirror of [fitHeight] and the right answer for the opposite
  /// problem: a panorama, a broadside, or a double-page spread in a pane
  /// taller than it is wide, where fitting the vertical edge would crop
  /// away both ends of the thing you are showing.
  ///
  /// One consequence worth knowing before authoring it. A fitWidth pane
  /// is exactly flush horizontally at rest, so it has no crop overflow for
  /// the LR/RL walk until the push scales it up, whereas a wide source in
  /// a fitHeight pane has travel from the first frame. A fitWidth pane
  /// therefore reads as a still that breathes rather than one that moves.
  fitWidth,
}

/// Parses a fit keyword. Returns null for anything unrecognised so callers
/// can fall back rather than guess.
///
/// `FIT` and `FITH` are the same thing. FIT came first and means the
/// vertical edge, and it stays the canonical emitted form: renaming it
/// when fitWidth arrived would have silently rewritten every pane token
/// already on disk. FITH exists for authors who would rather say which
/// edge they mean.
PaneFit? paneFitFromName(String raw) {
  switch (raw.trim().toUpperCase()) {
    case 'FILL':
      return PaneFit.fill;
    case 'FIT':
    case 'FITH':
      return PaneFit.fitHeight;
    case 'FITW':
      return PaneFit.fitWidth;
  }
  return null;
}

/// The next fit in the contact sheet's cycle.
///
/// A cycle rather than a toggle because there are three states now and a
/// checkbox cannot hold three. Ordered so the common path is short: FILL
/// is where everything starts, one click gets the fit that answers the
/// usual problem (a portrait cropped top and bottom), and a second gets
/// its mirror.
PaneFit nextPaneFit(PaneFit current) {
  switch (current) {
    case PaneFit.fill:
      return PaneFit.fitHeight;
    case PaneFit.fitHeight:
      return PaneFit.fitWidth;
    case PaneFit.fitWidth:
      return PaneFit.fill;
  }
}

/// Authored structure for one MOSAIC pane.
///
/// A pane consumes [imageCount] consecutive images from the folder order.
/// [heroIndex] is zero-based *inside the pane*. Null is meaningful: it means
/// this pane is NOT selected for Pane Life. `[CONFIG:PANELIFE:ON]` only
/// enables the capability; a pane must explicitly nominate a hero to move.
class AppPaneSpec {
  final int imageCount;
  final int? heroIndex;
  final PaneDirection direction;

  /// Scaling rule for every image this pane shows. Pane-level rather than
  /// per-image on purpose: a pane walking a mixed set would otherwise grow
  /// and lose its letterbox bars mid-walk, which reads as the layout
  /// changing its mind. Group the tall sources into their own pane instead.
  final PaneFit fit;

  /// Extra frames each image in this pane is held, indexed within the pane.
  ///
  /// THIS IS THE ONE AUTHORED FACT ON A PANE THAT CHANGES DURATION. Hero
  /// selection, direction, and fit were all frame-neutral by construction:
  /// they redistribute or re-scale inside a hold the page already owned.
  /// A hold extension is new time. It moves every scene after it, exactly
  /// as grouping does by changing page count, and it is authored for the
  /// same reason: because you asked for it, not as a side effect of a
  /// look.
  ///
  /// Applies whether or not Pane Life is enabled, which is not an
  /// afterthought. If extensions only lengthened walks, the exporter's
  /// frame-neutrality audit (which disables Pane Life, re-ticks, and
  /// compares) would see the count move and report a defect. Independent
  /// of Pane Life, a hold on an unstarred pane simply rests longer on a
  /// still image, which is also the most common thing anyone wants.
  ///
  /// May be shorter than [imageCount]; [holdAt] returns 0 past the end
  /// rather than throwing mid-render.
  final List<int> holds;

  const AppPaneSpec({
    required this.imageCount,
    this.heroIndex,
    this.direction = PaneDirection.leftToRight,
    this.fit = PaneFit.fill,
    this.holds = const [],
  });

  bool get hasHero => heroIndex != null;

  bool get fitsHeight => fit == PaneFit.fitHeight;

  bool get fitsWidth => fit == PaneFit.fitWidth;

  bool get fitsAnEdge => fit != PaneFit.fill;

  /// Chip label for this fit, or null when it is the default.
  String? get fitLabel {
    switch (fit) {
      case PaneFit.fill:
        return null;
      case PaneFit.fitHeight:
        return 'FIT';
      case PaneFit.fitWidth:
        return 'FITW';
    }
  }

  int holdAt(int i) =>
      (i < 0 || i >= holds.length) ? 0 : (holds[i] < 0 ? 0 : holds[i]);

  /// Frames this pane adds to its page.
  int get totalHold {
    int t = 0;
    for (final int h in holds) {
      if (h > 0) t += h;
    }
    return t;
  }

  bool get hasHold => totalHold > 0;

  AppPaneSpec copyWith({
    int? imageCount,
    int? heroIndex,
    bool clearHero = false,
    PaneDirection? direction,
    PaneFit? fit,
    List<int>? holds,
  }) {
    return AppPaneSpec(
      imageCount: imageCount ?? this.imageCount,
      heroIndex: clearHero ? null : (heroIndex ?? this.heroIndex),
      direction: direction ?? this.direction,
      fit: fit ?? this.fit,
      holds: holds ?? this.holds,
    );
  }

  /// This pane with image [i] held [frames] longer.
  ///
  /// Grows the list to the pane's length as needed, so a caller never has
  /// to know whether holds were authored before touching one.
  AppPaneSpec withHoldAt(int i, int frames) {
    final int count = imageCount < 1 ? 1 : imageCount;
    if (i < 0 || i >= count) return this;
    final List<int> next = List<int>.filled(count, 0);
    for (int k = 0; k < count; k++) {
      next[k] = holdAt(k);
    }
    next[i] = frames < 0 ? 0 : frames;
    return copyWith(holds: next);
  }

  AppPaneSpec normalized([int? available]) {
    int count = imageCount < 1 ? 1 : imageCount;
    if (available != null && available > 0 && count > available) {
      count = available;
    }
    final int? hero = heroIndex == null
        ? null
        : heroIndex!.clamp(0, count - 1).toInt();
    // Trimmed to the pane's real length. A pane cut short by the folder
    // running out of images must not keep paying for frames on photographs
    // it no longer shows.
    final List<int> h = [
      for (int k = 0; k < count; k++) holdAt(k),
    ];
    return AppPaneSpec(
      imageCount: count,
      heroIndex: hero,
      direction: direction,
      fit: fit,
      holds: h.any((v) => v > 0) ? h : const [],
    );
  }

  /// Canonical pane token. Grouping can exist without selection:
  /// `3-LR` = three images in one static pane; `3@2-LR` = same pane, with
  /// image 2 explicitly selected as the Pane Life hero. Single-image panes
  /// omit the default LR suffix to keep the language compact.
  ///
  /// FIT is a second suffix rather than a third direction word, because fit
  /// and reading direction are orthogonal: a grouped pane can letterbox and
  /// still walk its images right to left. `FILL` parses but is never
  /// emitted, so the canonical form of a default pane stays as short as it
  /// was before this existed. `FITH` likewise parses and is emitted as
  /// `FIT`, so a script that says which edge it means keeps working
  /// without every existing `-FIT` being rewritten.
  ///
  /// A hold extension is a `+` tail. `+45` is shorthand for "all of it on
  /// the image this pane is about", which is the hero, or image one when
  /// no hero is nominated. `+0,45,0` is the explicit per-image form. The
  /// shorthand is emitted whenever it is exact, so the common case stays
  /// readable, and the two forms mean the same thing: `3@2-LR+0,45,0`
  /// normalises to `3@2-LR+45` on the next write.
  String toScriptToken() {
    final String hero = heroIndex == null ? '' : '@${heroIndex! + 1}';
    final String fitTail = fit == PaneFit.fill ? '' : '-${fitLabel!}';
    final String holdTail = _holdTail();
    if (imageCount <= 1 && direction == PaneDirection.leftToRight) {
      return '$imageCount$hero$fitTail$holdTail';
    }
    final String dir =
        direction == PaneDirection.rightToLeft ? 'RL' : 'LR';
    return '$imageCount$hero-$dir$fitTail$holdTail';
  }

  String _holdTail() {
    if (!hasHold) return '';
    final int count = imageCount < 1 ? 1 : imageCount;
    final int focus = heroIndex == null ? 0 : heroIndex!.clamp(0, count - 1);

    bool onlyFocus = true;
    for (int i = 0; i < count; i++) {
      if (i != focus && holdAt(i) > 0) {
        onlyFocus = false;
        break;
      }
    }
    if (onlyFocus) return '+${holdAt(focus)}';

    return '+${[for (int i = 0; i < count; i++) holdAt(i)].join(',')}';
  }
}

/// Parses the tag's layout segment into its two axes.
///
/// Anything unrecognized (including null, which is the common case for
/// every script written before this existed) falls back to a windowed grid,
/// so existing templates render unchanged.
({AppLayout layout, bool maximizes}) parseAppLayoutSegment(String? s) {
  switch (s?.toUpperCase()) {
    case 'MOSAIC':
      return (layout: AppLayout.mosaic, maximizes: false);
    case 'MOSAIC_FULL':
      return (layout: AppLayout.mosaic, maximizes: true);
    default:
      return (layout: AppLayout.grid, maximizes: false);
  }
}

class AppRequest extends PresentationRequest {
  final String folder;

  /// Frames to hold AFTER the cascade reveal completes. In [AppLayout.mosaic]
  /// this is per page, the way a gallery's hold is per image.
  final int holdFrames;

  /// App window title bar text. Null means the painter uses its default.
  final String? title;

  /// Arrangement of the images inside the window.
  final AppLayout layout;

  /// Whether the window grows out to the whole frame once open, and
  /// restores to its desktop rect on the way out.
  final bool maximizes;

  /// Panes per page, authored. Empty means chunk at the layout default.
  ///
  /// MOSAIC only. A page costs a hold plus a pan, so this is the one thing
  /// about a folder presentation that changes its duration, which is why it
  /// is carried on the request from the script rather than read from beside
  /// the images. Image ORDER travels the other way, in the folder's
  /// manifest, because reordering never changes how long the tag runs.
  final List<int> pagePlan;

  /// Images grouped into authored panes. Empty preserves the legacy layout
  /// rule (one source image equals one pane) but does NOT select any pane for
  /// Pane Life. Selection is explicit in the script.
  ///
  /// Syntax lives in the final APP segment, for example:
  /// `3@2-LR;1-FIT;2@2-RL`
  /// means three consecutive images in pane one (image two is selected hero),
  /// one static image in pane two scaled to fit its vertical edge, then two
  /// images in pane three with image two selected and a right-to-left read.
  final List<AppPaneSpec> panePlan;

  AppRequest({
    required this.folder,
    required this.holdFrames,
    this.title,
    this.layout = AppLayout.grid,
    this.maximizes = false,
    this.pagePlan = const [],
    this.panePlan = const [],
  });
}

/// Raised by a [CARD:image:hold:r,g,b:heading]body[/CARD] block. Same
/// suspend-and-hand-off pattern as GalleryRequest/AppRequest. The SceneEngine
/// zooms the terminal out to parked, fades it away, slides a presentation
/// panel in from the right edge (title image on top, colored text block with
/// H1 heading + body copy below), holds, slides out, and resumes.
///
/// The whole block — including the multi-line body — is consumed as a single
/// tag match, so body text never enters the typing stream.
/// How a page capture meets a viewport it almost never matches.
///
/// Deliberately not the same vocabulary as [PaneFit], even though the
/// geometry overlaps. A mosaic pane fits an EDGE because a photograph in a
/// panel is a composition problem; a browser fits the WIDTH because that is
/// what a browser does to a page, and the leftover height is not overflow
/// to be cropped but page to be scrolled. Sharing an enum would have meant
/// explaining, at every call site, which of the two meanings was in play.
enum BrowserScroll {
  /// Fit the width, anchor top, then pan down through whatever is below the
  /// fold, inside the hold the page already owns.
  scroll,

  /// Fit the width, anchor top, no motion. Above the fold only.
  top,

  /// Contain the whole capture, letterboxed against the page plate. For a
  /// short page or a phone capture, where a scroll has nowhere to go.
  fit,
}

/// Splits the scroll segment into its two axes.
///
/// Deliberately the same shape as [parseAppLayoutSegment], because it is the
/// same idea: one enumerated keyword in the grammar carrying both a
/// composition fact and a window fact, taken apart the moment it is read.
/// `MOSAIC_FULL` established that spelling and this follows it rather than
/// inventing a second way to say the window fills the frame.
///
/// The two halves live in different places downstream and it is worth being
/// clear about which. Scroll is a PER PAGE fact: `_ActiveBrowser` keeps a
/// list of them, because a SLIDE switch can join a scrolling tag to a fitted
/// one and a browser that scrolls one page and not the next is just a
/// browser. Maximize is a property of the WINDOW, so it is a single value
/// and it joins the compatibility test that decides whether the next tag may
/// be absorbed at all.
///
/// Anything unrecognised, including null, is a plain scrolling window. Every
/// BROWSER tag written before this existed lands there unchanged.
({BrowserScroll scroll, bool maximizes}) parseBrowserScrollSegment(String? s) {
  switch (s?.trim().toUpperCase()) {
    case 'SCROLL_FULL':
      return (scroll: BrowserScroll.scroll, maximizes: true);
    case 'TOP':
      return (scroll: BrowserScroll.top, maximizes: false);
    case 'TOP_FULL':
      return (scroll: BrowserScroll.top, maximizes: true);
    case 'FIT':
      return (scroll: BrowserScroll.fit, maximizes: false);
    case 'FIT_FULL':
      return (scroll: BrowserScroll.fit, maximizes: true);
    case 'SCROLL':
    default:
      return (scroll: BrowserScroll.scroll, maximizes: false);
  }
}

/// The scroll half only, for labels and hints that have no opinion about
/// window state.
String browserScrollName(BrowserScroll s) {
  switch (s) {
    case BrowserScroll.scroll:
      return 'SCROLL';
    case BrowserScroll.top:
      return 'TOP';
    case BrowserScroll.fit:
      return 'FIT';
  }
}

/// The canonical segment keyword for a scroll plus window state.
///
/// The inverse of [parseBrowserScrollSegment], so an authoring surface that
/// holds the two facts apart can write the one word the grammar wants
/// without assembling the suffix by hand at each site.
String browserScrollSegment(BrowserScroll s, bool maximizes) =>
    maximizes ? '${browserScrollName(s)}_FULL' : browserScrollName(s);

/// Every scroll keyword the grammar accepts, in the order an authoring
/// surface should offer them.
///
/// A list rather than six literals repeated per surface. The node dropdown
/// and the ADD NODE palette both enumerate these, and that is exactly the
/// shape `config_keys.dart` exists to fix: a keyword missing from the
/// dropdown falls through to a text field, and one missing from the palette
/// cannot be discovered, and neither failure says anything on its way past.
///
/// [APP] still spells its three by hand at each site, which is the older
/// habit rather than the better one. Six is where the habit stops paying.
const List<String> kBrowserScrollSegments = [
  'SCROLL',
  'SCROLL_FULL',
  'TOP',
  'TOP_FULL',
  'FIT',
  'FIT_FULL',
];

/// Hard cap on pages in one browser window. Generous compared to the app
/// window's nine, because pages here are sequential navigations rather than
/// panels competing for one screen, and a SLIDE run can legitimately chain
/// several tags into one session.
///
/// Lives here rather than with the scene's timing constants, even though
/// every other cap does, because two very different things need it: the
/// compositor, which truncates, and the asset manager, which has to warn a
/// folder that it holds more captures than a window will visit. The asset
/// manager is an authoring surface and has no business importing the render
/// library for an integer. A cap is a fact about the format, not about the
/// animation, so this is where it can be read from both sides.
const int kBrowserMaxPages = 24;

/// Raised by `[BROWSER:folder:hold:title:scroll]`, where the scroll segment
/// may carry a `_FULL` suffix. Same suspend-and-hand-off pattern as every
/// other desktop presentation.
///
/// Carries no URLs. The addresses and page titles belong to the screenshots
/// and are read from the folder's `.r3nder_captions` sidecar during setup,
/// positionally alongside the decode, for the same reason captions are: a
/// file that fails to decode shortens the image list, and a lookup made
/// afterwards would put every address after the failure on the wrong page.
/// A browser confidently showing the wrong URL under the right screenshot
/// is worse than one showing none.
class BrowserRequest extends PresentationRequest {
  final String folder;

  /// Frames to hold each page after it has loaded. Under [BrowserScroll.scroll]
  /// this is also the budget the scroll travels inside; motion never buys
  /// itself more, the same rule Pane Life follows.
  final int holdFrames;

  /// Window title bar text. Null means the painter's default.
  final String? title;

  final BrowserScroll scroll;

  /// Whether the window grows out to the whole frame once open, and restores
  /// to its desktop rect on the way out.
  ///
  /// The same field [AppRequest] carries, and the same separation: which
  /// window this is, and how big it is, are unrelated questions.
  ///
  /// What it does NOT mean is the mosaic's version of maximized. When a
  /// MOSAIC goes full frame its title bar collapses and the panels grow into
  /// the space, because the bar is dressing and the panels are the content.
  /// A browser's tab strip and address bar are not dressing; they are the
  /// entire reason the window reads as a browser. Strip them and what is
  /// left is a photograph of a webpage. So a full browser keeps both bars at
  /// full height and gives up only the shadow, the corner radius, and the
  /// desktop around it.
  final bool maximizes;

  BrowserRequest({
    required this.folder,
    required this.holdFrames,
    this.title,
    this.scroll = BrowserScroll.scroll,
    this.maximizes = false,
  });
}

class CardRequest extends PresentationRequest {
  /// Image file inside images/ shown at the top of the card.
  final String image;

  /// Frames to hold with the card fully open (slide-in/out are extra,
  /// scene-owned).
  final int holdFrames;

  /// Text-block panel color (the programmable bottom portion).
  final Color panelColor;

  /// H1 heading. Empty string means no heading row is drawn.
  final String heading;

  /// Multi-line body copy, already stripped of injected [LINE:x] markers.
  final String body;

  CardRequest({
    required this.image,
    required this.holdFrames,
    required this.panelColor,
    required this.heading,
    required this.body,
  });
}

/// Raised by a [DOSSIER] block. Plays a dynamic sequence: info card enters
/// (optionally alone for [cardLead] frames), browsing gallery joins it
/// side-by-side, then [centerMode] decides whether the gallery takes center
/// stage or the side layout exits directly.
class DossierRequest extends PresentationRequest {
  final String folder;
  final String image;
  final int holdSplit;
  final int holdFull;

  /// What happens after the side-by-side card + gallery hold.
  ///
  /// [DossierCenterMode.grid] is the legacy behavior and therefore the
  /// default for every script written before this setting existed.
  final DossierCenterMode centerMode;

  /// Frames the card sits alone, fully seated, before the gallery window
  /// opens next to it. 0 = card and gallery arrive together (the classic
  /// behavior). Introduce the subject, then reveal the evidence.
  final int cardLead;

  final Color panelColor;
  final String heading;
  final String body;

  DossierRequest({
    required this.folder,
    required this.image,
    required this.holdSplit,
    required this.holdFull,
    this.centerMode = DossierCenterMode.grid,
    this.cardLead = 0,
    required this.panelColor,
    required this.heading,
    required this.body,
  });
}

/// The dossier's second-stage presentation after the side-by-side view.
///
/// Kept separate from [AppLayout] because SIDE_ONLY is meaningful for a
/// dossier but not for an APP, and a dossier's MOSAIC is a center-stage
/// continuation rather than an app-window mode.
enum DossierCenterMode {
  /// Legacy behavior: card exits and the gallery expands into the centered
  /// uniform grid.
  grid,

  /// Card exits and the gallery expands into the same Metro-style paged
  /// mosaic language used by APP:MOSAIC.
  mosaic,

  /// No center stage. The card and side gallery leave together after the
  /// side hold completes.
  sideOnly,
}

DossierCenterMode parseDossierCenterMode(String? s) {
  switch (s?.toUpperCase()) {
    case 'MOSAIC':
      return DossierCenterMode.mosaic;
    case 'SIDE_ONLY':
      return DossierCenterMode.sideOnly;
    default:
      return DossierCenterMode.grid;
  }
}

/// Raised by a [TIMELINE:hold:r,g,b:heading:stage:thumbW:gap:focus]body[/TIMELINE]
/// block. Same suspend-and-hand-off pattern as CardRequest. The SceneEngine
/// zooms the terminal out to parked, fades it away, slides a vertical
/// timeline panel in from the right, draws the spine, reveals events one at
/// a time in order, holds, slides out, and resumes.
///
/// The body is raw here — one event per "date | text" line. Parsing into
/// events happens in the SceneEngine, which owns the presentation.
class TimelineRequest extends PresentationRequest {
  /// Frames to hold AFTER all events have revealed (slide-in/out and the
  /// reveal sequence are extra, scene-owned).
  final int holdFrames;

  /// Panel color. Text auto-contrasts against it, same as CARD.
  final Color panelColor;

  /// H1 heading at the panel top. Empty string means no heading row.
  final String heading;

  /// OPTIONAL "center stage" sidecar: a folder inside images/ whose photos
  /// lay out as a contact sheet in a "Photos" window left of the panel.
  /// Photo i pairs with event i; a white connector line starts at the
  /// sheet's top-left, snakes across the grid, and activates each photo's
  /// border + year label at the exact frame its event reveals on the spine.
  /// Null = no stage (classic timeline).
  ///
  /// Note the tag's positional syntax: a stage segment requires a heading
  /// segment before it (five segments = heading + stage).
  final String? stageFolder;

  /// OPTIONAL thumbnail width for the stage, in logical px @ 1080p (the
  /// painter scales it for 4K). Thumbs fill left-to-right from the sheet's
  /// top-left and wrap when the next one would cross the right edge, so
  /// this value directly controls the grid shape. Null = painter default.
  /// Requires a stage segment before it (positional).
  final int? thumbW;

  /// OPTIONAL gap between thumbnails in the stage, in logical px @ 1080p.
  /// Requires a thumbW segment before it (positional).
  final int? stageGap;

  /// OPTIONAL boolean to trigger a background dimming effect.
  final bool focusMode;

  /// Multi-line body, already stripped of injected [LINE:x] markers.
  /// One event per line: "date | text", split on the first pipe. Lines
  /// with no pipe continue the previous event's text.
  final String body;

  TimelineRequest({
    required this.holdFrames,
    required this.panelColor,
    required this.heading,
    this.stageFolder,
    this.thumbW,
    this.stageGap,
    this.focusMode = false,
    required this.body,
  });
}

/// Builds a desktop-presentation hand-off from one canonical tag-regex match.
/// Returns null for non-presentation tags.
///
/// Defaults and positional interpretation live beside the request DTOs rather
/// than inside TerminalEngine.tick(), so the terminal state machine only has
/// to decide *when* a presentation suspends typing, not how every presentation
/// encodes its parameters.
/// Reads a `1,3,2` page plan off the tag.
///
/// The grammar already guarantees digits and commas, so this only has to
/// drop zeros: a page of no panels is not a page, and letting one through
/// would put an empty hold in the middle of a sequence with nothing on
/// screen to explain it.
List<int> parsePagePlan(String? raw) {
  if (raw == null || raw.isEmpty) return const [];
  final List<int> out = [];
  for (final part in raw.split(',')) {
    final int? n = int.tryParse(part.trim());
    if (n != null && n > 0) out.add(n);
  }
  return out;
}

/// Parses the optional MOSAIC pane structure segment.
///
/// Grammar (one token per pane, `;` separated):
///
///     imageCount-LR              // grouped, no Pane Life selection
///     imageCount@heroIndex-LR    // grouped + selected hero
///     imageCount@heroIndex-RL
///     imageCount-FIT             // fits the vertical edge, letterboxed
///     imageCount@heroIndex-RL-FIT
///
/// Counts are one-based in script because that is what the contact sheet
/// displays. Direction may be omitted and defaults to LR. Fit may be omitted
/// and defaults to FILL, so every token written before FIT existed parses to
/// exactly the spec it always did. Crucially, hero is
/// NOT defaulted: omitting `@heroIndex` means this pane stays static even
/// when `[CONFIG:PANELIFE:ON]` is present. Bad tokens are ignored rather than
/// making the whole APP a dud, matching R3nder's graceful degradation policy.
/// Shape of one pane token.
///
/// Public because the linter validates against it. This parser drops
/// anything that does not match, which is the right runtime behaviour and
/// the wrong authoring experience: a typo in `3@2-LX` silently collapses
/// the pane plan and the author is told nothing. One definition, so the
/// check and the parse cannot disagree about what is legal.
///
/// The suffixes are separately optional and ordered, so `1-FIT` leaves
/// the direction group null rather than being read as a direction. FILL is
/// legal input for an author who wants the default stated.
///
/// The hold tail is last and uses `+` rather than another `-`, because it
/// is the only suffix that is not a look: everything before it changes how
/// the pane is drawn, and `+45` changes how long the piece runs.
final RegExp kAppPaneToken = RegExp(
  r'^(\d+)(?:@(\d+))?(?:-(LR|RL))?(?:-(FITW|FITH|FIT|FILL))?'
  r'(?:\+(\d+(?:,\d+)*))?$',
  caseSensitive: false,
);

/// Reads the `+` tail of a pane token into per-image frame extensions.
///
/// `null` or empty gives no extension at all, which must stay distinct
/// from a list of zeros: the first emits nothing, and a script that never
/// asked for extra time should not grow a `+0` it did not write.
///
/// A single number is shorthand for "all of it on the image this pane is
/// about": the hero, or image one when no hero is nominated. A list is
/// positional and one entry per image, over-long lists truncated and short
/// ones zero-filled, so a hand edit that miscounts costs the miscounted
/// entry rather than the whole token.
List<int> _parseHolds(String? raw, int count, int? heroIndex) {
  if (raw == null || raw.trim().isEmpty) return const [];

  final List<String> parts = raw.split(',');
  final List<int> out = List<int>.filled(count, 0);

  if (parts.length == 1) {
    final int v = int.tryParse(parts[0].trim()) ?? 0;
    if (v <= 0) return const [];
    final int focus = (heroIndex ?? 0).clamp(0, count - 1).toInt();
    out[focus] = v;
    return out;
  }

  bool any = false;
  for (int i = 0; i < count && i < parts.length; i++) {
    final int v = int.tryParse(parts[i].trim()) ?? 0;
    if (v > 0) {
      out[i] = v;
      any = true;
    }
  }
  return any ? out : const [];
}

List<AppPaneSpec> parseAppPanePlan(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const [];

  final List<AppPaneSpec> out = [];
  for (final String piece in raw.split(';')) {
    final RegExpMatch? m = kAppPaneToken.firstMatch(piece.trim());
    if (m == null) continue;

    final int? count = int.tryParse(m.group(1)!);
    if (count == null || count <= 0) continue;

    final int? heroOneBased = m.group(2) == null
        ? null
        : int.tryParse(m.group(2)!);
    final PaneDirection direction =
        (m.group(3) ?? 'LR').toUpperCase() == 'RL'
            ? PaneDirection.rightToLeft
            : PaneDirection.leftToRight;
    final PaneFit fit = paneFitFromName(m.group(4) ?? 'FILL') ?? PaneFit.fill;
    final int? hero = heroOneBased == null
        ? null
        : (heroOneBased - 1).clamp(0, count - 1).toInt();
    out.add(AppPaneSpec(
      imageCount: count,
      heroIndex: hero,
      direction: direction,
      fit: fit,
      holds: _parseHolds(m.group(5), count, hero),
    ));
  }
  return out;
}

String formatAppPanePlan(List<AppPaneSpec> panes) =>
    panes.map((p) => p.toScriptToken()).join(';');

/// Resolves authored pane structure against the images that actually exist.
///
/// Every source image lands in exactly one pane. If the authored plan runs
/// short, the remainder degrades to one-image, unselected panes, so adding an
/// asset never silently opts it into motion. If it runs long, the final pane
/// is clipped to the supply and later empty panes disappear.
List<AppPaneSpec> resolveAppPanePlan(int imageCount, List<AppPaneSpec> plan) {
  if (imageCount <= 0) return const [];
  if (plan.isEmpty) {
    return List<AppPaneSpec>.generate(
      imageCount,
      (_) => const AppPaneSpec(imageCount: 1),
      growable: false,
    );
  }

  final List<AppPaneSpec> out = [];
  int placed = 0;
  int i = 0;
  while (placed < imageCount) {
    final int remaining = imageCount - placed;
    if (i >= plan.length) {
      out.add(const AppPaneSpec(imageCount: 1));
      placed++;
      continue;
    }

    final AppPaneSpec authored = plan[i++];
    final AppPaneSpec resolved = authored.normalized(remaining);
    out.add(resolved);
    placed += resolved.imageCount;
  }
  return out;
}

/// Items per MOSAIC page, resolved against the units actually present.
///
/// THE ONE COPY OF THIS RULE. The scene engine builds real pages from it and
/// the node editor shows the author what their plan will do; those two must
/// agree or the readout is a lie, so they call the same function rather than
/// each keeping a version of the arithmetic.
///
/// [plan] is advisory in both directions:
///
///  * SHORT: once exhausted, the remainder keeps chunking at [perPage], so
///    `1,3` over seven units plays 1,3,3. Adding a pane/photo and forgetting to
///    update the plan degrades rather than drops, matching how every other
///    asset mismatch in R3nder behaves.
///  * LONG: pages past the supply never happen, so `1,3,2` over four units
///    plays 1,3. A page of nothing is not a page; it would show as a hold on
///    an empty window.
///
/// A page is clamped to [perPage] because the mosaic composition is only
/// defined for one, two, or three panels. Asking for 5 gets 3.
///
/// Every image lands on exactly one page, for any plan and any count.
List<int> resolvePagePlan(int n, List<int> plan, {int perPage = 3}) {
  if (n <= 0) return const [];

  final List<int> out = [];
  int placed = 0;
  int i = 0;
  while (placed < n) {
    final int remaining = n - placed;

    int take = i < plan.length ? plan[i] : perPage;
    if (take > perPage) take = perPage;
    if (take > remaining) take = remaining;
    if (take <= 0) take = remaining < perPage ? remaining : perPage;

    out.add(take);
    placed += take;
    i++;
  }
  return out;
}

PresentationRequest? presentationRequestFromMatch(RegExpMatch match) {
  final String? galleryFolder = match.namedGroup('galFolder');
  if (galleryFolder != null) {
    return GalleryRequest(
      folder: galleryFolder,
      holdFrames: int.parse(match.namedGroup('galHold') ?? '90'),
      transition: match.namedGroup('galTrans') ?? 'CUT',
      title: match.namedGroup('galTitle'),
      isVideo: false,
    );
  }

  final String? videoFolder = match.namedGroup('vidFolder');
  if (videoFolder != null) {
    return GalleryRequest(
      folder: videoFolder,
      holdFrames: int.parse(match.namedGroup('vidHold') ?? '60'),
      transition: 'CUT',
      title: match.namedGroup('vidTitle'),
      isVideo: true,
      sourceFps: match.namedGroup('vidFps') ?? '30',
    );
  }

  final String? browserFolder = match.namedGroup('browFolder');
  if (browserFolder != null) {
    final seg = parseBrowserScrollSegment(match.namedGroup('browScroll'));
    return BrowserRequest(
      folder: browserFolder,
      holdFrames: int.parse(match.namedGroup('browHold') ?? '150'),
      title: match.namedGroup('browTitle'),
      scroll: seg.scroll,
      maximizes: seg.maximizes,
    );
  }

  final String? appFolder = match.namedGroup('appFolder');
  if (appFolder != null) {
    final layout = parseAppLayoutSegment(match.namedGroup('appLayout'));
    return AppRequest(
      folder: appFolder,
      holdFrames: int.parse(match.namedGroup('appHold') ?? '90'),
      title: match.namedGroup('appTitle'),
      layout: layout.layout,
      maximizes: layout.maximizes,
      pagePlan: parsePagePlan(match.namedGroup('appPages')),
      panePlan: parseAppPanePlan(match.namedGroup('appPanes')),
    );
  }

  final String? cardImage = match.namedGroup('cardImg');
  if (cardImage != null) {
    return CardRequest(
      image: cardImage,
      holdFrames: int.parse(match.namedGroup('cardHold') ?? '240'),
      panelColor: _parsePanelColor(match.namedGroup('cardRgb')),
      heading: (match.namedGroup('cardHead') ?? '').trim(),
      body: _cleanPresentationBody(match.namedGroup('cardBody') ?? ''),
    );
  }

  final String? dossierFolder = match.namedGroup('dosFolder');
  if (dossierFolder != null) {
    final String? lead = match.namedGroup('dosLead');
    return DossierRequest(
      folder: dossierFolder,
      image: match.namedGroup('dosImg')!,
      holdSplit: int.parse(match.namedGroup('dosHold1') ?? '120'),
      holdFull: int.parse(match.namedGroup('dosHold2') ?? '120'),
      centerMode: parseDossierCenterMode(match.namedGroup('dosCenterMode')),
      cardLead: lead == null ? 0 : int.parse(lead),
      panelColor: _parsePanelColor(match.namedGroup('dosRgb')),
      heading: (match.namedGroup('dosHead') ?? '').trim(),
      body: _cleanPresentationBody(match.namedGroup('dosBody') ?? ''),
    );
  }

  // TIMELINE has no required header segment, so its body group is the reliable
  // discriminator: the canonical regex always participates in tlBody.
  final String? timelineBody = match.namedGroup('tlBody');
  if (timelineBody != null) {
    final String? thumbW = match.namedGroup('tlThumbW');
    final String? gap = match.namedGroup('tlGap');
    return TimelineRequest(
      holdFrames: int.parse(match.namedGroup('tlHold') ?? '240'),
      panelColor: _parsePanelColor(match.namedGroup('tlRgb')),
      heading: (match.namedGroup('tlHead') ?? '').trim(),
      stageFolder: match.namedGroup('tlStage'),
      thumbW: thumbW == null ? null : int.parse(thumbW),
      stageGap: gap == null ? null : int.parse(gap),
      focusMode: match.namedGroup('tlFocus') != null,
      body: _cleanPresentationBody(timelineBody),
    );
  }

  return null;
}

Color _parsePanelColor(String? rgb) {
  if (rgb == null) return const Color.fromARGB(255, 30, 30, 38);
  final List<String> parts = rgb.split(',');
  return Color.fromARGB(
    255,
    int.parse(parts[0]),
    int.parse(parts[1]),
    int.parse(parts[2]),
  );
}

/// Removes editor-only line markers from block bodies while preserving the
/// writer's deliberate internal blank lines. Exactly one layout newline is
/// removed from each edge, matching the pre-refactor engine behavior.
String _cleanPresentationBody(String raw) {
  String s = raw.replaceAll(RegExp(r'\[LINE:\d+\]'), '');
  if (s.startsWith('\n')) s = s.substring(1);
  if (s.endsWith('\n')) s = s.substring(0, s.length - 1);
  return s;
}