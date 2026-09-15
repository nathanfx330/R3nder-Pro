// ./test/edit_workspace_sequence_placement_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_workspace.dart';
import 'package:r3nder/ui_theme.dart';

void main() {
  testWidgets('ADD TO SEQUENCE places selected EDIT with clip audio enabled',
      (WidgetTester tester) async {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:base:video/base.mp4:0:0:24:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    String changed = source;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 1200,
          height: 800,
          child: EditWorkspace(
            source: source,
            currentFrame: 0,
            theme: R3Theme.of(Colors.green),
            onSourceChanged: (String value) => changed = value,
            onSeek: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder button = find.byKey(
      const ValueKey<String>('add-structural-to-sequence'),
    );
    expect(button, findsOneWidget);

    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(changed, contains('[STRUCT:EDIT.main:AUDIO]'));
    expect(changed.endsWith('[STRUCT:EDIT.main:AUDIO]\n'), isTrue);
  });

  testWidgets('ADD TO SEQUENCE places selected MOSAIC with clip audio enabled',
      (WidgetTester tester) async {
    const String source = '''[EDIT:child]
[TRACK:V1]
[CLIP:base:video/base.mp4:0:0:24:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:left]
[CLIP:nested:EDIT.child:0:0:24:1]
[/CLIP]
[/PANE]
[/MOSAIC]
''';

    String changed = source;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 1200,
          height: 800,
          child: EditWorkspace(
            source: source,
            currentFrame: 0,
            theme: R3Theme.of(Colors.green),
            onSourceChanged: (String value) => changed = value,
            onSeek: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder selector = find.byKey(
      const ValueKey<String>('structural-source-selector'),
    );
    expect(selector, findsOneWidget);

    await tester.tap(selector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('MOSAIC.wall').last);
    await tester.pumpAndSettle();

    final Finder button = find.byKey(
      const ValueKey<String>('add-structural-to-sequence'),
    );
    expect(button, findsOneWidget);

    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(changed, contains('[STRUCT:MOSAIC.wall:AUDIO]'));
    expect(changed.endsWith('[STRUCT:MOSAIC.wall:AUDIO]\n'), isTrue);
  });
}
