// ./lib/r3_color_picker.dart
//
// Compact dependency-free color picker for r3nder authoring surfaces.
//
// The editor stores several colors as RGB source values, but authors should not
// have to think in comma-separated channels. This picker uses Flutter's HSVColor
// for visual selection and keeps an exact hexadecimal entry path for precision.

import 'package:flutter/material.dart';

import 'ui_theme.dart';

String r3ColorHex(Color color) {
  final int value = color.toARGB32();
  final int rgb = value & 0x00FFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

Color? parseR3HexColor(String value) {
  String text = value.trim();
  if (text.startsWith('#')) text = text.substring(1);
  if (text.length != 6) return null;
  final int? rgb = int.tryParse(text, radix: 16);
  if (rgb == null) return null;
  return Color(0xFF000000 | rgb);
}

Future<Color?> showR3ColorPicker({
  required BuildContext context,
  required Color initialColor,
  required R3Theme theme,
  String title = 'COLOR',
}) {
  return showDialog<Color>(
    context: context,
    builder: (BuildContext context) => _R3ColorPickerDialog(
      initialColor: initialColor,
      theme: theme,
      title: title,
    ),
  );
}

class _R3ColorPickerDialog extends StatefulWidget {
  const _R3ColorPickerDialog({
    required this.initialColor,
    required this.theme,
    required this.title,
  });

  final Color initialColor;
  final R3Theme theme;
  final String title;

  @override
  State<_R3ColorPickerDialog> createState() => _R3ColorPickerDialogState();
}

class _R3ColorPickerDialogState extends State<_R3ColorPickerDialog> {
  static const List<Color> _presets = <Color>[
    Color(0xFF0C0C10),
    Color(0xFF13131A),
    Color(0xFF1E1E26),
    Color(0xFF202632),
    Color(0xFF263140),
    Color(0xFF332D2A),
    Color(0xFF3A303B),
    Color(0xFFE8E6E3),
  ];

  late HSVColor _hsv;
  late final TextEditingController _hexController;
  String? _hexError;

  Color get _color => _hsv.toColor();

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initialColor);
    _hexController = TextEditingController(text: r3ColorHex(widget.initialColor));
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  void _syncHex() {
    final String text = r3ColorHex(_color);
    _hexController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _setColor(Color color) {
    setState(() {
      _hsv = HSVColor.fromColor(color);
      _hexError = null;
      _syncHex();
    });
  }

  void _setSv(Offset localPosition, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final double saturation =
        (localPosition.dx / size.width).clamp(0.0, 1.0).toDouble();
    final double value =
        (1.0 - (localPosition.dy / size.height))
            .clamp(0.0, 1.0)
            .toDouble();
    setState(() {
      _hsv = _hsv
          .withSaturation(saturation)
          .withValue(value);
      _hexError = null;
      _syncHex();
    });
  }

  void _setHue(Offset localPosition, Size size) {
    if (size.width <= 0) return;
    final double hue =
        ((localPosition.dx / size.width)
                    .clamp(0.0, 1.0)
                    .toDouble() *
                359.999)
            .toDouble();
    setState(() {
      _hsv = _hsv.withHue(hue);
      _hexError = null;
      _syncHex();
    });
  }

  void _applyHex(String value) {
    final Color? parsed = parseR3HexColor(value);
    setState(() {
      if (parsed == null) {
        _hexError = 'Use six hex digits, for example #1E1E26.';
        return;
      }
      _hsv = HSVColor.fromColor(parsed);
      _hexError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final Color color = _color;
    final int argb = color.toARGB32();
    final int red = (argb >> 16) & 0xFF;
    final int green = (argb >> 8) & 0xFF;
    final int blue = argb & 0xFF;

    return AlertDialog(
      backgroundColor: R3Theme.panel,
      title: Text(widget.title, style: widget.theme.value),
      content: SizedBox(
        width: sc(420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SaturationValueSquare(
              hsv: _hsv,
              onChanged: _setSv,
            ),
            SizedBox(height: sc(12)),
            _HueStrip(
              hue: _hsv.hue,
              onChanged: _setHue,
            ),
            SizedBox(height: sc(12)),
            Row(
              children: [
                Container(
                  key: const ValueKey<String>('r3-color-current-swatch'),
                  width: sc(54),
                  height: sc(54),
                  decoration: BoxDecoration(
                    color: color,
                    border: Border.all(color: R3Theme.textMid),
                    borderRadius: BorderRadius.circular(sc(3)),
                  ),
                ),
                SizedBox(width: sc(12)),
                Expanded(
                  child: TextFormField(
                    key: const ValueKey<String>('r3-color-hex-field'),
                    controller: _hexController,
                    decoration: InputDecoration(
                      labelText: 'HEX',
                      hintText: '#1E1E26',
                      errorText: _hexError,
                    ),
                    style: widget.theme.value,
                    textCapitalization: TextCapitalization.characters,
                    onChanged: _applyHex,
                  ),
                ),
              ],
            ),
            SizedBox(height: sc(7)),
            Text(
              'RGB  $red, $green, $blue',
              key: const ValueKey<String>('r3-color-rgb-readout'),
              style: widget.theme.fine.copyWith(color: R3Theme.textMid),
            ),
            SizedBox(height: sc(12)),
            Text('QUICK COLORS', style: widget.theme.microAccent),
            SizedBox(height: sc(6)),
            Wrap(
              spacing: sc(7),
              runSpacing: sc(7),
              children: List<Widget>.generate(
                _presets.length,
                (int index) {
                  final Color preset = _presets[index];
                  return Tooltip(
                    message: r3ColorHex(preset),
                    child: InkWell(
                      key: ValueKey<String>('r3-color-preset-$index'),
                      onTap: () => _setColor(preset),
                      borderRadius: BorderRadius.circular(sc(3)),
                      child: Container(
                        width: sc(34),
                        height: sc(28),
                        decoration: BoxDecoration(
                          color: preset,
                          border: Border.all(
                            color: preset.toARGB32() == color.toARGB32()
                                ? widget.theme.accent
                                : R3Theme.hairline,
                            width: preset.toARGB32() == color.toARGB32()
                                ? 2
                                : 1,
                          ),
                          borderRadius: BorderRadius.circular(sc(3)),
                        ),
                      ),
                    ),
                  );
                },
              ),
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
          key: const ValueKey<String>('r3-color-apply'),
          onPressed: _hexError == null
              ? () => Navigator.of(context).pop(_color)
              : null,
          child: const Text('USE COLOR'),
        ),
      ],
    );
  }
}

typedef _ColorPositionChanged = void Function(Offset position, Size size);

class _SaturationValueSquare extends StatelessWidget {
  const _SaturationValueSquare({
    required this.hsv,
    required this.onChanged,
  });

  final HSVColor hsv;
  final _ColorPositionChanged onChanged;

  @override
  Widget build(BuildContext context) {
    final Color hueColor = HSVColor.fromAHSV(1.0, hsv.hue, 1.0, 1.0).toColor();

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size size = Size(constraints.maxWidth, sc(190));
        void update(Offset position) => onChanged(position, size);

        return GestureDetector(
          key: const ValueKey<String>('r3-color-sv-square'),
          behavior: HitTestBehavior.opaque,
          onTapDown: (TapDownDetails details) => update(details.localPosition),
          onPanStart: (DragStartDetails details) => update(details.localPosition),
          onPanUpdate: (DragUpdateDetails details) => update(details.localPosition),
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: hueColor,
                      borderRadius: BorderRadius.circular(sc(3)),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: <Color>[
                          Colors.white,
                          Color(0x00FFFFFF),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(sc(3)),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: <Color>[
                          Color(0x00000000),
                          Colors.black,
                        ],
                      ),
                      borderRadius: BorderRadius.circular(sc(3)),
                      border: Border.all(color: R3Theme.hairline),
                    ),
                  ),
                ),
                Positioned(
                  left: hsv.saturation * size.width - sc(7),
                  top: (1.0 - hsv.value) * size.height - sc(7),
                  child: IgnorePointer(
                    child: Container(
                      width: sc(14),
                      height: sc(14),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: hsv.toColor(),
                        border: Border.all(
                          color: Colors.white,
                          width: 2,
                        ),
                        boxShadow: const <BoxShadow>[
                          BoxShadow(
                            color: Colors.black54,
                            blurRadius: 2,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _HueStrip extends StatelessWidget {
  const _HueStrip({
    required this.hue,
    required this.onChanged,
  });

  final double hue;
  final _ColorPositionChanged onChanged;

  static const List<Color> _hues = <Color>[
    Color(0xFFFF0000),
    Color(0xFFFFFF00),
    Color(0xFF00FF00),
    Color(0xFF00FFFF),
    Color(0xFF0000FF),
    Color(0xFFFF00FF),
    Color(0xFFFF0000),
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size size = Size(constraints.maxWidth, sc(22));
        void update(Offset position) => onChanged(position, size);

        return GestureDetector(
          key: const ValueKey<String>('r3-color-hue-strip'),
          behavior: HitTestBehavior.opaque,
          onTapDown: (TapDownDetails details) => update(details.localPosition),
          onPanStart: (DragStartDetails details) => update(details.localPosition),
          onPanUpdate: (DragUpdateDetails details) => update(details.localPosition),
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(colors: _hues),
                      border: Border.all(color: R3Theme.hairline),
                      borderRadius: BorderRadius.circular(sc(3)),
                    ),
                  ),
                ),
                Positioned(
                  left: (hue / 360.0) * size.width - sc(3),
                  top: -sc(3),
                  child: IgnorePointer(
                    child: Container(
                      width: sc(6),
                      height: size.height + sc(6),
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        border: Border.all(
                          color: Colors.white,
                          width: 2,
                        ),
                        borderRadius: BorderRadius.circular(sc(2)),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
