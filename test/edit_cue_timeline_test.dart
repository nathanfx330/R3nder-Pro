// ./test/edit_cue_timeline_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/card_presentation.dart';
import 'package:r3nder/edit_cue.dart';
import 'package:r3nder/edit_model.dart';

void main() {
  test('CARD cue continues across a later cut and stops at EDIT end', () {
    const String source = '''[EDIT:interview]
[TRACK:V1]
[CLIP:first:video/first.mp4:0:100:10:1]
[CUE:108][CARD:person.png:20]BIO[/CARD][/CUE]
[/CLIP]
[CLIP:second:video/second.mp4:10:0:10:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final EditSequence edit = EditDocumentModel.parse(source).edit('interview');

    expect(activeCardCuesForEdit(edit, 7), isEmpty);

    final ActiveEditCardCue trigger = activeCardCuesForEdit(edit, 8).single;
    expect(trigger.clip.id, 'first');
    expect(trigger.triggerProjectFrame, 8);
    expect(trigger.localFrame, 0);
    expect(trigger.presentationFrame.stage, CardPresentationStage.opening);
    expect(trigger.presentationFrame.slide, 0.0);

    // The anchor clip ended at frame 10, but the CARD presentation belongs to
    // structural time after firing, so it remains live over the next cut.
    final ActiveEditCardCue afterCut = activeCardCuesForEdit(edit, 15).single;
    expect(afterCut.clip.id, 'first');
    expect(afterCut.localFrame, 7);

    expect(activeCardCuesForEdit(edit, 19), hasLength(1));
    expect(activeCardCuesForEdit(edit, 20), isEmpty);
  });

  test('zero-hold CARD still owns its historical one seated frame', () {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:shot:video/a.mp4:0:0:80:1]
[CUE:0][CARD:person.png:0]BIO[/CARD][/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final EditSequence edit = EditDocumentModel.parse(source).edit('main');

    final ActiveEditCardCue lastOpening =
        activeCardCuesForEdit(edit, kCardSlideFrames - 1).single;
    expect(lastOpening.presentationFrame.stage, CardPresentationStage.opening);
    expect(lastOpening.presentationFrame.slide, 15 / 16);

    final ActiveEditCardCue seated =
        activeCardCuesForEdit(edit, kCardSlideFrames).single;
    expect(seated.presentationFrame.stage, CardPresentationStage.showing);
    expect(seated.presentationFrame.slide, 1.0);

    final int lastFrame =
        CardPresentationTiming(holdFrames: 0).durationFrames - 1;
    final ActiveEditCardCue closing =
        activeCardCuesForEdit(edit, lastFrame).single;
    expect(closing.presentationFrame.stage, CardPresentationStage.closing);
    expect(closing.presentationFrame.slide, 1 / 16);

    expect(activeCardCuesForEdit(edit, lastFrame + 1), isEmpty);
  });

  test('cue outside current source window never becomes active', () {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:shot:video/a.mp4:0:100:10:1]
[CUE:120][CARD:person.png:20]BIO[/CARD][/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final EditSequence edit = EditDocumentModel.parse(source).edit('main');
    for (int frame = 0; frame < edit.projectFrameCount; frame++) {
      expect(activeCardCuesForEdit(edit, frame), isEmpty);
    }
  });

  test('legacy overlapping CARD cues remain deterministic at runtime', () {
    // GUI authoring rejects new presentation-lane overlap, but parser/runtime
    // tolerance remains deliberate for hand-authored and historical source.
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:a:video/a.mp4:0:0:80:1]
[CUE:0][CARD:a.png:20]A[/CARD][/CUE]
[/CLIP]
[/TRACK]
[TRACK:V2]
[CLIP:b:video/b.mp4:0:0:80:1]
[CUE:0][CARD:b.png:20]B[/CARD][/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final EditSequence edit = EditDocumentModel.parse(source).edit('main');
    final List<ActiveEditCardCue> active = activeCardCuesForEdit(edit, 20);

    expect(active, hasLength(2));
    expect(
      active.map((ActiveEditCardCue item) => item.cue.card.image),
      <String>['a.png', 'b.png'],
    );
  });

  test('MOSAIC pane is the cue lifetime boundary', () {
    const String source = '''[MOSAIC:wall]
[PANE:left]
[CLIP:first:video/first.mp4:0:0:10:1]
[CUE:8][CARD:person.png:20]BIO[/CARD][/CUE]
[/CLIP]
[CLIP:second:video/second.mp4:10:0:10:1]
[/CLIP]
[/PANE]
[/MOSAIC]
''';

    final MosaicPane pane = EditDocumentModel.parse(source).mosaic('wall').pane('left');

    expect(activeCardCuesForPane(pane, 7), isEmpty);
    expect(activeCardCuesForPane(pane, 8), hasLength(1));
    expect(activeCardCuesForPane(pane, 15), hasLength(1));
    expect(activeCardCuesForPane(pane, 19), hasLength(1));
    expect(activeCardCuesForPane(pane, 20), isEmpty);
  });
}
