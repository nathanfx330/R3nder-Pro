// ./lib/scene_state.dart

part of 'scene_engine.dart';

// Presentation state objects used while a scene sequence is in flight.
// They remain in the scene_engine library so implementation-private state
// stays private to the compositor.

/// A gallery sequence in flight: the decoded images plus playback params.
class _ActiveGallery {
  final List<ui.Image> images;
  final int holdFrames;
  final String transition; // CUT | FADE | FLIP
  final String title; // Viewer window title bar text
  final bool isVideo; // Alters hold logic for video playback

  /// Exact source-rate ratio for VIDEO frame sampling. Unused by galleries.
  final int videoFpsNumerator;
  final int videoFpsDenominator;

  int imageIndex = 0;

  _ActiveGallery({
    required this.images,
    required this.holdFrames,
    required this.transition,
    required this.title,
    required this.isVideo,
    this.videoFpsNumerator = engineFps,
    this.videoFpsDenominator = 1,
  });
}

/// One visual MOSAIC pane. A pane may own several consecutive source images;
/// Pane Life decides which one is visible on a given deterministic frame.
class _MosaicPane {
  final List<ui.Image> images;

  /// Null means this pane has no authored Pane Life selection. The pane is
  /// still a real layout unit; it simply stays on its first image.
  final int? heroIndex;
  final PaneDirection direction;

  /// Authored scaling rule for this pane's images. Independent of Pane Life:
  /// a pane fits its vertical edge whether or not it ever moves, and whether
  /// or not `[CONFIG:PANELIFE:ON]` is present at all.
  final PaneFit fit;

  /// One record per image in [images], same index. May be shorter than
  /// [images] only if a caller built it wrong; [captionAt] tolerates that
  /// rather than throwing mid-render.
  final List<ImageCaption> captions;

  /// Extra frames per image, indexed within the pane. The only pane fact
  /// that lengthens the page.
  final List<int> holds;

  const _MosaicPane({
    required this.images,
    required this.heroIndex,
    required this.direction,
    this.fit = PaneFit.fill,
    this.captions = const [],
    this.holds = const [],
  });

  bool get hasHero => heroIndex != null;

  bool get fitsHeight => fit == PaneFit.fitHeight;

  /// Authoring fit mapped to the painter's runtime enum. The one place the
  /// two vocabularies meet.
  PaneFitMode get fitMode {
    switch (fit) {
      case PaneFit.fill:
        return PaneFitMode.fill;
      case PaneFit.fitHeight:
        return PaneFitMode.height;
      case PaneFit.fitWidth:
        return PaneFitMode.width;
    }
  }

  ImageCaption captionAt(int i) =>
      (i < 0 || i >= captions.length) ? ImageCaption.none : captions[i];

  /// Whether ANY image in this pane draws a band.
  ///
  /// The band is reserved for the whole pane, not per image. A three-image
  /// pane where only the second is captioned would otherwise resize its
  /// photo as the walk steps onto that image, and a photograph that
  /// changes size mid-shot reads as a glitch rather than as a label
  /// arriving. So the geometry is decided once for the pane and only the
  /// text swaps.
  bool get reservesBand => captions.any((c) => c.hasBand);

  int get staticImageIndex => heroIndex == null
      ? 0
      : heroIndex!.clamp(0, images.length - 1).toInt();

  /// Frames this pane adds to its page, selected or not.
  int get totalHold {
    int t = 0;
    for (final int h in holds) {
      if (h > 0) t += h;
    }
    return t;
  }

  PaneSequenceSpec get sequence => PaneSequenceSpec(
        imageCount: images.length,
        heroIndex: heroIndex,
        reverse: direction == PaneDirection.rightToLeft,
        holds: holds,
      );
}

/// An app-window sequence in flight: up to 9 decoded images, the panel
/// layout they render into, and cascade/hold/pan configuration.
///
/// LAYOUT CONTRACT WITH THE PAINTER
///
/// GRID keeps [gridCols] / [gridRows] and the painter's original tile
/// arithmetic, which distributes the gap BETWEEN tiles only, leaving the
/// outer edges flush. That arithmetic cannot be expressed as unit cells with
/// a uniform inset (it coincides at two columns and diverges at three, since
/// interior tiles lose a whole gap while edge tiles lose half), so it is left
/// exactly as it was. GRID renders byte-identical to before this existed.
///
/// MOSAIC instead carries [pages]: lists of unit rects in 0..1 space that
/// tile the content area edge to edge. The painter maps each into the grid
/// area and deflates it uniformly by half the mosaic gap. Panels are unequal
/// by design, so there is no uniformity to preserve and the simple rule is
/// the correct one.
class _ActiveApp {
  final List<ui.Image> images;
  final int holdFrames; // Hold AFTER cascade completes, per page in MOSAIC
  final String title;
  final AppLayout layout;

  /// Whether the window grows out to the whole frame once open. Independent
  /// of [layout]: a mosaic can stay a desktop window, and the maximize is a
  /// window behavior rather than a property of the composition.
  final bool maximizes;

  /// GRID only: the adaptive grid shape picked from images.length in setup.
  final int gridCols;
  final int gridRows;

  /// MOSAIC only: panel geometry per page, in unit space. Empty for GRID.
  ///
  /// Not final because a SLIDE app switch appends the next APP tag's pages
  /// onto this window rather than opening a second one.
  List<List<Rect>> pages;

  /// MOSAIC only: authored panes grouped to match [pages]. A pane can own
  /// one or several source images. Empty for GRID.
  List<List<_MosaicPane>> pagePanes;

  /// Base hold for each page, before pane extensions.
  ///
  /// A list rather than the single [holdFrames] because pages can now come
  /// from different APP tags: `[APP:canada:60:...]` followed by
  /// `[APP:brazil:90:...]` under APPSWITCH:SLIDE is one window whose pages
  /// were authored with different holds, and each must keep the one it was
  /// written with.
  ///
  /// Empty means "every page uses [holdFrames]", which is every script
  /// that never switches.
  List<int> pageBaseHold;

  /// Window title for each page, for the same reason. Empty means every
  /// page uses [title].
  List<String> pageTitle;

  /// Pane life settings for this sequence. CONFIG enables the capability;
  /// individual panes still require an explicit hero to move.
  final PaneLifeConfig paneLife;

  /// Motion plan for the page currently held, rebuilt on every page entry.
  ///
  /// Built once per page rather than per frame. Page geometry, the cascade
  /// length, and the hold are all fixed the moment a page is entered, so
  /// there is nothing per-frame to recompute except the ramp evaluation
  /// itself.
  PanePlan panePlan = PanePlan.disabled;

  /// Page currently held. During a pan this is the OUTGOING page, and the
  /// incoming one is pageIndex + 1. Always 0 for GRID.
  int pageIndex = 0;

  _ActiveApp({
    required this.images,
    required this.holdFrames,
    required this.title,
    required this.layout,
    required this.maximizes,
    required this.gridCols,
    required this.gridRows,
    this.pages = const [],
    this.pagePanes = const [],
    this.paneLife = PaneLifeConfig.off,
    this.pageBaseHold = const [],
    this.pageTitle = const [],
  }) {
    rebuildPanePlan();
  }

  /// Appends [next]'s pages onto this window: the SLIDE app switch.
  ///
  /// The whole feature is this method plus the decision to call it. Two
  /// adjacent APP tags stop being two windows opening and closing and
  /// become one window with more pages, which means the existing page pan
  /// carries the transition. Nothing new is drawn, nothing new is timed,
  /// and the bake stays deterministic because it is the same machinery
  /// that already turns pages.
  ///
  /// Per-page hold and title lists are materialised on first absorb rather
  /// than always carried, so a script that never switches allocates
  /// nothing and behaves exactly as it did.
  void absorb(_ActiveApp next) {
    final int hadPages = pages.length;

    // growable: true is load-bearing. List.filled is FIXED LENGTH, so the
    // adds below throw UnsupportedError on the first absorb of any script,
    // which the editor warm-up swallows into a simulation that never
    // completes and a spinner that never stops.
    final List<int> holds = pageBaseHold.isEmpty
        ? List<int>.filled(hadPages, holdFrames, growable: true)
        : List<int>.from(pageBaseHold);
    final List<String> titles = pageTitle.isEmpty
        ? List<String>.filled(hadPages, title, growable: true)
        : List<String>.from(pageTitle);

    for (int i = 0; i < next.pages.length; i++) {
      holds.add(next.holdFrames);
      titles.add(next.title);
    }

    pages = [...pages, ...next.pages];
    pagePanes = [...pagePanes, ...next.pagePanes];
    pageBaseHold = holds;
    pageTitle = titles;
  }

  /// Base hold for [page], falling back to the script's single value.
  int baseHoldFor(int page) => (page >= 0 && page < pageBaseHold.length)
      ? pageBaseHold[page]
      : holdFrames;

  /// Title for [page].
  String titleFor(int page) =>
      (page >= 0 && page < pageTitle.length) ? pageTitle[page] : title;

  bool get isMosaic => layout == AppLayout.mosaic;

  /// Frames the panes on [page] add to that page's hold.
  ///
  /// Summed across every pane on the page, selected or not. Selected panes
  /// run one after another inside the hold rather than together, so their
  /// extensions add rather than overlapping, and an extension on an
  /// unselected pane is simply more time spent on a still image.
  int pageHoldBonus(int page) {
    if (!isMosaic || page < 0 || page >= pagePanes.length) return 0;
    int t = 0;
    for (final p in pagePanes[page]) {
      t += p.totalHold;
    }
    return t;
  }

  /// Hold for the page currently on screen: the script's hold plus whatever
  /// that page's panes authored.
  ///
  /// THE ONE PLACE DURATION CHANGES. [holdFrames] stays the base value the
  /// script asked for, and every consumer that decides when a page ends
  /// reads this instead. Deliberately independent of [paneLife]: if
  /// extensions only applied while Pane Life was enabled, the exporter's
  /// neutrality audit would disable Pane Life, re-tick, watch the frame
  /// count move, and correctly report a defect.
  int get currentHoldFrames =>
      baseHoldFor(pageIndex) + pageHoldBonus(pageIndex);

  /// Rebuilds [panePlan] for the current page.
  ///
  /// Called on construction and on every page advance. GRID never gets a
  /// plan: its tile arithmetic is preserved byte for byte by contract, and
  /// pane life is a mosaic feature.
  void rebuildPanePlan() {
    if (!isMosaic || !paneLife.enabled) {
      panePlan = PanePlan.disabled;
      return;
    }
    panePlan = PanePlan.build(
      config: paneLife,
      panes: pageIndex < pagePanes.length
          ? pagePanes[pageIndex].map((p) => p.sequence).toList()
          : const [],
      cascadeFrames: cascadeTotalFrames,
      // BASE hold for THIS page, not the extended one and not the
      // script-wide scalar. The plan adds each pane's own extension to its
      // own slot, so handing it the grown figure would pay for the same
      // frames twice; and after a SLIDE absorb the pages on this window
      // came from tags with different holds, so the scalar would time a
      // brazilpaper page against canada's hold.
      holdFrames: baseHoldFor(pageIndex),
    );

    // THE INVARIANT THIS FEATURE RESTS ON. Motion must finish inside the
    // budget the page already owned, because a page advances on
    // cascadeTotalFrames + holdFrames and that sum is what every existing
    // bake was timed against. If motion could outlast it, turning pane
    // life on would silently re-time every finished piece.
    assert(() {
      if (!panePlan.isActive) return true;
      final int budget = cascadeTotalFrames + currentHoldFrames;
      for (int i = 0; i < panePlan.starts.length; i++) {
        if (panePlan.starts[i] + panePlan.durations[i] > budget) return false;
      }
      return true;
    }(), 'Pane motion overruns the page budget; frame counts would move.');
  }

  /// Motion/frame evaluation at explicit age inside appShowing.
  PaneFrame paneFrameAt(int i, int frames) => panePlan.frameAt(i, frames);

  int get pageCount => isMosaic ? pages.length : 1;

  /// Panels on the page currently held.
  int get tileCount {
    if (!isMosaic) return images.length;
    return pageIndex < pages.length ? pages[pageIndex].length : 0;
  }

  bool get hasMorePages => pageIndex + 1 < pageCount;

  /// Total frames of the cascade reveal on the current page (last panel's
  /// fade-in end). Pages after the first arrive already revealed, carried in
  /// by the pan itself, so their cascade is zero-length. Stacking a fade on
  /// top of a slide reads as two competing animations.
  ///
  /// GRID never advances past page 0, so this is unchanged for it.
  int get cascadeTotalFrames {
    if (pageIndex > 0) return 0;
    final int n = tileCount;
    if (n <= 0) return 0;
    return (n - 1) * kAppCascadeStagger + kAppCascadeTileFade;
  }

  /// 0..1 opacity of panel [i] at explicit age inside appShowing.
  /// Reading order, so the visible sweep runs diagonally. Always 1.0 on
  /// pages after the first, per [cascadeTotalFrames].
  double tileOpacityAt(int i, int frames) {
    if (pageIndex > 0) return 1.0;
    final int start = i * kAppCascadeStagger;
    final int local = frames - start;
    if (local <= 0) return 0.0;
    if (local >= kAppCascadeTileFade) return 1.0;
    return local / kAppCascadeTileFade;
  }
}

/// A browser sequence in flight: page captures plus the addresses that go
/// with them, and the per-page timing.
///
/// Per-page lists rather than scalars for the same reason [_ActiveApp]
/// carries them: under `[CONFIG:APPSWITCH:SLIDE]` a second BROWSER tag
/// becomes more pages of this window rather than a second window, and each
/// page has to keep the hold, the title, and the scroll mode it was written
/// with. A script that never switches has one value repeated and behaves
/// exactly as it reads.
class _ActiveBrowser {
  /// Page captures, one per page, in folder order.
  List<ui.Image> images;

  /// Address and page title per page, resolved positionally alongside the
  /// decode. Same index as [images] by construction, never by lookup.
  List<ImageCaption> sources;

  List<int> pageHold;
  List<String> pageTitle;
  List<BrowserScroll> pageScroll;

  /// Whether this window fills the frame. A property of the WINDOW, which is
  /// why it is one bool beside four per-page lists.
  ///
  /// That asymmetry is the whole point of splitting the scroll segment. Fit
  /// is per page because a SLIDE run can join a scrolling tag to a fitted one
  /// and a browser that scrolls one page and not the next is just a browser.
  /// Size is not: a window cannot be windowed on page two and full on page
  /// three without a resize nobody asked for and nothing animates. So a tag
  /// whose maximize state differs is refused by [absorb]'s caller and opens
  /// as its own window instead.
  ///
  /// Not final only because it is set at composition; nothing mutates it once
  /// the window is live.
  final bool maximizes;

  int pageIndex = 0;

  _ActiveBrowser({
    required this.images,
    required this.sources,
    required this.pageHold,
    required this.pageTitle,
    required this.pageScroll,
    this.maximizes = false,
  });

  /// Appends [next]'s pages onto this window: the browser's half of the
  /// SLIDE switch.
  ///
  /// Note what it is NOT: a pan. The app window slides because its pages
  /// are panels of one surface, and sliding is what a Metro panorama does.
  /// A browser's pages are separate documents that happen to be visited in
  /// order, so the join between two tags is the same navigation as the join
  /// between two images inside one tag. That makes absorbing here cheaper
  /// than it is for the app window: no new geometry and no new timing.
  ///
  /// It is not free of a compatibility test, though it was once. [maximizes]
  /// is deliberately not merged here, because it cannot be: the lists below
  /// grow per page and a window has exactly one size. The caller tests it
  /// before calling and declines the absorb when it differs, which is why
  /// this method can assume every page it appends belongs in a window the
  /// shape of the one already open.
  void absorb(_ActiveBrowser next) {
    images = [...images, ...next.images];
    sources = [...sources, ...next.sources];
    pageHold = [...pageHold, ...next.pageHold];
    pageTitle = [...pageTitle, ...next.pageTitle];
    pageScroll = [...pageScroll, ...next.pageScroll];
  }

  int get pageCount => images.length;

  bool get hasMorePages => pageIndex + 1 < pageCount;

  ui.Image? get currentImage =>
      (pageIndex >= 0 && pageIndex < images.length) ? images[pageIndex] : null;

  /// The capture arriving during a navigation, or null on the last page.
  ui.Image? get nextImage => (pageIndex + 1 < images.length)
      ? images[pageIndex + 1]
      : null;

  ImageCaption sourceAt(int page) =>
      (page >= 0 && page < sources.length) ? sources[page] : ImageCaption.none;

  int holdAt(int page) =>
      (page >= 0 && page < pageHold.length) ? pageHold[page] : 90;

  String titleAt(int page) => (page >= 0 && page < pageTitle.length)
      ? pageTitle[page]
      : kDefaultBrowserTitle;

  BrowserScroll scrollAt(int page) => (page >= 0 && page < pageScroll.length)
      ? pageScroll[page]
      : BrowserScroll.scroll;

  int get currentHold => holdAt(pageIndex);

  BrowserScroll get currentScroll => scrollAt(pageIndex);

  /// How far down the page the viewport has travelled, 0..1, at [frames]
  /// inside this page's hold.
  ///
  /// Pure function of [frames] and the page's own hold. The travel is carved
  /// out of a hold the page already owned, so a capture twenty screens tall
  /// costs exactly the same frames as one that fits. The painter multiplies
  /// this by whatever overflow the capture actually has once it knows the
  /// viewport.
  ///
  /// Returns 0 for TOP and FIT, and for a hold too short to travel legibly.
  /// Skipped rather than sped up: a scroll crammed into fifteen frames is not
  /// a fast read, it is a flicker.
  double scrollTAt(int frames) {
    if (currentScroll != BrowserScroll.scroll) return 0.0;
    final int hold = currentHold;
    if (hold <= 0) return 0.0;

    final int dwell = (hold * kBrowserScrollDwellFrac).round();
    final int travel = hold - dwell * 2;
    if (travel < kBrowserMinScrollFrames) return 0.0;

    final double t =
        ((frames - dwell) / travel).clamp(0.0, 1.0).toDouble();
    return applyEase(Ease.easeInOut, t);
  }
}

/// An info-card sequence in flight: the decoded title image plus the text
/// content and panel color snapshotted from the [CARD] block.
class _ActiveCard {
  /// Title image at the top of the card. Null if it failed to load — the
  /// card still plays, just with the panel color running full height.
  final ui.Image? image;

  final int holdFrames;
  final Color panelColor;
  final String heading;
  final String body;

  _ActiveCard({
    required this.image,
    required this.holdFrames,
    required this.panelColor,
    required this.heading,
    required this.body,
  });
}

class _ActiveDossier {
  final List<ui.Image> images;
  final ui.Image? titleImage;
  final int holdSplit;
  final int holdFull;
  final DossierCenterMode centerMode;

  /// MOSAIC only: the same deterministic three-panels-per-page geometry
  /// used by APP:MOSAIC. Empty for GRID and SIDE_ONLY.
  final List<List<Rect>> mosaicPages;
  final List<List<ui.Image>> mosaicPageImages;
  int mosaicPageIndex = 0;

  /// Frames the card sits alone, fully seated, before the gallery window
  /// opens next to it. 0 = card and gallery arrive together (classic).
  final int cardLead;

  final Color panelColor;
  final String heading;
  final String body;

  _ActiveDossier({
    required this.images,
    required this.titleImage,
    required this.holdSplit,
    required this.holdFull,
    required this.centerMode,
    this.mosaicPages = const [],
    this.mosaicPageImages = const [],
    this.cardLead = 0,
    required this.panelColor,
    required this.heading,
    required this.body,
  });

  bool get hasMoreMosaicPages =>
      centerMode == DossierCenterMode.mosaic &&
      mosaicPageIndex + 1 < mosaicPages.length;
}

/// One parsed timeline event: the date label left of the spine node, and
/// the descriptive text to its right.
class TimelineEvent {
  final String date;
  final String text;

  TimelineEvent({required this.date, required this.text});
}

/// A timeline sequence in flight: parsed events plus reveal/hold configuration
/// snapshotted from the [TIMELINE] block. Optionally carries a "center stage"
/// contact sheet paired 1:1 with events. All reveal evaluation lives on the
/// SceneEngine's explicit phase age, so no mutable timeline clock is stored.
class _ActiveTimeline {
  final List<TimelineEvent> events;
  final int holdFrames; // Hold AFTER all events revealed
  final Color panelColor;
  final String heading;

  /// Stage photos. Empty = no stage (classic timeline). photos[i] pairs
  /// with events[i]; if counts differ, only min(count) pairs animate and
  /// the remainder was warned about at activation.
  final List<ui.Image> stagePhotos;

  /// Scripted thumbnail width for the stage, in logical px @ 1080p (the
  /// painter multiplies by scale). Null = painter default.
  final int? stageThumbW;

  /// Scripted gap between thumbnails in logical px @ 1080p.
  final int? stageGap;

  /// Whether the background dimming effect is active.
  final bool focusMode;

  _ActiveTimeline({
    required this.events,
    required this.holdFrames,
    required this.panelColor,
    required this.heading,
    this.stagePhotos = const [],
    this.stageThumbW,
    this.stageGap,
    this.focusMode = false,
  });

  /// Total frames of the reveal (spine + last event's fade-in end).
  int get revealTotalFrames =>
      kTlSpineFrames + (events.length - 1) * kTlEventStagger + kTlEventFade;

  /// Number of photo<->event pairs that animate.
  int get stagePairCount =>
      stagePhotos.length < events.length ? stagePhotos.length : events.length;

  /// Parses raw block body into events. One event per "date | text" line,
  /// split on the FIRST pipe. A line with no pipe continues the previous
  /// event's text (joined with a newline). Blank lines are skipped. A
  /// pipeless line with no previous event becomes a dateless event.
  static List<TimelineEvent> parseBody(String body) {
    final List<TimelineEvent> out = [];
    for (final rawLine in body.split('\n')) {
      final String line = rawLine.trim();
      if (line.isEmpty) continue;

      final int pipe = line.indexOf('|');
      if (pipe >= 0) {
        out.add(TimelineEvent(
          date: line.substring(0, pipe).trim(),
          text: line.substring(pipe + 1).trim(),
        ));
      } else if (out.isNotEmpty) {
        final last = out.removeLast();
        out.add(TimelineEvent(
          date: last.date,
          text: '${last.text}\n$line',
        ));
      } else {
        out.add(TimelineEvent(date: '', text: line));
      }
    }
    return out;
  }
}