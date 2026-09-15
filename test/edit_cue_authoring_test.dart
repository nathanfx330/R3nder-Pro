// ./test/edit_cue_authoring_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_cue.dart';
import 'package:r3nder/edit_cue_authoring.dart';
import 'package:r3nder/edit_surface_model.dart';
import 'package:r3nder/presentation_requests.dart';

const String _source = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:test1_9:video/test1_9.mp4:0:0:13925:4/5:GAIN=-15.0]
      [#EDIT_TRANSITION:CROSSFADE:72]
      opaque child text stays byte-for-byte
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

CardRequest _card({
  String image = 'person.png',
  int hold = 90,
  Color color = const Color(0xFF182028),
  String heading = 'JOHN SMITH',
  String body = 'Biography text.',
}) {
  return CardRequest(
    image: image,
    holdFrames: hold,
    panelColor: color,
    heading: heading,
    body: body,
  );
}

void main() {
  test('add at playhead writes exact source-relative trigger on 4/5 clip', () {
    final EditSurfaceDocument document =
        EditSurfaceDocument.parse(_source, 'main');
    final EditSurfaceClip clip = document.clip('V1', 'test1_9');

    expect(cardCueSourceFrameAtProjectFrame(clip, 113), 90);

    final String next = addCardCueAtProjectFrame(
      document: document,
      trackId: 'V1',
      clipId: 'test1_9',
      projectFrame: 113,
      card: _card(),
    );

    expect(
      next,
      contains('[CLIP:test1_9:video/test1_9.mp4:0:0:13925:4/5:GAIN=-15.0]'),
    );
    expect(next, contains('[#EDIT_TRANSITION:CROSSFADE:72]'));
    expect(next, contains('opaque child text stays byte-for-byte'));
    expect(next, contains('[CUE:90]'));
    expect(next, contains('[CARD:person.png:90:24,32,40:JOHN SMITH]'));

    final EditSurfaceDocument reparsed = EditSurfaceDocument.parse(next, 'main');
    final List<EditCardCue> cues =
        parseClipCardCues(reparsed.clip('V1', 'test1_9').clip);
    expect(cues, hasLength(1));
    expect(cues.single.sourceFrame, 90);
    expect(cues.single.card.body, 'Biography text.');
  });

  test('update rewrites only cue span and keeps trigger', () {
    final EditSurfaceDocument document =
        EditSurfaceDocument.parse(_source, 'main');
    final String withCue = addCardCueAtProjectFrame(
      document: document,
      trackId: 'V1',
      clipId: 'test1_9',
      projectFrame: 113,
      card: _card(),
    );
    final EditSurfaceDocument current =
        EditSurfaceDocument.parse(withCue, 'main');
    final EditCardCue before =
        parseClipCardCues(current.clip('V1', 'test1_9').clip).single;
    final String prefix = withCue.substring(0, before.startOffset);
    final String suffix = withCue.substring(before.endOffset);

    final String next = updateCardCue(
      document: current,
      trackId: 'V1',
      clipId: 'test1_9',
      cueIndex: 0,
      card: _card(
        image: 'updated.png',
        hold: 45,
        color: const Color(0xFF010203),
        heading: 'UPDATED',
        body: 'Changed body.',
      ),
    );

    final EditSurfaceDocument reparsed = EditSurfaceDocument.parse(next, 'main');
    final EditCardCue after =
        parseClipCardCues(reparsed.clip('V1', 'test1_9').clip).single;

    expect(after.sourceFrame, 90);
    expect(after.card.image, 'updated.png');
    expect(after.card.holdFrames, 45);
    expect(after.card.heading, 'UPDATED');
    expect(after.card.body, 'Changed body.');
    expect(next.substring(0, after.startOffset), prefix);
    expect(next.substring(after.endOffset), suffix);
  });

  test('delete removes only the authored cue span', () {
    final EditSurfaceDocument document =
        EditSurfaceDocument.parse(_source, 'main');
    final String withCue = addCardCueAtProjectFrame(
      document: document,
      trackId: 'V1',
      clipId: 'test1_9',
      projectFrame: 113,
      card: _card(),
    );
    final EditSurfaceDocument current =
        EditSurfaceDocument.parse(withCue, 'main');
    final EditCardCue cue =
        parseClipCardCues(current.clip('V1', 'test1_9').clip).single;
    final String expected = withCue.replaceRange(cue.startOffset, cue.endOffset, '');

    final String next = deleteCardCue(
      document: current,
      trackId: 'V1',
      clipId: 'test1_9',
      cueIndex: 0,
    );

    expect(next, expected);
    expect(next, contains('[#EDIT_TRANSITION:CROSSFADE:72]'));
    expect(next, contains('GAIN=-15.0'));
    expect(next, contains('opaque child text stays byte-for-byte'));
    expect(parseClipCardCues(
      EditSurfaceDocument.parse(next, 'main').clip('V1', 'test1_9').clip,
    ), isEmpty);
  });

  test('split assigns cue to exactly one half and exact split goes right', () {
    const String source = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:shot:video/shot.mp4:0:100:100:1]
      [CUE:120]
        [CARD:left.png:10:30,30,38:LEFT]
        Left cue.
        [/CARD]
      [/CUE]
      [CUE:150]
        [CARD:right.png:10:30,30,38:RIGHT]
        Right cue.
        [/CARD]
      [/CUE]
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
    expect(track.clips, hasLength(2));

    final EditSurfaceClip left = track.clip('shot');
    final EditSurfaceClip right = track.clips.singleWhere(
      (EditSurfaceClip clip) => clip.id != 'shot',
    );
    final List<EditCardCue> leftCues = parseClipCardCues(left.clip);
    final List<EditCardCue> rightCues = parseClipCardCues(right.clip);

    expect(leftCues.map((EditCardCue cue) => cue.sourceFrame), <int>[120]);
    expect(rightCues.map((EditCardCue cue) => cue.sourceFrame), <int>[150]);
    expect(next.split('[CUE:120]').length - 1, 1);
    expect(next.split('[CUE:150]').length - 1, 1);
  });

  test('playhead outside selected clip cannot author a cue', () {
    final EditSurfaceDocument document =
        EditSurfaceDocument.parse(_source, 'main');
    final EditSurfaceClip clip = document.clip('V1', 'test1_9');

    expect(
      () => cardCueSourceFrameAtProjectFrame(clip, clip.endFrameExclusive),
      throwsArgumentError,
    );
  });
}
