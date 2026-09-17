// ./lib/edit_maximize_cue_controls.dart
//
// GUI authoring controls for clip-local MAXIMIZE shell cues in the EDIT
// inspector.
//
// This widget owns only transient form state. Durable changes are returned to
// EditSurface as hold-frame values and serialized into canonical CLIP source by
// edit_cue_authoring.dart. MAXIMIZE remains a shell cue, not a presentation
// request and not hidden timeline state.

import 'package:flutter/material.dart';

import 'edit_cue.dart';
import 'edit_surface_model.dart';
import 'maximize_presentation.dart';
import 'ui_theme.dart';

typedef EditMaximizeCueChanged = void Function(
  int cueIndex,
  int holdFrames,
);

class EditMaximizeCueControls extends StatefulWidget {
  const EditMaximizeCueControls({
    super.key,
    required this.clip,
    required this.cues,
    required this.playheadFrame,
    required this.theme,
    required this.onAddAtPlayhead,
    required this.onChanged,
    required this.onDeleted,
  });

  final EditSurfaceClip clip;
  final List<EditMaximizeCue> cues;
  final int playheadFrame;
  final R3Theme theme;

  /// Null while playback is running or when authoring is otherwise disabled.
  final ValueChanged<int>? onAddAtPlayhead;
  final EditMaximizeCueChanged? onChanged;
  final ValueChanged<int>? onDeleted;

  @override
  State<EditMaximizeCueControls> createState() =>
      _EditMaximizeCueControlsState();
}

class _EditMaximizeCueControlsState extends State<EditMaximizeCueControls> {
  int? get _playheadSourceFrame {
    final int frame = widget.playheadFrame;
    if (frame < widget.clip.atFrame || frame >= widget.clip.endFrameExclusive) {
      return null;
    }
    return widget.clip.clip.sourceFrameAtProjectOffset(
      frame - widget.clip.atFrame,
    );
  }

  Future<int?> _editHold({
    required int sourceFrame,
    int? existingHoldFrames,
  }) async {
    String draft = '${existingHoldFrames ?? 60}';
    String? errorText;

    return showDialog<int>(
      context: context,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (
            BuildContext context,
            void Function(VoidCallback fn) setDialogState,
          ) {
            void apply(String value) {
              final int? frames = int.tryParse(value.trim());
              if (frames == null || frames < 0) {
                setDialogState(
                  () => errorText = 'Hold must be zero or more frames.',
                );
                return;
              }
              Navigator.of(dialogContext).pop(frames);
            }

            return AlertDialog(
              backgroundColor: R3Theme.panel,
              title: Text(
                existingHoldFrames == null
                    ? 'Add MAXIMIZE cue · source F$sourceFrame'
                    : 'Edit MAXIMIZE cue · source F$sourceFrame',
                style: widget.theme.value,
              ),
              content: SizedBox(
                width: sc(380),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextFormField(
                      key: const ValueKey<String>(
                        'edit-maximize-cue-hold-field',
                      ),
                      initialValue: draft,
                      autofocus: true,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: 'Fullscreen hold frames',
                        errorText: errorText,
                      ),
                      style: widget.theme.value,
                      onChanged: (String value) => draft = value,
                      onFieldSubmitted: apply,
                    ),
                    SizedBox(height: sc(8)),
                    Text(
                      'MAXIMIZE uses a fixed 12 frame push in and 12 frame return. '
                      'The authored number is only the fullscreen hold. A hold of 0 is a pure in and out move.',
                      key: const ValueKey<String>('edit-maximize-cue-help'),
                      style: widget.theme.fine.copyWith(
                        color: R3Theme.textDim,
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('CANCEL'),
                ),
                TextButton(
                  key: const ValueKey<String>('edit-maximize-cue-apply'),
                  onPressed: () => apply(draft),
                  child: const Text('APPLY'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _add() async {
    final int? sourceFrame = _playheadSourceFrame;
    if (sourceFrame == null || widget.onAddAtPlayhead == null) return;
    final int? holdFrames = await _editHold(sourceFrame: sourceFrame);
    if (!mounted || holdFrames == null) return;
    widget.onAddAtPlayhead?.call(holdFrames);
  }

  Future<void> _edit(int cueIndex, EditMaximizeCue cue) async {
    if (widget.onChanged == null) return;
    final int? holdFrames = await _editHold(
      sourceFrame: cue.sourceFrame,
      existingHoldFrames: cue.holdFrames,
    );
    if (!mounted || holdFrames == null || holdFrames == cue.holdFrames) return;
    widget.onChanged?.call(cueIndex, holdFrames);
  }

  @override
  Widget build(BuildContext context) {
    final int? playheadSource = _playheadSourceFrame;
    final bool canAdd = playheadSource != null && widget.onAddAtPlayhead != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          playheadSource == null
              ? 'Park the playhead inside this clip to add a shell cue.'
              : 'Playhead maps to source F$playheadSource.',
          key: const ValueKey<String>('edit-maximize-cue-playhead'),
          style: widget.theme.micro.copyWith(color: R3Theme.textDim),
        ),
        SizedBox(height: sc(6)),
        SizedBox(
          height: sc(32),
          child: OutlinedButton.icon(
            key: const ValueKey<String>('edit-maximize-cue-add'),
            onPressed: canAdd ? _add : null,
            icon: const Icon(Icons.fullscreen, size: 16),
            label: const Text('ADD MAXIMIZE AT PLAYHEAD'),
            style: OutlinedButton.styleFrom(
              foregroundColor: R3Theme.textBright,
              side: const BorderSide(color: R3Theme.hairline),
              padding: EdgeInsets.symmetric(horizontal: sc(8)),
            ),
          ),
        ),
        if (widget.cues.isEmpty) ...[
          SizedBox(height: sc(6)),
          Text(
            'No MAXIMIZE cues in this clip.',
            key: const ValueKey<String>('edit-maximize-cue-empty'),
            style: widget.theme.micro.copyWith(color: R3Theme.textDim),
          ),
        ] else ...[
          SizedBox(height: sc(7)),
          for (int i = 0; i < widget.cues.length; i++) ...[
            _cueRow(i, widget.cues[i]),
            if (i != widget.cues.length - 1) SizedBox(height: sc(5)),
          ],
        ],
      ],
    );
  }

  Widget _cueRow(int cueIndex, EditMaximizeCue cue) {
    final MaximizePresentationTiming timing = MaximizePresentationTiming(
      holdFrames: cue.holdFrames,
    );

    return Container(
      key: ValueKey<String>('edit-maximize-cue-row-$cueIndex'),
      padding: EdgeInsets.symmetric(horizontal: sc(7), vertical: sc(6)),
      decoration: BoxDecoration(
        color: R3Theme.bg,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: R3Theme.hairline),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'SOURCE F${cue.sourceFrame}',
                  style: widget.theme.microAccent,
                ),
                SizedBox(height: sc(2)),
                Text(
                  'HOLD ${cue.holdFrames}F   TOTAL ${timing.durationFrames}F',
                  key: ValueKey<String>('edit-maximize-cue-summary-$cueIndex'),
                  style: widget.theme.fine.copyWith(
                    color: R3Theme.textBright,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: ValueKey<String>('edit-maximize-cue-edit-$cueIndex'),
            tooltip: 'Edit MAXIMIZE hold',
            visualDensity: VisualDensity.compact,
            iconSize: 17,
            onPressed: widget.onChanged == null ? null : () => _edit(cueIndex, cue),
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            key: ValueKey<String>('edit-maximize-cue-delete-$cueIndex'),
            tooltip: 'Delete MAXIMIZE cue',
            visualDensity: VisualDensity.compact,
            iconSize: 17,
            color: R3Theme.danger,
            onPressed: widget.onDeleted == null
                ? null
                : () => widget.onDeleted?.call(cueIndex),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }
}
