// ./test/editor_structural_chrome_close_handoff_test.dart

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/editor_screen.dart';

void main() {
  testWidgets('EditorScreen keeps CUSTOM STRUCT chrome through NODES EDIT close',
      (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final Directory root =
        Directory.systemTemp.createTempSync('r3_struct_close_handoff_');
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

    final Finder custom =
        find.byKey(const ValueKey<String>('struct-overlay-custom'));
    await tester.ensureVisible(custom);
    await tester.tap(custom);
    await tester.pump();

    final Finder title =
        find.byKey(const ValueKey<String>('struct-window-title'));
    final Finder top =
        find.byKey(const ValueKey<String>('struct-top-overlay'));
    final Finder bottom =
        find.byKey(const ValueKey<String>('struct-bottom-overlay'));

    await tester.ensureVisible(title);
    await tester.enterText(title, 'MONITOR [frame]');
    await tester.pump();
    await tester.ensureVisible(top);
    await tester.enterText(top, 'FRAME [frame]');
    await tester.pump();
    await tester.ensureVisible(bottom);
    await tester.enterText(bottom, 'REEL [frame]');
    await tester.pump();

    // Mirror the real workflow: the author checks the structural result in
    // EDIT before leaving the editor and returning to the dashboard BAKE.
    await tester.tap(find.text('EDIT').first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Back (Esc)'));
    await tester.pump();

    expect(
      closedText,
      '[STRUCT:MOSAIC.wall:OVERLAY=CUSTOM:TITLE="MONITOR [frame]":TOP="FRAME [frame]":BOTTOM="REEL [frame]"]\n',
    );
  });
}
