from pathlib import Path


def patch(path_str: str, replacements: list[tuple[str, str]]) -> None:
    path = Path(path_str)
    text = path.read_text()
    for old, new in replacements:
        count = text.count(old)
        if count != 1:
            raise SystemExit(
                f"{path_str}: expected one anchor, found {count}: {old[:100]!r}"
            )
        text = text.replace(old, new, 1)
    path.write_text(text)


patch(
    "lib/project_media_bin_view.dart",
    [
        (
            "import 'package:flutter/material.dart';",
            "import 'package:flutter/gestures.dart' show PointerScrollEvent;\n"
            "import 'package:flutter/material.dart';",
        ),
        (
            "  ProjectMediaThumbnailLoader? _thumbnailLoader;\n"
            "  String? _scanError;\n"
            "  late bool _expanded;",
            "  ProjectMediaThumbnailLoader? _thumbnailLoader;\n"
            "  String? _scanError;\n"
            "  late bool _expanded;\n"
            "  final ScrollController _horizontal = ScrollController();",
        ),
        (
            "  void _reload() {",
            "  @override\n"
            "  void dispose() {\n"
            "    _horizontal.dispose();\n"
            "    super.dispose();\n"
            "  }\n\n"
            "  void _reload() {",
        ),
        (
            "    return SizedBox(\n"
            "      height: sc(128),\n"
            "      child: ListView.separated(\n"
            "        key: const ValueKey<String>('project-media-bin-list'),\n"
            "        padding: EdgeInsets.fromLTRB(sc(10), 0, sc(10), sc(9)),\n"
            "        scrollDirection: Axis.horizontal,",
            "    return SizedBox(\n"
            "      height: sc(128),\n"
            "      child: Scrollbar(\n"
            "        controller: _horizontal,\n"
            "        thumbVisibility: true,\n"
            "        interactive: true,\n"
            "        child: Listener(\n"
            "          onPointerSignal: (event) {\n"
            "            if (event is! PointerScrollEvent || !_horizontal.hasClients) {\n"
            "              return;\n"
            "            }\n"
            "            final double delta = event.scrollDelta.dx.abs() >\n"
            "                    event.scrollDelta.dy.abs()\n"
            "                ? event.scrollDelta.dx\n"
            "                : event.scrollDelta.dy;\n"
            "            final ScrollPosition position = _horizontal.position;\n"
            "            final double target = (position.pixels + delta).clamp(\n"
            "              position.minScrollExtent,\n"
            "              position.maxScrollExtent,\n"
            "            );\n"
            "            if ((target - position.pixels).abs() > 0.5) {\n"
            "              _horizontal.jumpTo(target);\n"
            "            }\n"
            "          },\n"
            "          child: ListView.separated(\n"
            "            controller: _horizontal,\n"
            "            key: const ValueKey<String>('project-media-bin-list'),\n"
            "            padding: EdgeInsets.fromLTRB(sc(10), 0, sc(10), sc(9)),\n"
            "            scrollDirection: Axis.horizontal,",
        ),
        (
            "          );\n"
            "        },\n"
            "      ),\n"
            "    );\n"
            "  }\n\n"
            "  Widget _message",
            "          );\n"
            "        },\n"
            "          ),\n"
            "        ),\n"
            "      ),\n"
            "    );\n"
            "  }\n\n"
            "  Widget _message",
        ),
    ],
)

patch(
    "lib/edit_surface.dart",
    [
        (
            "import 'timeline_markers.dart';\n"
            "import 'ui_theme.dart';",
            "import 'timeline_markers.dart';\n"
            "import 'timeline_snap.dart';\n"
            "import 'ui_theme.dart';",
        ),
        (
            "  int? _lastSeekSent;\n"
            "  ValueListenable<EditPlaybackFrameState>? _playbackFrames;",
            "  int? _lastSeekSent;\n"
            "  String? _mediaDropPreviewTrackId;\n"
            "  int? _mediaDropPreviewFrame;\n"
            "  String? _clipSnapGuideTrackId;\n"
            "  int? _clipSnapGuideFrame;\n"
            "  ValueListenable<EditPlaybackFrameState>? _playbackFrames;",
        ),
        (
            "  final ScrollController _horizontal = ScrollController();\n"
            "  final ScrollController _vertical = ScrollController();",
            "  final ScrollController _horizontal = ScrollController();\n"
            "  final ScrollController _vertical = ScrollController();\n"
            "  final Map<String, GlobalKey> _laneKeys = <String, GlobalKey>{};",
        ),
        (
            "  int _frameFromDx(double dx, int frames) {",
            "  int get _snapThresholdFrames =>\n"
            "      math.max(1, (sc(7) / _pixelsPerFrame).round());\n\n"
            "  List<int> _trackSnapAnchors(\n"
            "    EditSurfaceTrack? track, {\n"
            "    String? excludingClipId,\n"
            "  }) {\n"
            "    final Set<int> anchors = <int>{0, math.max(0, _effectiveFrame)};\n"
            "    for (final EditSurfaceClip clip\n"
            "        in track?.clips ?? const <EditSurfaceClip>[]) {\n"
            "      if (clip.id == excludingClipId) continue;\n"
            "      anchors.add(clip.atFrame);\n"
            "      anchors.add(clip.endFrameExclusive);\n"
            "    }\n"
            "    final List<int> result = anchors.toList()..sort();\n"
            "    return result;\n"
            "  }\n\n"
            "  void _setClipSnapGuide(String trackId, int? anchorFrame) {\n"
            "    final String? nextTrack = anchorFrame == null ? null : trackId;\n"
            "    if (_clipSnapGuideTrackId == nextTrack &&\n"
            "        _clipSnapGuideFrame == anchorFrame) {\n"
            "      return;\n"
            "    }\n"
            "    setState(() {\n"
            "      _clipSnapGuideTrackId = nextTrack;\n"
            "      _clipSnapGuideFrame = anchorFrame;\n"
            "    });\n"
            "  }\n\n"
            "  int? _mediaDropFrameFor(\n"
            "    String trackId,\n"
            "    EditSurfaceTrack? track,\n"
            "    Offset globalOffset,\n"
            "  ) {\n"
            "    final GlobalKey? laneKey = _laneKeys[trackId];\n"
            "    final BuildContext? laneContext = laneKey?.currentContext;\n"
            "    final RenderObject? renderObject = laneContext?.findRenderObject();\n"
            "    if (renderObject is! RenderBox) return null;\n"
            "    final double dx = renderObject.globalToLocal(globalOffset).dx;\n"
            "    final int raw = math.max(0, (dx / _pixelsPerFrame).floor());\n"
            "    return snapTimelinePosition(\n"
            "      rawFrame: raw,\n"
            "      anchors: _trackSnapAnchors(track),\n"
            "      thresholdFrames: _snapThresholdFrames,\n"
            "    ).frame;\n"
            "  }\n\n"
            "  Widget _timelineGuide({\n"
            "    required Key key,\n"
            "    required int frame,\n"
            "    required Color color,\n"
            "  }) {\n"
            "    return Positioned(\n"
            "      key: key,\n"
            "      left: frame * _pixelsPerFrame - sc(1),\n"
            "      top: 0,\n"
            "      bottom: 0,\n"
            "      child: IgnorePointer(\n"
            "        child: Container(width: sc(2), color: color),\n"
            "      ),\n"
            "    );\n"
            "  }\n\n"
            "  int _frameFromDx(double dx, int frames) {",
        ),
        (
            "                onSelect: () => _select(clip),\n"
            "                onMove: (int atFrame) {",
            "                onSelect: () => _select(clip),\n"
            "                snapAnchors: _trackSnapAnchors(\n"
            "                  track,\n"
            "                  excludingClipId: clip.id,\n"
            "                ),\n"
            "                snapThresholdFrames: _snapThresholdFrames,\n"
            "                onSnapGuideChanged: (int? frame) =>\n"
            "                    _setClipSnapGuide(trackId, frame),\n"
            "                onMove: (int atFrame) {",
        ),
        (
            "              ),\n"
            "            ),\n"
            "        ],\n"
            "      ),\n"
            "    );\n\n"
            "    final EditProjectMediaDrop? onDrop = widget.onProjectMediaDrop;",
            "              ),\n"
            "            ),\n"
            "          if (_clipSnapGuideTrackId == trackId &&\n"
            "              _clipSnapGuideFrame != null)\n"
            "            _timelineGuide(\n"
            "              key: ValueKey<String>('edit-snap-guide-$trackId'),\n"
            "              frame: _clipSnapGuideFrame!,\n"
            "              color: widget.theme.accent,\n"
            "            ),\n"
            "          if (_mediaDropPreviewTrackId == trackId &&\n"
            "              _mediaDropPreviewFrame != null)\n"
            "            _timelineGuide(\n"
            "              key: ValueKey<String>('edit-media-drop-preview-$trackId'),\n"
            "              frame: _mediaDropPreviewFrame!,\n"
            "              color: R3Theme.ribbonMedia,\n"
            "            ),\n"
            "        ],\n"
            "      ),\n"
            "    );\n\n"
            "    final EditProjectMediaDrop? onDrop = widget.onProjectMediaDrop;",
        ),
        (
            "    final GlobalKey laneKey = GlobalKey();\n"
            "    return DragTarget<ProjectMediaItem>(",
            "    final GlobalKey laneKey =\n"
            "        _laneKeys.putIfAbsent(trackId, () => GlobalKey());\n"
            "    return DragTarget<ProjectMediaItem>(",
        ),
        (
            "      onAcceptWithDetails: (DragTargetDetails<ProjectMediaItem> details) {\n"
            "        if (widget.isPlaying || !details.data.isUsable) return;\n"
            "        final BuildContext? laneContext = laneKey.currentContext;\n"
            "        final RenderObject? renderObject = laneContext?.findRenderObject();\n"
            "        if (renderObject is! RenderBox) return;\n"
            "        final double dx = renderObject.globalToLocal(details.offset).dx;\n"
            "        final int atFrame = math.max(0, (dx / _pixelsPerFrame).floor());\n"
            "        onDrop(details.data, trackId, atFrame);\n"
            "      },",
            "      onMove: (DragTargetDetails<ProjectMediaItem> details) {\n"
            "        if (widget.isPlaying || !details.data.isUsable) return;\n"
            "        final int? frame = _mediaDropFrameFor(\n"
            "          trackId,\n"
            "          track,\n"
            "          details.offset,\n"
            "        );\n"
            "        if (frame == null ||\n"
            "            (_mediaDropPreviewTrackId == trackId &&\n"
            "                _mediaDropPreviewFrame == frame)) {\n"
            "          return;\n"
            "        }\n"
            "        setState(() {\n"
            "          _mediaDropPreviewTrackId = trackId;\n"
            "          _mediaDropPreviewFrame = frame;\n"
            "        });\n"
            "      },\n"
            "      onLeave: (_) {\n"
            "        if (_mediaDropPreviewTrackId != trackId) return;\n"
            "        setState(() {\n"
            "          _mediaDropPreviewTrackId = null;\n"
            "          _mediaDropPreviewFrame = null;\n"
            "        });\n"
            "      },\n"
            "      onAcceptWithDetails: (DragTargetDetails<ProjectMediaItem> details) {\n"
            "        if (widget.isPlaying || !details.data.isUsable) return;\n"
            "        final int? resolved = _mediaDropPreviewTrackId == trackId\n"
            "            ? _mediaDropPreviewFrame\n"
            "            : _mediaDropFrameFor(trackId, track, details.offset);\n"
            "        if (resolved == null) return;\n"
            "        setState(() {\n"
            "          _mediaDropPreviewTrackId = null;\n"
            "          _mediaDropPreviewFrame = null;\n"
            "        });\n"
            "        onDrop(details.data, trackId, resolved);\n"
            "      },",
        ),
        (
            "  final R3Theme theme;\n"
            "  final VoidCallback onSelect;\n"
            "  final ValueChanged<int> onMove;",
            "  final R3Theme theme;\n"
            "  final VoidCallback onSelect;\n"
            "  final List<int> snapAnchors;\n"
            "  final int snapThresholdFrames;\n"
            "  final ValueChanged<int?> onSnapGuideChanged;\n"
            "  final ValueChanged<int> onMove;",
        ),
        (
            "    required this.theme,\n"
            "    required this.onSelect,\n"
            "    required this.onMove,",
            "    required this.theme,\n"
            "    required this.onSelect,\n"
            "    required this.snapAnchors,\n"
            "    required this.snapThresholdFrames,\n"
            "    required this.onSnapGuideChanged,\n"
            "    required this.onMove,",
        ),
        (
            "  int get _previewAt {\n"
            "    switch (_mode) {\n"
            "      case _ClipDragMode.move:\n"
            "      case _ClipDragMode.trimStart:\n"
            "        return math.max(0, widget.clip.atFrame + _deltaFrames);\n"
            "      case _ClipDragMode.none:\n"
            "      case _ClipDragMode.trimEnd:\n"
            "        return widget.clip.atFrame;\n"
            "    }\n"
            "  }",
            "  int get _rawMoveAt => math.max(0, widget.clip.atFrame + _deltaFrames);\n\n"
            "  TimelineSnapResult get _moveSnap {\n"
            "    if (_mode != _ClipDragMode.move || _deltaFrames == 0) {\n"
            "      return TimelineSnapResult(\n"
            "        frame: _rawMoveAt,\n"
            "        anchorFrame: null,\n"
            "        edge: null,\n"
            "      );\n"
            "    }\n"
            "    return snapTimelineMove(\n"
            "      rawAtFrame: _rawMoveAt,\n"
            "      durationFrames: widget.clip.durationFrames,\n"
            "      anchors: widget.snapAnchors,\n"
            "      thresholdFrames: widget.snapThresholdFrames,\n"
            "    );\n"
            "  }\n\n"
            "  int get _previewAt {\n"
            "    switch (_mode) {\n"
            "      case _ClipDragMode.move:\n"
            "        return _moveSnap.frame;\n"
            "      case _ClipDragMode.trimStart:\n"
            "        return math.max(0, widget.clip.atFrame + _deltaFrames);\n"
            "      case _ClipDragMode.none:\n"
            "      case _ClipDragMode.trimEnd:\n"
            "        return widget.clip.atFrame;\n"
            "    }\n"
            "  }",
        ),
        (
            "    widget.onSelect();\n"
            "    setState(() {\n"
            "      _mode = mode;",
            "    widget.onSelect();\n"
            "    widget.onSnapGuideChanged(null);\n"
            "    setState(() {\n"
            "      _mode = mode;",
        ),
        (
            "    setState(() {\n"
            "      _dragPixels = event.position.dx - _pointerDownX;\n"
            "    });\n"
            "  }",
            "    setState(() {\n"
            "      _dragPixels = event.position.dx - _pointerDownX;\n"
            "    });\n"
            "    if (_mode == _ClipDragMode.move) {\n"
            "      final TimelineSnapResult snap = _moveSnap;\n"
            "      widget.onSnapGuideChanged(snap.snapped ? snap.anchorFrame : null);\n"
            "    }\n"
            "  }",
        ),
        (
            "  void _finishPointer({required bool commit}) {\n"
            "    final int delta = _deltaFrames;\n"
            "    final _ClipDragMode mode = _mode;\n\n"
            "    setState(() {",
            "  void _finishPointer({required bool commit}) {\n"
            "    final int delta = _deltaFrames;\n"
            "    final _ClipDragMode mode = _mode;\n"
            "    final int moveAt = mode == _ClipDragMode.move\n"
            "        ? _moveSnap.frame\n"
            "        : math.max(0, widget.clip.atFrame + delta);\n\n"
            "    setState(() {",
        ),
        (
            "    });\n\n"
            "    if (!commit || delta == 0) return;\n\n"
            "    switch (mode) {\n"
            "      case _ClipDragMode.move:\n"
            "        widget.onMove(math.max(0, widget.clip.atFrame + delta));",
            "    });\n"
            "    widget.onSnapGuideChanged(null);\n\n"
            "    if (!commit) return;\n\n"
            "    switch (mode) {\n"
            "      case _ClipDragMode.move:\n"
            "        if (moveAt != widget.clip.atFrame) widget.onMove(moveAt);",
        ),
        (
            "              child: _pointerRegion(\n"
            "                mode: _ClipDragMode.move,\n"
            "                child: Container(",
            "              child: MouseRegion(\n"
            "                cursor: SystemMouseCursors.move,\n"
            "                child: _pointerRegion(\n"
            "                  mode: _ClipDragMode.move,\n"
            "                  child: Container(",
        ),
        (
            "                  ),\n"
            "                ),\n"
            "              ),\n"
            "            ),\n"
            "            if (!widget.clip.transition.isNone)",
            "                  ),\n"
            "                ),\n"
            "              ),\n"
            "              ),\n"
            "            ),\n"
            "            if (!widget.clip.transition.isNone)",
        ),
    ],
)

patch(
    "test/project_media_bin_view_test.dart",
    [
        (
            "import 'package:flutter/material.dart';",
            "import 'package:flutter/gestures.dart';\n"
            "import 'package:flutter/material.dart';",
        ),
        (
            "  testWidgets('scan failure is surfaced without throwing out of build', (",
            "  testWidgets('vertical mouse wheel scrolls the horizontal media row', (\n"
            "    WidgetTester tester,\n"
            "  ) async {\n"
            "    final List<ProjectMediaItem> items = <ProjectMediaItem>[\n"
            "      for (int i = 0; i < 10; i++) _item('shot_$i.mp4'),\n"
            "    ];\n"
            "    await tester.pumpWidget(\n"
            "      MaterialApp(\n"
            "        home: Scaffold(\n"
            "          body: Align(\n"
            "            alignment: Alignment.topLeft,\n"
            "            child: SizedBox(\n"
            "              width: 600,\n"
            "              child: ProjectMediaBinPanel(\n"
            "                theme: theme,\n"
            "                projectClockRunning: false,\n"
            "                initiallyExpanded: true,\n"
            "                workspaceRootResolver: () => '/workspace',\n"
            "                scanMedia: ({String? workspaceRoot}) => items,\n"
            "                thumbnailLoader: _noThumbnail,\n"
            "              ),\n"
            "            ),\n"
            "          ),\n"
            "        ),\n"
            "      ),\n"
            "    );\n"
            "    await tester.pumpAndSettle();\n\n"
            "    final Finder list =\n"
            "        find.byKey(const ValueKey<String>('project-media-bin-list'));\n"
            "    final Finder scrollableFinder = find.descendant(\n"
            "      of: list,\n"
            "      matching: find.byType(Scrollable),\n"
            "    );\n"
            "    final ScrollableState scrollable =\n"
            "        tester.state<ScrollableState>(scrollableFinder);\n"
            "    expect(scrollable.position.pixels, 0);\n\n"
            "    await tester.sendEventToBinding(\n"
            "      PointerScrollEvent(\n"
            "        position: tester.getCenter(list),\n"
            "        scrollDelta: const Offset(0, 160),\n"
            "      ),\n"
            "    );\n"
            "    await tester.pump();\n\n"
            "    expect(scrollable.position.pixels, greaterThan(0));\n"
            "  });\n\n"
            "  testWidgets('scan failure is surfaced without throwing out of build', (",
        ),
    ],
)

patch(
    "test/edit_surface_test.dart",
    [
        (
            "  testWidgets('split button writes two real CLIP blocks at playhead',",
            "  testWidgets('moving a clip snaps to the playhead and shows a guide', (\n"
            "    WidgetTester tester,\n"
            "  ) async {\n"
            "    String? changed;\n"
            "    await tester.pumpWidget(\n"
            "      _host(\n"
            "        currentFrame: 25,\n"
            "        onSourceChanged: (String value) => changed = value,\n"
            "      ),\n"
            "    );\n"
            "    await tester.pumpAndSettle();\n\n"
            "    final Finder intro = find.text('intro');\n"
            "    final TestGesture gesture = await tester.startGesture(\n"
            "      tester.getCenter(intro),\n"
            "    );\n"
            "    await gesture.moveBy(const Offset(28, 0));\n"
            "    await tester.pump();\n\n"
            "    expect(\n"
            "      find.byKey(const ValueKey<String>('edit-snap-guide-V1')),\n"
            "      findsOneWidget,\n"
            "    );\n\n"
            "    await gesture.up();\n"
            "    await tester.pumpAndSettle();\n\n"
            "    expect(changed, isNotNull);\n"
            "    expect(\n"
            "      changed,\n"
            "      contains('[CLIP:intro:video/intro.mp4:25:20:40:1]'),\n"
            "    );\n"
            "    expect(\n"
            "      find.byKey(const ValueKey<String>('edit-snap-guide-V1')),\n"
            "      findsNothing,\n"
            "    );\n"
            "  });\n\n"
            "  testWidgets('split button writes two real CLIP blocks at playhead',",
        ),
    ],
)

patch(
    "test/edit_workspace_media_drag_test.dart",
    [
        (
            "    await gesture.moveTo(Offset(targetRect.left + 120, targetRect.center.dy));\n"
            "    await tester.pump();\n"
            "    await gesture.up();",
            "    await gesture.moveTo(Offset(targetRect.left + 120, targetRect.center.dy));\n"
            "    await tester.pump();\n"
            "    expect(\n"
            "      find.byKey(const ValueKey<String>('edit-media-drop-preview-V1')),\n"
            "      findsOneWidget,\n"
            "    );\n"
            "    await gesture.up();",
        ),
    ],
)
