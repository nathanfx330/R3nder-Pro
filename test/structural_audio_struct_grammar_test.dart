// ./test/structural_audio_struct_grammar_test.dart

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/editor_screen.dart';
import 'package:r3nder/script_nodes.dart';
import 'package:r3nder/structural_chrome.dart';
import 'package:r3nder/structural_sequence.dart';

const String _editOnly = '''[EDIT:main]
[TRACK:V1]
[CLIP:a:video/a.mp4:0:0:30:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';

void main() {
  test('STRUCT AUDIO is a bare placement token with canonical serialization', () {
    const String authored =
        '[STRUCT:MOSAIC.wall:FULL:AUDIO:OVERLAY=CUSTOM:TITLE="MONITOR"]';

    final StructuralChromeSpec? spec = parseStructuralChromeTag(authored);
    expect(spec, isNotNull);
    expect(spec!.source, 'MOSAIC.wall');
    expect(spec.fullscreen, isTrue);
    expect(spec.clipAudio, isTrue);
    expect(spec.overlayMode, StructuralOverlayMode.custom);
    expect(spec.windowTitle, 'MONITOR');
    expect(formatStructuralChromeTag(spec), authored);

    final StructuralChromeSpec? reordered =
        parseStructuralChromeTag('[STRUCT:MOSAIC.wall:AUDIO:FULL]');
    expect(reordered, isNotNull);
    expect(reordered!.clipAudio, isTrue);
    expect(reordered.fullscreen, isTrue);
    expect(
      formatStructuralChromeTag(reordered),
      '[STRUCT:MOSAIC.wall:FULL:AUDIO]',
    );

    expect(
      parseStructuralChromeTag('[STRUCT:EDIT.main:AUDIO:AUDIO]'),
      isNull,
    );
  });

  test('STRUCT without AUDIO stays byte-identical and defaults off', () {
    const String authored =
        '[STRUCT:EDIT.main:OVERLAY=NONE:TITLE="Silent monitor"]';

    final StructuralChromeSpec? spec = parseStructuralChromeTag(authored);
    expect(spec, isNotNull);
    expect(spec!.clipAudio, isFalse);
    expect(formatStructuralChromeTag(spec), authored);

    final List<ScriptNode> nodes = parseScriptToNodes('$authored\n');
    final String roundTrip =
        nodes.map((ScriptNode node) => node.toMarkup()).join();
    expect(roundTrip, '$authored\n');
  });

  test('STRUCT node carries AUDIO through unrelated typed edits', () {
    final ScriptNode audio = parseScriptToNodes(
      '[STRUCT:EDIT.main:AUDIO]',
    ).firstWhere((ScriptNode node) => node.type == 'STRUCT');

    expect(audio.param('audio'), 'AUDIO');
    audio.set('title', 'MONITOR');
    expect(
      audio.toMarkup(),
      '[STRUCT:EDIT.main:AUDIO:TITLE="MONITOR"]',
    );

    final ScriptNode silent = parseScriptToNodes(
      '[STRUCT:EDIT.main]',
    ).firstWhere((ScriptNode node) => node.type == 'STRUCT');

    expect(silent.param('audio'), isEmpty);
    silent.set('title', 'MONITOR');
    expect(
      silent.toMarkup(),
      '[STRUCT:EDIT.main:TITLE="MONITOR"]',
    );
  });

  test('sequence placement carries AUDIO intent without changing timing', () {
    final StructuralSequencePlacement audio =
        parseStructuralSequencePlacements(
      '${_editOnly}[STRUCT:EDIT.main:AUDIO]\n',
    ).single;
    final StructuralSequencePlacement silent =
        parseStructuralSequencePlacements(
      '${_editOnly}[STRUCT:EDIT.main]\n',
    ).single;

    expect(audio.clipAudio, isTrue);
    expect(silent.clipAudio, isFalse);
    expect(audio.sourceDurationFrames, silent.sourceDurationFrames);
    expect(audio.durationFrames, silent.durationFrames);
    expect(audio.contentStartFrame, silent.contentStartFrame);
    expect(audio.contentEndFrameExclusive, silent.contentEndFrameExclusive);
  });

  test('append placement writes AUDIO only when authored', () {
    final StructuralSourceRef sourceRef =
        StructuralSourceRef.tryParse('EDIT.main')!;

    final String audio = appendStructuralSequencePlacement(
      rawDocument: _editOnly,
      sourceRef: sourceRef,
      clipAudio: true,
    );
    expect(audio, '${_editOnly}[STRUCT:EDIT.main:AUDIO]\n');

    final String silent = appendStructuralSequencePlacement(
      rawDocument: _editOnly,
      sourceRef: sourceRef,
    );
    expect(silent, '${_editOnly}[STRUCT:EDIT.main]\n');
  });

  testWidgets('EditorScreen preserves AUDIO through dirty NODES close handoff',
      (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final Directory root =
        Directory.systemTemp.createTempSync('r3_struct_audio_handoff_');
    final Directory images = Directory('${root.path}/images')..createSync();
    final Directory sprites = Directory('${root.path}/sprites')..createSync();
    final File template = File('${root.path}/template.txt')
      ..writeAsStringSync('[STRUCT:MOSAIC.wall:AUDIO]\n');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    String? closedText;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditorScreen(
            templatePath: template.path,
            initialText: '[STRUCT:MOSAIC.wall:AUDIO]\n',
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

    final Finder title =
        find.byKey(const ValueKey<String>('struct-window-title'));
    await tester.ensureVisible(title);
    await tester.enterText(title, 'MONITOR [frame]');
    await tester.pump();

    // Exercise the same real view handoff and Escape close path used by the
    // existing structural chrome contract. AUDIO has no checkbox yet in Stage
    // 2, so this proves hidden typed state survives another STRUCT field
    // becoming dirty and serializing the placement.
    await tester.tap(find.text('EDIT').first);
    await tester.pumpAndSettle();
    expect(find.text('SOURCE OUTPUT'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(
      closedText,
      '[STRUCT:MOSAIC.wall:AUDIO:TITLE="MONITOR [frame]"]\n',
    );
  });
}
