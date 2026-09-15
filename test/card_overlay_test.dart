// ./test/card_overlay_test.dart

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/card_overlay.dart';
import 'package:r3nder/edit_model.dart';

void main() {
  test('EDIT cue plans over the complete structural surface', () {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:shot:video/a.mp4:0:0:100:1]
[CUE:0][CARD:person.png:8:10,20,30:ALICE]Biography[/CARD][/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final EditDocumentModel model = EditDocumentModel.parse(source);
    final StructuralSourceRef root = StructuralSourceRef.tryParse('EDIT.main')!;
    final List<StructuralCardOverlayPlacement> placements =
        structuralCardOverlayPlacements(model, root, 16);

    expect(placements, hasLength(1));
    expect(placements.single.normalizedRect, const Rect.fromLTWH(0, 0, 1, 1));
    expect(placements.single.slide, 1.0);
    expect(placements.single.card.heading, 'ALICE');
    expect(structuralCardImageSource(placements.single.card), 'images/person.png');
  });

  test('MOSAIC cue owns only its pane rectangle', () {
    const String source = '''[MOSAIC:wall]
[PANE:left]
[CLIP:leftShot:video/left.mp4:0:0:100:1]
[/CLIP]
[/PANE]
[PANE:right]
[CLIP:rightShot:video/right.mp4:0:0:100:1]
[CUE:0][CARD:person.png:8]BIO[/CARD][/CUE]
[/CLIP]
[/PANE]
[/MOSAIC]
''';

    final EditDocumentModel model = EditDocumentModel.parse(source);
    final StructuralSourceRef root = StructuralSourceRef.tryParse('MOSAIC.wall')!;
    final List<StructuralCardOverlayPlacement> placements =
        structuralCardOverlayPlacements(model, root, 16);

    expect(placements, hasLength(1));
    expect(
      placements.single.normalizedRect,
      const Rect.fromLTRB(0.56, 0, 1, 1),
    );
  });

  testWidgets('CARD pixels cannot escape their MOSAIC pane', (tester) async {
    const String source = '''[MOSAIC:wall]
[PANE:left]
[CLIP:leftShot:video/left.mp4:0:0:100:1]
[/CLIP]
[/PANE]
[PANE:right]
[CLIP:rightShot:video/right.mp4:0:0:100:1]
[CUE:0][CARD:missing.png:8:22,36,52:ALICE]Biography[/CARD][/CUE]
[/CLIP]
[/PANE]
[/MOSAIC]
''';

    final EditDocumentModel model = EditDocumentModel.parse(source);
    final StructuralSourceRef root = StructuralSourceRef.tryParse('MOSAIC.wall')!;
    final List<StructuralCardOverlayPlacement> placements =
        structuralCardOverlayPlacements(model, root, 16);
    final CardOverlayImageCache images =
        CardOverlayImageCache((String _) => '/definitely/missing');

    const int width = 320;
    const int height = 180;
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(
      recorder,
      const Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    );
    paintStructuralCardOverlays(
      canvas: canvas,
      size: const Size(width.toDouble(), height.toDouble()),
      placements: placements,
      images: images,
      fontFamily: 'monospace',
    );
    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(width, height);
    final ByteData data = (await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!;
    final Uint8List rgba = data.buffer.asUint8List();

    int minX = width;
    int maxX = -1;
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        if (rgba[(y * width + x) * 4 + 3] == 0) continue;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
      }
    }

    expect(maxX, greaterThanOrEqualTo(0));
    expect(minX, greaterThanOrEqualTo((width * 0.56).floor()));
    expect(maxX, lessThan(width));

    image.dispose();
    picture.dispose();
    images.dispose();
  });
}
