// ./test/card_overlay_test.dart

import 'dart:ui' as ui;

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
    expect(placements.single.normalizedRect, const ui.Rect.fromLTWH(0, 0, 1, 1));
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
      const ui.Rect.fromLTRB(0.56, 0, 1, 1),
    );
  });

  test('overlapping MOSAIC CARD cues remain bounded to their authored panes', () {
    const String source = '''[MOSAIC:wall]
[PANE:left]
[CLIP:leftShot:video/left.mp4:0:0:100:1]
[CUE:0][CARD:left.png:8]LEFT[/CARD][/CUE]
[/CLIP]
[/PANE]
[PANE:right]
[CLIP:rightShot:video/right.mp4:0:0:100:1]
[CUE:0][CARD:right.png:8]RIGHT[/CARD][/CUE]
[/CLIP]
[/PANE]
[/MOSAIC]
''';

    final EditDocumentModel model = EditDocumentModel.parse(source);
    final StructuralSourceRef root = StructuralSourceRef.tryParse('MOSAIC.wall')!;
    final List<StructuralCardOverlayPlacement> placements =
        structuralCardOverlayPlacements(model, root, 16);

    expect(placements, hasLength(2));
    expect(
      placements.map((StructuralCardOverlayPlacement p) => p.normalizedRect),
      <ui.Rect>[
        const ui.Rect.fromLTRB(0, 0, 0.56, 1),
        const ui.Rect.fromLTRB(0.56, 0, 1, 1),
      ],
    );

    for (final StructuralCardOverlayPlacement placement in placements) {
      final ui.Rect rect = placement.normalizedRect;
      expect(rect.left, greaterThanOrEqualTo(0.0));
      expect(rect.top, greaterThanOrEqualTo(0.0));
      expect(rect.right, lessThanOrEqualTo(1.0));
      expect(rect.bottom, lessThanOrEqualTo(1.0));
      expect(rect.width, greaterThan(0.0));
      expect(rect.height, greaterThan(0.0));
    }
  });
}
