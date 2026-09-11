// ./test/edit_clip_inspector_test.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_surface.dart';
import 'package:r3nder/ui_theme.dart';

const String _source = '''[EDIT:main]\n  [TRACK:V1]\n    [CLIP:intro:video/intro.mp4:10:20:40:1]\n    [/CLIP]\n    [CLIP:later:video/later.mp4:90:0:20:1]\n    [/CLIP]\n  [/TRACK]\n  [TRACK:V2]\n    [CLIP:overlay:video/overlay.mp4:25:5:30:2]\n    [/CLIP]\n  [/TRACK]\n[/EDIT]\n''';

Widget _host({
  required ValueChanged<String> onSourceChanged,
  bool withTextField = false,
}) {
  final R3Theme theme = R3Theme.of(const Color(0xFF00FF00));
  final Widget edit = Expanded(
    child: EditSurface(
      source: _source,
      editId: 'main',
      currentFrame: 0,
      theme: theme,
      onSourceChanged: onSourceChanged,
      onSeek: (_) {},
    ),
  );

  return MaterialApp(
    theme: theme.materialTheme(),
    home: Scaffold(
      body: SizedBox(
        width: 1280,
        height: 720,
        child: Column(
          children: [
            if (withTextField)
              const SizedBox(
                height: 42,
                child: TextField(
                  key: ValueKey<String>('outside-edit-text-field'),
                ),
              ),
            edit,
          ],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('inspector projects selected authored CLIP properties',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(onSourceChanged: (_) {}));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('edit-clip-inspector')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('edit-inspector-empty')),
      findsOneWidget,
    );

    await tester.tap(find.text('overlay'));
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('edit-inspector-empty')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('edit-inspector-clip-id')),
      findsOneWidget,
    );
    expect(find.text('video/overlay.mp4'), findsOneWidget);
    expect(find.text('V2'), findsWidgets);
    expect(find.text('F25'), findsOneWidget);
    expect(find.text('F5'), findsOneWidget);
    expect(find.text('F63'), findsOneWidget);
    expect(find.text('30F'), findsOneWidget);
    expect(find.text('2X'), findsOneWidget);
  });

  testWidgets('inspector delete removes selected clip and clears selection',
      (WidgetTester tester) async {
    String? changed;
    await tester.pumpWidget(_host(onSourceChanged: (String value) {
      changed = value;
    }));
    await tester.pumpAndSettle();

    await tester.tap(find.text('intro'));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('edit-inspector-delete')),
    );
    await tester.pumpAndSettle();

    expect(changed, isNotNull);
    expect(changed, isNot(contains('[CLIP:intro:')));
    expect(changed, contains('[CLIP:later:video/later.mp4:90:0:20:1]'));
    expect(changed, contains('[CLIP:overlay:video/overlay.mp4:25:5:30:2]'));
    expect(
      find.byKey(const ValueKey<String>('edit-inspector-empty')),
      findsOneWidget,
    );
  });

  testWidgets('Delete key removes selected clip when timeline owns focus',
      (WidgetTester tester) async {
    String? changed;
    await tester.pumpWidget(_host(onSourceChanged: (String value) {
      changed = value;
    }));
    await tester.pumpAndSettle();

    await tester.tap(find.text('intro'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();

    expect(changed, isNotNull);
    expect(changed, isNot(contains('[CLIP:intro:')));
    expect(changed, contains('[CLIP:later:video/later.mp4:90:0:20:1]'));
  });

  testWidgets('Delete key is ignored while a text field owns focus',
      (WidgetTester tester) async {
    String? changed;
    await tester.pumpWidget(
      _host(
        withTextField: true,
        onSourceChanged: (String value) {
          changed = value;
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('intro'));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('outside-edit-text-field')),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();

    expect(changed, isNull);
    expect(find.text('intro'), findsWidgets);
  });
}
