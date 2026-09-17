// ./test/edit_maximize_cue_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_cue.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/maximize_presentation.dart';

void main() {
  test('MAXIMIZE parses as shell cue without entering presentation union', () {
    const String source = '''[EDIT:interview]
[TRACK:V1]
[CLIP:talk:video/interview.mp4:0:0:300:1]
[CUE:40]
  [MAXIMIZE:180]
[/CUE]
[CUE:100]
  [CARD:person.png:10]Bio[/CARD]
[/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final EditClip clip =
        EditDocumentModel.parse(source).edit('interview').track('V1').clip('talk');

    final List<EditMaximizeCue> maximize = parseClipMaximizeCues(clip);
    final List<EditCardCue> cards = parseClipCardCues(clip);
    final List<EditDossierCue> dossiers = parseClipDossierCues(clip);

    expect(maximize, hasLength(1));
    expect(maximize.single.sourceFrame, 40);
    expect(maximize.single.holdFrames, 180);
    expect(maximize.single.rawSource, contains('[MAXIMIZE:180]'));
    expect(cards, hasLength(1));
    expect(cards.single.sourceFrame, 100);
    expect(dossiers, isEmpty);
  });

  test('MAXIMIZE trigger follows exact rational clip timing', () {
    const String source = '''[EDIT:interview]
[TRACK:V1]
[CLIP:talk:video/interview.mp4:20:100:60:4/5]
[CUE:124][MAXIMIZE:5][/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final EditSequence edit = EditDocumentModel.parse(source).edit('interview');
    final EditClip clip = edit.track('V1').clip('talk');
    final EditMaximizeCue cue = parseClipMaximizeCues(clip).single;

    expect(cueProjectFrame(clip, cue.sourceFrame), 50);
    expect(activeMaximizeCuesForEdit(edit, 49), isEmpty);

    final ActiveEditMaximizeCue first =
        activeMaximizeCuesForEdit(edit, 50).single;
    expect(first.triggerProjectFrame, 50);
    expect(first.localFrame, 0);
    expect(first.presentationFrame.stage, MaximizePresentationStage.entering);
    expect(first.presentationFrame.amount, 0.0);
  });

  test('malformed MAXIMIZE hold is rejected by the CUE parser', () {
    const String source = '''[EDIT:interview]
[TRACK:V1]
[CLIP:talk:video/interview.mp4:0:0:100:1]
[CUE:10][MAXIMIZE:nope][/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final EditClip clip =
        EditDocumentModel.parse(source).edit('interview').track('V1').clip('talk');

    expect(
      () => parseClipMaximizeCues(clip),
      throwsA(
        isA<EditCueFormatException>().having(
          (EditCueFormatException error) => error.message,
          'message',
          contains('MAXIMIZE requires'),
        ),
      ),
    );
  });
}
