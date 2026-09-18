// ./test/card_face_painter_parity_test.dart

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/card_overlay.dart';
import 'package:r3nder/card_overlay_state.dart';
import 'package:r3nder/edit_cue.dart';

Future<Uint8List> _pictureRgba(
  ui.Picture picture,
  int width,
  int height,
) async {
  final ui.Image image = await picture.toImage(width, height);
  try {
    final ByteData? data =
        await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(data, isNotNull);
    return data!.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
  } finally {
    image.dispose();
  }
}

Future<void> _writeHero(File file) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 96, 54),
    Paint()..color = const Color(0xFF294A63),
  );
  canvas.drawCircle(
    const Offset(68, 24),
    15,
    Paint()..color = const Color(0xFFD3A44C),
  );
  final ui.Image image = await recorder.endRecording().toImage(96, 54);
  try {
    final ByteData? png =
        await image.toByteData(format: ui.ImageByteFormat.png);
    expect(png, isNotNull);
    file.writeAsBytesSync(
      png!.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
    );
  } finally {
    image.dispose();
  }
}

void main() {
  test(
    'runtime seated SIDECARD face equals direct face painter pixels',
    () async {
      const Size size = Size(640, 360);
      final Directory root = Directory.systemTemp.createTempSync(
        'r3nder_card_face_parity_',
      );
      final Directory images = Directory('${root.path}/images')
        ..createSync(recursive: true);
      final File hero = File('${images.path}/hero.png');
      await _writeHero(hero);

      final SideCardRequest card = SideCardRequest(
        image: 'hero.png',
        holdFrames: 120,
        panelColor: const Color(0xFF1E1E26),
        heading: 'ELK IN THE HIGH COUNTRY',
        body: '''[PANEL]
PRESET: DOCUMENTARY
KICKER: WILDLIFE
SUBTITLE: Seasonal migration
[/PANEL]
Elk return to higher elevations during late summer.''',
      );
      final StructuralCardOverlayPlacement runtimePlacement =
          StructuralCardOverlayPlacement(
        card: card,
        slide: 1.0,
        normalizedRect: const Rect.fromLTWH(0, 0, 1, 1),
      );
      final CardOverlayImageCache cache = CardOverlayImageCache(
        (String source) => '${root.path}/$source',
      );

      addTearDown(() {
        cache.dispose();
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      expect(await cache.ensure(<StructuralCardOverlayPlacement>[
        runtimePlacement,
      ]), isTrue);
      final ui.Image? decoded = cache.imageFor(card);
      expect(decoded, isNotNull);

      final ui.PictureRecorder runtimeRecorder = ui.PictureRecorder();
      paintStructuralSideCardPanel(
        canvas: Canvas(runtimeRecorder),
        size: size,
        placement: runtimePlacement,
        images: cache,
        fontFamily: 'monospace',
      );
      final Uint8List runtime = await _pictureRgba(
        runtimeRecorder.endRecording(),
        size.width.toInt(),
        size.height.toInt(),
      );

      final ui.PictureRecorder directRecorder = ui.PictureRecorder();
      paintPresentationCardFace(
        canvas: Canvas(directRecorder),
        cardRect: sideCardSeatedPanelRect(size),
        referenceScale: math.min(
          size.width / 1920.0,
          size.height / 1080.0,
        ),
        card: card,
        image: decoded,
        inheritedFontFamily: 'monospace',
      );
      final Uint8List direct = await _pictureRgba(
        directRecorder.endRecording(),
        size.width.toInt(),
        size.height.toInt(),
      );

      expect(
        direct,
        orderedEquals(runtime),
        reason: 'The runtime caller must own placement/motion only. '
            'Any face pixel left behind outside paintPresentationCardFace '
            'breaks this extraction seam.',
      );
    },
  );
}
