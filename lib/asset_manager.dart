// ./lib/asset_manager.dart

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'folder_captions.dart';
import 'parser.dart';
import 'presentation_requests.dart' show kBrowserMaxPages;
import 'ui_theme.dart';

/// Name of the authoring trash folder inside images/.
///
/// Shared rather than repeated, because three features have to agree about
/// it and they fail in different directions when they do not: the node
/// panel's pickers must hide it (or the bin looks like a source folder),
/// the orphan scan must skip it (or your trash is reported as clutter to
/// clean up), and the recycle browser must find it. A literal in each place
/// is three chances to drift.
const String kRecycleFolderName = '_recycle';

/// What kind of thing a script reference resolves to on disk.
enum AssetKind {
  /// A single file inside the workspace images/ folder
  /// (CARD image, SVG stencil, IMG tile, PHOTO scan, wallpaper).
  imageFile,

  /// A folder inside images/ whose CONTENTS are the asset
  /// (GALLERY, VIDEO, APP, TIMELINE stage, SVGFLASH).
  imageFolder,

  /// A single file inside the workspace sprites/ folder.
  spriteFile,
}

enum AssetStatus {
  /// Exists, and (for folders) contains at least one usable file.
  ok,

  /// Does not exist on disk.
  missing,

  /// Folder exists but contains no files of the expected type — the
  /// runtime treats this the same as missing (dud, warning, burned hold),
  /// so the manager surfaces it distinctly.
  emptyFolder,

  /// Folder has content, but fewer usable files than the script's NEEDS
  /// directive declared. Nothing breaks: the shot renders with what is
  /// there. It just renders with less than the author asked for, which is
  /// invisible at author time unless the manager says so.
  shortCount,
}

/// One asset reference pulled from the script, with its resolved disk
/// status. A path referenced by multiple tags (e.g. the same folder used
/// by a GALLERY and an APP) is merged into one ref; [usedBy] lists every
/// tag that touches it.
class AssetRef {
  final AssetKind kind;

  /// The path exactly as written in the script (relative to images/ or
  /// sprites/ depending on kind).
  final String scriptPath;

  /// Resolved absolute path in the active workspace.
  final String absolutePath;

  /// Tag names that reference this asset ("GALLERY", "CARD", "CONFIG:DESKTOP"...).
  final Set<String> usedBy;

  /// File extensions (lowercase, with dot) that count as "usable content"
  /// when this is a folder. Merged across tags: a folder used by both
  /// SVGFLASH and GALLERY accepts either family.
  final Set<String> expectedExts;

  AssetStatus status;

  /// Number of usable files found on disk. Only meaningful for
  /// [AssetKind.imageFolder]; file refs leave it at 0.
  ///
  /// This exists because "the folder is not empty" and "the folder has what
  /// the shot needs" are different questions, and the status alone can only
  /// answer the first. A GALLERY with one image and an APP MOSAIC with one
  /// image both resolve to OK, and both are almost certainly wrong.
  int fileCount;

  /// How many usable files the script says this folder should hold, from a
  /// NEEDS directive. Null when the script never declared one, which is the
  /// default and leaves behavior exactly as it was.
  int? expectedCount;

  AssetRef({
    required this.kind,
    required this.scriptPath,
    required this.absolutePath,
    required this.usedBy,
    required this.expectedExts,
    this.status = AssetStatus.missing,
    this.fileCount = 0,
    this.expectedCount,
  });
}

/// Files sitting in the workspace that no script reference touches.
/// Informational only — R3nder never deletes anything.
class OrphanEntry {
  /// Path relative to the workspace (e.g. "images/old_logo.svg").
  final String relativePath;

  /// True if this is a whole unreferenced directory.
  final bool isFolder;

  OrphanEntry({required this.relativePath, required this.isFolder});
}

class AssetScanResult {
  final List<AssetRef> refs;
  final List<OrphanEntry> orphans;

  AssetScanResult({required this.refs, required this.orphans});

  int get missingCount =>
      refs.where((r) => r.status != AssetStatus.ok).length;
}

/// Raster extensions the SceneEngine's folder loader accepts.
const Set<String> _kRasterExts = {'.png', '.jpg', '.jpeg', '.webp', '.bmp'};
const Set<String> _kSvgExts = {'.svg'};

// -----------------------------------------------------------------------
// OS drop bridge
// -----------------------------------------------------------------------

/// One file drop from the OS: what was dropped, and where.
///
/// [position] is in Flutter logical pixels relative to the view origin,
/// directly comparable to a RenderBox's global rect, so a listener can hit
/// test the drop against a widget. Null when the runner did not send one,
/// which is the pre-position payload shape: a listener that needs a target
/// must fall back to something it nominated beforehand.
class DropEvent {
  final List<String> paths;
  final Offset? position;

  const DropEvent({required this.paths, this.position});

  bool get hasPosition => position != null;
}

/// Receives file paths dropped onto the app window, forwarded from the
/// native GTK runner over the "r3nder/drop" method channel.
///
/// Design: the C side fires "onDrop" for EVERY drop, regardless of app
/// state. This bus holds at most ONE active listener, whichever UI element
/// currently gives drops a meaning. Drops arriving with no listener are
/// silently ignored, so dropping a file onto the menu does nothing.
///
/// A single listener is still right even though the payload now carries a
/// position. Position decides which widget inside a screen takes the drop;
/// the claim decides which screen is listening at all. Those are different
/// questions, and only one screen is ever up.
class DropBus {
  static const MethodChannel _channel = MethodChannel('r3nder/drop');
  static bool _initialized = false;

  static void Function(DropEvent event)? _listener;

  /// Hover feedback, both optional. A claimant that only cares about the
  /// commit passes neither and behaves exactly as before.
  ///
  /// These are advisory by design and the runner treats them the same way.
  /// If they never fire, because the C half has not been rebuilt or because
  /// a future platform does not report motion, the drop path is unaffected:
  /// the cost is a missing highlight, not a missing import. Nothing should
  /// ever be made to depend on having seen a motion event before a drop.
  static void Function(Offset position)? _onMotion;
  static VoidCallback? _onLeave;

  static void _ensureInit() {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onDrop':
          final DropEvent? event = _decode(call.arguments);
          if (event != null && event.paths.isNotEmpty) {
            _listener?.call(event);
          }
          // A drop ends the drag, so any highlight it produced is now stale.
          // Fired after the drop so a listener sees the import first and
          // does not have to defend its result message against a clear.
          _onLeave?.call();
          break;

        case 'onDragMotion':
          final Offset? p = _decodePoint(call.arguments);
          if (p != null) _onMotion?.call(p);
          break;

        case 'onDragLeave':
          _onLeave?.call();
          break;
      }
      return null;
    });
  }

  /// Reads either payload shape.
  ///
  /// A Map carries paths plus an x/y position. A bare List is the older
  /// shape and carries no position. Both are accepted on purpose: the C
  /// half needs a full rebuild while Dart hot-reloads, so the two are
  /// routinely out of step during development, and a hard failure there
  /// would look like broken drag-and-drop rather than a stale binary.
  static DropEvent? _decode(dynamic args) {
    if (args is List) {
      return DropEvent(paths: args.map((e) => e.toString()).toList());
    }
    if (args is Map) {
      final dynamic rawPaths = args['paths'];
      if (rawPaths is! List) return null;
      final List<String> paths =
          rawPaths.map((e) => e.toString()).toList();

      return DropEvent(paths: paths, position: _decodePoint(args));
    }
    return null;
  }

  /// An x/y pair out of a channel map, or null if either is missing. Shared
  /// by the drop and motion paths so the two cannot disagree about what a
  /// position looks like on the wire.
  static Offset? _decodePoint(dynamic args) {
    if (args is! Map) return null;
    final num? x = args['x'] as num?;
    final num? y = args['y'] as num?;
    if (x == null || y == null) return null;
    return Offset(x.toDouble(), y.toDouble());
  }

  /// Claims the drop listener. Returns a release callback; ALWAYS call it
  /// (e.g. in a finally) or drops will leak to a dead widget. Claiming
  /// while another listener is active replaces it — last claim wins, which
  /// matches dialog stacking order.
  ///
  /// [onMotion] and [onLeave] are released by the same callback, so a
  /// claimant cannot accidentally keep receiving hover events after giving
  /// up the drop.
  static VoidCallback listen(
    void Function(DropEvent event) onDrop, {
    void Function(Offset position)? onMotion,
    VoidCallback? onLeave,
  }) {
    _ensureInit();
    _listener = onDrop;
    _onMotion = onMotion;
    _onLeave = onLeave;
    return () {
      if (identical(_listener, onDrop)) {
        _listener = null;
        _onMotion = null;
        _onLeave = null;
      }
    };
  }
}

// -----------------------------------------------------------------------
// Scanner
// -----------------------------------------------------------------------

class AssetScanner {
  /// Scans [docText] (the raw template text, straight from disk or the
  /// editor buffer) and resolves every asset reference against the active
  /// workspace. Pure and synchronous — safe to call on every template load.
  ///
  /// Mirrors SceneEngine.setup() exactly: the wallpaper comes from the raw
  /// text's [CONFIG:DESKTOP:...], everything else from tagRegex matches on
  /// the PREPROCESSED text, so commented-out tags don't count here either.
  static AssetScanResult scan({
    required String docText,
    required String imagesDir,
    required String spritesDir,
  }) {
    // Keyed on "<kind>|<scriptPath>" so duplicate references merge.
    final Map<String, AssetRef> refs = {};

    void addRef(AssetKind kind, String scriptPath, String tag,
        Set<String> expectedExts) {
      final String cleaned = scriptPath.trim();
      if (cleaned.isEmpty) return;

      final String base =
          kind == AssetKind.spriteFile ? spritesDir : imagesDir;
      final String key = '${kind.name}|$cleaned';

      final existing = refs[key];
      if (existing != null) {
        existing.usedBy.add(tag);
        existing.expectedExts.addAll(expectedExts);
      } else {
        refs[key] = AssetRef(
          kind: kind,
          scriptPath: cleaned,
          absolutePath: '$base/$cleaned',
          usedBy: {tag},
          expectedExts: Set.of(expectedExts),
        );
      }
    }

    // Wallpaper: read from the RAW text, because preprocessScript strips
    // CONFIG tags before tagRegex would ever see them.
    final desktopMatch =
        RegExp(r'\[CONFIG:DESKTOP:([^\]]+)\]').firstMatch(docText);
    if (desktopMatch != null) {
      addRef(AssetKind.imageFile, desktopMatch.group(1)!, 'CONFIG:DESKTOP',
          const {});
    }

    // Declared folder counts, read from the RAW text for the same reason as
    // the wallpaper above: NEEDS lives inside a [# comment], so
    // preprocessScript deletes it before tagRegex could ever see it.
    //
    //   [#NEEDS:panels_x9:9]
    //
    // The engine never sees this. It exists purely so the asset manager can
    // say "6 of 9" instead of a green OK that tells the author nothing. A
    // folder with no directive behaves exactly as it always has.
    final Map<String, int> declaredCounts = {};
    for (final m in RegExp(r'\[#\s*NEEDS:\s*([^\s:\]]+)\s*:\s*(\d+)\s*\]')
        .allMatches(docText)) {
      final String folder = m.group(1)!;
      final int want = int.tryParse(m.group(2)!) ?? 0;
      if (want <= 0) continue;
      // Declared twice, take the larger: whichever shot needs the most wins.
      final int? prev = declaredCounts[folder];
      declaredCounts[folder] = (prev == null || want > prev) ? want : prev;
    }

    // Everything else: preprocess first (strips [# comments] and CONFIG
    // lines), then walk tagRegex — the same pass SceneEngine.setup runs.
    final String pre = ScriptParser.preprocessScript(docText);

    for (final match in tagRegex.allMatches(pre)) {
      final galFolder = match.namedGroup('galFolder');
      final vidFolder = match.namedGroup('vidFolder');
      final appFolder = match.namedGroup('appFolder');
      final browFolder = match.namedGroup('browFolder');
      final dosFolder = match.namedGroup('dosFolder');
      final dosImg = match.namedGroup('dosImg');
      final tlStage = match.namedGroup('tlStage');
      final svgfFolder = match.namedGroup('svgfFolder');
      final cardImg = match.namedGroup('cardImg');
      final svgFile = match.namedGroup('svgFile');
      final imgFile = match.namedGroup('imgFile');
      final photoFile = match.namedGroup('photoFile');
      final spritePath = match.namedGroup('spritePath');
      final spriteOff = match.namedGroup('spriteOff');

      if (galFolder != null) {
        addRef(AssetKind.imageFolder, galFolder, 'GALLERY', _kRasterExts);
      }
      if (vidFolder != null) {
        addRef(AssetKind.imageFolder, vidFolder, 'VIDEO', _kRasterExts);
      }
      if (appFolder != null) {
        addRef(AssetKind.imageFolder, appFolder, 'APP', _kRasterExts);
      }
      if (browFolder != null) {
        addRef(AssetKind.imageFolder, browFolder, 'BROWSER', _kRasterExts);
      }
      if (dosFolder != null) {
        addRef(AssetKind.imageFolder, dosFolder, 'DOSSIER (Gallery)', _kRasterExts);
      }
      if (dosImg != null) {
        addRef(AssetKind.imageFile, dosImg, 'DOSSIER (Card)', const {});
      }
      if (tlStage != null) {
        addRef(AssetKind.imageFolder, tlStage, 'TIMELINE stage', _kRasterExts);
      }
      if (svgfFolder != null) {
        addRef(AssetKind.imageFolder, svgfFolder, 'SVGFLASH', _kSvgExts);
      }
      if (cardImg != null) {
        addRef(AssetKind.imageFile, cardImg, 'CARD', const {});
      }
      if (svgFile != null) {
        addRef(AssetKind.imageFile, svgFile, 'SVG', const {});
      }
      if (imgFile != null) {
        addRef(AssetKind.imageFile, imgFile, 'IMG', const {});
      }
      if (photoFile != null) {
        addRef(AssetKind.imageFile, photoFile, 'PHOTO', const {});
      }
      if (spritePath != null) {
        addRef(AssetKind.spriteFile, spritePath, 'SPRITE', const {});
      }
      // SPRITE_OFF references the same file; count it so a script that
      // only turns a sprite off still shows the dependency.
      if (spriteOff != null) {
        addRef(AssetKind.spriteFile, spriteOff, 'SPRITE_OFF', const {});
      }
    }

    // ---------------------------------------------------------------
    // Resolve status
    // ---------------------------------------------------------------
    for (final ref in refs.values) {
      switch (ref.kind) {
        case AssetKind.imageFile:
        case AssetKind.spriteFile:
          ref.status = File(ref.absolutePath).existsSync()
              ? AssetStatus.ok
              : AssetStatus.missing;
          break;

        case AssetKind.imageFolder:
          final dir = Directory(ref.absolutePath);
          if (!dir.existsSync()) {
            ref.status = AssetStatus.missing;
            ref.fileCount = 0;
            break;
          }
          // Count rather than test for existence: the author needs to see
          // whether a folder holds one image or nine, and the status alone
          // cannot carry that.
          ref.fileCount = dir.listSync().whereType<File>().where((f) {
            final String p = f.path.toLowerCase();
            return ref.expectedExts.any(p.endsWith);
          }).length;

          ref.expectedCount = declaredCounts[ref.scriptPath];

          if (ref.fileCount == 0) {
            ref.status = AssetStatus.emptyFolder;
          } else if (ref.expectedCount != null &&
              ref.fileCount < ref.expectedCount!) {
            ref.status = AssetStatus.shortCount;
          } else {
            ref.status = AssetStatus.ok;
          }
          break;
      }
    }

    // ---------------------------------------------------------------
    // Orphans: top-level entries in images/ and sprites/ that nothing
    // references. A file inside a referenced folder is covered by the
    // folder; a file reference with a subpath ("people/mark.png") covers
    // its parent directory from being flagged wholesale.
    // ---------------------------------------------------------------
    final Set<String> referencedImageFiles = {};
    final Set<String> referencedImageFolders = {};
    final Set<String> referencedSprites = {};

    for (final ref in refs.values) {
      switch (ref.kind) {
        case AssetKind.imageFile:
          referencedImageFiles.add(ref.scriptPath);
          break;
        case AssetKind.imageFolder:
          referencedImageFolders.add(ref.scriptPath);
          break;
        case AssetKind.spriteFile:
          referencedSprites.add(ref.scriptPath);
          break;
      }
    }

    final List<OrphanEntry> orphans = [];

    final imagesRoot = Directory(imagesDir);
    if (imagesRoot.existsSync()) {
      for (final entity in imagesRoot.listSync()) {
        final String name = entity.path.split(Platform.pathSeparator).last;
        if (name.startsWith('.')) continue;

        // The recycle bin is unreferenced by definition: everything in it was
        // removed from a script on purpose. Reporting it as an orphan would
        // invite cleaning up the one folder that exists to make removal
        // reversible.
        if (entity is Directory &&
            name.toLowerCase() == kRecycleFolderName) {
          continue;
        }

        if (entity is File) {
          if (!referencedImageFiles.contains(name)) {
            orphans.add(
                OrphanEntry(relativePath: 'images/$name', isFolder: false));
          }
        } else if (entity is Directory) {
          final bool asFolder = referencedImageFolders
              .any((f) => f == name || f.startsWith('$name/'));
          final bool holdsRefFile =
              referencedImageFiles.any((f) => f.startsWith('$name/'));
          if (!asFolder && !holdsRefFile) {
            orphans.add(
                OrphanEntry(relativePath: 'images/$name', isFolder: true));
          }
        }
      }
    }

    final spritesRoot = Directory(spritesDir);
    if (spritesRoot.existsSync()) {
      for (final entity in spritesRoot.listSync()) {
        if (entity is! File) continue;
        final String name = entity.path.split(Platform.pathSeparator).last;
        if (name.startsWith('.')) continue;
        if (!referencedSprites.contains(name) &&
            !referencedSprites.any((s) => s.endsWith('/$name'))) {
          orphans.add(
              OrphanEntry(relativePath: 'sprites/$name', isFolder: false));
        }
      }
    }

    orphans.sort((a, b) => a.relativePath.compareTo(b.relativePath));

    final List<AssetRef> sorted = refs.values.toList()
      ..sort((a, b) {
        // Problems float to the top, then alphabetical.
        final int pa = a.status == AssetStatus.ok ? 1 : 0;
        final int pb = b.status == AssetStatus.ok ? 1 : 0;
        if (pa != pb) return pa - pb;
        return a.scriptPath.compareTo(b.scriptPath);
      });

    return AssetScanResult(refs: sorted, orphans: orphans);
  }
}

// -----------------------------------------------------------------------
// Import logic (shared by drop and typed-path flows)
// -----------------------------------------------------------------------

class AssetImporter {
  /// Imports a single source path (file OR directory, as dropped/typed)
  /// into [ref]'s destination. Throws a String message on failure.
  ///
  ///  - file ref + source file      -> copy to the exact destination path
  ///  - folder ref + source dir     -> copy the dir's files into destination
  ///  - folder ref + source file    -> copy that file into the destination
  static void importPath(AssetRef ref, String src) {
    if (src.isEmpty) throw 'No source path given.';

    final bool srcIsDir = Directory(src).existsSync();
    final bool srcIsFile = File(src).existsSync();
    if (!srcIsDir && !srcIsFile) throw 'Source not found: $src';

    if (ref.kind == AssetKind.imageFolder) {
      Directory(ref.absolutePath).createSync(recursive: true);
      if (srcIsDir) {
        int copied = 0;
        for (final entity in Directory(src).listSync()) {
          if (entity is! File) continue;
          final String name =
              entity.path.split(Platform.pathSeparator).last;
          if (name.startsWith('.')) continue;
          entity.copySync('${ref.absolutePath}/$name');
          copied++;
        }
        if (copied == 0) throw 'Source folder contained no files.';
      } else {
        final String name = src.split(Platform.pathSeparator).last;
        File(src).copySync('${ref.absolutePath}/$name');
      }
    } else {
      // File-kind destination.
      if (srcIsDir) {
        throw 'This asset is a single file — drop or enter a file, not a folder.';
      }
      Directory(File(ref.absolutePath).parent.path)
          .createSync(recursive: true);
      File(src).copySync(ref.absolutePath);
    }
  }

  /// Imports a batch of dropped paths into [ref]. For file refs only the
  /// first path is used (extras reported); for folder refs every path is
  /// imported (files copied in, directories copied contents-wise).
  /// Returns a human-readable summary. Throws a String on total failure.
  static String importDropped(AssetRef ref, List<String> paths) {
    if (paths.isEmpty) throw 'Nothing dropped.';

    if (ref.kind != AssetKind.imageFolder) {
      importPath(ref, paths.first);
      return paths.length > 1
          ? 'Imported first of ${paths.length} dropped items.'
          : 'Imported.';
    }

    int ok = 0;
    String? firstError;
    for (final p in paths) {
      try {
        importPath(ref, p);
        ok++;
      } catch (e) {
        firstError ??= e.toString();
      }
    }
    if (ok == 0) throw firstError ?? 'Import failed.';
    return 'Imported $ok of ${paths.length} dropped item(s).';
  }
}

// -----------------------------------------------------------------------
// Screen
// -----------------------------------------------------------------------

class AssetManagerScreen extends StatefulWidget {
  /// The template text to scan (the editor buffer / loaded doc — may be
  /// newer than disk, which is exactly what we want).
  final String docText;

  final String imagesDir;
  final String spritesDir;
  final VoidCallback onClose;

  /// Active phosphor color, so the manager's accent matches the rest of
  /// the app. Defaults to classic green if the caller doesn't pass one.
  final Color phosphor;

  const AssetManagerScreen({
    super.key,
    required this.docText,
    required this.imagesDir,
    required this.spritesDir,
    required this.onClose,
    this.phosphor = const Color(0xFF00FF00),
  });

  @override
  State<AssetManagerScreen> createState() => _AssetManagerScreenState();
}

class _AssetManagerScreenState extends State<AssetManagerScreen> {
  late AssetScanResult _result;

  R3Theme get _t => R3Theme.of(widget.phosphor);

  @override
  void initState() {
    super.initState();
    _rescan();
  }

  void _rescan() {
    _result = AssetScanner.scan(
      docText: widget.docText,
      imagesDir: widget.imagesDir,
      spritesDir: widget.spritesDir,
    );
  }

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color),
    );
  }

  // -------------------------------------------------------------------
  // Import dialog (typed path OR live OS drop)
  // -------------------------------------------------------------------

  Future<void> _showImportDialog(AssetRef ref) async {
    final srcCtrl = TextEditingController();
    final bool isFolder = ref.kind == AssetKind.imageFolder;
    final t = _t;

    // Non-null once a drop import succeeds — carries the summary out of
    // the dialog so the snack fires after it closes.
    String? dropSummary;

    // Claim the drop bus for this dialog's lifetime. A drop performs the
    // import immediately and closes the dialog on success.
    VoidCallback releaseDrop = () {};

    try {
      final bool? proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (dialogCtx, setDialogState) {
              // (Re)claim on every dialog build — cheap, idempotent enough
              // for our single-listener bus, and guarantees the freshest
              // setDialogState is captured.
              releaseDrop();
              // Position is deliberately ignored here. This dialog already
              // nominated its destination (ref) when you hit IMPORT, so a
              // drop anywhere on the window means that one asset. Hit
              // testing would only add a way to miss.
              releaseDrop = DropBus.listen((event) {
                try {
                  final String summary =
                      AssetImporter.importDropped(ref, event.paths);
                  dropSummary = summary;
                  Navigator.of(dialogCtx).pop(false); // handled; skip typed path
                } catch (e) {
                  // Stay open so they can retry; surface the error inline.
                  setDialogState(() {
                    srcCtrl.text = '';
                  });
                  _snack('Drop import failed: $e', Colors.red);
                }
              });

              return AlertDialog(
                title: Text(
                  isFolder ? 'IMPORT FOLDER CONTENTS' : 'IMPORT FILE',
                  style: t.value.copyWith(letterSpacing: 2),
                ),
                content: SizedBox(
                  width: sc(560),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      R3MicroLabel("Destination", theme: t),
                      SizedBox(height: sc(4)),
                      Text(ref.absolutePath, style: t.fine),
                      SizedBox(height: sc(14)),

                      // --- Drop zone ---
                      Container(
                        width: double.infinity,
                        padding: EdgeInsets.symmetric(vertical: sc(26)),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(color: t.accentDim, width: 1.5),
                          color: t.accentFaint,
                        ),
                        child: Column(
                          children: [
                            Icon(Icons.download_outlined,
                                size: sc(30), color: t.accent),
                            SizedBox(height: sc(8)),
                            Text(
                              (isFolder
                                      ? 'DROP A FOLDER OR IMAGE FILES HERE'
                                      : 'DROP THE FILE HERE'),
                              style: t.micro.copyWith(color: t.accent),
                            ),
                            SizedBox(height: sc(4)),
                            Text(
                              'anywhere on the R3nder window works',
                              style: t.fine,
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: sc(14)),

                      R3MicroLabel("Or enter a source path", theme: t),
                      SizedBox(height: sc(8)),
                      TextField(
                        controller: srcCtrl,
                        style: t.value,
                        decoration: InputDecoration(
                          labelText: isFolder
                              ? 'Source folder path (blank = just create the folder)'
                              : 'Source file path',
                          isDense: true,
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  R3Button('Cancel', theme: t, compact: true,
                      onPressed: () => Navigator.of(dialogCtx).pop(false)),
                  R3Button('Import', theme: t, compact: true,
                      kind: R3ButtonKind.primary,
                      onPressed: () => Navigator.of(dialogCtx).pop(true)),
                ],
              );
            },
          );
        },
      );

      // Path A: a drop already did the work inside the dialog.
      if (dropSummary != null) {
        setState(_rescan);
        _snack('${ref.scriptPath}: $dropSummary', Colors.green.shade700);
        return;
      }

      // Path B: typed path + IMPORT button.
      if (proceed != true) return;

      final String src = srcCtrl.text.trim();
      try {
        if (isFolder && src.isEmpty) {
          // Blank source on a folder = "just scaffold it".
          Directory(ref.absolutePath).createSync(recursive: true);
        } else {
          AssetImporter.importPath(ref, src);
        }
      } catch (e) {
        _snack('Import failed: $e', Colors.red);
        return;
      }

      setState(_rescan);
      _snack('Imported: ${ref.scriptPath}', Colors.green.shade700);
    } finally {
      releaseDrop();
      srcCtrl.dispose();
    }
  }

  // -------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------

  /// Status colors come from the fixed signal palette — status semantics
  /// never re-tint with the phosphor, only chrome does.
  Color _statusColor(AssetStatus s) {
    switch (s) {
      case AssetStatus.ok:
        return R3Theme.okGreen;
      case AssetStatus.missing:
        return R3Theme.danger;
      case AssetStatus.emptyFolder:
        return R3Theme.warn;
      case AssetStatus.shortCount:
        return R3Theme.warn;
    }
  }

  /// Chip text. Folder refs report their content count instead of a bare
  /// OK, since an OK folder can still be short of what the shot needs.
  String _statusLabel(AssetRef ref) {
    switch (ref.status) {
      case AssetStatus.ok:
        if (ref.kind != AssetKind.imageFolder) return 'OK';
        if (ref.expectedCount != null) {
          return '${ref.fileCount} OF ${ref.expectedCount}';
        }
        return ref.fileCount == 1 ? '1 FILE' : '${ref.fileCount} FILES';
      case AssetStatus.missing:
        return 'MISSING';
      case AssetStatus.emptyFolder:
        return 'EMPTY FOLDER';
      case AssetStatus.shortCount:
        return '${ref.fileCount} OF ${ref.expectedCount}';
    }
  }

  /// Extra line under a folder row explaining what the count will produce,
  /// so a single-image folder reads as suspicious rather than as done.
  String? _folderHint(AssetRef ref) {
    if (ref.kind != AssetKind.imageFolder) return null;

    // The declared shortfall is the most useful thing we can say, so it
    // outranks everything else and is the only hint shown on a short row.
    if (ref.status == AssetStatus.shortCount) {
      final int short = ref.expectedCount! - ref.fileCount;
      return 'THIS CALL NEEDS ${ref.expectedCount}. '
          '$short MISSING. DROP THE WHOLE SOURCE FOLDER, OR SELECT '
          'EVERY FILE AT ONCE.';
    }

    if (ref.status != AssetStatus.ok) return null;

    final int n = ref.fileCount;
    if (n == 1 && ref.expectedCount == null) {
      return 'ONE IMAGE: A GALLERY SHOWS IT ALONE, AN APP FILLS THE '
          'WINDOW WITH IT. DROP THE WHOLE FOLDER TO ADD MORE.';
    }
    if (ref.usedBy.contains('APP')) {
      if (n > 9) {
        return '$n IMAGES: AN APP USES THE FIRST 9, THE REST ARE DROPPED.';
      }
      final int pages = (n + 2) ~/ 3;
      return '$n IMAGES: GRID FILLS ONE SCREEN, '
          'MOSAIC MAKES $pages ${pages == 1 ? 'PAGE' : 'PAGES'}.';
    }
    if (ref.usedBy.contains('BROWSER')) {
      // The count IS the page count here, one capture per navigation, so
      // the useful thing to report is the other half: whether the folder
      // says where its captures came from. A browser folder with no
      // sidecar renders with an empty address bar, which reads as a
      // broken app rather than as an unauthored folder — and this row is
      // the only place that is visible before a bake.
      final String urls = _folderHasUrls(ref)
          ? ''
          : ' NO URLS IN $kFolderCaptionFile: THE ADDRESS BAR WILL BE EMPTY.';
      if (n > kBrowserMaxPages) {
        return '$n CAPTURES: A BROWSER VISITS THE FIRST $kBrowserMaxPages.$urls';
      }
      return '$n CAPTURES: $n ${n == 1 ? 'NAVIGATION' : 'NAVIGATIONS'} '
          'IN ONE WINDOW.$urls';
    }
    return null;
  }

  /// Whether any image in this folder has an authored URL.
  ///
  /// Reads the sidecar rather than trusting the scan, because the scan
  /// answers questions about files existing and this is a question about
  /// what is written inside one of them.
  bool _folderHasUrls(AssetRef ref) =>
      readFolderCaptions(ref.absolutePath).values.any((c) => c.hasSource);

  IconData _kindIcon(AssetKind k) {
    switch (k) {
      case AssetKind.imageFile:
        return Icons.image_outlined;
      case AssetKind.imageFolder:
        return Icons.folder_outlined;
      case AssetKind.spriteFile:
        return Icons.grid_on_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    final int missing = _result.missingCount;

    return Column(
      children: [
        // --- Top bar ---
        Container(
          padding: EdgeInsets.symmetric(horizontal: sc(14), vertical: sc(8)),
          decoration: const BoxDecoration(
            color: R3Theme.panel,
            border: Border(bottom: BorderSide(color: R3Theme.hairline)),
          ),
          child: Row(
            children: [
              R3MicroLabel("Asset Manager", theme: t, accent: true),
              SizedBox(width: sc(12)),
              Container(width: 1, height: sc(16), color: R3Theme.hairline),
              SizedBox(width: sc(12)),
              R3Tally(
                state: missing == 0
                    ? (_result.refs.isEmpty
                        ? R3TallyState.off
                        : R3TallyState.ok)
                    : R3TallyState.error,
              ),
              SizedBox(width: sc(8)),
              Text(
                (missing == 0
                        ? 'ALL ${_result.refs.length} ASSETS RESOLVED'
                        : '$missing OF ${_result.refs.length} NEED ATTENTION'),
                style: t.micro.copyWith(
                  color: missing == 0 ? R3Theme.textDim : R3Theme.danger,
                ),
              ),
              const Spacer(),
              InkWell(
                onTap: () => setState(_rescan),
                borderRadius: BorderRadius.circular(3),
                child: Tooltip(
                  message: 'Rescan',
                  child: Padding(
                    padding: EdgeInsets.all(sc(5)),
                    child: Icon(Icons.refresh,
                        size: sc(17), color: R3Theme.textMid),
                  ),
                ),
              ),
              SizedBox(width: sc(8)),
              R3Button('Back', theme: t, compact: true,
                  onPressed: widget.onClose),
            ],
          ),
        ),

        // --- List ---
        Expanded(
          child: Container(
            color: R3Theme.bg,
            child: _result.refs.isEmpty && _result.orphans.isEmpty
                ? Center(
                    child: Text(
                      'THIS SCRIPT REFERENCES NO EXTERNAL ASSETS',
                      style: t.micro,
                    ),
                  )
                : ListView(
                    padding: EdgeInsets.all(sc(14)),
                    children: [
                      ..._result.refs.map((r) => _buildRefRow(t, r)),
                      if (_result.orphans.isNotEmpty) ...[
                        SizedBox(height: sc(24)),
                        Padding(
                          padding: EdgeInsets.only(bottom: sc(8)),
                          child: R3MicroLabel(
                              "Unreferenced files in workspace",
                              theme: t),
                        ),
                        ..._result.orphans.map((o) => _buildOrphanRow(t, o)),
                      ],
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildRefRow(R3Theme t, AssetRef ref) {
    final Color statusColor = _statusColor(ref.status);
    final bool needsAction = ref.status != AssetStatus.ok;

    return Container(
      margin: EdgeInsets.only(bottom: sc(8)),
      padding: EdgeInsets.symmetric(horizontal: sc(14), vertical: sc(10)),
      decoration: BoxDecoration(
        color: R3Theme.panel,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
          color: needsAction
              ? statusColor.withValues(alpha: 0.4)
              : R3Theme.hairline,
        ),
      ),
      child: Row(
        children: [
          Icon(_kindIcon(ref.kind), size: sc(18), color: R3Theme.textDim),
          SizedBox(width: sc(12)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(ref.scriptPath, style: t.value),
                SizedBox(height: sc(3)),
                Text(
                  'USED BY: ${ref.usedBy.join(', ').toUpperCase()}',
                  style: t.micro.copyWith(letterSpacing: sc(1.2)),
                ),
                SizedBox(height: sc(2)),
                Text(
                  ref.absolutePath,
                  overflow: TextOverflow.ellipsis,
                  style: t.fine,
                ),
                if (_folderHint(ref) != null) ...[
                  SizedBox(height: sc(3)),
                  Text(
                    _folderHint(ref)!,
                    style: t.micro.copyWith(
                      color: (ref.status == AssetStatus.shortCount ||
                              ref.fileCount == 1)
                          ? R3Theme.warn
                          : R3Theme.textDim,
                      letterSpacing: sc(1.0),
                    ),
                  ),
                ],
              ],
            ),
          ),
          SizedBox(width: sc(12)),
          Container(
            padding:
                EdgeInsets.symmetric(horizontal: sc(8), vertical: sc(3)),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: statusColor.withValues(alpha: 0.6)),
            ),
            child: Text(
              _statusLabel(ref),
              style: TextStyle(
                fontFamily: 'monospace',
                fontFamilyFallback: R3Theme.monoStack,
                fontSize: sc(10.5),
                letterSpacing: sc(1.4),
                fontWeight: FontWeight.bold,
                color: statusColor,
              ),
            ),
          ),
          if (needsAction) ...[
            SizedBox(width: sc(10)),
            R3Button('Import', theme: t, compact: true,
                kind: R3ButtonKind.primary,
                onPressed: () => _showImportDialog(ref)),
          ],
        ],
      ),
    );
  }

  Widget _buildOrphanRow(R3Theme t, OrphanEntry orphan) {
    return Container(
      margin: EdgeInsets.only(bottom: sc(6)),
      padding: EdgeInsets.symmetric(horizontal: sc(14), vertical: sc(7)),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: R3Theme.hairline),
      ),
      child: Row(
        children: [
          Icon(
            orphan.isFolder
                ? Icons.folder_outlined
                : Icons.insert_drive_file_outlined,
            size: sc(14),
            color: R3Theme.textDim,
          ),
          SizedBox(width: sc(12)),
          Expanded(
            child: Text(orphan.relativePath, style: t.fine),
          ),
          Text('NOT REFERENCED', style: t.micro.copyWith(fontSize: sc(9.5))),
        ],
      ),
    );
  }
}