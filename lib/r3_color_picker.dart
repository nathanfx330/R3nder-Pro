// ./lib/r3_color_picker.dart
//
// Compact HSV color picker used by r3nder authoring controls.
//
// The durable script format remains whatever the caller owns. This widget
// returns only a Color, so CARD authoring can continue serializing panel
// colors as canonical r,g,b values without coupling script syntax to UI.

import 'package:flutter/material.dart';

import 'ui_theme.dart';

Future<Color?> showR3ColorPicker({
  required BuildContext context,
  required Color initialColor,
  String title = 'COLOR',
}) {
  return showDialog<Color>(
    context: context,
    builder: (BuildContext context) => _R3ColorPickerDialog(
      initialColor: initialColor,
      title: title,
    ),
  );
}

String r3ColorHex(Color color) {
  final int rgb = color.toARGB32() & 0x00FFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

Color? parseR3ColorHex(String raw) {
  String value = raw.trim();
  if (value.startsWith('#')) value = value.substring(1);
  if (value.length == 3) {
    value = value.split('').map((String c) => '$c$c').join();
  }
  if (value.length != 6) return null;
  final int? rgb = int.tryParse(value, radix: 16);
  if (rgb == null) return null;
  return Color(0xFF000000 | rgb);
}

class _R3ColorPickerDialog extends StatefulWidget {
  const _R3ColorPickerDialog({
    required this.initialColor,
    required this.title,
  });

  final Color initialColor;
  final String title;

  @override
  State<_R3ColorPickerDialog> createState() => _R3ColorPickerDialogState();
}

class _R3ColorPickerDialogState extends State<_R3ColorPickerDialog> {
  late HSVColor _hsv;
  late final TextEditingController _hexController;

  static const List<Color> _quickColors = <Color>[
    Color(0xFF0C0C10),
    Color(0xFF13131A),
    Color(0xFF1E1E26),
    Color(0xFF182028),
    Color(0xFF242A33),
    Color(0xFF2A2230),
    Color(0xFF2B2520),
    Color(0xFF202A25),
  ];

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

  Color get _color => _hsv.toColor().withValues(alpha: 1.0);

  void _setHsv(HSVColor hsv, {bool syncHex = true}) {
    setState(() {
      _hsv = hsv;
      if (syncHex) {
        _hexController.value = TextEditingValue(
          text: r3ColorHex(_color),
          selection: TextSelection.collapsed(
            offset: r3ColorHex(_color).length,
          ),
        );
      }
    });
  }

  void _setColor(Color color) {
    _setHsv(HSVColor.fromColor(color));
  }

  void _setSvFromOffset(Offset local, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final double saturation =
        (local.dx / size.width).clamp(0.0, 1.0).toDouble();
    final double value =
        (1.0 - local.dy / size.height).clamp(0.0, 1.0).toDouble();
    _setHsv(_hsv.withSaturation(saturation).withValue(value));
  }

  void _setHueFromOffset(Offset local, Size size) {
    if (size.width <= 0) return;
    final double hue =
        (local.dx / size.width).clamp(0.0, 1.0).toDouble() * 360.0;
    _setHsv(_hsv.withHue(hue == 360.0 ? 0.0 : hue));
  }

  @override
  Widget build(BuildContext context) {
    final R3Theme theme = R3Theme.of(Theme.of(context).colorScheme.primary);
    final Color hueColor = HSVColor.fromAHSV(1.0, _hsv.hue, 1.0, 1.0).toColor();
    final int argb = _color.toARGB32();
    final int red = (argb >> 16) & 0xFF;
    final int green = (argb >> 8) & 0xFF;
    final int blue = argb & 0xFF;

    return AlertDialog(
      key: const ValueKey<String>('r3-color-picker-dialog'),
      backgroundColor: R3Theme.panel,
      titlePadding: EdgeInsets.fromLTRB(sc(18), sc(16), sc(18), sc(8)),
      contentPadding: EdgeInsets.fromLTRB(sc(18), 0, sc(18), sc(10)),
      actionsPadding: EdgeInsets.fromLTRB(sc(10), 0, sc(10), sc(10)),
      title: Row(
        children: [
          Expanded(
            child: Text(widget.title, style: theme.value),
          ),
          Container(
            key: const ValueKey<String>('r3-color-picker-current-swatch'),
            width: sc(42),
            height: sc(24),
            decoration: BoxDecoration(
              color: _color,
              border: Border.all(color: R3Theme.textDim),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: sc(390),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('SATURATION / VALUE', style: theme.microAccent),
              SizedBox(height: sc(6)),
              SizedBox(
                key: const ValueKey<String>('r3-color-picker-sv'),
                height: sc(210),
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final Size size = Size(
                      constraints.maxWidth,
                      constraints.maxHeight,
                    );
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (TapDownDetails details) {
                        _setSvFromOffset(details.localPosition, size);
                      },
                      onPanStart: (DragStartDetails details) {
                        _setSvFromOffset(details.localPosition, size);
                      },
                      onPanUpdate: (DragUpdateDetails details) {
                        _setSvFromOffset(details.localPosition, size);
                      },
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            ColoredBox(color: hueColor),
                            const DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: <Color>[
                                    Colors.white,
                                    Color(0x00FFFFFF),
                                  ],
                                ),
                              ),
                            ),
                            const DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: <Color>[
                                    Color(0x00000000),
                                    Colors.black,
                                  ],
                                ),
                              ),
                            ),
                            IgnorePointer(
                              child: CustomPaint(
                                painter: _SvThumbPainter(
                                  saturation: _hsv.saturation,
                                  value: _hsv.value,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              SizedBox(height: sc(12)),
              Text('HUE', style: theme.microAccent),
              SizedBox(height: sc(6)),
              SizedBox(
                key: const ValueKey<String>('r3-color-picker-hue'),
                height: sc(24),
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final Size size = Size(
                      constraints.maxWidth,
                      constraints.maxHeight,
                    );
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (TapDownDetails details) {
                        _setHueFromOffset(details.localPosition, size);
                      },
                      onPanStart: (DragStartDetails details) {
                        _setHueFromOffset(details.localPosition, size);
                      },
                      onPanUpdate: (DragUpdateDetails details) {
                        _setHueFromOffset(details.localPosition, size);
                      },
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            const DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: <Color>[
                                    Color(0xFFFF0000),
                                    Color(0xFFFFFF00),
                                    Color(0xFF00FF00),
                                    Color(0xFF00FFFF),
                                    Color(0xFF0000FF),
                                    Color(0xFFFF00FF),
                                    Color(0xFFFF0000),
                                  ],
                                ),
                              ),
                            ),
                            IgnorePointer(
                              child: CustomPaint(
                                painter: _HueThumbPainter(hue: _hsv.hue),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              SizedBox(height: sc(12)),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey<String>('r3-color-picker-hex-field'),
                      controller: _hexController,
                      decoration: const InputDecoration(
                        labelText: 'Hex',
                        hintText: '#182028',
                      ),
                      style: theme.value,
                      onChanged: (String value) {
                        final Color? parsed = parseR3ColorHex(value);
                        if (parsed == null) return;
                        _setHsv(HSVColor.fromColor(parsed), syncHex: false);
                      },
                    ),
                  ),
                  SizedBox(width: sc(10)),
                  Expanded(
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
                      child: Text(
                        'RGB  $red, $green, $blue',
                        key: const ValueKey<String>('r3-color-picker-rgb-value'),
                        style: theme.valueDim,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: sc(12)),
              Text('QUICK COLORS', style: theme.microAccent),
              SizedBox(height: sc(6)),
              Wrap(
                spacing: sc(7),
                runSpacing: sc(7),
                children: [
                  for (final Color color in _quickColors)
                    InkWell(
                      key: ValueKey<String>(
                        'r3-color-picker-quick-${r3ColorHex(color)}',
                      ),
                      onTap: () => _setColor(color),
                      borderRadius: BorderRadius.circular(3),
                      child: Container(
                        width: sc(36),
                        height: sc(28),
                        decoration: BoxDecoration(
                          color: color,
                          border: Border.all(
                            color: color.toARGB32() == _color.toARGB32()
                                ? theme.accent
                                : R3Theme.hairline,
                            width: color.toARGB32() == _color.toARGB32()
                                ? 2
                                : 1,
                          ),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('CANCEL'),
        ),
        TextButton(
          key: const ValueKey<String>('r3-color-picker-apply'),
          onPressed: () => Navigator.of(context).pop(_color),
          child: const Text('USE COLOR'),
        ),
      ],
    );
  }
}

class _SvThumbPainter extends CustomPainter {
  const _SvThumbPainter({
    required this.saturation,
    required this.value,
  });

  final double saturation;
  final double value;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(
      size.width * saturation,
      size.height * (1.0 - value),
    );
    canvas.drawCircle(
      center,
      7,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = Colors.black.withValues(alpha: 0.75),
    );
    canvas.drawCircle(
      center,
      5.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_SvThumbPainter oldDelegate) {
    return saturation != oldDelegate.saturation || value != oldDelegate.value;
  }
}

class _HueThumbPainter extends CustomPainter {
  const _HueThumbPainter({required this.hue});

  final double hue;

  @override
  void paint(Canvas canvas, Size size) {
    final double x = size.width * (hue / 360.0);
    final RRect outer = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(x, size.height / 2),
        width: 7,
        height: size.height,
      ),
      const Radius.circular(2),
    );
    canvas.drawRRect(
      outer,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Colors.black.withValues(alpha: 0.75),
    );
    canvas.drawRRect(
      outer,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_HueThumbPainter oldDelegate) => hue != oldDelegate.hue;
}
