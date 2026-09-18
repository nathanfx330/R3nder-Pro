// ./test/editorial_card_face_test.dart

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/card_overlay.dart';
import 'package:r3nder/edit_cue.dart';
import 'package:r3nder/presentation_panel_content.dart';

Future<ui.Image> _solidHero(Color color) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 160, 90),
    Paint()..color = color,
  );
  return recorder.endRecording().toImage(160, 90);
}

Future<Uint8List> _renderEditorial(ui.Image hero) async {
  const Size size = Size(640, 360);
  final SideCardRequest card = SideCardRequest(
    image: 'hero.png',
    holdFrames: 120,
    panelColor: const Color(0xFF1E1E26),
    heading: 'Elk in the High Country',
    body: '''[PANEL]
PRESET: EDITORIAL
KICKER: WILDLIFE
[/PANEL]
Elk return to higher elevations during late summer.''',
  );

  final ui.PictureRecorder recorder = ui.PictureRecorder();
  paintPresentationCardFace(
    canvas: Canvas(recorder),
    cardRect: sideCardSeatedPanelRect(size),
    referenceScale: math.min(
      size.width / 1920.0,
      size.height / 1080.0,
    ),
    card: card,
    image: hero,
    inheritedFontFamily: 'monospace',
  );
  final ui.Image rendered =
      await recorder.endRecording().toImage(size.width.toInt(), size.height.toInt());
  try {
    final ByteData? data =
        await rendered.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(data, isNotNull);
    return data!.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
  } finally {
    rendered.dispose();
  }
}

void main() {
  test('EDITORIAL parses as an explicit PANEL preset', () {
    final PresentationPanelContent content = parsePresentationPanelContent(
      heading: 'SUBJECT',
      body: '''[PANEL]
PRESET: EDITORIAL
KICKER: WILDLIFE
[/PANEL]
Body.''',
    );

    expect(content.preset, PresentationPanelPreset.editorial);
    expect(presentationPanelPresetName(content.preset), 'EDITORIAL');
    expect(content.kicker, 'WILDLIFE');
    expect(content.body, 'Body.');
  });

  test('EDITORIAL paints no kicker or treatment inside the hero image', () async {
    const Color heroColor = Color(0xFF315D7A);
    final ui.Image hero = await _solidHero(heroColor);
    addTearDown(hero.dispose);

    final Uint8List rgba = await _renderEditorial(hero);
    const int width = 640;
    const Size size = Size(640, 360);
    final Rect card = sideCardSeatedPanelRect(size);
    final Rect imageRect = Rect.fromLTWH(
      card.left,
      card.top,
      card.width,
      card.height * 0.38,
    );

    int changed = 0;
    final int left = (imageRect.left + 18).ceil();
    final int right = (imageRect.right - 18).floor();
    final int top = (imageRect.top + 18).ceil();
    final int bottom = (imageRect.bottom - 3).floor();

    for (int y = top; y < bottom; y++) {
      for (int x = left; x < right; x++) {
        final int offset = (y * width + x) * 4;
        if (rgba[offset] != heroColor.red ||
            rgba[offset + 1] != heroColor.green ||
            rgba[offset + 2] != heroColor.blue ||
            rgba[offset + 3] != 0xFF) {
          changed++;
        }
      }
    }

    expect(
      changed,
      0,
      reason: 'EDITORIAL moves its kicker into the content block. The hero '
          'must remain an unadorned full-bleed image with no duplicate kicker, '
          'scrim, or accent rule painted over it.',
    );
  });
}
