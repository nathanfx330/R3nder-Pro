// ./lib/mosaic_surface.dart
//
// GUI surface for canonical MOSAIC / PANE / CLIP authoring.
//
// The script remains canonical, but the authoring abstraction is visual:
// choose a one, two, or three-pane layout and assign already-authored EDIT cuts
// to those panes. A pane assignment copies the cut's source IN, duration, and
// speed at composition frame zero. Raw AT and DURATION fields are deliberately
// not exposed here.

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
  late String _workingSource;
  String? _error;

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

  void _commit(String Function(MosaicSurfaceDocument document) operation) {
    final MosaicSurfaceDocument? document = _parse();
    if (document == null) {
      setState(() {});
      return;
    }

    try {
      final String next = operation(document);
      MosaicSurfaceDocument.parse(next, widget.mosaicId);
      setState(() {
        _workingSource = next;
        _error = null;
      });
      widget.onSourceChanged(next);
    } catch (error) {
      setState(() => _error = '$error');
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
          title: Text('Assign cut to Pane $paneNumber', style: widget.theme.value),
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

  Future<void> _assignPane(
    MosaicSurfaceDocument document,
    MosaicPane pane,
    int paneNumber,
  ) async {
    final _EditCutChoice? choice = await _pickCut(document, paneNumber);
    if (choice == null || !mounted) return;

    _commit((MosaicSurfaceDocument current) {
      return current.assignCut(pane.id, choice.clip);
    });
  }

  void _setPaneCount(int count) {
    _commit((MosaicSurfaceDocument current) => current.setPaneCount(count));
  }

  void _clearPane(MosaicPane pane) {
    _commit((MosaicSurfaceDocument current) => current.clearPane(pane.id));
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
                child: _buildPaneLayout(document, mosaic),
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
      padding: EdgeInsets.symmetric(horizontal: sc(10), vertical: sc(7)),
      decoration: const BoxDecoration(
        color: R3Theme.panel,
        border: Border(
          top: BorderSide(color: R3Theme.hairline),
          bottom: BorderSide(color: R3Theme.hairline),
        ),
      ),
      child: Wrap(
        spacing: sc(7),
        runSpacing: sc(6),
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
  ) {
    if (mosaic.panes.isEmpty) {
      return _message('CHOOSE A 1, 2, OR 3 PANE LAYOUT');
    }

    if (mosaic.panes.length == 1) {
      return _buildPane(document, mosaic.panes[0], 1);
    }

    if (mosaic.panes.length == 2) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 14,
            child: _buildPane(document, mosaic.panes[0], 1),
          ),
          SizedBox(width: sc(8)),
          Expanded(
            flex: 11,
            child: _buildPane(document, mosaic.panes[1], 2),
          ),
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 14,
          child: _buildPane(document, mosaic.panes[0], 1),
        ),
        SizedBox(width: sc(8)),
        Expanded(
          flex: 11,
          child: Column(
            children: [
              Expanded(
                child: _buildPane(document, mosaic.panes[1], 2),
              ),
              SizedBox(height: sc(8)),
              Expanded(
                child: _buildPane(document, mosaic.panes[2], 3),
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
  ) {
    final EditClip? cut = pane.clips.isEmpty ? null : pane.clips.first;
    final bool legacyMulti = pane.clips.length > 1;

    return Container(
      key: ValueKey<String>('mosaic-pane:${pane.id}'),
      decoration: BoxDecoration(
        color: R3Theme.bg,
        border: Border.all(
          color: cut == null ? R3Theme.hairline : widget.theme.accentDim,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: EdgeInsets.symmetric(horizontal: sc(9), vertical: sc(7)),
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
                if (legacyMulti) ...[
                  SizedBox(width: sc(8)),
                  Text(
                    'LEGACY ${pane.clips.length} CLIPS',
                    style: widget.theme.micro.copyWith(color: R3Theme.warn),
                  ),
                ],
                const Spacer(),
                if (cut != null)
                  R3Button(
                    'CLEAR',
                    theme: widget.theme,
                    compact: true,
                    onPressed: widget.isPlaying ? null : () => _clearPane(pane),
                  ),
                R3Button(
                  cut == null ? 'ASSIGN CUT' : 'CHANGE CUT',
                  theme: widget.theme,
                  compact: true,
                  kind: cut == null ? R3ButtonKind.primary : R3ButtonKind.normal,
                  onPressed: widget.isPlaying
                      ? null
                      : () => _assignPane(document, pane, paneNumber),
                ),
              ],
            ),
          ),
          Expanded(
            child: cut == null
                ? InkWell(
                    onTap: widget.isPlaying
                        ? null
                        : () => _assignPane(document, pane, paneNumber),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.add_to_queue,
                            color: widget.theme.accentDim,
                            size: sc(28),
                          ),
                          SizedBox(height: sc(8)),
                          Text('EMPTY', style: widget.theme.value),
                          SizedBox(height: sc(4)),
                          Text(
                            'Assign an already-trimmed EDIT cut',
                            style: widget.theme.micro,
                          ),
                        ],
                      ),
                    ),
                  )
                : _buildAssignedCut(cut),
          ),
        ],
      ),
    );
  }

  Widget _buildAssignedCut(EditClip clip) {
    final int out = _sourceOut(clip);
    return Padding(
      key: ValueKey<String>('mosaic-cut-assignment:${clip.id}'),
      padding: EdgeInsets.all(sc(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            clip.id,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget.theme.value.copyWith(
              color: widget.theme.accent,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: sc(5)),
          Text(
            clip.source,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: widget.theme.fine.copyWith(color: R3Theme.textBright),
          ),
          SizedBox(height: sc(10)),
          Wrap(
            spacing: sc(12),
            runSpacing: sc(5),
            children: [
              Text('IN F${clip.inFrame}', style: widget.theme.microAccent),
              Text('OUT F$out', style: widget.theme.microAccent),
              Text('CUT ${clip.durationFrames}F', style: widget.theme.micro),
              Text('${clip.speed.canonicalMarkup}X', style: widget.theme.micro),
            ],
          ),
        ],
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
