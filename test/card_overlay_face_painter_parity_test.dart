// ./test/card_overlay_face_painter_parity_test.dart

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/card_overlay.dart';
import 'package:r3nder/edit_cue.dart';

Future<ui.Image> _makeSourceImage() async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 96, 72),
    Paint()..color = const Color(0xFF203040),
  );
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 48, 36),
    Paint()..color = const Color(0xFFD49B52),
  );
  canvas.drawRect(
    const Rect.fromLTWH(48, 36, 48, 36),
    Paint()..color = const Color(0xFF6D8CA8),
  );
  final ui.Picture picture = recorder.endRecording();
  try {
    return await picture.toImage(96, 72);
  } finally {
    picture.dispose();
  }
}

Future<Uint8List> _rgba(ui.Image image) async {
  final ByteData? bytes =
      await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  expect(bytes, isNotNull);
  return bytes!.buffer.asUint8List(
    bytes.offsetInBytes,
    bytes.lengthInBytes,
  );
}

Future<ui.Image> _renderRuntime({
  required Size size,
  required StructuralCardOverlayPlacement placement,
  required CardOverlayImageCache images,
  required void Function(Rect rect) onRect,
}) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  final Rect? rect = paintStructuralSideCardPanel(
    canvas: canvas,
    size: size,
    placement: placement,
    images: images,
    fontFamily: 'monospace',
  );
  expect(rect, isNotNull);
  onRect(rect!);

  final ui.Picture picture = recorder.endRecording();
  try {
    return await picture.toImage(
      size.width.round(),
      size.height.round(),
    );
  } finally {
    picture.dispose();
  }
}

Future<ui.Image> _renderDirectFace({
  required Size size,
  required Rect rect,
  required double scale,
  required SideCardRequest card,
  required ui.Image? image,
}) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
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
      size.width.round(),
      size.height.round(),
    );
  } finally {
    picture.dispose();
  }
}

void main() {
  testWidgets(
    'seated runtime SIDECARD face matches direct face painter exactly',
    (WidgetTester tester) async {
      const Size size = Size(960, 540);
      const double scale = 0.5;

      final Directory root = Directory.systemTemp.createTempSync(
        'r3nder_card_face_parity_',
      );
      final Directory imagesDir = Directory('${root.path}/images')
        ..createSync(recursive: true);

      final ui.Image source = await _makeSourceImage();
      final ByteData? png =
          await source.toByteData(format: ui.ImageByteFormat.png);
      expect(png, isNotNull);
      File('${imagesDir.path}/subject.png').writeAsBytesSync(
        png!.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      );
      source.dispose();

      final SideCardRequest card = SideCardRequest(
        image: 'subject.png',
        holdFrames: 45,
        panelColor: const Color(0xFF171B20),
        heading: 'GUARDIANS OF THE WILD',
        body: '''[PANEL]
PRESET: DOCUMENTARY
KICKER: WILDLIFE
SUBTITLE: Protected lands and species
META: REGION | NORTH AMERICA
[/PANEL]
From towering mountains to remote coastlines, wild places sustain extraordinary life.''',
      );
      final StructuralCardOverlayPlacement placement =
          StructuralCardOverlayPlacement(
        card: card,
        slide: 1.0,
        normalizedRect: const Rect.fromLTWH(0, 0, 1, 1),
      );

      final CardOverlayImageCache images = CardOverlayImageCache(
        (String source) => '${root.path}/$source',
      );
      addTearDown(() {
        images.dispose();
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      final bool changed = await images.ensure(
        <StructuralCardOverlayPlacement>[placement],
      );
      expect(changed, isTrue);
      expect(images.imageFor(card), isNotNull);

      Rect? runtimeRect;
      final ui.Image runtime = await _renderRuntime(
        size: size,
        placement: placement,
        images: images,
        onRect: (Rect rect) => runtimeRect = rect,
      );
      expect(runtimeRect, isNotNull);

      final ui.Image direct = await _renderDirectFace(
        size: size,
        rect: runtimeRect!,
        scale: scale,
        card: card,
        image: images.imageFor(card),
      );

      final Uint8List runtimeRgba = await _rgba(runtime);
      final Uint8List directRgba = await _rgba(direct);
      runtime.dispose();
      direct.dispose();

      expect(runtimeRgba.length, directRgba.length);

      // The runtime path deliberately owns the drop shadow while the direct
      // face painter deliberately does not. The blur can bleed into the four
      // transparent rounded-corner cutouts even though both captures are
      // restricted to the returned card rect. Compare every fully owned face
      // pixel byte-for-byte: no tolerance, no color-distance threshold.
      //
      // This still covers the image, photo treatment, panel fill/gradient,
      // border, typography, and content placement. The only excluded pixels
      // are the antialiased/transparent edge where environmental shadow and
      // intrinsic face are intentionally different layers.
      final Rect faceRect = runtimeRect!;
      final int width = size.width.round();
      final int height = size.height.round();
      int comparedPixels = 0;
      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          if (!faceRect.contains(Offset(x + 0.5, y + 0.5))) continue;
          final int offset = (y * width + x) * 4;
          if (directRgba[offset + 3] != 0xFF) continue;

          comparedPixels++;
          expect(
            runtimeRgba.sublist(offset, offset + 4),
            directRgba.sublist(offset, offset + 4),
            reason: 'Face pixel differs at ($x, $y).',
          );
        }
      }

      expect(
        comparedPixels,
        greaterThan((faceRect.width * faceRect.height * 0.95).floor()),
        reason: 'The exact comparison must cover essentially the whole face.',
      );

      // Rounded corners are intrinsic to the face. A corner remains outside
      // the direct face while the center is fully opaque.
      final int cornerX = faceRect.left.floor();
      final int cornerY = faceRect.top.floor();
      final int cornerOffset = (cornerY * width + cornerX) * 4;
      expect(directRgba[cornerOffset + 3], lessThan(0xFF));

      final int centerX = faceRect.center.dx.floor();
      final int centerY = faceRect.center.dy.floor();
      final int centerOffset = (centerY * width + centerX) * 4;
      expect(directRgba[centerOffset + 3], 0xFF);
    },
  );
}
