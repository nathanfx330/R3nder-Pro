// ./test/edit_sidecard_authoring_test.dart

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

SideCardRequest _side({
  String image = 'person.png',
  int hold = 90,
  Color color = const Color(0xFF182028),
  String heading = 'JOHN SMITH',
  String body = 'Biography text.',
}) {
  return SideCardRequest(
    image: image,
    holdFrames: hold,
    panelColor: color,
    heading: heading,
    body: body,
  );
}

CardRequest _full() {
  return CardRequest(
    image: 'overlay.png',
    holdFrames: 30,
    panelColor: const Color(0xFF1E1E26),
    heading: 'FULL',
    body: 'Fullscreen body.',
  );
}

void main() {
  test('add at playhead writes SIDECARD and exact 4/5 source trigger', () {
    final EditSurfaceDocument document =
        EditSurfaceDocument.parse(_source, 'main');

    final String next = addCardCueAtProjectFrame(
      document: document,
      trackId: 'V1',
      clipId: 'test1_9',
      projectFrame: 113,
      card: _side(),
    );

    expect(next, contains('[CUE:90]'));
    expect(next, contains('[SIDECARD:person.png:90:24,32,40:JOHN SMITH]'));
    expect(next, contains('[/SIDECARD]'));
    expect(next, isNot(contains('[CARD:person.png')));
    expect(next, contains('[#EDIT_TRANSITION:CROSSFADE:72]'));
    expect(next, contains('GAIN=-15.0'));
    expect(next, contains('opaque child text stays byte-for-byte'));

    final EditSurfaceDocument reparsed = EditSurfaceDocument.parse(next, 'main');
    final EditCardCue cue =
        parseClipCardCues(reparsed.clip('V1', 'test1_9').clip).single;
    expect(cue.sourceFrame, 90);
    expect(cue.isSideCard, isTrue);
    expect(cue.card.body, 'Biography text.');
  });

  test('update may switch SIDECARD to fullscreen CARD without moving trigger', () {
    final EditSurfaceDocument document =
        EditSurfaceDocument.parse(_source, 'main');
    final String withSide = addCardCueAtProjectFrame(
      document: document,
      trackId: 'V1',
      clipId: 'test1_9',
      projectFrame: 113,
      card: _side(),
    );

    final String next = updateCardCue(
      document: EditSurfaceDocument.parse(withSide, 'main'),
      trackId: 'V1',
      clipId: 'test1_9',
      cueIndex: 0,
      card: _full(),
    );

    expect(next, contains('[CUE:90]'));
    expect(next, contains('[CARD:overlay.png:30:30,30,38:FULL]'));
    expect(next, isNot(contains('[SIDECARD:')));

    final EditCardCue cue = parseClipCardCues(
      EditSurfaceDocument.parse(next, 'main').clip('V1', 'test1_9').clip,
    ).single;
    expect(cue.sourceFrame, 90);
    expect(cue.isSideCard, isFalse);
    expect(cue.card.body, 'Fullscreen body.');
  });

  test('update may switch fullscreen CARD to SIDECARD without moving trigger', () {
    final EditSurfaceDocument document =
        EditSurfaceDocument.parse(_source, 'main');
    final String withFull = addCardCueAtProjectFrame(
      document: document,
      trackId: 'V1',
      clipId: 'test1_9',
      projectFrame: 113,
      card: _full(),
    );

    final String next = updateCardCue(
      document: EditSurfaceDocument.parse(withFull, 'main'),
      trackId: 'V1',
      clipId: 'test1_9',
      cueIndex: 0,
      card: _side(heading: 'SIDE NOW'),
    );

    expect(next, contains('[CUE:90]'));
    expect(next, contains('[SIDECARD:person.png:90:24,32,40:SIDE NOW]'));
    expect(next, isNot(contains('[CARD:overlay.png')));

    final EditCardCue cue = parseClipCardCues(
      EditSurfaceDocument.parse(next, 'main').clip('V1', 'test1_9').clip,
    ).single;
    expect(cue.sourceFrame, 90);
    expect(cue.isSideCard, isTrue);
  });

  test('delete removes only SIDECARD cue source span', () {
    final EditSurfaceDocument document =
        EditSurfaceDocument.parse(_source, 'main');
    final String withCue = addCardCueAtProjectFrame(
      document: document,
      trackId: 'V1',
      clipId: 'test1_9',
      projectFrame: 113,
      card: _side(),
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
  });
}
