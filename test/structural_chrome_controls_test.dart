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
  String title = 'Archive Viewer';
  String mode = 'DEFAULT';
  String top = 'FEB 1972';
  String bottom = '16MM TRANSFER · REEL 4';

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Material(
        child: SizedBox(
          width: 420,
          child: StructuralChromeControls(
            theme: R3Theme.of(Colors.green),
            windowTitle: title,
            overlayMode: mode,
            topOverlay: top,
            bottomOverlay: bottom,
            onWindowTitleChanged: (value) => setState(() => title = value),
            onOverlayModeChanged: (value) => setState(() => mode = value),
            onTopOverlayChanged: (value) => setState(() => top = value),
            onBottomOverlayChanged: (value) => setState(() => bottom = value),
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
