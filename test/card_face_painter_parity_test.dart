// ./test/card_face_painter_parity_test.dart

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/card_overlay.dart';
import 'package:r3nder/edit_model.dart';

const ui.Size _compositionSize = ui.Size(640, 360);

String _sideCardSource({required bool rich}) {
  final String body = rich
      ? '''[PANEL]
PRESET: DOCUMENTARY
KICKER: PROFILE / DOCUMENTARY
SUBTITLE: Investigative Reporter
META: LOCATION | Washington, DC
[/PANEL]
Biography copy for the parity seam.'''
      : 'Biography copy for the parity seam.';

  return '''[EDIT:main]
[TRACK:V1]
[CLIP:shot:video/a.mp4:0:0:100:1]
[CUE:0][SIDECARD:hero.png:8:30,30,38:ALICE]$body[/SIDECARD][/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
''';
}

Future<File> _writeHero(Directory root) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 48, 32),
    ui.Paint()..color = const ui.Color(0xFF27485C),
  );
  canvas.drawRect(
    const ui.Rect.fromLTWH(24, 0, 24, 32),
    ui.Paint()..color = const ui.Color(0xFFD89B4A),
  );
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(48, 32);
  picture.dispose();
  try {
    final ByteData? png =
        await image.toByteData(format: ui.ImageByteFormat.png);
    expect(png, isNotNull);
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

Future<Uint8List> _raster(
  void Function(ui.Canvas canvas) paint,
) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  paint(canvas);
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(
    _compositionSize.width.toInt(),
    _compositionSize.height.toInt(),
  );
  picture.dispose();
  try {
    final ByteData? rgba =
        await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(rgba, isNotNull);
    return Uint8List.fromList(
      rgba!.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes),
    );
  } finally {
    image.dispose();
  }
}

void main() {
  for (final bool rich in <bool>[false, true]) {
    test(
      'seated SIDECARD runtime face equals direct face painter '
      '(${rich ? 'rich' : 'simple'})',
      () async {
        final Directory root =
            Directory.systemTemp.createTempSync('r3nder_card_face_parity_');
        final File hero = await _writeHero(root);
        addTearDown(() {
          if (root.existsSync()) root.deleteSync(recursive: true);
        });

        final String source = _sideCardSource(rich: rich);
        final EditDocumentModel model = EditDocumentModel.parse(source);
        final StructuralSourceRef rootRef =
            StructuralSourceRef.tryParse('EDIT.main')!;
        final List<StructuralCardOverlayPlacement> placements =
            structuralCardOverlayPlacements(model, rootRef, 16);

        expect(placements, hasLength(1));
        final StructuralCardOverlayPlacement placement = placements.single;
        expect(placement.isSideCard, isTrue);
        expect(placement.slide, 1.0);

        final CardOverlayImageCache images = CardOverlayImageCache(
          (String source) => hero.path,
        );
        addTearDown(images.dispose);
        expect(await images.ensure(placements), isTrue);

        final ui.Image? heroImage = images.imageFor(placement.card);
        expect(heroImage, isNotNull);

        // Runtime path: drive the real structural SIDECARD panel painter at the
        // first fully seated frame. This is the path the program compositor
        // actually uses; no test-owned card geometry is substituted here.
        final Uint8List runtime = await _raster((ui.Canvas canvas) {
          paintStructuralSideCardPanel(
            canvas: canvas,
            size: _compositionSize,
            placement: placement,
            images: images,
            fontFamily: 'monospace',
          );
        });

        // Direct path: use the same seated rectangle authority consumed by the
        // runtime path. Do not reconstruct its geometry in the test.
        final ui.Rect seated = sideCardSeatedPanelRect(_compositionSize);
        final Uint8List direct = await _raster((ui.Canvas canvas) {
          paintPresentationCardFace(
            canvas: canvas,
            compositionSize: _compositionSize,
            cardRect: seated,
            card: placement.card,
            image: heroImage,
            inheritedFontFamily: 'monospace',
          );
        });

        expect(
          direct,
          orderedEquals(runtime),
          reason: 'A visual responsibility remains outside the shared face '
              'painter if the seated runtime raster differs at any pixel.',
        );
      },
    );
  }
}
