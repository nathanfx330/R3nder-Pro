// ./test/structural_sequence_chrome_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/structural_chrome.dart';
import 'package:r3nder/structural_sequence.dart';

const String _source = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:clip:video/file.mp4:0:0:30:1]
    [/CLIP]
  [/TRACK]
[/EDIT]
[STRUCT:EDIT.main:FULL:OVERLAY=CUSTOM:TITLE="Field Monitor":TOP="FEB 1972":BOTTOM="REEL 4"]
''';

void main() {
  test('planner carries authored player chrome on the STRUCT placement', () {
    final placements = parseStructuralSequencePlacements(_source);
    expect(placements, hasLength(1));

    final placement = placements.single;
    expect(placement.fullscreen, isTrue);
    expect(placement.overlayMode, StructuralOverlayMode.custom);
    expect(placement.windowTitle, 'Field Monitor');
    expect(placement.effectiveWindowTitle, 'Field Monitor');
    expect(placement.topOverlay, 'FEB 1972');
    expect(placement.bottomOverlay, 'REEL 4');
  });

  test('legacy placement keeps existing chrome defaults', () {
    const String source = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:clip:video/file.mp4:0:0:30:1]
    [/CLIP]
  [/TRACK]
[/EDIT]
[STRUCT:EDIT.main]
''';

    final placement = parseStructuralSequencePlacements(source).single;
    expect(placement.fullscreen, isFalse);
    expect(placement.overlayMode, StructuralOverlayMode.defaultOverlay);
    expect(placement.windowTitle, isEmpty);
    expect(placement.effectiveWindowTitle, 'EDIT.main');
    expect(placement.topOverlay, isEmpty);
    expect(placement.bottomOverlay, isEmpty);
  });
}
