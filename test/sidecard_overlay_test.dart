// ./test/sidecard_overlay_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/card_overlay.dart';
import 'package:r3nder/edit_model.dart';

const String _source = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:shot:video/shot.mp4:0:0:300:1]
      [CUE:90]
        [SIDECARD:person.png:45:24,32,40:JOHN SMITH]
          Biography text.
        [/SIDECARD]
      [/CUE]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

void main() {
  test('seated SIDECARD puts window left and card right without overlap', () {
    const Size size = Size(1920, 1080);
    final Rect video = sideCardSeatedVideoWindowRect(size);
    final Rect card = sideCardSeatedPanelRect(size);

    expect(video.left, greaterThanOrEqualTo(0));
    expect(video.top, greaterThanOrEqualTo(0));
    expect(video.right, lessThanOrEqualTo(size.width));
    expect(video.bottom, lessThanOrEqualTo(size.height));

    expect(card.left, greaterThan(video.right));
    expect(card.right, lessThanOrEqualTo(size.width));
    expect(card.top, closeTo(video.top, 0.001));
    expect(card.bottom, closeTo(video.bottom, 0.001));
    expect(card.width, closeTo(size.width * 0.30, 0.001));
  });

  test('direct EDIT SIDECARD resolves as full structural target placement', () {
    final EditDocumentModel model = EditDocumentModel.parse(_source);
    final StructuralSourceRef root = StructuralSourceRef.parse('EDIT.main');

    final List<StructuralCardOverlayPlacement> placements =
        structuralCardOverlayPlacements(model, root, 106);

    expect(placements, hasLength(1));
    expect(placements.single.isSideCard, isTrue);
    expect(placements.single.slide, 1.0);
    expect(
      placements.single.normalizedRect,
      const Rect.fromLTWH(0, 0, 1, 1),
    );
  });

  test('SIDECARD starts from the same CARD slide timing', () {
    final EditDocumentModel model = EditDocumentModel.parse(_source);
    final StructuralSourceRef root = StructuralSourceRef.parse('EDIT.main');

    final StructuralCardOverlayPlacement opening =
        structuralCardOverlayPlacements(model, root, 90).single;
    final StructuralCardOverlayPlacement seated =
        structuralCardOverlayPlacements(model, root, 106).single;

    expect(opening.slide, 0.0);
    expect(seated.slide, 1.0);
  });
}
