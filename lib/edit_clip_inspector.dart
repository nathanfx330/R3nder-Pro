// ./lib/edit_clip_inspector.dart
//
// Selected-CLIP inspector for the EDIT surface.
//
// The EDIT inspector is a projection of authored CLIP state, not a second
// project model. A property that cannot be expressed in the authored CLIP
// representation does not belong in this inspector. Inspector edits must round
// trip through the canonical script and preserve unrelated authored source byte
// for byte.

import 'package:flutter/material.dart';

import 'edit_surface_model.dart';
import 'ui_theme.dart';

class EditClipInspector extends StatelessWidget {
  final EditSurfaceClip? clip;
  final R3Theme theme;
  final VoidCallback? onDelete;

  const EditClipInspector({
    super.key,
    required this.clip,
    required this.theme,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final EditSurfaceClip? selected = clip;

    return Container(
      key: const ValueKey<String>('edit-clip-inspector'),
      width: sc(264),
      decoration: const BoxDecoration(
        color: R3Theme.panel,
        border: Border(left: BorderSide(color: R3Theme.hairline)),
      ),
      child: Padding(
        padding: EdgeInsets.all(sc(12)),
        child: selected == null
            ? _buildEmpty()
            : _buildSelected(context, selected),
      ),
    );
  }

  Widget _buildEmpty() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        R3MicroLabel('CLIP INSPECTOR', theme: theme, accent: true),
        SizedBox(height: sc(14)),
        Expanded(
          child: SingleChildScrollView(
            child: Text(
              'Select a clip in the timeline to inspect its authored properties.',
              key: const ValueKey<String>('edit-inspector-empty'),
              style: theme.fine.copyWith(color: R3Theme.textDim),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSelected(BuildContext context, EditSurfaceClip selected) {
    final int sourceOut = selected.clip.sourceFrameAtProjectOffset(
      selected.durationFrames - 1,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        R3MicroLabel('CLIP INSPECTOR', theme: theme, accent: true),
        SizedBox(height: sc(10)),
        Text(
          selected.id,
          key: const ValueKey<String>('edit-inspector-clip-id'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.value.copyWith(
            color: R3Theme.textBright,
            fontWeight: FontWeight.w600,
          ),
        ),
        SizedBox(height: sc(10)),
        Expanded(
          child: SingleChildScrollView(
            key: const ValueKey<String>('edit-inspector-properties-scroll'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _field('SOURCE', selected.source,
                    key: 'edit-inspector-source'),
                _field('TRACK', selected.trackId,
                    key: 'edit-inspector-track'),
                _field('TIMELINE START', 'F${selected.atFrame}',
                    key: 'edit-inspector-at'),
                _field('SOURCE IN', 'F${selected.inFrame}',
                    key: 'edit-inspector-in'),
                _field('SOURCE OUT', 'F$sourceOut',
                    key: 'edit-inspector-out'),
                _field('DURATION', '${selected.durationFrames}F',
                    key: 'edit-inspector-duration'),
                _field('SPEED', '${selected.speed}X',
                    key: 'edit-inspector-speed'),
              ],
            ),
          ),
        ),
        SizedBox(height: sc(8)),
        SizedBox(
          height: sc(34),
          child: OutlinedButton.icon(
            key: const ValueKey<String>('edit-inspector-delete'),
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline, size: 16),
            label: const Text('DELETE CLIP'),
            style: OutlinedButton.styleFrom(
              foregroundColor: R3Theme.danger,
              side: const BorderSide(color: R3Theme.danger),
              padding: EdgeInsets.symmetric(horizontal: sc(10)),
            ),
          ),
        ),
        SizedBox(height: sc(6)),
        Text(
          'Delete removes only this authored CLIP block. Timeline gaps remain.',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.micro.copyWith(color: R3Theme.textDim),
        ),
      ],
    );
  }

  Widget _field(String label, String value, {required String key}) {
    return Padding(
      padding: EdgeInsets.only(bottom: sc(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.micro),
          SizedBox(height: sc(2)),
          Text(
            value,
            key: ValueKey<String>(key),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.fine.copyWith(color: R3Theme.textBright),
          ),
        ],
      ),
    );
  }
}
