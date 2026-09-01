// ./lib/editor_node_workspace.dart

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'asset_manager.dart';
import 'desktop_open.dart';
import 'editor_tag_menu.dart';
import 'config_keys.dart';
import 'folder_order.dart';
import 'motion.dart';
import 'folder_captions.dart';
import 'presentation_requests.dart';
import 'node_asset_preview.dart';
import 'ui_theme.dart';
import 'node_assets.dart';
import 'script_nodes.dart';

export 'node_assets.dart';
export 'script_nodes.dart';

/// One [ITEM:id]text[/ITEM] inside a menu body. Used only by the menu form.
final RegExp _menuItemRegex =
    RegExp(r'\[ITEM:([a-zA-Z0-9_-]+)\](.*?)\[/ITEM\]', dotAll: true);

/// Asset-manager directive used by the node UI to badge undersupplied folders.
final RegExp _needsRegex =
    RegExp(r'\[#\s*NEEDS:\s*([^\s:\]]+)\s*:\s*(\d+)\s*\]');

/// One image currently parked in images/_recycle. [originalFolder] is the
/// relative workspace folder it came from, which makes restore deterministic
/// without maintaining a separate database or sidecar file.
class _RecycleEntry {
  final String absolutePath;
  final String originalFolder;
  final String name;

  const _RecycleEntry({
    required this.absolutePath,
    required this.originalFolder,
    required this.name,
  });
}

/// A field nominated to catch drops that land on no field at all.
///
/// Identified by node ID rather than by node reference: a reparse from an
/// external edit or an undo replaces every node object, and a pin holding
/// a dead node would silently import into nothing.

class _PinnedField {
  final String nodeId;
  final String paramKey;
  final AssetSlot slot;

  const _PinnedField(this.nodeId, this.paramKey, this.slot);

  String get key => '$nodeId|$paramKey';
}

class DotGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = R3Theme.hairline
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;

    final double spacing = sc(24);
    for (double x = spacing; x < size.width; x += spacing) {
      for (double y = spacing; y < size.height; y += spacing) {
        canvas.drawPoints(ui.PointMode.points, [Offset(x, y)], paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ---------------------------------------------------------------------
// Widget
// ---------------------------------------------------------------------

class EditorNodeWorkspace extends StatefulWidget {
  final String initialText;
  final R3Theme theme;
  final int highlightedLine;

  /// Absolute path of the workspace images/ folder. Populates the file and
  /// folder pickers.
  final String imagesDir;

  /// Absolute path of the workspace sprites/ folder.
  final String spritesDir;

  /// Font families registered from the workspace fonts folder, for the
  /// caption font picker. Empty is fine: the control degrades to "script
  /// font" only, which is also the default.
  final List<String> availableFonts;

  /// Called whenever a node is edited so the parent can update its buffer
  /// and mark the document as dirty.
  final ValueChanged<String> onTextChanged;

  /// Called when files move on disk without the script changing: a drop
  /// import into an already-named folder, a recycle, a restore, a purge.
  ///
  /// This exists because [onTextChanged] cannot carry it. The parent
  /// compares the incoming text against its buffer and does nothing when
  /// they match, which is correct for text and wrong for assets: the scene
  /// decodes every referenced image once at setup, so a folder whose
  /// CONTENTS changed under an unchanged `[APP:folder:...]` tag keeps
  /// rendering the images it loaded at open. Recycling a photo out of a
  /// gallery and watching it stay on screen is that bug.
  final VoidCallback? onAssetsChanged;

  /// Node to select on mount instead of the first visible one, by document
  /// index.
  ///
  /// Set when arriving from a double-tap on the script ribbon, so the panel
  /// opens on the block that was clicked, ready to edit.
  ///
  /// An INDEX, not a [ScriptNode.id]. Ids come from a global counter that
  /// never resets, so the ribbon's parse and this widget's parse of the
  /// same text produce two disjoint sets and an id could never cross the
  /// boundary. Position in the document is what both sides compute
  /// identically. Ids stay correct everywhere inside this widget, where
  /// they have to survive inserts and deletes; index only works as a
  /// cross-parse address, and only while the text has not changed under it.
  ///
  /// Out of range falls back to the first visible node, which is what
  /// happens if the document changed between the tap and the mount.
  final int? initialSelectedNodeIndex;

  const EditorNodeWorkspace({
    super.key,
    required this.initialText,
    required this.theme,
    required this.highlightedLine,
    required this.imagesDir,
    required this.spritesDir,
    this.availableFonts = const <String>[],
    required this.onTextChanged,
    this.onAssetsChanged,
    this.initialSelectedNodeIndex,
  });

  @override
  State<EditorNodeWorkspace> createState() => _EditorNodeWorkspaceState();
}

class _EditorNodeWorkspaceState extends State<EditorNodeWorkspace> {
  /// Fixed row height for the node list. Kept a constant so the
  /// scroll-to-line math stays exact instead of estimated.
  static final double _rowH = sc(62);
  static final double _listPadV = sc(12);

  List<ScriptNode> _nodes = [];
  String? _selectedId;
  int _lastAutoScrolledIdx = -1;

  /// Which folder image the per-image profile is open on, as
  /// "absoluteDir|filename". View state only: nothing about which
  /// thumbnail you clicked belongs in the script or on disk.
  ///
  /// The profile started life as caption-only and is now the one place any
  /// per-image fact is authored: caption, credit, hold extension, and the
  /// URL and page title a BROWSER window reads. Named for the panel rather
  /// than for the first thing it happened to edit.
  ///
  /// Keyed by directory as well as name because two APP nodes can point at
  /// different folders that both contain "01.jpg", and a bare filename key
  /// would open the second node's profile on the first node's picture.
  String? _profileTarget;

  /// Load position and folder size for the open profile, so it can work
  /// out which pane the image belongs to. Recomputed from the position
  /// rather than stored as a pane index, which would go stale the moment a
  /// pane is split or merged.
  int _profileIndex = -1;
  int _profileTotal = 0;

  /// Captions for the folder whose profile is open, read from the sidecar
  /// once and edited in memory until a field changes.
  ///
  /// Held rather than re-read on every build for the same reason the order
  /// manifest is not: a rebuild happens on every keystroke, and reading a
  /// file per frame of typing is both slow and a way to lose the character
  /// you just typed to a stale read.
  Map<String, ImageCaption> _captionCacheForDir = {};
  String? _captionCacheDir;

  late NodeAssetLibrary _assets;

  final ScrollController _scrollController = ScrollController();

  /// Text controllers keyed by "nodeId|field". Held here rather than using
  /// TextFormField.initialValue so a field refreshes when something else
  /// writes the same param (a picker, a mode switch) without losing the
  /// caret while the user is typing into it.
  final Map<String, TextEditingController> _controllers = {};

  // -------------------------------------------------------------------
  // Drop targeting
  //
  // The runner reports where a drop landed, so the common case needs no
  // click: every asset field registers its geometry through a
  // DropTargetRegion and DropZoneRegistry resolves the position to a
  // field. The panel holds the DropBus claim for as long as node mode is
  // open, which is what makes that work without the user nominating
  // anything first.
  //
  // PINNING covers what position cannot: a drop that lands on the node
  // list, or on empty panel, where there is no field under the cursor to
  // resolve to. One field can be pinned as the catch-all for those. It is
  // stored by node ID rather than by node object because a reparse
  // replaces every node, and by paramKey because a node can own several
  // asset fields.
  // -------------------------------------------------------------------

  /// The catch-all field for drops that hit no field, or null for none.
  _PinnedField? _pinned;

  /// DropBus release callback for the panel's claim. Must be called before
  /// dropping the reference or drops leak to a dead widget.
  VoidCallback? _dropRelease;

  /// Set while a copy is in flight so a second drop cannot land mid-import.
  bool _importBusy = false;

  /// Which field the last status message belongs to, so the result shows
  /// under the field that produced it rather than under the pinned one.
  /// Null when there is no message.
  ///
  /// Shared by every per-field action that can fail, not just import: a
  /// drop that copied nothing and a file-manager handoff that found no
  /// file manager are the same sentence in the same place, and a second
  /// message channel would only mean two of them could be on screen at
  /// once saying different things about one field.
  String? _fieldMessageKey;

  /// Result of the last per-field action. Cleared when another starts.
  String? _fieldMessage;
  bool _fieldFailed = false;

  /// When true the right column becomes the workspace recycle browser instead
  /// of the selected node's settings. The selected node is intentionally kept
  /// intact so closing recycle returns to exactly where the author was.
  bool _showRecyclePanel = false;

  /// Cached recycle contents. Unlike normal form fields, this is not scanned on
  /// every keystroke; it refreshes when the panel opens or R3nder moves a file.
  List<_RecycleEntry> _recycleItems = const [];

  /// [#NEEDS:folder:N] directives from the live document, folder name
  /// lowercased. Rebuilt in [_recomputeLines] rather than read per build:
  /// the properties panel rebuilds on every keystroke and recomposing the
  /// whole document to answer one badge is not a trade worth making.
  Map<String, int> _declaredCounts = const {};

  // -------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _assets = NodeAssetLibrary.scan(widget.imagesDir, widget.spritesDir);
    _recycleItems = _recycleEntries();
    _nodes = _parseTextToNodes(widget.initialText);
    _recomputeLines();

    // Honour an incoming selection (a ribbon double-tap) when it resolves,
    // otherwise open on the first visible node as before.
    final int? wanted = widget.initialSelectedNodeIndex;
    if (wanted != null && wanted >= 0 && wanted < _nodes.length) {
      _selectedId = _nodes[wanted].id;
    } else {
      final int first = _nodes.indexWhere((n) => n.isVisible);
      if (first >= 0) _selectedId = _nodes[first].id;
    }

    // Claimed for as long as node mode is open, not per field. Position
    // decides which field takes a drop; this claim only decides that the
    // node panel is the screen listening at all. Hover rides the same
    // claim, so it can never outlive the panel that paints it.
    _dropRelease = DropBus.listen(
      _onDrop,
      onMotion: _onDragMotion,
      onLeave: _onDragLeave,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToHighlightedLine(animate: false);
    });
  }

  @override
  void didUpdateWidget(EditorNodeWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.initialText != oldWidget.initialText) {
      // If the incoming text is what we just composed, the node objects are
      // already correct and only their line spans need refreshing. Anything
      // else means the buffer changed underneath us (an external edit or an
      // undo), so rebuild the graph from the document.
      if (widget.initialText != _compose()) {
        // Every node object is about to be replaced, so a pin naming one of
        // them is about to name nothing. The bus claim is untouched: it
        // belongs to the panel, not to any node.
        _pinned = null;
        _disposeControllers();
        _nodes = _parseTextToNodes(widget.initialText);
        if (_nodeIndexById(_selectedId) < 0) {
          final int first = _nodes.indexWhere((n) => n.isVisible);
          _selectedId = first >= 0 ? _nodes[first].id : null;
        }
      }
      _recomputeLines();
    }

    if (widget.highlightedLine != oldWidget.highlightedLine &&
        widget.highlightedLine >= 0) {
      _scrollToHighlightedLine();
    }
  }

  @override
  void dispose() {
    _dropRelease?.call();
    _dropRelease = null;
    _hoveredKey = null;
    // Regions register during build and unregister on their own dispose,
    // but widget teardown order is not guaranteed to run them all before
    // this. Clearing here means a region cannot outlive the panel that
    // gave it meaning.
    DropZoneRegistry.clear();
    _disposeControllers();
    _scrollController.dispose();
    super.dispose();
  }

  void _disposeControllers() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
  }

  /// Fetches (or creates) the controller for a field, adopting an external
  /// value change without stomping the caret.
  TextEditingController _ctl(String key, String value) {
    final TextEditingController c =
        _controllers.putIfAbsent(key, () => TextEditingController(text: value));
    if (c.text != value) {
      final TextSelection prev = c.selection;
      c.value = TextEditingValue(
        text: value,
        selection: (prev.start <= value.length && prev.end <= value.length)
            ? prev
            : TextSelection.collapsed(offset: value.length),
      );
    }
    return c;
  }

  // -------------------------------------------------------------------
  // Asset previews, drop targeting, and import
  // -------------------------------------------------------------------

  /// Workspace directory a bare name in this slot resolves against.
  String _slotRoot(AssetSlot slot) =>
      slot == AssetSlot.spriteFile ? widget.spritesDir : widget.imagesDir;

  /// Absolute path for the value currently in an asset field. Empty when
  /// the field is empty, which callers treat as "nothing to preview"
  /// rather than as a missing file.
  String _slotAbsolute(AssetSlot slot, String value) {
    final String v = value.trim();
    if (v.isEmpty) return '';
    return '${_slotRoot(slot)}${Platform.pathSeparator}$v';
  }

  /// Hands the asset a field names to the session's file manager.
  ///
  /// The name in the field is the whole reason this is worth a button. A
  /// script says `evidence`, which is the correct thing for it to say and
  /// is why a workspace can move, but culling a contact sheet, renaming a
  /// scan, or checking what a folder actually holds are all filesystem
  /// jobs, and without this the author leaves R3nder to go find a
  /// directory whose path only R3nder knows.
  ///
  /// Reports through the shared per-field status line rather than a
  /// dialog or a snackbar. A failure here is a fact about this field, it
  /// belongs under this field, and it is the same sentence in the same
  /// place as a drop that copied nothing.
  ///
  /// Touches no document state. This cannot dirty the script, cannot move
  /// a frame boundary, and deliberately does not rescan on the way out:
  /// the file manager is still open and the author has not done anything
  /// in it yet. Any change they make there arrives through the same
  /// import path everything else does.
  Future<void> _revealAsset(ScriptNode node, String paramKey,
      AssetSlot slot, String value) async {
    final String key = _fieldKey(node, paramKey);
    final String abs = _slotAbsolute(slot, value);

    setState(() {
      _fieldMessage = null;
      _fieldMessageKey = key;
      _fieldFailed = false;
    });

    final String? failure = await revealInFileManager(abs);
    if (!mounted) return;

    setState(() {
      _fieldMessage = failure;
      _fieldMessageKey = failure == null ? null : key;
      _fieldFailed = failure != null;
    });
  }

  /// Re-reads the workspace after files move on disk. Cheap enough to do
  /// inline: two directory listings, the same pair node mode already does
  /// once on open. The preview caches are dropped at the same time because
  /// a name that resolved to nothing a moment ago now resolves to something.
  ///
  /// Also tells the parent, because the live preview holds decoded images
  /// from setup time and has no other way to learn they are stale. Firing
  /// from here rather than from each call site is deliberate: this function
  /// is already the one thing every disk mutation has to call, so a future
  /// asset operation that forgets to notify would have to forget to rescan
  /// too, and that failure is visible immediately.
  void _rescanAssets() {
    invalidateAssetPreviews();
    _assets = NodeAssetLibrary.scan(widget.imagesDir, widget.spritesDir);
    widget.onAssetsChanged?.call();
  }

  /// Non-destructive removal from a folder contact sheet. The source must
  /// resolve underneath images/, then it is moved to
  /// `images/_recycle/<original-folder>/` with a collision-safe filename.
  ///
  /// This intentionally changes no script text. [_notifyChanged] is still
  /// called so the live scene resimulates against the new folder contents.
  Future<void> _recycleFolderImage(String absolutePath) async {
    try {
      final String root = Directory(widget.imagesDir).resolveSymbolicLinksSync();
      final String source = File(absolutePath).resolveSymbolicLinksSync();
      final String prefix = root.endsWith(Platform.pathSeparator)
          ? root
          : '$root${Platform.pathSeparator}';
      if (!source.startsWith(prefix)) {
        throw 'That image is outside this workspace.';
      }

      final String relative = source.substring(prefix.length);
      final List<String> parts = relative.split(Platform.pathSeparator);
      if (parts.length < 2 || parts.first.toLowerCase() == kRecycleFolderName) {
        throw 'Only images inside a workspace folder can be recycled here.';
      }

      final String name = parts.removeLast();
      final String subfolder = parts.join(Platform.pathSeparator);
      final Directory recycleDir = Directory(
        '$prefix$kRecycleFolderName${Platform.pathSeparator}$subfolder',
      )..createSync(recursive: true);
      final String targetName = _uniqueName(recycleDir.path, name);
      final String target =
          '${recycleDir.path}${Platform.pathSeparator}$targetName';

      final File src = File(source);
      try {
        src.renameSync(target);
      } catch (_) {
        // rename can fail across mount boundaries. Copy+delete preserves the
        // same non-destructive user contract in that case.
        src.copySync(target);
        src.deleteSync();
      }

      if (!mounted) return;
      _rescanAssets();
      _recycleItems = _recycleEntries();
      _notifyChanged();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('RECYCLE FAILED — $e')),
      );
    }
  }

  /// Writes a new load order for an asset folder.
  ///
  /// The order lives in a `.r3nder_order` dotfile inside the folder itself,
  /// so filenames are never rewritten. That matters for archival material,
  /// where a filename carries a date or a box number and re-prefixing it to
  /// encode a composition decision would trade something irreplaceable for
  /// something cosmetic.
  ///
  /// Ends with [_notifyChanged] like every other on-disk asset change, which
  /// reaches the editor as onAssetsChanged and reloads the live preview. The
  /// scene decodes each folder once at setup, so without that a reordered
  /// MOSAIC would keep drawing the composition it opened with.
  Future<void> _reorderFolder(String absoluteDir, List<String> names) async {
    final bool ok = writeFolderOrder(absoluteDir, names);
    if (!mounted) return;

    if (!ok) {
      // Silently failing to save an order somebody just arranged by hand is
      // worse than saying so: the sheet would snap back on the next build
      // with no explanation.
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('COULD NOT WRITE FOLDER ORDER')),
      );
      return;
    }

    _rescanAssets();
    _notifyChanged();
  }

  /// Drops a folder's manifest, returning it to filename order.
  Future<void> _resetFolderOrder(String absoluteDir) async {
    clearFolderOrder(absoluteDir);
    if (!mounted) return;
    _rescanAssets();
    _notifyChanged();
  }

  /// Raster images parked under images/_recycle, recursively. The folder path
  /// below _recycle is the original folder path, so no restore metadata file
  /// is needed and a bin survives app restarts.
  List<_RecycleEntry> _recycleEntries() {
    final List<_RecycleEntry> out = [];
    final Directory recycle = Directory(
      '${widget.imagesDir}${Platform.pathSeparator}$kRecycleFolderName',
    );
    try {
      if (!recycle.existsSync()) return out;
      final String root = recycle.resolveSymbolicLinksSync();
      final String prefix = root.endsWith(Platform.pathSeparator)
          ? root
          : '$root${Platform.pathSeparator}';

      for (final ent in recycle.listSync(recursive: true, followLinks: false)) {
        if (ent is! File) continue;
        final String lower = ent.path.toLowerCase();
        if (!kRasterThumbExts.any(lower.endsWith)) continue;

        String absolute;
        try {
          absolute = ent.resolveSymbolicLinksSync();
        } catch (_) {
          continue;
        }
        if (!absolute.startsWith(prefix)) continue;

        final String relative = absolute.substring(prefix.length);
        final List<String> parts = relative.split(Platform.pathSeparator);
        if (parts.isEmpty) continue;
        final String name = parts.removeLast();
        final String folder =
            parts.isEmpty ? '' : parts.join(Platform.pathSeparator);
        out.add(_RecycleEntry(
          absolutePath: absolute,
          originalFolder: folder,
          name: name,
        ));
      }
    } catch (_) {
      return const [];
    }

    out.sort((a, b) {
      final int byFolder = a.originalFolder
          .toLowerCase()
          .compareTo(b.originalFolder.toLowerCase());
      if (byFolder != 0) return byFolder;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  /// Restores one recycled image to the folder encoded in its recycle path.
  /// Existing files are never overwritten; the same _2/_3 naming convention
  /// used by imports and recycling keeps every byte recoverable.
  Future<void> _restoreRecycledImage(_RecycleEntry entry) async {
    try {
      final String imagesRoot =
          Directory(widget.imagesDir).resolveSymbolicLinksSync();
      final Directory recycleDir = Directory(
        '$imagesRoot${Platform.pathSeparator}$kRecycleFolderName',
      );
      if (!recycleDir.existsSync()) throw 'Recycle folder is missing.';

      final String recycleRoot = recycleDir.resolveSymbolicLinksSync();
      final String recyclePrefix = recycleRoot.endsWith(Platform.pathSeparator)
          ? recycleRoot
          : '$recycleRoot${Platform.pathSeparator}';
      final String source = File(entry.absolutePath).resolveSymbolicLinksSync();
      if (!source.startsWith(recyclePrefix)) {
        throw 'That image is outside the recycle folder.';
      }

      final String relative = source.substring(recyclePrefix.length);
      final List<String> parts = relative.split(Platform.pathSeparator);
      if (parts.isEmpty) throw 'Recycle path is invalid.';
      final String name = parts.removeLast();
      final String originalFolder = parts.join(Platform.pathSeparator);
      if (originalFolder.isEmpty) {
        throw 'Original folder is missing from this recycle entry.';
      }

      final Directory targetDir = Directory(
        '$imagesRoot${Platform.pathSeparator}$originalFolder',
      )..createSync(recursive: true);
      final String targetName = _uniqueName(targetDir.path, name);
      final String target =
          '${targetDir.path}${Platform.pathSeparator}$targetName';

      final File src = File(source);
      try {
        src.renameSync(target);
      } catch (_) {
        src.copySync(target);
        src.deleteSync();
      }

      // Remove empty recycle subdirectories but deliberately leave _recycle
      // itself in place. This keeps the bin stable while avoiding dead folder
      // names in the author's mental model.
      Directory cursor = File(source).parent;
      while (cursor.path != recycleRoot) {
        try {
          if (cursor.listSync(followLinks: false).isNotEmpty) break;
          final Directory parent = cursor.parent;
          cursor.deleteSync();
          cursor = parent;
        } catch (_) {
          break;
        }
      }

      if (!mounted) return;
      _rescanAssets();
      _recycleItems = _recycleEntries();
      _notifyChanged();
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            targetName == name
                ? 'RESTORED — $originalFolder/$name'
                : 'RESTORED AS — $originalFolder/$targetName',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('RESTORE FAILED — $e')),
      );
    }
  }

  String _fieldKey(ScriptNode node, String paramKey) =>
      '${node.id}|$paramKey';

  bool _isPinned(ScriptNode node, String paramKey) =>
      _pinned?.key == _fieldKey(node, paramKey);

  void _pinField(ScriptNode node, String paramKey, AssetSlot slot) {
    setState(() {
      _pinned = _PinnedField(node.id, paramKey, slot);
      _fieldMessage = null;
      _fieldMessageKey = null;
      _fieldFailed = false;
    });
  }

  void _unpin() {
    if (_pinned == null) return;
    setState(() => _pinned = null);
  }

  /// Field currently under a drag, or null. The second half of the two-stage
  /// filter described in the runner: it throttles on movement because it
  /// cannot know the targets, and this throttles on target identity because
  /// it can. Dragging across 200 pixels inside one field repaints once.
  String? _hoveredKey;

  void _onDragMotion(Offset position) {
    if (!mounted) return;
    final String? hit = DropZoneRegistry.hitTest(position);
    if (hit == _hoveredKey) return;
    setState(() => _hoveredKey = hit);
  }

  void _onDragLeave() {
    if (!mounted || _hoveredKey == null) return;
    setState(() => _hoveredKey = null);
  }

  /// Entry point for every OS drop while node mode is open.
  ///
  /// Position wins. A drop that landed inside a field's region goes to that
  /// field, no click required, and [DropZoneRegistry] resolves it against
  /// live geometry so a scrolled panel cannot misroute. Only when the drop
  /// hit no field, or when the runner sent no position at all (an older
  /// binary against newer Dart), does the pinned field catch it.
  void _onDrop(DropEvent event) {
    // Fires from the platform channel, outside any build.
    if (!mounted || _importBusy || event.paths.isEmpty) return;

    final Offset? pos = event.position;
    if (pos != null && DropZoneRegistry.dispatch(pos, event.paths)) return;

    final _PinnedField? pin = _pinned;
    if (pin == null) return;

    // A pin outlives nothing: resolve it through the current node list, so
    // a pin left over from a node that has since been deleted or reparsed
    // is ignored rather than importing into a corpse.
    final int idx = _nodes.indexWhere((n) => n.id == pin.nodeId);
    if (idx < 0) {
      _unpin();
      return;
    }

    _handleDrop(event.paths, _nodes[idx], pin.paramKey, pin.slot);
  }

  /// A destination filename that will not clobber an existing file.
  /// R3nder never deletes anything, and silently overwriting an asset that
  /// another node references is a deletion with extra steps.
  String _uniqueName(String dir, String name) {
    final int dot = name.lastIndexOf('.');
    final String stem = dot > 0 ? name.substring(0, dot) : name;
    final String ext = dot > 0 ? name.substring(dot) : '';

    String candidate = name;
    int n = 2;
    while (File('$dir${Platform.pathSeparator}$candidate').existsSync() &&
        n <= 999) {
      candidate = '${stem}_$n$ext';
      n++;
    }
    return candidate;
  }

  bool _extAccepted(AssetSlot slot, String path) {
    final String lower = path.toLowerCase();
    return slot.acceptedExts.any(lower.endsWith);
  }

  /// Routes a batch of dropped paths into one field.
  ///
  /// Two shapes, decided by the slot rather than by what was dropped:
  /// a file field takes one file, a folder field takes any mix of files
  /// and directories and copies their contents in. Everything the slot
  /// cannot draw is skipped and counted rather than copied, since an
  /// unusable file in a referenced folder is a bake-time problem with no
  /// edit-time symptom.
  Future<void> _handleDrop(
    List<String> paths,
    ScriptNode node,
    String paramKey,
    AssetSlot slot,
  ) async {
    if (_importBusy || paths.isEmpty) return;
    final String key = _fieldKey(node, paramKey);
    setState(() {
      _importBusy = true;
      _fieldMessage = null;
      _fieldMessageKey = key;
      _fieldFailed = false;
    });

    String message;
    bool failed = false;
    try {
      message = slot.isFolder
          ? await _importIntoFolder(paths, node, paramKey, slot)
          : _importAsFile(paths, node, paramKey, slot);
    } catch (e) {
      message = e.toString();
      failed = true;
    }

    if (!mounted) return;
    _rescanAssets();
    setState(() {
      _importBusy = false;
      _fieldMessage = message;
      _fieldMessageKey = key;
      _fieldFailed = failed;
    });
    if (!failed) _notifyChanged();
  }

  /// File-kind destination: one file lands in the slot's root directory
  /// and the field is pointed at it.
  String _importAsFile(
    List<String> paths,
    ScriptNode node,
    String paramKey,
    AssetSlot slot,
  ) {
    final String first = paths.first;
    if (Directory(first).existsSync()) {
      throw 'This field names a single file. Drop a file, not a folder.';
    }
    if (!File(first).existsSync()) throw 'Source not found: $first';
    if (!_extAccepted(slot, first)) {
      throw 'Wrong type for this field. Accepts '
          '${slot.acceptedExts.join(' ')}.';
    }

    final String root = _slotRoot(slot);
    Directory(root).createSync(recursive: true);

    final String srcName = first.split(Platform.pathSeparator).last;
    final String destName = _uniqueName(root, srcName);
    File(first).copySync('$root${Platform.pathSeparator}$destName');

    node.set(paramKey, destName);

    final String renamed =
        destName == srcName ? '' : ' as $destName (name was taken)';
    final String extras =
        paths.length > 1 ? '. Ignored ${paths.length - 1} other item(s)' : '';
    return 'Imported $srcName$renamed$extras.';
  }

  /// Folder-kind destination. The folder name comes from the field if it
  /// already has one, from the dropped directory's own name when a single
  /// directory was dropped, and from a prompt otherwise. Dropping a folder
  /// of stills onto an empty GALLERY field is therefore one move.
  Future<String> _importIntoFolder(
    List<String> paths,
    ScriptNode node,
    String paramKey,
    AssetSlot slot,
  ) async {
    String folderName = node.param(paramKey).trim();

    if (folderName.isEmpty) {
      if (paths.length == 1 && Directory(paths.first).existsSync()) {
        folderName = paths.first.split(Platform.pathSeparator).last;
      } else {
        final String? picked = await _promptFolderName();
        if (picked == null) return 'Import cancelled.';
        folderName = picked;
      }
    }

    folderName = _sanitizeFolderName(folderName);
    if (folderName.isEmpty) throw 'That folder name has no usable characters.';

    final String dest =
        '${_slotRoot(slot)}${Platform.pathSeparator}$folderName';
    Directory(dest).createSync(recursive: true);

    int copied = 0;
    int skipped = 0;

    void copyFile(String src) {
      if (!_extAccepted(slot, src)) {
        skipped++;
        return;
      }
      final String name = src.split(Platform.pathSeparator).last;
      if (name.startsWith('.')) {
        skipped++;
        return;
      }
      File(src).copySync(
          '$dest${Platform.pathSeparator}${_uniqueName(dest, name)}');
      copied++;
    }

    for (final p in paths) {
      if (Directory(p).existsSync()) {
        // One level only. A nested tree is not what a flat asset folder
        // means, and recursing would quietly flatten a structure the user
        // built on purpose.
        for (final ent in Directory(p).listSync(followLinks: false)) {
          if (ent is File) copyFile(ent.path);
        }
      } else if (File(p).existsSync()) {
        copyFile(p);
      }
    }

    if (copied == 0) {
      throw skipped == 0
          ? 'Nothing usable in that drop.'
          : 'Skipped $skipped file(s): this field accepts '
              '${slot.acceptedExts.join(' ')}.';
    }

    node.set(paramKey, folderName);

    final String tail = skipped > 0 ? ', skipped $skipped' : '';
    return 'Copied $copied file(s) into $folderName$tail.';
  }

  /// Strips path separators and leading dots so a typed name cannot escape
  /// the workspace or create a hidden folder the scanner will not list.
  String _sanitizeFolderName(String raw) {
    String s = raw.trim().replaceAll(RegExp(r'[\\/]+'), '_');
    while (s.startsWith('.')) {
      s = s.substring(1);
    }
    return s.trim();
  }

  Future<String?> _promptFolderName() async {
    final t = widget.theme;
    final TextEditingController ctl = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: R3Theme.panel,
          title: Text('NEW FOLDER NAME',
              style: t.value.copyWith(letterSpacing: sc(2))),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Loose files need a folder to live in, and this field is '
                'empty. Name it and the drop lands there.',
                style: t.fine.copyWith(height: 1.4),
              ),
              SizedBox(height: sc(14)),
              TextField(
                controller: ctl,
                autofocus: true,
                style: t.value,
                decoration: const InputDecoration(
                    isDense: true, hintText: 'evidence_scans'),
                onSubmitted: (v) => Navigator.pop(ctx, v),
              ),
            ],
          ),
          actions: [
            R3Button('Cancel',
                theme: t,
                compact: true,
                onPressed: () => Navigator.pop(ctx, null)),
            R3Button('Create',
                theme: t,
                compact: true,
                kind: R3ButtonKind.primary,
                onPressed: () => Navigator.pop(ctx, ctl.text)),
          ],
        ),
      );
    } finally {
      ctl.dispose();
    }
  }

  // -------------------------------------------------------------------
  // Document composition and line tracking
  // -------------------------------------------------------------------

  /// The whole document, rebuilt from the node list. Joined with the empty
  /// string because every node carries its own whitespace.
  String _compose() {
    final StringBuffer b = StringBuffer();
    for (final n in _nodes) {
      b.write(n.toMarkup());
    }
    return b.toString();
  }

  /// Walks the node list accumulating newlines to assign each node its line
  /// span. Exact by construction, since the composed document is the
  /// concatenation of exactly these markups.
  ///
  /// endLine is the line of the node's LAST character, matching how the
  /// engine reports the line it is currently executing.
  void _recomputeLines() {
    assignNodeLineSpans(_nodes);

    // [#NEEDS:folder:N] declarations. Kept here rather than folded into the
    // hoisted span pass because it is panel business: the ribbon has no use
    // for it, and a shared function that computed something one caller
    // always discards would be the wrong shape.
    final Map<String, int> needs = {};
    for (final n in _nodes) {
      final String m = n.toMarkup();
      if (!m.contains('NEEDS:')) continue;
      for (final hit in _needsRegex.allMatches(m)) {
        final int? v = int.tryParse(hit.group(2)!);
        if (v != null) needs[hit.group(1)!.toLowerCase()] = v;
      }
    }
    _declaredCounts = needs;
  }

  void _notifyChanged() {
    _recomputeLines();
    _lastAutoScrolledIdx = -1;
    setState(() {});
    widget.onTextChanged(_compose());
  }

  // -------------------------------------------------------------------
  // Parsing
  // -------------------------------------------------------------------

  /// Splits the document into a gapless node list. Every character of the
  /// input lands in exactly one node.
  // -------------------------------------------------------------------
  // Parsing
  //
  // The parser itself is top level (see parseScriptToNodes). It is pure,
  // text in and nodes out, and the script ribbon in text mode needs the
  // same decomposition without mounting this widget. Leaving it as a State
  // method would have meant either duplicating it or instantiating a node
  // workspace nobody renders.
  // -------------------------------------------------------------------

  List<ScriptNode> _parseTextToNodes(String text) => parseScriptToNodes(text);

  // -------------------------------------------------------------------
  // Node list helpers
  // -------------------------------------------------------------------

  List<int> get _visibleIndices {
    final List<int> out = [];
    for (int i = 0; i < _nodes.length; i++) {
      if (_nodes[i].isVisible) out.add(i);
    }
    return out;
  }

  int _nodeIndexById(String? id) {
    if (id == null) return -1;
    return _nodes.indexWhere((n) => n.id == id);
  }

  ScriptNode? get _selectedNode {
    final int i = _nodeIndexById(_selectedId);
    return i < 0 ? null : _nodes[i];
  }

  /// A node plus the spacer run trailing it. Structural edits move and
  /// delete whole blocks so line breaks never pile up or vanish.
  int _blockEnd(int start) {
    int e = start + 1;
    while (e < _nodes.length && _nodes[e].isSpacer) {
      e++;
    }
    return e;
  }

  // -------------------------------------------------------------------
  // Scrolling
  // -------------------------------------------------------------------

  void _scrollToHighlightedLine({bool animate = true}) {
    if (!_scrollController.hasClients) return;
    if (widget.highlightedLine < 0) return;

    final List<int> vis = _visibleIndices;
    int hitVis = -1;
    for (int v = 0; v < vis.length; v++) {
      final ScriptNode n = _nodes[vis[v]];
      if (widget.highlightedLine >= n.startLine &&
          widget.highlightedLine <= n.endLine) {
        hitVis = v;
      }
    }
    if (hitVis < 0 || hitVis == _lastAutoScrolledIdx) return;
    _lastAutoScrolledIdx = hitVis;

    final double viewport = _scrollController.position.viewportDimension;
    final double target =
        _listPadV + (hitVis * _rowH) - (viewport / 2) + (_rowH / 2);
    final double clamped =
        target.clamp(0.0, _scrollController.position.maxScrollExtent);

    if (animate) {
      _scrollController.animateTo(
        clamped,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scrollController.jumpTo(clamped);
    }
  }

  // -------------------------------------------------------------------
  // Structural editing
  // -------------------------------------------------------------------

  /// Parses palette markup into nodes so inserted content is guaranteed to
  /// match what the form expects. Marks them dirty so they emit from
  /// params, not from the palette's literal string.
  List<ScriptNode> _nodesFromMarkup(String markup) {
    final List<ScriptNode> parsed = _parseTextToNodes(markup);
    for (final n in parsed) {
      if (!n.isSpacer) n.dirty = true;
    }
    return parsed;
  }

  void _insertSnippet(TagSnippet snip) {
    final List<ScriptNode> incoming = _nodesFromMarkup(snip.insertText);
    if (incoming.isEmpty) return;

    // Insert after the selected node's block, or at the end.
    int at = _nodes.length;
    final int sel = _nodeIndexById(_selectedId);
    if (sel >= 0) at = _blockEnd(sel);

    // Keep the inserted tag on its own line: if the preceding markup does
    // not already end on a newline, open one.
    final List<ScriptNode> batch = [];
    if (at > 0 && !_nodes[at - 1].toMarkup().endsWith('\n')) {
      batch.add(ScriptNode(type: kSpacer, rawText: '\n'));
    }
    batch.addAll(incoming);
    batch.add(ScriptNode(type: kSpacer, rawText: '\n'));

    ScriptNode? firstVisible;
    for (final n in batch) {
      if (n.isVisible) {
        firstVisible = n;
        break;
      }
    }

    setState(() {
      _nodes.insertAll(at, batch);
      if (firstVisible != null) _selectedId = firstVisible.id;
    });
    _notifyChanged();
  }

  void _deleteSelected() {
    final int i = _nodeIndexById(_selectedId);
    if (i < 0) return;

    setState(() {
      _nodes.removeRange(i, _blockEnd(i));
      final List<int> vis = _visibleIndices;
      if (vis.isEmpty) {
        _selectedId = null;
      } else {
        final int next = vis.firstWhere((v) => v >= i, orElse: () => vis.last);
        _selectedId = _nodes[next].id;
      }
    });
    _notifyChanged();
  }

  void _duplicateSelected() {
    final int i = _nodeIndexById(_selectedId);
    if (i < 0) return;

    final ScriptNode src = _nodes[i];
    final ScriptNode copy = ScriptNode(type: src.type, rawText: src.rawText)
      ..params = Map<String, String>.from(src.params)
      ..body = src.body
      ..prefix = src.prefix
      ..suffix = src.suffix
      ..dirty = src.dirty;

    setState(() {
      _nodes.insertAll(
          _blockEnd(i), [copy, ScriptNode(type: kSpacer, rawText: '\n')]);
      _selectedId = copy.id;
    });
    _notifyChanged();
  }

  /// Moves the selected block one visible slot up or down.
  void _moveSelected(int dir) {
    final int i = _nodeIndexById(_selectedId);
    if (i < 0) return;

    final List<int> vis = _visibleIndices;
    final int v = vis.indexOf(i);
    if (v < 0) return;

    final int targetVis = v + dir;
    if (targetVis < 0 || targetVis >= vis.length) return;

    // ReorderableListView's convention: a downward move addresses the slot
    // one past the destination, because the item is still in the list.
    _reorderVisible(v, dir > 0 ? targetVis + 1 : targetVis);
  }

  /// Block-aware reorder, shared by the drag handles and the move buttons.
  /// [newVis] follows ReorderableListView's convention: the index the item
  /// should occupy in the list as it existed BEFORE removal.
  void _reorderVisible(int oldVis, int newVis) {
    final List<int> vis = _visibleIndices;
    if (oldVis < 0 || oldVis >= vis.length) return;

    final int start = vis[oldVis];
    final int end = _blockEnd(start);
    final List<ScriptNode> block = _nodes.sublist(start, end);

    // Where the block lands, expressed in full-list terms before removal.
    final int insertAt = newVis >= vis.length ? _nodes.length : vis[newVis];

    setState(() {
      _nodes.removeRange(start, end);
      // Pulling the block out shifts anything after it left by its size.
      int adjusted = insertAt > start ? insertAt - block.length : insertAt;
      adjusted = adjusted.clamp(0, _nodes.length);
      _nodes.insertAll(adjusted, block);
    });
    _notifyChanged();
  }

  // -------------------------------------------------------------------
  // Presentation helpers
  // -------------------------------------------------------------------

  Color _getNodeColor(String type) {
    switch (type) {
      case 'TEXT':
        return Colors.green.shade600;
      case 'PAUSE':
      case 'SPEED':
      case 'VPAD':
        return Colors.blue.shade500;
      case 'GALLERY':
      case 'VIDEO':
      case 'CARD':
      case 'APP':
      case 'BROWSER':
      case 'DOSSIER':
      case 'TIMELINE':
        return Colors.redAccent.shade400;
      case 'IMG':
      case 'SVG':
      case 'SVGFLASH':
      case 'PHOTO':
      case 'SPRITE':
      case 'SPRITE_OFF':
        return Colors.amber.shade600;
      case 'COLOR':
      case 'WIPE':
      case 'FLASH':
      case 'SCRAMBLE':
      case 'INVERT':
      case 'REDACT':
        return Colors.deepPurpleAccent.shade400;
      case 'ALIGN':
      case 'SIZE':
      case 'LEAD':
      case 'BAR':
        return Colors.tealAccent.shade400;
      case 'CONFIG':
      case 'REGION':
      case 'REGION_END':
      case 'SELECT':
        return Colors.blueGrey.shade400;
      case 'DEF_MENU':
      case 'CALL':
      case 'MENU_STATE':
      case 'MACRO_CFG':
        return Colors.orangeAccent.shade400;
      default:
        return Colors.grey.shade600;
    }
  }

  IconData _getNodeIcon(String type) {
    switch (type) {
      case 'TEXT':
        return Icons.text_fields;
      case 'PAUSE':
        return Icons.pause_circle_outline;
      case 'SPEED':
        return Icons.speed;
      case 'VPAD':
        return Icons.height;
      case 'GALLERY':
      case 'DOSSIER':
        return Icons.photo_library;
      case 'VIDEO':
        return Icons.movie_outlined;
      case 'CARD':
        return Icons.info_outline;
      case 'APP':
        return Icons.grid_view;
      case 'BROWSER':
        return Icons.public;
      case 'TIMELINE':
        return Icons.timeline;
      case 'COLOR':
        return Icons.color_lens;
      case 'WIPE':
        return Icons.cleaning_services;
      case 'IMG':
      case 'SVG':
      case 'PHOTO':
        return Icons.image;
      case 'SVGFLASH':
        return Icons.flash_on;
      case 'SPRITE':
        return Icons.animation;
      case 'SPRITE_OFF':
        return Icons.stop_circle_outlined;
      case 'FLASH':
        return Icons.bolt;
      case 'SCRAMBLE':
        return Icons.shuffle;
      case 'INVERT':
        return Icons.invert_colors;
      case 'REDACT':
        return Icons.block;
      case 'BAR':
        return Icons.linear_scale;
      case 'ALIGN':
        return Icons.format_align_center;
      case 'SIZE':
        return Icons.format_size;
      case 'LEAD':
        return Icons.format_line_spacing;
      case 'CONFIG':
        return Icons.settings_outlined;
      case 'REGION':
      case 'REGION_END':
        return Icons.select_all;
      case 'SELECT':
        return Icons.highlight_alt;
      case 'DEF_MENU':
        return Icons.list_alt;
      case 'CALL':
        return Icons.play_for_work;
      case 'MENU_STATE':
        return Icons.radio_button_checked;
      case 'MACRO_CFG':
        return Icons.tune;
      default:
        return Icons.code;
    }
  }

  String _getNodeSummary(ScriptNode node) {
    switch (node.type) {
      case 'TEXT':
        return node.body.replaceAll('\n', ' \u21b5 ');
      case 'PAUSE':
        return '${node.param('frames', '30')} frames';
      case 'SPEED':
        return node.param('speed', '1') == 'MAX'
            ? 'Instant'
            : '${node.param('speed', '1')} char/frame';
      case 'COLOR':
        return node.param('color');
      case 'FLASH':
        return node.param('flash');
      case 'SCRAMBLE':
        return node.param('scramble');
      case 'INVERT':
        return node.param('invert');
      case 'REDACT':
        return node.param('redact') == '/REDACT' ? 'Close' : 'Open';
      case 'ALIGN':
        return node.param('align');
      case 'SIZE':
        return node.param('size');
      case 'LEAD':
        return node.param('lead');
      case 'VPAD':
        return '${node.param('vpad')} px';
      case 'BAR':
        return '${node.param('width')} wide, ${node.param('frames')} frames';
      case 'REGION':
      case 'SELECT':
        return node.param('id');
      case 'REGION_END':
        return 'End of region';
      case 'CONFIG':
        return '${node.param('key')} = ${node.param('value')}';
      case 'GALLERY':
      case 'VIDEO':
      case 'SVGFLASH':
        return node.param('folder');
      case 'BROWSER':
        final seg = parseBrowserScrollSegment(node.param('scroll', 'SCROLL'));
        final String full = seg.maximizes ? ', full' : '';
        switch (seg.scroll) {
          case BrowserScroll.top:
            return '${node.param('folder')} (above the fold$full)';
          case BrowserScroll.fit:
            return '${node.param('folder')} (fitted$full)';
          case BrowserScroll.scroll:
            return '${node.param('folder')} (scrolling$full)';
        }
      case 'APP':
        final String lay = node.param('layout', 'GRID').toUpperCase();
        if (lay == 'MOSAIC_FULL') return '${node.param('folder')} (mosaic, full)';
        if (lay == 'MOSAIC') return '${node.param('folder')} (mosaic)';
        return node.param('folder');
      case 'DOSSIER':
        final String mode = node.param('centerMode', 'GRID');
        final String tail = mode == 'MOSAIC'
            ? ' (mosaic)'
            : mode == 'SIDE_ONLY'
                ? ' (side card only)'
                : '';
        return '${node.param('folder')} + ${node.param('image')}$tail';
      case 'CARD':
        return node.param('heading').isNotEmpty
            ? node.param('heading')
            : node.param('image');
      case 'TIMELINE':
        return node.param('heading').isNotEmpty
            ? node.param('heading')
            : 'Timeline';
      case 'IMG':
      case 'SVG':
      case 'PHOTO':
      case 'SPRITE':
      case 'SPRITE_OFF':
        return node.param('file');
      case 'DEF_MENU':
        final int n = _menuItemRegex.allMatches(node.body).length;
        return '${node.param('id')}, $n ${n == 1 ? 'item' : 'items'}';
      case 'CALL':
        return 'draw ${node.param('menu')}';
      case 'MENU_STATE':
        return '${node.param('menu')} -> ${node.param('instance')}';
      case 'MACRO_CFG':
        return '${node.param('instance')} = ${node.param('item')}';
      default:
        return node.rawText.replaceAll('\n', ' \u21b5 ');
    }
  }

  /// The node's primary asset reference, or null when it has none. Drives
  /// the missing badge on the row.
  ({AssetSlot slot, String value})? _primaryAsset(ScriptNode n) {
    switch (n.type) {
      case 'GALLERY':
      case 'VIDEO':
      case 'APP':
      case 'BROWSER':
      case 'DOSSIER':
        return (slot: AssetSlot.imageFolder, value: n.param('folder'));
      case 'SVGFLASH':
        return (slot: AssetSlot.svgFolder, value: n.param('folder'));
      case 'CARD':
        return (slot: AssetSlot.rasterFile, value: n.param('image'));
      case 'IMG':
      case 'PHOTO':
        return (slot: AssetSlot.rasterFile, value: n.param('file'));
      case 'SVG':
        return (slot: AssetSlot.svgFile, value: n.param('file'));
      case 'SPRITE':
      case 'SPRITE_OFF':
        return (slot: AssetSlot.spriteFile, value: n.param('file'));
      default:
        return null;
    }
  }

  bool _nodeHasMissingAsset(ScriptNode n) {
    final a = _primaryAsset(n);
    if (a == null) return false;
    return !_assets.resolves(a.slot, a.value);
  }

  // -------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _buildNodeGraphView()),
        Container(width: 1, color: R3Theme.hairline),
        SizedBox(
          width: sc(360),
          child: _showRecyclePanel
              ? _buildRecyclePanel()
              : _buildNodePropertiesPanel(),
        ),
      ],
    );
  }

  // --- Graph column --------------------------------------------------

  Widget _buildNodeGraphView() {
    final List<int> vis = _visibleIndices;

    int activeVis = -1;
    if (widget.highlightedLine >= 0) {
      for (int v = 0; v < vis.length; v++) {
        final ScriptNode n = _nodes[vis[v]];
        if (widget.highlightedLine >= n.startLine &&
            widget.highlightedLine <= n.endLine) {
          activeVis = v;
        }
      }
    }

    return Container(
      color: R3Theme.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildGraphToolbar(vis.length),
          Expanded(
            child: CustomPaint(
              painter: DotGridPainter(),
              child: vis.isEmpty
                  ? Center(
                      child: Text('EMPTY SCRIPT. ADD A NODE.',
                          style: widget.theme.micro))
                  : ScrollConfiguration(
                      behavior: ScrollConfiguration.of(context).copyWith(
                        dragDevices: {
                          PointerDeviceKind.touch,
                          PointerDeviceKind.mouse,
                          PointerDeviceKind.trackpad,
                        },
                      ),
                      child: ReorderableListView.builder(
                        scrollController: _scrollController,
                        buildDefaultDragHandles: false,
                        padding: EdgeInsets.symmetric(
                            horizontal: sc(16), vertical: _listPadV),
                        itemCount: vis.length,
                        onReorder: _reorderVisible,
                        itemBuilder: (ctx, v) =>
                            _buildNodeRow(v, vis[v], activeVis),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGraphToolbar(int count) {
    final t = widget.theme;
    final bool hasSel = _selectedNode != null;

    return Container(
      padding: EdgeInsets.symmetric(horizontal: sc(14), vertical: sc(8)),
      decoration: const BoxDecoration(
        color: R3Theme.panel,
        border: Border(bottom: BorderSide(color: R3Theme.hairline)),
      ),
      child: Row(
        children: [
          R3Button('Add',
              theme: t,
              compact: true,
              kind: R3ButtonKind.primary,
              onPressed: _openPalette),
          SizedBox(width: sc(8)),
          R3Button(
            'Recycle · ${_recycleItems.length}',
            theme: t,
            compact: true,
            onPressed: () {
              FocusScope.of(context).unfocus();
              setState(() {
                _recycleItems = _recycleEntries();
                _showRecyclePanel = true;
              });
            },
          ),
          SizedBox(width: sc(8)),
          _iconAction(Icons.arrow_upward, 'Move up',
              hasSel ? () => _moveSelected(-1) : null),
          _iconAction(Icons.arrow_downward, 'Move down',
              hasSel ? () => _moveSelected(1) : null),
          _iconAction(Icons.copy_all_outlined, 'Duplicate',
              hasSel ? _duplicateSelected : null),
          _iconAction(Icons.delete_outline, 'Delete',
              hasSel ? _deleteSelected : null,
              danger: true),
          const Spacer(),
          Text('$count NODES', style: t.micro),
        ],
      ),
    );
  }

  Widget _iconAction(IconData icon, String tip, VoidCallback? onTap,
      {bool danger = false}) {
    final Color c = onTap == null
        ? R3Theme.textDim
        : (danger ? R3Theme.danger : R3Theme.textMid);
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(3),
        child: Padding(
          padding: EdgeInsets.all(sc(6)),
          child: Icon(icon, size: sc(16), color: c),
        ),
      ),
    );
  }

  Widget _buildNodeRow(int vis, int nodeIdx, int activeVis) {
    final ScriptNode node = _nodes[nodeIdx];
    final bool isSelected = node.id == _selectedId;
    final bool isPlaying = vis == activeVis;
    final bool missing = _nodeHasMissingAsset(node);
    final Color color = _getNodeColor(node.type);
    final t = widget.theme;

    return Padding(
      key: ValueKey(node.id),
      padding: EdgeInsets.only(bottom: sc(6)),
      child: SizedBox(
        height: _rowH - sc(6),
        child: GestureDetector(
          onTap: () {
            FocusScope.of(context).unfocus();
            // A pin names a field on the panel, and moving the panel to
            // another node takes that field off screen. Position-based
            // drops need no cleanup: the field's region unregisters itself
            // when it leaves the tree.
            if (_selectedId != node.id) _unpin();
            setState(() {
              _selectedId = node.id;
              _showRecyclePanel = false;
            });
          },
          child: Container(
            decoration: BoxDecoration(
              color: R3Theme.panel,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(
                color: isPlaying
                    ? R3Theme.okGreen
                    : (isSelected ? t.accent : R3Theme.hairline),
                width: isSelected || isPlaying ? 1.5 : 1,
              ),
              boxShadow: isPlaying
                  ? [
                      BoxShadow(
                          color: R3Theme.okGreen.withValues(alpha: 0.22),
                          blurRadius: 10)
                    ]
                  : null,
            ),
            child: Row(
              children: [
                Container(
                  width: sc(5),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius:
                        const BorderRadius.horizontal(left: Radius.circular(4)),
                  ),
                ),
                SizedBox(width: sc(10)),
                Icon(_getNodeIcon(node.type), size: sc(15), color: color),
                SizedBox(width: sc(10)),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(node.type, style: t.micro.copyWith(color: color)),
                      SizedBox(height: sc(3)),
                      Text(
                        _getNodeSummary(node),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.fine.copyWith(color: R3Theme.textMid),
                      ),
                    ],
                  ),
                ),
                if (missing) ...[
                  const R3Tally(state: R3TallyState.error, count: 'MISSING'),
                  SizedBox(width: sc(8)),
                ],
                if (isPlaying) ...[
                  const R3Tally(state: R3TallyState.ok),
                  SizedBox(width: sc(8)),
                ],
                Text('L${node.startLine + 1}', style: t.fine),
                ReorderableDragStartListener(
                  index: vis,
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: sc(8)),
                    child: Icon(Icons.drag_indicator,
                        size: sc(16), color: R3Theme.textDim),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // --- Palette -------------------------------------------------------

  Future<void> _openPalette() async {
    final t = widget.theme;
    String filter = '';

    final TagSnippet? picked = await showDialog<TagSnippet>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setDialogState) {
          final String f = filter.trim().toLowerCase();
          final List<TagSnippet> shown = f.isEmpty
              ? kAllTags
              : kAllTags
                  .where((s) =>
                      s.label.toLowerCase().contains(f) ||
                      s.description.toLowerCase().contains(f))
                  .toList();

          return AlertDialog(
            title:
                Text('ADD NODE', style: t.value.copyWith(letterSpacing: sc(2))),
            content: SizedBox(
              width: sc(430),
              height: sc(420),
              child: Column(
                children: [
                  TextField(
                    autofocus: true,
                    style: t.value,
                    decoration: const InputDecoration(
                        isDense: true, hintText: 'Filter tags'),
                    onChanged: (v) => setDialogState(() => filter = v),
                  ),
                  SizedBox(height: sc(12)),
                  Expanded(
                    child: shown.isEmpty
                        ? Center(child: Text('NO MATCH', style: t.micro))
                        : ListView.builder(
                            itemCount: shown.length,
                            itemBuilder: (c, i) {
                              final TagSnippet s = shown[i];
                              return InkWell(
                                onTap: () => Navigator.pop(ctx, s),
                                child: Container(
                                  padding: EdgeInsets.symmetric(
                                      horizontal: sc(10), vertical: sc(9)),
                                  decoration: const BoxDecoration(
                                    border: Border(
                                        bottom:
                                            BorderSide(color: R3Theme.hairline)),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(s.label, style: t.value),
                                      SizedBox(height: sc(2)),
                                      Text(s.description,
                                          style: t.fine,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              R3Button('Cancel',
                  theme: t,
                  compact: true,
                  onPressed: () => Navigator.pop(ctx, null)),
            ],
          );
        });
      },
    );

    if (picked != null) _insertSnippet(picked);
  }

  /// Permanently deletes everything the recycle browser is showing.
  ///
  /// This is the ONLY place R3nder deletes a file, and the exception is
  /// deliberate. The bin is hidden from every picker and from the orphan
  /// scan, which is what makes removal feel safe; the cost is that there is
  /// no way to empty it from inside the app. Telling an author to go find a
  /// folder whose name starts with an underscore in a file manager is worse
  /// than one confirmed button here.
  ///
  /// Scoped to [_recycleItems] rather than deleting the tree, so anything in
  /// the bin the browser did not list (a stray non-raster, a file dropped
  /// there by hand) survives. Purge removes what you were shown, exactly.
  Future<void> _purgeRecycle() async {
    final List<_RecycleEntry> doomed = List.of(_recycleItems);
    if (doomed.isEmpty) return;

    final int bytes = _recycleBytes(doomed);
    final bool ok = await _confirmPurge(doomed.length, bytes);
    if (!ok || !mounted) return;

    int removed = 0;
    final List<String> failed = [];
    final Set<String> touchedDirs = {};

    for (final e in doomed) {
      try {
        final File f = File(e.absolutePath);
        touchedDirs.add(f.parent.path);
        f.deleteSync();
        removed++;
      } catch (_) {
        failed.add(e.name);
      }
    }

    // Same pruning contract restore uses: empty subdirectories go, _recycle
    // itself stays, so the bin is a stable place rather than one that
    // appears and disappears.
    final String recycleRoot =
        '${widget.imagesDir}${Platform.pathSeparator}$kRecycleFolderName';
    for (final path in touchedDirs) {
      Directory cursor = Directory(path);
      while (cursor.path != recycleRoot) {
        try {
          if (!cursor.existsSync()) break;
          if (cursor.listSync(followLinks: false).isNotEmpty) break;
          final Directory parent = cursor.parent;
          cursor.deleteSync();
          cursor = parent;
        } catch (_) {
          break;
        }
      }
    }

    if (!mounted) return;
    // Deliberately not [_rescanAssets]. Purge only touches the recycle bin,
    // which is hidden from the pickers and unreachable from any script, so
    // the asset library is unchanged and the scene has nothing stale to
    // reload. Notifying here would cost a full resimulation for a folder
    // nothing renders from.
    invalidateAssetPreviews();
    setState(() => _recycleItems = _recycleEntries());

    final String msg = failed.isEmpty
        ? 'Purged $removed file(s).'
        : 'Purged $removed, could not remove ${failed.length}: '
            '${failed.take(3).join(', ')}';
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  int _recycleBytes(List<_RecycleEntry> entries) {
    int total = 0;
    for (final e in entries) {
      try {
        total += File(e.absolutePath).lengthSync();
      } catch (_) {
        // A file that vanished under us contributes nothing and is not an
        // error worth surfacing on a size readout.
      }
    }
    return total;
  }

  static String _byteLabel(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// Confirmation is required and cannot be defaulted through: the primary
  /// action is Cancel, and the destructive one has to be chosen. Everywhere
  /// else in this app an accident is undoable, so this is the one dialog
  /// that has to be read.
  Future<bool> _confirmPurge(int count, int bytes) async {
    final t = widget.theme;
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: R3Theme.panel,
        title: Text('PURGE RECYCLE',
            style: t.value.copyWith(letterSpacing: sc(2))),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Permanently deletes $count file(s), ${_byteLabel(bytes)}.',
              style: t.value,
            ),
            SizedBox(height: sc(10)),
            Text(
              'This cannot be undone and it is the only action in R3nder '
              'that removes a file from disk. Anything still referenced by '
              'a script is not in here.',
              style: t.fine.copyWith(height: 1.4),
            ),
          ],
        ),
        actions: [
          R3Button('Cancel',
              theme: t,
              compact: true,
              kind: R3ButtonKind.primary,
              onPressed: () => Navigator.pop(ctx, false)),
          R3Button('Purge',
              theme: t, compact: true, onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    return yes ?? false;
  }

  // --- Recycle panel -------------------------------------------------

  Widget _buildRecyclePanel() {
    final t = widget.theme;
    final List<_RecycleEntry> entries = _recycleItems;

    return Container(
      color: R3Theme.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: EdgeInsets.symmetric(horizontal: sc(16), vertical: sc(12)),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: R3Theme.hairline)),
            ),
            child: Row(
              children: [
                Icon(Icons.restore_from_trash_outlined,
                    size: sc(16), color: t.accent),
                SizedBox(width: sc(10)),
                Expanded(
                  child: Text(
                    entries.isEmpty
                        ? 'RECYCLE · 0'
                        : 'RECYCLE · ${entries.length} · '
                            '${_byteLabel(_recycleBytes(entries))}',
                    style: t.micro.copyWith(color: t.accent),
                  ),
                ),
                if (entries.isNotEmpty)
                  Tooltip(
                    message: 'Permanently delete everything listed here',
                    child: InkWell(
                      onTap: _purgeRecycle,
                      borderRadius: BorderRadius.circular(3),
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: sc(8), vertical: sc(4)),
                        child: Text('PURGE',
                            style: t.fine.copyWith(color: R3Theme.danger)),
                      ),
                    ),
                  ),
                SizedBox(width: sc(4)),
                Tooltip(
                  message: 'Back to node settings',
                  child: InkWell(
                    onTap: () => setState(() => _showRecyclePanel = false),
                    borderRadius: BorderRadius.circular(3),
                    child: Padding(
                      padding: EdgeInsets.all(sc(5)),
                      child: Icon(Icons.close,
                          size: sc(16), color: R3Theme.textMid),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: entries.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.delete_outline,
                            size: sc(34), color: R3Theme.textDim),
                        SizedBox(height: sc(10)),
                        Text('RECYCLE IS EMPTY', style: t.micro),
                        SizedBox(height: sc(5)),
                        Text(
                          'REMOVED GALLERY IMAGES APPEAR HERE',
                          style: t.fine.copyWith(color: R3Theme.textDim),
                        ),
                      ],
                    ),
                  )
                : ListView(
                    padding: EdgeInsets.fromLTRB(
                        sc(16), sc(16), sc(16), sc(48)),
                    children: [
                      _hint(
                        'Nothing here is deleted. Restore returns an image to '
                        'its original folder; name collisions get a safe suffix.',
                      ),
                      Wrap(
                        spacing: sc(8),
                        runSpacing: sc(12),
                        children: [
                          for (final entry in entries)
                            _RecycleThumbCard(
                              entry: entry,
                              theme: t,
                              onRestore: () => _restoreRecycledImage(entry),
                            ),
                        ],
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  // --- Properties panel ----------------------------------------------

  Widget _buildNodePropertiesPanel() {
    final ScriptNode? node = _selectedNode;
    if (node == null) {
      return Container(
        color: R3Theme.panel,
        child:
            Center(child: Text('NO NODE SELECTED', style: widget.theme.micro)),
      );
    }

    final Color color = _getNodeColor(node.type);

    return Container(
      color: R3Theme.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: EdgeInsets.symmetric(horizontal: sc(16), vertical: sc(12)),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: R3Theme.hairline)),
            ),
            child: Row(
              children: [
                Icon(_getNodeIcon(node.type), size: sc(16), color: color),
                SizedBox(width: sc(10)),
                Expanded(
                  child: Text('${node.type} SETTINGS',
                      style: widget.theme.micro.copyWith(color: color)),
                ),
                Text('L${node.startLine + 1}', style: widget.theme.fine),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(sc(16), sc(16), sc(16), sc(48)),
              children: _buildNodeFormFields(node),
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------
  // Form controls
  // -------------------------------------------------------------------

  Widget _wrap(Widget child) =>
      Padding(padding: EdgeInsets.only(bottom: sc(16)), child: child);

  Widget _hint(String text, {bool danger = false}) {
    return Padding(
      padding: EdgeInsets.only(bottom: sc(14)),
      child: Text(
        text,
        style: widget.theme.fine.copyWith(
          color: danger ? R3Theme.danger : R3Theme.textDim,
          height: 1.4,
        ),
      ),
    );
  }

  /// Dims and disables a control the positional grammar does not allow to
  /// be set yet, and says why. This is the whole reason the form beats
  /// hand-written markup: an invalid segment order cannot be produced.
  Widget _gate(bool enabled, String reason, Widget child) {
    if (enabled) return child;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Opacity(opacity: 0.35, child: IgnorePointer(child: child)),
        Padding(
          padding: EdgeInsets.only(bottom: sc(14)),
          child: Text(reason.toUpperCase(),
              style: widget.theme.micro.copyWith(color: R3Theme.warn)),
        ),
      ],
    );
  }

  /// Dropdown without R3Dropdown's label gutter, for rows that already
  /// carry their own header.
  Widget _bareDropdown({
    required String value,
    required List<String> items,
    required String Function(String) itemLabel,
    required ValueChanged<String?> onChanged,
  }) {
    final t = widget.theme;
    final String safe = items.contains(value)
        ? value
        : (items.isNotEmpty ? items.first : '');

    return Container(
      padding: EdgeInsets.symmetric(horizontal: sc(8), vertical: sc(4)),
      decoration: BoxDecoration(
        color: R3Theme.panelHi,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: R3Theme.hairline),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: safe,
          dropdownColor: R3Theme.panelHi,
          icon: Icon(Icons.arrow_drop_down,
              color: R3Theme.textMid, size: sc(18)),
          isExpanded: true,
          isDense: true,
          style: t.value,
          focusColor: Colors.transparent,
          onChanged: items.isEmpty ? null : onChanged,
          items: items
              .map((s) => DropdownMenuItem<String>(
                    value: s,
                    child: Text(itemLabel(s),
                        style: t.value, overflow: TextOverflow.ellipsis),
                  ))
              .toList(),
        ),
      ),
    );
  }

  Widget _fText(ScriptNode node, String label, String key,
      {String fallback = '', String? hintText}) {
    final t = widget.theme;
    return _wrap(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        R3MicroLabel(label, theme: t),
        SizedBox(height: sc(6)),
        TextField(
          controller: _ctl('${node.id}|$key', node.param(key, fallback)),
          style: t.value,
          decoration: InputDecoration(isDense: true, hintText: hintText),
          onChanged: (v) {
            node.set(key, v);
            _notifyChanged();
          },
        ),
      ],
    ));
  }

  Widget _fArea(ScriptNode node, String label, String fieldKey, String value,
      ValueChanged<String> onChanged,
      {int minLines = 4}) {
    final t = widget.theme;
    return _wrap(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        R3MicroLabel(label, theme: t),
        SizedBox(height: sc(6)),
        TextField(
          controller: _ctl('${node.id}|$fieldKey', value),
          style: t.value,
          maxLines: null,
          minLines: minLines,
          decoration: const InputDecoration(isDense: true),
          onChanged: (v) {
            onChanged(v);
            node.dirty = true;
            _notifyChanged();
          },
        ),
      ],
    ));
  }

  /// Slider for feel plus chevrons for exact values. Frame counts need
  /// both: you drag to find the timing, then nudge to land on it.
  Widget _fInt(ScriptNode node, String label, String key,
      {required double min,
      required double max,
      required String def,
      String suffix = ''}) {
    final t = widget.theme;
    final int current =
        int.tryParse(node.param(key, def)) ?? int.tryParse(def) ?? min.toInt();

    void apply(int v) {
      node.set(key, '${v.clamp(min.toInt(), max.toInt())}');
      _notifyChanged();
    }

    return _wrap(Row(
      children: [
        Expanded(
          child: R3Slider(
            theme: t,
            label: label,
            value: current.toDouble().clamp(min, max),
            min: min,
            max: max,
            format: (v) =>
                suffix.isEmpty ? '${v.toInt()}' : '${v.toInt()} $suffix',
            onChanged: (v) => apply(v.round()),
          ),
        ),
        SizedBox(width: sc(4)),
        _iconAction(Icons.remove, 'Minus one', () => apply(current - 1)),
        _iconAction(Icons.add, 'Plus one', () => apply(current + 1)),
      ],
    ));
  }

  Widget _fEnum(ScriptNode node, String label, String key,
      List<String> options, String def,
      {ValueChanged<String>? onPicked}) {
    final String current = node.param(key, def);
    final List<String> items =
        options.contains(current) ? options : [current, ...options];

    return _wrap(R3Dropdown<String>(
      theme: widget.theme,
      label: label,
      value: current,
      items: items,
      itemLabel: (s) => s,
      onChanged: (v) {
        if (v == null) return;
        if (onPicked != null) {
          onPicked(v);
        } else {
          node.set(key, v);
        }
        _notifyChanged();
      },
    ));
  }

  Widget _fDossierCenterMode(ScriptNode node) {
    const List<String> options = ['GRID', 'MOSAIC', 'SIDE_ONLY'];
    final String current = node.param('centerMode', 'GRID');

    String labelFor(String value) {
      switch (value) {
        case 'MOSAIC':
          return 'CENTER MOSAIC';
        case 'SIDE_ONLY':
          return 'SIDE CARD ONLY — SKIP CENTER GALLERY';
        default:
          return 'CENTER GRID';
      }
    }

    return _wrap(R3Dropdown<String>(
      theme: widget.theme,
      label: 'After side view',
      value: options.contains(current) ? current : 'GRID',
      items: options,
      itemLabel: labelFor,
      onChanged: (v) {
        if (v == null) return;
        node.set('centerMode', v);
        _notifyChanged();
      },
    ));
  }

  /// Asset picker: a menu of what actually exists in the workspace, a
  /// preview of what the current value points at, a manual-entry escape
  /// hatch, and a drop target that imports straight into the workspace.
  ///
  /// The whole field is the drop region, not just the visible bar: a drop
  /// on the label or the thumbnail obviously means this field.
  ///
  /// [maxDimension] is the pixel cap the tag enforces at load time, passed
  /// through to the preview. Over the cap the runtime plays the tag as a
  /// dud with its timing preserved, which is a failure with no visible
  /// symptom until the bake, so it is reported here instead.
  Widget _fAsset(ScriptNode node, String label, String key, AssetSlot slot,
      {bool optional = false, int? maxDimension}) {
    final t = widget.theme;
    final String current = node.param(key);
    final List<String> found = _assets.forSlot(slot);
    final bool resolves = _assets.resolves(slot, current);
    final String fieldKey = _fieldKey(node, key);
    final bool pinned = _isPinned(node, key);
    final bool showingResult = _fieldMessageKey == fieldKey;

    final List<String> items = [];
    if (optional || current.isEmpty) items.add('');
    if (current.isNotEmpty && !found.contains(current)) items.add(current);
    items.addAll(found);

    return _wrap(DropTargetRegion(
      id: fieldKey,
      onDrop: (paths) => _handleDrop(paths, node, key, slot),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              R3MicroLabel(label, theme: t),
              SizedBox(width: sc(8)),
              if (!resolves)
                const R3Tally(state: R3TallyState.error, count: 'MISSING')
              else if (current.isNotEmpty)
                const R3Tally(state: R3TallyState.ok),
              const Spacer(),
              Text(_assets.slotLabel(slot), style: t.fine),
              // Enabled only where it can succeed. A field naming nothing
              // has no path, and one naming something the scan did not
              // find would open a directory that is not there: both are
              // better said by a dead control than by a status line
              // arriving a moment after the click.
              _iconAction(
                slot.isFolder ? Icons.folder_open : Icons.image_search,
                slot.isFolder ? 'OPEN FOLDER' : 'SHOW FILE',
                (current.trim().isNotEmpty && resolves && canRevealPaths)
                    ? () => _revealAsset(node, key, slot, current)
                    : null,
              ),
            ],
          ),
          SizedBox(height: sc(6)),
          if (found.isEmpty)
            Text('NOTHING FOUND IN WORKSPACE', style: t.micro)
          else
            _bareDropdown(
              value: current,
              items: items,
              itemLabel: (s) => s.isEmpty ? '(none)' : s,
              onChanged: (v) {
                if (v == null) return;
                node.set(key, v);
                _notifyChanged();
              },
            ),
          SizedBox(height: sc(6)),
          TextField(
            controller: _ctl(fieldKey, current),
            style: t.fine.copyWith(color: R3Theme.textMid),
            decoration: const InputDecoration(
                isDense: true, hintText: 'or type a path'),
            onChanged: (v) {
              node.set(key, v);
              _notifyChanged();
            },
          ),
          if (current.trim().isNotEmpty && resolves) ...[
            SizedBox(height: sc(12)),
            _assetPreview(node, slot, current, maxDimension),
          ],
          SizedBox(height: sc(10)),
          AssetDropZone(
            theme: t,
            pinned: pinned,
            hovering: _hoveredKey == fieldKey,
            busy: showingResult && _importBusy,
            hint: _dropHint(slot, current),
            onPin: () => _pinField(node, key, slot),
            onUnpin: _unpin,
          ),
          if (showingResult && _fieldMessage != null) ...[
            SizedBox(height: sc(8)),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                R3Tally(
                    state: _fieldFailed
                        ? R3TallyState.error
                        : R3TallyState.ok),
                SizedBox(width: sc(8)),
                Expanded(
                  child: Text(
                    _fieldMessage!,
                    style: t.fine.copyWith(
                      color: _fieldFailed ? R3Theme.danger : R3Theme.textMid,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    ));
  }

  /// One line saying what a drop will do, which differs by slot and by
  /// whether the field already names something.
  String _dropHint(AssetSlot slot, String current) {
    final String v = current.trim();
    if (!slot.isFolder) {
      return 'COPY ONE FILE INTO ${slot == AssetSlot.spriteFile ? 'SPRITES/' : 'IMAGES/'}';
    }
    if (v.isNotEmpty) return 'ADD FILES TO $v';
    return 'A FOLDER NAMES ITSELF, FILES WILL PROMPT';
  }

  Widget _assetPreview(
      ScriptNode node, AssetSlot slot, String value, int? maxDimension) {
    final String abs = _slotAbsolute(slot, value);
    if (abs.isEmpty) return const SizedBox.shrink();

    if (slot.isFolder) {
      // Page breaks are an APP MOSAIC concept. Every other folder tag
      // plays its images as one run, so offering break markers there would
      // draw a control that means nothing.
      final bool paged = node.type == 'APP' &&
          node.param('layout', 'GRID').toUpperCase().startsWith('MOSAIC');

      // Whether clicking a thumbnail opens the per-image profile at all.
      // A MOSAIC pane can carry a caption; a BROWSER page needs an address.
      // Both are facts about the file rather than the shot, so both are
      // authored in the same panel, and every other folder tag has nothing
      // per-image to say and leaves its thumbnails inert.
      final bool profiled = paged || node.type == 'BROWSER';

      final Map<String, ImageCaption> folderCaptions =
          profiled ? _captionsFor(abs) : const {};
      final String? selName =
          (profiled && _profileTarget != null &&
                  _profileTarget!.startsWith('$abs|'))
              ? _profileTarget!.substring(abs.length + 1)
              : null;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AssetFolderPreview(
            absoluteDir: abs,
            kind: slot.thumbKind,
            theme: widget.theme,
            expectedCount: _declaredFolderCount(value),
            onRecycle:
                slot == AssetSlot.imageFolder ? _recycleFolderImage : null,
            // Offered for every folder slot, not just rasters. SVGFLASH
            // flickers its folder in sequence, so its order is authored too,
            // and the engine reads the same manifest for both.
            onReorder: (names) => _reorderFolder(abs, names),
            onResetOrder: () => _resetFolderOrder(abs),
            pagePlan: paged ? parsePagePlan(node.param('pages')) : null,
            onPagePlanChanged:
                paged ? (plan) => _setPagePlan(node, plan) : null,
            panePlan: paged ? parseAppPanePlan(node.param('panes')) : null,
            onPanePlanChanged:
                paged ? (plan) => _setPanePlan(node, plan) : null,
            // Captions are a MOSAIC band, so the furniture only appears
            // where a band can actually be drawn.
            captions: paged ? folderCaptions : null,
            selectedName: selName,
            onSelectName: profiled
                ? (name, index, total) => setState(() {
                      final String key = '$abs|$name';
                      // Clicking the open thumbnail closes the profile, so
                      // the panel can be dismissed without hunting for an
                      // X, the same way the ★ clears itself.
                      final bool closing = _profileTarget == key;
                      _profileTarget = closing ? null : key;
                      _profileIndex = closing ? -1 : index;
                      _profileTotal = closing ? 0 : total;
                    })
                : null,
            holdFrames: paged ? _holdsByImage(node, _paneCountFor(node)) : const [],
          ),
          if (profiled && selName != null)
            _imageProfile(abs, selName, folderCaptions, node),
        ],
      );
    }
    return AssetFilePreview(
      absolutePath: abs,
      displayName: value.trim(),
      kind: slot.thumbKind,
      theme: widget.theme,
      maxDimension: maxDimension,
    );
  }

  /// Reads a [#NEEDS:folder:N] directive out of the live document, so the
  /// contact sheet can flag a folder that came up short.
  ///
  /// The directive is a comment: the preprocessor strips it before the tag
  /// parser runs, and the asset manager reads it off the raw script for
  /// exactly this reason. Reading the cache rather than the saved file
  /// keeps it honest against unsaved edits.
  int? _declaredFolderCount(String folder) {
    final String name = folder.trim();
    if (name.isEmpty) return null;
    return _declaredCounts[name.toLowerCase()];
  }

  /// RGB swatch. Optional slots offer a clear action, which is how a
  /// stencil goes back to inheriting the live pen color.
  Widget _fRgb(ScriptNode node, String label, String key,
      {required String def, bool optional = false, String? clearedLabel}) {
    final t = widget.theme;
    final String current = node.param(key).trim();
    final bool cleared = current.isEmpty;
    final String effective = cleared ? def : current;
    final Color swatch = _parseRgb(effective) ?? R3Theme.panelHi;

    return _wrap(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        R3MicroLabel(label, theme: t),
        SizedBox(height: sc(6)),
        Row(
          children: [
            InkWell(
              onTap: () async {
                final String? picked = await _pickRgb(effective);
                if (picked == null) return;
                node.set(key, picked);
                _notifyChanged();
              },
              borderRadius: BorderRadius.circular(4),
              child: Container(
                width: sc(46),
                height: sc(30),
                decoration: BoxDecoration(
                  color: (cleared && optional) ? R3Theme.panelHi : swatch,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: R3Theme.hairline),
                ),
                child: (cleared && optional)
                    ? Icon(Icons.remove, size: sc(14), color: R3Theme.textDim)
                    : null,
              ),
            ),
            SizedBox(width: sc(10)),
            Expanded(
              child: Text(
                cleared ? (clearedLabel ?? 'DEFAULT $def') : effective,
                style: cleared ? t.valueDim : t.value,
              ),
            ),
            if (optional && !cleared)
              _iconAction(Icons.backspace_outlined, 'Clear override', () {
                node.set(key, '');
                _notifyChanged();
              }),
          ],
        ),
      ],
    ));
  }

  Widget _fToggle(ScriptNode node, String label, String key, String onValue,
      String description) {
    final t = widget.theme;
    final bool on = node.param(key).trim().isNotEmpty;

    return _wrap(InkWell(
      onTap: () {
        node.set(key, on ? '' : onValue);
        _notifyChanged();
      },
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: sc(4)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: sc(16),
              height: sc(16),
              margin: EdgeInsets.only(top: sc(2)),
              decoration: BoxDecoration(
                color: on ? t.accentFaint : Colors.transparent,
                borderRadius: BorderRadius.circular(3),
                border:
                    Border.all(color: on ? t.accentDim : R3Theme.hairline),
              ),
              child:
                  on ? Icon(Icons.check, size: sc(12), color: t.accent) : null,
            ),
            SizedBox(width: sc(10)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label.toUpperCase(), style: t.micro),
                  SizedBox(height: sc(3)),
                  Text(description, style: t.fine),
                ],
              ),
            ),
          ],
        ),
      ),
    ));
  }

  static Color? _parseRgb(String s) {
    final List<String> parts = s.split(',');
    if (parts.length != 3) return null;
    final int? r = int.tryParse(parts[0].trim());
    final int? g = int.tryParse(parts[1].trim());
    final int? b = int.tryParse(parts[2].trim());
    if (r == null || g == null || b == null) return null;
    return Color.fromARGB(
        255, r.clamp(0, 255), g.clamp(0, 255), b.clamp(0, 255));
  }

  Future<String?> _pickRgb(String initial) async {
    final t = widget.theme;
    final List<String> parts = initial.split(',');
    int r = int.tryParse(parts.isNotEmpty ? parts[0].trim() : '') ?? 255;
    int g = int.tryParse(parts.length > 1 ? parts[1].trim() : '') ?? 255;
    int b = int.tryParse(parts.length > 2 ? parts[2].trim() : '') ?? 255;

    final bool? apply = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setDialogState) {
          Widget channel(String label, int value, ValueChanged<int> onChanged) {
            return R3Slider(
              theme: t,
              label: label,
              value: value.toDouble(),
              min: 0,
              max: 255,
              onChanged: (v) => setDialogState(() => onChanged(v.round())),
            );
          }

          return AlertDialog(
            title: Text('EDIT COLOR',
                style: t.value.copyWith(letterSpacing: sc(2))),
            content: SizedBox(
              width: sc(300),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: double.infinity,
                    height: sc(60),
                    decoration: BoxDecoration(
                      color: Color.fromARGB(255, r, g, b),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: R3Theme.hairline),
                    ),
                  ),
                  SizedBox(height: sc(6)),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text('$r,$g,$b', style: t.fine),
                  ),
                  SizedBox(height: sc(10)),
                  channel('R', r, (v) => r = v),
                  channel('G', g, (v) => g = v),
                  channel('B', b, (v) => b = v),
                ],
              ),
            ),
            actions: [
              R3Button('Cancel',
                  theme: t,
                  compact: true,
                  onPressed: () => Navigator.pop(ctx, false)),
              R3Button('Apply',
                  theme: t,
                  compact: true,
                  kind: R3ButtonKind.primary,
                  onPressed: () => Navigator.pop(ctx, true)),
            ],
          );
        });
      },
    );

    if (apply != true) return null;
    return '$r,$g,$b';
  }

  // -------------------------------------------------------------------
  // Per-type forms
  // -------------------------------------------------------------------

  List<Widget> _buildNodeFormFields(ScriptNode node) {
    final List<Widget> f = [];

    switch (node.type) {
      // --- Text -----------------------------------------------------
      case 'TEXT':
        f.add(_fArea(node, 'Typing text', 'body', node.body,
            (v) => node.body = v,
            minLines: 6));
        if (node.prefix.isNotEmpty || node.suffix.isNotEmpty) {
          f.add(_hint('Surrounding blank lines are held outside this field, '
              'so the typed layout stays exactly as written.'));
        }
        break;

      // --- Core typing ---------------------------------------------
      case 'WIPE':
        f.add(_hint('Clears the terminal instantly and resets the cursor to '
            'the top left. Also clears any stacked PHOTO layers.'));
        break;

      case 'PAUSE':
        f.add(_fInt(node, 'Hold', 'frames',
            min: 0, max: 600, def: '30', suffix: 'fr'));
        f.add(_hint('30 frames is one second at the engine-locked 30fps.'));
        break;

      case 'SPEED':
        f.addAll(_speedForm(node));
        break;

      // --- Formatting ------------------------------------------------
      case 'SIZE':
        f.addAll(_defaultableForm(node, 'size', 'Font size', 8, 200, '48',
            'Returns to the size set in the main menu TYPE panel.'));
        break;

      case 'LEAD':
        f.addAll(_defaultableForm(node, 'lead', 'Leading', 0, 300, '60',
            'Returns to the leading set in the main menu TYPE panel.'));
        break;

      case 'VPAD':
        f.add(_fInt(node, 'Vertical pad', 'vpad',
            min: 0, max: 800, def: '40', suffix: 'px'));
        f.add(_hint(
            'Inserts empty vertical space without typing blank lines.'));
        break;

      case 'ALIGN':
        f.add(_fEnum(
            node, 'Align', 'align', ['LEFT', 'CENTER', 'RIGHT'], 'LEFT'));
        break;

      // --- Color and effects -----------------------------------------
      case 'COLOR':
        f.add(_fEnum(
            node,
            'Pen',
            'color',
            ['RED', 'GREEN', 'BLUE', 'YELLOW', 'WHITE', 'BLACK', 'NORMAL'],
            'NORMAL'));
        f.add(_hint(
            'NORMAL returns to the phosphor color set in the main menu.'));
        break;

      case 'FLASH':
        f.add(_fEnum(
            node,
            'Flash',
            'flash',
            ['INVERT', 'SPIKE', 'RED', 'GREEN', 'YELLOW', 'WAVE', 'OFF'],
            'OFF'));
        break;

      case 'SCRAMBLE':
        f.add(_fEnum(node, 'Scramble', 'scramble', ['on', 'off'], 'on'));
        f.add(_hint(
            'Seeded, so every run and every bake scrambles identically.'));
        break;

      case 'INVERT':
        f.add(_fEnum(node, 'Invert', 'invert', ['on', 'off'], 'on'));
        f.add(_hint('Swaps the text foreground and background colors.'));
        break;

      case 'REDACT':
        f.add(
            _fEnum(node, 'Marker', 'redact', ['REDACT', '/REDACT'], 'REDACT'));
        f.add(_hint('Open and close markers wrap the text they hide.'));
        break;

      // --- Progress bar ----------------------------------------------
      case 'BAR':
        f.add(_fInt(node, 'Width', 'width',
            min: 1, max: 120, def: '20', suffix: 'ch'));
        f.add(_fInt(node, 'Fill time', 'frames',
            min: 1, max: 900, def: '60', suffix: 'fr'));
        f.add(_fText(node, 'Fill char', 'fill', fallback: '\u2588'));
        f.add(_fText(node, 'Empty char', 'empty', fallback: ' '));
        f.add(_fText(node, 'Brackets', 'brackets', fallback: '[]'));
        f.add(_hint('Set brackets to NONE for a bare bar.'));
        break;

      // --- Regions ----------------------------------------------------
      case 'REGION':
        f.add(_fText(node, 'Region id', 'id', fallback: 'region'));
        f.add(_hint('Close the span with a /REGION node.'));
        break;

      case 'REGION_END':
        f.add(_hint('Closes the most recent REGION span.'));
        break;

      case 'SELECT':
        f.add(_fText(node, 'Region id', 'id',
            fallback: 'NONE', hintText: 'NONE clears all highlights'));
        f.add(_fRgb(node, 'Highlight color', 'rgb',
            def: '0,255,0', optional: true, clearedLabel: 'ENGINE DEFAULT'));
        break;

      // --- Config ------------------------------------------------------
      case 'CONFIG':
        f.addAll(_configForm(node));
        break;

      // --- Desktop presentations ---------------------------------------
      case 'GALLERY':
        f.add(_fAsset(node, 'Image folder', 'folder', AssetSlot.imageFolder));
        f.add(_fInt(node, 'Per image', 'hold',
            min: 1, max: 600, def: '90', suffix: 'fr'));
        f.add(_fEnum(node, 'Transition', 'transition',
            ['CUT', 'FADE', 'FLIP'], 'CUT'));
        f.add(_fText(node, 'Window title', 'title',
            hintText: 'Image Viewer'));
        break;

      case 'VIDEO':
        f.add(
            _fAsset(node, 'Sequence folder', 'folder', AssetSlot.imageFolder));
        f.add(_fEnum(node, 'Source FPS', 'fps',
            ['23.976', '24', '25', '29.97', '30', '50', '59.94', '60'], '30'));
        f.add(_fInt(node, 'First-frame hold', 'hold',
            min: 0, max: 600, def: '60', suffix: 'fr'));
        f.add(_fText(node, 'Video name', 'title', hintText: 'file.mp4'));
        f.add(_hint('R3nder stays locked to 30 fps. Source FPS controls how '
            'the extracted sequence is sampled; the last frame then holds '
            'for 30 frames before closing.'));
        break;

      case 'BROWSER':
        f.add(_fAsset(node, 'Capture folder', 'folder', AssetSlot.imageFolder));
        f.add(_fInt(node, 'Per page', 'hold',
            min: 1, max: 900, def: '150', suffix: 'fr'));
        f.add(_fText(node, 'Window title', 'title',
            hintText: 'Web Browser'));
        f.add(_fEnum(node, 'Page fit', 'scroll',
            kBrowserScrollSegments, 'SCROLL'));
        f.add(_hint(_browserScrollHint(node.param('scroll', 'SCROLL'))));
        f.add(_hint(
            'The address and the page title are not in the script: a URL '
            'cannot survive a grammar that splits on ":". They live per '
            'image in $kFolderCaptionFile beside the captures, alongside the '
            'captions, and are authored by clicking a thumbnail above.'));
        break;

      case 'APP':
        f.addAll(_appForm(node));
        break;

      case 'CARD':
        f.add(_fAsset(node, 'Cover image', 'image', AssetSlot.rasterFile));
        f.add(_fInt(node, 'Hold open', 'hold',
            min: 0, max: 1200, def: '240', suffix: 'fr'));
        f.add(_fRgb(node, 'Panel color', 'rgb', def: '30,30,38'));
        f.add(_fText(node, 'Heading', 'heading'));
        f.add(_fArea(node, 'Body copy', 'body', node.body,
            (v) => node.body = v));
        f.add(_hint('Body copy renders on the card and never types in the '
            'terminal. Text contrast follows the panel luminance.'));
        break;

      case 'DOSSIER':
        f.add(_fAsset(node, 'Gallery folder', 'folder', AssetSlot.imageFolder));
        f.add(_fAsset(node, 'Card image', 'image', AssetSlot.rasterFile));
        f.add(_fInt(node, 'Side gallery hold', 'hold1',
            min: 0, max: 900, def: '120', suffix: 'fr'));
        f.add(_fDossierCenterMode(node));
        if (node.param('centerMode', 'GRID') != 'SIDE_ONLY') {
          f.add(_fInt(node, 'Center hold', 'hold2',
              min: 0, max: 900, def: '120', suffix: 'fr'));
          if (node.param('centerMode', 'GRID') == 'MOSAIC') {
            f.add(_hint('Center hold applies to each 3-image mosaic page.'));
          }
        }
        f.add(_fInt(node, 'Card lead', 'cardLead',
            min: 0, max: 600, def: '0', suffix: 'fr'));
        f.add(_fRgb(node, 'Panel color', 'rgb', def: '30,30,38'));
        f.add(_fText(node, 'Heading', 'heading'));
        f.add(_fArea(node, 'Body copy', 'body', node.body,
            (v) => node.body = v));
        f.add(_hint('Card lead holds the card alone before the gallery opens '
            'beside it. After side view chooses whether the gallery expands '
            'to the center as a grid, becomes a mosaic, or exits with the '
            'card.'));
        break;

      case 'TIMELINE':
        f.addAll(_timelineForm(node));
        break;

      // --- Stencils -----------------------------------------------------
      case 'SVG':
        f.add(_fAsset(node, 'Stencil file', 'file', AssetSlot.svgFile));
        f.add(_fInt(node, 'Hold', 'hold',
            min: 1, max: 900, def: '60', suffix: 'fr'));
        f.add(_fRgb(node, 'Fill override', 'rgb',
            def: '0,255,0', optional: true, clearedLabel: 'INHERIT PEN'));
        break;

      case 'SVGFLASH':
        f.add(_fAsset(node, 'Stencil folder', 'folder', AssetSlot.svgFolder));
        f.add(_fInt(node, 'Per logo', 'framesPer',
            min: 1, max: 60, def: '4', suffix: 'fr'));
        f.add(_fInt(node, 'Cycles', 'cycles', min: 1, max: 30, def: '3'));
        f.add(_fRgb(node, 'Fill override', 'rgb',
            def: '0,255,0', optional: true, clearedLabel: 'INHERIT PEN'));
        break;

      case 'PHOTO':
        f.addAll(_photoForm(node));
        break;

      case 'IMG':
        f.add(_fAsset(node, 'Tile file', 'file', AssetSlot.rasterFile,
            maxDimension: 512));
        f.add(_fInt(node, 'Repeats', 'repeat', min: 1, max: 200, def: '1'));
        f.add(_fEnum(node, 'Channel', 'channel', ['R', 'G', 'B'], 'R'));
        // The label follows the repeat count, because the parameter does.
        // Calling it "Per copy" on a single tile would name a thing that
        // is not happening.
        final bool imgTiled =
            (int.tryParse(node.param('repeat', '1')) ?? 1) > 1;
        f.add(_fInt(node, imgTiled ? 'Per copy' : 'Scan time', 'framesPer',
            min: 1, max: 60, def: '2', suffix: 'fr'));
        f.add(_hint(imgTiled
            ? 'Frames between each copy revealing, left to right.'
            : 'One tile has nothing to stagger, so this is how long a '
                'scanline takes to cross it, top to bottom. Same frame '
                'budget either way.'));
        f.add(_fInt(node, 'Release gate', 'release',
            min: 0, max: 100, def: '100', suffix: '%'));
        f.add(_hint('Release below 100 opens the typing gate early, so the '
            'next tag runs while this band keeps drawing. Tiles cap at '
            '512 by 512 and must be authored 1-bit.'));
        break;

      case 'SPRITE':
        f.add(_fAsset(node, 'Sprite file', 'file', AssetSlot.spriteFile));
        f.add(_fInt(node, 'Per frame', 'hold',
            min: 1, max: 120, def: '30', suffix: 'fr'));
        f.add(_hint('Frames are separated by a [FRAME] line inside the '
            'sprite text file.'));
        break;

      case 'SPRITE_OFF':
        f.add(_fAsset(node, 'Sprite file', 'file', AssetSlot.spriteFile));
        f.add(_hint('Freezes that sprite on its current frame.'));
        break;

      // --- Macro menus -------------------------------------------------
      case 'DEF_MENU':
        f.addAll(_defMenuForm(node));
        break;

      case 'CALL':
        f.addAll(_callForm(node));
        break;

      case 'MENU_STATE':
        f.addAll(_menuStateForm(node));
        break;

      case 'MACRO_CFG':
        f.addAll(_macroCfgForm(node));
        break;

      // --- Anything the form does not model -----------------------------
      default:
        f.add(_fArea(node, 'Raw markup', 'raw', node.rawText,
            (v) => node.rawText = v,
            minLines: 5));
        f.add(_hint('Edited as literal markup. Comments, menu definitions, '
            'and macro config lines live here.'));
        break;
    }

    return f;
  }

  /// APP's layout sits positionally behind the title, so the control is
  /// gated the same way TIMELINE's stage is. The hold label changes with the
  /// mode because its meaning changes: once per window in GRID, once per
  /// page in MOSAIC.
  List<Widget> _appForm(ScriptNode node) {
    final List<Widget> f = [];

    final bool hasTitle = node.param('title').trim().isNotEmpty;
    final String layout = node.param('layout', 'GRID').toUpperCase();
    final bool isMosaic = layout.startsWith('MOSAIC');
    final bool isFull = layout == 'MOSAIC_FULL';

    f.add(_fAsset(node, 'Image folder', 'folder', AssetSlot.imageFolder));
    f.add(_fInt(node, isMosaic ? 'Hold per page' : 'Hold after cascade',
        'hold',
        min: 0, max: 900, def: '90', suffix: 'fr'));
    f.add(_fText(node, 'Window title', 'title', hintText: 'App'));

    f.add(_gate(
      hasTitle,
      'A layout requires a title',
      _fEnum(node, 'Layout', 'layout',
          const ['GRID', 'MOSAIC', 'MOSAIC_FULL'], 'GRID'),
    ));

    if (isMosaic) {
      f.add(_hint('Up to three unequal panes per page, hero geometry '
          'alternating sides, '
          'panning horizontally for the rest. Nine one-image panes make three '
          'pages by default; grouping images into shared panes can reduce '
          'that page count. The hold above '
          'applies to each page.'));
      f.add(_hint(isFull
          ? 'MOSAIC_FULL: the window maximizes out to the whole frame once '
              'open, then restores to its desktop rect on the way out.'
          : 'MOSAIC: stays a chromed window on the desktop. Use '
              'MOSAIC_FULL to have it fill the frame.'));

      f.add(_fText(node, 'Page plan', 'pages', hintText: '1,3,2'));
      f.add(_appPagePlanReadout(node));
      f.add(_hint('Panes per page, comma separated, ending a page early '
          'like a clear. Blank chunks three at a time. Each page costs a '
          'hold plus a pan, so this changes how long the tag runs, which '
          'is why it lives in the script rather than beside the images. '
          'Image ORDER lives in the folder, since reordering changes no '
          'timing.'));
      f.add(_fText(node, 'Pane structure', 'panes',
          hintText: '3@2-LR;1;2@2-RL'));
      f.add(_hint('Optional MOSAIC pane grouping + Pane Life selection. '
          'Tokens are IMAGES[@HERO][-DIRECTION][-FIT], separated by '
          'semicolons. '
          '3-LR groups three images but selects no motion; 3@2-LR selects '
          'image 2 as that pane\'s Pane Life hero. ★ is a real toggle: click '
          'again to remove @HERO. FIT on the pane\'s first thumbnail cycles '
          'the scaling rule: FILL crops to fill, FIT scales to the vertical '
          'edge (letterboxing a source taller than the pane rather than '
          'losing its top and bottom), FITW scales to the horizontal edge '
          'for a panorama in a tall pane. Independent of Pane Life in both '
          'directions. A +FRAMES tail holds an image longer and is the one '
          'pane fact that makes the piece run longer. Blank keeps one image '
          'per pane with no Pane Life selection.'));
    } else {
      f.add(_hint('Up to nine tiles, all the same size. The grid shape '
          'follows the image count.'));
    }

    return f;
  }

  /// Writes a page plan back to the tag from the contact sheet.
  ///
  /// Always writes an EXPLICIT plan, even when the strip was showing the
  /// implicit default chunking. Once you have moved a break by hand the
  /// arrangement is authored, and leaving it implicit would mean the next
  /// image you add silently re-flows the pages you just set.
  ///
  /// An empty plan clears the parameter rather than writing '', so the tag
  /// goes back to its shortest legal form instead of carrying a dangling
  /// separator.
  void _setPagePlan(ScriptNode node, List<int> plan) {
    node.set('pages', plan.isEmpty ? '' : plan.join(','));
    _notifyChanged();
  }

  /// How many images the contact sheet is showing for [node].
  ///
  /// Taken from the last selection when there is one, because that is the
  /// only place the real folder count is known here: the sheet reads the
  /// directory, this panel does not. Falls back to the declared count,
  /// which is what the script claims rather than what is on disk, and is
  /// only used to size a display array.
  int _paneCountFor(ScriptNode node) {
    if (_profileTotal > 0) return _profileTotal;
    return _declaredFolderCount(node.param('folder')) ?? 0;
  }

  /// Hold extension per load position, for the contact sheet badges.
  List<int> _holdsByImage(ScriptNode node, int count) {
    if (count <= 0) return const [];
    final List<AppPaneSpec> panes = resolveAppPanePlan(
        count, parseAppPanePlan(node.param('panes')));
    final List<int> out = List<int>.filled(count, 0);
    int at = 0;
    for (final AppPaneSpec pane in panes) {
      for (int k = 0; k < pane.imageCount && at < count; k++, at++) {
        out[at] = pane.holdAt(k);
      }
    }
    return out;
  }

  /// Which pane owns load position [index], and where inside it.
  ///
  /// Returns null when the plan cannot place it, which happens while the
  /// folder count and the authored plan disagree mid-edit.
  ({int pane, int within})? _paneAddressOf(
      ScriptNode node, int index, int count) {
    if (index < 0 || count <= 0) return null;
    final List<AppPaneSpec> panes = resolveAppPanePlan(
        count, parseAppPanePlan(node.param('panes')));
    int at = 0;
    for (int p = 0; p < panes.length; p++) {
      final int end = at + panes[p].imageCount;
      if (index < end) return (pane: p, within: index - at);
      at = end;
    }
    return null;
  }

  /// Writes a hold extension onto the pane that owns this image.
  ///
  /// Goes through the pane plan and the APP tag, NOT the caption sidecar.
  /// A hold is composition: it changes how long the piece runs, and it
  /// belongs to the cut rather than to the photograph. The same scan held
  /// two seconds in one film is held four in another.
  void _setHoldFrames(ScriptNode node, int index, int count, int frames) {
    final addr = _paneAddressOf(node, index, count);
    if (addr == null) return;
    final List<AppPaneSpec> panes = resolveAppPanePlan(
        count, parseAppPanePlan(node.param('panes')));
    if (addr.pane >= panes.length) return;
    panes[addr.pane] = panes[addr.pane].withHoldAt(addr.within, frames);
    _setPanePlan(node, panes);
  }

  /// Captions for [dir], read once and then held.
  Map<String, ImageCaption> _captionsFor(String dir) {
    if (_captionCacheDir != dir) {
      _captionCacheDir = dir;
      _captionCacheForDir = readFolderCaptions(dir);
    }
    return _captionCacheForDir;
  }

  /// Writes one image's record back to the sidecar.
  ///
  /// Writes on every keystroke, like every other field in this panel. The
  /// sidecar is a few hundred bytes and the alternative is a save button,
  /// which is a thing to forget. A failed write is surfaced rather than
  /// swallowed: a caption that looked saved and was not is the one failure
  /// this feature cannot afford, because you will not find out until the
  /// bake.
  /// What the chosen page fit will actually do, in the panel, at the moment
  /// the choice is made.
  ///
  /// Worth the words because two of the three answers are "nothing moves",
  /// and a scroll that correctly declined to run looks exactly like a scroll
  /// that is broken. Naming the frame-neutrality rule here is the only place
  /// an author meets it before a bake.
  /// Hint for the scroll segment, which carries two facts.
  ///
  /// Split before switching rather than adding six cases, because the two
  /// halves say unrelated things: one is how the capture meets the viewport,
  /// the other is how big the window is. Six cases would have written the
  /// same sentence about FULL three times.
  String _browserScrollHint(String segment) {
    final seg = parseBrowserScrollSegment(segment);

    String fit;
    switch (seg.scroll) {
      case BrowserScroll.top:
        fit = 'TOP fits the capture to the window width and holds above '
            'the fold. Nothing moves.';
        break;
      case BrowserScroll.fit:
        fit = 'FIT contains the whole capture in the window, letterboxed '
            'against the page plate. For a short page or a phone capture, '
            'where a scroll would have nowhere to go. Nothing moves.';
        break;
      case BrowserScroll.scroll:
        fit = 'SCROLL fits the width and pans down through whatever is '
            'below the fold, inside this hold. The travel divides the hold '
            'rather than extending it, so a capture twenty screens tall runs '
            'exactly as long as one that fits. A hold too short to travel '
            'legibly plays static at the top rather than scrolling faster.';
        break;
    }

    if (!seg.maximizes) return fit;

    return '$fit\n\n_FULL maximizes the window out to the whole frame once '
        'it has opened, and restores to its desktop rect on the way out. '
        'Unlike MOSAIC_FULL the chrome stays: a browser without its tab '
        'strip and address bar is a photograph of a webpage. It gives up '
        'the shadow, the rounded corners, and the desktop around it. Under '
        'APPSWITCH:SLIDE a full window will only absorb another full one, '
        'since there is no animation between two sizes inside a navigation.';
  }

  void _setCaption(String dir, String name, ImageCaption record) {
    final Map<String, ImageCaption> all =
        Map<String, ImageCaption>.from(_captionsFor(dir));
    all[name] = record;
    final bool ok = writeFolderCaptions(dir, all);
    setState(() {
      _captionCacheForDir = all;
      _captionCacheDir = dir;
    });
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('COULD NOT WRITE $kFolderCaptionFile')),
      );
    }
    // The band is geometry, so the preview has to re-simulate to show it.
    _notifyChanged();
  }

  /// Per-image profile, opened by clicking a thumbnail in the contact
  /// sheet.
  ///
  /// Lives here rather than in the sheet because the sheet is out of room:
  /// four corners of every thumbnail are already spoken for by position,
  /// ★, LR/RL, FIT, and the recycle X. A caption is also not a toggle, and
  /// a text field the width of a 54px thumbnail is not a text field.
  Widget _imageProfile(String dir, String name,
      Map<String, ImageCaption> captions, ScriptNode node) {
    final t = widget.theme;
    final ImageCaption rec = captions[name] ?? ImageCaption.none;
    final String key = '$dir|$name';

    final bool isBrowser = node.type == 'BROWSER';

    // Pane arithmetic is an APP MOSAIC question. A browser has pages rather
    // than panes, so asking for a pane address on one would resolve against
    // a pane plan that does not exist and hand back a hold slider for a
    // token nothing will ever write.
    final int count = isBrowser ? 0 : _paneCountFor(node);
    final addr = isBrowser ? null : _paneAddressOf(node, _profileIndex, count);
    final List<AppPaneSpec> panes = isBrowser
        ? const []
        : resolveAppPanePlan(count, parseAppPanePlan(node.param('panes')));
    final int hold = (addr != null && addr.pane < panes.length)
        ? panes[addr.pane].holdAt(addr.within)
        : 0;

    return Container(
      margin: EdgeInsets.only(top: sc(10)),
      padding: EdgeInsets.all(sc(10)),
      decoration: BoxDecoration(
        color: R3Theme.panelHi,
        borderRadius: BorderRadius.circular(sc(4)),
        border: Border.all(color: t.accentDim),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(name.toUpperCase(),
                    style: t.micro.copyWith(color: t.accent),
                    overflow: TextOverflow.ellipsis),
              ),
              InkWell(
                onTap: () => setState(() => _profileTarget = null),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: sc(4)),
                  child: Icon(Icons.close,
                      size: sc(14), color: R3Theme.textDim),
                ),
              ),
            ],
          ),
          SizedBox(height: sc(8)),
          if (isBrowser) ...[
            R3MicroLabel('ADDRESS', theme: t),
            SizedBox(height: sc(6)),
            TextField(
              controller: _ctl('$key|url', rec.url),
              style: t.value,
              decoration: const InputDecoration(
                  isDense: true, hintText: 'https://example.org/page'),
              onChanged: (v) => _setCaption(dir, name, rec.copyWith(url: v)),
            ),
            SizedBox(height: sc(10)),
            R3MicroLabel('PAGE TITLE', theme: t),
            SizedBox(height: sc(6)),
            TextField(
              controller: _ctl('$key|pageTitle', rec.pageTitle),
              style: t.value,
              decoration: InputDecoration(
                  isDense: true,
                  hintText: rec.displayTabTitle.isEmpty
                      ? 'Shown on the tab'
                      : rec.displayTabTitle),
              onChanged: (v) =>
                  _setCaption(dir, name, rec.copyWith(pageTitle: v)),
            ),
            SizedBox(height: sc(8)),
            Text(
              'Both live in $kFolderCaptionFile beside the captures, not in '
              'the script: a URL cannot survive a grammar that splits on '
              '":". An empty page title falls back to the host out of the '
              'address, which is what a browser does anyway. Neither is '
              'affected by HAS CAPTION below: that decides whether a MOSAIC '
              'band draws, and an address bar is chrome rather than a label.',
              style: t.fine.copyWith(color: R3Theme.textDim, height: 1.4),
            ),
            Padding(
              padding: EdgeInsets.symmetric(vertical: sc(10)),
              child: Container(height: 1, color: t.accentFaint),
            ),
          ],
          // The checkbox is authored separately from the text, so
          // unchecking a caption keeps the words. Dropping a label for one
          // cut must not destroy the research that produced it.
          InkWell(
            onTap: () =>
                _setCaption(dir, name, rec.copyWith(enabled: !rec.enabled)),
            child: Row(
              children: [
                Icon(
                  rec.enabled
                      ? Icons.check_box
                      : Icons.check_box_outline_blank,
                  size: sc(16),
                  color: rec.enabled ? t.accent : R3Theme.textDim,
                ),
                SizedBox(width: sc(6)),
                Text('HAS CAPTION', style: t.micro),
              ],
            ),
          ),
          SizedBox(height: sc(10)),
          R3MicroLabel('CAPTION', theme: t),
          SizedBox(height: sc(6)),
          TextField(
            controller: _ctl('$key|caption', rec.caption),
            style: t.value,
            maxLines: null,
            minLines: 2,
            decoration: const InputDecoration(isDense: true),
            onChanged: (v) =>
                _setCaption(dir, name, rec.copyWith(caption: v)),
          ),
          SizedBox(height: sc(10)),
          R3MicroLabel('CREDIT', theme: t),
          SizedBox(height: sc(6)),
          TextField(
            controller: _ctl('$key|credit', rec.credit),
            style: t.value,
            decoration: const InputDecoration(
                isDense: true, hintText: 'Collection, box, accession'),
            onChanged: (v) => _setCaption(dir, name, rec.copyWith(credit: v)),
          ),
          SizedBox(height: sc(8)),
          Text(
            'Stored in $kFolderCaptionFile beside the images, not in the '
            'script. The caption travels with the photograph.',
            style: t.fine.copyWith(color: R3Theme.textDim, height: 1.4),
          ),
          if (addr != null) ...[
            Padding(
              padding: EdgeInsets.symmetric(vertical: sc(10)),
              child: Container(height: 1, color: t.accentFaint),
            ),
            R3MicroLabel('HOLD LONGER', theme: t),
            SizedBox(height: sc(6)),
            R3Slider(
              theme: t,
              label: 'Extra frames',
              value: hold.toDouble(),
              min: 0,
              max: 600,
              format: (v) => v <= 0 ? 'none' : '+${v.toStringAsFixed(0)} fr',
              onChanged: (v) => _setHoldFrames(
                  node, _profileIndex, count, v.round()),
            ),
            SizedBox(height: sc(8)),
            Text(
              'Unlike the caption, this is script state: it goes in the APP '
              'pane token and it MAKES THE PIECE LONGER. Every scene after '
              'this page moves by the frames you add. It applies whether or '
              'not Pane Life is on.',
              style: t.fine.copyWith(color: R3Theme.textDim, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }

  /// Writes authored MOSAIC pane structure from the contact sheet.
  ///
  /// Empty clears back to one-image-per-pane with no Pane Life selection.
  /// The same collapse happens when the explicit plan is only unselected
  /// one-image LR panes, so toggling the final ★ off removes the pane segment
  /// instead of leaving script noise like `1;1;1`. Real grouping, direction,
  /// or fit remains authored even when no hero is selected.
  ///
  /// Fit has to be in this test. A plan of all `1-FIT` panes is one image
  /// per pane, unselected, and left to right, so without the fit clause it
  /// reads as the default and the collapse throws the fit away the moment
  /// it is set.
  void _setPanePlan(ScriptNode node, List<AppPaneSpec> plan) {
    final bool implicit = plan.isEmpty || plan.every((p) =>
        p.imageCount == 1 &&
        p.heroIndex == null &&
        p.direction == PaneDirection.leftToRight &&
        p.fit == PaneFit.fill);
    node.set('panes', implicit ? '' : formatAppPanePlan(plan));
    _notifyChanged();
  }

  /// Shows what the page plan will actually do against the folder as it
  /// stands, resolved through the same rules the engine uses.
  ///
  /// Worth the space because the plan is advisory in both directions: it
  /// chunks on when it runs short and stops when it runs long, so what you
  /// typed and what plays are often not the same list. Reading that off the
  /// tag alone means doing the arithmetic in your head against a folder you
  /// cannot see.
  Widget _appPagePlanReadout(ScriptNode node) {
    final t = widget.theme;
    final String folder = node.param('folder').trim();
    if (folder.isEmpty) return const SizedBox.shrink();

    final int count = listFolderAssets(
      _slotAbsolute(AssetSlot.imageFolder, folder),
      ThumbKind.raster,
    ).length;
    if (count == 0) return const SizedBox.shrink();

    final int capped = count > 9 ? 9 : count;
    final List<AppPaneSpec> paneSpecs =
        resolveAppPanePlan(capped, parseAppPanePlan(node.param('panes')));
    final List<int> plan = parsePagePlan(node.param('pages'));
    final List<int> pages = resolvePagePlan(paneSpecs.length, plan);

    return _wrap(Row(
      children: [
        R3MicroLabel('PLAYS AS', theme: t),
        SizedBox(width: sc(8)),
        Text(
          '${pages.join(' + ')}  '
          '(${pages.length} page${pages.length == 1 ? '' : 's'}, '
          '${paneSpecs.length} pane${paneSpecs.length == 1 ? '' : 's'}, '
          '$capped image${capped == 1 ? '' : 's'})',
          style: t.fine,
        ),
      ],
    ));
  }

  // -------------------------------------------------------------------
  // Macro menu forms
  //
  // These four tags reference each other by name, and until now the only
  // way to keep them consistent was to remember what you typed twenty
  // lines earlier. The forms read the rest of the document instead: CALL
  // and MENU_STATE pick from the menus actually defined, and MACRO_CFG
  // resolves its instance back to a menu to offer that menu's real items.
  // -------------------------------------------------------------------

  /// Every menu defined anywhere in the document, as id to item list.
  Map<String, List<({String id, String text})>> get _definedMenus {
    final Map<String, List<({String id, String text})>> out = {};
    for (final n in _nodes) {
      if (n.type != 'DEF_MENU') continue;
      out[n.param('id')] = _parseMenuItems(n.body);
    }
    return out;
  }

  /// Instance id to the menu it belongs to, taken from MENU_STATE nodes.
  /// MACRO_CFG names an instance but not a menu, so this is the only way
  /// to know which items a given config row is choosing between.
  Map<String, String> get _instanceMenus {
    final Map<String, String> out = {};
    for (final n in _nodes) {
      if (n.type != 'MENU_STATE') continue;
      final String inst = n.param('instance');
      if (inst.isNotEmpty) out[inst] = n.param('menu');
    }
    return out;
  }

  static List<({String id, String text})> _parseMenuItems(String body) {
    return _menuItemRegex
        .allMatches(body)
        .map((m) => (id: m.group(1)!, text: m.group(2) ?? ''))
        .toList();
  }

  /// Rebuilds a menu body from its items. One item per line, which is how
  /// they are written by hand and how the dashboard reads them back.
  static String _buildMenuBody(List<({String id, String text})> items) {
    if (items.isEmpty) return '\n';
    final StringBuffer b = StringBuffer('\n');
    for (final it in items) {
      b.write('[ITEM:${it.id}]${it.text}[/ITEM]\n');
    }
    return b.toString();
  }

  List<Widget> _defMenuForm(ScriptNode node) {
    final List<Widget> f = [];
    final items = _parseMenuItems(node.body);

    f.add(_fText(node, 'Menu id', 'id', fallback: 'menu'));

    void commit(List<({String id, String text})> next) {
      node.body = _buildMenuBody(next);
      node.dirty = true;
      _notifyChanged();
    }

    f.add(_wrap(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            R3MicroLabel('Items', theme: widget.theme),
            const Spacer(),
            _iconAction(Icons.add, 'Add item', () {
              commit([
                ...items,
                (id: 'opt${items.length + 1}', text: '  NEW ITEM'),
              ]);
            }),
          ],
        ),
        SizedBox(height: sc(6)),
        if (items.isEmpty)
          Text('NO ITEMS YET', style: widget.theme.micro)
        else
          for (int i = 0; i < items.length; i++)
            Padding(
              padding: EdgeInsets.only(bottom: sc(8)),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: sc(84),
                    child: TextField(
                      controller: _ctl(
                          '${node.id}|item_id_$i', items[i].id),
                      style: widget.theme.fine,
                      decoration: const InputDecoration(
                          isDense: true, hintText: 'id'),
                      onChanged: (v) {
                        final next = [...items];
                        next[i] = (id: v, text: items[i].text);
                        commit(next);
                      },
                    ),
                  ),
                  SizedBox(width: sc(6)),
                  Expanded(
                    child: TextField(
                      controller: _ctl(
                          '${node.id}|item_tx_$i', items[i].text),
                      style: widget.theme.value,
                      decoration: const InputDecoration(
                          isDense: true, hintText: 'label'),
                      onChanged: (v) {
                        final next = [...items];
                        next[i] = (id: items[i].id, text: v);
                        commit(next);
                      },
                    ),
                  ),
                  _iconAction(Icons.arrow_upward, 'Move up',
                      i == 0
                          ? null
                          : () {
                              final next = [...items];
                              final t = next.removeAt(i);
                              next.insert(i - 1, t);
                              commit(next);
                            }),
                  _iconAction(Icons.close, 'Remove item', () {
                    final next = [...items]..removeAt(i);
                    commit(next);
                  }, danger: true),
                ],
              ),
            ),
      ],
    )));

    f.add(_hint('Leading spaces in a label are preserved, which is how the '
        'menu gets its indent. Line breaks inside a label are stripped by '
        'the parser, so keep each item on one line.'));

    if (items.isNotEmpty) {
      final String id = node.param('id');
      final bool called = _nodes.any((n) => n.type == 'CALL' && n.param('menu') == id);
      if (!called) {
        f.add(_hint('This menu is defined but never drawn. Add a CALL node '
            'with menu id "$id" to put it on screen.', danger: true));
      }
    }

    return f;
  }

  List<Widget> _callForm(ScriptNode node) {
    final List<Widget> f = [];
    final menus = _definedMenus.keys.toList()..sort();
    final String current = node.param('menu');
    final bool resolves = current.isEmpty || menus.contains(current);

    f.add(_wrap(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            R3MicroLabel('Menu', theme: widget.theme),
            SizedBox(width: sc(8)),
            if (!resolves)
              const R3Tally(state: R3TallyState.error, count: 'UNDEFINED'),
          ],
        ),
        SizedBox(height: sc(6)),
        if (menus.isEmpty)
          Text('NO MENUS DEFINED IN THIS SCRIPT', style: widget.theme.micro)
        else
          _bareDropdown(
            value: current,
            items: [
              if (current.isNotEmpty && !menus.contains(current)) current,
              ...menus,
            ],
            itemLabel: (s) => s,
            onChanged: (v) {
              if (v == null) return;
              node.set('menu', v);
              _notifyChanged();
            },
          ),
      ],
    )));

    f.add(_hint('Draws the menu once at this point in the script, wrapped '
        'in REGION tags so a later MENU_STATE can highlight a row.'));
    return f;
  }

  List<Widget> _menuStateForm(ScriptNode node) {
    final List<Widget> f = [];
    final defined = _definedMenus;
    final menus = defined.keys.toList()..sort();
    final String current = node.param('menu');

    f.add(_wrap(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            R3MicroLabel('Menu', theme: widget.theme),
            SizedBox(width: sc(8)),
            if (current.isNotEmpty && !menus.contains(current))
              const R3Tally(state: R3TallyState.error, count: 'UNDEFINED'),
          ],
        ),
        SizedBox(height: sc(6)),
        if (menus.isEmpty)
          Text('NO MENUS DEFINED IN THIS SCRIPT', style: widget.theme.micro)
        else
          _bareDropdown(
            value: current,
            items: [
              if (current.isNotEmpty && !menus.contains(current)) current,
              ...menus,
            ],
            itemLabel: (s) => s,
            onChanged: (v) {
              if (v == null) return;
              node.set('menu', v);
              _notifyChanged();
            },
          ),
      ],
    )));

    f.add(_fText(node, 'Instance id', 'instance',
        hintText: 'unique per highlight step'));

    f.add(_hint('Each instance is a separate highlight step with its own '
        'color and blink settings. Reusing an id reuses those settings.'));

    final items = defined[current];
    if (items != null && items.isNotEmpty) {
      f.add(_hint('Rows available: ${items.map((e) => e.id).join(', ')}'));
    }

    return f;
  }

  List<Widget> _macroCfgForm(ScriptNode node) {
    final List<Widget> f = [];

    final String instance = node.param('instance');
    final String? menuName = _instanceMenus[instance];
    final items = menuName == null ? null : _definedMenus[menuName];

    f.add(_hint('Written automatically by the Macro Menu Controller on the '
        'main menu. Editing it here works, and the controller will pick up '
        'your change the next time the template loads.'));

    f.add(_fText(node, 'Instance id', 'instance'));

    if (items == null || items.isEmpty) {
      f.add(_fText(node, 'Selected item', 'item', fallback: 'NONE'));
      f.add(_hint(menuName == null
          ? 'No MENU_STATE node references this instance, so its rows '
              'cannot be resolved. Add one to get a picker here.'
          : 'Menu "$menuName" has no items yet.'));
    } else {
      final List<String> options = ['NONE', ...items.map((e) => e.id)];
      f.add(_fEnum(node, 'Selected item', 'item', options, 'NONE'));
      f.add(_hint('From menu "$menuName".'));
    }

    f.add(_fRgb(node, 'Highlight color', 'rgb', def: '0,255,0'));

    f.add(_fEnum(node, 'Blink', 'blink', const ['0', '1', '2'], '0'));
    f.add(_hint('0 is solid, 1 and 2 blink that many times before settling.'));

    return f;
  }

  List<Widget> _speedForm(ScriptNode node) {
    final bool isMax = node.param('speed', '1').toUpperCase() == 'MAX';

    return [
      _wrap(R3Dropdown<String>(
        theme: widget.theme,
        label: 'Mode',
        value: isMax ? 'MAX' : 'CHARS',
        items: const ['CHARS', 'MAX'],
        itemLabel: (s) => s == 'MAX' ? 'MAX (instant)' : 'CHARS / FRAME',
        onChanged: (v) {
          if (v == null) return;
          node.set('speed', v == 'MAX' ? 'MAX' : '5');
          _notifyChanged();
        },
      )),
      if (isMax)
        _hint('MAX types the run instantly, with no per-frame cadence.')
      else
        _fInt(node, 'Chars/frame', 'speed', min: 1, max: 40, def: '1'),
    ];
  }

  /// SIZE and LEAD share a shape: a DEFAULT sentinel or an explicit number.
  List<Widget> _defaultableForm(ScriptNode node, String key, String label,
      double min, double max, String customDef, String defaultHint) {
    final String current = node.param(key, 'DEFAULT');
    final bool isDefault = current.toUpperCase() == 'DEFAULT';

    return [
      _wrap(R3Dropdown<String>(
        theme: widget.theme,
        label: 'Mode',
        value: isDefault ? 'DEFAULT' : 'CUSTOM',
        items: const ['DEFAULT', 'CUSTOM'],
        itemLabel: (s) => s,
        onChanged: (v) {
          if (v == null) return;
          node.set(key, v == 'DEFAULT' ? 'DEFAULT' : customDef);
          _notifyChanged();
        },
      )),
      if (isDefault)
        _hint(defaultHint)
      else
        _fInt(node, label, key, min: min, max: max, def: customDef),
    ];
  }

  /// CONFIG's value type depends on its key, so the editor for it swaps
  /// with the key and resets to a valid default when the key changes.
  /// Controls for `[CONFIG:PANELIFE:ON[:zoom[:ease]]]`.
  ///
  /// The whole setting is ONE `value` param holding a colon-joined
  /// compound, because it rides on the generic CONFIG grammar and that is
  /// what buys the feature its zero grammar cost. This form is where that
  /// cost gets paid back: real controls that parse the string apart and
  /// rebuild it, instead of asking someone to type `ON:102:INOUT` into a
  /// box labelled "Window title".
  ///
  /// Rebuilt shortest-first. `ON` alone stays `ON` rather than becoming
  /// `ON:102:INOUT`, so touching an unrelated field does not rewrite a
  /// hand-authored tag into its expanded form and pollute the diff.
  List<Widget> _paneLifeFields(ScriptNode node) {
    final List<String> parts = node
        .param('value', 'ON')
        .split(':')
        .map((s) => s.trim())
        .toList();

    String at(int i) => i < parts.length ? parts[i] : '';

    final bool on = at(0).toUpperCase() == 'ON';
    final double zoom = (double.tryParse(at(1)) ?? kPaneDefaultZoomPercent)
        .clamp(kPaneMinZoomPercent, kPaneMaxZoomPercent)
        .toDouble();
    final String ease = at(2).isEmpty ? 'INOUT' : at(2).toUpperCase();

    void write({bool? onV, double? zoomV, String? easeV}) {
      final bool o = onV ?? on;
      if (!o) {
        node.set('value', 'OFF');
        _notifyChanged();
        return;
      }
      final double z = zoomV ?? zoom;
      final String e = easeV ?? ease;

      final bool defaultZoom = (z - kPaneDefaultZoomPercent).abs() < 0.05;
      final bool defaultEase = e == 'INOUT';

      if (defaultZoom && defaultEase) {
        node.set('value', 'ON');
      } else if (defaultEase) {
        node.set('value', 'ON:${z.toStringAsFixed(0)}');
      } else {
        node.set('value', 'ON:${z.toStringAsFixed(0)}:$e');
      }
      _notifyChanged();
    }

    final t = widget.theme;

    return [
      _wrap(R3Dropdown<String>(
        theme: t,
        label: 'Panel motion',
        value: on ? 'ON' : 'OFF',
        items: const ['ON', 'OFF'],
        itemLabel: (s) => s,
        onChanged: (v) => write(onV: v == 'ON'),
      )),
      if (on)
        _wrap(R3Slider(
          theme: t,
          label: 'Push to',
          value: zoom,
          min: kPaneMinZoomPercent,
          max: kPaneMaxZoomPercent,
          format: (v) => '${v.toStringAsFixed(0)}%',
          onChanged: (v) => write(zoomV: v),
        )),
      if (on)
        _wrap(R3Dropdown<String>(
          theme: t,
          label: 'Easing',
          value: ease,
          items: const ['INOUT', 'OUT', 'IN', 'LINEAR'],
          itemLabel: (s) => s,
          onChanged: (v) => write(easeV: v ?? 'INOUT'),
        )),
      if (on && zoom <= kPaneMinZoomPercent + 0.05)
        _hint('At 100% the panels do not move. Nudge the push up to bring '
            'them to life.'),
    ];
  }

  /// Controls for `[CONFIG:CAPTION:ALIGN[:size[:font]]]`.
  ///
  /// Same shape as the Pane Life form and for the same reason: the value
  /// is only expanded as far as it needs to be, so touching alignment on a
  /// tag that never set a font does not rewrite it into the full triple
  /// and pollute the diff.
  ///
  /// The font picker is the reason the workspace now receives the loaded
  /// family list. A free-text field would have been less code and would
  /// have required you to remember, and spell, a filename minus its
  /// extension.
  List<Widget> _captionFields(ScriptNode node) {
    final CaptionConfig cfg = CaptionConfig.parse(node.param('value', 'LEFT'));
    final t = widget.theme;

    void write(CaptionConfig next) {
      node.set('value', next.toConfigValue());
      _notifyChanged();
    }

    // "Script font" is a real selection, not an absence: it means follow
    // whatever font the piece is set in, which is what a caption should do
    // unless you have a reason otherwise.
    const String kScriptFont = 'Script font';
    final List<String> fonts = [
      kScriptFont,
      ...widget.availableFonts,
    ];
    final String currentFont =
        (cfg.fontFamily != null && cfg.fontFamily!.trim().isNotEmpty)
            ? cfg.fontFamily!.trim()
            : kScriptFont;

    return [
      _wrap(R3Dropdown<String>(
        theme: t,
        label: 'Caption alignment',
        value: cfg.align == CaptionAlign.center
            ? 'CENTER'
            : (cfg.align == CaptionAlign.right ? 'RIGHT' : 'LEFT'),
        items: const ['LEFT', 'CENTER', 'RIGHT'],
        itemLabel: (s) => s,
        onChanged: (v) => write(cfg.copyWith(
            align: captionAlignFromName(v ?? 'LEFT') ?? CaptionAlign.left)),
      )),
      _wrap(R3Slider(
        theme: t,
        label: 'Caption size',
        value: cfg.sizePx,
        min: kCaptionMinSizePx,
        max: kCaptionMaxSizePx,
        format: (v) => '${v.toStringAsFixed(0)}px',
        onChanged: (v) => write(cfg.copyWith(sizePx: v)),
      )),
      _wrap(R3Dropdown<String>(
        theme: t,
        label: 'Caption font',
        value: fonts.contains(currentFont) ? currentFont : kScriptFont,
        items: fonts,
        itemLabel: (s) => s,
        onChanged: (v) => write(v == null || v == kScriptFont
            ? cfg.copyWith(clearFont: true)
            : cfg.copyWith(fontFamily: v)),
      )),
      if (cfg.fontFamily != null &&
          !widget.availableFonts.contains(cfg.fontFamily))
        _hint(
            'This script names the font "${cfg.fontFamily}", which is not in '
            'this workspace\'s fonts folder. Captions will fall back to the '
            'script font rather than failing. Drop the file into fonts/ if '
            'you want it here too.',
            danger: false),
      _hint('Applies to every MOSAIC caption band in the script. What a '
          'caption SAYS is stored per image in $kFolderCaptionFile beside '
          'the photographs; this is only how it is set.'),
    ];
  }

  List<Widget> _configForm(ScriptNode node) {
    final List<Widget> f = [];
    final String key = node.param('key', 'SIZE').toUpperCase();

    // Keys and their defaults come from config_keys.dart. They used to be
    // two hand-maintained literals here and a third in the tag palette,
    // which meant a new key needed three edits in two files with nothing
    // to catch a miss.
    f.add(_fEnum(
      node,
      'Key',
      'key',
      kConfigKeyNames,
      'SIZE',
      onPicked: (v) {
        // The value's type changes with the key, so carrying the old value
        // across would emit something the engine cannot read.
        node.set('key', v);
        node.set('value', configDefaultFor(v));
      },
    ));

    switch (key) {
      case 'FG':
        f.add(_fRgb(node, 'Foreground', 'value', def: '0,255,0'));
        f.add(_hint('Overrides the phosphor color chosen in the main menu '
            'when this template loads.'));
        break;
      case 'BG':
        f.add(_fRgb(node, 'Background', 'value', def: '10,15,10'));
        break;
      case 'SIZE':
        f.add(_fInt(node, 'Base font size', 'value',
            min: 8, max: 200, def: '48', suffix: 'px'));
        break;
      case 'DESKTOP':
        f.add(_fAsset(node, 'Wallpaper', 'value', AssetSlot.rasterFile));
        f.add(_hint('Setting a wallpaper is what unlocks the windowed OS '
            'mode for GALLERY, APP, CARD, DOSSIER, and TIMELINE.'));
        break;
      case 'PANELIFE':
        f.addAll(_paneLifeFields(node));
        f.add(_hint('PANELIFE:ON enables the capability only. It does not '
            'animate every MOSAIC pane. A pane moves only when its APP pane '
            'token contains an explicit @HERO, which the contact-sheet ★ '
            'writes and removes. LR/RL controls the walk inside a selected '
            'multi-image pane.'));
        f.add(_hint('Frame counts do not change. Only selected panes divide '
            'the hold the page already has, so one selected hero can use the '
            'whole hold while two selected panes split it. Each selected pane '
            'needs at least $kPaneMinPushFrames frames; if the available hold '
            'is shorter, the selected heroes render still and a warning says '
            'why.'));
        break;
      case 'CAPTION':
        f.addAll(_captionFields(node));
        break;
      case 'APPSWITCH':
        f.add(_wrap(R3Dropdown<String>(
          theme: widget.theme,
          label: 'Between adjacent APP tags',
          value: node.param('value', 'DESKTOP').trim().toUpperCase() == 'SLIDE'
              ? 'SLIDE'
              : 'DESKTOP',
          items: const ['DESKTOP', 'SLIDE'],
          itemLabel: (v) => v == 'SLIDE'
              ? 'SLIDE  (stay open, pan across)'
              : 'DESKTOP  (close and reopen)',
          onChanged: (v) {
            node.set('value', v ?? 'DESKTOP');
            _notifyChanged();
          },
        )));
        f.add(_hint('DESKTOP is the original behaviour: the window '
            'un-maximizes, shrinks away, and the next APP grows back out. '
            'SLIDE keeps the window and treats the next tag as more pages '
            'of it, so the transition is the same horizontal pan MOSAIC '
            'already uses between pages. SLIDE applies only between '
            'adjacent APP tags with the same layout and maximize state; '
            'anything else still opens its own window. It makes the piece '
            'SHORTER, since four window animations are replaced by one '
            'pan.'));
        break;
      default:
        f.add(_fText(node, 'Window title', 'value',
            hintText: 'operator@field-terminal: ~'));
        break;
    }
    return f;
  }

  /// TIMELINE's tail is strictly positional: a stage needs a heading, thumb
  /// width needs a stage, gap needs a thumb width, FOCUS needs a gap. Each
  /// control is gated on its predecessor so an unparseable tag cannot be
  /// produced from this form.
  List<Widget> _timelineForm(ScriptNode node) {
    final List<Widget> f = [];

    final bool hasHeading = node.param('heading').trim().isNotEmpty;
    final bool hasStage = node.param('stage').trim().isNotEmpty;

    f.add(_fInt(node, 'Hold', 'hold',
        min: 0, max: 1200, def: '240', suffix: 'fr'));
    f.add(_fRgb(node, 'Panel color', 'rgb', def: '30,30,38'));
    f.add(_fText(node, 'Heading', 'heading'));

    f.add(_gate(
      hasHeading,
      'A stage requires a heading',
      _fAsset(node, 'Center stage folder', 'stage', AssetSlot.imageFolder,
          optional: true),
    ));

    f.add(_gate(
      hasStage,
      'Thumbnails require a stage folder',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _fInt(node, 'Thumb width', 'thumbW',
              min: 40, max: 600, def: '150', suffix: 'px'),
          _fInt(node, 'Thumb gap', 'gap',
              min: 0, max: 200, def: '40', suffix: 'px'),
          _fToggle(node, 'Focus', 'focus', 'FOCUS',
              'Dims the wallpaper into a vignette while the panel is up.'),
        ],
      ),
    ));

    f.add(_fArea(node, 'Events', 'body', node.body, (v) => node.body = v,
        minLines: 6));
    f.add(_hint('One event per line as "date | text". A line with no pipe '
        'continues the previous event. Photo i pairs with event i.'));

    return f;
  }

  /// PHOTO's release percentage sits positionally behind the tint override,
  /// so the gate control unlocks only once a tint is set.
  List<Widget> _photoForm(ScriptNode node) {
    final List<Widget> f = [];
    final bool hasRgb = node.param('rgb').trim().isNotEmpty;

    f.add(_fAsset(node, 'Scan file', 'file', AssetSlot.rasterFile,
        maxDimension: 1024));
    f.add(_fInt(node, 'Hold', 'hold',
        min: 1, max: 900, def: '120', suffix: 'fr'));
    f.add(_fEnum(node, 'Channel', 'channel', ['R', 'G', 'B'], 'R'));
    f.add(_fRgb(node, 'Tint override', 'rgb',
        def: '0,255,0', optional: true, clearedLabel: 'INHERIT PEN'));

    f.add(_gate(
      hasRgb,
      'A release requires a tint override',
      _fInt(node, 'Release gate', 'release',
          min: 0, max: 100, def: '100', suffix: '%'),
    ));

    f.add(_hint('A release turns this into a stacking onion layer that '
        'persists until the next WIPE. Without one it is a classic '
        'fullscreen photo that replaces the screen. Layers cap at six.'));

    return f;
  }
}

// ---------------------------------------------------------------------
// Recycle browser thumbnail
// ---------------------------------------------------------------------

class _RecycleThumbCard extends StatefulWidget {
  final _RecycleEntry entry;
  final R3Theme theme;
  final Future<void> Function() onRestore;

  const _RecycleThumbCard({
    required this.entry,
    required this.theme,
    required this.onRestore,
  });

  @override
  State<_RecycleThumbCard> createState() => _RecycleThumbCardState();
}

class _RecycleThumbCardState extends State<_RecycleThumbCard> {
  bool _hovered = false;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final double width = sc(98);
    final double thumb = sc(98);
    final String folder = widget.entry.originalFolder.isEmpty
        ? 'IMAGES/'
        : widget.entry.originalFolder;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                AssetThumb(
                  path: widget.entry.absolutePath,
                  kind: ThumbKind.raster,
                  size: thumb,
                  theme: widget.theme,
                ),
                if (_hovered || _busy)
                  Positioned.fill(
                    child: Container(
                      alignment: Alignment.bottomCenter,
                      decoration: const BoxDecoration(
                        color: Color(0x66000000),
                      ),
                      padding: EdgeInsets.all(sc(6)),
                      child: Material(
                        color: const Color(0xE61A1A1A),
                        borderRadius: BorderRadius.circular(sc(3)),
                        child: InkWell(
                          onTap: _busy
                              ? null
                              : () async {
                                  setState(() => _busy = true);
                                  try {
                                    await widget.onRestore();
                                  } finally {
                                    if (mounted) setState(() => _busy = false);
                                  }
                                },
                          borderRadius: BorderRadius.circular(sc(3)),
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: sc(7), vertical: sc(5)),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_busy)
                                  SizedBox(
                                    width: sc(12),
                                    height: sc(12),
                                    child: const CircularProgressIndicator(
                                      strokeWidth: 1.5,
                                      color: Colors.white,
                                    ),
                                  )
                                else
                                  Icon(Icons.restore,
                                      size: sc(13), color: Colors.white),
                                SizedBox(width: sc(4)),
                                Text(
                                  _busy ? 'RESTORING' : 'RESTORE',
                                  style: widget.theme.micro
                                      .copyWith(color: Colors.white),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            SizedBox(height: sc(5)),
            Text(
              widget.entry.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: widget.theme.fine.copyWith(color: R3Theme.textMid),
            ),
            SizedBox(height: sc(2)),
            Text(
              folder,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: widget.theme.micro.copyWith(color: R3Theme.textDim),
            ),
          ],
        ),
      ),
    );
  }
}