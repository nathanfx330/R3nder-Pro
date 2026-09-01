// ./lib/parser.dart

/// Dart regex group names must be alphanumeric, so Python's `b_w` became `bW`, etc.
/// Also, Dart uses `(?<name>...)` instead of Python's `(?P<name>...)` for named groups.
/// Removed the '^' anchor so `matchAsPrefix` works correctly at index > 0.
final RegExp tagRegex = RegExp(
  r'\[(?:'
  r'(?<wipe>WIPE)|'
  r'LINE:(?<line>\d+)|'
  r'PAUSE:(?<pause>\d+)|'
  r'SPEED:(?<speed>\d+|MAX)|'
  r'SIZE:(?<size>\d+|DEFAULT)|'
  r'LEAD:(?<lead>\d+|DEFAULT)|'
  r'VPAD:(?<vpad>\d+)|'
  r'ALIGN:(?<align>LEFT|CENTER|RIGHT)|'
  r'BAR:(?<bW>\d+):(?<bF>\d+)(?::(?<bFill>[^:]*))?(?::(?<bEmpty>[^:]*))?(?::(?<bBrack>\[\]|[^\]]*))?|'
  r'(?<redact>/?REDACT)|'
  r'SCRAMBLE:(?<scramble>on|off)|'
  r'INVERT:(?<invert>on|off)|'
  r'FLASH:(?<flash>INVERT|SPIKE|RED|GREEN|YELLOW|WAVE|OFF)|'
  // Desktop flow: suspends the terminal, pages through every image in
  // images/<folder>/ (hold = frames per image, default 90; transition =
  // CUT | FADE | FLIP, default CUT; title = viewer window title bar text,
  // e.g. a fake document filename — default "Image Viewer"), then resumes.
  r'GALLERY:(?<galFolder>[a-zA-Z0-9_\-/]+)(?::(?<galHold>\d+))?(?::(?<galTrans>CUT|FADE|FLIP))?(?::(?<galTitle>[^:\]]+))?|'
  r'VIDEO:(?<vidFolder>[a-zA-Z0-9_\-/]+)(?::(?<vidHold>\d+))?(?::(?<vidTitle>[^:\]]+))?(?::(?<vidFps>23\.976|24|25|29\.97|30|50|59\.94|60))?|'
  // Desktop browser flow: suspends the terminal, zooms out to the desktop,
  // and opens a generic web-browser window holding page screenshots. One
  // image per page; a page turn is a NAVIGATION (address bar cuts to the
  // next URL, a load bar sweeps the top of the viewport) rather than a
  // gallery's fade, because that is the only transition a browser has.
  //
  // folder = subfolder of images/ holding the screenshots, in .r3nder_order.
  // hold   = frames per page (default 150). Longer than a gallery's default
  //          on purpose: a page that scrolls has to be readable while it
  //          moves, and 90 frames of travel down a full-page capture reads
  //          as a swipe rather than as reading.
  // title  = window title bar text (default "Web Browser").
  // scroll = SCROLL (default) | TOP | FIT, each with an optional _FULL
  //          suffix. How the capture meets a viewport it almost never
  //          matches:
  //            SCROLL : fit the WIDTH, top-anchored, then pan down through
  //                     the overflow inside the hold the page already owns.
  //            TOP    : fit the width and hold above the fold. No motion.
  //            FIT    : contain the whole capture in the viewport, letterboxed
  //                     against the page plate. For a short page or a phone
  //                     capture, where a scroll would have nowhere to go.
  //          The _FULL suffix is a WINDOW modifier, not a fitting rule, and
  //          it is spelled this way because [APP] already spells it this
  //          way. MOSAIC_FULL is one segment carrying two facts, split
  //          apart the moment it is parsed rather than in the grammar; this
  //          is the same shape applied to the only enumerated segment a
  //          browser has. A new positional tail would have been the other
  //          option and it is the wrong one: the language already has a
  //          word for "this window fills the frame", and inventing a second
  //          one means two spellings of one idea.
  //          The split matters downstream. Fit is a PER PAGE fact and rides
  //          in the page list, exactly as it does today; maximize is a
  //          property of the WINDOW, so it also joins the compatibility
  //          test that decides whether APPSWITCH:SLIDE may absorb the next
  //          tag. A windowed browser cannot absorb a full one, for the same
  //          reason a windowed mosaic cannot: that is not a navigation, it
  //          is a different window.
  //          Longest alternatives first. SCROLL would otherwise match the
  //          head of SCROLL_FULL and strand the suffix, failing the whole
  //          tag, which is the identical hazard the APP layout segment
  //          documents.
  //
  // WHAT IS DELIBERATELY NOT HERE: the URL and the page title. Neither can
  // live in a tag segment, because the grammar splits on ':' and a URL
  // spends two colons and a pair of slashes before it says anything. That
  // is the same wall captions hit, and it lands on the same answer: they
  // are facts about the screenshot rather than choices about the shot, so
  // they live in the folder's .r3nder_captions sidecar (columns 5 and 6)
  // and travel with the images. The same capture used in two films carries
  // the same address in both.
  r'BROWSER:(?<browFolder>[a-zA-Z0-9_\-/]+)(?::(?<browHold>\d+))?(?::(?<browTitle>[^:\]]+))?(?::(?<browScroll>SCROLL_FULL|SCROLL|TOP_FULL|TOP|FIT_FULL|FIT))?|'
  // Desktop app flow: suspends the terminal, zooms out to the desktop, opens
  // a fullscreen app window containing a rounded-rect image layout, reveals
  // the tiles in a staggered cascade, holds, then closes and returns to the
  // terminal.
  // hold   = frames to hold AFTER the cascade completes (default 90). In
  //          MOSAIC this is per page, the way GALLERY's hold is per image.
  // title  = window title bar text (default "App").
  // layout = GRID | MOSAIC | MOSAIC_FULL (default GRID).
  //          GRID        : the original adaptive uniform grid, 1x1 / 1x2 /
  //                        1x3 / 2x2 / 2x3 / 3x3 by image count, capped at 9.
  //          MOSAIC      : Metro-style unequal panels built by recursive
  //                        halving, 3 per page, panning to reach the rest.
  //          MOSAIC_FULL : the same composition, but the window maximizes
  //                        out to the whole frame once open and restores to
  //                        its desktop rect on the way out.
  // The _FULL suffix is a window modifier, not a layout. Composition and
  // window behavior are separate questions and read better kept apart.
  // layout is positional behind title, so a layout requires a title.
  // Longest alternatives first: GRID would otherwise match the head of
  // GRID_FULL and strand the suffix, failing the whole tag.
  // pages  = optional comma list of PANES per page, e.g. 1,3,2. MOSAIC only.
  //          A page break costs a hold plus a pan, so paging is a TIMING
  //          construct, which is why it lives in the tag rather than beside
  //          the folder: a reader has to be able to count the frames off
  //          this line. Order, which changes no timing, lives in the
  //          folder's .r3nder_order manifest instead.
  //          Runs short: the remainder chunks at the layout default, so
  //          1,3 over seven panes plays 1,3,3. Adding a pane and
  //          forgetting the plan degrades rather than drops.
  //          Runs long: pages past the supply never happen. 1,3,2 over four
  //          panes plays 1,3.
  //          Positional behind layout, so pages require a layout.
  // panes  = optional authored image grouping for Pane Life. Semicolon
  //          separated tokens: count@hero-LR or count@hero-RL. Example:
  //          3@2-LR;1@1-LR;2@2-RL. Counts consume consecutive images from
  //          the folder order. Hero is 1-based within its pane. Omitted
  //          means the legacy one-image-per-pane behavior. Positional after
  //          pages, so authored panes require an explicit page segment
  //          (normally 3, which is the existing implicit default).
  r'APP:(?<appFolder>[a-zA-Z0-9_\-/]+)(?::(?<appHold>\d+))?(?::(?<appTitle>[^:\]]+))?(?::(?<appLayout>MOSAIC_FULL|MOSAIC|GRID))?(?::(?<appPages>\d+(?:,\d+)*))?(?::(?<appPanes>[^\]]+))?|'
  // Desktop dynamic dossier flow: info card enters (optionally alone),
  // browsing gallery joins it side-by-side, then the scripted center mode
  // either takes the gallery center-stage or exits the side layout directly.
  // [DOSSIER:suspect_photos:mugshot.png:120:120:45:MOSAIC:180,40,50:TARGET PROFILE] body [/DOSSIER]
  // folder   = images/folder to load for the gallery
  // image    = images/file to load for the info card
  // hold1    = frames to hold in split mode (card + gallery side by side).
  // hold2    = frames to hold after gallery takes center stage.
  // cardLead = OPTIONAL frames the card sits alone, fully seated, before
  //            the gallery window opens next to it (default 0 = card and
  //            gallery arrive together, the classic behavior). Introduce
  //            the subject, then reveal the evidence.
  //            NOTE: segments are positional — a cardLead requires hold1
  //            and hold2 before it.
  // center   = OPTIONAL second-stage behavior after the side hold:
  //            GRID (legacy/default), MOSAIC, or SIDE_ONLY. The layout
  //            segment sits before color; old tags still parse because an
  //            RGB triplet cannot match one of these keywords.
  r'DOSSIER:(?<dosFolder>[a-zA-Z0-9_\-/]+):(?<dosImg>[a-zA-Z0-9_\-\./]+)(?::(?<dosHold1>\d+))?(?::(?<dosHold2>\d+))?(?::(?<dosLead>\d+))?(?::(?<dosCenterMode>GRID|MOSAIC|SIDE_ONLY))?(?::(?<dosRgb>\d+,\d+,\d+))?(?::(?<dosHead>[^:\]]+))?\](?<dosBody>[\s\S]*?)\[/DOSSIER|'
  // Desktop info-card flow: suspends the terminal, zooms out to the desktop,
  // fades the parked terminal away, and slides a presentation panel in from
  // the right edge — title image on top, colored text block below with an
  // H1 heading and body copy. Holds, slides out, terminal fades back, resumes.
  //
  //   [CARD:mark_07.png:240:180,40,50:TARGET PROFILE]
  //   Aiden Pearce. Fixer.
  //   Threat index: HIGH.
  //   [/CARD]
  //
  //   image   = file inside images/ (required)
  //   hold    = frames to hold fully open (optional, default 240)
  //   r,g,b   = text-block panel color (optional, default 30,30,38)
  //   heading = H1 title text (optional, default empty)
  //   body    = everything between the tags, rendered as multi-line copy.
  //             Never touches the typing engine — the whole block is
  //             consumed as a single tag match.
  r'CARD:(?<cardImg>[a-zA-Z0-9_\-\./]+)(?::(?<cardHold>\d+))?(?::(?<cardRgb>\d+,\d+,\d+))?(?::(?<cardHead>[^:\]]+))?\](?<cardBody>[\s\S]*?)\[/CARD|'
  // Desktop timeline flow: suspends the terminal, zooms out to the desktop,
  // fades the parked terminal away, and slides a vertical timeline panel in
  // from the right edge. The spine draws top-to-bottom, then events reveal
  // one at a time in chronological order (node pops, date + text fade in),
  // holds, slides out, terminal fades back, resumes.
  //
  //   [TIMELINE:240:250,60,50:OPERATION HISTORY:yearbook:120:40]
  //   1994 | Company founded in Detroit
  //   1999 | First federal contract
  //   2003 | Whistleblower memo drafted
  //   [/TIMELINE]
  //
  //   hold    = frames to hold AFTER all events revealed (optional, default 240)
  //   r,g,b   = panel color (optional, default 30,30,38); text auto-contrasts
  //   heading = H1 title text (optional, default empty)
  //   stage   = OPTIONAL "center stage" sidecar: a folder inside images/
  //             whose photos lay out as a contact sheet in a "Photos"
  //             window left of the panel. Photo i pairs with event i in
  //             order; a white connector line starts at the sheet's
  //             top-left, snakes across the grid, and activates each
  //             photo's border + year label at the exact frame its event
  //             reveals on the spine. Extra photos or extra events are
  //             warned about and left unpaired.
  //             NOTE: the segments are positional, so a stage REQUIRES a
  //             heading — [TIMELINE:240:250,60,50:photos] parses "photos"
  //             as the heading. Five segments = heading + stage.
  //   thumbW  = OPTIONAL thumbnail width in logical px @ 1080p (scaled at
  //             4K). Thumbs fill left-to-right from the sheet's top-left
  //             and wrap to a new row when the next thumb would cross the
  //             right edge — so this value directly controls the grid
  //             shape. Default 150. Requires a stage segment before it.
  //   gap     = OPTIONAL gap between thumbnails in logical px @ 1080p.
  //             Requires the thumbW segment before it.
  //   focus   = OPTIONAL keyword to dim the background. Requires the gap segment.
  //   body    = one event per line, "date | text", split on the FIRST pipe.
  //             A line with no pipe continues the previous event's text.
  //             Never touches the typing engine — the whole block is
  //             consumed as a single tag match.
  r'TIMELINE(?::(?<tlHold>\d+))?(?::(?<tlRgb>\d+,\d+,\d+))?(?::(?<tlHead>[^:\]]+))?(?::(?<tlStage>[a-zA-Z0-9_\-/]+))?(?::(?<tlThumbW>\d+))?(?::(?<tlGap>\d+))?(?::(?<tlFocus>FOCUS))?\](?<tlBody>[\s\S]*?)\[/TIMELINE|'
  // IN-TERMINAL SVG stencil flow. This never leaves the terminal screen —
  // no desktop, no window chrome, no zooms. The engine wipes the screen,
  // shows the SVG scaled-to-fit inside the margins for `hold` frames, wipes
  // again, and resumes typing.
  //
  //   [SVG:logo.svg:60]           — wipe, show 60 frames in pen color, wipe
  //   [SVG:logo.svg:60:255,50,50] — same, but filled in a tagged color
  //
  //   file  = .svg file inside images/ (required)
  //   hold  = frames to hold on screen (optional, default 60)
  //   r,g,b = fill color override (optional, default = current pen color,
  //           so the stencil is on-theme automatically)
  //
  //   CHAINING: consecutive [SVG] tags CUT between each other — the entry
  //   wipe plays once at the start of the run and the exit wipe once at the
  //   end, so [SVG:a.svg:20][SVG:b.svg:20] reads as one continuous sequence.
  //
  // NOTE: SVGFLASH is listed BEFORE SVG so the alternation can't ever be
  // shadowed by a shorter prefix.
  //
  // Boot-logo flicker: cycles through every .svg in images/<folder>/
  // (sorted by filename) at `framesPer` frames each, looping the whole
  // folder `cycles` times. Same wipe-in/wipe-out framing as [SVG].
  //
  //   [SVGFLASH:bootlogos:4:3]           — each logo 4 frames, 3 loops
  //   [SVGFLASH:bootlogos:4:3:0,255,120] — same, tagged fill color
  //
  //   folder    = folder inside images/ containing .svg files (required)
  //   framesPer = frames per logo (optional, default 4)
  //   cycles    = full loops through the folder (optional, default 3)
  //   r,g,b     = fill color override (optional, default = pen color)
  r'SVGFLASH:(?<svgfFolder>[a-zA-Z0-9_\-/]+)(?::(?<svgfFrames>\d+))?(?::(?<svgfCycles>\d+))?(?::(?<svgfRgb>\d+,\d+,\d+))?|'
  r'SVG:(?<svgFile>[a-zA-Z0-9_\-\./]+)(?::(?<svgHold>\d+))?(?::(?<svgRgb>\d+,\d+,\d+))?|'
  // IN-TERMINAL crude photo scan: fullscreen 1-bit raster stencil.
  //   [PHOTO:suspect.png:120]              — wipe, hold 120, R channel, pen tint
  //   [PHOTO:suspect.png:120:G]            — mask from green channel
  //   [PHOTO:suspect.png:120:G:255,0,0]    — tint override
  //   [PHOTO:suspect.png:120:G:255,0,0:25] — release the gate at 25% of the scan
  //
  // Uses the same thresholding engine as IMG, but fits to the margins and
  // reveals top-to-bottom over 1 second to simulate a slow wirephoto scan.
  // Max resolution is 1024x1024 (use high contrast/posterization, not fine dither).
  //
  //   STACKING / ONION LAYERS: a PHOTO that fires while another PHOTO is
  //   still on screen PUSHES onto the stack instead of replacing it — the
  //   new layer scans in top-to-bottom directly OVER the previous ones,
  //   which remain fully visible. Off-pixels draw nothing, so lower layers
  //   show through the gaps of upper ones. The layers share ONE tint (same
  //   phosphor); the layering reads through GEOMETRY alone — a solid 3D
  //   mesh, then its wireframe/edge pass scanning in over it in the same
  //   color, building up structure like passes on a single-color tube. All
  //   stacked layers persist until an explicit [WIPE] (or a scroll-wipe /
  //   chained SVG takeover) clears the whole stack at once.
  //
  //   release = OPTIONAL % of THIS layer's own scanline reveal at which the
  //             typing gate opens (0..100), letting the NEXT PHOTO (or typed
  //             text/tag) begin while this layer is still scanning in behind
  //             it. Omitted (or >= 100) blocks until this layer has fully
  //             scanned — the classic exclusive behavior, so every existing
  //             PHOTO script is byte-identical.
  //             NOTE: positional — a release requires channel AND rgb
  //             segments before it (e.g. [PHOTO:mesh.png:120:R:0,255,0:25]).
  //             The rgb override tints the WHOLE stack effect; per-layer
  //             tint variation isn't the intent — same color throughout.
  r'PHOTO:(?<photoFile>[a-zA-Z0-9_\-\./]+)(?::(?<photoHold>\d+))?(?::(?<photoChannel>[RGB]))?(?::(?<photoRgb>\d+,\d+,\d+))?(?::(?<photoRelease>\d+))?|'
  // IN-TERMINAL raster stencil flow: IBM 3279 Programmed Symbols emulation
  // (GDDM-style tile stamping). A small user-authored 1-bit tile is stamped
  // into the terminal's line flow like an oversized glyph, repeated
  // horizontally, revealed sequentially left to right.
  //
  //   [IMG:divider.png]           — 1 copy, R channel, 2 frames per copy
  //   [IMG:divider.png:12]        — 12 copies across the line
  //   [IMG:divider.png:12:G]      — mask read from the green channel
  //   [IMG:divider.png:12:G:1]    — reveal cadence of 1 frame per copy
  //   [IMG:divider.png:12:G:1:25] — release the typing gate at 25% of the reveal
  //
  //   file      = raster file inside images/ (required). Author it in GIMP —
  //               R3nder does ZERO image processing.
  //   repeat    = horizontal copy count (optional, default 1). The band
  //               clamps to the margins with a warning if it won't fit.
  //   channel   = R | G | B (optional, default R). The chosen channel is
  //               read as a HARD binary mask, fixed threshold >= 128:
  //               pixel on = pen-color phosphor, pixel off = NOTHING drawn
  //               (the terminal background shows through). No black is
  //               ever painted, no grayscale, no anti-aliasing — light on
  //               the monitor, exactly like phosphor. Nearest-neighbor
  //               scaling only; hard pixel edges are the point.
  //   framesPer = how fast the band draws on (optional, default 2). One
  //               meaning, two shapes, decided by the repeat count:
  //                 repeat > 1 : frames between each copy revealing, left
  //                              to right. Copies land whole.
  //                 repeat = 1 : frames for a SCANLINE to cross the tile
  //                              top to bottom, the wirephoto reveal.
  //                              Nothing to stagger with one copy, so the
  //                              same budget is spent drawing instead of
  //                              waiting on a finished tile.
  //               Timing is identical either way: a band always gates for
  //               copies * framesPer, so no existing script changes length.
  //               Reveal is frame-counted and fully deterministic, same
  //               pattern as BAR.
  //   release   = OPTIONAL % of THIS band's reveal at which the typing gate
  //               opens (0..100), so the NEXT tag or typed text begins while
  //               this band keeps revealing behind it. Omitted (or >= 100) =
  //               block the full reveal, exactly as before. Multiple bands
  //               can be mid-reveal at once, so early-release chains cleanly.
  //               NOTE: positional — a release requires channel AND framesPer
  //               segments before it (e.g. [IMG:tile.png:12:R:3:25]).
  //
  //   Tint = pen color at the moment the tag fires, so [WHITE][IMG:...]
  //   gives pure white and the tile stays on-theme in green/amber modes
  //   automatically — same rule as SVG stencils.
  r'IMG:(?<imgFile>[a-zA-Z0-9_\-\./]+)(?::(?<imgRepeat>\d+))?(?::(?<imgChannel>[RGB]))?(?::(?<imgFrames>\d+))?(?::(?<imgRelease>\d+))?|'
  r'SPRITE:(?<spritePath>[a-zA-Z0-9_\-\./]+)(?::(?<spriteHold>\d+))?|'
  r'SPRITE_OFF:(?<spriteOff>[a-zA-Z0-9_\-\./]+)|'
  r'CONFIG:(?<configKey>[A-Z]+):(?<configVal>[^\]]+)|'
  r'REGION:(?<regionId>[a-zA-Z0-9_-]+)|'
  r'(?<regionEnd>/REGION)|'
  r'SELECT:(?<selId>[a-zA-Z0-9_-]+|NONE)(?::(?<selBg>\d+,\d+,\d+))?|'
  r'(?<color>RED|GREEN|BLUE|YELLOW|WHITE|BLACK|NORMAL)'
  r')\]',
);

class MenuItem {
  final String id;
  final String text;
  MenuItem({required this.id, required this.text});
}

class MacroConfig {
  String? selectedItem;
  int bgR, bgG, bgB;
  int blinkMode;

  MacroConfig({
    this.selectedItem,
    this.bgR = 0,
    this.bgG = 255,
    this.bgB = 0,
    this.blinkMode = 0,
  });
}

class MenuStateRef {
  final String menuName;
  final String instanceId;
  MenuStateRef({required this.menuName, required this.instanceId});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MenuStateRef &&
          menuName == other.menuName &&
          instanceId == other.instanceId;

  @override
  int get hashCode => menuName.hashCode ^ instanceId.hashCode;
}

class TemplateData {
  final String rawText;
  final Map<String, String> configs;
  final Map<String, List<MenuItem>> definedMenus;
  final List<MenuStateRef> menuStatesFound;
  final Map<String, MacroConfig> macroConfigs;

  TemplateData({
    required this.rawText,
    required this.configs,
    required this.definedMenus,
    required this.menuStatesFound,
    required this.macroConfigs,
  });
}

class ScriptParser {
  /// Reads the template to extract [CONFIG], [DEF_MENU], [MENU_STATE], and [MACRO_CFG] data.
  static TemplateData parseTemplateData(String text) {
    Map<String, String> configs = {};
    final configRegExp = RegExp(r'\[CONFIG:([A-Z]+):([^\]]+)\]');
    for (final match in configRegExp.allMatches(text)) {
      configs[match.group(1)!] = match.group(2)!;
    }

    Map<String, MacroConfig> macroCfgs = {};
    final macroCfgRegExp = RegExp(
        r'\[MACRO_CFG:([a-zA-Z0-9_-]+):([a-zA-Z0-9_-]+|NONE):(\d+,\d+,\d+):(\d+)\]');
    for (final match in macroCfgRegExp.allMatches(text)) {
      final id = match.group(1)!;
      final selItem = match.group(2)!;
      final bgParts = match.group(3)!.split(',');
      final blinkMode = int.parse(match.group(4)!);

      macroCfgs[id] = MacroConfig(
        selectedItem: selItem != "NONE" ? selItem : null,
        bgR: int.parse(bgParts[0]),
        bgG: int.parse(bgParts[1]),
        bgB: int.parse(bgParts[2]),
        blinkMode: blinkMode,
      );
    }

    Map<String, List<MenuItem>> definedMenus = {};
    final defMenuRegExp =
        RegExp(r'\[DEF_MENU:([a-zA-Z0-9_-]+)\](.*?)\[/DEF_MENU\]', dotAll: true);
    for (final defMatch in defMenuRegExp.allMatches(text)) {
      final mName = defMatch.group(1)!;
      final mContent = defMatch.group(2)!;

      List<MenuItem> items = [];
      final itemRegExp = RegExp(r'\[ITEM:([a-zA-Z0-9_-]+)\](.*?)\[/ITEM\]', dotAll: true);
      for (final itemMatch in itemRegExp.allMatches(mContent)) {
        items.add(MenuItem(
          id: itemMatch.group(1)!,
          text: itemMatch.group(2)!.replaceAll('\n', ''), // Keep horizontal spaces, strip breaks
        ));
      }
      definedMenus[mName] = items;
    }

    List<MenuStateRef> menuStatesFound = [];
    final menuStateRegExp =
        RegExp(r'\[MENU_STATE:([a-zA-Z0-9_-]+):([a-zA-Z0-9_-]+)\]');
    for (final match in menuStateRegExp.allMatches(text)) {
      final stateRef = MenuStateRef(
        menuName: match.group(1)!,
        instanceId: match.group(2)!,
      );
      if (!menuStatesFound.contains(stateRef)) {
        menuStatesFound.add(stateRef);
      }
    }

    return TemplateData(
      rawText: text,
      configs: configs,
      definedMenus: definedMenus,
      menuStatesFound: menuStatesFound,
      macroConfigs: macroCfgs,
    );
  }

  /// Dynamically handles [CALL] to draw regions, and [MENU_STATE] to inject SELECT tags.
  static String injectMacros(
    String text,
    Map<String, List<MenuItem>> definedMenus,
    List<MenuStateRef> menuStatesList,
    Map<String, MacroConfig> menuSettings,
  ) {
    // 1. Strip the definitions so they don't render to screen
    text = text.replaceAll(RegExp(r'\[DEF_MENU:.*?\[/DEF_MENU\]\n?', dotAll: true), '');
    text = text.replaceAll(RegExp(r'\[MACRO_CFG:.*?\]\n?'), '');

    // 2. Replace [CALL:menu_name] with REGION wrapped text (Drawing the menu)
    definedMenus.forEach((mName, items) {
      List<String> repLines = [];
      for (var item in items) {
        repLines.add("[REGION:${item.id}]${item.text}[/REGION]");
      }
      text = text.replaceAll("[CALL:$mName]", repLines.join("\n"));
    });

    // 3. Replace [MENU_STATE:menu_name:instance_id] with instant SELECT tags (Highlighting the menu)
    for (var state in menuStatesList) {
      final mName = state.menuName;
      final iId = state.instanceId;

      final settings = menuSettings[iId];
      final selectedItem = settings?.selectedItem;

      if (selectedItem != null && settings != null) {
        final bgStr = "${settings.bgR},${settings.bgG},${settings.bgB}";
        final blinkMode = settings.blinkMode;

        String repStr = "";
        // Dynamic blinking logic translated from Python
        if (blinkMode == 0) {
          repStr = "[SELECT:$selectedItem:$bgStr]";
        } else if (blinkMode == 1) {
          repStr = "[SELECT:$selectedItem:$bgStr][PAUSE:5][SELECT:NONE][PAUSE:5][SELECT:$selectedItem:$bgStr]";
        } else if (blinkMode == 2) {
          repStr = "[SELECT:$selectedItem:$bgStr][PAUSE:5][SELECT:NONE][PAUSE:5][SELECT:$selectedItem:$bgStr][PAUSE:5][SELECT:NONE][PAUSE:5][SELECT:$selectedItem:$bgStr]";
        }

        text = text.replaceAll("[MENU_STATE:$mName:$iId]", repStr);
      } else {
        text = text.replaceAll("[MENU_STATE:$mName:$iId]", "[SELECT:NONE]");
      }
    }

    return text;
  }

  /// Finds lines that contain ONLY valid control tags and merges them with the text below to prevent empty line breaks.
  static String stripFormattingNewlines(String text) {
    List<String> lines = text.split('\n');
    List<String> mergedLines = [];
    String tagBuffer = "";

    for (String line in lines) {
      String stripped = line.trim();
      bool isOnlyTags = false;
      int pos = 0; // MOVED UP to fix scoping issue

      if (stripped.isNotEmpty && stripped.startsWith('[')) {
        isOnlyTags = true;
        while (pos < stripped.length) {
          // Use matchAsPrefix instead of substring + firstMatch for performance and correctness
          final match = tagRegex.matchAsPrefix(stripped, pos);
          if (match != null) {
            pos = match.end;
            while (pos < stripped.length && (stripped[pos] == ' ' || stripped[pos] == '\t')) {
              pos++;
            }
          } else {
            isOnlyTags = false;
            break;
          }
        }
      }

      if (isOnlyTags && stripped.isNotEmpty && pos == stripped.length) {
        tagBuffer += stripped;
      } else {
        mergedLines.add(tagBuffer + line);
        tagBuffer = "";
      }
    }

    if (tagBuffer.isNotEmpty) {
      mergedLines.add(tagBuffer);
    }

    return mergedLines.join('\n');
  }

  /// Cleans up comments, extracts configs, removes empty tag lines, ready for layout.
  static String preprocessScript(String text) {
    // 1. Strip out all unrendered comments like [# This is a comment]
    String cleanText = text.replaceAll(RegExp(r'\[#.*?\]\n?', dotAll: true), '');

    // 2. Strip out CONFIG tags before layout so they don't leave empty lines
    cleanText = cleanText.replaceAll(RegExp(r'\[CONFIG:.*?\]\n?'), '');

    // 3. Intelligent Whitespace Pass
    return stripFormattingNewlines(cleanText);
  }
}