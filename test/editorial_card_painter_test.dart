// ./test/editorial_card_painter_test.dart

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/card_overlay.dart';
import 'package:r3nder/presentation_requests.dart';

const ui.Size _size = ui.Size(640, 360);
const ui.Color _heroColor = ui.Color(0xFF6B7F51);

Future<ui.Image> _solidHero() async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 64, 40),
    ui.Paint()..color = _heroColor,
  );
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(64, 40);
  picture.dispose();
  return image;
}

Future<Uint8List> _render({
  required CardRequest card,
  required ui.Image hero,
}) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  paintPresentationCardFace(
    canvas: canvas,
    compositionSize: _size,
    cardRect: sideCardSeatedPanelRect(_size),
    card: card,
    image: hero,
    inheritedFontFamily: 'monospace',
  );
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(
    _size.width.toInt(),
    _size.height.toInt(),
  );
  picture.dispose();
  try {
    final ByteData? data =
        await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(data, isNotNull);
    return Uint8List.fromList(
      data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  } finally {
    image.dispose();
  }
}

CardRequest _editorialCard({
  required bool withKicker,
  String styleDirectives = '',
}) {
  final String kicker = withKicker ? 'KICKER: WILDLIFE\n' : '';
  final String style =
      styleDirectives.isEmpty ? '' : '$styleDirectives\n';
  return CardRequest(
    image: 'hero.png',
    holdFrames: 120,
    panelColor: const Color(0xFF1E1E26),
    heading: 'Elk in the High Country',
    body: '''[PANEL]
PRESET: EDITORIAL
${kicker}${style}[/PANEL]
Elk return to higher elevations during late summer.''',
  );
}

int _differentPixels(
  Uint8List a,
  Uint8List b, {
  required ui.Rect rect,
}) {
  final int width = _size.width.toInt();
  final int height = _size.height.toInt();
  final int left = rect.left.ceil().clamp(0, width);
  final int right = rect.right.floor().clamp(0, width);
  final int top = rect.top.ceil().clamp(0, height);
  final int bottom = rect.bottom.floor().clamp(0, height);

  int count = 0;
  for (int y = top; y < bottom; y++) {
    for (int x = left; x < right; x++) {
      final int offset = (y * width + x) * 4;
      if (a[offset] != b[offset] ||
          a[offset + 1] != b[offset + 1] ||
          a[offset + 2] != b[offset + 2] ||
          a[offset + 3] != b[offset + 3]) {
        count++;
      }
    }
  }
  return count;
}

void main() {
  test('EDITORIAL leaves hero untouched and paints kicker only below it',
      () async {
    final ui.Image hero = await _solidHero();
    addTearDown(hero.dispose);

    final Uint8List withKicker = await _render(
      card: _editorialCard(withKicker: true),
      hero: hero,
    );
    final Uint8List withoutKicker = await _render(
      card: _editorialCard(withKicker: false),
      hero: hero,
    );

    final ui.Rect cardRect = sideCardSeatedPanelRect(_size);
    final double imageBottom = cardRect.top + cardRect.height * 0.38;
    final ui.Rect imageInterior = ui.Rect.fromLTRB(
      cardRect.left + 4,
      cardRect.top + 4,
      cardRect.right - 4,
      imageBottom - 4,
    );
    final ui.Rect contentInterior = ui.Rect.fromLTRB(
      cardRect.left + 4,
      imageBottom + 2,
      cardRect.right - 4,
      cardRect.bottom - 4,
    );

    expect(
      _differentPixels(withKicker, withoutKicker, rect: imageInterior),
      0,
      reason: 'EDITORIAL must not paint kicker/scrim/rule treatment over hero.',
    );
    expect(
      _differentPixels(withKicker, withoutKicker, rect: contentInterior),
      greaterThan(0),
      reason: 'The authored kicker must affect the content block below hero.',
    );

    final int sampleX = cardRect.center.dx.floor();
    final int sampleY = (imageBottom - 6).floor();
    final int offset = (sampleY * _size.width.toInt() + sampleX) * 4;
    expect(withKicker[offset], _heroColor.red);
    expect(withKicker[offset + 1], _heroColor.green);
    expect(withKicker[offset + 2], _heroColor.blue);
    expect(withKicker[offset + 3], _heroColor.alpha);
  });

  test('authored IMAGE percentage changes the hero allocation', () async {
    final ui.Image hero = await _solidHero();
    addTearDown(hero.dispose);

    final Uint8List shallow = await _render(
      card: _editorialCard(
        withKicker: false,
        styleDirectives: 'IMAGE: 25%',
      ),
      hero: hero,
    );
    final Uint8List deep = await _render(
      card: _editorialCard(
        withKicker: false,
        styleDirectives: 'IMAGE: 55%',
      ),
      hero: hero,
    );

    final ui.Rect cardRect = sideCardSeatedPanelRect(_size);
    final int x = cardRect.center.dx.floor();
    final int y = (cardRect.top + cardRect.height * 0.40).floor();
    final int offset = (y * _size.width.toInt() + x) * 4;

    expect(deep[offset], _heroColor.red);
    expect(deep[offset + 1], _heroColor.green);
    expect(deep[offset + 2], _heroColor.blue);
    expect(
      <int>[
        shallow[offset],
        shallow[offset + 1],
        shallow[offset + 2],
      ],
      isNot(<int>[_heroColor.red, _heroColor.green, _heroColor.blue]),
    );
  });

  test('authored heading/body reference sizes affect only content raster',
      () async {
    final ui.Image hero = await _solidHero();
    addTearDown(hero.dispose);

    final Uint8List defaults = await _render(
      card: _editorialCard(withKicker: true),
      hero: hero,
    );
    final Uint8List authored = await _render(
      card: _editorialCard(
        withKicker: true,
        styleDirectives: 'HEADING_SIZE: 46\nBODY_SIZE: 24',
      ),
      hero: hero,
    );

    final ui.Rect cardRect = sideCardSeatedPanelRect(_size);
    final double imageBottom = cardRect.top + cardRect.height * 0.38;
    expect(
      _differentPixels(
        defaults,
        authored,
        rect: ui.Rect.fromLTRB(
          cardRect.left + 4,
          cardRect.top + 4,
          cardRect.right - 4,
          imageBottom - 4,
        ),
      ),
      0,
    );
    expect(
      _differentPixels(
        defaults,
        authored,
        rect: ui.Rect.fromLTRB(
          cardRect.left + 4,
          imageBottom + 2,
          cardRect.right - 4,
          cardRect.bottom - 4,
        ),
      ),
      greaterThan(0),
    );
  });

}
