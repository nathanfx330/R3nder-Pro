// ./test/presentation_card_face_preview_test.dart

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/presentation_card_face_preview.dart';
import 'package:r3nder/presentation_requests.dart';

Future<File> _writeHero(Directory root) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 48, 32),
    ui.Paint()..color = const ui.Color(0xFF507050),
  );
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(48, 32);
  picture.dispose();
  try {
    final ByteData? png =
        await image.toByteData(format: ui.ImageByteFormat.png);
    final File file = File('${root.path}/hero.png');
    file.writeAsBytesSync(
      png!.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      flush: true,
    );
    return file;
  } finally {
    image.dispose();
  }
}

void main() {
  testWidgets('face preview resolves image through shared card cache',
      (WidgetTester tester) async {
    final Directory root =
        Directory.systemTemp.createTempSync('r3nder_card_preview_');
    final File hero = await _writeHero(root);
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    int resolutions = 0;
    final CardRequest card = CardRequest(
      image: 'hero.png',
      holdFrames: 90,
      panelColor: const Color(0xFF1E1E26),
      heading: 'Elk in the High Country',
      body: '''[PANEL]
PRESET: EDITORIAL
KICKER: WILDLIFE
[/PANEL]
Editorial body copy.''',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 420,
          child: PresentationCardFacePreview(
            card: card,
            resolveSource: (String source) {
              resolutions++;
              expect(source, 'images/hero.png');
              return hero.path;
            },
          ),
        ),
      ),
    );

    for (int i = 0; i < 8; i++) {
      await tester.pump();
    }

    expect(
      find.byKey(
        const ValueKey<String>('presentation-card-face-preview'),
      ),
      findsOneWidget,
    );
    expect(resolutions, 1);
    expect(tester.takeException(), isNull);
  });
}
