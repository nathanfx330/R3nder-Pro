// ./lib/mosaic_surface.dart
//
// GUI surface for canonical MOSAIC / PANE / CLIP authoring.
//
// Each visual pane is a real compact timeline. ADD CUT introduces already-
// trimmed EDIT material, then authored CLIPs can be moved and trimmed directly
// against a ruler. Crossfades live on the actual overlap between adjacent cuts.
// The script remains canonical; this widget owns only transient gesture state.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'edit_model.dart';
import 'edit_video_preview.dart';
import 'media_layer.dart';
import 'mosaic_surface_model.dart';
import 'ui_theme.dart';

class MosaicSurface extends StatefulWidget {
  final String source;
  final String mosaicId;
  final int currentFrame;
  final bool isPlaying;
  final R3Theme theme;
  final ValueChanged<String> onSourceChanged;
  final ValueChanged<int> onSeek;

  /// Test seams shared with EditVideoPreview.
  final MediaDecoderBackend? backend;
  final String Function(String source)? resolveSource;

  const MosaicSurface({
    super.key,
    required this.source,
    required this.mosaicId,
    required this.currentFrame,
    required this.theme,
    required this.onSourceChanged,
    required this.onSeek,
    this.isPlaying = false,
    this.backend,
    this.resolveSource,
  });

  @override
  State<MosaicSurface> createState() => _MosaicSurfaceState();
}

class _MosaicSurfaceState extends State<MosaicSurface> {
  static final double _kRulerHeight = sc(22);

  late String _workingSource;
  String? _selectedPaneId;
  String? _selectedClipId;
  String? _error;
  double _pixelsPerFrame = 2.0;

  @override
  void initState() {
    super.initState();
    _workingSource = widget.source;
  }

  @override
  void didUpdateWidget(covariant MosaicSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.source != oldWidget.source && widget.source != _workingSource) {
      _workingSource = widget.source;
      _error = null;
    }
  }

  MosaicSurfaceDocument? _parse() {
    try {
      return MosaicSurfaceDocument.parse(_workingSource, widget.mosaicId);
    } catch (error) {
      _error = '$error';
      return null;
    }
  }

  bool _commit(String Function(MosaicSurfaceDocument document) operation) {
    final MosaicSurfaceDocument? document = _parse();
    if (document == null) {
      setState(() {});
      return false;
    }

    try {
      final String next = operation(document);
      MosaicSurfaceDocument.parse(next, widget.mosaicId);
      setState(() {
        _workingSource = next;
        _error = null;
      });
      widget.onSourceChanged(next);
      return true;
    } catch (error) {
      setState(() => _error = '$error');
      return false;
    }
  }

  List<_EditCutChoice> _editCuts(MosaicSurfaceDocument document) {
    final List<_EditCutChoice> cuts = <_EditCutChoice>[];
    for (final EditSequence edit in document.model.edits) {
      for (final EditTrack track in edit.tracks) {
        for (final EditClip clip in track.clips) {
          cuts.add(
            _EditCutChoice(
              editId: edit.id,
              trackId: track.id,
              clip: clip,
            ),
          );
        }
      }
    }
    return cuts;
  }

  int _sourceOut(EditClip clip) =>
      clip.sourceFrameAtProjectOffset(clip.durationFrames - 1);

  Future<_EditCutChoice?> _pickCut(
    MosaicSurfaceDocument document,
    int paneNumber,
  ) async {
    final List<_EditCutChoice> cuts = _editCuts(document);
    if (cuts.isEmpty) {
      setState(() {
        _error = 'No EDIT cuts exist yet. Trim a clip in EDIT first.';
      });
      return null;
    }

    return showDialog<_EditCutChoice>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: R3Theme.panel,
          title: Text('Add cut to Pane $paneNumber', style: widget.theme.value),
          content: SizedBox(
            width: sc(620),
            height: sc(390),
            child: ListView.separated(
              itemCount: cuts.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (BuildContext context, int index) {
                final _EditCutChoice choice = cuts[index];
                final EditClip clip = choice.clip;
                return InkWell(
                  key: ValueKey<String>(
                    'mosaic-cut:${choice.editId}:${choice.trackId}:${clip.id}',
                  ),
                  onTap: () => Navigator.of(context).pop(choice),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: sc(8),
                      vertical: sc(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'EDIT ${choice.editId}  /  ${choice.trackId}  /  ${clip.id}',
                          style: widget.theme.value.copyWith(
                            color: widget.theme.accent,
                          ),
                        ),
                        SizedBox(height: sc(4)),
                        Text(
                          clip.source,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: widget.theme.fine,
                        ),
                        SizedBox(height: sc(3)),
                        Text(
                          'IN F${clip.inFrame}   OUT F${_sourceOut(clip)}   '
                          'CUT ${clip.durationFrames}F   ${clip.speed.canonicalMarkup}X',
                          style: widget.theme.micro,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('CANCEL'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _appendCut(
    MosaicSurfaceDocument document,
    MosaicPane pane,
    int paneNumber,
  ) async {
    final _EditCutChoice? choice = await _pickCut(document, paneNumber);
    if (choice == null || !mounted) return;

    _commit((MosaicSurfaceDocument current) {
      return current.appendCut(pane.id, choice.clip);
    });
  }

  void _setPaneCount(int count) {
    _commit((MosaicSurfaceDocument current) => current.setPaneCount(count));
  }

  void _clearPane(MosaicPane pane) {
    final bool cleared =
        _commit((MosaicSurfaceDocument current) => current.clearPane(pane.id));
    if (!cleared || !mounted) return;
    if (_selectedPaneId == pane.id) {
      setState(() {
        _selectedPaneId = null;
        _selectedClipId = null;
      });
    }
  }

  void _selectClip(String paneId, EditClip clip) {
    setState(() {
      _selectedPaneId = paneId;
      _selectedClipId = clip.id;
      _error = null;
    });
  }

  Future<int?> _customCrossfadeFrames({
    required int currentFrames,
    required int maxFrames,
  }) async {
    final int initial = currentFrames > 0
        ? currentFrames
        : maxFrames >= 48
            ? 48
            : maxFrames;
    String draft = '$initial';

    return showDialog<int>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          backgroundColor: R3Theme.panel,
          title: Text('Crossfade frames', style: widget.theme.value),
          content: TextFormField(
            key: const ValueKey<String>('mosaic-xfade-custom-field'),
            initialValue: draft,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: '1 to $maxFrames frames',
            ),
            style: widget.theme.value,
            onChanged: (String value) => draft = value,
            onFieldSubmitted: (String value) {
              final int? frames = int.tryParse(value.trim());
              if (frames != null && frames > 0 && frames <= maxFrames) {
                Navigator.of(dialogContext).pop(frames);
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('CANCEL'),
            ),
            TextButton(
              onPressed: () {
                final int? frames = int.tryParse(draft.trim());
                if (frames == null || frames <= 0 || frames > maxFrames) return;
                Navigator.of(dialogContext).pop(frames);
              },
              child: const Text('APPLY'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _choosePaneCrossfade(
    MosaicPane pane,
    EditClip left,
    EditClip right,
    int selected,
    int currentFrames,
  ) async {
    final int maxFrames = left.durationFrames < right.durationFrames
        ? left.durationFrames
        : right.durationFrames;
    int frames = selected;
    if (selected == -1) {
      final int? custom = await _customCrossfadeFrames(
        currentFrames: currentFrames,
        maxFrames: maxFrames,
      );
      if (custom == null || !mounted) return;
      frames = custom;
    }

    _commit((MosaicSurfaceDocument current) {
      return current.setCrossfadeBetween(
        pane.id,
        left.id,
        right.id,
        frames,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final MosaicSurfaceDocument? document = _parse();
    if (document == null) {
      return _message('MOSAIC LANGUAGE ERROR\n${_error ?? ''}');
    }

    final MosaicSequence mosaic = document.mosaic;
    final int end = mosaic.projectFrameCount;
    final int frame = end <= 0 ? 0 : widget.currentFrame.clamp(0, end - 1);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double previewHeight = constraints.maxHeight.isFinite
            ? (constraints.maxHeight * 0.40)
                .clamp(sc(100), sc(230))
                .toDouble()
            : sc(230);

        return Column(
          children: [
            SizedBox(
              height: previewHeight,
              child: EditVideoPreview(
                source: _workingSource,
                structuralSource: 'MOSAIC.${mosaic.id}',
                currentFrame: frame,
                isPlaying: widget.isPlaying,
                fastPreview: widget.isPlaying,
                theme: widget.theme,
                backend: widget.backend,
                resolveSource: widget.resolveSource,
              ),
            ),
            _buildLayoutBar(mosaic),
            if (_error != null)
              Container(
                width: double.infinity,
                padding: EdgeInsets.symmetric(
                  horizontal: sc(10),
                  vertical: sc(5),
                ),
                color: R3Theme.danger.withValues(alpha: 0.12),
                child: Text(
                  _error!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: widget.theme.fine.copyWith(color: R3Theme.danger),
                ),
              ),
            Expanded(
              child: Padding(
                padding: EdgeInsets.all(sc(8)),
                child: _buildPaneLayout(document, mosaic, frame),
              ),
            ),
            if (end > 0) _buildPlayhead(frame, end),
          ],
        );
      },
    );
  }

  Widget _buildLayoutBar(MosaicSequence mosaic) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(horizontal: sc(10), vertical: sc(6)),
      decoration: const BoxDecoration(
        color: R3Theme.panel,
        border: Border(
          top: BorderSide(color: R3Theme.hairline),
          bottom: BorderSide(color: R3Theme.hairline),
        ),
      ),
      child: Wrap(
        spacing: sc(7),
        runSpacing: sc(5),
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          R3MicroLabel(
            'MOSAIC ${mosaic.id}',
            theme: widget.theme,
            accent: true,
          ),
          SizedBox(width: sc(4)),
          Text('LAYOUT', style: widget.theme.micro),
          for (final int count in const <int>[1, 2, 3])
            R3Button(
              count == 1 ? '1 PANE' : '$count PANES',
              theme: widget.theme,
              compact: true,
              kind: mosaic.panes.length == count
                  ? R3ButtonKind.primary
                  : R3ButtonKind.normal,
              onPressed: widget.isPlaying || mosaic.panes.length == count
                  ? null
                  : () => _setPaneCount(count),
            ),
          SizedBox(width: sc(8)),
          Text('TIMELINE ZOOM', style: widget.theme.micro),
          SizedBox(
            width: sc(105),
            child: Slider(
              min: 0.5,
              max: 8.0,
              value: _pixelsPerFrame,
              onChanged: widget.isPlaying
                  ? null
                  : (double value) {
                      setState(() => _pixelsPerFrame = value);
                    },
            ),
          ),
          Text(
            '${mosaic.projectFrameCount}F COMPOSITION',
            style: widget.theme.micro,
          ),
        ],
      ),
    );
  }

  Widget _buildPaneLayout(
    MosaicSurfaceDocument document,
    MosaicSequence mosaic,
    int frame,
  ) {
    if (mosaic.panes.isEmpty) {
      return _message('CHOOSE A 1, 2, OR 3 PANE LAYOUT');
    }

    if (mosaic.panes.length == 1) {
      return _buildPane(document, mosaic.panes[0], 1, frame);
    }

    if (mosaic.panes.length == 2) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 14,
            child: _buildPane(document, mosaic.panes[0], 1, frame),
          ),
          SizedBox(width: sc(8)),
          Expanded(
            flex: 11,
            child: _buildPane(document, mosaic.panes[1], 2, frame),
          ),
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 14,
          child: _buildPane(document, mosaic.panes[0], 1, frame),
        ),
        SizedBox(width: sc(8)),
        Expanded(
          flex: 11,
          child: Column(
            children: [
              Expanded(
                child: _buildPane(document, mosaic.panes[1], 2, frame),
              ),
              SizedBox(height: sc(8)),
              Expanded(
                child: _buildPane(document, mosaic.panes[2], 3, frame),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPane(
    MosaicSurfaceDocument document,
    MosaicPane pane,
    int paneNumber,
    int frame,
  ) {
    final bool hasCuts = pane.clips.isNotEmpty;
    final bool paneSelected = _selectedPaneId == pane.id;
    EditClip? selected;
    if (paneSelected && _selectedClipId != null) {
      for (final EditClip clip in pane.clips) {
        if (clip.id == _selectedClipId) {
          selected = clip;
          break;
        }
      }
    }

    return Container(
      key: ValueKey<String>('mosaic-pane:${pane.id}'),
      decoration: BoxDecoration(
        color: R3Theme.bg,
        border: Border.all(
          color: hasCuts ? widget.theme.accentDim : R3Theme.hairline,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: EdgeInsets.symmetric(horizontal: sc(8), vertical: sc(5)),
            decoration: const BoxDecoration(
              color: R3Theme.panel,
              border: Border(bottom: BorderSide(color: R3Theme.hairline)),
            ),
            child: Row(
              children: [
                Text(
                  'PANE $paneNumber',
                  style: widget.theme.microAccent,
                ),
                SizedBox(width: sc(8)),
                Text(
                  '${pane.clips.length} CUT${pane.clips.length == 1 ? '' : 'S'}',
                  style: widget.theme.micro,
                ),
                if (selected != null) ...[
                  SizedBox(width: sc(10)),
                  Flexible(
                    child: Text(
                      '${selected.id}  AT ${selected.atFrame}  '
                      'IN ${selected.inFrame}  ${selected.durationFrames}F',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: widget.theme.micro.copyWith(
                        color: R3Theme.textBright,
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                if (hasCuts)
                  R3Button(
                    'CLEAR',
                    theme: widget.theme,
                    compact: true,
                    onPressed: widget.isPlaying ? null : () => _clearPane(pane),
                  ),
                R3Button(
                  'ADD CUT',
                  theme: widget.theme,
                  compact: true,
                  kind: hasCuts ? R3ButtonKind.normal : R3ButtonKind.primary,
                  onPressed: widget.isPlaying
                      ? null
                      : () => _appendCut(document, pane, paneNumber),
                ),
              ],
            ),
          ),
          Expanded(
            child: !hasCuts
                ? InkWell(
                    onTap: widget.isPlaying
                        ? null
                        : () => _appendCut(document, pane, paneNumber),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.add_to_queue,
                            color: widget.theme.accentDim,
                            size: sc(25),
                          ),
                          SizedBox(height: sc(6)),
                          Text('EMPTY', style: widget.theme.value),
                          SizedBox(height: sc(3)),
                          Text(
                            'ADD CUT to start this pane timeline',
                            style: widget.theme.micro,
                          ),
                        ],
                      ),
                    ),
                  )
                : _buildPaneTimeline(document, pane, frame),
          ),
        ],
      ),
    );
  }

  Widget _buildPaneTimeline(
    MosaicSurfaceDocument document,
    MosaicPane pane,
    int frame,
  ) {
    final List<EditClip> ordered = List<EditClip>.from(pane.clips)
      ..sort((EditClip a, EditClip b) {
        final int time = a.atFrame.compareTo(b.atFrame);
        if (time != 0) return time;
        return a.id.compareTo(b.id);
      });

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double viewportWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : sc(300);
        final double viewportHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : sc(90);
        final int timelineFrames = math.max(
          pane.projectFrameCount,
          frame + 1,
        );
        final double timelineWidth = math.max(
          viewportWidth,
          math.max(1, timelineFrames) * _pixelsPerFrame + sc(36),
        );
        final double laneAvailable = math.max(
          sc(26),
          viewportHeight - _kRulerHeight - sc(6),
        );
        final double clipHeight = math.min(sc(50), laneAvailable);
        final double clipTop = _kRulerHeight +
            math.max(0.0, (laneAvailable - clipHeight) / 2.0);

        final List<Widget> overlays = <Widget>[];
        for (int index = 0; index < ordered.length - 1; index++) {
          overlays.add(
            _buildBetweenCrossfade(
              document: document,
              pane: pane,
              left: ordered[index],
              right: ordered[index + 1],
              clipTop: clipTop,
            ),
          );
        }

        return ClipRect(
          child: SingleChildScrollView(
            key: ValueKey<String>('mosaic-pane-timeline:${pane.id}'),
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: timelineWidth,
              height: viewportHeight,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 0,
                    top: 0,
                    right: 0,
                    height: _kRulerHeight,
                    child: GestureDetector(
                      key: ValueKey<String>('mosaic-ruler:${pane.id}'),
                      behavior: HitTestBehavior.opaque,
                      onTapDown: widget.isPlaying
                          ? null
                          : (TapDownDetails details) {
                              final int seek =
                                  (details.localPosition.dx / _pixelsPerFrame)
                                      .floor()
                                      .clamp(0, math.max(0, timelineFrames - 1));
                              widget.onSeek(seek);
                            },
                      child: CustomPaint(
                        painter: _MosaicRulerPainter(
                          pixelsPerFrame: _pixelsPerFrame,
                          frames: timelineFrames,
                          theme: widget.theme,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    top: _kRulerHeight,
                    right: 0,
                    bottom: 0,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: R3Theme.bg,
                        border: Border(
                          top: BorderSide(
                            color: R3Theme.hairline.withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                    ),
                  ),
                  for (final EditClip clip in ordered)
                    Positioned(
                      left: clip.atFrame * _pixelsPerFrame,
                      top: clipTop,
                      child: _MosaicTimelineClip(
                        key: ValueKey<String>(
                          'mosaic-timeline-clip:${pane.id}:${clip.id}',
                        ),
                        paneId: pane.id,
                        clip: clip,
                        incomingCrossfadeFrames:
                            document.incomingCrossfadeFrames(pane.id, clip.id),
                        pixelsPerFrame: _pixelsPerFrame,
                        height: clipHeight,
                        selected: _selectedPaneId == pane.id &&
                            _selectedClipId == clip.id,
                        enabled: !widget.isPlaying,
                        theme: widget.theme,
                        onSelect: () => _selectClip(pane.id, clip),
                        onMove: (int atFrame) {
                          _commit((MosaicSurfaceDocument current) {
                            return current.moveClip(pane.id, clip.id, atFrame);
                          });
                        },
                        onTrimStart: (int atFrame) {
                          _commit((MosaicSurfaceDocument current) {
                            return current.trimClipStart(
                              pane.id,
                              clip.id,
                              atFrame,
                            );
                          });
                        },
                        onTrimEnd: (int endFrameExclusive) {
                          _commit((MosaicSurfaceDocument current) {
                            return current.trimClipEnd(
                              pane.id,
                              clip.id,
                              endFrameExclusive,
                            );
                          });
                        },
                      ),
                    ),
                  ...overlays,
                  if (frame >= 0)
                    Positioned(
                      left: frame * _pixelsPerFrame,
                      top: 0,
                      bottom: 0,
                      width: 1,
                      child: IgnorePointer(
                        child: Container(color: widget.theme.accent),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBetweenCrossfade({
    required MosaicSurfaceDocument document,
    required MosaicPane pane,
    required EditClip left,
    required EditClip right,
    required double clipTop,
  }) {
    final int current = document.incomingCrossfadeFrames(pane.id, right.id);
    final int maxFrames = left.durationFrames < right.durationFrames
        ? left.durationFrames
        : right.durationFrames;
    final double overlapWidth = current * _pixelsPerFrame;
    final double centerFrame = current > 0
        ? right.atFrame + current / 2.0
        : right.atFrame.toDouble();
    final double badgeWidth = sc(58);

    return Positioned(
      left: math.max(0.0, centerFrame * _pixelsPerFrame - badgeWidth / 2.0),
      top: math.max(_kRulerHeight, clipTop - sc(2)),
      width: badgeWidth,
      height: sc(22),
      child: PopupMenuButton<int>(
        key: ValueKey<String>('mosaic-xfade:${pane.id}:${left.id}:${right.id}'),
        tooltip: 'Crossfade between ${left.id} and ${right.id}',
        color: R3Theme.panelHi,
        enabled: !widget.isPlaying,
        padding: EdgeInsets.zero,
        onSelected: (int value) {
          _choosePaneCrossfade(pane, left, right, value, current);
        },
        itemBuilder: (_) => <PopupMenuEntry<int>>[
          PopupMenuItem<int>(
            enabled: false,
            height: sc(30),
            child: Text('XFADE BETWEEN CUTS', style: widget.theme.microAccent),
          ),
          PopupMenuItem<int>(
            value: 0,
            child: Text(current == 0 ? '✓  HARD CUT' : 'HARD CUT'),
          ),
          for (final int frames in const <int>[12, 24, 48, 72])
            PopupMenuItem<int>(
              value: frames,
              enabled: frames <= maxFrames,
              child: Text(
                current == frames ? '✓  $frames FRAMES' : '$frames FRAMES',
              ),
            ),
          const PopupMenuDivider(),
          PopupMenuItem<int>(
            value: -1,
            enabled: maxFrames > 0,
            child: const Text('CUSTOM…'),
          ),
        ],
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: current > 0
                ? R3Theme.ribbonWindow.withValues(alpha: 0.92)
                : R3Theme.panelHi.withValues(alpha: 0.95),
            border: Border.all(
              color: current > 0 ? R3Theme.ribbonWindow : R3Theme.textDim,
            ),
            borderRadius: BorderRadius.circular(3),
            boxShadow: const <BoxShadow>[
              BoxShadow(blurRadius: 2, spreadRadius: 0),
            ],
          ),
          child: Text(
            current > 0 ? 'XFADE\n${current}F' : 'CUT / XF',
            textAlign: TextAlign.center,
            style: widget.theme.micro.copyWith(
              color: current > 0 ? R3Theme.textBright : R3Theme.textMid,
              height: 0.95,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlayhead(int frame, int end) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: sc(12), vertical: sc(5)),
      decoration: const BoxDecoration(
        color: R3Theme.panel,
        border: Border(top: BorderSide(color: R3Theme.hairline)),
      ),
      child: Row(
        children: [
          Text('MOSAIC PLAYHEAD  F$frame', style: widget.theme.micro),
          Expanded(
            child: Slider(
              value: frame.toDouble(),
              min: 0,
              max: (end - 1).toDouble(),
              onChanged: widget.isPlaying
                  ? null
                  : (double value) => widget.onSeek(value.round()),
            ),
          ),
          Text('${end}F', style: widget.theme.micro),
        ],
      ),
    );
  }

  Widget _message(String text) {
    return Container(
      color: R3Theme.bg,
      alignment: Alignment.center,
      padding: EdgeInsets.all(sc(24)),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: widget.theme.value.copyWith(color: R3Theme.textMid),
      ),
    );
  }
}

class _MosaicTimelineClip extends StatefulWidget {
  final String paneId;
  final EditClip clip;
  final int incomingCrossfadeFrames;
  final double pixelsPerFrame;
  final double height;
  final bool selected;
  final bool enabled;
  final R3Theme theme;
  final VoidCallback onSelect;
  final ValueChanged<int> onMove;
  final ValueChanged<int> onTrimStart;
  final ValueChanged<int> onTrimEnd;

  const _MosaicTimelineClip({
    super.key,
    required this.paneId,
    required this.clip,
    required this.incomingCrossfadeFrames,
    required this.pixelsPerFrame,
    required this.height,
    required this.selected,
    required this.enabled,
    required this.theme,
    required this.onSelect,
    required this.onMove,
    required this.onTrimStart,
    required this.onTrimEnd,
  });

  @override
  State<_MosaicTimelineClip> createState() => _MosaicTimelineClipState();
}

enum _MosaicClipDragMode { none, move, trimStart, trimEnd }

class _MosaicTimelineClipState extends State<_MosaicTimelineClip> {
  _MosaicClipDragMode _mode = _MosaicClipDragMode.none;
  double _dragPixels = 0.0;

  int get _deltaFrames => (_dragPixels / widget.pixelsPerFrame).round();

  int get _previewAt {
    switch (_mode) {
      case _MosaicClipDragMode.move:
      case _MosaicClipDragMode.trimStart:
        return math.max(0, widget.clip.atFrame + _deltaFrames);
      case _MosaicClipDragMode.none:
      case _MosaicClipDragMode.trimEnd:
        return widget.clip.atFrame;
    }
  }

  int get _previewDuration {
    switch (_mode) {
      case _MosaicClipDragMode.trimStart:
        final int effectiveDelta = _previewAt - widget.clip.atFrame;
        return math.max(1, widget.clip.durationFrames - effectiveDelta);
      case _MosaicClipDragMode.trimEnd:
        return math.max(1, widget.clip.durationFrames + _deltaFrames);
      case _MosaicClipDragMode.none:
      case _MosaicClipDragMode.move:
        return widget.clip.durationFrames;
    }
  }

  void _start(_MosaicClipDragMode mode) {
    if (!widget.enabled) return;
    widget.onSelect();
    setState(() {
      _mode = mode;
      _dragPixels = 0.0;
    });
  }

  void _update(DragUpdateDetails details) {
    if (_mode == _MosaicClipDragMode.none) return;
    setState(() => _dragPixels += details.delta.dx);
  }

  void _finish() {
    final _MosaicClipDragMode mode = _mode;
    final int previewAt = _previewAt;
    final int previewDuration = _previewDuration;
    final int delta = _deltaFrames;

    setState(() {
      _mode = _MosaicClipDragMode.none;
      _dragPixels = 0.0;
    });

    if (delta == 0) return;
    switch (mode) {
      case _MosaicClipDragMode.move:
        widget.onMove(previewAt);
        break;
      case _MosaicClipDragMode.trimStart:
        widget.onTrimStart(previewAt);
        break;
      case _MosaicClipDragMode.trimEnd:
        widget.onTrimEnd(widget.clip.atFrame + previewDuration);
        break;
      case _MosaicClipDragMode.none:
        break;
    }
  }

  GestureDetector _dragRegion(
    _MosaicClipDragMode mode,
    Widget child,
  ) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.enabled ? widget.onSelect : null,
      onHorizontalDragStart: widget.enabled ? (_) => _start(mode) : null,
      onHorizontalDragUpdate: widget.enabled ? _update : null,
      onHorizontalDragEnd: widget.enabled ? (_) => _finish() : null,
      onHorizontalDragCancel: widget.enabled
          ? () {
              setState(() {
                _mode = _MosaicClipDragMode.none;
                _dragPixels = 0.0;
              });
            }
          : null,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final double width = math.max(
      sc(22),
      _previewDuration * widget.pixelsPerFrame,
    );
    final double moveOffset =
        (_previewAt - widget.clip.atFrame) * widget.pixelsPerFrame;
    final Color border = widget.selected
        ? widget.theme.accent
        : R3Theme.ribbonMedia;
    final Color fill = widget.selected
        ? widget.theme.accentFaint
        : R3Theme.ribbonMedia.withValues(alpha: 0.30);
    final double transitionWidth = math.min(
      math.max(0.0, width - sc(12)),
      widget.incomingCrossfadeFrames * widget.pixelsPerFrame,
    );
    final int sourceOut = widget.clip.sourceFrameAtProjectOffset(
      widget.clip.durationFrames - 1,
    );

    return Transform.translate(
      offset: Offset(moveOffset, 0),
      child: SizedBox(
        width: width,
        height: widget.height,
        child: Stack(
          children: [
            Positioned.fill(
              child: _dragRegion(
                _MosaicClipDragMode.move,
                Container(
                  key: ValueKey<String>(
                    'mosaic-cut-assignment:${widget.clip.id}',
                  ),
                  padding: EdgeInsets.fromLTRB(sc(8), sc(5), sc(8), sc(4)),
                  decoration: BoxDecoration(
                    color: fill,
                    border: Border.all(color: border),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        widget.clip.id,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: widget.theme.fine.copyWith(
                          color: widget.selected
                              ? widget.theme.accent
                              : R3Theme.textBright,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (widget.height >= sc(40)) ...[
                        SizedBox(height: sc(2)),
                        Text(
                          'IN ${widget.clip.inFrame}  OUT $sourceOut  '
                          '${widget.clip.durationFrames}F',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: widget.theme.micro,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (transitionWidth > 0)
              Positioned(
                left: sc(6),
                top: 0,
                bottom: 0,
                width: transitionWidth,
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: const _MosaicTransitionPainter(
                      color: R3Theme.ribbonWindow,
                    ),
                  ),
                ),
              ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: sc(7),
              child: MouseRegion(
                key: ValueKey<String>(
                  'mosaic-clip:${widget.paneId}:${widget.clip.id}-in-handle',
                ),
                cursor: widget.enabled
                    ? SystemMouseCursors.resizeLeftRight
                    : SystemMouseCursors.basic,
                child: _dragRegion(
                  _MosaicClipDragMode.trimStart,
                  Container(
                    color: border.withValues(
                      alpha: widget.selected ? 0.62 : 0.32,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: sc(7),
              child: MouseRegion(
                key: ValueKey<String>(
                  'mosaic-clip:${widget.paneId}:${widget.clip.id}-out-handle',
                ),
                cursor: widget.enabled
                    ? SystemMouseCursors.resizeLeftRight
                    : SystemMouseCursors.basic,
                child: _dragRegion(
                  _MosaicClipDragMode.trimEnd,
                  Container(
                    color: border.withValues(
                      alpha: widget.selected ? 0.62 : 0.32,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MosaicRulerPainter extends CustomPainter {
  final double pixelsPerFrame;
  final int frames;
  final R3Theme theme;

  const _MosaicRulerPainter({
    required this.pixelsPerFrame,
    required this.frames,
    required this.theme,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = R3Theme.panel);

    final int major = _majorStep(pixelsPerFrame);
    final int minor = math.max(1, major ~/ 5);
    final TextPainter text = TextPainter(
      textDirection: TextDirection.ltr,
      maxLines: 1,
    );

    for (int frame = 0; frame <= frames + major; frame += minor) {
      final double x = frame * pixelsPerFrame;
      if (x > size.width) break;
      final bool isMajor = frame % major == 0;
      canvas.drawLine(
        Offset(x, isMajor ? sc(7) : sc(13)),
        Offset(x, size.height),
        Paint()
          ..color = isMajor ? R3Theme.textDim : R3Theme.hairline
          ..strokeWidth = 1,
      );

      if (isMajor) {
        text.text = TextSpan(
          text: '$frame',
          style: theme.micro.copyWith(color: R3Theme.textDim),
        );
        text.layout();
        text.paint(canvas, Offset(x + sc(2), 0));
      }
    }
  }

  static int _majorStep(double pixelsPerFrame) {
    if (pixelsPerFrame >= 6) return 10;
    if (pixelsPerFrame >= 2) return 30;
    if (pixelsPerFrame >= 1) return 60;
    return 120;
  }

  @override
  bool shouldRepaint(covariant _MosaicRulerPainter oldDelegate) =>
      oldDelegate.pixelsPerFrame != pixelsPerFrame ||
      oldDelegate.frames != frames ||
      oldDelegate.theme.accent != theme.accent;
}

class _MosaicTransitionPainter extends CustomPainter {
  final Color color;

  const _MosaicTransitionPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color.withValues(alpha: 0.85)
      ..strokeWidth = 1;
    for (double x = -size.height; x < size.width; x += sc(6)) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MosaicTransitionPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _EditCutChoice {
  final String editId;
  final String trackId;
  final EditClip clip;

  const _EditCutChoice({
    required this.editId,
    required this.trackId,
    required this.clip,
  });
}
