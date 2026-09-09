// ./test/editor_structural_audio_node_test.dart

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/editor_node_workspace.dart';
import 'package:r3nder/editor_screen.dart';
import 'package:r3nder/ui_theme.dart';

const String _source = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:clip:video/file.mp4:0:10:30:1]
    [/CLIP]
  [/TRACK]
[/EDIT]
[STRUCT:EDIT.main:FULL:OVERLAY=CUSTOM:TITLE="Field Monitor":TOP="FEB 1972":BOTTOM="REEL 4"]
''';

void main() {
  testWidgets('STRUCT Audio control writes only the placement AUDIO token',
      (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final Directory root =
        Directory.systemTemp.createTempSync('r3_struct_audio_node_');
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

    expect(find.text('STRUCT SETTINGS'), findsOneWidget);
    expect(find.text('FULL SCREEN'), findsOneWidget);
    expect(find.text('AUDIO'), findsOneWidget);
    expect(
      find.text(
        'Play the audio belonging to clips in this sequence. Workspace voice '
        'and music beds are authored separately and are unaffected.',
      ),
      findsOneWidget,
    );

    final Finder audio = find.text('AUDIO');
    await tester.ensureVisible(audio);
    await tester.tap(audio);
    await tester.pump();

    expect(
      changed,
      contains(
        '[STRUCT:EDIT.main:FULL:AUDIO:OVERLAY=CUSTOM:TITLE="Field Monitor":TOP="FEB 1972":BOTTOM="REEL 4"]',
      ),
    );

    await tester.tap(audio);
    await tester.pump();

    expect(
      changed,
      contains(
        '[STRUCT:EDIT.main:FULL:OVERLAY=CUSTOM:TITLE="Field Monitor":TOP="FEB 1972":BOTTOM="REEL 4"]',
      ),
    );
    expect(changed, isNot(contains(':AUDIO')));
  });

  testWidgets('EditorScreen Audio toggle survives EDIT and Escape handoff',
      (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final Directory root =
        Directory.systemTemp.createTempSync('r3_struct_audio_ui_handoff_');
    final Directory images = Directory('${root.path}/images')..createSync();
    final Directory sprites = Directory('${root.path}/sprites')..createSync();
    final File template = File('${root.path}/template.txt')
      ..writeAsStringSync('[STRUCT:MOSAIC.wall]\n');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    String? closedText;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditorScreen(
            templatePath: template.path,
            initialText: '[STRUCT:MOSAIC.wall]\n',
            fontFamily: 'monospace',
            fontColor: Colors.green,
            bgColor: Colors.black,
            engineWidth: 1920,
            engineHeight: 1080,
            engineScale: 1,
            fontSize: 48,
            lineSpacing: 60,
            tracking: 0,
            marginTop: 100,
            marginSide: 100,
            imagesDir: images.path,
            spritesDir: sprites.path,
            onClose: (String text) => closedText = text,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('NODES'));
    await tester.pumpAndSettle();
    expect(find.text('STRUCT SETTINGS'), findsOneWidget);

    final Finder audio = find.text('AUDIO');
    await tester.ensureVisible(audio);
    await tester.tap(audio);
    await tester.pump();

    await tester.tap(find.text('EDIT').first);
    await tester.pumpAndSettle();
    expect(find.text('SOURCE OUTPUT'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(closedText, '[STRUCT:MOSAIC.wall:AUDIO]\n');
  });
}
