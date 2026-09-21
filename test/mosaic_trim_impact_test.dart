// ./test/mosaic_trim_impact_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_cue.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/mosaic_trim.dart';
import 'package:r3nder/mosaic_trim_impact.dart';

const String _source = '''[EDIT:source]
[TRACK:V1]
[CLIP:media:video/source.mp4:0:0:500:1]
  [STRUCT:MOSAIC.wall]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:short]
[CLIP:short:EDIT.source:0:0:100:1][/CLIP]
[/PANE]
[PANE:long]
[CLIP:long:EDIT.source:0:20:200:2]
[CUE:60][MAXIMIZE:5][/CUE]
[CUE:220][CARD:card.png:20:30,30,38:CARD]Body.[/CARD][/CUE]
[CUE:240][MAXIMIZE:5][/CUE]
[CUE:260]
[DOSSIER:evidence:person.png:45:60:12:MOSAIC:24,32,40:PERSON]
Body.
[/DOSSIER]
[/CUE]
[CUE:10][MAXIMIZE:5][/CUE]
[CUE:500][MAXIMIZE:5][/CUE]
[/CLIP]
[CLIP:removed:EDIT.source:200:0:20:1]
[CUE:0][MAXIMIZE:5][/CUE]
[/CLIP]
[/PANE]
[/MOSAIC]
[MOSAIC:relay]
[PANE:relay]
[CLIP:relay:MOSAIC.wall:0:0:101:1][/CLIP]
[/PANE]
[/MOSAIC]
[EDIT:consumer]
[TRACK:V1]
[CLIP:new:MOSAIC.wall:0:90:6:2][/CLIP]
[CLIP:safe:MOSAIC.wall:10:0:200:1/2][/CLIP]
[CLIP:old:MOSAIC.wall:220:230:2:1][/CLIP]
[/TRACK]
[/EDIT]
[STRUCT:MOSAIC.wall]
[PAUSE:10]
[STRUCT:MOSAIC.wall:FULL]
[STRUCT:EDIT.consumer]
''';

void main() {
  test('preview reports the exact pending trim without changing its source', () {
    final MosaicTrimImpact impact = previewMosaicTrim(_source, 'wall')!;

    expect(impact.sourceAfter, trimMosaicToShortest(_source, 'wall'));
    expect(impact.beforeFrames, 220);
    expect(impact.afterFrames, 100);
    expect(impact.framesRemoved, 120);
    expect(impact.clipsTrimmed, 1);
    expect(impact.clipsRemoved, 1);
    expect(EditDocumentModel.parse(_source).mosaic('wall').projectFrameCount, 220);
    expect(impact.summary, contains('220 to 100 frames (120 removed)'));
    expect(impact.summary, contains('Existing gaps remain.'));
  });

  test('counts newly dormant pane cues with IN and speed across cue families', () {
    final MosaicTrimImpact impact = previewMosaicTrim(_source, 'wall')!;

    expect(impact.dormantCues, 3);
    expect(impact.removedCues, 1);
    final EditClip before =
        EditDocumentModel.parse(_source).mosaic('wall').pane('long').clip('long');
    final EditClip after = EditDocumentModel.parse(impact.sourceAfter)
        .mosaic('wall').pane('long').clip('long');
    expect(after.block.innerSource, before.block.innerSource);
    expect(impact.summary, contains('Pane cues made dormant: 3.'));
    expect(impact.summary, contains('Cues deleted with removed clips: 1.'));
  });

  test('counts executable STRUCT uses and reports original document lines', () {
    final MosaicTrimImpact impact = previewMosaicTrim(_source, 'wall')!;
    final List<String> lines = _source.split('\n');
    final List<int> expected = <int>[
      lines.indexOf('[STRUCT:MOSAIC.wall]') + 1,
      lines.indexOf('[STRUCT:MOSAIC.wall:FULL]') + 1,
    ];

    expect(impact.placementLines, expected);
    expect(impact.summary, contains('STRUCT placements affected: 2.'));
    expect(impact.summary, contains('Later TEXT timing moves earlier.'));
    expect(() => impact.placementLines.clear(), throwsUnsupportedError);
  });

  test('overruns use exact last source requests and authored consumer order', () {
    final MosaicTrimImpact impact = previewMosaicTrim(_source, 'wall')!;

    expect(impact.consumerOverruns.map((c) => c.location), <String>[
      'MOSAIC.relay / relay / relay',
      'EDIT.consumer / V1 / new',
      'EDIT.consumer / V1 / old',
    ]);
    expect(impact.consumerOverruns.map((c) => c.lastSourceFrame),
        <int>[100, 100, 231]);
    expect(impact.consumerOverruns.map((c) => c.alreadyOverran),
        <bool>[false, false, true]);
    expect(impact.summary, contains('already overran before this trim'));
    final EditDocumentModel before = EditDocumentModel.parse(_source);
    final EditDocumentModel after = EditDocumentModel.parse(impact.sourceAfter);
    expect(after.edit('consumer').block.rawSource,
        before.edit('consumer').block.rawSource);
    expect(after.mosaic('relay').block.rawSource,
        before.mosaic('relay').block.rawSource);
  });

  test('already aligned panes have no pending confirmation', () {
    final String aligned = trimMosaicToShortest(_source, 'wall');
    expect(previewMosaicTrim(aligned, 'wall'), isNull);
  });

  test('malformed affected cue fails instead of claiming a complete summary', () {
    final String malformed = _source.replaceFirst('[CUE:220]', '[CUE:oops]');
    expect(() => previewMosaicTrim(malformed, 'wall'),
        throwsA(isA<EditCueFormatException>()));
  });

  test('trim conflicts remain blocking during impact preparation', () {
    final String conflicting = _source.replaceFirst(
      '[CLIP:long:EDIT.source:0:20:200:2]',
      '[CLIP:long:EDIT.source:150:20:200:2]',
    );
    expect(() => previewMosaicTrim(conflicting, 'wall'),
        throwsA(isA<MosaicTrimException>()));
  });
}
