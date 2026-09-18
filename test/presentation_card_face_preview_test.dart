// ./test/presentation_card_face_preview_test.dart

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/card_overlay.dart';
import 'package:r3nder/presentation_card_face_preview.dart';
import 'package:r3nder/presentation_requests.dart';

const Size _slot = Size(500, 230);

CardRequest _card() => CardRequest(
      image: 'hero.png',
      holdFrames: 90,
      panelColor: const Color(0xFF1E1E26),
      heading: 'Elk in the High Country',
      body: '''[PANEL]
PRESET: EDITORIAL
KICKER: WILDLIFE
HEADING_SIZE: 36
BODY_SIZE: 18
IMAGE: 44%
[/PANEL]
Editorial body copy.''',
    );

Future<Uint8List> _rgba(ui.Image image) async {
  final ByteData? data =
      await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  expect(data, isNotNull);
  return Uint8List.fromList(
    data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
  );
}

Future<ui.Image> _direct(CardRequest card) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  final Rect rect = presentationCardFacePreviewRect(_slot);
  final double scale = presentationCardFacePreviewScale(_slot);
  paintPresentationCardFace(
    canvas,
    rect,
    scale,
    card,
    null,
    'monospace',
  );
  final ui.Picture picture = recorder.endRecording();
  try {
    return await picture.toImage(
      _slot.width.toInt(),
      _slot.height.toInt(),
    );
  } finally {
    picture.dispose();
  }
}

void main() {
  test('preview fit is height-bound, centered, and letterboxed', () {
    final Rect rect = presentationCardFacePreviewRect(_slot);
    final Rect reference = sideCardSeatedPanelRect(
      kPresentationCardReferenceComposition,
    );

    expect(rect.height, closeTo(_slot.height - 16.0, 0.0001));
    expect(rect.width, lessThan(_slot.width - 16.0));
    expect(rect.center.dx, closeTo(_slot.width / 2.0, 0.0001));
    expect(rect.center.dy, closeTo(_slot.height / 2.0, 0.0001));
    expect(rect.left, greaterThan(8.0));
    expect(rect.right, lessThan(_slot.width - 8.0));

    final double scale = presentationCardFacePreviewScale(_slot);
    expect(rect.width, closeTo(reference.width * scale, 0.0001));
    expect(rect.height, closeTo(reference.height * scale, 0.0001));
  });

  testWidgets('preview raster exactly matches direct shared face painter',
      (WidgetTester tester) async {
    final CardRequest card = _card();

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: _slot.width,
            child: PresentationCardFacePreview(
              card: card,
              height: _slot.height,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final RenderRepaintBoundary boundary =
        tester.renderObject<RenderRepaintBoundary>(
      find.byKey(
        const ValueKey<String>('presentation-card-face-preview'),
      ),
    );
    final ui.Image preview = await boundary.toImage(pixelRatio: 1.0);
    final ui.Image direct = await _direct(card);
    try {
      final Uint8List previewBytes = await _rgba(preview);
      final Uint8List directBytes = await _rgba(direct);
      expect(previewBytes, orderedEquals(directBytes));
    } finally {
      preview.dispose();
      direct.dispose();
    }
  });
}
