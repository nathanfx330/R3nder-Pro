// ./test/mosaic_trim_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/mosaic_trim.dart';

MosaicSequence _mosaic(String panes) {
  return EditDocumentModel.parse('''[EDIT:source]
[TRACK:V1]
[CLIP:media:video/source.mp4:0:0:500:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
$panes
[/MOSAIC]
''').mosaic('wall');
}

void main() {
  group('mosaicCommonEndFrame', () {
    test('no panes has no candidate', () {
      expect(mosaicCommonEndFrame(_mosaic('')), isNull);
    });

    test('only empty panes have no candidate', () {
      final MosaicSequence mosaic = _mosaic('''[PANE:left]
[/PANE]
[PANE:right]
[/PANE]''');

      expect(mosaicCommonEndFrame(mosaic), isNull);
    });

    test('one populated pane has no candidate even beside empty panes', () {
      final MosaicSequence mosaic = _mosaic('''[PANE:left]
[/PANE]
[PANE:middle]
[CLIP:a:EDIT.source:0:0:100:1]
[/CLIP]
[/PANE]
[PANE:right]
[/PANE]''');

      expect(mosaicCommonEndFrame(mosaic), isNull);
    });

    test('empty pane does not contribute a zero endpoint', () {
      final MosaicSequence mosaic = _mosaic('''[PANE:left]
[CLIP:a:EDIT.source:0:0:100:1]
[/CLIP]
[/PANE]
[PANE:middle]
[/PANE]
[PANE:right]
[CLIP:b:EDIT.source:0:0:200:1]
[/CLIP]
[/PANE]''');

      expect(mosaicCommonEndFrame(mosaic), 100);
    });

    test('equal populated endpoints have no candidate beside an empty pane', () {
      final MosaicSequence mosaic = _mosaic('''[PANE:left]
[CLIP:a:EDIT.source:0:0:100:1]
[/CLIP]
[/PANE]
[PANE:middle]
[/PANE]
[PANE:right]
[CLIP:b:EDIT.source:20:0:80:1]
[/CLIP]
[/PANE]''');

      expect(mosaicCommonEndFrame(mosaic), isNull);
    });

    for (int shortestPane = 0; shortestPane < 3; shortestPane++) {
      test('finds the shortest endpoint in pane ${shortestPane + 1}', () {
        final StringBuffer panes = StringBuffer();
        for (int pane = 0; pane < 3; pane++) {
          final int duration = pane == shortestPane ? 90 : 200;
          panes.writeln('''[PANE:pane$pane]
[CLIP:clip$pane:EDIT.source:0:0:$duration:1]
[/CLIP]
[/PANE]''');
        }

        expect(mosaicCommonEndFrame(_mosaic(panes.toString())), 90);
      });
    }

    test('internal gaps use the assembled end rather than summed durations', () {
      final MosaicSequence mosaic = _mosaic('''[PANE:left]
[CLIP:first:EDIT.source:0:0:20:1]
[/CLIP]
[CLIP:last:EDIT.source:80:0:20:1]
[/CLIP]
[/PANE]
[PANE:right]
[CLIP:long:EDIT.source:0:0:200:1]
[/CLIP]
[/PANE]''');

      expect(mosaicCommonEndFrame(mosaic), 100);
      expect(mosaic.pane('left').clip('last').atFrame, 80);
      expect(mosaic.projectFrameCount, 200);
    });

    test('crossfade overlap uses the maximum clip end without double counting',
        () {
      final MosaicSequence mosaic = _mosaic('''[PANE:left]
[CLIP:outgoing:EDIT.source:0:0:100:1]
[/CLIP]
[CLIP:incoming:EDIT.source:80:0:120:1]
[#EDIT_TRANSITION:CROSSFADE:20]
[/CLIP]
[/PANE]
[PANE:right]
[CLIP:long:EDIT.source:0:0:210:1]
[/CLIP]
[/PANE]''');

      expect(mosaicCommonEndFrame(mosaic), 200);
    });

    test('uses authored AT and duration regardless of source IN and speed', () {
      final MosaicSequence mosaic = _mosaic('''[PANE:left]
[CLIP:a:EDIT.source:10:300:70:2]
[/CLIP]
[/PANE]
[PANE:right]
[CLIP:b:EDIT.source:0:0:100:1/2]
[/CLIP]
[/PANE]''');

      expect(mosaicCommonEndFrame(mosaic), 80);
    });

    test('candidate calculation leaves trim conflict validation to the caller',
        () {
      final MosaicSequence mosaic = _mosaic('''[PANE:left]
[CLIP:short:EDIT.source:0:0:90:1]
[/CLIP]
[/PANE]
[PANE:middle]
[CLIP:outgoing:EDIT.source:0:0:100:1]
[/CLIP]
[CLIP:incoming:EDIT.source:80:0:120:1]
[#EDIT_TRANSITION:CROSSFADE:20]
[/CLIP]
[/PANE]
[PANE:right]
[CLIP:late:EDIT.source:150:0:150:1]
[/CLIP]
[/PANE]''');

      // Applying this candidate would cut a crossfade and empty the last pane.
      // T0 only computes the endpoint; later trim validation must reject it.
      expect(mosaicCommonEndFrame(mosaic), 90);
      expect(mosaic.pane('right').clips, hasLength(1));
      expect(mosaic.projectFrameCount, 300);
    });
  });
}
