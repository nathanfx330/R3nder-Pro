// ./lib/edit_card_cue_controls.dart
//
// GUI authoring controls for clip-local CARD cues in the EDIT inspector.
//
// This widget owns only transient form state. Every durable change is returned
// to EditSurface as a CardRequest and is serialized into the canonical CLIP
// source by edit_cue_authoring.dart.

import 'package:flutter/material.dart';

import 'edit_cue.dart';
import 'edit_surface_model.dart';
import 'presentation_requests.dart';
import 'ui_theme.dart';

typedef EditCardCueChanged = void Function(int cueIndex, CardRequest card);

class EditCardCueControls extends StatefulWidget {
  const EditCardCueControls({
    super.key,
    required this.clip,
    required this.cues,
    required this.playheadFrame,
    required this.theme,
    required this.imageOptions,
    required this.onAddAtPlayhead,
    required this.onChanged,
    required this.onDeleted,
  });

  final EditSurfaceClip clip;
  final List<EditCardCue> cues;
  final int playheadFrame;
  final R3Theme theme;

  /// Returns workspace-relative image paths when the author opens a CARD form.
  /// The directory is scanned on demand rather than on every EDIT rebuild.
  final List<String> Function()? imageOptions;

  /// Null while playback is running or when the playhead is outside the CLIP.
  final ValueChanged<CardRequest>? onAddAtPlayhead;
  final EditCardCueChanged? onChanged;
  final ValueChanged<int>? onDeleted;

  @override
  State<EditCardCueControls> createState() => _EditCardCueControlsState();
}

class _EditCardCueControlsState extends State<EditCardCueControls> {
  int? get _playheadSourceFrame {
    final int frame = widget.playheadFrame;
    if (frame < widget.clip.atFrame || frame >= widget.clip.endFrameExclusive) {
      return null;
    }
    return widget.clip.clip.sourceFrameAtProjectOffset(frame - widget.clip.atFrame);
  }

  Future<CardRequest?> _editCard({
    required int sourceFrame,
    CardRequest? existing,
  }) async {
    final List<String> images = <String>{
      ...?widget.imageOptions?.call(),
      if (existing != null && existing.image.trim().isNotEmpty)
        existing.image.trim(),
    }.toList()
      ..sort();

    final int argb = existing?.panelColor.toARGB32() ?? 0xFF1E1E26;
    final int red = (argb >> 16) & 0xFF;
    final int green = (argb >> 8) & 0xFF;
    final int blue = argb & 0xFF;

    final TextEditingController image = TextEditingController(
      text: existing?.image ?? (images.isEmpty ? '' : images.first),
    );
    final TextEditingController hold = TextEditingController(
      text: '${existing?.holdFrames ?? 90}',
    );
    final TextEditingController rgb = TextEditingController(
      text: '$red,$green,$blue',
    );
    final TextEditingController heading = TextEditingController(
      text: existing?.heading ?? '',
    );
    final TextEditingController body = TextEditingController(
      text: existing?.body ?? '',
    );

    try {
      return await showDialog<CardRequest>(
        context: context,
        builder: (BuildContext dialogContext) {
          String? errorText;

          return StatefulBuilder(
            builder: (
              BuildContext context,
              void Function(VoidCallback fn) setDialogState,
            ) {
              void apply() {
                final String imageValue = image.text.trim();
                final int? holdFrames = int.tryParse(hold.text.trim());
                final List<String> channels = rgb.text
                    .split(',')
                    .map((String value) => value.trim())
                    .toList(growable: false);
                final List<int?> parsed = channels
                    .map((String value) => int.tryParse(value))
                    .toList(growable: false);

                String? problem;
                if (imageValue.isEmpty ||
                    imageValue.contains(':') ||
                    imageValue.contains(']') ||
                    imageValue.contains('\n') ||
                    imageValue.contains('\r')) {
                  problem = 'Choose one image path from the workspace images folder.';
                } else if (holdFrames == null || holdFrames < 0) {
                  problem = 'Hold must be zero or more frames.';
                } else if (channels.length != 3 ||
                    parsed.length != 3 ||
                    parsed.any((int? value) =>
                        value == null || value < 0 || value > 255)) {
                  problem = 'Color must be r,g,b with values from 0 to 255.';
                } else if (heading.text.contains(':') ||
                    heading.text.contains(']') ||
                    heading.text.contains('\n') ||
                    heading.text.contains('\r')) {
                  problem = 'Heading cannot contain colon, ] or a newline.';
                } else if (body.text.contains('[/CARD]')) {
                  problem = 'Body cannot contain [/CARD].';
                }

                if (problem != null) {
                  setDialogState(() => errorText = problem);
                  return;
                }

                Navigator.of(dialogContext).pop(
                  CardRequest(
                    image: imageValue,
                    holdFrames: holdFrames!,
                    panelColor: Color.fromARGB(
                      255,
                      parsed[0]!,
                      parsed[1]!,
                      parsed[2]!,
                    ),
                    heading: heading.text.trim(),
                    body: body.text,
                  ),
                );
              }

              return AlertDialog(
                backgroundColor: R3Theme.panel,
                title: Text(
                  existing == null
                      ? 'Add CARD cue · source F$sourceFrame'
                      : 'Edit CARD cue · source F$sourceFrame',
                  style: widget.theme.value,
                ),
                content: SizedBox(
                  width: sc(520),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                key: const ValueKey<String>(
                                  'edit-card-cue-image-field',
                                ),
                                controller: image,
                                decoration: const InputDecoration(
                                  labelText: 'Image in workspace images/',
                                ),
                                style: widget.theme.value,
                              ),
                            ),
                            SizedBox(width: sc(8)),
                            PopupMenuButton<String>(
                              key: const ValueKey<String>(
                                'edit-card-cue-image-menu',
                              ),
                              enabled: images.isNotEmpty,
                              tooltip: 'Choose workspace image',
                              color: R3Theme.panelHi,
                              onSelected: (String value) {
                                image.text = value;
                                image.selection = TextSelection.collapsed(
                                  offset: image.text.length,
                                );
                                setDialogState(() => errorText = null);
                              },
                              itemBuilder: (_) => images
                                  .map(
                                    (String value) => PopupMenuItem<String>(
                                      value: value,
                                      child: Text(value),
                                    ),
                                  )
                                  .toList(growable: false),
                              child: Container(
                                padding: EdgeInsets.symmetric(
                                  horizontal: sc(10),
                                  vertical: sc(11),
                                ),
                                decoration: BoxDecoration(
                                  color: R3Theme.bg,
                                  border: Border.all(color: R3Theme.hairline),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                                child: const Icon(
                                  Icons.image_outlined,
                                  size: 18,
                                  color: R3Theme.textMid,
                                ),
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: sc(10)),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                key: const ValueKey<String>(
                                  'edit-card-cue-hold-field',
                                ),
                                controller: hold,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'Hold frames',
                                ),
                                style: widget.theme.value,
                              ),
                            ),
                            SizedBox(width: sc(10)),
                            Expanded(
                              child: TextField(
                                key: const ValueKey<String>(
                                  'edit-card-cue-rgb-field',
                                ),
                                controller: rgb,
                                decoration: const InputDecoration(
                                  labelText: 'Panel r,g,b',
                                ),
                                style: widget.theme.value,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: sc(10)),
                        TextField(
                          key: const ValueKey<String>(
                            'edit-card-cue-heading-field',
                          ),
                          controller: heading,
                          decoration: const InputDecoration(labelText: 'Heading'),
                          style: widget.theme.value,
                        ),
                        SizedBox(height: sc(10)),
                        TextField(
                          key: const ValueKey<String>('edit-card-cue-body-field'),
                          controller: body,
                          minLines: 3,
                          maxLines: 7,
                          decoration: InputDecoration(
                            labelText: 'Body',
                            errorText: errorText,
                            alignLabelWithHint: true,
                          ),
                          style: widget.theme.value,
                        ),
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('CANCEL'),
                  ),
                  TextButton(
                    key: const ValueKey<String>('edit-card-cue-apply'),
                    onPressed: apply,
                    child: Text(existing == null ? 'ADD CUE' : 'APPLY'),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      image.dispose();
      hold.dispose();
      rgb.dispose();
      heading.dispose();
      body.dispose();
    }
  }

  Future<void> _add() async {
    final int? sourceFrame = _playheadSourceFrame;
    final ValueChanged<CardRequest>? callback = widget.onAddAtPlayhead;
    if (sourceFrame == null || callback == null) return;
    final CardRequest? card = await _editCard(sourceFrame: sourceFrame);
    if (!mounted || card == null) return;
    callback(card);
  }

  Future<void> _edit(int index, EditCardCue cue) async {
    final EditCardCueChanged? callback = widget.onChanged;
    if (callback == null) return;
    final CardRequest? card = await _editCard(
      sourceFrame: cue.sourceFrame,
      existing: cue.card,
    );
    if (!mounted || card == null) return;
    callback(index, card);
  }

  @override
  Widget build(BuildContext context) {
    final int? playheadSourceFrame = _playheadSourceFrame;
    final bool canAdd =
        widget.onAddAtPlayhead != null && playheadSourceFrame != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: sc(32),
          child: OutlinedButton.icon(
            key: const ValueKey<String>('edit-card-cue-add'),
            onPressed: canAdd ? _add : null,
            icon: const Icon(Icons.add, size: 16),
            label: const Text('ADD CARD CUE AT PLAYHEAD'),
            style: OutlinedButton.styleFrom(
              padding: EdgeInsets.symmetric(horizontal: sc(7)),
              foregroundColor: widget.theme.accent,
              side: BorderSide(color: widget.theme.accentDim),
            ),
          ),
        ),
        SizedBox(height: sc(5)),
        Text(
          canAdd
              ? 'Playhead F${widget.playheadFrame} → source F$playheadSourceFrame.'
              : 'Park the playhead inside this clip to add a CARD cue.',
          style: widget.theme.micro.copyWith(color: R3Theme.textDim),
        ),
        if (widget.cues.isEmpty) ...[
          SizedBox(height: sc(8)),
          Text(
            'No authored CARD cues in this CLIP.',
            key: const ValueKey<String>('edit-card-cue-empty'),
            style: widget.theme.fine.copyWith(color: R3Theme.textDim),
          ),
        ] else ...[
          SizedBox(height: sc(9)),
          for (int index = 0; index < widget.cues.length; index++)
            _cueRow(index, widget.cues[index]),
        ],
      ],
    );
  }

  Widget _cueRow(int index, EditCardCue cue) {
    final int? projectFrame = cueProjectFrame(widget.clip.clip, cue.sourceFrame);
    final String project = projectFrame == null ? 'DORMANT' : 'P$projectFrame';
    final String heading = cue.card.heading.trim();

    return Container(
      key: ValueKey<String>('edit-card-cue-row-$index'),
      margin: EdgeInsets.only(bottom: sc(7)),
      padding: EdgeInsets.all(sc(7)),
      decoration: BoxDecoration(
        color: R3Theme.bg,
        border: Border.all(color: R3Theme.hairline),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'SOURCE F${cue.sourceFrame}   $project',
                  style: widget.theme.microAccent,
                ),
              ),
              Text('${cue.card.holdFrames}F', style: widget.theme.micro),
            ],
          ),
          SizedBox(height: sc(3)),
          Text(
            cue.card.image,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget.theme.fine.copyWith(color: R3Theme.textBright),
          ),
          if (heading.isNotEmpty) ...[
            SizedBox(height: sc(2)),
            Text(
              heading,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: widget.theme.micro.copyWith(color: R3Theme.textMid),
            ),
          ],
          SizedBox(height: sc(5)),
          Row(
            children: [
              TextButton(
                key: ValueKey<String>('edit-card-cue-edit-$index'),
                onPressed: widget.onChanged == null ? null : () => _edit(index, cue),
                style: TextButton.styleFrom(
                  minimumSize: Size.zero,
                  padding: EdgeInsets.symmetric(
                    horizontal: sc(6),
                    vertical: sc(3),
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text('EDIT', style: widget.theme.micro),
              ),
              const Spacer(),
              TextButton(
                key: ValueKey<String>('edit-card-cue-delete-$index'),
                onPressed: widget.onDeleted == null
                    ? null
                    : () => widget.onDeleted!(index),
                style: TextButton.styleFrom(
                  minimumSize: Size.zero,
                  padding: EdgeInsets.symmetric(
                    horizontal: sc(6),
                    vertical: sc(3),
                  ),
                  foregroundColor: R3Theme.danger,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text('DELETE', style: widget.theme.micro),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
