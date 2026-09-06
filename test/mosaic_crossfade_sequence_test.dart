// ./test/mosaic_crossfade_sequence_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/mosaic_surface_model.dart';

const String _source = '''[EDIT:cuts]
[TRACK:V1]
[CLIP:a:video/a.mp4:0:0:60:1]
[/CLIP]
[CLIP:b:video/b.mp4:60:0:60:1]
[/CLIP]
[CLIP:c:video/c.mp4:120:0:60:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:left]
[CLIP:a:video/a.mp4:0:0:60:1]
[/CLIP]
[CLIP:b:video/b.mp4:60:0:60:1]
[/CLIP]
[CLIP:c:video/c.mp4:120:0:60:1]
[/CLIP]
[/PANE]
[/MOSAIC]
''';

void main() {
  test('changing A-B crossfade shifts B and every downstream cut together', () {
    final MosaicSurfaceDocument document =
        MosaicSurfaceDocument.parse(_source, 'wall');

    final String fade24 = document.setCrossfadeBetween('left', 'a', 'b', 24);
    final MosaicSurfaceDocument after24 =
        MosaicSurfaceDocument.parse(fade24, 'wall');
    expect(after24.clip('left', 'a').atFrame, 0);
    expect(after24.clip('left', 'b').atFrame, 36);
    expect(after24.clip('left', 'c').atFrame, 96);
    expect(after24.incomingCrossfadeFrames('left', 'b'), 24);

    final String fade48 = after24.setCrossfadeBetween('left', 'a', 'b', 48);
    final MosaicSurfaceDocument after48 =
        MosaicSurfaceDocument.parse(fade48, 'wall');
    expect(after48.clip('left', 'b').atFrame, 12);
    expect(after48.clip('left', 'c').atFrame, 72);
    expect(after48.incomingCrossfadeFrames('left', 'b'), 48);

    final String hard = after48.setCrossfadeBetween('left', 'a', 'b', 0);
    final MosaicSurfaceDocument afterHard =
        MosaicSurfaceDocument.parse(hard, 'wall');
    expect(afterHard.clip('left', 'b').atFrame, 60);
    expect(afterHard.clip('left', 'c').atFrame, 120);
    expect(afterHard.incomingCrossfadeFrames('left', 'b'), 0);
    expect(afterHard.mosaic.projectFrameCount, 180);
  });

  test('appendCut makes duplicate cut ids unique instead of replacing a pane', () {
    final MosaicSurfaceDocument document =
        MosaicSurfaceDocument.parse(_source, 'wall');
    final EditClip sourceCut = document.model.edit('cuts').track('V1').clip('a');
    final String next = document.appendCut('left', sourceCut);
    final MosaicSurfaceDocument reparsed =
        MosaicSurfaceDocument.parse(next, 'wall');

    expect(reparsed.pane('left').clips.map((EditClip c) => c.id),
        containsAll(<String>['a', 'b', 'c', 'a_2']));
    expect(reparsed.clip('left', 'a_2').atFrame, 180);
  });
}
