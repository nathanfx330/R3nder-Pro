// ./lib/structural_chrome_controls.dart
//
// Node-mode authoring controls for placement-owned STRUCT player chrome.
//
// This widget owns no document state and knows nothing about ScriptNode. The
// node workspace supplies the currently authored token values and the same
// controller cache used by every other text field, then commits each change
// through its normal node serialization path. That keeps undo/reparse adoption
// and caret behavior identical to the rest of NODES.

import 'package:flutter/material.dart';

import 'structural_chrome.dart';
import 'ui_theme.dart';

class StructuralChromeControls extends StatelessWidget {
  final R3Theme theme;
  final TextEditingController windowTitleController;
  final String overlayMode;
  final TextEditingController topOverlayController;
  final TextEditingController bottomOverlayController;
  final ValueChanged<String> onWindowTitleChanged;
  final ValueChanged<String> onOverlayModeChanged;
  final ValueChanged<String> onTopOverlayChanged;
  final ValueChanged<String> onBottomOverlayChanged;

  const StructuralChromeControls({
    super.key,
    required this.theme,
    required this.windowTitleController,
    required this.overlayMode,
    required this.topOverlayController,
    required this.bottomOverlayController,
    required this.onWindowTitleChanged,
    required this.onOverlayModeChanged,
    required this.onTopOverlayChanged,
    required this.onBottomOverlayChanged,
  });

  StructuralOverlayMode get _mode =>
      structuralOverlayModeFromToken(overlayMode) ??
      StructuralOverlayMode.defaultOverlay;

  @override
  Widget build(BuildContext context) {
    final StructuralOverlayMode mode = _mode;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _textField(
          key: const ValueKey<String>('struct-window-title'),
          label: 'Window title',
          controller: windowTitleController,
          hintText: 'Uses the STRUCT source name when blank',
          onChanged: onWindowTitleChanged,
        ),
        SizedBox(height: sc(16)),
        R3MicroLabel('Overlay', theme: theme),
        SizedBox(height: sc(7)),
        _choice(
          current: mode,
          mode: StructuralOverlayMode.defaultOverlay,
          label: 'DEFAULT',
          description: 'Keep the current frame/status overlays.',
        ),
        _choice(
          current: mode,
          mode: StructuralOverlayMode.custom,
          label: 'CUSTOM',
          description: 'Replace the top and bottom informational copy.',
        ),
        _choice(
          current: mode,
          mode: StructuralOverlayMode.none,
          label: 'NONE',
          description: 'Hide informational overlays; keep the window title.',
        ),
        if (mode == StructuralOverlayMode.custom) ...[
          SizedBox(height: sc(14)),
          _textField(
            key: const ValueKey<String>('struct-top-overlay'),
            label: 'Custom top',
            controller: topOverlayController,
            hintText: 'Right side of the window title bar',
            onChanged: onTopOverlayChanged,
          ),
          SizedBox(height: sc(12)),
          _textField(
            key: const ValueKey<String>('struct-bottom-overlay'),
            label: 'Custom bottom',
            controller: bottomOverlayController,
            hintText: 'Lower-left player overlay',
            onChanged: onBottomOverlayChanged,
          ),
        ],
        SizedBox(height: sc(6)),
        Text(
          mode == StructuralOverlayMode.custom
              ? 'CUSTOM COPY IS PLACEMENT-OWNED AND BAKES WITH THIS STRUCT.'
              : 'CUSTOM COPY IS KEPT WHEN YOU SWITCH MODES AND RETURNS WHEN CUSTOM IS SELECTED AGAIN.',
          style: theme.fine.copyWith(
            color: R3Theme.textDim,
            height: 1.35,
          ),
        ),
      ],
    );
  }

  Widget _choice({
    required StructuralOverlayMode current,
    required StructuralOverlayMode mode,
    required String label,
    required String description,
  }) {
    final bool selected = current == mode;
    return InkWell(
      key: ValueKey<String>('struct-overlay-${mode.token.toLowerCase()}'),
      onTap: () => onOverlayModeChanged(mode.token),
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: sc(6)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: sc(16),
              height: sc(16),
              margin: EdgeInsets.only(top: sc(2)),
              decoration: BoxDecoration(
                color: selected ? theme.accentFaint : Colors.transparent,
                borderRadius: BorderRadius.circular(3),
                border: Border.all(
                  color: selected ? theme.accentDim : R3Theme.hairline,
                ),
              ),
              child: selected
                  ? Icon(Icons.check, size: sc(12), color: theme.accent)
                  : null,
            ),
            SizedBox(width: sc(10)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: theme.micro),
                  SizedBox(height: sc(2)),
                  Text(description, style: theme.fine),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _textField({
    required Key key,
    required String label,
    required TextEditingController controller,
    required String hintText,
    required ValueChanged<String> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        R3MicroLabel(label, theme: theme),
        SizedBox(height: sc(6)),
        TextField(
          key: key,
          controller: controller,
          style: theme.value,
          decoration: InputDecoration(
            isDense: true,
            hintText: hintText,
          ),
          onChanged: onChanged,
        ),
      ],
    );
  }
}
