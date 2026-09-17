// ./test/marker_focus_test.dart

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/editor_screen.dart';

void main() {
  testWidgets('M stays printable while the script TextField owns focus',
      (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final Directory root =
        Directory.systemTemp.createTempSync('r3_marker_focus_');
    final Directory images = Directory('${root.path}/images')..createSync();
    final Directory sprites = Directory('${root.path}/sprites')..createSync();
    final File template = File('${root.path}/template.txt')
      ..writeAsStringSync('alpha');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditorScreen(
            templatePath: template.path,
            initialText: 'alpha',
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
            onClose: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder editor = find.byType(TextField);
    expect(editor, findsOneWidget);

    await tester.tap(editor);
    await tester.pump();

    TextField field = tester.widget<TextField>(editor);
    expect(field.controller!.text, 'alpha');

    // A physical M key event must not escape the focused editor and author a
    // timeline MARK. Widget tests do not synthesize platform text input from a
    // hardware key event, so the second assertion below separately proves that
    // ordinary text input still accepts the printable character.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();

    field = tester.widget<TextField>(editor);
    expect(field.controller!.text, 'alpha');
    expect(field.controller!.text, isNot(contains('[MARK:')));

    await tester.enterText(editor, 'm');
    await tester.pump();

    field = tester.widget<TextField>(editor);
    expect(field.controller!.text, 'm');
    expect(field.controller!.text, isNot(contains('[MARK:')));
  });
}
