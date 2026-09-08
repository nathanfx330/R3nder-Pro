// ./test/structural_chrome_controls_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/structural_chrome_controls.dart';
import 'package:r3nder/ui_theme.dart';

class _Harness extends StatefulWidget {
  const _Harness();

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late final TextEditingController title;
  late final TextEditingController top;
  late final TextEditingController bottom;
  String mode = 'DEFAULT';

  @override
  void initState() {
    super.initState();
    title = TextEditingController(text: 'Archive Viewer');
    top = TextEditingController(text: 'FEB 1972');
    bottom = TextEditingController(text: '16MM TRANSFER · REEL 4');
  }

  @override
  void dispose() {
    title.dispose();
    top.dispose();
    bottom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Material(
        child: SizedBox(
          width: 420,
          child: StructuralChromeControls(
            theme: R3Theme.of(Colors.green),
            windowTitleController: title,
            overlayMode: mode,
            topOverlayController: top,
            bottomOverlayController: bottom,
            onWindowTitleChanged: (_) {},
            onOverlayModeChanged: (value) => setState(() => mode = value),
            onTopOverlayChanged: (_) {},
            onBottomOverlayChanged: (_) {},
          ),
        ),
      ),
    );
  }
}

void main() {
  testWidgets(
    'STRUCT chrome controls preserve dormant custom copy across mode changes',
    (WidgetTester tester) async {
      await tester.pumpWidget(const _Harness());

      expect(
        find.byKey(const ValueKey<String>('struct-window-title')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('struct-top-overlay')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('struct-bottom-overlay')),
        findsNothing,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('struct-overlay-custom')),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('struct-top-overlay')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('struct-bottom-overlay')),
        findsOneWidget,
      );
      expect(find.text('FEB 1972'), findsOneWidget);
      expect(find.text('16MM TRANSFER · REEL 4'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('struct-overlay-none')),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('struct-top-overlay')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('struct-bottom-overlay')),
        findsNothing,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('struct-overlay-custom')),
      );
      await tester.pump();

      expect(find.text('FEB 1972'), findsOneWidget);
      expect(find.text('16MM TRANSFER · REEL 4'), findsOneWidget);
    },
  );
}
