// ./lib/mosaic_surface.dart
//
// GUI surface for canonical MOSAIC / PANE / CLIP authoring.
//
// This widget owns only transient selection and dialog state. Every durable
// operation goes through MosaicSurfaceDocument and immediately emits complete
// script text. Preview is the same structural compositor used when MOSAIC is
// nested inside an EDIT, driven by the parent EditWorkspace ProjectClock.

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

  Future<void> _addPane(MosaicSurfaceDocument document) async {
    if (document.mosaic.panes.length >= 3) {
      setState(() => _error = 'A MOSAIC supports at most 3 panes.');
      return;
    }
    final _SourcePlacement? placement = await _pickPlacement(
      document,
      title: 'Add pane source',
      initialAt: 0,
    );
    if (placement == null || !mounted) return;

    _commit((MosaicSurfaceDocument current) {
      final String paneId = current.nextPaneId();
      return current.addPane(
        paneId: paneId,
        clipId: 'source',
        structuralSource: placement.source,
        atFrame: placement.atFrame,
        durationFrames: placement.durationFrames,
      );
    });
  }

  Future<void> _addClip(
    MosaicSurfaceDocument document,
    MosaicPane pane,
  ) async {
    final _SourcePlacement? placement = await _pickPlacement(
      document,
      title: 'Add clip to ${pane.id}',
      initialAt: widget.currentFrame,
    );
    if (placement == null || !mounted) return;

    _commit((MosaicSurfaceDocument current) {
      return current.addClip(
        paneId: pane.id,
        clipId: current.nextClipId(pane.id),
        structuralSource: placement.source,
        atFrame: placement.atFrame,
        inFrame: 0,
        durationFrames: placement.durationFrames,
      );
    });
  }

  Future<_SourcePlacement?> _pickPlacement(
    MosaicSurfaceDocument document, {
    required String title,
    required int initialAt,
  }) async {
    final List<StructuralSourceRef> choices =
        document.availableStructuralSources();
    if (choices.isEmpty) {
      setState(() => _error = 'No EDIT or other MOSAIC source is available.');
      return null;
    }

    String selected = choices.first.canonicalSource;
    final TextEditingController atController =
        TextEditingController(text: '$initialAt');
    final TextEditingController durationController = TextEditingController(
      text: '${document.model.structuralSourceFrameCount(choices.first)}',
    );

    final _SourcePlacement? result = await showDialog<_SourcePlacement>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            return AlertDialog(
              backgroundColor: R3Theme.panel,
              title: Text(title, style: widget.theme.value),
              content: SizedBox(
                width: sc(420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('SOURCE', style: widget.theme.micro),
                    DropdownButton<String>(
                      value: selected,
                      isExpanded: true,
                      dropdownColor: R3Theme.panel,
                      style: widget.theme.value,
                      items: [
                        for (final StructuralSourceRef ref in choices)
                          DropdownMenuItem<String>(
                            value: ref.canonicalSource,
                            child: Text(ref.canonicalSource),
                          ),
                      ],
                      onChanged: (String? value) {
                        if (value == null) return;
                        final StructuralSourceRef ref =
                            StructuralSourceRef.tryParse(value)!;
                        setDialogState(() {
                          selected = value;
                          durationController.text =
                              '${document.model.structuralSourceFrameCount(ref)}';
                        });
                      },
                    ),
                    SizedBox(height: sc(10)),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: atController,
                            keyboardType: TextInputType.number,
                            style: widget.theme.value,
                            decoration:
                                const InputDecoration(labelText: 'AT FRAME'),
                          ),
                        ),
                        SizedBox(width: sc(12)),
                        Expanded(
                          child: TextField(
                            controller: durationController,
                            keyboardType: TextInputType.number,
                            style: widget.theme.value,
                            decoration:
                                const InputDecoration(labelText: 'DURATION'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('CANCEL'),
                ),
                TextButton(
                  onPressed: () {
                    final int? at = int.tryParse(atController.text.trim());
                    final int? duration =
                        int.tryParse(durationController.text.trim());
                    if (at == null ||
                        at < 0 ||
                        duration == null ||
                        duration <= 0) {
                      return;
                    }
                    Navigator.of(context).pop(
                      _SourcePlacement(
                        source: selected,
                        atFrame: at,
                        durationFrames: duration,
                      ),
                    );
                  },
                  child: const Text('ADD'),
                ),
              ],
            );
          },
        );
      },
    );

    atController.dispose();
    durationController.dispose();
    return result;
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
        // The old fixed sc(230) monitor reserved 287.5 logical pixels at the
        // current UI scale. Inside EditorScreen that could leave less than one
        // compact control row for PANE authoring. The monitor is presentation,
        // not project geometry, so it may shrink with the available workspace
        // while the compositor still renders the same canonical frame.
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
            Container(
              width: double.infinity,
              padding: EdgeInsets.symmetric(
                horizontal: sc(10),
                vertical: sc(7),
              ),
              decoration: const BoxDecoration(
                color: R3Theme.panel,
                border: Border(
                  top: BorderSide(color: R3Theme.hairline),
                  bottom: BorderSide(color: R3Theme.hairline),
                ),
              ),
              child: Wrap(
                spacing: sc(8),
                runSpacing: sc(6),
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  R3MicroLabel(
                    'MOSAIC ${mosaic.id}',
                    theme: widget.theme,
                    accent: true,
                  ),
                  Text(
                    '${mosaic.panes.length} PANE${mosaic.panes.length == 1 ? '' : 'S'}   '
                    '${mosaic.projectFrameCount} FRAMES',
                    style: widget.theme.micro,
                  ),
                  R3Button(
                    'ADD PANE',
                    theme: widget.theme,
                    compact: true,
                    onPressed: mosaic.panes.length >= 3
                        ? null
                        : () => _addPane(document),
                  ),
                ],
              ),
            ),
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
              child: mosaic.panes.isEmpty
                  ? _message(
                      'EMPTY MOSAIC\n\nADD PANE chooses an EDIT or MOSAIC source.',
                    )
                  : Padding(
                      padding: EdgeInsets.all(sc(8)),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (int i = 0; i < mosaic.panes.length; i++) ...[
                            if (i > 0) SizedBox(width: sc(8)),
                            Expanded(
                              flex: i == 0 && mosaic.panes.length > 1 ? 14 : 11,
                              child: _buildPane(document, mosaic.panes[i]),
                            ),
                          ],
                        ],
                      ),
                    ),
            ),
            if (end > 0)
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: sc(12),
                  vertical: sc(5),
                ),
                decoration: const BoxDecoration(
                  color: R3Theme.panel,
                  border: Border(top: BorderSide(color: R3Theme.hairline)),
                ),
                child: Row(
                  children: [
                    Text('F$frame', style: widget.theme.micro),
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
                    Text('/ $end', style: widget.theme.micro),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildPane(MosaicSurfaceDocument document, MosaicPane pane) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool compact = constraints.maxHeight < sc(120);
        final bool headerOnly = constraints.maxHeight < sc(62);

        return Container(
          key: ValueKey<String>('mosaic-pane:${pane.id}'),
          decoration: BoxDecoration(
            color: R3Theme.bg,
            border: Border.all(color: R3Theme.hairline),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: sc(8),
                  vertical: compact ? sc(2) : sc(6),
                ),
                decoration: const BoxDecoration(
                  color: R3Theme.panel,
                  border: Border(
                    bottom: BorderSide(color: R3Theme.hairline),
                  ),
                ),
                child: Row(
                  children: [
                    // Dynamic ids keep their authored case. R3MicroLabel
                    // uppercases its whole string, which turned pane id "pane"
                    // into the confusing visible label "PANE PANE".
                    Text(
                      'PANE ${pane.id}',
                      style: widget.theme.microAccent,
                    ),
                    const Spacer(),
                    if (!headerOnly)
                      R3Button(
                        'ADD CLIP',
                        theme: widget.theme,
                        compact: true,
                        onPressed: () => _addClip(document, pane),
                      ),
                  ],
                ),
              ),
              if (!headerOnly)
                Expanded(
                  child: pane.clips.isEmpty
                      ? Center(
                          child: Text('NO CLIPS', style: widget.theme.micro),
                        )
                      : ListView.separated(
                          padding: EdgeInsets.all(sc(7)),
                          itemCount: pane.clips.length,
                          separatorBuilder: (_, __) => SizedBox(height: sc(6)),
                          itemBuilder: (BuildContext context, int index) {
                            return _buildClip(
                              document,
                              pane,
                              pane.clips[index],
                            );
                          },
                        ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildClip(
    MosaicSurfaceDocument document,
    MosaicPane pane,
    EditClip clip,
  ) {
    final List<StructuralSourceRef> choices =
        document.availableStructuralSources();
    final bool currentAvailable = choices.any(
      (StructuralSourceRef ref) => ref.canonicalSource == clip.source,
    );
    final List<String> sources = <String>[
      if (!currentAvailable) clip.source,
      ...choices.map((StructuralSourceRef ref) => ref.canonicalSource),
    ];

    return Container(
      key: ValueKey<String>('mosaic-clip:${pane.id}:${clip.id}'),
      padding: EdgeInsets.all(sc(7)),
      decoration: BoxDecoration(
        color: R3Theme.panel,
        border: Border.all(color: R3Theme.hairline),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(clip.id, style: widget.theme.value),
              const Spacer(),
              Text(
                'AT ${clip.atFrame}   IN ${clip.inFrame}   '
                'DUR ${clip.durationFrames}   ${clip.speed.canonicalMarkup}X',
                style: widget.theme.micro,
              ),
            ],
          ),
          SizedBox(height: sc(5)),
          DropdownButton<String>(
            key: ValueKey<String>('mosaic-source:${pane.id}:${clip.id}'),
            value: clip.source,
            isExpanded: true,
            dropdownColor: R3Theme.panel,
            style: widget.theme.value,
            underline: Container(height: 1, color: R3Theme.hairline),
            items: [
              for (final String source in sources)
                DropdownMenuItem<String>(
                  value: source,
                  child: Text(source, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: widget.isPlaying
                ? null
                : (String? value) {
                    if (value == null || value == clip.source) return;
                    _commit((MosaicSurfaceDocument current) {
                      return current.setClipSource(pane.id, clip.id, value);
                    });
                  },
          ),
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

class _SourcePlacement {
  final String source;
  final int atFrame;
  final int durationFrames;

  const _SourcePlacement({
    required this.source,
    required this.atFrame,
    required this.durationFrames,
  });
}
