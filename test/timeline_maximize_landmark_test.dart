// ./test/timeline_maximize_landmark_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/timeline_markers.dart';

void main() {
  test('MAXIMIZE projects honest shell IN and OUT landmarks', () {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:shot:video/shot.mp4:0:0:100:1]
[CUE:10][MAXIMIZE:0][/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final List<DerivedLandmark> derived =
        derivedLandmarksForEdit(source, 'main');
    final List<DerivedLandmark> shell = derived
        .where((DerivedLandmark item) =>
            item.kind == DerivedLandmarkKind.shellIn ||
            item.kind == DerivedLandmarkKind.shellOut)
        .toList(growable: false);

    expect(shell, hasLength(2));
    expect(shell[0].kind, DerivedLandmarkKind.shellIn);
    expect(shell[0].frame, 10);
    expect(shell[0].label, 'MAXIMIZE IN');
    expect(shell[1].kind, DerivedLandmarkKind.shellOut);
    expect(shell[1].frame, 34);
    expect(shell[1].label, 'MAXIMIZE OUT');
  });

  test('shell OUT reflects source-boundary truncation', () {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:shot:video/shot.mp4:0:0:100:1]
[CUE:90][MAXIMIZE:180][/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final List<DerivedLandmark> shell = derivedLandmarksForEdit(source, 'main')
        .where((DerivedLandmark item) =>
            item.kind == DerivedLandmarkKind.shellIn ||
            item.kind == DerivedLandmarkKind.shellOut)
        .toList(growable: false);

    expect(shell, hasLength(2));
    expect(shell[0].frame, 90);
    expect(shell[1].frame, 100);
  });
}
