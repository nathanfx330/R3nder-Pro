// ./lib/project_media_bin_view.dart
//
// Reusable project-media browser UI.
//
// This widget is intentionally nonauthoring. It projects video/ through the
// Phase 1 model, asks the Phase 2 cache for thumbnails, and exposes an optional
// item activation callback. Timeline placement and TEXT attachment belong to
// later gestures that reuse this same surface.

import 'dart:io';

import 'package:flutter/material.dart';

import 'edit_media_import.dart' show resolveActiveWorkspaceRoot;
import 'project_media_bin.dart';
import 'project_media_thumbnails.dart';
import 'ui_theme.dart';

typedef ProjectMediaBinScanner =
    List<ProjectMediaItem> Function({String? workspaceRoot});

typedef ProjectMediaThumbnailLoader =
    Future<String?> Function(
      ProjectMediaItem item, {
      required bool projectClockRunning,
    });

class ProjectMediaBinPanel extends StatefulWidget {
  final R3Theme theme;
  final bool projectClockRunning;
  final int refreshToken;
  final bool initiallyExpanded;
  final String Function()? workspaceRootResolver;
  final ProjectMediaBinScanner? scanMedia;
  final ProjectMediaThumbnailLoader? thumbnailLoader;
  final ValueChanged<ProjectMediaItem>? onItemPressed;

  const ProjectMediaBinPanel({
    super.key,
    required this.theme,
    required this.projectClockRunning,
    this.refreshToken = 0,
    this.initiallyExpanded = false,
    this.workspaceRootResolver,
    this.scanMedia,
    this.thumbnailLoader,
    this.onItemPressed,
  });

  @override
  State<ProjectMediaBinPanel> createState() => _ProjectMediaBinPanelState();
}

class _ProjectMediaBinPanelState extends State<ProjectMediaBinPanel> {
  List<ProjectMediaItem> _items = const <ProjectMediaItem>[];
  ProjectMediaThumbnailLoader? _thumbnailLoader;
  String? _scanError;
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
    _reload();
  }

  @override
  void didUpdateWidget(covariant ProjectMediaBinPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refreshToken != oldWidget.refreshToken ||
        widget.workspaceRootResolver != oldWidget.workspaceRootResolver ||
        widget.scanMedia != oldWidget.scanMedia ||
        widget.thumbnailLoader != oldWidget.thumbnailLoader) {
      _reload();
    }
  }

  void _reload() {
    try {
      final String root =
          (widget.workspaceRootResolver ?? resolveActiveWorkspaceRoot)();
      final ProjectMediaBinScanner scanner =
          widget.scanMedia ?? scanProjectMediaBin;
      final List<ProjectMediaItem> items = scanner(workspaceRoot: root);
      final ProjectMediaThumbnailLoader loader =
          widget.thumbnailLoader ??
          ProjectMediaThumbnailService(workspaceRoot: root).thumbnailFor;

      _items = items;
      _thumbnailLoader = loader;
      _scanError = null;
    } catch (error) {
      _items = const <ProjectMediaItem>[];
      _thumbnailLoader = widget.thumbnailLoader;
      _scanError = '$error';
    }
  }

  void _refresh() {
    setState(_reload);
  }

  @override
  Widget build(BuildContext context) {
    final String countLabel = _scanError != null
        ? 'UNAVAILABLE'
        : '${_items.length} ${_items.length == 1 ? 'FILE' : 'FILES'}';

    return Container(
      decoration: const BoxDecoration(
        color: R3Theme.panel,
        border: Border(bottom: BorderSide(color: R3Theme.hairline)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            height: sc(31),
            child: Row(
              children: <Widget>[
                InkWell(
                  key: const ValueKey<String>('project-media-bin-toggle'),
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: sc(10)),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          _expanded ? Icons.expand_more : Icons.chevron_right,
                          size: sc(16),
                          color: widget.theme.accentDim,
                        ),
                        SizedBox(width: sc(4)),
                        Text('MEDIA BIN', style: widget.theme.microAccent),
                        SizedBox(width: sc(8)),
                        Text(countLabel, style: widget.theme.micro),
                      ],
                    ),
                  ),
                ),
                const Spacer(),
                IconButton(
                  key: const ValueKey<String>('project-media-bin-refresh'),
                  tooltip: 'Refresh project media',
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.refresh,
                    size: sc(15),
                    color: R3Theme.textDim,
                  ),
                  onPressed: _refresh,
                ),
                SizedBox(width: sc(5)),
              ],
            ),
          ),
          if (_expanded) _buildExpanded(),
        ],
      ),
    );
  }

  Widget _buildExpanded() {
    if (_scanError != null) {
      return _message('PROJECT MEDIA UNAVAILABLE', detail: _scanError);
    }
    if (_items.isEmpty) {
      return _message(
        'NO PROJECT MEDIA',
        detail: 'Files in video/ appear here.',
      );
    }

    final ProjectMediaThumbnailLoader? loader = _thumbnailLoader;
    return SizedBox(
      height: sc(118),
      child: ListView.separated(
        key: const ValueKey<String>('project-media-bin-list'),
        padding: EdgeInsets.fromLTRB(sc(10), 0, sc(10), sc(9)),
        scrollDirection: Axis.horizontal,
        itemCount: _items.length,
        separatorBuilder: (_, __) => SizedBox(width: sc(8)),
        itemBuilder: (BuildContext context, int index) {
          final ProjectMediaItem item = _items[index];
          return _ProjectMediaTile(
            key: ValueKey<String>('project-media:${item.resolvedPath}'),
            item: item,
            theme: widget.theme,
            projectClockRunning: widget.projectClockRunning,
            thumbnailLoader: loader,
            onPressed: widget.onItemPressed == null
                ? null
                : () => widget.onItemPressed!(item),
          );
        },
      ),
    );
  }

  Widget _message(String title, {String? detail}) {
    return SizedBox(
      height: sc(72),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(title, style: widget.theme.micro),
            if (detail != null) ...<Widget>[
              SizedBox(height: sc(4)),
              Text(
                detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: widget.theme.fine,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProjectMediaTile extends StatefulWidget {
  final ProjectMediaItem item;
  final R3Theme theme;
  final bool projectClockRunning;
  final ProjectMediaThumbnailLoader? thumbnailLoader;
  final VoidCallback? onPressed;

  const _ProjectMediaTile({
    super.key,
    required this.item,
    required this.theme,
    required this.projectClockRunning,
    required this.thumbnailLoader,
    required this.onPressed,
  });

  @override
  State<_ProjectMediaTile> createState() => _ProjectMediaTileState();
}

class _ProjectMediaTileState extends State<_ProjectMediaTile> {
  Future<String?>? _thumbnailFuture;

  @override
  void initState() {
    super.initState();
    _requestThumbnail();
  }

  @override
  void didUpdateWidget(covariant _ProjectMediaTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool itemChanged =
        widget.item.resolvedPath != oldWidget.item.resolvedPath ||
        widget.item.sizeBytes != oldWidget.item.sizeBytes ||
        widget.item.modifiedAt != oldWidget.item.modifiedAt;
    final bool playbackStopped =
        oldWidget.projectClockRunning && !widget.projectClockRunning;
    if (itemChanged ||
        playbackStopped ||
        widget.thumbnailLoader != oldWidget.thumbnailLoader) {
      _requestThumbnail();
    }
  }

  void _requestThumbnail() {
    final ProjectMediaThumbnailLoader? loader = widget.thumbnailLoader;
    _thumbnailFuture = loader?.call(
      widget.item,
      projectClockRunning: widget.projectClockRunning,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool usable = widget.item.isUsable;
    return SizedBox(
      width: sc(132),
      child: InkWell(
        onTap: usable ? widget.onPressed : null,
        child: Container(
          decoration: BoxDecoration(
            color: R3Theme.bg,
            border: Border.all(
              color: usable ? R3Theme.hairline : R3Theme.danger,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: FutureBuilder<String?>(
                  future: _thumbnailFuture,
                  builder: (BuildContext context, AsyncSnapshot<String?> snap) {
                    final String? path = snap.data;
                    if (path == null || path.isEmpty) {
                      return _thumbnailPlaceholder();
                    }
                    return Image.file(
                      File(path),
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.low,
                      errorBuilder: (_, __, ___) => _thumbnailPlaceholder(),
                    );
                  },
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(sc(6), sc(4), sc(6), sc(5)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      widget.item.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: widget.theme.fine.copyWith(
                        color: usable ? R3Theme.textMid : R3Theme.danger,
                      ),
                    ),
                    if (!usable)
                      Text(
                        'UNUSABLE NAME',
                        style: widget.theme.micro.copyWith(
                          color: R3Theme.danger,
                          fontSize: sc(8),
                          letterSpacing: sc(1),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _thumbnailPlaceholder() {
    return Container(
      color: R3Theme.panelHi,
      alignment: Alignment.center,
      child: Icon(Icons.movie_outlined, size: sc(28), color: R3Theme.textDim),
    );
  }
}
