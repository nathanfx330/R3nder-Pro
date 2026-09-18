// ./test/edit_cue_overlap_policy_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_cue.dart';
import 'package:r3nder/edit_cue_authoring.dart';
import 'package:r3nder/edit_cue_overlap.dart';
import 'package:r3nder/edit_surface_model.dart';
import 'package:r3nder/presentation_requests.dart';

const String _singleClip = '''[EDIT:main]
[TRACK:V1]
[CLIP:shot:video/shot.mp4:0:0:160:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';

CardRequest _card({
  String image = 'card.png',
  int hold = 8,
  String heading = 'CARD',
  bool side = false,
}) {
  if (side) {
    return SideCardRequest(
      image: image,
      holdFrames: hold,
      panelColor: const Color(0xFF182028),
      heading: heading,
      body: 'Body.',
    );
  }
  return CardRequest(
    image: image,
    holdFrames: hold,
    panelColor: const Color(0xFF182028),
    heading: heading,
    body: 'Body.',
  );
}

DossierRequest _dossier() {
  return DossierRequest(
    folder: 'evidence',
    image: 'person.png',
    holdSplit: 10,
    holdFull: 20,
    centerMode: DossierCenterMode.mosaic,
    cardLead: 0,
    panelColor: const Color(0xFF182028),
    heading: 'DOSSIER',
    body: 'Evidence.',
  );
}

void main() {
  test('occupied range uses source-derived start and project-native duration', () {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:shot:video/shot.mp4:0:0:100:4/5]
[/CLIP]
[/TRACK]
[/EDIT]
''';
    final EditSurfaceClip clip =
        EditSurfaceDocument.parse(source, 'main').clip('V1', 'shot');

    expect(
      cueOccupiedRange(clip.clip, 10, 4).toString(),
      '[13, 17)',
    );
  });

  test('abutting presentation ranges are accepted', () {
    String source = addCardCueAtProjectFrame(
      document: EditSurfaceDocument.parse(_singleClip, 'main'),
      trackId: 'V1',
      clipId: 'shot',
      projectFrame: 0,
      card: _card(image: 'a.png'),
    );

    source = addCardCueAtProjectFrame(
      document: EditSurfaceDocument.parse(source, 'main'),
      trackId: 'V1',
      clipId: 'shot',
      projectFrame: 40,
      card: _card(image: 'b.png'),
    );

    expect(RegExp(r'\[CUE:').allMatches(source), hasLength(2));
    expect(
      cueOverlapDiagnostics(EditSurfaceDocument.parse(source, 'main')),
      isEmpty,
    );
  });

  test('intersecting presentation range is rejected', () {
    final String source = addCardCueAtProjectFrame(
      document: EditSurfaceDocument.parse(_singleClip, 'main'),
      trackId: 'V1',
      clipId: 'shot',
      projectFrame: 0,
      card: _card(image: 'a.png'),
    );

    expect(
      () => addCardCueAtProjectFrame(
        document: EditSurfaceDocument.parse(source, 'main'),
        trackId: 'V1',
        clipId: 'shot',
        projectFrame: 39,
        card: _card(image: 'b.png'),
      ),
      throwsA(isA<EditCueAuthoringException>()),
    );
  });

  test('presentation collision scans every clip in the EDIT', () {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:a:video/a.mp4:0:0:120:1]
[CUE:0][CARD:a.png:8]A[/CARD][/CUE]
[/CLIP]
[/TRACK]
[TRACK:V2]
[CLIP:b:video/b.mp4:0:0:120:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    expect(
      () => addCardCueAtProjectFrame(
        document: EditSurfaceDocument.parse(source, 'main'),
        trackId: 'V2',
        clipId: 'b',
        projectFrame: 10,
        card: _card(side: true, image: 'side.png'),
      ),
      throwsA(isA<EditCueAuthoringException>()),
    );
  });

  test('CARD and MAXIMIZE may occupy identical frames on separate lanes', () {
    String source = addCardCueAtProjectFrame(
      document: EditSurfaceDocument.parse(_singleClip, 'main'),
      trackId: 'V1',
      clipId: 'shot',
      projectFrame: 0,
      card: _card(),
    );

    source = addMaximizeCueAtProjectFrame(
      document: EditSurfaceDocument.parse(source, 'main'),
      trackId: 'V1',
      clipId: 'shot',
      projectFrame: 0,
      holdFrames: 16,
    );

    expect(parseClipCardCues(
      EditSurfaceDocument.parse(source, 'main').clip('V1', 'shot').clip,
    ), hasLength(1));
    expect(parseClipMaximizeCues(
      EditSurfaceDocument.parse(source, 'main').clip('V1', 'shot').clip,
    ), hasLength(1));
    expect(
      cueOverlapDiagnostics(EditSurfaceDocument.parse(source, 'main')),
      isEmpty,
    );
  });

  test('CARD and DOSSIER block each other in the presentation lane', () {
    final String source = addCardCueAtProjectFrame(
      document: EditSurfaceDocument.parse(_singleClip, 'main'),
      trackId: 'V1',
      clipId: 'shot',
      projectFrame: 0,
      card: _card(),
    );

    expect(
      () => addDossierCueAtProjectFrame(
        document: EditSurfaceDocument.parse(source, 'main'),
        trackId: 'V1',
        clipId: 'shot',
        projectFrame: 10,
        dossier: _dossier(),
        dossierDurationFramesFor: (_) => 60,
      ),
      throwsA(isA<EditCueAuthoringException>()),
    );
  });

  test('duration edit excludes itself but cannot expand into a neighbor', () {
    String source = addCardCueAtProjectFrame(
      document: EditSurfaceDocument.parse(_singleClip, 'main'),
      trackId: 'V1',
      clipId: 'shot',
      projectFrame: 0,
      card: _card(image: 'a.png'),
    );
    source = addCardCueAtProjectFrame(
      document: EditSurfaceDocument.parse(source, 'main'),
      trackId: 'V1',
      clipId: 'shot',
      projectFrame: 40,
      card: _card(image: 'b.png'),
    );

    final String unchangedRange = updateCardCue(
      document: EditSurfaceDocument.parse(source, 'main'),
      trackId: 'V1',
      clipId: 'shot',
      cueIndex: 1,
      card: _card(image: 'b2.png'),
    );
    expect(unchangedRange, contains('b2.png'));

    expect(
      () => updateCardCue(
        document: EditSurfaceDocument.parse(source, 'main'),
        trackId: 'V1',
        clipId: 'shot',
        cueIndex: 0,
        card: _card(image: 'a.png', hold: 9),
      ),
      throwsA(isA<EditCueAuthoringException>()),
    );
  });

  test('cue outside current source window is inert and blocks nothing', () {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:shot:video/shot.mp4:0:0:100:1]
[CUE:200][CARD:old.png:90]OLD[/CARD][/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final String next = addCardCueAtProjectFrame(
      document: EditSurfaceDocument.parse(source, 'main'),
      trackId: 'V1',
      clipId: 'shot',
      projectFrame: 0,
      card: _card(),
    );
    expect(RegExp(r'\[CUE:').allMatches(next), hasLength(2));
  });

  test('DOSSIER diagnostics grow with injected resolved duration', () {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:shot:video/shot.mp4:0:0:160:1]
[CUE:0]
[DOSSIER:evidence:person.png:10:20:0:MOSAIC:24,32,40:PERSON]
Evidence.
[/DOSSIER]
[/CUE]
[CUE:70][CARD:card.png:0]Card.[/CARD][/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
''';
    final EditSurfaceDocument document =
        EditSurfaceDocument.parse(source, 'main');

    expect(
      cueOverlapDiagnostics(
        document,
        dossierDurationFramesFor: (_) => 60,
      ),
      isEmpty,
    );
    expect(
      cueOverlapDiagnostics(
        document,
        dossierDurationFramesFor: (_) => 80,
      ),
      hasLength(1),
    );
  });

  test('slip may round abutting CARD cues into overlap and diagnostics report it',
      () {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:shot:video/shot.mp4:0:0:100:4/5]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    String current = addCardCueAtProjectFrame(
      document: EditSurfaceDocument.parse(source, 'main'),
      trackId: 'V1',
      clipId: 'shot',
      projectFrame: 4,
      card: _card(image: 'a.png', hold: 0),
    );
    current = addCardCueAtProjectFrame(
      document: EditSurfaceDocument.parse(current, 'main'),
      trackId: 'V1',
      clipId: 'shot',
      projectFrame: 37,
      card: _card(image: 'b.png', hold: 0),
    );

    final EditSurfaceDocument before =
        EditSurfaceDocument.parse(current, 'main');
    expect(cueOverlapDiagnostics(before), isEmpty);

    // Clip geometry remains independent authoring. A one-frame slip changes
    // ceiling-rounded cue spacing from 33 frames to 32 and is deliberately
    // permitted rather than rejected by the cue policy.
    final String slippedSource = before.slipClip('V1', 'shot', 1);
    final EditSurfaceDocument slipped =
        EditSurfaceDocument.parse(slippedSource, 'main');

    expect(cueOverlapDiagnostics(slipped), hasLength(1));
  });
}
