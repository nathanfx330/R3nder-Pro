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
import 'structural_chrome_controls.dart';

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
  // -------------------------------------------------------------------

  /// The catch-all field for drops that hit no field, or null for none.
  _PinnedField? _pinned;

  VoidCallback? _dropRelease;
  bool _importBusy = false;
  String? _fieldMessageKey;
  String? _fieldMessage;
  bool _fieldFailed = false;
  bool _showRecyclePanel = false;
  List<_RecycleEntry> _recycleItems = const [];
  Map<String, int> _declaredCounts = const {};

  @override
  void initState() {
    super.initState();
    _assets = NodeAssetLibrary.scan(widget.imagesDir, widget.spritesDir);
    _recycleItems = _recycleEntries();
    _nodes = _parseTextToNodes(widget.initialText);
    _recomputeLines();

    final int? wanted = widget.initialSelectedNodeIndex;
    if (wanted != null && wanted >= 0 && wanted < _nodes.length) {
      _selectedId = _nodes[wanted].id;
    } else {
      final int first = _nodes.indexWhere((n) => n.isVisible);
      if (first >= 0) _selectedId = _nodes[first].id;
    }

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
      if (widget.initialText != _compose()) {
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

  String _slotRoot(AssetSlot slot) =>
      slot == AssetSlot.spriteFile ? widget.spritesDir : widget.imagesDir;

  String _slotAbsolute(AssetSlot slot, String value) {
    final String v = value.trim();
    if (v.isEmpty) return '';
    return '${_slotRoot(slot)}${Platform.pathSeparator}$v';
  }

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

  void _rescanAssets() {
    invalidateAssetPreviews();
    _assets = NodeAssetLibrary.scan(widget.imagesDir, widget.spritesDir);
    widget.onAssetsChanged?.call();
  }

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

  Future<void> _reorderFolder(String absoluteDir, List<String> names) async {
    final bool ok = writeFolderOrder(absoluteDir, names);
    if (!mounted) return;

    if (!ok) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('COULD NOT WRITE FOLDER ORDER')),
      );
      return;
    }

    _rescanAssets();
    _notifyChanged();
  }

  Future<void> _resetFolderOrder(String absoluteDir) async {
    clearFolderOrder(absoluteDir);
    if (!mounted) return;
    _rescanAssets();
    _notifyChanged();
  }

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

  void _onDrop(DropEvent event) {
    if (!mounted || _importBusy || event.paths.isEmpty) return;

    final Offset? pos = event.position;
    if (pos != null && DropZoneRegistry.dispatch(pos, event.paths)) return;

    final _PinnedField? pin = _pinned;
    if (pin == null) return;

    final int idx = _nodes.indexWhere((n) => n.id == pin.nodeId);
    if (idx < 0) {
      _unpin();
      return;
    }

    _handleDrop(event.paths, _nodes[idx], pin.paramKey, pin.slot);
  }

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

  String _compose() {
    final StringBuffer b = StringBuffer();
    for (final n in _nodes) {
      b.write(n.toMarkup());
    }
    return b.toString();
  }

  void _recomputeLines() {
    assignNodeLineSpans(_nodes);

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

  List<ScriptNode> _parseTextToNodes(String text) => parseScriptToNodes(text);

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

  int _blockEnd(int start) {
    int e = start + 1;
    while (e < _nodes.length && _nodes[e].isSpacer) {
      e++;
    }
    return e;
  }

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

    int at = _nodes.length;
    final int sel = _nodeIndexById(_selectedId);
    if (sel >= 0) at = _blockEnd(sel);

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

  void _moveSelected(int dir) {
    final int i = _nodeIndexById(_selectedId);
    if (i < 0) return;

    final List<int> vis = _visibleIndices;
    final int v = vis.indexOf(i);
    if (v < 0) return;

    final int targetVis = v + dir;
    if (targetVis < 0 || targetVis >= vis.length) return;

    _reorderVisible(v, dir > 0 ? targetVis + 1 : targetVis);
  }

  void _reorderVisible(int oldVis, int newVis) {
    final List<int> vis = _visibleIndices;
    if (oldVis < 0 || oldVis >= vis.length) return;

    final int start = vis[oldVis];
    final int end = _blockEnd(start);
    final List<ScriptNode> block = _nodes.sublist(start, end);
    final int insertAt = newVis >= vis.length ? _nodes.length : vis[newVis];

    setState(() {
      _nodes.removeRange(start, end);
      int adjusted = insertAt > start ? insertAt - block.length : insertAt;
      adjusted = adjusted.clamp(0, _nodes.length);
      _nodes.insertAll(adjusted, block);
    });
    _notifyChanged();
  }

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
        return node.body.replaceAll('\n', ' ↵ ');
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
        return node.rawText.replaceAll('\n', ' ↵ ');
    }
  }

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
      } catch (_) {}
    }
    return total;
  }

  static String _byteLabel(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

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
      final bool paged = node.type == 'APP' &&
          node.param('layout', 'GRID').toUpperCase().startsWith('MOSAIC');
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
            onReorder: (names) => _reorderFolder(abs, names),
            onResetOrder: () => _resetFolderOrder(abs),
            pagePlan: paged ? parsePagePlan(node.param('pages')) : null,
            onPagePlanChanged:
                paged ? (plan) => _setPagePlan(node, plan) : null,
            panePlan: paged ? parseAppPanePlan(node.param('panes')) : null,
            onPanePlanChanged:
                paged ? (plan) => _setPanePlan(node, plan) : null,
            captions: paged ? folderCaptions : null,
            selectedName: selName,
            onSelectName: profiled
                ? (name, index, total) => setState(() {
                      final String key = '$abs|$name';
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

  int? _declaredFolderCount(String folder) {
    final String name = folder.trim();
    if (name.isEmpty) return null;
    return _declaredCounts[name.toLowerCase()];
  }

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

  List<Widget> _buildNodeFormFields(ScriptNode node) {
    final List<Widget> f = [];

    switch (node.type) {
      case 'TEXT':
        f.add(_fArea(node, 'Typing text', 'body', node.body,
            (v) => node.body = v,
            minLines: 6));
        if (node.prefix.isNotEmpty || node.suffix.isNotEmpty) {
          f.add(_hint('Surrounding blank lines are held outside this field, '
              'so the typed layout stays exactly as written.'));
        }
        break;

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

      case 'BAR':
        f.add(_fInt(node, 'Width', 'width',
            min: 1, max: 120, def: '20', suffix: 'ch'));
        f.add(_fInt(node, 'Fill time', 'frames',
            min: 1, max: 900, def: '60', suffix: 'fr'));
        f.add(_fText(node, 'Fill char', 'fill', fallback: '█'));
        f.add(_fText(node, 'Empty char', 'empty', fallback: ' '));
        f.add(_fText(node, 'Brackets', 'brackets', fallback: '[]'));
        f.add(_hint('Set brackets to NONE for a bare bar.'));
        break;

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

      case 'CONFIG':
        f.addAll(_configForm(node));
        break;

      case 'STRUCT':
        f.addAll(_structForm(node));
        break;

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

  /// First-class controls for one `[STRUCT:...]` placement.
  ///
  /// EDIT and MOSAIC definitions are authored in their own structural panels.
  /// This form owns only this placement: source, window/fullscreen mode, clip
  /// audio intent, window title, and informational player overlay presentation.
  List<Widget> _structForm(ScriptNode node) {
    final List<Widget> f = [];
    final String current = node.param('source').trim();

    final List<String> sources = _nodes
        .where((n) =>
            n.isStructural && (n.type == 'EDIT' || n.type == 'MOSAIC'))
        .map((n) {
          final String id = n.param('id').trim();
          return id.isEmpty ? '' : '${n.type}.$id';
        })
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList()
      ..sort();

    final bool resolves = current.isNotEmpty && sources.contains(current);
    final List<String> items = [
      if (current.isNotEmpty && !sources.contains(current)) current,
      ...sources,
    ];

    f.add(_wrap(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            R3MicroLabel('Source', theme: widget.theme),
            SizedBox(width: sc(8)),
            if (current.isNotEmpty && !resolves)
              const R3Tally(state: R3TallyState.error, count: 'UNRESOLVED'),
          ],
        ),
        SizedBox(height: sc(6)),
        if (items.isEmpty)
          Text('NO EDIT OR MOSAIC SOURCES DEFINED', style: widget.theme.micro)
        else
          _bareDropdown(
            value: current,
            items: items,
            itemLabel: (s) => s,
            onChanged: (v) {
              if (v == null) return;
              node.set('source', v);
              _notifyChanged();
            },
          ),
      ],
    )));

    f.add(_fToggle(
      node,
      'Full screen',
      'mode',
      'FULL',
      'Fill the program frame directly instead of presenting this source '
          'inside a desktop window.',
    ));

    f.add(_fToggle(
      node,
      'Audio',
      'audio',
      'AUDIO',
      'Play the audio belonging to clips in this sequence. Workspace voice '
          'and music beds are authored separately and are unaffected.',
    ));

    f.add(_wrap(
      StructuralChromeControls(
        theme: widget.theme,
        windowTitleController:
            _ctl('${node.id}|title', node.param('title')),
        overlayMode: node.param('overlay', 'DEFAULT'),
        topOverlayController:
            _ctl('${node.id}|top', node.param('top')),
        bottomOverlayController:
            _ctl('${node.id}|bottom', node.param('bottom')),
        onWindowTitleChanged: (value) {
          node.set('title', value);
          _notifyChanged();
        },
        onOverlayModeChanged: (value) {
          node.set('overlay', value);
          _notifyChanged();
        },
        onTopOverlayChanged: (value) {
          node.set('top', value);
          _notifyChanged();
        },
        onBottomOverlayChanged: (value) {
          node.set('bottom', value);
          _notifyChanged();
        },
      ),
    ));

    f.add(_hint('This changes only this STRUCT placement. The referenced '
        'EDIT or MOSAIC definition stays unchanged and can be placed '
        'windowed or full screen with different chrome somewhere else.'));

    return f;
  }

  // Remaining helpers and forms continue unchanged from the current file.
  // They are omitted here only for brevity in this attempted replacement.
}
