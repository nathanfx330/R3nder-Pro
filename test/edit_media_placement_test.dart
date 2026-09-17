// ./test/edit_media_placement_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_media_import.dart';
import 'package:r3nder/edit_media_placement.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/edit_surface_model.dart';

const ImportedEditVideo _unityMedia = ImportedEditVideo(
  authoredSource: 'video/shot.mp4',
  resolvedPath: '/workspace/video/shot.mp4',
  clipBaseId: 'shot',
  durationFrames: 100,
  sourceLengthFrames: 100,
);

void main() {
  test('creates requested target EDIT when other EDITs already exist', () {
    const String source = '''HEADER
[EDIT:main]
[/EDIT]
TAIL
''';

    final MediaPlacementResult placed = placeMediaInEdit(
      source: source,
      media: _unityMedia,
      editId: 'shot_014',
      trackId: 'V1',
      atFrame: 0,
    );

    final EditDocumentModel model = EditDocumentModel.parse(placed.document);
    expect(
      model.edits.map((EditSequence edit) => edit.id),
      <String>['main', 'shot_014'],
    );
    expect(
      EditSurfaceDocument.parse(placed.document, 'shot_014')
          .clip('V1', 'shot')
          .source,
      'video/shot.mp4',
    );
    expect(placed.document.startsWith(source), isTrue);
  });

  test('source in and out author inFrame duration and conformed speed once', () {
    const ImportedEditVideo media = ImportedEditVideo(
      authoredSource: 'video/24fps.mp4',
      resolvedPath: '/workspace/video/24fps.mp4',
      clipBaseId: 'fps24',
      durationFrames: 300,
      sourceLengthFrames: 240,
      speedNumerator: 4,
      speedDenominator: 5,
      sourceFpsNumerator: 24,
      sourceFpsDenominator: 1,
    );

    final MediaPlacementResult placed = placeMediaInEdit(
      source: '[EDIT:main]\n[/EDIT]\n',
      media: media,
      editId: 'main',
      trackId: 'V1',
      atFrame: 10,
      inFrame: 40,
      outFrameExclusive: 120,
    );

    final EditSurfaceClip clip =
        EditSurfaceDocument.parse(placed.document, 'main').clip('V1', 'fps24');
    expect(clip.atFrame, 10);
    expect(clip.inFrame, 40);
    expect(clip.durationFrames, 100);
    expect(clip.speed, ExactClipSpeed(4, 5));
    expect(placed.requestedOutFrameExclusive, 120);
  });

  test('whole-file placement derives duration from source span, not cached duration', () {
    const ImportedEditVideo media = ImportedEditVideo(
      authoredSource: 'video/24fps.mp4',
      resolvedPath: '/workspace/video/24fps.mp4',
      clipBaseId: 'fps24',
      durationFrames: 999,
      sourceLengthFrames: 240,
      speedNumerator: 4,
      speedDenominator: 5,
      sourceFpsNumerator: 24,
      sourceFpsDenominator: 1,
    );

    final MediaPlacementResult placed = placeMediaInEdit(
      source: '[EDIT:main]\n[/EDIT]\n',
      media: media,
      editId: 'main',
      trackId: 'V1',
      atFrame: 0,
    );

    final EditSurfaceClip clip =
        EditSurfaceDocument.parse(placed.document, 'main').clip('V1', 'fps24');
    expect(clip.durationFrames, 300);
    expect(placed.durationFrames, 300);
  });

  test('source range beyond media length is rejected', () {
    expect(
      () => placeMediaInEdit(
        source: '[EDIT:main]\n[/EDIT]\n',
        media: _unityMedia,
        editId: 'main',
        trackId: 'V1',
        atFrame: 0,
        inFrame: 90,
        outFrameExclusive: 101,
      ),
      throwsArgumentError,
    );
  });

  test('plain placement rejects occupied frames and exact abutment succeeds', () {
    const String source = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:base:video/base.mp4:0:0:100:1]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

    expect(
      () => placeMediaInEdit(
        source: source,
        media: _unityMedia,
        editId: 'main',
        trackId: 'V1',
        atFrame: 50,
      ),
      throwsStateError,
    );

    final MediaPlacementResult abutting = placeMediaInEdit(
      source: source,
      media: _unityMedia,
      editId: 'main',
      trackId: 'V1',
      atFrame: 100,
    );
    expect(
      EditSurfaceDocument.parse(abutting.document, 'main')
          .clip('V1', 'shot')
          .atFrame,
      100,
    );
  });

  test('same media placed twice on one track receives distinct CLIP ids', () {
    final MediaPlacementResult first = placeMediaInEdit(
      source: '[EDIT:main]\n[/EDIT]\n',
      media: _unityMedia,
      editId: 'main',
      trackId: 'V1',
      atFrame: 0,
    );
    final MediaPlacementResult second = placeMediaInEdit(
      source: first.document,
      media: _unityMedia,
      editId: 'main',
      trackId: 'V1',
      atFrame: 100,
    );

    expect(first.clipId, 'shot');
    expect(second.clipId, 'shot_2');
  });

  test('crossfade overlap survives unrelated legal placement', () {
    const String source = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:a:video/a.mp4:0:0:80:1]
      [#EDIT_TRANSITION_OUT:CROSSFADE:24]
    [/CLIP]
    [CLIP:b:video/b.mp4:56:0:80:1]
      [#EDIT_TRANSITION:CROSSFADE:24]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

    final EditSurfaceDocument before = EditSurfaceDocument.parse(source, 'main');
    expect(appendFrameForTrack(before, 'V1'), 136);

    final MediaPlacementResult placed = placeMediaInEdit(
      source: source,
      media: _unityMedia,
      editId: 'main',
      trackId: 'V1',
      atFrame: 136,
    );

    expect(placed.document, contains('[#EDIT_TRANSITION_OUT:CROSSFADE:24]'));
    expect(placed.document, contains('[#EDIT_TRANSITION:CROSSFADE:24]'));
    expect(
      EditSurfaceDocument.parse(placed.document, 'main').clip('V1', 'shot').atFrame,
      136,
    );
  });

  test('append frame uses maximum clip end rather than document order', () {
    const String source = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:late:video/late.mp4:100:0:20:1]
    [/CLIP]
    [CLIP:early:video/early.mp4:0:0:10:1]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';
    final EditSurfaceDocument document = EditSurfaceDocument.parse(source, 'main');
    expect(appendFrameForTrack(document, 'V1'), 120);
  });

  test('CRLF and untouched regions remain byte-for-byte intact', () {
    const String source = 'HEADER\r\n[EDIT:main]\r\n[/EDIT]\r\nTAIL\r\n';

    final MediaPlacementResult placed = placeMediaInEdit(
      source: source,
      media: _unityMedia,
      editId: 'main',
      trackId: 'V1',
      atFrame: 0,
    );

    expect(placed.document.startsWith('HEADER\r\n[EDIT:main]\r\n'), isTrue);
    expect(placed.document.endsWith('[/EDIT]\r\nTAIL\r\n'), isTrue);
    expect(placed.document.replaceAll('\r\n', '').contains('\n'), isFalse);
  });

  test('EDIT id collision walk ignores the MOSAIC namespace', () {
    const String source = '''[EDIT:shot]
[/EDIT]
[MOSAIC:shot_2]
  [PANE:left]
    [CLIP:m:video/m.mp4:0:0:1:1]
    [/CLIP]
  [/PANE]
[/MOSAIC]
''';
    final EditDocumentModel model = EditDocumentModel.parse(source);
    expect(uniqueEditId(model, 'shot'), 'shot_2');
  });
}
