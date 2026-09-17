// ./test/edit_clip_creation_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_media_import.dart';
import 'package:r3nder/edit_media_placement.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/edit_surface_model.dart';

void main() {
  test('first media placement creates EDIT main V1 and a real CLIP', () {
    const String original = '[TITLE:Opening]\nHello world\n';

    final MediaPlacementResult placed = placeMediaInEdit(
      source: original,
      media: const ImportedEditVideo(
        authoredSource: 'video/interview.mp4',
        resolvedPath: '/workspace/video/interview.mp4',
        clipBaseId: 'interview',
        durationFrames: 90,
        sourceLengthFrames: 90,
      ),
      editId: 'main',
      trackId: 'V1',
      atFrame: 0,
    );

    expect(placed.document.startsWith(original), isTrue);
    final EditSurfaceDocument document =
        EditSurfaceDocument.parse(placed.document, 'main');
    final EditSurfaceClip clip = document.clip('V1', 'interview');
    expect(clip.source, 'video/interview.mp4');
    expect(clip.atFrame, 0);
    expect(clip.inFrame, 0);
    expect(clip.durationFrames, 90);
    expect(clip.speed, ExactClipSpeed.unity);
  });

  test('adding overlay creates V2 without regenerating existing V1 source', () {
    const String source = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:base:video/base.mp4:0:0:120:1]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

    final EditSurfaceDocument document = EditSurfaceDocument.parse(source, 'main');
    final String next = document.addClip(
      trackId: 'V2',
      clipId: 'overlay',
      mediaSource: 'video/overlay.mp4',
      atFrame: 30,
      durationFrames: 60,
    );

    expect(
      next,
      contains('[CLIP:base:video/base.mp4:0:0:120:1]'),
    );
    final EditSurfaceDocument reparsed = EditSurfaceDocument.parse(next, 'main');
    expect(reparsed.clip('V1', 'base').durationFrames, 120);
    expect(reparsed.clip('V2', 'overlay').atFrame, 30);
    expect(reparsed.clip('V2', 'overlay').durationFrames, 60);
  });

  test('adding another video to V1 inserts at playhead and allocates unique id', () {
    const String source = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:shot:video/shot.mp4:0:0:30:1]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

    final EditSurfaceDocument document = EditSurfaceDocument.parse(source, 'main');
    final String id = document.nextClipId('V1', 'shot');
    expect(id, 'shot_2');

    final String next = document.addClip(
      trackId: 'V1',
      clipId: id,
      mediaSource: 'video/shot_2.mp4',
      atFrame: 45,
      durationFrames: 75,
    );

    final EditSurfaceDocument reparsed = EditSurfaceDocument.parse(next, 'main');
    expect(reparsed.track('V1').clips.map((clip) => clip.id), <String>['shot', 'shot_2']);
    expect(reparsed.clip('V1', 'shot_2').atFrame, 45);
    expect(reparsed.projectFrameCount, 120);
  });
}
