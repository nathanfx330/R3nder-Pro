// ./lib/node_asset_preview.dart

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'folder_order.dart';
import 'folder_captions.dart';
import 'presentation_requests.dart';
import 'svg_path.dart';
import 'ui_theme.dart';

// =====================================================================
// WHY THIS FILE EXISTS
//
// The node properties panel offers asset pickers: dropdowns of what the
// workspace actually holds. A dropdown tells you a filename exists. It
// does not tell you whether mugshot.png is the mugshot you meant, and it
// says nothing at all about the one property that decides whether an
// [IMG] or [PHOTO] plays or burns its timing as a dud: pixel dimensions.
//
// So the panel renders the asset. Three kinds, no new dependencies:
//
//   raster  Image.file with cacheWidth pinned, so the image cache holds
//           thumbnails rather than full plates. A folder of 4K stills
//           previewed at 64px costs the cache 64px of decode each.
//   svg     SvgParser is synchronous and hands back a ui.Path plus a
//           viewBox, so a CustomPainter fits it to the box. This is the
//           same parser the engine draws with, which means the thumb
//           shows what will actually render, including the background
//           plate culling and the fill rule inference. A stencil that
//           reads as a solid block here will read as a solid block in
//           the bake.
//   sprite  Frame 0 of the .txt in tiny monospace. Enough to tell two
//           sprites apart, which is all a picker needs.
//
// NOTHING HERE ENTERS THE RENDER PATH. This is authoring furniture. The
// caches are process-wide and invalidated by hand after an import,
// rather than keyed on mtime, because a stat per thumb per rebuild is a
// syscall storm for a value that only changes when this app writes it.
// =====================================================================

/// How to draw a given asset. Deliberately not [AssetSlot]: that enum
/// belongs to the node workspace and also drives pickers and labels, so
/// importing it here would tie the renderer to the form. The workspace
/// maps slot to kind at the call site.
enum ThumbKind { raster, svg, sprite }

/// Extensions each kind will attempt. Mirrors NodeAssetLibrary's lists and
/// the SceneEngine's folder loaders.
const Set<String> kRasterThumbExts = {
  '.png', '.jpg', '.jpeg', '.bmp', '.gif', '.webp',
};
const Set<String> kSvgThumbExts = {'.svg'};
const Set<String> kSpriteThumbExts = {'.txt'};

Set<String> extsFor(ThumbKind kind) {
  switch (kind) {
    case ThumbKind.raster:
      return kRasterThumbExts;
    case ThumbKind.svg:
      return kSvgThumbExts;
    case ThumbKind.sprite:
      return kSpriteThumbExts;
  }
}

/// Sorted filenames inside [dir] that [kind] can draw. Every failure mode
/// (missing directory, permissions) degrades to an empty list, matching
/// NodeAssetLibrary.scan: the panel always builds.
List<String> listFolderAssets(String dir, ThumbKind kind) {
  final Set<String> exts = extsFor(kind);
  final List<String> found = [];
  try {
    final Directory d = Directory(dir);
    if (!d.existsSync()) return const [];
    for (final ent in d.listSync(followLinks: false)) {
      if (ent is! File) continue;
      final String name = ent.path.split(Platform.pathSeparator).last;
      if (name.startsWith('.')) continue;
      final String lower = name.toLowerCase();
      if (exts.any(lower.endsWith)) found.add(name);
    }
  } catch (_) {
    return const [];
  }
  found.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return found;
}

// ---------------------------------------------------------------------
// Raster header probe
// ---------------------------------------------------------------------

/// Pixel dimensions and byte size of a raster, read from the file header
/// without a full decode.
///
/// Dimensions are the reason this exists. [IMG] caps at 512 on either
/// axis and [PHOTO] at 1024, and a file over the cap does not fail loudly:
/// it plays as a dud with its timing burned as a pause. Finding that out
/// by baking is expensive. Finding it out from an amber badge in the
/// picker costs nothing.
class RasterInfo {
  final bool ok;
  final int width;
  final int height;
  final int bytes;
  final String error;

  const RasterInfo({
    required this.ok,
    this.width = 0,
    this.height = 0,
    this.bytes = 0,
    this.error = '',
  });

  const RasterInfo.failed(this.error)
      : ok = false,
        width = 0,
        height = 0,
        bytes = 0;

  int get maxAxis => width > height ? width : height;

  /// "1920x1080  2.3 MB"
  String get label {
    if (!ok) return error.isEmpty ? 'UNREADABLE' : error;
    return '${width}x$height  $sizeLabel';
  }

  String get sizeLabel {
    if (bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Process-wide probe cache. Futures are cached, not results, so two
/// widgets asking for the same file during one build share one read.
class RasterInfoCache {
  static final Map<String, Future<RasterInfo>> _cache = {};

  static Future<RasterInfo> of(String path) {
    return _cache.putIfAbsent(path, () => _probe(path));
  }

  /// Drops everything. Called after an import writes into the workspace,
  /// since a path can now point at different bytes than it did.
  static void invalidate() => _cache.clear();

  static Future<RasterInfo> _probe(String path) async {
    ui.ImmutableBuffer? buf;
    ui.ImageDescriptor? desc;
    try {
      final File f = File(path);
      if (!f.existsSync()) return const RasterInfo.failed('NOT ON DISK');
      final int bytes = f.lengthSync();

      buf = await ui.ImmutableBuffer.fromFilePath(path);
      desc = await ui.ImageDescriptor.encoded(buf);
      final int w = desc.width;
      final int h = desc.height;
      return RasterInfo(ok: true, width: w, height: h, bytes: bytes);
    } catch (_) {
      return const RasterInfo.failed('NOT A READABLE IMAGE');
    } finally {
      // Descriptor first: it holds a view onto the buffer.
      desc?.dispose();
      buf?.dispose();
    }
  }
}

// ---------------------------------------------------------------------
// SVG and sprite caches
// ---------------------------------------------------------------------

/// Parsed stencils keyed by absolute path. Parsing is synchronous and
/// cheap for the file sizes involved, but a contact sheet scrolling past
/// would reparse on every frame without this.
class SvgThumbCache {
  static final Map<String, SvgDocument?> _cache = {};

  static SvgDocument? of(String path) {
    if (_cache.containsKey(path)) return _cache[path];
    SvgDocument? doc;
    try {
      final File f = File(path);
      doc = f.existsSync() ? SvgParser.parse(f.readAsStringSync()) : null;
    } catch (_) {
      doc = null;
    }
    _cache[path] = doc;
    return doc;
  }

  static void invalidate() => _cache.clear();
}

/// Frame 0 of a sprite file, already clipped to thumbnail proportions.
class SpriteThumbCache {
  static const int _maxLines = 9;
  static const int _maxCols = 30;

  static final Map<String, String> _cache = {};

  static String of(String path) {
    final String? hit = _cache[path];
    if (hit != null) return hit;

    String out = '';
    try {
      final File f = File(path);
      if (f.existsSync()) {
        final String raw = f.readAsStringSync();
        // Frames are separated by [FRAME] on its own line. Everything
        // before the first separator is frame 0, which is the frame the
        // engine commits at spawn time.
        final int cut = raw.indexOf('[FRAME]');
        final String frame0 = cut >= 0 ? raw.substring(0, cut) : raw;
        final List<String> lines = frame0
            .split('\n')
            .where((l) => l.trim().isNotEmpty)
            .take(_maxLines)
            .map((l) => l.length > _maxCols ? l.substring(0, _maxCols) : l)
            .toList();
        out = lines.join('\n');
      }
    } catch (_) {
      out = '';
    }
    _cache[path] = out;
    return out;
  }

  static void invalidate() => _cache.clear();
}

/// Clears every preview cache at once. The node workspace calls this after
/// any import, because a filename that resolved to nothing a moment ago
/// now resolves to something.
void invalidateAssetPreviews() {
  RasterInfoCache.invalidate();
  SvgThumbCache.invalidate();
  SpriteThumbCache.invalidate();
}

// ---------------------------------------------------------------------
// SVG thumbnail painter
// ---------------------------------------------------------------------

/// Draws a parsed stencil fit inside the box, preserving aspect. Fill only,
/// which is the whole of what the engine draws too, so the thumb cannot
/// flatter a stencil that will render as a silhouette.
class _SvgThumbPainter extends CustomPainter {
  final SvgDocument doc;
  final Color color;

  _SvgThumbPainter(this.doc, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (doc.viewWidth <= 0 || doc.viewHeight <= 0) return;

    final double pad = size.shortestSide * 0.10;
    final double availW = size.width - pad * 2;
    final double availH = size.height - pad * 2;
    if (availW <= 0 || availH <= 0) return;

    final double scale =
        math.min(availW / doc.viewWidth, availH / doc.viewHeight);
    final double drawW = doc.viewWidth * scale;
    final double drawH = doc.viewHeight * scale;

    canvas.save();
    canvas.translate(
      (size.width - drawW) / 2,
      (size.height - drawH) / 2,
    );
    canvas.scale(scale);
    canvas.translate(-doc.viewLeft, -doc.viewTop);
    canvas.drawPath(doc.path, Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SvgThumbPainter old) =>
      old.doc != doc || old.color != color;
}

// ---------------------------------------------------------------------
// Thumbnail
// ---------------------------------------------------------------------

/// One asset drawn inside a fixed square box. Handles its own missing and
/// unreadable states, so callers never have to check the disk first.
class AssetThumb extends StatelessWidget {
  /// Absolute path to the asset.
  final String path;

  final ThumbKind kind;

  /// Box edge in logical pixels. Callers pass an already-scaled value.
  final double size;

  final R3Theme theme;

  /// Accent border, used to mark the field the panel is currently armed on.
  final bool highlight;

  const AssetThumb({
    super.key,
    required this.path,
    required this.kind,
    required this.size,
    required this.theme,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final bool exists = _existsSync();

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: R3Theme.panelHi,
        borderRadius: BorderRadius.circular(sc(3)),
        border: Border.all(
          color: highlight ? theme.accentDim : R3Theme.hairline,
          width: highlight ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: exists ? _buildContent(context) : _buildMissing(),
    );
  }

  bool _existsSync() {
    try {
      return path.isNotEmpty && File(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  Widget _buildMissing() {
    return Center(
      child: Icon(
        Icons.broken_image_outlined,
        size: size * 0.42,
        color: R3Theme.textDim,
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    switch (kind) {
      case ThumbKind.raster:
        // cacheWidth pins the decode. Without it a folder of 4K stills
        // previewed at 64px would put full-resolution bitmaps in the image
        // cache and the editor would balloon on a large workspace.
        final double dpr = MediaQuery.devicePixelRatioOf(context);
        final int cacheW = (size * dpr).round().clamp(16, 512);
        return Image.file(
          File(path),
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          cacheWidth: cacheW,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => _buildMissing(),
        );

      case ThumbKind.svg:
        final SvgDocument? doc = SvgThumbCache.of(path);
        if (doc == null) {
          return Center(
            child: Icon(Icons.help_outline,
                size: size * 0.40, color: R3Theme.textDim),
          );
        }
        return CustomPaint(
          painter: _SvgThumbPainter(doc, R3Theme.textBright),
          size: Size(size, size),
        );

      case ThumbKind.sprite:
        final String art = SpriteThumbCache.of(path);
        if (art.isEmpty) {
          return Center(
            child: Icon(Icons.text_fields,
                size: size * 0.40, color: R3Theme.textDim),
          );
        }
        return Padding(
          padding: EdgeInsets.all(sc(3)),
          child: FittedBox(
            fit: BoxFit.contain,
            alignment: Alignment.center,
            child: Text(
              art,
              softWrap: false,
              style: TextStyle(
                fontFamily: 'monospace',
                fontFamilyFallback: R3Theme.monoStack,
                fontSize: 8,
                height: 1.05,
                color: R3Theme.textMid,
              ),
            ),
          ),
        );
    }
  }
}

// ---------------------------------------------------------------------
// Single-file preview
// ---------------------------------------------------------------------

/// Thumbnail plus a metadata line, for a field that names one file.
///
/// [maxDimension] is the cap the tag enforces at load time (512 for IMG,
/// 1024 for PHOTO, null where there is no cap). Exceeding it is reported
/// in amber right here, because the runtime's answer is to play the tag as
/// a dud with its timing preserved, which looks like nothing went wrong.
class AssetFilePreview extends StatelessWidget {
  final String absolutePath;
  final String displayName;
  final ThumbKind kind;
  final R3Theme theme;
  final int? maxDimension;

  /// Box edge, or null for the default. Not a defaulted parameter because
  /// sc() is not const.
  final double? size;

  const AssetFilePreview({
    super.key,
    required this.absolutePath,
    required this.displayName,
    required this.kind,
    required this.theme,
    this.maxDimension,
    this.size,
  });

  @override
  Widget build(BuildContext context) {
    final double box = size ?? sc(76);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AssetThumb(
          path: absolutePath,
          kind: kind,
          size: box,
          theme: theme,
        ),
        SizedBox(width: sc(10)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.value,
              ),
              SizedBox(height: sc(4)),
              if (kind == ThumbKind.raster)
                _rasterMeta(context)
              else
                Text(_staticMeta(), style: theme.fine),
            ],
          ),
        ),
      ],
    );
  }

  /// Non-raster kinds have nothing worth probing asynchronously: an SVG is
  /// resolution independent and a sprite is text.
  String _staticMeta() {
    try {
      final File f = File(absolutePath);
      if (!f.existsSync()) return 'NOT ON DISK';
      if (kind == ThumbKind.svg) {
        final SvgDocument? doc = SvgThumbCache.of(absolutePath);
        if (doc == null) return 'NO DRAWABLE GEOMETRY';
        return 'VIEWBOX ${doc.viewWidth.round()}x${doc.viewHeight.round()}';
      }
      return 'SPRITE';
    } catch (_) {
      return '';
    }
  }

  Widget _rasterMeta(BuildContext context) {
    return FutureBuilder<RasterInfo>(
      future: RasterInfoCache.of(absolutePath),
      builder: (ctx, snap) {
        if (!snap.hasData) {
          return Text('READING...', style: theme.fine);
        }
        final RasterInfo info = snap.data!;
        if (!info.ok) {
          return Row(
            children: [
              const R3Tally(state: R3TallyState.error),
              SizedBox(width: sc(8)),
              Expanded(
                child: Text(info.label,
                    style: theme.fine.copyWith(color: R3Theme.danger)),
              ),
            ],
          );
        }

        final int? cap = maxDimension;
        final bool over = cap != null && info.maxAxis > cap;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(info.label, style: theme.fine),
            if (over) ...[
              SizedBox(height: sc(6)),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const R3Tally(state: R3TallyState.warn, count: 'OVERSIZE'),
                  SizedBox(width: sc(8)),
                  Expanded(
                    child: Text(
                      'CAP IS ${cap}PX. THIS PLAYS AS A DUD.',
                      style: theme.fine.copyWith(color: R3Theme.warn),
                    ),
                  ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------
// Folder contact sheet
// ---------------------------------------------------------------------

/// Every drawable file in a folder, wrapped as thumbnails.
///
/// Capped at [limit] with a count tail. A gallery folder can legitimately
/// hold a hundred stills and decoding all of them to fill a properties
/// panel is not a service to anyone. The header reports the true total, so
/// the cap never hides a count discrepancy.
class AssetFolderPreview extends StatelessWidget {
  final String absoluteDir;
  final ThumbKind kind;
  final R3Theme theme;
  final int limit;

  /// Thumb edge, or null for the default. Not a defaulted parameter
  /// because sc() is not const.
  final double? thumbSize;

  /// Count the script implies this folder should hold, from a [#NEEDS:...]
  /// directive, or null when nothing was declared.
  final int? expectedCount;

  /// Optional authoring action for raster-folder thumbnails. When present,
  /// an X appears on hover and the caller decides how the file is removed.
  /// R3nder's node workspace uses this to move files into images/_recycle
  /// rather than deleting them.
  final Future<void> Function(String absolutePath)? onRecycle;

  /// Persist a new order for this folder. When present, thumbnails become
  /// draggable, every file is shown rather than the first [limit], and each
  /// carries its position number.
  ///
  /// Reordering exists because folder order is not cosmetic: MOSAIC pane
  /// grouping consumes consecutive positions, a TIMELINE stage pairs photo
  /// i with event i, and SVGFLASH flickers in sequence. Before this the only
  /// order was the filename, so dropping in a new scan could silently
  /// recompose a shot that was already right.
  final Future<void> Function(List<String> orderedNames)? onReorder;

  /// Delete the manifest and fall back to filename order. Only offered when
  /// a manifest actually exists, so the control is never a no-op.
  final Future<void> Function()? onResetOrder;

  /// Authored panes-per-page from the tag, or null when this folder is not
  /// consumed by a paged layout. Empty list means paged but unplanned, which
  /// still shows breaks: the default chunking is where the pages fall
  /// whether or not anyone wrote it down.
  final List<int>? pagePlan;

  /// Write a new plan back to the tag. Null leaves the markers read-only.
  final void Function(List<int> plan)? onPagePlanChanged;

  /// Authored MOSAIC pane grouping / Pane Life selection. Null means this
  /// folder is not used by a mosaic APP; empty means one image per pane and
  /// no pane is selected for Pane Life.
  final List<AppPaneSpec>? panePlan;

  /// Writes grouping / hero / direction changes back into the APP tag.
  final void Function(List<AppPaneSpec> plan)? onPanePlanChanged;

  /// Caption records for this folder, keyed by filename. Null means the
  /// caller is not offering caption authoring at all, which keeps the
  /// sheet clean for the folder tags that do not draw bands.
  final Map<String, ImageCaption>? captions;

  /// Filename the sidebar profile is currently showing, or null.
  final String? selectedName;

  /// Tap on a thumbnail. Pure view state; nothing is written.
  ///
  /// Reports the load position and the folder's total alongside the name,
  /// because the profile needs to know which PANE this image belongs to in
  /// order to author a hold, and pane membership is positional. Deliberately
  /// not the pane index itself: splitting or merging panes would leave a
  /// stored pane index pointing at the wrong group, while an image index
  /// stays true and the membership can be recomputed.
  final void Function(String name, int index, int total)? onSelectName;

  /// Per-image hold extensions in frames, indexed by load position.
  ///
  /// Display only. Authoring lives in the profile panel, where there is
  /// room for a number.
  final List<int> holdFrames;

  const AssetFolderPreview({
    super.key,
    required this.absoluteDir,
    required this.kind,
    required this.theme,
    this.limit = 12,
    this.expectedCount,
    this.thumbSize,
    this.onRecycle,
    this.onReorder,
    this.onResetOrder,
    this.pagePlan,
    this.onPagePlanChanged,
    this.panePlan,
    this.onPanePlanChanged,
    this.captions,
    this.selectedName,
    this.onSelectName,
    this.holdFrames = const [],
  });

  @override
  Widget build(BuildContext context) {
    final double box = thumbSize ?? sc(54);
    final bool dirExists = _dirExists();

    // Read through the manifest, so the sheet shows the order the engine
    // will actually load. Straight off disk on every build rather than held
    // in state: a reorder writes the manifest and the next build reads it
    // back, which means there is no second copy of the order to fall out of
    // step with the folder.
    final List<String> files = dirExists
        ? orderedFolderNames(absoluteDir, listFolderAssets(absoluteDir, kind))
        : const [];

    if (!dirExists) {
      return _note('FOLDER NOT ON DISK', R3Theme.danger);
    }
    if (files.isEmpty) {
      // The runtime treats an empty folder as a dud, so this is an error
      // state and not an empty-list shrug.
      return _note('EMPTY FOLDER', R3Theme.danger);
    }

    // The cap exists so a 200 image gallery does not fill the panel. It has
    // to lift when reordering, because you cannot arrange what is not drawn,
    // and a partial reorder that silently ignored the tail would be worse
    // than no reorder at all.
    final bool canReorder = onReorder != null;
    final List<String> shown =
        canReorder ? files : files.take(limit).toList();
    final int hidden = files.length - shown.length;

    // Pane structure is positional over the ordered folder. Empty authored
    // data resolves to one image per pane, which is both the legacy runtime
    // behavior and the most honest contact-sheet starting point.
    final List<AppPaneSpec> resolvedPanes = panePlan == null
        ? const <AppPaneSpec>[]
        : resolveAppPanePlan(shown.length, panePlan!);
    final List<({int start, int end, AppPaneSpec spec})> paneRanges =
        _paneRanges(resolvedPanes);
    final Map<int, int> paneEndToIndex = {
      for (int p = 0; p < paneRanges.length; p++)
        if (paneRanges[p].end < shown.length) paneRanges[p].end - 1: p,
    };
    final Set<int> paneEnds = paneEndToIndex.keys.toSet();

    // Page planning now counts visual panes, not source images. With legacy
    // one-image panes the arithmetic is identical to the old implementation.
    final Set<int> pagePaneEnds = _pageEnds(resolvedPanes.length);
    final Set<int> lockedPagePaneEnds =
        _lockedEnds(resolvedPanes.length, pagePaneEnds);

    final List<int> paneForImage = List<int>.filled(shown.length, -1);
    final Set<int> heroImages = {};
    // Fit is a pane fact with no hero to hang off, so its chip goes on the
    // pane's first thumbnail: the one place that exists for every pane,
    // starred or not.
    final Set<int> paneFirstImages = {};
    for (int p = 0; p < paneRanges.length; p++) {
      final range = paneRanges[p];
      for (int i = range.start; i < range.end; i++) paneForImage[i] = p;
      final int? hero = range.spec.heroIndex;
      if (hero != null) heroImages.add(range.start + hero);
      if (range.start < shown.length) paneFirstImages.add(range.start);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _countBadge(files.length),
            SizedBox(width: sc(8)),
            Text('${files.length} FILE${files.length == 1 ? '' : 'S'}',
                style: theme.fine),
            if (expectedCount != null && files.length != expectedCount) ...[
              SizedBox(width: sc(8)),
              Expanded(
                child: Text(
                  'SCRIPT DECLARES $expectedCount',
                  style: theme.fine.copyWith(color: R3Theme.warn),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ] else
              const Spacer(),
            // Which of the two orders you are looking at. Worth stating: a
            // folder in filename order and one arranged to look identical
            // behave differently the moment you add a file.
            if (canReorder)
              Text(
                folderHasOrder(absoluteDir) ? 'CUSTOM ORDER' : 'NAME ORDER',
                style: theme.fine.copyWith(
                  color: folderHasOrder(absoluteDir)
                      ? theme.accent
                      : R3Theme.textDim,
                ),
              ),
            if (canReorder &&
                onResetOrder != null &&
                folderHasOrder(absoluteDir)) ...[
              SizedBox(width: sc(8)),
              InkWell(
                onTap: () => onResetOrder!(),
                borderRadius: BorderRadius.circular(sc(3)),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                      horizontal: sc(6), vertical: sc(2)),
                  child: Text('RESET',
                      style: theme.fine.copyWith(color: R3Theme.textDim)),
                ),
              ),
            ],
          ],
        ),
        if (panePlan != null) ...[
          SizedBox(height: sc(5)),
          Text(
            '☆ CLICK TO SELECT  ·  ★ CLICK AGAIN TO CLEAR  ·  LR/RL FLIPS THE SELECTED PANE  ·  FIT CYCLES FILL / VERTICAL EDGE / HORIZONTAL EDGE  ·  PANE BAR SPLITS / MERGES  ·  CLICK A THUMBNAIL FOR ITS PROFILE',
            style: theme.fine.copyWith(color: R3Theme.textDim),
          ),
        ],
        SizedBox(height: sc(8)),
        Wrap(
          spacing: sc(6),
          runSpacing: sc(6),
          children: [
            // One cell per image: the thumbnail, and the page marker that
            // follows it. Paired in a Row rather than emitted as two Wrap
            // children so the Wrap can never break the line between a thumb
            // and its own marker, which would strand a break at the start of
            // the next row reading as though it belonged to a different
            // image.
            for (int i = 0; i < shown.length; i++)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (canReorder)
                    _ReorderSlot(
                      index: i,
                      theme: theme,
                      size: box,
                      onMove: (from) => _move(files, from, i),
                      child: _HoverRecycleThumb(
                        path:
                            '$absoluteDir${Platform.pathSeparator}${shown[i]}',
                        kind: kind,
                        size: box,
                        theme: theme,
                        onRecycle: onRecycle,
                        position: i + 1,
                        isHero: panePlan != null && heroImages.contains(i),
                        onHeroTap: panePlan == null || onPanePlanChanged == null
                            ? null
                            : () => _setHero(shown.length, i),
                        directionLabel: panePlan != null &&
                                paneForImage[i] >= 0 &&
                                heroImages.contains(i) &&
                                resolvedPanes[paneForImage[i]].imageCount > 1
                            ? (resolvedPanes[paneForImage[i]].direction ==
                                    PaneDirection.rightToLeft
                                ? 'RL'
                                : 'LR')
                            : null,
                        onDirectionTap: panePlan == null ||
                                onPanePlanChanged == null ||
                                paneForImage[i] < 0 ||
                                resolvedPanes[paneForImage[i]].imageCount <= 1
                            ? null
                            : () => _flipDirection(
                                shown.length, paneForImage[i]),
                        fitLabel: panePlan != null && paneForImage[i] >= 0
                            ? resolvedPanes[paneForImage[i]].fitLabel
                            : null,
                        onFitTap: panePlan == null ||
                                onPanePlanChanged == null ||
                                paneForImage[i] < 0 ||
                                !paneFirstImages.contains(i)
                            ? null
                            : () => _setFit(shown.length, paneForImage[i]),
                        hasCaption:
                            captions?[shown[i]]?.hasBand ?? false,
                        selected: selectedName == shown[i],
                        onSelect: onSelectName == null
                            ? null
                            : () => onSelectName!(shown[i], i, shown.length),
                        holdFrames:
                            i < holdFrames.length ? holdFrames[i] : 0,
                      ),
                    )
                  else
                    _HoverRecycleThumb(
                      path: '$absoluteDir${Platform.pathSeparator}${shown[i]}',
                      kind: kind,
                      size: box,
                      theme: theme,
                      onRecycle: onRecycle,
                      isHero: panePlan != null && heroImages.contains(i),
                      onHeroTap: panePlan == null || onPanePlanChanged == null
                          ? null
                          : () => _setHero(shown.length, i),
                      directionLabel: panePlan != null &&
                              paneForImage[i] >= 0 &&
                              heroImages.contains(i) &&
                              resolvedPanes[paneForImage[i]].imageCount > 1
                          ? (resolvedPanes[paneForImage[i]].direction ==
                                  PaneDirection.rightToLeft
                              ? 'RL'
                              : 'LR')
                          : null,
                      onDirectionTap: panePlan == null ||
                              onPanePlanChanged == null ||
                              paneForImage[i] < 0 ||
                              resolvedPanes[paneForImage[i]].imageCount <= 1
                          ? null
                          : () =>
                              _flipDirection(shown.length, paneForImage[i]),
                      fitLabel: panePlan != null && paneForImage[i] >= 0
                          ? resolvedPanes[paneForImage[i]].fitLabel
                          : null,
                      onFitTap: panePlan == null ||
                              onPanePlanChanged == null ||
                              paneForImage[i] < 0 ||
                              !paneFirstImages.contains(i)
                          ? null
                          : () => _setFit(shown.length, paneForImage[i]),
                      hasCaption: captions?[shown[i]]?.hasBand ?? false,
                      selected: selectedName == shown[i],
                      onSelect: onSelectName == null
                          ? null
                          : () => onSelectName!(shown[i], i, shown.length),
                      holdFrames: i < holdFrames.length ? holdFrames[i] : 0,
                    ),
                  if (panePlan != null && i < shown.length - 1)
                    _PaneBreakMarker(
                      theme: theme,
                      size: box,
                      active: paneEnds.contains(i),
                      onTap: onPanePlanChanged == null
                          ? null
                          : () => _togglePaneBreak(shown.length, i),
                    ),
                  // Page breaks can only happen between complete panes. The
                  // second marker is therefore offered only on an active pane
                  // divider; it still edits the APP page-plan independently.
                  if (pagePlan != null &&
                      i < shown.length - 1 &&
                      paneEndToIndex.containsKey(i))
                    _PageBreakMarker(
                      theme: theme,
                      size: box,
                      active: pagePaneEnds.contains(paneEndToIndex[i]),
                      locked:
                          lockedPagePaneEnds.contains(paneEndToIndex[i]),
                      onTap: (onPagePlanChanged == null ||
                              lockedPagePaneEnds
                                  .contains(paneEndToIndex[i]))
                          ? null
                          : () => _toggleBreak(resolvedPanes.length,
                              pagePaneEnds, paneEndToIndex[i]!),
                    ),
                ],
              ),
            // Tail target, so the last position is reachable. Without it a
            // thumbnail can be moved anywhere except the end, which is the
            // move you want most often after adding a file.
            if (canReorder && shown.length > 1)
              _ReorderSlot(
                index: shown.length,
                theme: theme,
                size: box,
                onMove: (from) => _move(files, from, shown.length),
                child: SizedBox(width: sc(10), height: box),
              ),
            if (hidden > 0)
              Container(
                width: box,
                height: box,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: R3Theme.panelHi,
                  borderRadius: BorderRadius.circular(sc(3)),
                  border: Border.all(color: R3Theme.hairline),
                ),
                child: Text('+$hidden', style: theme.fine),
              ),
          ],
        ),
      ],
    );
  }

  List<({int start, int end, AppPaneSpec spec})> _paneRanges(
      List<AppPaneSpec> panes) {
    final List<({int start, int end, AppPaneSpec spec})> out = [];
    int at = 0;
    for (final spec in panes) {
      final int end = at + spec.imageCount;
      out.add((start: at, end: end, spec: spec));
      at = end;
    }
    return out;
  }

  /// Returns a fully explicit plan against the current source count. Editing
  /// starts from this resolved form so a click never changes what unrelated
  /// remainder images were doing implicitly.
  List<AppPaneSpec> _resolvedPanePlan(int count) =>
      resolveAppPanePlan(count, panePlan ?? const []);

  void _setHero(int count, int imageIndex) {
    final List<AppPaneSpec> panes = _resolvedPanePlan(count);
    int at = 0;
    for (int p = 0; p < panes.length; p++) {
      final AppPaneSpec spec = panes[p];
      final int end = at + spec.imageCount;
      if (imageIndex >= at && imageIndex < end) {
        final int clicked = imageIndex - at;
        // The star is a real language toggle, not an indicator. Clicking the
        // active hero removes @hero from this pane; clicking any other image
        // moves the single selection within the pane.
        //
        // copyWith rather than a fresh spec, so an edit to one authored fact
        // never silently drops another. Fit was the second such fact and
        // will not be the last.
        panes[p] = spec.copyWith(
          heroIndex: spec.heroIndex == clicked ? null : clicked,
          clearHero: spec.heroIndex == clicked,
        );
        onPanePlanChanged?.call(panes);
        return;
      }
      at = end;
    }
  }

  void _flipDirection(int count, int paneIndex) {
    final List<AppPaneSpec> panes = _resolvedPanePlan(count);
    if (paneIndex < 0 || paneIndex >= panes.length) return;
    final AppPaneSpec spec = panes[paneIndex];
    panes[paneIndex] = spec.copyWith(
      direction: spec.direction == PaneDirection.leftToRight
          ? PaneDirection.rightToLeft
          : PaneDirection.leftToRight,
    );
    onPanePlanChanged?.call(panes);
  }

  /// Cycles this pane's fit: FILL, then the vertical edge, then the
  /// horizontal edge, then back.
  ///
  /// A cycle rather than a toggle because there are three fits and a
  /// two-state control cannot express three. The order puts the common
  /// answer one click away: FILL is where every pane starts, one click
  /// fixes a portrait losing its top and bottom, a second fixes a panorama
  /// losing its ends.
  ///
  /// A pane property, not an image one, which is why the chip is offered on
  /// the pane's first thumbnail only and why the whole pane changes
  /// together. Independent of Pane Life in both directions: an unstarred
  /// pane can fit, and starring one changes nothing about how it scales.
  void _setFit(int count, int paneIndex) {
    final List<AppPaneSpec> panes = _resolvedPanePlan(count);
    if (paneIndex < 0 || paneIndex >= panes.length) return;
    final AppPaneSpec spec = panes[paneIndex];
    panes[paneIndex] = spec.copyWith(fit: nextPaneFit(spec.fit));
    onPanePlanChanged?.call(panes);
  }

  /// Splits or merges the authored pane boundary immediately after global
  /// source image [index]. Hero selection is preserved only on the side that
  /// already owned it. Splitting or merging never invents Pane Life selection.
  void _togglePaneBreak(int count, int index) {
    final List<AppPaneSpec> panes = _resolvedPanePlan(count);
    final ranges = _paneRanges(panes);

    // Active boundary: merge this pane with the next one.
    for (int p = 0; p < ranges.length - 1; p++) {
      if (ranges[p].end - 1 != index) continue;
      final AppPaneSpec left = panes[p];
      final AppPaneSpec right = panes[p + 1];
      // A merged pane can still have at most one hero. Preserve the left
      // selection when present; otherwise carry the right selection across
      // with its index shifted into the merged pane. Never invent a hero.
      final int? mergedHero = left.heroIndex ??
          (right.heroIndex == null
              ? null
              : left.imageCount + right.heroIndex!);
      panes[p] = AppPaneSpec(
        imageCount: left.imageCount + right.imageCount,
        heroIndex: mergedHero,
        direction: left.heroIndex != null ? left.direction : right.direction,
        // Fit follows the pane you merged INTO. Unlike direction it has no
        // hero to point at the meaningful side, and the left pane is the one
        // whose identity survives the merge in every other respect.
        fit: left.fit,
      );
      panes.removeAt(p + 1);
      onPanePlanChanged?.call(panes);
      return;
    }

    // Inactive boundary: split the pane containing it.
    for (int p = 0; p < ranges.length; p++) {
      final range = ranges[p];
      if (index < range.start || index >= range.end - 1) continue;

      final AppPaneSpec old = panes[p];
      final int leftCount = index - range.start + 1;
      final int rightCount = old.imageCount - leftCount;
      if (leftCount <= 0 || rightCount <= 0) return;

      final int? oldHero = old.heroIndex;
      final bool heroLeft = oldHero != null && oldHero < leftCount;
      final bool heroRight = oldHero != null && oldHero >= leftCount;
      final AppPaneSpec left = AppPaneSpec(
        imageCount: leftCount,
        heroIndex: heroLeft ? oldHero : null,
        direction: old.direction,
        fit: old.fit,
      );
      final AppPaneSpec right = AppPaneSpec(
        imageCount: rightCount,
        heroIndex: heroRight ? oldHero! - leftCount : null,
        direction: old.direction,
        fit: old.fit,
      );

      panes[p] = left;
      panes.insert(p + 1, right);
      onPanePlanChanged?.call(panes);
      return;
    }
  }

  /// Indices after which a page ends, resolved against the real image count.
  ///
  /// The last image always ends a page and is excluded: a marker there would
  /// mark the end of the sequence rather than a break in it.
  Set<int> _pageEnds(int count) {
    final List<int>? plan = pagePlan;
    if (plan == null || count <= 0) return const {};

    final List<int> sizes = resolvePagePlan(count, plan);
    final Set<int> ends = {};
    int at = 0;
    for (final size in sizes) {
      at += size;
      if (at < count) ends.add(at - 1);
    }
    return ends;
  }

  /// Turn a set of break positions back into a panels-per-page plan.
  ///
  /// The two representations are a clean bijection: run lengths between
  /// breaks. Editing happens in break positions because that is what a
  /// marker in the strip is, and the tag stores run lengths because that is
  /// what reads well on one line.
  List<int> _planFromEnds(int count, Set<int> ends) {
    final List<int> plan = [];
    int run = 0;
    for (int i = 0; i < count; i++) {
      run++;
      if (ends.contains(i) || i == count - 1) {
        plan.add(run);
        run = 0;
      }
    }
    return plan;
  }

  /// Breaks that cannot be removed, because the page they would merge into
  /// exceeds what the composition holds.
  ///
  /// The mosaic is defined for one, two, or three panels, so with nine
  /// images the breaks after 3 and 6 are structural rather than authored:
  /// asking to remove one requests a five panel page, the resolver clamps
  /// it straight back, and the click reads as broken. Marking them locked
  /// says so instead of letting you push against a wall.
  Set<int> _lockedEnds(int count, Set<int> ends, {int perPage = 3}) {
    final Set<int> locked = {};
    for (final e in ends) {
      final Set<int> without = Set<int>.of(ends)..remove(e);
      final List<int> runs = _planFromEnds(count, without);
      if (runs.any((r) => r > perPage)) locked.add(e);
    }
    return locked;
  }

  void _toggleBreak(int count, Set<int> ends, int index) {
    final Set<int> next = Set<int>.of(ends);
    if (!next.remove(index)) next.add(index);
    onPagePlanChanged?.call(_planFromEnds(count, next));
  }

  /// Move [from] to sit at [to] in the displayed sequence, then persist.
  ///
  /// Insert-before rather than swap. Arranging a composition is moving one
  /// item through a sequence; a swap would fling whatever was already there
  /// back to where the dragged item came from, which is almost never what
  /// was meant.
  void _move(List<String> current, int from, int to) {
    if (from == to || from == to - 1) return;
    final List<String> next = List<String>.of(current);
    final String item = next.removeAt(from);
    next.insert(from < to ? to - 1 : to, item);
    onReorder?.call(next);
  }

  bool _dirExists() {
    try {
      return absoluteDir.isNotEmpty && Directory(absoluteDir).existsSync();
    } catch (_) {
      return false;
    }
  }

  /// A folder holding exactly one image is amber rather than green: one
  /// file satisfies "not empty" while almost never being what the shot
  /// wanted. Same call the asset manager makes.
  Widget _countBadge(int n) {
    if (n == 1) return const R3Tally(state: R3TallyState.warn);
    if (expectedCount != null && n < expectedCount!) {
      return const R3Tally(state: R3TallyState.warn);
    }
    return const R3Tally(state: R3TallyState.ok);
  }

  Widget _note(String text, Color color) {
    return Row(
      children: [
        R3Tally(
            state: color == R3Theme.danger
                ? R3TallyState.error
                : R3TallyState.warn),
        SizedBox(width: sc(8)),
        Text(text, style: theme.fine.copyWith(color: color)),
      ],
    );
  }
}

/// Boundary between source images that says whether they share one visual
/// MOSAIC pane. Lit means a pane ends here. Clicking a lit divider merges the
/// two panes; clicking a ghost divider splits the current pane here.
class _PaneBreakMarker extends StatefulWidget {
  final R3Theme theme;
  final double size;
  final bool active;
  final VoidCallback? onTap;

  const _PaneBreakMarker({
    required this.theme,
    required this.size,
    required this.active,
    required this.onTap,
  });

  @override
  State<_PaneBreakMarker> createState() => _PaneBreakMarkerState();
}

class _PaneBreakMarkerState extends State<_PaneBreakMarker> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final bool interactive = widget.onTap != null;
    final bool ghost = !widget.active && _hovered;
    return MouseRegion(
      cursor: interactive ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: interactive ? (_) => setState(() => _hovered = true) : null,
      onExit: interactive ? (_) => setState(() => _hovered = false) : null,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Tooltip(
          message: widget.active
              ? 'Pane ends here — click to merge'
              : 'Split pane here',
          waitDuration: const Duration(milliseconds: 350),
          child: SizedBox(
            width: sc(10),
            height: widget.size,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 90),
                width: widget.active ? sc(3) : sc(1),
                height: widget.active ? widget.size * 0.82 : widget.size * 0.45,
                decoration: BoxDecoration(
                  color: widget.active
                      ? widget.theme.accent
                      : (ghost ? widget.theme.accentDim : R3Theme.hairline),
                  borderRadius: BorderRadius.circular(sc(2)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A page boundary between two thumbnails, and the control that sets it.
///
/// Full-height bar rather than a gap, because a gap is what the Wrap already
/// puts between every pair and would say nothing. Lit when a page ends here,
/// ghosted on hover when one could, so the whole strip advertises that the
/// breaks are movable without drawing nine bars at once.
class _PageBreakMarker extends StatefulWidget {
  final R3Theme theme;
  final double size;
  final bool active;

  /// Forced by the three-panel cap rather than authored, so it is drawn but
  /// not offered as a control.
  final bool locked;

  final VoidCallback? onTap;

  const _PageBreakMarker({
    required this.theme,
    required this.size,
    required this.active,
    required this.locked,
    required this.onTap,
  });

  @override
  State<_PageBreakMarker> createState() => _PageBreakMarkerState();
}

class _PageBreakMarkerState extends State<_PageBreakMarker> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final bool interactive = widget.onTap != null;
    final bool lit = widget.active;
    final bool ghost = !lit && _hovered;

    return MouseRegion(
      cursor: interactive
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      onEnter: interactive ? (_) => setState(() => _hovered = true) : null,
      onExit: interactive ? (_) => setState(() => _hovered = false) : null,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Tooltip(
          message: widget.locked
              ? 'Page ends here. Three panes is the maximum, so this '
                  'break cannot be removed.'
              : (lit ? 'Page ends here' : 'Break the page here'),
          waitDuration: const Duration(milliseconds: 400),
          child: SizedBox(
            // Wider than the bar so it is comfortable to hit, while the
            // drawn mark stays thin enough not to read as a thumbnail.
            width: sc(12),
            height: widget.size,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 90),
                width: lit ? sc(3) : sc(1),
                height: lit ? widget.size : widget.size * 0.55,
                decoration: BoxDecoration(
                  color: lit
                      ? (widget.locked
                          ? widget.theme.accentDim
                          : widget.theme.accent)
                      : (ghost ? widget.theme.accentDim : R3Theme.hairline),
                  borderRadius: BorderRadius.circular(sc(2)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Drop target and drag handle for one position in the contact sheet.
///
/// Stateless: DragTarget's builder hands back candidateData, so the
/// insertion caret needs no state of its own and cannot get stuck lit after
/// a drag that ended somewhere else.
class _ReorderSlot extends StatelessWidget {
  final int index;
  final R3Theme theme;
  final double size;
  final void Function(int fromIndex) onMove;
  final Widget child;

  const _ReorderSlot({
    required this.index,
    required this.theme,
    required this.size,
    required this.onMove,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return DragTarget<int>(
      onWillAcceptWithDetails: (d) => d.data != index,
      onAcceptWithDetails: (d) => onMove(d.data),
      builder: (context, candidate, rejected) {
        final bool lit = candidate.isNotEmpty;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Insertion caret on the leading edge, so the drop reads as
            // "lands here, pushing the rest right" rather than "swaps with
            // this one".
            AnimatedContainer(
              duration: const Duration(milliseconds: 80),
              width: lit ? sc(3) : sc(1),
              height: size,
              color: lit ? theme.accent : Colors.transparent,
            ),
            SizedBox(width: sc(2)),
            Draggable<int>(
              data: index,
              // Horizontal affinity so a vertical drag still scrolls the
              // properties panel underneath. Without it, trying to scroll
              // with the pointer over a thumbnail picks the thumbnail up.
              affinity: Axis.horizontal,
              feedback: Opacity(
                opacity: 0.85,
                child: Material(color: Colors.transparent, child: child),
              ),
              childWhenDragging: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(sc(3)),
                  border: Border.all(color: theme.accentDim),
                ),
              ),
              child: child,
            ),
          ],
        );
      },
    );
  }
}

class _HoverRecycleThumb extends StatefulWidget {
  final String path;
  final ThumbKind kind;
  final double size;
  final R3Theme theme;
  final Future<void> Function(String absolutePath)? onRecycle;

  /// 1-based load position, shown in the corner when reordering is on.
  ///
  /// Worth the pixels because position has meaning downstream and it is not
  /// otherwise visible: MOSAIC builds its hero panel from the first of each
  /// page of three, so 1, 4 and 7 are the big ones, and a TIMELINE stage
  /// pairs photo i with event i.
  final int? position;

  /// MOSAIC pane authoring furniture. [isHero] is drawn even when false as
  /// a hover target so any image can be promoted without opening another
  /// form. Direction appears only on the hero of multi-image panes.
  final bool isHero;
  final VoidCallback? onHeroTap;
  final String? directionLabel;
  final VoidCallback? onDirectionTap;

  /// This thumbnail's PANE fit, as a chip label: 'FIT' for the vertical
  /// edge, 'FITW' for the horizontal one, null for the FILL default.
  ///
  /// Shown on every image of a fitted pane so the state is readable from
  /// any thumbnail, while [onFitTap] is supplied only on the pane's first
  /// image, which is where the control lives. Tapping cycles rather than
  /// toggles, so the label is what tells you where in the cycle you are.
  final String? fitLabel;
  final VoidCallback? onFitTap;

  /// Caption authoring. [hasCaption] marks an image whose caption is ON,
  /// so a folder's annotated images are findable at a glance. [selected]
  /// is pure view state: which image the sidebar profile is showing.
  ///
  /// Selection is a TAP on the image body, which was free. Every existing
  /// pane control is a chip in a corner and all four corners are taken, so
  /// a fifth chip was not available even if a chip were the right shape
  /// for opening a panel, which it is not.
  final bool hasCaption;
  final bool selected;
  final VoidCallback? onSelect;

  /// Extra frames this image is held, or 0. Shown as a badge because a
  /// hold is the one pane fact you cannot see by looking at the render:
  /// a photograph that sits a beat longer looks exactly like one that
  /// does not until you count frames.
  final int holdFrames;

  const _HoverRecycleThumb({
    required this.path,
    required this.kind,
    required this.size,
    required this.theme,
    required this.onRecycle,
    this.position,
    this.isHero = false,
    this.onHeroTap,
    this.directionLabel,
    this.onDirectionTap,
    this.fitLabel,
    this.onFitTap,
    this.hasCaption = false,
    this.selected = false,
    this.onSelect,
    this.holdFrames = 0,
  });

  @override
  State<_HoverRecycleThumb> createState() => _HoverRecycleThumbState();
}

class _HoverRecycleThumbState extends State<_HoverRecycleThumb> {
  bool _hovered = false;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final bool canRecycle = widget.onRecycle != null;
    final bool hasPaneControls = widget.onHeroTap != null ||
        widget.onDirectionTap != null ||
        widget.onFitTap != null ||
        widget.onSelect != null;
    return MouseRegion(
      onEnter: (canRecycle || hasPaneControls)
          ? (_) => setState(() => _hovered = true)
          : null,
      onExit: (canRecycle || hasPaneControls)
          ? (_) => setState(() => _hovered = false)
          : null,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Tap selects for the sidebar profile. Wrapped around the thumb
          // itself rather than the whole Stack so it never swallows a
          // click meant for the star, the chips, or the recycle X, which
          // sit above it in paint order.
          GestureDetector(
            onTap: widget.onSelect,
            child: AssetThumb(
              path: widget.path,
              kind: widget.kind,
              size: widget.size,
              theme: widget.theme,
            ),
          ),
          // Selection ring. Drawn as an overlay rather than a border on
          // the thumb so it cannot change the layout size and reflow the
          // whole sheet on every click.
          if (widget.selected)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(sc(3)),
                    border: Border.all(color: widget.theme.accent, width: sc(2)),
                  ),
                ),
              ),
            ),
          // A captioned image is worth finding at a glance in a folder of
          // forty scans. Top right, above the recycle X, which only
          // appears on hover.
          if ((widget.hasCaption || widget.holdFrames > 0) && !_hovered)
            Positioned(
              top: sc(3),
              right: sc(3),
              child: IgnorePointer(
                child: Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: sc(4), vertical: sc(1)),
                  decoration: BoxDecoration(
                    color: const Color(0xD9000000),
                    borderRadius: BorderRadius.circular(sc(2)),
                  ),
                  child: Text(
                      widget.holdFrames > 0
                          ? (widget.hasCaption
                              ? 'C +${widget.holdFrames}'
                              : '+${widget.holdFrames}')
                          : 'C',
                      style: widget.theme.fine.copyWith(
                          color: widget.theme.accent, height: 1.1)),
                ),
              ),
            ),
          // Bottom left, opposite corner from the recycle X, so the two
          // never overlap on a small thumbnail.
          if (widget.position != null)
            Positioned(
              left: sc(3),
              bottom: sc(3),
              child: Container(
                padding: EdgeInsets.symmetric(
                    horizontal: sc(4), vertical: sc(1)),
                decoration: BoxDecoration(
                  color: const Color(0xD9000000),
                  borderRadius: BorderRadius.circular(sc(2)),
                ),
                child: Text(
                  '${widget.position}',
                  style: widget.theme.fine
                      .copyWith(color: R3Theme.textBright, height: 1.1),
                ),
              ),
            ),
          if (widget.onHeroTap != null && (widget.isHero || _hovered))
            Positioned(
              left: sc(3),
              top: sc(3),
              child: Tooltip(
                message: widget.isHero
                    ? 'Remove Pane Life hero'
                    : 'Select Pane Life hero',
                child: Material(
                  color: const Color(0xD9000000),
                  borderRadius: BorderRadius.circular(sc(3)),
                  child: InkWell(
                    onTap: widget.onHeroTap,
                    borderRadius: BorderRadius.circular(sc(3)),
                    child: SizedBox(
                      width: sc(20),
                      height: sc(20),
                      child: Icon(
                        widget.isHero ? Icons.star : Icons.star_border,
                        size: sc(14),
                        color: widget.isHero
                            ? widget.theme.accent
                            : Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          // Pane properties share the bottom-right corner as one row. They
          // are the same kind of fact and they can both apply to the same
          // thumbnail (a one-image starred pane that also fits), so they
          // cannot each own the corner outright.
          if (widget.directionLabel != null ||
              widget.fitLabel != null ||
              (widget.onFitTap != null && _hovered))
            Positioned(
              right: sc(3),
              bottom: sc(3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.fitLabel != null ||
                      (widget.onFitTap != null && _hovered))
                    Padding(
                      padding: EdgeInsets.only(right: sc(3)),
                      child: Tooltip(
                        message: widget.fitLabel == 'FIT'
                            ? 'Fits the vertical edge. Click for the '
                                'horizontal edge'
                            : (widget.fitLabel == 'FITW'
                                ? 'Fits the horizontal edge. Click to fill '
                                    'and crop'
                                : 'Fills and crops. Click to fit the '
                                    'vertical edge'),
                        child: Material(
                          color: const Color(0xD9000000),
                          borderRadius: BorderRadius.circular(sc(2)),
                          child: InkWell(
                            onTap: widget.onFitTap,
                            borderRadius: BorderRadius.circular(sc(2)),
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                  horizontal: sc(4), vertical: sc(2)),
                              child: Text(
                                // The dim 'FIT' on a FILL pane is the
                                // affordance, not a state: it says a fit
                                // is available here, and the cycle starts
                                // with the one you probably want.
                                widget.fitLabel ?? 'FIT',
                                style: widget.theme.fine.copyWith(
                                  color: widget.fitLabel != null
                                      ? widget.theme.accent
                                      : R3Theme.textDim,
                                  height: 1.0,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (widget.directionLabel != null)
                    Tooltip(
                      message: 'Pane direction, click to flip',
                      child: Material(
                        color: const Color(0xD9000000),
                        borderRadius: BorderRadius.circular(sc(2)),
                        child: InkWell(
                          onTap: widget.onDirectionTap,
                          borderRadius: BorderRadius.circular(sc(2)),
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: sc(4), vertical: sc(2)),
                            child: Text(widget.directionLabel!,
                                style: widget.theme.fine.copyWith(
                                    color: widget.theme.accent, height: 1.0)),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          if (canRecycle && (_hovered || _busy))
            Positioned(
              top: sc(3),
              right: sc(3),
              child: Tooltip(
                message: 'Move to recycle',
                child: Material(
                  color: const Color(0xD9000000),
                  borderRadius: BorderRadius.circular(sc(3)),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(sc(3)),
                    onTap: _busy
                        ? null
                        : () async {
                            setState(() => _busy = true);
                            try {
                              await widget.onRecycle!(widget.path);
                            } finally {
                              if (mounted) setState(() => _busy = false);
                            }
                          },
                    child: SizedBox(
                      width: sc(20),
                      height: sc(20),
                      child: _busy
                          ? Padding(
                              padding: EdgeInsets.all(sc(5)),
                              child: const CircularProgressIndicator(
                                strokeWidth: 1.5,
                                color: Colors.white,
                              ),
                            )
                          : Icon(Icons.close,
                              size: sc(14), color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Drop targeting
// ---------------------------------------------------------------------------

/// A region that can accept an OS file drop, and what to do when it does.
class _RegisteredZone {
  final GlobalKey key;
  void Function(List<String> paths) onDrop;

  _RegisteredZone(this.key, this.onDrop);
}

/// Maps a drop position to the field that should receive it.
///
/// The runner reports where a drop landed, but the single-listener [DropBus]
/// only says which screen is listening. This registry closes the gap: every
/// asset field wraps itself in a [DropTargetRegion], and the screen holding
/// the bus claim asks [dispatch] to find which region the point fell inside.
///
/// Geometry is read live from each region's RenderBox rather than cached,
/// because the properties panel scrolls and rebuilds constantly and a cached
/// rect would send a drop to whatever used to be under the cursor. Regions
/// do not overlap in practice (they are rows in one scroll view), so the
/// first containing region wins and no z-order is tracked.
class DropZoneRegistry {
  static final Map<String, _RegisteredZone> _zones = {};

  /// Registers, or refreshes the handler for, the region [id]. Called on
  /// every rebuild: the handler is a closure over the node and field it
  /// belongs to, so a stale one would import into an old node object.
  static void register(
      String id, GlobalKey key, void Function(List<String> paths) onDrop) {
    final _RegisteredZone? existing = _zones[id];
    if (existing != null && existing.key == key) {
      existing.onDrop = onDrop;
      return;
    }
    _zones[id] = _RegisteredZone(key, onDrop);
  }

  static void unregister(String id) => _zones.remove(id);

  /// The region containing [globalPosition], or null.
  ///
  /// Shared by hover and drop rather than duplicated, so the field that
  /// lights up under the cursor is provably the field that will receive the
  /// file. Two hit tests that agreed almost always would be worse than one:
  /// the highlight is a promise about where the drop goes.
  static String? hitTest(Offset globalPosition) {
    for (final entry in _zones.entries) {
      final BuildContext? ctx = entry.value.key.currentContext;
      if (ctx == null) continue;
      final RenderObject? ro = ctx.findRenderObject();
      if (ro is! RenderBox || !ro.attached || !ro.hasSize) continue;

      final Rect rect = ro.localToGlobal(Offset.zero) & ro.size;
      if (rect.contains(globalPosition)) return entry.key;
    }
    return null;
  }

  /// True when [globalPosition] fell inside a registered region, which then
  /// received [paths]. False means the caller should fall back to whatever
  /// it pinned, or ignore the drop.
  static bool dispatch(Offset globalPosition, List<String> paths) {
    final String? id = hitTest(globalPosition);
    if (id == null) return false;

    // Re-read rather than trusting a handle from the hit test: the map is
    // rewritten on every build and the region could have been replaced in
    // between, though not within one frame.
    final _RegisteredZone? zone = _zones[id];
    if (zone == null) return false;

    zone.onDrop(paths);
    return true;
  }

  /// Drops every registration. The properties panel calls this when it tears
  /// down, so a region cannot outlive the screen that gave it meaning.
  static void clear() => _zones.clear();
}

/// Wraps the region of the UI that a drop over it should target.
///
/// Deliberately wraps a whole field rather than just the visible drop bar:
/// the bar is the affordance, but a drop that lands on the field's label or
/// its thumbnail obviously means that field, and making the user hit a
/// 30 pixel strip would be a worse tool for no gain.
class DropTargetRegion extends StatefulWidget {
  /// Stable across rebuilds and unique within the screen. The field key
  /// ("nodeId|paramKey") is what the node panel uses.
  final String id;

  final void Function(List<String> paths) onDrop;
  final Widget child;

  const DropTargetRegion({
    super.key,
    required this.id,
    required this.onDrop,
    required this.child,
  });

  @override
  State<DropTargetRegion> createState() => _DropTargetRegionState();
}

class _DropTargetRegionState extends State<DropTargetRegion> {
  final GlobalKey _boxKey = GlobalKey();

  @override
  void dispose() {
    DropZoneRegistry.unregister(widget.id);
    super.dispose();
  }

  @override
  void didUpdateWidget(DropTargetRegion old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id) DropZoneRegistry.unregister(old.id);
  }

  @override
  Widget build(BuildContext context) {
    // Registered during build rather than in initState, because the handler
    // closes over state that changes between builds and the registry must
    // hold the current one, not the first one.
    DropZoneRegistry.register(widget.id, _boxKey, widget.onDrop);
    return KeyedSubtree(key: _boxKey, child: widget.child);
  }
}

// ---------------------------------------------------------------------------
// Drop zone
// ---------------------------------------------------------------------------

/// The visible drop affordance for a field, and the pin control.
///
/// Dropping onto the field imports there, no click required: the runner
/// reports the drop position and [DropZoneRegistry] resolves it. While a
/// drag is in flight the runner also reports motion, so the field under the
/// cursor lights up before the user commits. Pinning exists for the drop
/// that lands somewhere else on the window, on the node list or outside the
/// panel, where there is no field under the cursor to resolve to. A pinned
/// field catches those.
class AssetDropZone extends StatelessWidget {
  final R3Theme theme;

  /// True when a drag is currently over this field. Takes visual priority
  /// over [pinned], because it answers the more immediate question: pinned
  /// says where a drop would go if you missed, hovering says where this one
  /// is going right now.
  final bool hovering;

  /// True when this field is the catch-all for drops that hit no field.
  final bool pinned;

  /// What a drop will do, in one short line. Differs per slot and per
  /// whether the field currently names anything.
  final String hint;

  final VoidCallback onPin;
  final VoidCallback onUnpin;

  /// Set while an import is running so the control cannot be re-hit
  /// mid-copy.
  final bool busy;

  const AssetDropZone({
    super.key,
    required this.theme,
    required this.pinned,
    required this.hint,
    required this.onPin,
    required this.onUnpin,
    this.hovering = false,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final bool lit = hovering || pinned;
    final Color border = hovering
        ? theme.accent
        : (pinned ? theme.accentDim : R3Theme.hairline);
    final Color fill = lit ? theme.accentFaint : Colors.transparent;
    final Color ink = lit ? theme.accent : R3Theme.textDim;

    return AnimatedContainer(
      // Short enough to feel immediate under a moving cursor. The motion
      // stream is throttled in the runner and only repaints on a target
      // change, so this animates once per field crossed rather than
      // continuously.
      duration: const Duration(milliseconds: 90),
      width: double.infinity,
      padding: EdgeInsets.symmetric(horizontal: sc(10), vertical: sc(9)),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(sc(4)),
        border: Border.all(color: border, width: hovering ? 1.5 : 1),
      ),
      child: Row(
        children: [
          Icon(
            busy
                ? Icons.hourglass_empty
                : (hovering
                    ? Icons.file_download_outlined
                    : (pinned
                        ? Icons.push_pin_outlined
                        : Icons.add_photo_alternate_outlined)),
            size: sc(15),
            color: ink,
          ),
          SizedBox(width: sc(10)),
          Expanded(
            child: Text(
              busy
                  ? 'IMPORTING...'
                  : (hovering
                      ? 'RELEASE TO IMPORT: $hint'
                      : (pinned
                          ? 'PINNED. ANY DROP LANDS HERE: $hint'
                          : 'DROP FILES HERE: $hint')),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.micro.copyWith(color: ink),
            ),
          ),
          // Hidden while hovering: a click target is meaningless with a drag
          // in flight, and the row should read as one statement about where
          // the file is about to land.
          if (!busy && !hovering)
            InkWell(
              onTap: pinned ? onUnpin : onPin,
              borderRadius: BorderRadius.circular(sc(3)),
              child: Padding(
                padding:
                    EdgeInsets.symmetric(horizontal: sc(8), vertical: sc(4)),
                child: Text(
                  pinned ? 'UNPIN' : 'PIN',
                  style: theme.fine.copyWith(
                    color: pinned ? theme.accent : R3Theme.textDim,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}