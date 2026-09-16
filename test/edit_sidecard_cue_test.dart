// ./test/edit_sidecard_cue_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/card_overlay.dart';
import 'package:r3nder/edit_cue.dart';
import 'package:r3nder/edit_model.dart';

const String _source = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:shot:video/shot.mp4:0:0:300:1]
      [CUE:90]
        [SIDECARD:person.png:45:24,32,40:JOHN SMITH]
          Biography text.
        [/SIDECARD]
      [/CUE]
      [CUE:210]
        [CARD:overlay.png:10:30,30,38:FULL CARD]
          Fullscreen text.
        [/CARD]
      [/CUE]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

void main() {
  test('SIDECARD parses as a CARD-family cue without becoming ordinary CARD', () {
    final EditDocumentModel model = EditDocumentModel.parse(_source);
    final EditClip clip = model.edit('main').tracks.single.clips.single;
    final List<EditCardCue> cues = parseClipCardCues(clip);

    expect(cues, hasLength(2));

    final EditCardCue side = cues[0];
    expect(side.sourceFrame, 90);
    expect(side.isSideCard, isTrue);
    expect(side.card, isA<SideCardRequest>());
    expect(side.card.image, 'person.png');
    expect(side.card.holdFrames, 45);
    expect(side.card.panelColor, const Color.fromARGB(255, 24, 32, 40));
    expect(side.card.heading, 'JOHN SMITH');
    expect(side.card.body, 'Biography text.');
    expect(side.rawSource, contains('[SIDECARD:person.png:45:24,32,40:JOHN SMITH]'));

    final EditCardCue full = cues[1];
    expect(full.sourceFrame, 210);
    expect(full.isSideCard, isFalse);
    expect(full.card, isNot(isA<SideCardRequest>()));
    expect(full.card.body, 'Fullscreen text.');
  });

  test('SIDECARD uses the same deterministic CARD lifetime', () {
    final EditDocumentModel model = EditDocumentModel.parse(_source);
    final EditSequence edit = model.edit('main');

    final List<ActiveEditCardCue> atTrigger = activeCardCuesForEdit(edit, 90);
    expect(atTrigger, hasLength(1));
    expect(atTrigger.single.cue.isSideCard, isTrue);
    expect(atTrigger.single.localFrame, 0);

    // 16 opening + 45 hold + 16 closing = 77 visual frames.
    final List<ActiveEditCardCue> last = activeCardCuesForEdit(edit, 166);
    expect(last, hasLength(1));
    expect(last.single.cue.isSideCard, isTrue);
    expect(last.single.localFrame, 76);

    expect(activeCardCuesForEdit(edit, 167), isEmpty);
  });

  test('outer-shell selector keeps the final closing frame alive', () {
    final EditDocumentModel model = EditDocumentModel.parse(_source);
    const StructuralSourceRef root = StructuralSourceRef(
      StructuralSourceKind.edit,
      'main',
    );

    final StructuralCardOverlayPlacement? last =
        structuralSideCardPlacement(model, root, 166);
    expect(last, isNotNull);
    expect(last!.isSideCard, isTrue);
    expect(last.slide, closeTo(1 / 16, 0.000001));

    expect(structuralSideCardPlacement(model, root, 167), isNull);
  });

  test('SIDECARD source-relative trigger follows exact rational clip speed', () {
    const String rational = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:slow:video/slow.mp4:0:0:300:4/5]
      [CUE:90]
        [SIDECARD:person.png:45:24,32,40:JOHN SMITH]
          Biography text.
        [/SIDECARD]
      [/CUE]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';
    final EditClip clip = EditDocumentModel.parse(rational)
        .edit('main')
        .tracks
        .single
        .clips
        .single;

    expect(cueProjectFrame(clip, 90), 113);
  });
}
