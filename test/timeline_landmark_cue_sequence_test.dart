// ./test/timeline_landmark_cue_sequence_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/timeline_markers.dart';

void main() {
  test('CARD SIDECARD and DOSSIER cues all project as timeline landmarks', () {
    const String source = '''[EDIT:cut]
  [TRACK:V1]
    [CLIP:c1:clip.mp4:10:0:120:1]
      [CUE:10]
        [CARD:person.png:10:24,32,40:FULL]
          Full card.
        [/CARD]
      [/CUE]
      [CUE:40]
        [SIDECARD:person.png:10:24,32,40:SIDE]
          Side card.
        [/SIDECARD]
      [/CUE]
      [CUE:70]
        [DOSSIER:evidence:person.png:10:20:0:MOSAIC:24,32,40:FILE]
          Dossier body.
        [/DOSSIER]
      [/CUE]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

    final List<DerivedLandmark> landmarks =
        derivedLandmarksForEdit(source, 'cut');
    final List<DerivedLandmark> cues = landmarks
        .where((DerivedLandmark item) => item.kind == DerivedLandmarkKind.cue)
        .toList(growable: false);
    final List<DerivedLandmark> outs = landmarks
        .where(
          (DerivedLandmark item) =>
              item.kind == DerivedLandmarkKind.presentationOut,
        )
        .toList(growable: false);

    expect(cues, hasLength(3));
    expect(cues.map((DerivedLandmark item) => item.frame), <int>[20, 50, 80]);
    expect(
      cues.map((DerivedLandmark item) => item.label),
      <String>['CARD IN', 'SIDECARD IN', 'DOSSIER CUE'],
    );

    // CARD/SIDECARD hold 10: 16 opening + 10 seated + 16 closing = 42.
    expect(outs, hasLength(2));
    expect(outs.map((DerivedLandmark item) => item.frame), <int>[62, 92]);
    expect(
      outs.map((DerivedLandmark item) => item.label),
      <String>['CARD OUT', 'SIDECARD OUT'],
    );
  });

  test('CARD OUT follows presentation lifetime across a later clip cut', () {
    const String source = '''[EDIT:cut]
  [TRACK:V1]
    [CLIP:a:a.mp4:0:0:30:1]
      [CUE:20]
        [CARD:person.png:20:24,32,40:FULL]
          Full card.
        [/CARD]
      [/CUE]
    [/CLIP]
    [CLIP:b:b.mp4:30:0:70:1]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

    final List<DerivedLandmark> landmarks =
        derivedLandmarksForEdit(source, 'cut');
    final DerivedLandmark cardIn = landmarks.singleWhere(
      (DerivedLandmark item) => item.label == 'CARD IN',
    );
    final DerivedLandmark cardOut = landmarks.singleWhere(
      (DerivedLandmark item) => item.label == 'CARD OUT',
    );

    expect(cardIn.frame, 20);
    // 16 open + 20 hold + 16 close = 52 visible frames. The source clip ends
    // at 30, but the presentation intentionally continues across that cut.
    expect(cardOut.frame, 72);
  });

  test('CARD OUT truncates at enclosing EDIT boundary', () {
    const String source = '''[EDIT:cut]
  [TRACK:V1]
    [CLIP:a:a.mp4:0:0:30:1]
      [CUE:20]
        [CARD:person.png:50:24,32,40:FULL]
          Full card.
        [/CARD]
      [/CUE]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

    final List<DerivedLandmark> landmarks =
        derivedLandmarksForEdit(source, 'cut');
    final DerivedLandmark cardOut = landmarks.singleWhere(
      (DerivedLandmark item) => item.label == 'CARD OUT',
    );

    expect(cardOut.frame, 30);
  });

  test('adjacent clip OUT and IN remain separate landmark definitions', () {
    const String source = '''[EDIT:cut]
  [TRACK:V1]
    [CLIP:a:a.mp4:0:0:30:1]
    [/CLIP]
    [CLIP:b:b.mp4:30:0:30:1]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

    final List<DerivedLandmark> landmarks =
        derivedLandmarksForEdit(source, 'cut');
    final List<DerivedLandmark> boundary = landmarks
        .where((DerivedLandmark item) => item.frame == 30)
        .toList(growable: false);

    expect(boundary, hasLength(2));
    expect(
      boundary.map((DerivedLandmark item) => item.kind).toSet(),
      <DerivedLandmarkKind>{
        DerivedLandmarkKind.clipIn,
        DerivedLandmarkKind.clipOut,
      },
    );
  });
}
