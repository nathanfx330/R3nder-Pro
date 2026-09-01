// ./lib/node_assets.dart

// Node-editor asset slot metadata and workspace asset index.
//
// Kept separate from script_nodes.dart so timeline/ribbon consumers of the
// pure script model do not depend on filesystem or preview UI code.

import 'dart:io';

import 'asset_manager.dart';
import 'node_asset_preview.dart';

// ---------------------------------------------------------------------
// Workspace asset library
// ---------------------------------------------------------------------

/// What kind of asset a field expects. Drives which list the picker offers
/// and how a dangling reference is reported.
enum AssetSlot { rasterFile, svgFile, imageFolder, svgFolder, spriteFile }

/// Everything the preview and import paths need to know about a slot,
/// kept beside the enum so adding a slot cannot leave one of them stale.
///
/// [root] answers "which workspace directory does a bare name in this
/// field resolve against", which is the question the picker never had to
/// ask because a dropdown of names is enough to pick with. A preview has
/// to actually open the file, and an import has to write one.
extension AssetSlotMeta on AssetSlot {
  /// True when the field names a directory rather than a file.
  bool get isFolder =>
      this == AssetSlot.imageFolder || this == AssetSlot.svgFolder;

  /// How the contents should be drawn. A raster folder and a raster file
  /// share a renderer; only the container differs.
  ThumbKind get thumbKind {
    switch (this) {
      case AssetSlot.rasterFile:
      case AssetSlot.imageFolder:
        return ThumbKind.raster;
      case AssetSlot.svgFile:
      case AssetSlot.svgFolder:
        return ThumbKind.svg;
      case AssetSlot.spriteFile:
        return ThumbKind.sprite;
    }
  }

  /// Extensions an import into this slot will accept. Dropping anything
  /// else is reported rather than copied, because a .mp4 sitting in
  /// images/ next to a name the script references is a bake-time dud with
  /// no edit-time symptom.
  Set<String> get acceptedExts => extsFor(thumbKind);
}

/// A one-shot scan of the active workspace, taken when node mode opens.
///
/// This is what lets the form offer real choices instead of a text box:
/// folder and file names stop being things the writer has to remember and
/// spell correctly, and a reference that resolves to nothing is flagged at
/// edit time rather than at bake time.
class NodeAssetLibrary {
  final List<String> rasterFiles;
  final List<String> svgFiles;
  final List<String> imageFolders;
  final List<String> svgFolders;
  final List<String> spriteFiles;

  const NodeAssetLibrary({
    this.rasterFiles = const [],
    this.svgFiles = const [],
    this.imageFolders = const [],
    this.svgFolders = const [],
    this.spriteFiles = const [],
  });

  static const List<String> _rasterExt = [
    '.png', '.jpg', '.jpeg', '.bmp', '.gif', '.webp',
  ];

  /// Scans images/ and sprites/. Every failure mode (missing directory,
  /// permissions) degrades to an empty list, so the form always builds and
  /// manual entry always remains available.
  factory NodeAssetLibrary.scan(String imagesDir, String spritesDir) {
    final List<String> rasters = [];
    final List<String> svgs = [];
    final List<String> imgFolders = [];
    final List<String> svgFolders = [];
    final List<String> sprites = [];

    bool isRaster(String p) {
      final String lower = p.toLowerCase();
      return _rasterExt.any(lower.endsWith);
    }

    try {
      final Directory d = Directory(imagesDir);
      if (d.existsSync()) {
        for (final ent in d.listSync(followLinks: false)) {
          final String name = ent.path.split(Platform.pathSeparator).last;
          if (ent is File) {
            if (isRaster(name)) {
              rasters.add(name);
            } else if (name.toLowerCase().endsWith('.svg')) {
              svgs.add(name);
            }
          } else if (ent is Directory) {
            // Authoring trash lives under images/_recycle. It is deliberately
            // kept out of normal asset pickers so removing a thumbnail does
            // not make the recycle bin look like a source folder.
            if (name.toLowerCase() == kRecycleFolderName) continue;
            imgFolders.add(name);
            // A folder counts as an SVG folder only if it actually holds
            // stencils, which is the same test SVGFLASH applies at runtime.
            try {
              final bool hasSvg = ent.listSync(followLinks: false).any(
                  (f) => f is File && f.path.toLowerCase().endsWith('.svg'));
              if (hasSvg) svgFolders.add(name);
            } catch (_) {
              // Unreadable subfolder: leave it out of the SVG list.
            }
          }
        }
      }
    } catch (_) {
      // No images directory yet.
    }

    try {
      final Directory d = Directory(spritesDir);
      if (d.existsSync()) {
        for (final ent in d.listSync(followLinks: false)) {
          if (ent is File) {
            final String name = ent.path.split(Platform.pathSeparator).last;
            if (name.toLowerCase().endsWith('.txt')) sprites.add(name);
          }
        }
      }
    } catch (_) {
      // No sprites directory yet.
    }

    int byName(String a, String b) =>
        a.toLowerCase().compareTo(b.toLowerCase());
    rasters.sort(byName);
    svgs.sort(byName);
    imgFolders.sort(byName);
    svgFolders.sort(byName);
    sprites.sort(byName);

    return NodeAssetLibrary(
      rasterFiles: rasters,
      svgFiles: svgs,
      imageFolders: imgFolders,
      svgFolders: svgFolders,
      spriteFiles: sprites,
    );
  }

  List<String> forSlot(AssetSlot slot) {
    switch (slot) {
      case AssetSlot.rasterFile:
        return rasterFiles;
      case AssetSlot.svgFile:
        return svgFiles;
      case AssetSlot.imageFolder:
        return imageFolders;
      case AssetSlot.svgFolder:
        return svgFolders;
      case AssetSlot.spriteFile:
        return spriteFiles;
    }
  }

  String slotLabel(AssetSlot slot) {
    switch (slot) {
      case AssetSlot.rasterFile:
        return 'images/';
      case AssetSlot.svgFile:
        return 'images/*.svg';
      case AssetSlot.imageFolder:
        return 'images/ folder';
      case AssetSlot.svgFolder:
        return 'svg folder';
      case AssetSlot.spriteFile:
        return 'sprites/';
    }
  }

  /// True when the value names something that exists. An empty value counts
  /// as resolved so an unfilled optional field does not read as an error.
  bool resolves(AssetSlot slot, String value) {
    final String v = value.trim();
    if (v.isEmpty) return true;
    return forSlot(slot).contains(v);
  }
}