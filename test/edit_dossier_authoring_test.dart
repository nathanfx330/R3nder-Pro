// ./test/edit_dossier_authoring_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_cue.dart';
import 'package:r3nder/edit_cue_authoring.dart';
import 'package:r3nder/edit_surface_model.dart';
import 'package:r3nder/presentation_requests.dart';

const String _source = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:test1_9:video/test1_9.mp4:0:0:300:4/5:GAIN=-15.0]
      [#EDIT_TRANSITION:CROSSFADE:12]
      opaque child text stays byte-for-byte
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

DossierRequest _dossier({
  String folder = 'evidence',
  String image = 'person.png',
  int split = 45,
  int full = 60,
  int lead = 12,
  DossierCenterMode mode = DossierCenterMode.mosaic,
  Color color = const Color(0xFF182028),
  String heading = 'JOHN SMITH',
  String body = 'Biography text.',
}) {
  return DossierRequest(
    folder: folder,
    image: image,
    holdSplit: split,
    holdFull: full,
    centerMode: mode,
    cardLead: lead,
    panelColor: color,
    heading: heading,
    body: body,
  );
}

void main() {
  test('add at playhead writes DOSSIER and exact 4/5 source trigger', () {
    final EditSurfaceDocument document =
        EditSurfaceDocument.parse(_source, 'main');

    final String next = addDossierCueAtProjectFrame(
      document: document,
      trackId: 'V1',
      clipId: 'test1_9',
      projectFrame: 113,
      dossier: _dossier(),
    );

    expect(next, contains('[CUE:90]'));
    expect(
      next,
      contains(
        '[DOSSIER:evidence:person.png:45:60:12:MOSAIC:24,32,40:JOHN SMITH]',
      ),
    );
    expect(next, contains('[/DOSSIER]'));
    expect(next, contains('[#EDIT_TRANSITION:CROSSFADE:12]'));
    expect(next, contains('GAIN=-15.0'));
    expect(next, contains('opaque child text stays byte-for-byte'));

    final EditDossierCue cue = parseClipDossierCues(
      EditSurfaceDocument.parse(next, 'main').clip('V1', 'test1_9').clip,
    ).single;
    expect(cue.sourceFrame, 90);
    expect(cue.dossier.folder, 'evidence');
    expect(cue.dossier.centerMode, DossierCenterMode.mosaic);
    expect(cue.dossier.body, 'Biography text.');
  });

  test('update preserves trigger while replacing authored DOSSIER facts', () {
    final String withCue = addDossierCueAtProjectFrame(
      document: EditSurfaceDocument.parse(_source, 'main'),
      trackId: 'V1',
      clipId: 'test1_9',
      projectFrame: 113,
      dossier: _dossier(),
    );

    final String next = updateDossierCue(
      document: EditSurfaceDocument.parse(withCue, 'main'),
      trackId: 'V1',
      clipId: 'test1_9',
      cueIndex: 0,
      dossier: _dossier(
        folder: 'documents',
        image: 'new.png',
        split: 20,
        full: 30,
        lead: 0,
        mode: DossierCenterMode.grid,
        heading: 'UPDATED',
        body: 'New body.',
      ),
    );

    expect(next, contains('[CUE:90]'));
    expect(
      next,
      contains(
        '[DOSSIER:documents:new.png:20:30:0:GRID:24,32,40:UPDATED]',
      ),
    );
    expect(next, isNot(contains('DOSSIER:evidence:')));

    final EditDossierCue cue = parseClipDossierCues(
      EditSurfaceDocument.parse(next, 'main').clip('V1', 'test1_9').clip,
    ).single;
    expect(cue.sourceFrame, 90);
    expect(cue.dossier.heading, 'UPDATED');
    expect(cue.dossier.body, 'New body.');
  });

  test('delete removes exactly one DOSSIER cue source span', () {
    final String withCue = addDossierCueAtProjectFrame(
      document: EditSurfaceDocument.parse(_source, 'main'),
      trackId: 'V1',
      clipId: 'test1_9',
      projectFrame: 113,
      dossier: _dossier(),
    );
    final EditSurfaceDocument current =
        EditSurfaceDocument.parse(withCue, 'main');
    final EditDossierCue cue =
        parseClipDossierCues(current.clip('V1', 'test1_9').clip).single;
    final String expected =
        withCue.replaceRange(cue.startOffset, cue.endOffset, '');

    final String next = deleteDossierCue(
      document: current,
      trackId: 'V1',
      clipId: 'test1_9',
      cueIndex: 0,
    );

    expect(next, expected);
    expect(next, contains('[#EDIT_TRANSITION:CROSSFADE:12]'));
    expect(next, contains('opaque child text stays byte-for-byte'));
  });

  test('split assigns CARD and DOSSIER cues to exactly one source half', () {
    String current = _source;
    current = addDossierCueAtProjectFrame(
      document: EditSurfaceDocument.parse(current, 'main'),
      trackId: 'V1',
      clipId: 'test1_9',
      projectFrame: 50,
      dossier: _dossier(heading: 'LEFT DOSSIER'),
    );
    current = addCardCueAtProjectFrame(
      document: EditSurfaceDocument.parse(current, 'main'),
      trackId: 'V1',
      clipId: 'test1_9',
      projectFrame: 200,
      card: CardRequest(
        image: 'right.png',
        holdFrames: 30,
        panelColor: const Color(0xFF1E1E26),
        heading: 'RIGHT CARD',
        body: 'Right body.',
      ),
    );

    final String split = splitClipWithCardCueOwnership(
      document: EditSurfaceDocument.parse(current, 'main'),
      trackId: 'V1',
      clipId: 'test1_9',
      projectFrame: 150,
    );
    final EditSurfaceDocument result = EditSurfaceDocument.parse(split, 'main');
    final List<EditSurfaceClip> clips =
        result.track('V1').clips.toList(growable: false)
          ..sort(
            (EditSurfaceClip a, EditSurfaceClip b) =>
                a.atFrame.compareTo(b.atFrame),
          );

    expect(clips, hasLength(2));
    final EditSurfaceClip left = clips[0];
    final EditSurfaceClip right = clips[1];

    expect(parseClipDossierCues(left.clip), hasLength(1));
    expect(parseClipCardCues(left.clip), isEmpty);
    expect(parseClipDossierCues(right.clip), isEmpty);
    expect(parseClipCardCues(right.clip), hasLength(1));

    expect(
      parseClipDossierCues(left.clip).single.dossier.heading,
      'LEFT DOSSIER',
    );
    expect(parseClipCardCues(right.clip).single.card.heading, 'RIGHT CARD');

    // Every authored cue exists exactly once after the split.
    expect(RegExp(r'\[CUE:').allMatches(split), hasLength(2));
  });
}
