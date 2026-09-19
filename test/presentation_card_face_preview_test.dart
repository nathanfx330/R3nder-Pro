// ./test/presentation_card_face_preview_test.dart

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/card_overlay.dart';
import 'package:r3nder/presentation_card_face_preview.dart';
import 'package:r3nder/presentation_panel_painter.dart';
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

Future<ui.Image> _renderPreviewHelper(CardRequest card) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  paintPresentationCardFacePreview(
    canvas: canvas,
    slotSize: _slot,
    card: card,
    image: null,
    inheritedFontFamily: 'monospace',
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

Future<ui.Image> _renderDirectFace(
  CardRequest card, {
  ui.Image? image,
}) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  final Rect rect = presentationCardFacePreviewRect(_slot);
  final double scale = presentationCardFacePreviewScale(_slot);
  paintPresentationCardFace(
    canvas,
    rect,
    scale,
    card,
    image,
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

Future<ui.Image> _solidImage(Color color) async {
  const int size = 16;
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    Paint()..color = color,
  );
  final ui.Picture picture = recorder.endRecording();
  try {
    return await picture.toImage(size, size);
  } finally {
    picture.dispose();
  }
}

Color _pixel(Uint8List rgba, int width, int x, int y) {
  final int offset = (y * width + x) * 4;
  return Color.fromARGB(
    rgba[offset + 3],
    rgba[offset],
    rgba[offset + 1],
    rgba[offset + 2],
  );
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

  testWidgets('preview widget mounts the read-only shared painter surface',
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

    expect(
      find.byKey(
        const ValueKey<String>('presentation-card-face-preview'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey<String>('presentation-card-face-preview-paint'),
      ),
      findsOneWidget,
    );

    final Size paintedSize = tester.getSize(
      find.byKey(
        const ValueKey<String>('presentation-card-face-preview-paint'),
      ),
    );
    expect(paintedSize, _slot);
    expect(tester.takeException(), isNull);
  });

  test('preview paint helper exactly matches direct shared face painter',
      () async {
    final CardRequest card = _card();
    final ui.Image preview = await _renderPreviewHelper(card);
    final ui.Image direct = await _renderDirectFace(card);
    try {
      final Uint8List previewBytes = await _rgba(preview);
      final Uint8List directBytes = await _rgba(direct);
      expect(previewBytes, orderedEquals(directBytes));
    } finally {
      preview.dispose();
      direct.dispose();
    }
  });
  test('shared face layout owns painter image boundary and focus origin',
      () async {
    final CardRequest card = _card();
    const Color heroColor = Color(0xFFEC407A);
    final ui.Image hero = await _solidImage(heroColor);
    final Rect cardRect = presentationCardFacePreviewRect(_slot);
    final double scale = presentationCardFacePreviewScale(_slot);
    final PresentationCardFaceLayout layout =
        presentationCardFaceLayout(cardRect, card, hero);
    final ui.Image rendered = await _renderDirectFace(card, image: hero);

    try {
      expect(layout.imageFraction, closeTo(0.44, 0.0001));
      expect(
        layout.imageBottom,
        closeTo(cardRect.top + cardRect.height * 0.44, 0.0001),
      );
      expect(
        layout.pad,
        closeTo(
          cardRect.width * kPresentationCardFacePadFraction,
          0.0001,
        ),
      );

      final PresentationPanelFocusRegions regions =
          presentationCardFaceFocusRegions(
        rect: cardRect,
        scale: scale,
        card: card,
        image: hero,
        inheritedFontFamily: 'monospace',
      )!;
      expect(
        regions.kicker!.top,
        closeTo(layout.imageBottom + layout.pad * 0.78, 0.0001),
      );

      final Uint8List rgba = await _rgba(rendered);
      final int x = cardRect.center.dx.round();
      final int imageY = (layout.imageBottom - 3.0).floor();
      final int panelY = (layout.imageBottom + 3.0).ceil();

      expect(_pixel(rgba, _slot.width.toInt(), x, imageY), heroColor);
      expect(
        _pixel(rgba, _slot.width.toInt(), x, panelY),
        card.panelColor,
      );
    } finally {
      rendered.dispose();
      hero.dispose();
    }
  });

  testWidgets('interactive preview routes editorial regions to callbacks',
      (WidgetTester tester) async {
    final CardRequest card = _card();
    int kickerTaps = 0;
    int headingTaps = 0;
    int bodyTaps = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: _slot.width,
            child: PresentationCardFacePreview(
              card: card,
              height: _slot.height,
              onKickerTap: () => kickerTaps++,
              onHeadingTap: () => headingTaps++,
              onBodyTap: () => bodyTaps++,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final Finder hitSurface = find.byKey(
      const ValueKey<String>('presentation-card-face-preview-hit-surface'),
    );
    expect(hitSurface, findsOneWidget);

    final Rect cardRect = presentationCardFacePreviewRect(_slot);
    final double scale = presentationCardFacePreviewScale(_slot);
    final PresentationPanelFocusRegions regions =
        presentationCardFaceFocusRegions(
      rect: cardRect,
      scale: scale,
      card: card,
      image: null,
      inheritedFontFamily: 'monospace',
    )!;
    final Offset origin = tester.getTopLeft(hitSurface);

    await tester.tapAt(origin + regions.kicker!.center);
    await tester.pump();
    expect(kickerTaps, 1);
    expect(headingTaps, 0);
    expect(bodyTaps, 0);

    await tester.tapAt(origin + regions.heading!.center);
    await tester.pump();
    expect(headingTaps, 1);

    await tester.tapAt(origin + regions.body!.center);
    await tester.pump();
    expect(bodyTaps, 1);

    await tester.tapAt(origin + Offset(cardRect.center.dx, cardRect.bottom - 2));
    await tester.pump();
    expect(kickerTaps, 1);
    expect(headingTaps, 1);
    expect(bodyTaps, 1);
  });

  test('editorial focus regions follow authored heading size', () {
    CardRequest cardWithHeadingSize(double size) => CardRequest(
          image: '',
          holdFrames: 90,
          panelColor: const Color(0xFF1E1E26),
          heading: 'A heading that wraps across multiple lines in the card',
          body: '''[PANEL]
PRESET: EDITORIAL
KICKER: WILDLIFE
HEADING_SIZE: $size
BODY_SIZE: 18
[/PANEL]
Body copy.''',
        );

    PresentationPanelFocusRegions regionsFor(CardRequest card) {
      final Rect cardRect = presentationCardFacePreviewRect(_slot);
      final double scale = presentationCardFacePreviewScale(_slot);
      return presentationCardFaceFocusRegions(
        rect: cardRect,
        scale: scale,
        card: card,
        image: null,
        inheritedFontFamily: 'monospace',
      )!;
    }

    final PresentationPanelFocusRegions small =
        regionsFor(cardWithHeadingSize(28));
    final PresentationPanelFocusRegions large =
        regionsFor(cardWithHeadingSize(56));

    expect(large.heading!.height, greaterThan(small.heading!.height));
    expect(large.body!.top, greaterThan(small.body!.top));
  });


}
