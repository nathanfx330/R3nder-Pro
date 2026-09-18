// ./test/presentation_panel_painter_test.dart

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/presentation_panel_content.dart';
import 'package:r3nder/presentation_panel_painter.dart';
import 'package:r3nder/presentation_requests.dart';

Future<ui.Image> _heroImage() async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 16, 9),
    Paint()..color = const Color(0xFF35506A),
  );
  canvas.drawRect(
    const Rect.fromLTWH(0, 5, 16, 4),
    Paint()..color = const Color(0xFFC59657),
  );
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(16, 9);
  picture.dispose();
  return image;
}

Future<Uint8List> _renderFace(CardRequest card, ui.Image hero) async {
  const Size size = Size(640, 360);
  const Rect rect = Rect.fromLTWH(430, 38, 190, 284);
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  paintPresentationCardFace(
    canvas: canvas,
    compositionSize: size,
    cardRect: rect,
    card: card,
    image: hero,
    inheritedFontFamily: 'serif',
  );
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(640, 360);
  picture.dispose();
  try {
    final ByteData? data =
        await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) throw StateError('Unable to read card pixels.');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
  }
}

bool _regionEquals(
  Uint8List a,
  Uint8List b, {
  required int left,
  required int top,
  required int right,
  required int bottom,
}) {
  const int width = 640;
  for (int y = top; y < bottom; y++) {
    for (int x = left; x < right; x++) {
      final int o = (y * width + x) * 4;
      for (int channel = 0; channel < 4; channel++) {
        if (a[o + channel] != b[o + channel]) return false;
      }
    }
  }
  return true;
}

void main() {
  test('authored PANEL font overrides inherited font and blank inherits', () {
    final PresentationPanelContent authored = parsePresentationPanelContent(
      heading: 'ALICE',
      body: '''[PANEL]
PRESET: DOCUMENTARY
FONT: DejaVu Serif
[/PANEL]
Biography.''',
    );
    final PresentationPanelContent inherited = parsePresentationPanelContent(
      heading: 'ALICE',
      body: '''[PANEL]
PRESET: DOCUMENTARY
[/PANEL]
Biography.''',
    );

    expect(presentationPanelFontFamily(authored, 'monospace'), 'DejaVu Serif');
    expect(presentationPanelFontFamily(inherited, 'monospace'), 'monospace');
  });

  test('authored kicker overrides preset label and blank keeps preset default', () {
    final PresentationPanelContent authored = parsePresentationPanelContent(
      heading: 'ALICE',
      body: '''[PANEL]
PRESET: DOCUMENTARY
KICKER: ARCHIVE / INTERVIEW
[/PANEL]''',
    );
    final PresentationPanelContent documentaryDefault =
        parsePresentationPanelContent(
      heading: 'ALICE',
      body: '''[PANEL]
PRESET: DOCUMENTARY
[/PANEL]''',
    );
    final PresentationPanelContent dossierDefault = parsePresentationPanelContent(
      heading: 'ALICE',
      body: '''[PANEL]
PRESET: DOSSIER
[/PANEL]''',
    );

    expect(presentationPanelKickerText(authored), 'ARCHIVE / INTERVIEW');
    expect(
      presentationPanelKickerText(documentaryDefault),
      'PROFILE / DOCUMENTARY',
    );
    expect(
      presentationPanelKickerText(dossierDefault),
      'DOSSIER / SUBJECT FILE',
    );
  });

  test('documentary PANEL semantic painter accepts identity facts and biography', () {
    final PresentationPanelContent content = parsePresentationPanelContent(
      heading: 'JOHN SMITH',
      body: '''[PANEL]
PRESET: DOCUMENTARY
KICKER: ARCHIVE / INTERVIEW
SUBTITLE: Investigative Reporter
META: ORGANIZATION | Example News
META: LOCATION | Washington, DC
META: RANGE | 1990 | 1995
[/PANEL]
Reported on the case for six years.''',
    );
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);

    expect(
      () => paintPresentationPanelContent(
        canvas: canvas,
        cardRect: const Rect.fromLTWH(0, 0, 560, 920),
        contentTop: 310,
        content: content,
        pad: 30,
        scale: 1,
        panelColor: const Color(0xFF1E1E26),
        headColor: const Color(0xFFF2F0EC),
        bodyColor: const Color(0xDDE8E5E0),
        inheritedFontFamily: 'sans-serif',
        showKicker: false,
      ),
      returnsNormally,
    );
    recorder.endRecording().dispose();
  });

  test('photo treatment paints independently of shell choreography', () {
    final PresentationPanelContent content = parsePresentationPanelContent(
      heading: 'SUBJECT',
      body: '''[PANEL]
PRESET: DOSSIER
KICKER: CASE FILE / 17A
SUBTITLE: Case Officer
[/PANEL]''',
    );
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);

    expect(
      () => paintPresentationPanelPhotoTreatment(
        canvas: canvas,
        imageRect: const Rect.fromLTWH(0, 0, 560, 320),
        content: content,
        panelColor: const Color(0xFF1E1E26),
        headColor: const Color(0xFFF2F0EC),
        inheritedFontFamily: 'sans-serif',
        scale: 1,
      ),
      returnsNormally,
    );
    recorder.endRecording().dispose();
  });  test('EDITORIAL keeps all text below the hero image', () async {
    final ui.Image hero = await _heroImage();
    addTearDown(hero.dispose);

    final CardRequest withCopy = CardRequest(
      image: 'hero.png',
      holdFrames: 90,
      panelColor: const Color(0xFF1E1E26),
      heading: 'Elk in the High Country',
      body: '''[PANEL]
PRESET: EDITORIAL
KICKER: WILDLIFE
IMAGE: 38%
[/PANEL]
Elk return to higher elevations during late summer.''',
    );
    final CardRequest withoutCopy = CardRequest(
      image: 'hero.png',
      holdFrames: 90,
      panelColor: const Color(0xFF1E1E26),
      heading: '',
      body: '''[PANEL]
PRESET: EDITORIAL
IMAGE: 38%
[/PANEL]''',
    );

    final Uint8List painted = await _renderFace(withCopy, hero);
    final Uint8List blank = await _renderFace(withoutCopy, hero);

    // card top 38 + 284 * .38 = 145.92. Compare a conservative interior of
    // the hero so shadow/rounded-edge pixels cannot influence the assertion.
    expect(
      _regionEquals(
        painted,
        blank,
        left: 440,
        top: 48,
        right: 610,
        bottom: 140,
      ),
      isTrue,
      reason:
          'EDITORIAL must not paint a kicker, rule, scrim, or any other text '
          'treatment inside the hero image.',
    );
    expect(
      _regionEquals(
        painted,
        blank,
        left: 440,
        top: 165,
        right: 610,
        bottom: 300,
      ),
      isFalse,
      reason: 'EDITORIAL kicker, heading, and body belong in the content block.',
    );
  });


}
