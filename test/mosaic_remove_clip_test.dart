// ./test/mosaic_remove_clip_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_linter.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/mosaic_surface_model.dart';

const String _before = '''PREFIX
[EDIT:source]
[TRACK:V1]
[CLIP:media:video/source.mp4:0:0:300:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
  [PANE:left]
    [CLIP:first:EDIT.source:0:7:100:1]
keep first body
    [/CLIP]
    [#] keep this comment before the selected block
    ''';

const String _selected = '''[CLIP:middle:EDIT.source:80:20:100:1/2]
[#EDIT_TRANSITION:CROSSFADE:20]
[CUE:25]
[CARD:card.png:20:30,30,38:SELECTED]
selected cue body
[/CARD]
[/CUE]
opaque selected bytes
    [/CLIP]''';

const String _after = '''\n    [#] keep this comment after the selected block
    [CLIP:last:EDIT.source:200:40:80:2]
keep last body
    [/CLIP]
  [/PANE]
  [PANE:right]
    [CLIP:middle:EDIT.source:0:0:120:1]
same clip id in another pane stays
    [/CLIP]
  [/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall]
SUFFIX
''';

const String _source = '$_before$_selected$_after';

void main() {
  group('MosaicSurfaceDocument.removeClip', () {
    for (final String newline in <String>['\n', '\r\n']) {
      final String label = newline == '\n' ? 'LF' : 'CRLF';
      test('preserves every byte outside the selected block with $label', () {
        final String source = _source.replaceAll('\n', newline);
        final MosaicSurfaceDocument document =
            MosaicSurfaceDocument.parse(source, 'wall');

        final String next = document.removeClip('left', 'middle');
        final MosaicSurfaceDocument after =
            MosaicSurfaceDocument.parse(next, 'wall');

        expect(next, '$_before$_after'.replaceAll('\n', newline));
        expect(document.source, source);
        expect(document.pane('left').clips, hasLength(3));
        expect(after.pane('left').clips.map((EditClip clip) => clip.id),
            <String>['first', 'last']);
        expect(after.clip('right', 'middle').durationFrames, 120);
      });
    }

    test('removing incoming crossfade clip leaves other timing unchanged', () {
      final MosaicSurfaceDocument document =
          MosaicSurfaceDocument.parse(_source, 'wall');
      expect(document.incomingCrossfadeFrames('left', 'middle'), 20);

      final String next = document.removeClip('left', 'middle');
      final MosaicSurfaceDocument after =
          MosaicSurfaceDocument.parse(next, 'wall');

      expect(next, isNot(contains('[#EDIT_TRANSITION:CROSSFADE:20]')));
      expect(next, isNot(contains('selected cue body')));
      expect(after.incomingCrossfadeFrames('left', 'first'), 0);
      expect(after.incomingCrossfadeFrames('left', 'last'), 0);
      expect(after.clip('left', 'first').atFrame, 0);
      expect(after.clip('left', 'first').endFrameExclusive, 100);
      expect(after.clip('left', 'last').atFrame, 200);
      expect(after.clip('left', 'last').inFrame, 40);
      expect(after.clip('left', 'last').durationFrames, 80);
      expect(after.clip('left', 'last').speed, ExactClipSpeed(2));
      expect(after.projectFrameCount, 280);
      expect(EditGraphLinter.lint(after.model).isValid, isTrue);
    });

    test('removing first clip preserves the next clips incoming transition', () {
      final MosaicSurfaceDocument document =
          MosaicSurfaceDocument.parse(_source, 'wall');
      final MosaicSurfaceDocument after = MosaicSurfaceDocument.parse(
        document.removeClip('left', 'first'),
        'wall',
      );

      expect(after.clip('left', 'middle').block.rawSource, _selected);
      expect(after.clip('left', 'middle').atFrame, 80);
      expect(after.incomingCrossfadeFrames('left', 'middle'), 20);
      expect(after.clip('left', 'last').atFrame, 200);
    });

    test('removing the only clip preserves the empty pane and pane order', () {
      final MosaicSurfaceDocument document =
          MosaicSurfaceDocument.parse(_source, 'wall');

      final String next = document.removeClip('right', 'middle');
      final MosaicSurfaceDocument after =
          MosaicSurfaceDocument.parse(next, 'wall');

      expect(after.mosaic.panes.map((MosaicPane pane) => pane.id),
          <String>['left', 'right']);
      expect(after.pane('right').clips, isEmpty);
      expect(after.pane('right').projectFrameCount, 0);
      expect(after.pane('left').block.rawSource,
          document.pane('left').block.rawSource);
      expect(after.projectFrameCount, 280);
      expect(EditGraphLinter.lint(after.model).isValid, isTrue);
    });

    for (final bool missingPane in <bool>[true, false]) {
      test('unknown ${missingPane ? 'pane' : 'clip'} fails without mutation', () {
        final MosaicSurfaceDocument document =
            MosaicSurfaceDocument.parse(_source, 'wall');

        expect(
          () => document.removeClip(
            missingPane ? 'missing' : 'left',
            missingPane ? 'middle' : 'missing',
          ),
          throwsStateError,
        );
        expect(document.source, _source);
      });
    }

    test('reparsed removals derive duration from surviving clips', () {
      final MosaicSurfaceDocument document =
          MosaicSurfaceDocument.parse(_source, 'wall');
      final MosaicSurfaceDocument withoutLast = MosaicSurfaceDocument.parse(
        document.removeClip('left', 'last'),
        'wall',
      );
      expect(withoutLast.projectFrameCount, 180);

      final MosaicSurfaceDocument withoutMiddle = MosaicSurfaceDocument.parse(
        withoutLast.removeClip('left', 'middle'),
        'wall',
      );
      expect(withoutMiddle.pane('left').projectFrameCount, 100);
      expect(withoutMiddle.projectFrameCount, 120);
      expect(withoutMiddle.clip('right', 'middle').durationFrames, 120);
      expect(withoutMiddle.source, contains('[STRUCT:MOSAIC.wall]'));
    });

    test('validates the resulting structural graph before returning source', () {
      final String invalid = _source.replaceFirst(
        '[CLIP:last:EDIT.source:',
        '[CLIP:last:EDIT.missing:',
      );
      final MosaicSurfaceDocument document =
          MosaicSurfaceDocument.parse(invalid, 'wall');

      expect(
        () => document.removeClip('left', 'middle'),
        throwsA(isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('missing EDIT "missing"'),
        )),
      );
      expect(document.source, invalid);
    });
  });
}
