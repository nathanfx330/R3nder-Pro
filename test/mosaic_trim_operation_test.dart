// ./test/mosaic_trim_operation_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/mosaic_surface_model.dart';
import 'package:r3nder/mosaic_trim.dart';

String _script(String panes, {int sourceFrames = 500}) => '''PREFIX
[EDIT:source]
[TRACK:V1]
[CLIP:media:video/source.mp4:0:0:$sourceFrames:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
$panes
[/MOSAIC]
[EDIT:consumer]
[TRACK:V1]
[CLIP:usage:MOSAIC.wall:0:0:400:1]
[/CLIP]
[/TRACK]
[/EDIT]
[STRUCT:MOSAIC.wall]
SUFFIX
''';

const String _boundaryClip = '''[CLIP:boundary:EDIT.source:100:0:20:1]
[#EDIT_TRANSITION:CROSSFADE:10]
[/CLIP]''';

const String _laterClip = '''[CLIP:later:EDIT.source:150:0:20:1]
later clip body
[/CLIP]''';

const String _panes = '''[PANE:short]
[CLIP:first:EDIT.source:0:0:20:1]
[/CLIP]
[CLIP:last:EDIT.source:80:0:20:1]
[/CLIP]
[/PANE]
[PANE:long]
  [CLIP:crossing:EDIT.source:10:200:180:1/2:GAIN=0.5:MUTE]
[CUE:260]
[CARD:card.png:20:30,30,38:KEPT]
dormant cue body remains authored
[/CARD]
[/CUE]
  [/CLIP]
[CLIP:exact:EDIT.source:20:0:80:1]
exact boundary body
[/CLIP]
  $_boundaryClip
  [#] keep this gap comment
  $_laterClip
[/PANE]
[PANE:empty]
[/PANE]''';

MosaicTrimException _conflict(String source) {
  try {
    trimMosaicToShortest(source, 'wall');
  } on MosaicTrimException catch (error) {
    return error;
  }
  throw StateError('Expected a MosaicTrimException.');
}

void main() {
  group('trimMosaicToShortest', () {
    for (final String newline in <String>['\n', '\r\n']) {
      final String label = newline == '\n' ? 'LF' : 'CRLF';
      test('aligns endings with exact source preservation for $label', () {
        final String source = _script(_panes).replaceAll('\n', newline);
        final MosaicSurfaceDocument before =
            MosaicSurfaceDocument.parse(source, 'wall');

        final String next = trimMosaicToShortest(source, 'wall');
        final MosaicSurfaceDocument after =
            MosaicSurfaceDocument.parse(next, 'wall');
        final String expected = _script(_panes
                .replaceFirst(':10:200:180:1/2:', ':10:200:90:1/2:')
                .replaceFirst(_boundaryClip, '')
                .replaceFirst(_laterClip, ''))
            .replaceAll('\n', newline);

        expect(next, expected);
        expect(after.projectFrameCount, 100);
        expect(after.pane('short').block.rawSource,
            before.pane('short').block.rawSource);
        expect(after.pane('empty').block.rawSource,
            before.pane('empty').block.rawSource);
        expect(after.clip('long', 'exact').block.rawSource,
            before.clip('long', 'exact').block.rawSource);
        expect(after.model.edit('source').block.rawSource,
            before.model.edit('source').block.rawSource);
        expect(after.model.edit('consumer').block.rawSource,
            before.model.edit('consumer').block.rawSource);
        expect(after.clip('long', 'crossing').block.innerSource,
            before.clip('long', 'crossing').block.innerSource);
        expect(after.pane('long').clips.map((EditClip clip) => clip.id),
            <String>['crossing', 'exact']);
        expect(after.clip('long', 'crossing').atFrame, 10);
        expect(after.clip('long', 'crossing').inFrame, 200);
        expect(after.clip('long', 'crossing').speed, ExactClipSpeed(1, 2));
        expect(after.clip('short', 'last').atFrame, 80);
        expect(before.source, source);
        expect(before.projectFrameCount, 190);
        expect(trimMosaicToShortest(next, 'wall'), next);
      });
    }

    const Map<String, String> noOps = <String, String>{
      'empty panes': '[PANE:a][/PANE][PANE:b][/PANE]',
      'one populated pane': '''[PANE:a]
[CLIP:a:EDIT.source:0:0:100:1][/CLIP]
[/PANE][PANE:b][/PANE]''',
      'equal pane endings': '''[PANE:a]
[CLIP:a:EDIT.source:0:0:100:1][/CLIP]
[/PANE][PANE:b]
[CLIP:b:EDIT.source:50:0:50:1][/CLIP]
[/PANE]''',
    };
    for (final MapEntry<String, String> entry in noOps.entries) {
      test('${entry.key} returns the original source unchanged', () {
        final String source = _script(entry.value);
        expect(identical(trimMosaicToShortest(source, 'wall'), source), isTrue);
      });
    }

    test('rejects a target inside an incoming crossfade and names its pane', () {
      final String source = _script('''[PANE:short]
[CLIP:short:EDIT.source:0:0:90:1][/CLIP]
[/PANE]
[PANE:fade]
[CLIP:outgoing:EDIT.source:0:0:100:1][/CLIP]
[CLIP:incoming:EDIT.source:80:0:120:1]
[#EDIT_TRANSITION:CROSSFADE:20]
[/CLIP]
[/PANE]''');
      final MosaicTrimException error = _conflict(source);

      expect(error.mosaicId, 'wall');
      expect(error.endFrameExclusive, 90);
      expect(error.conflicts, hasLength(1));
      expect(error.conflicts.single.kind,
          MosaicTrimConflictKind.incomingCrossfade);
      expect(error.conflicts.single.paneId, 'fade');
      expect(error.conflicts.single.clipId, 'incoming');
      expect(error.message, contains('PANE "fade", CLIP "incoming"'));
      expect(error.message, contains('20F incoming crossfade'));
      expect(error.message, contains('10 remaining frames'));
      expect(MosaicSurfaceDocument.parse(source, 'wall').projectFrameCount, 200);
    });

    test('target at the end of an incoming crossfade is allowed', () {
      final String source = _script('''[PANE:short]
[CLIP:short:EDIT.source:0:0:100:1][/CLIP]
[/PANE]
[PANE:fade]
[CLIP:outgoing:EDIT.source:0:0:100:1][/CLIP]
[CLIP:incoming:EDIT.source:80:0:120:1]
[#EDIT_TRANSITION:CROSSFADE:20]
[/CLIP]
[/PANE]''');
      final MosaicSurfaceDocument after = MosaicSurfaceDocument.parse(
        trimMosaicToShortest(source, 'wall'),
        'wall',
      );

      expect(after.projectFrameCount, 100);
      expect(after.clip('fade', 'incoming').durationFrames, 20);
      expect(after.incomingCrossfadeFrames('fade', 'incoming'), 20);
    });

    for (final int at in <int>[100, 150]) {
      test('rejects emptying a pane whose content starts at frame $at', () {
        final String source = _script('''[PANE:short]
[CLIP:short:EDIT.source:0:0:100:1][/CLIP]
[/PANE]
[PANE:late]
[CLIP:late:EDIT.source:$at:0:150:1][/CLIP]
[/PANE]''');
        final MosaicTrimException error = _conflict(source);

        expect(error.conflicts, hasLength(1));
        expect(error.conflicts.single.kind, MosaicTrimConflictKind.emptyPane);
        expect(error.conflicts.single.paneId, 'late');
        expect(error.conflicts.single.clipId, isNull);
        expect(error.message, contains('PANE "late"'));
        expect(error.message, contains('remove all its clips'));
        expect(MosaicSurfaceDocument.parse(source, 'wall').pane('late').clips,
            hasLength(1));
      });
    }

    test('reports every conflict in authored pane then clip order', () {
      // IDs and AT values deliberately disagree with authored order.
      final String source = _script('''[PANE:z_pane]
[CLIP:safe:EDIT.source:0:0:200:1][/CLIP]
[CLIP:z_clip:EDIT.source:80:0:120:1]
[#EDIT_TRANSITION:CROSSFADE:20]
[/CLIP]
[CLIP:a_clip:EDIT.source:70:0:100:1]
[#EDIT_TRANSITION:CROSSFADE:25]
[/CLIP]
[/PANE]
[PANE:a_pane]
[CLIP:late:EDIT.source:150:0:150:1][/CLIP]
[/PANE]
[PANE:short]
[CLIP:short:EDIT.source:0:0:90:1][/CLIP]
[/PANE]''');
      final MosaicTrimException error = _conflict(source);

      expect(error.conflicts.map((MosaicTrimConflict c) => c.paneId),
          <String>['z_pane', 'z_pane', 'a_pane']);
      expect(error.conflicts.map((MosaicTrimConflict c) => c.clipId),
          <String?>['z_clip', 'a_clip', null]);
      expect(error.conflicts.map((MosaicTrimConflict c) => c.paneIndex),
          <int>[0, 0, 1]);
      expect(error.conflicts.map((MosaicTrimConflict c) => c.clipIndex),
          <int?>[1, 2, null]);
      expect(error.message,
          'Cannot trim MOSAIC "wall" to frame 90:\n'
          'PANE "z_pane", CLIP "z_clip": '
          '20F incoming crossfade exceeds the 10 remaining frames.\n'
          'PANE "z_pane", CLIP "a_clip": '
          '25F incoming crossfade exceeds the 20 remaining frames.\n'
          'PANE "a_pane": trimming would remove all its clips.');
      expect(_conflict(source).message, error.message);
      expect(() => error.conflicts.clear(), throwsUnsupportedError);
      expect(MosaicSurfaceDocument.parse(source, 'wall')
          .clip('z_pane', 'safe').durationFrames, 200);
    });

    test('trims both longer panes in a three populated pane composition', () {
      final String source = _script('''[PANE:a]
[CLIP:a:EDIT.source:0:0:150:1][/CLIP]
[/PANE]
[PANE:b]
[CLIP:b:EDIT.source:0:0:100:1][/CLIP]
[/PANE]
[PANE:c]
[CLIP:c:EDIT.source:0:0:200:1][/CLIP]
[/PANE]''');
      final MosaicSurfaceDocument after = MosaicSurfaceDocument.parse(
        trimMosaicToShortest(source, 'wall'),
        'wall',
      );

      expect(after.mosaic.panes.map((MosaicPane pane) => pane.projectFrameCount),
          <int>[100, 100, 100]);
      expect(after.projectFrameCount, 100);
    });

    test('unknown MOSAIC fails rather than selecting a different source', () {
      expect(() => trimMosaicToShortest(_script(_panes), 'missing'),
          throwsStateError);
    });

    test('short referenced content does not override authored pane endings', () {
      final String source = _script('''[PANE:a]
[CLIP:a:EDIT.source:0:0:90:1][/CLIP]
[/PANE]
[PANE:b]
[CLIP:b:EDIT.source:0:0:200:1][/CLIP]
[/PANE]''', sourceFrames: 30);
      final MosaicSurfaceDocument after = MosaicSurfaceDocument.parse(
        trimMosaicToShortest(source, 'wall'),
        'wall',
      );

      expect(after.projectFrameCount, 90);
      expect(after.model.edit('source').projectFrameCount, 30);
    });
  });
}
