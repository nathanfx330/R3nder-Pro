// ./test/card_overlay_state_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/card_overlay_state.dart';
import 'package:r3nder/edit_model.dart';

void main() {
  test('EDIT lifetime truncates SIDECARD but exposes final shell state', () {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:shot:video/shot.mp4:0:0:12:1]
[CUE:8]
[SIDECARD:person.png:45:24,32,40:JOHN SMITH]
Biography text.
[/SIDECARD]
[/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final EditDocumentModel model = EditDocumentModel.parse(source);
    final StructuralSourceRef root = StructuralSourceRef.tryParse('EDIT.main')!;

    // The final authored source frame is cue age three, so the opening is only
    // 3/16 complete when EDIT lifetime cuts the presentation off.
    final StructuralCardOverlayPlacement? finalFrame =
        structuralSideCardPlacement(model, root, 11);
    expect(finalFrame, isNotNull);
    expect(finalFrame!.slide, closeTo(3 / 16, 0.000001));

    // Presentation state does not leak beyond the EDIT lifetime.
    expect(structuralSideCardPlacement(model, root, 12), isNull);

    // STRUCT may still query the final visible shell state solely to choose the
    // origin of its own closing choreography. This does not extend the card.
    final StructuralCardOverlayPlacement? boundary =
        structuralSideCardPlacementAtSourceEnd(model, root, 12);
    expect(boundary, isNotNull);
    expect(boundary!.slide, closeTo(3 / 16, 0.000001));
  });
}
