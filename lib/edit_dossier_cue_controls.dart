// ./lib/edit_dossier_cue_controls.dart
//
// GUI authoring controls for clip-local DOSSIER cues in the EDIT inspector.
//
// Like CARD authoring, this widget owns transient form state only. Durable
// changes are returned as DossierRequest values and serialized into the
// canonical CLIP source by edit_cue_authoring.dart. No inspector-only project
// state is introduced.

import 'package:flutter/material.dart';

import 'edit_cue.dart';
import 'edit_surface_model.dart';
import 'presentation_requests.dart';
import 'ui_theme.dart';

typedef EditDossierCueChanged = void Function(
  int cueIndex,
  DossierRequest dossier,
);

class EditDossierCueControls extends StatefulWidget {
  const EditDossierCueControls({
    super.key,
    required this.clip,
    required this.cues,
    required this.playheadFrame,
    required this.theme,
    required this.folderOptions,
    required this.imageOptions,
    required this.onAddAtPlayhead,
    required this.onChanged,
    required this.onDeleted,
  });

  final EditSurfaceClip clip;
  final List<EditDossierCue> cues;
  final int playheadFrame;
  final R3Theme theme;

  /// Workspace-relative DOSSIER folders beneath images/.
  final List<String> Function()? folderOptions;

  /// Workspace-relative portrait/image paths beneath images/.
  final List<String> Function()? imageOptions;

  /// Null while playback is running or when the playhead is outside the CLIP.
  final ValueChanged<DossierRequest>? onAddAtPlayhead;
  final EditDossierCueChanged? onChanged;
  final ValueChanged<int>? onDeleted;

  @override
  State<EditDossierCueControls> createState() =>
      _EditDossierCueControlsState();
}

class _EditDossierCueControlsState extends State<EditDossierCueControls> {
  int? get _playheadSourceFrame {
    final int frame = widget.playheadFrame;
    if (frame < widget.clip.atFrame || frame >= widget.clip.endFrameExclusive) {
      return null;
    }
    return widget.clip.clip.sourceFrameAtProjectOffset(
      frame - widget.clip.atFrame,
    );
  }

  String _modeName(DossierCenterMode mode) {
    switch (mode) {
      case DossierCenterMode.grid:
        return 'GRID';
      case DossierCenterMode.mosaic:
        return 'MOSAIC';
      case DossierCenterMode.sideOnly:
        return 'SIDE ONLY';
    }
  }

  Future<DossierRequest?> _editDossier({
    required int sourceFrame,
    DossierRequest? existing,
  }) async {
    final List<String> folders = <String>{
      ...?widget.folderOptions?.call(),
      if (existing != null && existing.folder.trim().isNotEmpty)
        existing.folder.trim(),
    }.toList()
      ..sort();
    final List<String> images = <String>{
      ...?widget.imageOptions?.call(),
      if (existing != null && existing.image.trim().isNotEmpty)
        existing.image.trim(),
    }.toList()
      ..sort();

    final int argb = existing?.panelColor.toARGB32() ?? 0xFF182028;
    final int red = (argb >> 16) & 0xFF;
    final int green = (argb >> 8) & 0xFF;
    final int blue = argb & 0xFF;

    String folderDraft =
        existing?.folder ?? (folders.isEmpty ? '' : folders.first);
    String imageDraft = existing?.image ?? (images.isEmpty ? '' : images.first);
    String splitDraft = '${existing?.holdSplit ?? 90}';
    String fullDraft = '${existing?.holdFull ?? 120}';
    String leadDraft = '${existing?.cardLead ?? 0}';
    DossierCenterMode modeDraft =
        existing?.centerMode ?? DossierCenterMode.mosaic;
    String rgbDraft = '$red,$green,$blue';
    String headingDraft = existing?.heading ?? '';
    String bodyDraft = existing?.body ?? '';

    return showDialog<DossierRequest>(
      context: context,
      builder: (BuildContext dialogContext) {
        String? errorText;

        return StatefulBuilder(
          builder: (
            BuildContext context,
            void Function(VoidCallback fn) setDialogState,
          ) {
            void apply() {
              final String folderValue = folderDraft.trim();
              final String imageValue = imageDraft.trim();
              final int? splitFrames = int.tryParse(splitDraft.trim());
              final int? fullFrames = int.tryParse(fullDraft.trim());
              final int? leadFrames = int.tryParse(leadDraft.trim());
              final List<String> channels = rgbDraft
                  .split(',')
                  .map((String value) => value.trim())
                  .toList(growable: false);
              final List<int?> parsed = channels
                  .map((String value) => int.tryParse(value))
                  .toList(growable: false);

              String? problem;
              if (!_validPath(folderValue)) {
                problem =
                    'Choose one evidence folder beneath the workspace images folder.';
              } else if (!_validPath(imageValue)) {
                problem =
                    'Choose one portrait image beneath the workspace images folder.';
              } else if (splitFrames == null || splitFrames < 0) {
                problem = 'Split hold must be zero or more frames.';
              } else if (fullFrames == null || fullFrames < 0) {
                problem = 'Center hold must be zero or more frames.';
              } else if (leadFrames == null || leadFrames < 0) {
                problem = 'Card lead must be zero or more frames.';
              } else if (channels.length != 3 ||
                  parsed.length != 3 ||
                  parsed.any((int? value) =>
                      value == null || value < 0 || value > 255)) {
                problem = 'Color must be r,g,b with values from 0 to 255.';
              } else if (headingDraft.contains(':') ||
                  headingDraft.contains(']') ||
                  headingDraft.contains('\n') ||
                  headingDraft.contains('\r')) {
                problem = 'Heading cannot contain colon, ] or a newline.';
              } else if (bodyDraft.contains('[/DOSSIER]')) {
                problem = 'Body cannot contain a DOSSIER closing tag.';
              }

              if (problem != null) {
                setDialogState(() => errorText = problem);
                return;
              }

              Navigator.of(dialogContext).pop(
                DossierRequest(
                  folder: folderValue,
                  image: imageValue,
                  holdSplit: splitFrames!,
                  holdFull: fullFrames!,
                  centerMode: modeDraft,
                  cardLead: leadFrames!,
                  panelColor: Color.fromARGB(
                    255,
                    parsed[0]!,
                    parsed[1]!,
                    parsed[2]!,
                  ),
                  heading: headingDraft.trim(),
                  body: bodyDraft,
                ),
              );
            }

            return AlertDialog(
              backgroundColor: R3Theme.panel,
              title: Text(
                existing == null
                    ? 'Add DOSSIER cue · source F$sourceFrame'
                    : 'Edit DOSSIER cue · source F$sourceFrame',
                style: widget.theme.value,
              ),
              content: SizedBox(
                width: sc(560),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: KeyedSubtree(
                              key: ValueKey<String>(
                                'edit-dossier-cue-folder-draft:$folderDraft',
                              ),
                              child: TextFormField(
                                key: const ValueKey<String>(
                                  'edit-dossier-cue-folder-field',
                                ),
                                initialValue: folderDraft,
                                decoration: const InputDecoration(
                                  labelText: 'Evidence folder in images/',
                                ),
                                style: widget.theme.value,
                                onChanged: (String value) => folderDraft = value,
                              ),
                            ),
                          ),
                          SizedBox(width: sc(8)),
                          PopupMenuButton<String>(
                            key: const ValueKey<String>(
                              'edit-dossier-cue-folder-menu',
                            ),
                            enabled: folders.isNotEmpty,
                            tooltip: 'Choose evidence folder',
                            color: R3Theme.panelHi,
                            onSelected: (String value) {
                              setDialogState(() {
                                folderDraft = value;
                                errorText = null;
                              });
                            },
                            itemBuilder: (_) => folders
                                .map(
                                  (String value) => PopupMenuItem<String>(
                                    value: value,
                                    child: Text(value),
                                  ),
                                )
                                .toList(growable: false),
                            child: _pickerFace(Icons.folder_open_outlined),
                          ),
                        ],
                      ),
                      SizedBox(height: sc(10)),
                      Row(
                        children: [
                          Expanded(
                            child: KeyedSubtree(
                              key: ValueKey<String>(
                                'edit-dossier-cue-image-draft:$imageDraft',
                              ),
                              child: TextFormField(
                                key: const ValueKey<String>(
                                  'edit-dossier-cue-image-field',
                                ),
                                initialValue: imageDraft,
                                decoration: const InputDecoration(
                                  labelText: 'Portrait image in images/',
                                ),
                                style: widget.theme.value,
                                onChanged: (String value) => imageDraft = value,
                              ),
                            ),
                          ),
                          SizedBox(width: sc(8)),
                          PopupMenuButton<String>(
                            key: const ValueKey<String>(
                              'edit-dossier-cue-image-menu',
                            ),
                            enabled: images.isNotEmpty,
                            tooltip: 'Choose portrait image',
                            color: R3Theme.panelHi,
                            onSelected: (String value) {
                              setDialogState(() {
                                imageDraft = value;
                                errorText = null;
                              });
                            },
                            itemBuilder: (_) => images
                                .map(
                                  (String value) => PopupMenuItem<String>(
                                    value: value,
                                    child: Text(value),
                                  ),
                                )
                                .toList(growable: false),
                            child: _pickerFace(Icons.image_outlined),
                          ),
                        ],
                      ),
                      SizedBox(height: sc(10)),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              key: const ValueKey<String>(
                                'edit-dossier-cue-split-field',
                              ),
                              initialValue: splitDraft,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Split hold frames',
                              ),
                              style: widget.theme.value,
                              onChanged: (String value) => splitDraft = value,
                            ),
                          ),
                          SizedBox(width: sc(8)),
                          Expanded(
                            child: TextFormField(
                              key: const ValueKey<String>(
                                'edit-dossier-cue-full-field',
                              ),
                              initialValue: fullDraft,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Center hold frames',
                              ),
                              style: widget.theme.value,
                              onChanged: (String value) => fullDraft = value,
                            ),
                          ),
                          SizedBox(width: sc(8)),
                          Expanded(
                            child: TextFormField(
                              key: const ValueKey<String>(
                                'edit-dossier-cue-lead-field',
                              ),
                              initialValue: leadDraft,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Card lead frames',
                              ),
                              style: widget.theme.value,
                              onChanged: (String value) => leadDraft = value,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: sc(10)),
                      Row(
                        children: [
                          Expanded(
                            child: Text('CENTER STAGE', style: widget.theme.micro),
                          ),
                          PopupMenuButton<DossierCenterMode>(
                            key: const ValueKey<String>(
                              'edit-dossier-cue-mode-menu',
                            ),
                            tooltip: 'DOSSIER center-stage mode',
                            color: R3Theme.panelHi,
                            onSelected: (DossierCenterMode value) {
                              setDialogState(() {
                                modeDraft = value;
                                errorText = null;
                              });
                            },
                            itemBuilder: (_) => const <
                                PopupMenuEntry<DossierCenterMode>>[
                              PopupMenuItem<DossierCenterMode>(
                                value: DossierCenterMode.grid,
                                child: Text('GRID'),
                              ),
                              PopupMenuItem<DossierCenterMode>(
                                value: DossierCenterMode.mosaic,
                                child: Text('MOSAIC'),
                              ),
                              PopupMenuItem<DossierCenterMode>(
                                value: DossierCenterMode.sideOnly,
                                child: Text('SIDE ONLY'),
                              ),
                            ],
                            child: Container(
                              key: const ValueKey<String>(
                                'edit-dossier-cue-mode',
                              ),
                              width: sc(150),
                              padding: EdgeInsets.symmetric(
                                horizontal: sc(9),
                                vertical: sc(7),
                              ),
                              decoration: BoxDecoration(
                                color: R3Theme.bg,
                                border: Border.all(color: R3Theme.hairline),
                                borderRadius: BorderRadius.circular(3),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      _modeName(modeDraft),
                                      key: const ValueKey<String>(
                                        'edit-dossier-cue-mode-value',
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: widget.theme.micro.copyWith(
                                        color: R3Theme.textBright,
                                      ),
                                    ),
                                  ),
                                  const Icon(
                                    Icons.arrow_drop_down,
                                    size: 15,
                                    color: R3Theme.textDim,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: sc(10)),
                      TextFormField(
                        key: const ValueKey<String>(
                          'edit-dossier-cue-rgb-field',
                        ),
                        initialValue: rgbDraft,
                        decoration: const InputDecoration(
                          labelText: 'Panel r,g,b',
                        ),
                        style: widget.theme.value,
                        onChanged: (String value) => rgbDraft = value,
                      ),
                      SizedBox(height: sc(10)),
                      TextFormField(
                        key: const ValueKey<String>(
                          'edit-dossier-cue-heading-field',
                        ),
                        initialValue: headingDraft,
                        decoration: const InputDecoration(labelText: 'Heading'),
                        style: widget.theme.value,
                        onChanged: (String value) => headingDraft = value,
                      ),
                      SizedBox(height: sc(10)),
                      TextFormField(
                        key: const ValueKey<String>(
                          'edit-dossier-cue-body-field',
                        ),
                        initialValue: bodyDraft,
                        minLines: 3,
                        maxLines: 7,
                        decoration: InputDecoration(
                          labelText: 'Biography / body',
                          errorText: errorText,
                          alignLabelWithHint: true,
                        ),
                        style: widget.theme.value,
                        onChanged: (String value) => bodyDraft = value,
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
                  key: const ValueKey<String>('edit-dossier-cue-apply'),
                  onPressed: apply,
                  child: Text(existing == null ? 'ADD CUE' : 'APPLY'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  bool _validPath(String value) {
    return value.isNotEmpty &&
        !value.contains(':') &&
        !value.contains(']') &&
        !value.contains('\n') &&
        !value.contains('\r');
  }

  Widget _pickerFace(IconData icon) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: sc(10), vertical: sc(11)),
      decoration: BoxDecoration(
        color: R3Theme.bg,
        border: Border.all(color: R3Theme.hairline),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Icon(icon, size: 18, color: R3Theme.textMid),
    );
  }

  Future<void> _add() async {
    final int? sourceFrame = _playheadSourceFrame;
    final ValueChanged<DossierRequest>? callback = widget.onAddAtPlayhead;
    if (sourceFrame == null || callback == null) return;
    final DossierRequest? dossier = await _editDossier(
      sourceFrame: sourceFrame,
    );
    if (!mounted || dossier == null) return;
    callback(dossier);
  }

  Future<void> _edit(int index, EditDossierCue cue) async {
    final EditDossierCueChanged? callback = widget.onChanged;
    if (callback == null) return;
    final DossierRequest? dossier = await _editDossier(
      sourceFrame: cue.sourceFrame,
      existing: cue.dossier,
    );
    if (!mounted || dossier == null) return;
    callback(index, dossier);
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
            key: const ValueKey<String>('edit-dossier-cue-add'),
            onPressed: canAdd ? _add : null,
            icon: const Icon(Icons.add, size: 16),
            label: const Text('ADD DOSSIER CUE AT PLAYHEAD'),
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
              : 'Park the playhead inside this clip to add a DOSSIER cue.',
          style: widget.theme.micro.copyWith(color: R3Theme.textDim),
        ),
        if (widget.cues.isEmpty) ...[
          SizedBox(height: sc(8)),
          Text(
            'No authored DOSSIER cues in this CLIP.',
            key: const ValueKey<String>('edit-dossier-cue-empty'),
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

  Widget _cueRow(int index, EditDossierCue cue) {
    final int? projectFrame = cueProjectFrame(widget.clip.clip, cue.sourceFrame);
    final String project = projectFrame == null ? 'DORMANT' : 'P$projectFrame';
    final String heading = cue.dossier.heading.trim();

    return Container(
      key: ValueKey<String>('edit-dossier-cue-row-$index'),
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
                  '${_modeName(cue.dossier.centerMode)}   '
                  'SOURCE F${cue.sourceFrame}   $project',
                  key: ValueKey<String>('edit-dossier-cue-mode-row-$index'),
                  style: widget.theme.microAccent,
                ),
              ),
            ],
          ),
          SizedBox(height: sc(3)),
          Text(
            cue.dossier.folder,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget.theme.fine.copyWith(color: R3Theme.textBright),
          ),
          SizedBox(height: sc(2)),
          Text(
            'SPLIT ${cue.dossier.holdSplit}F   CENTER ${cue.dossier.holdFull}F   '
            'LEAD ${cue.dossier.cardLead}F',
            style: widget.theme.micro.copyWith(color: R3Theme.textDim),
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
                key: ValueKey<String>('edit-dossier-cue-edit-$index'),
                onPressed:
                    widget.onChanged == null ? null : () => _edit(index, cue),
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
                key: ValueKey<String>('edit-dossier-cue-delete-$index'),
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
