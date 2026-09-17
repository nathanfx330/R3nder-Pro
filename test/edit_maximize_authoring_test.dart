// ./test/edit_maximize_authoring_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_cue.dart';
import 'package:r3nder/edit_cue_authoring.dart';
import 'package:r3nder/edit_surface_model.dart';

const String _source = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:shot:video/shot.mp4:0:100:100:1]
      opaque child text stays byte-for-byte
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

void main() {
  test('add update and delete MAXIMIZE stay source-backed', () {
    final EditSurfaceDocument document =
        EditSurfaceDocument.parse(_source, 'main');

    final String added = addMaximizeCueAtProjectFrame(
      document: document,
      trackId: 'V1',
      clipId: 'shot',
      projectFrame: 20,
      holdFrames: 180,
    );
    expect(added, contains('[CUE:120]'));
    expect(added, contains('[MAXIMIZE:180]'));
    expect(added, contains('opaque child text stays byte-for-byte'));

    final EditSurfaceDocument withCue =
        EditSurfaceDocument.parse(added, 'main');
    final EditMaximizeCue before =
        parseClipMaximizeCues(withCue.clip('V1', 'shot').clip).single;
    expect(before.sourceFrame, 120);
    expect(before.holdFrames, 180);

    final String updated = updateMaximizeCue(
      document: withCue,
      trackId: 'V1',
      clipId: 'shot',
      cueIndex: 0,
      holdFrames: 0,
    );
    final EditSurfaceDocument afterUpdate =
        EditSurfaceDocument.parse(updated, 'main');
    final EditMaximizeCue after =
        parseClipMaximizeCues(afterUpdate.clip('V1', 'shot').clip).single;
    expect(after.sourceFrame, 120);
    expect(after.holdFrames, 0);
    expect(updated, contains('[MAXIMIZE:0]'));

    final String deleted = deleteMaximizeCue(
      document: afterUpdate,
      trackId: 'V1',
      clipId: 'shot',
      cueIndex: 0,
    );
    expect(
      parseClipMaximizeCues(
        EditSurfaceDocument.parse(deleted, 'main').clip('V1', 'shot').clip,
      ),
      isEmpty,
    );
    expect(deleted, contains('opaque child text stays byte-for-byte'));
  });

  test('split assigns MAXIMIZE to exactly the half containing its trigger', () {
    const String source = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:shot:video/shot.mp4:0:100:100:1]
      [CUE:120][MAXIMIZE:30][/CUE]
      [CUE:150][MAXIMIZE:60][/CUE]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';
    final EditSurfaceDocument document =
        EditSurfaceDocument.parse(source, 'main');

    final String next = splitClipWithCardCueOwnership(
      document: document,
      trackId: 'V1',
      clipId: 'shot',
      projectFrame: 50,
    );
    final EditSurfaceDocument split = EditSurfaceDocument.parse(next, 'main');
    final EditSurfaceTrack track = split.track('V1');
    final EditSurfaceClip left = track.clips.singleWhere(
      (EditSurfaceClip clip) => clip.id == 'shot',
    );
    final EditSurfaceClip right = track.clips.singleWhere(
      (EditSurfaceClip clip) => clip.id != 'shot',
    );

    expect(
      parseClipMaximizeCues(left.clip)
          .map((EditMaximizeCue cue) => cue.sourceFrame),
      <int>[120],
    );
    expect(
      parseClipMaximizeCues(right.clip)
          .map((EditMaximizeCue cue) => cue.sourceFrame),
      <int>[150],
    );
    expect(next.split('[CUE:120]').length - 1, 1);
    expect(next.split('[CUE:150]').length - 1, 1);
  });

  test('negative MAXIMIZE hold is rejected by authoring API', () {
    final EditSurfaceDocument document =
        EditSurfaceDocument.parse(_source, 'main');

    expect(
      () => addMaximizeCueAtProjectFrame(
        document: document,
        trackId: 'V1',
        clipId: 'shot',
        projectFrame: 20,
        holdFrames: -1,
      ),
      throwsArgumentError,
    );
  });
}
