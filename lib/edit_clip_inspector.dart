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
  final ValueChanged<int>? onSlipBy;
  final ValueChanged<ExactClipSpeed>? onSpeedChanged;
  final ValueChanged<EditTransition>? onIncomingTransitionChanged;
  final ValueChanged<EditTransition>? onOutgoingTransitionChanged;
  final ValueChanged<ClipAudioGain>? onAudioGainChanged;
  final ValueChanged<bool>? onMutedChanged;
  final VoidCallback? onDelete;

  const EditClipInspector({
    super.key,
    required this.clip,
    required this.theme,
    this.onSlipBy,
    this.onSpeedChanged,
    this.onIncomingTransitionChanged,
    this.onOutgoingTransitionChanged,
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
        child: selected == null ? _buildEmpty() : _buildSelected(selected),
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

  Widget _buildSelected(EditSurfaceClip selected) {
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
                _sectionDivider(),
                R3MicroLabel('SOURCE TIMING', theme: theme, accent: true),
                SizedBox(height: sc(7)),
                _ClipTimingControls(
                  clip: selected,
                  theme: theme,
                  onSlipBy: onSlipBy,
                  onSpeedChanged: onSpeedChanged,
                ),
                SizedBox(height: sc(10)),
                _sectionDivider(),
                R3MicroLabel('TRANSITIONS', theme: theme, accent: true),
                SizedBox(height: sc(7)),
                _ClipTransitionControls(
                  key: ValueKey<String>(
                    'edit-transition-controls:${selected.trackId}:${selected.id}',
                  ),
                  clip: selected,
                  theme: theme,
                  onIncomingChanged: onIncomingTransitionChanged,
                  onOutgoingChanged: onOutgoingTransitionChanged,
                ),
                SizedBox(height: sc(10)),
                _sectionDivider(),
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

  Widget _sectionDivider() {
    return Padding(
      padding: EdgeInsets.only(top: sc(2), bottom: sc(9)),
      child: const Divider(height: 1, color: R3Theme.hairline),
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

class _ClipTimingControls extends StatelessWidget {
  final EditSurfaceClip clip;
  final R3Theme theme;
  final ValueChanged<int>? onSlipBy;
  final ValueChanged<ExactClipSpeed>? onSpeedChanged;

  const _ClipTimingControls({
    required this.clip,
    required this.theme,
    required this.onSlipBy,
    required this.onSpeedChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('SLIP SOURCE', style: theme.micro)),
            _smallButton(
              key: const ValueKey<String>('edit-inspector-slip-minus'),
              label: '-1',
              onPressed:
                  onSlipBy == null || clip.inFrame <= 0 ? null : () => onSlipBy!(-1),
            ),
            SizedBox(width: sc(4)),
            _smallButton(
              key: const ValueKey<String>('edit-inspector-slip-plus'),
              label: '+1',
              onPressed: onSlipBy == null ? null : () => onSlipBy!(1),
            ),
          ],
        ),
        SizedBox(height: sc(8)),
        Row(
          children: [
            Expanded(child: Text('SPEED', style: theme.micro)),
            PopupMenuButton<String>(
              key: const ValueKey<String>('edit-inspector-speed-menu'),
              tooltip: 'Clip speed',
              enabled: onSpeedChanged != null,
              color: R3Theme.panelHi,
              onSelected: (String value) {
                onSpeedChanged?.call(ExactClipSpeed.parse(value));
              },
              itemBuilder: (_) => const <String>['1/4', '1/2', '1', '2', '4']
                  .map(
                    (String value) => PopupMenuItem<String>(
                      value: value,
                      child: Text('$value X'),
                    ),
                  )
                  .toList(),
              child: _selectorFace(
                '${clip.speed}X',
                theme,
                key: const ValueKey<String>('edit-inspector-speed'),
              ),
            ),
          ],
        ),
        SizedBox(height: sc(5)),
        Text(
          'Slip changes SOURCE IN without moving the clip. Speed changes source sampling without changing authored duration.',
          style: theme.micro.copyWith(color: R3Theme.textDim),
        ),
      ],
    );
  }

  Widget _smallButton({
    required Key key,
    required String label,
    required VoidCallback? onPressed,
  }) {
    return SizedBox(
      height: sc(28),
      child: OutlinedButton(
        key: key,
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          minimumSize: Size(sc(42), sc(28)),
          padding: EdgeInsets.symmetric(horizontal: sc(8)),
          foregroundColor: R3Theme.textBright,
          side: const BorderSide(color: R3Theme.hairline),
        ),
        child: Text(label, style: theme.micro),
      ),
    );
  }
}

class _ClipTransitionControls extends StatefulWidget {
  final EditSurfaceClip clip;
  final R3Theme theme;
  final ValueChanged<EditTransition>? onIncomingChanged;
  final ValueChanged<EditTransition>? onOutgoingChanged;

  const _ClipTransitionControls({
    super.key,
    required this.clip,
    required this.theme,
    required this.onIncomingChanged,
    required this.onOutgoingChanged,
  });

  @override
  State<_ClipTransitionControls> createState() =>
      _ClipTransitionControlsState();
}

class _ClipTransitionControlsState extends State<_ClipTransitionControls> {
  String _summary(EditTransition transition) {
    switch (transition.kind) {
      case EditTransitionKind.none:
        return 'NONE';
      case EditTransitionKind.crossfade:
        return 'CROSSFADE ${transition.frames}F';
      case EditTransitionKind.luma:
        return 'LUMA ${transition.frames}F';
    }
  }

  Future<int?> _customCrossfade(EditTransition current) async {
    final int maxFrames = widget.clip.durationFrames;
    final int initial = current.kind == EditTransitionKind.crossfade
        ? current.frames
        : maxFrames >= 48
            ? 48
            : maxFrames;
    String draft = '$initial';
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
              if (frames == null || frames <= 0 || frames > maxFrames) {
                setDialogState(
                  () => errorText = 'Enter 1 to $maxFrames frames.',
                );
                return;
              }
              Navigator.of(dialogContext).pop(frames);
            }

            return AlertDialog(
              backgroundColor: R3Theme.panel,
              title: Text('Crossfade frames', style: widget.theme.value),
              content: TextFormField(
                key: const ValueKey<String>('edit-inspector-xfade-field'),
                initialValue: draft,
                autofocus: true,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: '1 to $maxFrames frames',
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
  }

  Future<EditTransition?> _lumaTransition(EditTransition current) async {
    final int maxFrames = widget.clip.durationFrames;
    String sourceDraft = current.kind == EditTransitionKind.luma
        ? current.lumaSource
        : '';
    String framesDraft = current.kind == EditTransitionKind.luma
        ? '${current.frames}'
        : '${maxFrames < 12 ? maxFrames : 12}';
    String? errorText;

    return showDialog<EditTransition>(
      context: context,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (
            BuildContext context,
            void Function(VoidCallback fn) setDialogState,
          ) {
            void apply() {
              final String source = sourceDraft.trim();
              final int? frames = int.tryParse(framesDraft.trim());
              if (source.isEmpty ||
                  source.contains(':') ||
                  source.contains('\n') ||
                  source.contains('\r')) {
                setDialogState(
                  () => errorText = 'Mask source must be a path without colon or newline.',
                );
                return;
              }
              if (frames == null || frames <= 0 || frames > maxFrames) {
                setDialogState(
                  () => errorText = 'Transition must be 1 to $maxFrames frames.',
                );
                return;
              }
              Navigator.of(dialogContext).pop(
                EditTransition.luma(source, frames),
              );
            }

            return AlertDialog(
              backgroundColor: R3Theme.panel,
              title: Text('Luma transition', style: widget.theme.value),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    key: const ValueKey<String>('edit-inspector-luma-source'),
                    initialValue: sourceDraft,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Mask source'),
                    style: widget.theme.value,
                    onChanged: (String value) => sourceDraft = value,
                  ),
                  SizedBox(height: sc(10)),
                  TextFormField(
                    key: const ValueKey<String>('edit-inspector-luma-frames'),
                    initialValue: framesDraft,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: '1 to $maxFrames frames',
                      errorText: errorText,
                    ),
                    style: widget.theme.value,
                    onChanged: (String value) => framesDraft = value,
                    onFieldSubmitted: (_) => apply(),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('CANCEL'),
                ),
                TextButton(
                  onPressed: apply,
                  child: const Text('APPLY'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _handleMenu({
    required bool incoming,
    required String action,
  }) async {
    final EditTransition current =
        incoming ? widget.clip.transition : widget.clip.outgoingTransition;
    EditTransition? next;

    if (action == 'none') {
      next = const EditTransition.none();
    } else if (action == 'xfade:custom') {
      final int? frames = await _customCrossfade(current);
      if (!mounted || frames == null) return;
      next = EditTransition.crossfade(frames);
    } else if (action.startsWith('xfade:')) {
      next = EditTransition.crossfade(
        int.parse(action.substring('xfade:'.length)),
      );
    } else if (action == 'luma') {
      if (!incoming) return;
      next = await _lumaTransition(current);
      if (!mounted || next == null) return;
    }

    if (next == null || next == current) return;
    if (incoming) {
      widget.onIncomingChanged?.call(next);
    } else {
      widget.onOutgoingChanged?.call(next);
    }
  }

  List<PopupMenuEntry<String>> _items({required bool incoming}) {
    final List<PopupMenuEntry<String>> items = <PopupMenuEntry<String>>[
      const PopupMenuItem<String>(value: 'none', child: Text('NONE')),
    ];
    for (final int frames in const <int>[12, 24, 48, 72]) {
      items.add(
        PopupMenuItem<String>(
          value: 'xfade:$frames',
          enabled: frames <= widget.clip.durationFrames,
          child: Text('CROSSFADE $frames FRAMES'),
        ),
      );
    }
    items.add(
      const PopupMenuItem<String>(
        value: 'xfade:custom',
        child: Text('CROSSFADE CUSTOM…'),
      ),
    );
    if (incoming) {
      items.add(const PopupMenuDivider());
      items.add(
        const PopupMenuItem<String>(
          value: 'luma',
          child: Text('LUMA…'),
        ),
      );
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final EditTransition incoming = widget.clip.transition;
    final EditTransition outgoing = widget.clip.outgoingTransition;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('INCOMING', style: widget.theme.micro),
        SizedBox(height: sc(3)),
        PopupMenuButton<String>(
          key: const ValueKey<String>('edit-inspector-transition-in-menu'),
          enabled: widget.onIncomingChanged != null,
          tooltip: 'Incoming transition',
          color: R3Theme.panelHi,
          onSelected: (String action) {
            _handleMenu(incoming: true, action: action);
          },
          itemBuilder: (_) => _items(incoming: true),
          child: _selectorFace(
            _summary(incoming),
            widget.theme,
            key: const ValueKey<String>('edit-inspector-transition-in'),
          ),
        ),
        if (incoming.kind == EditTransitionKind.luma) ...[
          SizedBox(height: sc(3)),
          Text(
            incoming.lumaSource,
            key: const ValueKey<String>('edit-inspector-luma-summary'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: widget.theme.micro.copyWith(color: R3Theme.textDim),
          ),
        ],
        SizedBox(height: sc(8)),
        Text('OUTGOING', style: widget.theme.micro),
        SizedBox(height: sc(3)),
        PopupMenuButton<String>(
          key: const ValueKey<String>('edit-inspector-transition-out-menu'),
          enabled: widget.onOutgoingChanged != null,
          tooltip: 'Outgoing transition',
          color: R3Theme.panelHi,
          onSelected: (String action) {
            _handleMenu(incoming: false, action: action);
          },
          itemBuilder: (_) => _items(incoming: false),
          child: _selectorFace(
            _summary(outgoing),
            widget.theme,
            key: const ValueKey<String>('edit-inspector-transition-out'),
          ),
        ),
        SizedBox(height: sc(5)),
        Text(
          'Incoming supports crossfade or luma. Outgoing currently supports crossfade only.',
          style: widget.theme.micro.copyWith(color: R3Theme.textDim),
        ),
      ],
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

Widget _selectorFace(String label, R3Theme theme, {Key? key}) {
  return Container(
    key: key,
    constraints: BoxConstraints(
      minWidth: sc(104),
      maxWidth: sc(170),
    ),
    padding: EdgeInsets.symmetric(horizontal: sc(8), vertical: sc(6)),
    decoration: BoxDecoration(
      color: R3Theme.bg,
      borderRadius: BorderRadius.circular(3),
      border: Border.all(color: R3Theme.hairline),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.micro.copyWith(color: R3Theme.textBright),
          ),
        ),
        SizedBox(width: sc(4)),
        const Icon(Icons.arrow_drop_down, size: 15, color: R3Theme.textDim),
      ],
    ),
  );
}
