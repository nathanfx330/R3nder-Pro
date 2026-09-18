// ./test/r3_color_picker_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/r3_color_picker.dart';
import 'package:r3nder/ui_theme.dart';

void main() {
  test('hex helpers round-trip opaque RGB colors', () {
    const Color color = Color(0xFF182028);
    expect(r3ColorHex(color), '#182028');
    expect(parseR3HexColor('#182028')?.toARGB32(), 0xFF182028);
    expect(parseR3HexColor('182028')?.toARGB32(), 0xFF182028);
    expect(parseR3HexColor('#xyzxyz'), isNull);
    expect(parseR3HexColor('#1234'), isNull);
  });

  testWidgets('picker accepts exact hex and returns selected color',
      (WidgetTester tester) async {
    Color? picked;
    final R3Theme theme = R3Theme.of(const Color(0xFF00FF00));

    await tester.pumpWidget(
      MaterialApp(
        theme: theme.materialTheme(),
        home: Builder(
          builder: (BuildContext context) {
            return Center(
              child: TextButton(
                key: const ValueKey<String>('open-picker'),
                onPressed: () async {
                  picked = await showR3ColorPicker(
                    context: context,
                    initialColor: const Color(0xFF1E1E26),
                    theme: theme,
                    title: 'PANEL COLOR',
                  );
                },
                child: const Text('OPEN'),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey<String>('open-picker')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('r3-color-sv-square')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('r3-color-hue-strip')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('r3-color-current-swatch')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('r3-color-hex-field')),
      '#336699',
    );
    await tester.pump();

    expect(find.text('RGB  51, 102, 153'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('r3-color-apply')));
    await tester.pumpAndSettle();

    expect(picked, isNotNull);
    expect(picked!.toARGB32(), 0xFF336699);
  });
}
