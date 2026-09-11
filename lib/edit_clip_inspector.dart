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

import 'edit_model.dart';
import 'edit_surface_model.dart';
import 'ui_theme.dart';

class EditClipInspector extends StatelessWidget {
  final EditSurfaceClip? clip;
  final R3Theme theme;
  final ValueChanged<ClipAudioGain>? onAudioGainChanged;
  final ValueChanged<bool>? onMutedChanged;
  final VoidCallback? onDelete;

  const EditClipInspector({
    super.key,
    required this.clip,
    required this.theme,
    this.onAudioGainChanged,
    this.onMutedChanged,
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
                Padding(
                  padding: EdgeInsets.symmetric(vertical: sc(4)),
                  child: const Divider(height: 1, color: R3Theme.hairline),
                ),
                SizedBox(height: sc(9)),
                R3MicroLabel('AUDIO', theme: theme, accent: true),
                SizedBox(height: sc(7)),
                _ClipAudioControls(
                  key: ValueKey<String>(
                    'edit-audio-controls:${selected.trackId}:${selected.id}',
                  ),
                  gain: selected.audioGain,
                  muted: selected.muted,
                  theme: theme,
                  onGainChanged: onAudioGainChanged,
                  onMutedChanged: onMutedChanged,
                ),
                SizedBox(height: sc(10)),
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

class _ClipAudioControls extends StatefulWidget {
  final ClipAudioGain gain;
  final bool muted;
  final R3Theme theme;
  final ValueChanged<ClipAudioGain>? onGainChanged;
  final ValueChanged<bool>? onMutedChanged;

  const _ClipAudioControls({
    super.key,
    required this.gain,
    required this.muted,
    required this.theme,
    required this.onGainChanged,
    required this.onMutedChanged,
  });

  @override
  State<_ClipAudioControls> createState() => _ClipAudioControlsState();
}

class _ClipAudioControlsState extends State<_ClipAudioControls> {
  late double _draftDb;

  @override
  void initState() {
    super.initState();
    _draftDb = widget.gain.decibels;
  }

  @override
  void didUpdateWidget(covariant _ClipAudioControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gain != widget.gain) {
      _draftDb = widget.gain.decibels;
    }
  }

  Future<void> _editNumericGain() async {
    String draft = widget.gain.canonicalMarkup;
    String? errorText;

    final ClipAudioGain? next = await showDialog<ClipAudioGain>(
      context: context,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (
            BuildContext context,
            void Function(VoidCallback fn) setDialogState,
          ) {
            void apply(String value) {
              try {
                Navigator.of(dialogContext).pop(
                  ClipAudioGain.parse(value),
                );
              } on FormatException catch (error) {
                setDialogState(() => errorText = '${error.message}');
              }
            }

            return AlertDialog(
              backgroundColor: R3Theme.panel,
              title: Text('Clip audio gain', style: widget.theme.value),
              content: TextFormField(
                key: const ValueKey<String>('edit-inspector-gain-field'),
                initialValue: draft,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  signed: true,
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: '-60.0 to +12.0 dB',
                  errorText: errorText,
                ),
                style: widget.theme.value,
                onChanged: (String value) => draft = value,
                onFieldSubmitted: apply,
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('CANCEL'),
                ),
                TextButton(
                  onPressed: () => apply(draft),
                  child: const Text('APPLY'),
                ),
              ],
            );
          },
        );
      },
    );

    if (!mounted || next == null || next == widget.gain) return;
    setState(() => _draftDb = next.decibels);
    widget.onGainChanged?.call(next);
  }

  void _commitSlider(double value) {
    final ClipAudioGain gain = ClipAudioGain.fromDecibels(value);
    setState(() => _draftDb = gain.decibels);
    if (gain != widget.gain) widget.onGainChanged?.call(gain);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('GAIN', style: widget.theme.micro),
            const Spacer(),
            TextButton(
              key: const ValueKey<String>('edit-inspector-gain-value'),
              onPressed: widget.onGainChanged == null ? null : _editNumericGain,
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                padding: EdgeInsets.symmetric(
                  horizontal: sc(6),
                  vertical: sc(3),
                ),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                '${_draftDb.toStringAsFixed(1)} dB',
                style: widget.theme.fine.copyWith(color: R3Theme.textBright),
              ),
            ),
            SizedBox(width: sc(4)),
            TextButton(
              key: const ValueKey<String>('edit-inspector-gain-reset'),
              onPressed: widget.onGainChanged == null || widget.gain.isUnity
                  ? null
                  : () {
                      setState(() => _draftDb = 0.0);
                      widget.onGainChanged?.call(ClipAudioGain.unity);
                    },
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                padding: EdgeInsets.symmetric(
                  horizontal: sc(5),
                  vertical: sc(3),
                ),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text('RESET', style: widget.theme.micro),
            ),
          ],
        ),
        Slider(
          key: const ValueKey<String>('edit-inspector-gain-slider'),
          min: -60.0,
          max: 12.0,
          divisions: 720,
          value: _draftDb.clamp(-60.0, 12.0).toDouble(),
          onChanged: widget.onGainChanged == null
              ? null
              : (double value) => setState(() => _draftDb = value),
          onChangeEnd:
              widget.onGainChanged == null ? null : _commitSlider,
        ),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('MUTE', style: widget.theme.micro),
                  SizedBox(height: sc(2)),
                  Text(
                    widget.muted ? 'MUTED' : 'AUDIBLE',
                    key: const ValueKey<String>('edit-inspector-mute-state'),
                    style: widget.theme.fine.copyWith(
                      color: widget.muted
                          ? R3Theme.warn
                          : R3Theme.textBright,
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              key: const ValueKey<String>('edit-inspector-mute'),
              value: widget.muted,
              onChanged: widget.onMutedChanged,
            ),
          ],
        ),
        SizedBox(height: sc(3)),
        Text(
          'Mute keeps the authored gain so unmuting restores the same level.',
          style: widget.theme.micro.copyWith(color: R3Theme.textDim),
        ),
      ],
    );
  }
}
