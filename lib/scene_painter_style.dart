// ./lib/scene_painter_style.dart

part of 'scene_painter.dart';

// Visual constants for the simulated desktop and presentation surfaces.
// Keeping style tokens out of the painter implementation makes geometry and
// drawing behavior easier to follow without changing any rendered values.

/// Simulated window-manager styling (Ubuntu / Yaru dark). All values are in
/// logical engine pixels at 1080p and multiplied by the engine scale for 4K.
const double _kTitleBarHeight = 38.0;
const double _kWindowCornerRadius = 4.0; // Yaru is squarer than mac chrome
const double _kWindowMarginFrac = 0.06; // terminal window inset from screen edge
const double _kViewerMarginFrac = 0.10; // image viewer inset from screen edge

/// App window sits a bit tighter than the viewer — feels more "fullscreen app"
/// than "floating image viewer".
const double _kAppMarginFrac = 0.06;

/// Rounded-rect tile styling for the app grid.
const double _kAppTileRadius = 18.0;     // logical px @ 1080p, * scale for 4K
const double _kAppTileGapFrac = 0.018;   // gap between tiles as fraction of engineW
const double _kAppGridPadFrac = 0.022;   // inset from window content edges

/// MOSAIC panel styling. Deliberately not the grid's numbers.
///
/// The gap is less than half the grid's and there is no float shadow: flat
/// plates butted close together is the Metro read, and a drop shadow is the
/// Wii read. The two fight each other, so mosaic drops the shadow entirely
/// and keeps the corner rounding as the Mac note in the blend.
const double _kAppMosaicGapFrac = 0.008;
const double _kAppMosaicRadius = 14.0;

/// How far a panel rises into place as it fades in, as a fraction of frame
/// height. Metro's arrival is a short travel, not a long one.
const double _kAppMosaicRiseFrac = 0.035;

// ---------------------------------------------------------------------
// Browser window
//
// Generic on purpose. The window has to read as "a web browser" in a frame
// somebody sees for four seconds, and every actual browser's identity lives
// in a logo and a tab shape that are somebody's trademark. What is left once
// those are gone is the part that carries the meaning anyway: a tab strip, a
// back arrow, and an address bar. Those are the furniture of the medium
// rather than of any product.
//
// It sits in the Yaru palette the rest of the desktop uses. A browser drawn
// in its own colours would read as a screenshot pasted onto the desktop
// instead of as a window running on it.
// ---------------------------------------------------------------------

const double _kBrowserMarginFrac = 0.05; // window inset from screen edge
const double _kBrowserTabBarHeight = 40.0; // tab strip, logical px @ 1080p
const double _kBrowserToolbarHeight = 44.0; // address bar row
/// Active tab width, fraction of the window.
///
/// A single tab, so this is a look rather than a division of available
/// strip. 0.30 was a quarter of the frame at the window's usual inset,
/// roughly double what any browser gives one tab, and it read as a tab
/// stretched to fill rather than as a tab. The title ellipsizes, so a long
/// page name costs a cut rather than a wider tab.
const double _kBrowserTabWidthFrac = 0.20;
const double _kBrowserTabRadius = 9.0;
const double _kBrowserUrlRadius = 15.0;
const double _kBrowserTabTextSize = 14.0;
const double _kBrowserUrlTextSize = 15.0;

/// Scrollbar geometry. Present only when the capture actually overflows,
/// because a scrollbar on a page that fits is a lie about the document.
const double _kBrowserScrollbarWidth = 9.0;
const double _kBrowserScrollbarMinThumb = 34.0;

/// Load bar: a thin accent line sweeping the top of the viewport during a
/// navigation. Deliberately inside the content area rather than under the
/// toolbar, which is where every browser has put it since the throbber died.
const double _kBrowserLoadBarHeight = 3.0;

const Color _kBrowserTabBar = Color(0xFF2A2726);
const Color _kBrowserTabActive = Color(0xFF3B3735);
const Color _kBrowserTabText = Color(0xFFDAD6D2);
const Color _kBrowserTabTextDim = Color(0xFF8E8884);
const Color _kBrowserToolbar = Color(0xFF3B3735);
const Color _kBrowserUrlPill = Color(0xFF262322);
const Color _kBrowserUrlText = Color(0xFFCFCAC6);
const Color _kBrowserGlyph = Color(0xFFB6B0AC);
const Color _kBrowserAccent = Color(0xFFE95420); // Ubuntu orange
const Color _kBrowserScrollTrack = Color(0x14FFFFFF);
const Color _kBrowserScrollThumb = Color(0x4DFFFFFF);

/// Plate behind the capture. A page that does not fill its viewport shows
/// this, so it is white rather than the window's dark chrome: a letterboxed
/// screenshot should read as paper the page did not cover, not as a hole.
const Color _kBrowserPageBack = Color(0xFFF2F1EF);

/// Info-card styling (Watch-Dogs style floating card).
const double _kCardWidthFrac = 0.30;    // card width as fraction of engineW
const double _kCardTopFrac = 0.045;     // gap above the card, fraction of engineH
const double _kCardBottomFrac = 0.045;  // gap below the card, fraction of engineH
const double _kCardRightFrac = 0.022;   // gap off the right edge when seated, fraction of engineW
const double _kCardRadius = 16.0;       // corner radius, logical px @ 1080p, * scale for 4K
const double _kCardImageFrac = 0.42;    // title image height as fraction of CARD height
const double _kCardPadFrac = 0.055;     // inner text padding as fraction of card width
const double _kCardHeadingSize = 34.0;  // logical px @ 1080p, * scale for 4K
const double _kCardBodySize = 20.0;     // logical px @ 1080p, * scale for 4K

/// Dossier split-mode "browsing" scroll. In split mode the gallery is a
/// single-column strip showing TWO tiles at a time; the strip pages upward
/// one tile at a time on a fixed frame cadence — the AI is skimming the
/// evidence, not exhibiting it. The scroll is a pure function of the
/// dossier's framesIntoPhase counter, which the SceneEngine freezes at its
/// final value during dossierTransitioning, so the hand-off inherits the
/// exact scrolled positions with no snapshot state.
///
/// Scrolling is monotonic (no loop): when the strip runs out of tiles it
/// rests on the last pair until the split hold expires. Looping would risk
/// a visible position jump at the hand-off.
const int _kDossierScrollHoldFrames = 40; // frames a pair rests before paging
const int _kDossierScrollAnimFrames = 14; // frames the one-tile page-up takes

/// Timeline panel styling (vertical dossier-style timeline).
/// Wider than the card — the content is structured rows, not copy.
const double _kTlWidthFrac = 0.42;      // panel width as fraction of engineW
const double _kTlRadius = 16.0;         // corner radius, matches card
const double _kTlPadFrac = 0.055;       // inner padding as fraction of panel width
const double _kTlHeadingSize = 34.0;    // logical px @ 1080p, * scale for 4K
const double _kTlDateSize = 22.0;       // date label size
const double _kTlTextSize = 19.0;       // event body text size
const double _kTlDateColFrac = 0.19;    // date column width as fraction of panel width
const double _kTlSpineWidth = 3.0;      // spine line thickness, * scale for 4K
const double _kTlNodeRadius = 7.0;      // event node dot radius, * scale for 4K
const double _kTlEventSlidePx = 26.0;   // horizontal slide distance during event reveal

/// Center-stage (contact-sheet sidecar) styling. The stage is a Yaru-chromed
/// window ("Photos") sitting in the desktop space LEFT of the timeline
/// panel — a contact sheet of small portrait thumbnails. Thumbs fill
/// left-to-right from the sheet's TOP-LEFT and wrap to a new row when the
/// next thumb would cross the right edge (thumb width is scriptable via the
/// TIMELINE tag's sixth segment). The white connector line starts at the
/// first thumb's position and snakes BEHIND the thumbnails (draw order:
/// line, then photos, then activated borders + year plates), emerging in
/// the gaps between them.
const double _kStageMarginFrac = 0.035;   // stage window inset from screen edges, fraction of engineW
const double _kStagePanelGapFrac = 0.025; // gap between stage window and the panel's left edge
const double _kStageTileGapFrac = 0.014;  // gap between thumbnails, fraction of engineW
const double _kStagePhotoAspect = 3 / 4;  // portrait: width / height
const double _kStageDefaultThumbW = 150.0; // default thumb width, logical px @ 1080p, * scale for 4K
const double _kStageGridPadFrac = 0.020;  // grid inset from window content edges, fraction of engineW
const double _kStageTileRadius = 6.0;     // thumbnail corner radius, * scale for 4K
const double _kStageBorderWidth = 3.0;    // activated border stroke, * scale for 4K
const double _kStageLineWidth = 3.0;      // connector line thickness, * scale for 4K
const double _kStageYearSize = 15.0;      // year plate text size, * scale for 4K
// An un-activated thumbnail used to be the photo under a black overlay at
// _kStageDimOpacity. It is now an opaque plate with the photo fading in on
// top from zero, so "dim" became "absent" and the constant had nothing left
// to describe. Removed rather than left as lint noise.
const String _kStageWindowTitle = 'Photos';
const double _kStageWindowOpacity = 0.85; // translucent glassy background (0.0 to 1.0)
const double _kStageWindowBlurSigma = 12.0; // strength of the frosted glass blur

// Yaru dark palette
const Color _kHeaderBar = Color(0xFF33302F); // warm dark grey, faint aubergine cast
const Color _kHeaderText = Color(0xFFC7C3C0);
const Color _kControlCircle = Color(0xFF474341);
const Color _kControlGlyph = Color(0xFFDEDAD6);
const Color _kTerminalBody = Color(0xFF300A24); // GNOME Terminal dark purple
const Color _kViewerBody = Color(0xFF242120);
const Color _kAppBody = Color(0xFF1E1B1A); // slightly darker than viewer

/// Plate behind a mosaic panel, visible while a photo fades in and wherever
/// a photo's aspect leaves it showing through.
const Color _kAppMosaicPlate = Color(0xFF262220);

/// Fills the frame behind the panels, so the seams between them read as
/// deliberate rather than as holes onto the wallpaper.
const Color _kAppMosaicBack = Color(0xFF0E0C0B);

/// Hairline on the inside edge of a mosaic panel. Without it, two photos
/// with similar edge values butt together and read as one plate.
const Color _kAppMosaicEdge = Color(0x24FFFFFF);

// ---------------------------------------------------------------------
// Caption band
//
// The band is not drawn. It is the plate, left showing by deflating the
// rect the photograph draws into, which is why it needs no fill colour
// and inherits the panel's clip, corners, and hairline for free. The
// label sits INSIDE the panel's outline, so photo and text read as one
// blocky unit rather than a picture with a note stuck underneath it.
// ---------------------------------------------------------------------

// Caption SIZE and ALIGNMENT are no longer constants. They are authored
// per script through [CONFIG:CAPTION:...] and live on CaptionConfig in
// folder_captions.dart, with kCaptionDefaultSizePx as the fallback. What
// stays here is the geometry the author never sets: how the band relates
// to the panel it sits in.
//
// Type is still sized on `s` rather than on the panel, wherever the size
// comes from. Scaling type to panel size would produce a contact sheet
// where the same label comes out four different sizes depending on where
// the mosaic put it, which reads as inconsistency rather than hierarchy.
// Every label is the same size, and a panel that cannot afford one goes
// without.

/// Credit line, relative to the caption. Under, smaller, dimmer: the way a
/// collection line is set under a museum label.
const double _kAppCaptionCreditScale = 0.82;

/// Padding around the band's text, as a multiple of the caption size.
const double _kAppCaptionPadFrac = 0.55;

/// Most of a panel the band may take before the panel is better off with
/// no label at all. Past this the photograph has become an illustration of
/// its own caption.
const double _kAppCaptionMaxBandFrac = 0.34;

const Color _kAppCaptionText = Color(0xFFE8E4E0);
const Color _kAppCaptionCredit = Color(0xFF9A9490);