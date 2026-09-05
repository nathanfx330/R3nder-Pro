// ./test/edit_workspace_sequence_placement_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_workspace.dart';
import 'package:r3nder/ui_theme.dart';

void main() {
  testWidgets('ADD TO SEQUENCE places selected structural source in main script',
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

    expect(changed, contains('[STRUCT:EDIT.main]'));
    expect(changed.endsWith('[STRUCT:EDIT.main]\n'), isTrue);
  });
}
