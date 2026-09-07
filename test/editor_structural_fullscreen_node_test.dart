// ./test/editor_structural_fullscreen_node_test.dart

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/editor_node_workspace.dart';
import 'package:r3nder/script_nodes.dart';
import 'package:r3nder/ui_theme.dart';

const String _source = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:clip:video/file.mp4:0:10:10:1]
    [/CLIP]
  [/TRACK]
[/EDIT]
[MOSAIC:mosaic_2]
  [PANE:pane1]
    [CLIP:edit_main:EDIT.main:0:0:10:1]
    [/CLIP]
  [/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.mosaic_2]
''';

void main() {
  testWidgets(
      'existing generated STRUCT node owns source and fullscreen controls',
      (WidgetTester tester) async {
    final Directory root =
        Directory.systemTemp.createTempSync('r3_struct_node_test_');
    final Directory images = Directory('${root.path}/images')..createSync();
    final Directory sprites = Directory('${root.path}/sprites')..createSync();
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    final List<ScriptNode> parsed = parseScriptToNodes(_source);
    final int structIndex =
        parsed.indexWhere((ScriptNode node) => node.type == 'STRUCT');
    expect(structIndex, greaterThanOrEqualTo(0));

    String changed = _source;
    final R3Theme theme = R3Theme.of(const Color(0xFF00FF00));

    await tester.pumpWidget(
      MaterialApp(
        theme: theme.materialTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 1280,
            height: 720,
            child: EditorNodeWorkspace(
              initialText: _source,
              theme: theme,
              highlightedLine: -1,
              imagesDir: images.path,
              spritesDir: sprites.path,
              initialSelectedNodeIndex: structIndex,
              onTextChanged: (String value) => changed = value,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('STRUCT SETTINGS'), findsOneWidget);
    expect(find.text('SOURCE'), findsOneWidget);
    expect(find.text('FULL SCREEN'), findsOneWidget);
    expect(find.text('RAW MARKUP'), findsNothing);
    expect(find.text('MOSAIC.mosaic_2'), findsWidgets);

    await tester.tap(find.text('FULL SCREEN'));
    await tester.pump();

    expect(changed, contains('[STRUCT:MOSAIC.mosaic_2:FULL]'));
    expect(changed, isNot(contains('[STRUCT:MOSAIC.mosaic_2]\n')));

    await tester.tap(find.text('FULL SCREEN'));
    await tester.pump();

    expect(changed, contains('[STRUCT:MOSAIC.mosaic_2]\n'));
    expect(changed, isNot(contains('[STRUCT:MOSAIC.mosaic_2:FULL]')));
  });
}
