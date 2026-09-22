// ./test/editor_structural_split_node_test.dart

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/editor_node_workspace.dart';
import 'package:r3nder/script_nodes.dart';
import 'package:r3nder/ui_theme.dart';

const String _source = '''[EDIT:left]
[TRACK:V1]
[CLIP:left_clip:video/left.mp4:0:0:30:1]
[/CLIP]
[/TRACK]
[/EDIT]
[EDIT:right]
[TRACK:V1]
[CLIP:right_clip:video/right.mp4:0:0:30:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:pane1]
[CLIP:left:EDIT.left:0:0:30:1]
[/CLIP]
[/PANE]
[PANE:pane2]
[CLIP:right:EDIT.right:0:0:30:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall:FULL]
''';

void main() {
  testWidgets('STRUCT node authors SPLIT aspect and keeps FULL exclusive',
      (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final Directory root =
        Directory.systemTemp.createTempSync('r3_struct_split_node_');
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
          body: EditorNodeWorkspace(
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
    );
    await tester.pumpAndSettle();

    expect(find.text('FULL SCREEN'), findsOneWidget);
    expect(find.text('TWO WINDOWS'), findsOneWidget);
    expect(find.text('CLIENT ASPECT'), findsNothing);

    final Finder twoWindows = find.text('TWO WINDOWS');
    await tester.ensureVisible(twoWindows);
    await tester.tap(twoWindows);
    await tester.pump();

    expect(changed, contains('[STRUCT:MOSAIC.wall:SPLIT]'));
    expect(changed, isNot(contains('[STRUCT:MOSAIC.wall:FULL]')));
    expect(find.text('MAXIMIZE SPLIT'), findsOneWidget);
    expect(find.text('CLIENT ASPECT'), findsOneWidget);

    final Finder maximizeSplit = find.text('MAXIMIZE SPLIT');
    await tester.ensureVisible(maximizeSplit);
    await tester.tap(maximizeSplit);
    await tester.pump();

    expect(changed, contains('[STRUCT:MOSAIC.wall:SPLIT:MAX]'));

    final Finder aspectLabel = find.text('CLIENT ASPECT');
    final Finder aspectRow = find.ancestor(
      of: aspectLabel,
      matching: find.byType(Row),
    ).first;
    final Finder aspectDropdown = find.descendant(
      of: aspectRow,
      matching: find.byType(DropdownButton<String>),
    );
    expect(aspectDropdown, findsOneWidget);

    await tester.tap(aspectDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('4X3').last);
    await tester.pumpAndSettle();

    expect(
      changed,
      contains('[STRUCT:MOSAIC.wall:SPLIT:MAX:ASPECT=4X3]'),
    );

    // The aspect dropdown sits below the presentation toggles. On the real
    // inspector-sized test viewport, bringing it into view can lazily unbuild
    // the earlier FULL SCREEN row. Scroll the properties panel back upward
    // before exercising the reciprocal FULL -> clears SPLIT contract.
    await tester.drag(
      find.byType(Scrollable).last,
      const Offset(0, 500),
    );
    await tester.pumpAndSettle();

    final Finder fullScreen = find.text('FULL SCREEN');
    expect(fullScreen, findsOneWidget);
    await tester.tap(fullScreen);
    await tester.pump();

    expect(changed, contains('[STRUCT:MOSAIC.wall:FULL]'));
    expect(changed, isNot(contains(':SPLIT')));
    expect(changed, isNot(contains(':MAX')));
    expect(changed, isNot(contains(':ASPECT=')));
    expect(find.text('CLIENT ASPECT'), findsNothing);
  });
}
