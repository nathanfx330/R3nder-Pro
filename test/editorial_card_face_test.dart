// ./test/editorial_card_face_test.dart

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/card_overlay.dart';
import 'package:r3nder/presentation_panel_content.dart';
import 'package:r3nder/presentation_requests.dart';

const Size _size = Size(640, 360);
const Color _heroColor = Color(0xFF315D7A);
const Color _panelColor = Color(0xFF1E1E26);

Future<ui.Image> _solidHero() async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 160, 90),
    Paint()..color = _heroColor,
  );
  final ui.Picture picture = recorder.endRecording();
  try {
    return await picture.toImage(160, 90);
  } finally {
    picture.dispose();
  }
}

Future<Uint8List> _render(CardRequest card, ui.Image hero) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  paintPresentationCardFace(
    canvas,
    sideCardSeatedPanelRect(_size),
    math.min(_size.width / 1920.0, _size.height / 1080.0),
    card,
    hero,
    'monospace',
  );

  final ui.Picture picture = recorder.endRecording();
  final ui.Image rendered = await picture.toImage(
    _size.width.toInt(),
    _size.height.toInt(),
  );
  picture.dispose();
  try {
    final ByteData? data =
        await rendered.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(data, isNotNull);
    return Uint8List.fromList(
      data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  } finally {
    rendered.dispose();
  }
}

CardRequest _card({
  required String heading,
  required String panelBody,
}) {
  return CardRequest(
    image: 'hero.png',
    holdFrames: 120,
    panelColor: _panelColor,
    heading: heading,
    body: panelBody,
  );
}

int _differentPixels(
  Uint8List a,
  Uint8List b, {
  required Rect rect,
}) {
  final int width = _size.width.toInt();
  final int height = _size.height.toInt();
  final int left = rect.left.ceil().clamp(0, width).toInt();
  final int right = rect.right.floor().clamp(0, width).toInt();
  final int top = rect.top.ceil().clamp(0, height).toInt();
  final int bottom = rect.bottom.floor().clamp(0, height).toInt();

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
  test('EDITORIAL parses and round-trips as an explicit opt-in preset', () {
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
    expect(
      presentationPanelDefaultKicker(PresentationPanelPreset.editorial),
      isEmpty,
    );

    final String rewritten = formatPresentationPanelBody(
      preset: content.preset,
      kicker: content.kicker,
      fontFamily: content.fontFamily,
      subtitle: content.subtitle,
      metadata: content.metadata,
      preservedDirectives: content.preservedDirectives,
      body: content.body,
    );
    expect(rewritten, contains('PRESET: EDITORIAL'));
    expect(rewritten, contains('KICKER: WILDLIFE'));
  });

  test('EDITORIAL uses a clean 38 percent hero and flat panel', () async {
    final ui.Image hero = await _solidHero();
    addTearDown(hero.dispose);

    final Uint8List raster = await _render(
      _card(
        heading: '',
        panelBody: '''[PANEL]
PRESET: EDITORIAL
[/PANEL]''',
      ),
      hero,
    );

    final Rect card = sideCardSeatedPanelRect(_size);
    final double imageBottom = card.top + card.height * 0.38;
    final int width = _size.width.toInt();

    final int heroX = card.center.dx.floor();
    final int heroY = (imageBottom - 6).floor();
    final int heroOffset = (heroY * width + heroX) * 4;
    expect(raster[heroOffset], _heroColor.red);
    expect(raster[heroOffset + 1], _heroColor.green);
    expect(raster[heroOffset + 2], _heroColor.blue);
    expect(raster[heroOffset + 3], 0xFF);

    final int panelY = (imageBottom + 18).floor();
    final int panelOffset = (panelY * width + heroX) * 4;
    expect(raster[panelOffset], _panelColor.red);
    expect(raster[panelOffset + 1], _panelColor.green);
    expect(raster[panelOffset + 2], _panelColor.blue);
    expect(raster[panelOffset + 3], 0xFF);
  });

  test('EDITORIAL paints authored kicker only in the content block', () async {
    final ui.Image hero = await _solidHero();
    addTearDown(hero.dispose);

    final Uint8List withKicker = await _render(
      _card(
        heading: '',
        panelBody: '''[PANEL]
PRESET: EDITORIAL
KICKER: WILDLIFE
[/PANEL]''',
      ),
      hero,
    );
    final Uint8List withoutKicker = await _render(
      _card(
        heading: '',
        panelBody: '''[PANEL]
PRESET: EDITORIAL
[/PANEL]''',
      ),
      hero,
    );

    final Rect card = sideCardSeatedPanelRect(_size);
    final double imageBottom = card.top + card.height * 0.38;
    final Rect heroInterior = Rect.fromLTRB(
      card.left + 4,
      card.top + 4,
      card.right - 4,
      imageBottom - 4,
    );
    final Rect contentInterior = Rect.fromLTRB(
      card.left + 4,
      imageBottom + 2,
      card.right - 4,
      card.bottom - 4,
    );

    expect(
      _differentPixels(withKicker, withoutKicker, rect: heroInterior),
      0,
      reason: 'EDITORIAL must not paint kicker, scrim, rule, or other text '
          'treatment inside the full-bleed hero.',
    );
    expect(
      _differentPixels(withKicker, withoutKicker, rect: contentInterior),
      greaterThan(0),
      reason: 'The authored kicker must be painted once in the content block.',
    );
  });

  test('EDITORIAL heading and body use the new restrained hierarchy', () async {
    final ui.Image hero = await _solidHero();
    addTearDown(hero.dispose);

    final Uint8List withCopy = await _render(
      _card(
        heading: 'Elk in the High Country',
        panelBody: '''[PANEL]
PRESET: EDITORIAL
KICKER: WILDLIFE
[/PANEL]
Elk return to higher elevations during late summer.''',
      ),
      hero,
    );
    final Uint8List withoutCopy = await _render(
      _card(
        heading: '',
        panelBody: '''[PANEL]
PRESET: EDITORIAL
[/PANEL]''',
      ),
      hero,
    );

    final Rect card = sideCardSeatedPanelRect(_size);
    final double imageBottom = card.top + card.height * 0.38;
    expect(
      _differentPixels(
        withCopy,
        withoutCopy,
        rect: Rect.fromLTRB(
          card.left + 4,
          imageBottom + 2,
          card.right - 4,
          card.bottom - 4,
        ),
      ),
      greaterThan(0),
    );
  });
  test('authored IMAGE percentage changes only hero allocation', () async {
    final ui.Image hero = await _solidHero();
    addTearDown(hero.dispose);

    final Uint8List shallow = await _render(
      _card(
        heading: '',
        panelBody: '''[PANEL]
PRESET: EDITORIAL
IMAGE: 25%
[/PANEL]''',
      ),
      hero,
    );
    final Uint8List deep = await _render(
      _card(
        heading: '',
        panelBody: '''[PANEL]
PRESET: EDITORIAL
IMAGE: 55%
[/PANEL]''',
      ),
      hero,
    );

    final Rect card = sideCardSeatedPanelRect(_size);
    final int width = _size.width.toInt();
    final int x = card.center.dx.floor();
    final int y = (card.top + card.height * 0.40).floor();
    final int offset = (y * width + x) * 4;

    expect(deep[offset], _heroColor.red);
    expect(deep[offset + 1], _heroColor.green);
    expect(deep[offset + 2], _heroColor.blue);
    expect(
      <int>[shallow[offset], shallow[offset + 1], shallow[offset + 2]],
      isNot(<int>[_heroColor.red, _heroColor.green, _heroColor.blue]),
    );
  });

  test('authored type sizes change content without touching hero', () async {
    final ui.Image hero = await _solidHero();
    addTearDown(hero.dispose);

    final Uint8List defaults = await _render(
      _card(
        heading: 'Elk in the High Country',
        panelBody: '''[PANEL]
PRESET: EDITORIAL
KICKER: WILDLIFE
[/PANEL]
Elk return to higher elevations during late summer.''',
      ),
      hero,
    );
    final Uint8List authored = await _render(
      _card(
        heading: 'Elk in the High Country',
        panelBody: '''[PANEL]
PRESET: EDITORIAL
KICKER: WILDLIFE
HEADING_SIZE: 46
BODY_SIZE: 24
[/PANEL]
Elk return to higher elevations during late summer.''',
      ),
      hero,
    );

    final Rect card = sideCardSeatedPanelRect(_size);
    final double imageBottom = card.top + card.height * 0.38;
    expect(
      _differentPixels(
        defaults,
        authored,
        rect: Rect.fromLTRB(
          card.left + 4,
          card.top + 4,
          card.right - 4,
          imageBottom - 4,
        ),
      ),
      0,
      reason: 'Type directives must not alter the hero raster.',
    );
    expect(
      _differentPixels(
        defaults,
        authored,
        rect: Rect.fromLTRB(
          card.left + 4,
          imageBottom + 2,
          card.right - 4,
          card.bottom - 4,
        ),
      ),
      greaterThan(0),
      reason: 'Authored reference sizes must affect content typography.',
    );
  });

}
