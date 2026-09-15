// ./test/edit_cue_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_cue.dart';
import 'package:r3nder/edit_model.dart';

void main() {
  test('clip-local CUE parses one canonical CARD through shared request parser',
      () {
    const String source = '''[EDIT:interview]
[TRACK:V1]
[CLIP:talk:video/interview.mp4:10:100:60:1]
before
[CUE:124]
[CARD:person.png:3:10,20,30:ALICE]
Bio line
[/CARD]
[/CUE]
after
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final EditClip clip =
        EditDocumentModel.parse(source).edit('interview').track('V1').clip('talk');
    final List<EditCardCue> cues = parseClipCardCues(clip);

    expect(cues, hasLength(1));
    final EditCardCue cue = cues.single;
    expect(cue.sourceFrame, 124);
    expect(cue.card.image, 'person.png');
    expect(cue.card.holdFrames, 3);
    expect(cue.card.panelColor.value, 0xFF0A141E);
    expect(cue.card.heading, 'ALICE');
    expect(cue.card.body, 'Bio line');
    expect(source.substring(cue.startOffset, cue.endOffset), cue.rawSource);
    expect(cue.rawSource, contains('[CARD:person.png:3:10,20,30:ALICE]'));
  });

  test('CUE-looking text inside opaque CARD body does not become another cue',
      () {
    const String source = '''[EDIT:interview]
[TRACK:V1]
[CLIP:talk:video/interview.mp4:0:0:120:1]
[CARD:standalone.png:5]
Literal [CUE:999] in ordinary card prose.
[/CARD]
[CUE:40]
[CARD:person.png:8]
Actual cued card.
[/CARD]
[/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final EditClip clip =
        EditDocumentModel.parse(source).edit('interview').track('V1').clip('talk');
    final List<EditCardCue> cues = parseClipCardCues(clip);

    expect(cues, hasLength(1));
    expect(cues.single.sourceFrame, 40);
    expect(cues.single.card.body, 'Actual cued card.');
  });

  test('cue source frame maps to project time with exact rational arithmetic',
      () {
    const String source = '''[EDIT:rates]
[TRACK:V1]
[CLIP:slow:video/slow.mp4:20:100:20:4/5]
[/CLIP]
[CLIP:fast:video/fast.mp4:50:200:10:3/2]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final EditDocumentModel model = EditDocumentModel.parse(source);
    final EditTrack track = model.edit('rates').track('V1');
    final EditClip slow = track.clip('slow');
    final EditClip fast = track.clip('fast');

    expect(cueProjectOffset(slow, 100), 0);
    expect(cueProjectFrame(slow, 100), 20);
    expect(cueProjectOffset(slow, 101), 2);
    expect(cueProjectFrame(slow, 101), 22);
    expect(cueProjectOffset(slow, 99), isNull);
    expect(cueProjectOffset(slow, 116), isNull);

    // 3/2 sampling walks 200, 201, 203... Source frame 202 is skipped as
    // a decoded sample, but the continuous source position crosses it at
    // project offset 2, so the cue still fires deterministically there.
    expect(fast.sourceFrameAtProjectOffset(2), 203);
    expect(cueProjectOffset(fast, 202), 2);
    expect(cueProjectFrame(fast, 202), 52);
    expect(cueProjectOffset(fast, 214), isNull);
  });

  test('multiple CUE blocks preserve authored order', () {
    const String source = '''[EDIT:interview]
[TRACK:V1]
[CLIP:talk:video/interview.mp4:0:0:300:1]
[CUE:20][CARD:a.png:1]A[/CARD][/CUE]
transition text remains somebody else's source
[CUE:200]
  [CARD:b.png:2]B[/CARD]
[/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final EditClip clip =
        EditDocumentModel.parse(source).edit('interview').track('V1').clip('talk');
    final List<EditCardCue> cues = parseClipCardCues(clip);

    expect(cues.map((EditCardCue cue) => cue.sourceFrame), <int>[20, 200]);
    expect(cues.map((EditCardCue cue) => cue.card.image), <String>['a.png', 'b.png']);
  });

  test('malformed CUE frame is rejected', () {
    const String source = '''[EDIT:interview]
[TRACK:V1]
[CLIP:talk:video/interview.mp4:0:0:100:1]
[CUE:nope][CARD:a.png:1]A[/CARD][/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final EditClip clip =
        EditDocumentModel.parse(source).edit('interview').track('V1').clip('talk');

    expect(
      () => parseClipCardCues(clip),
      throwsA(isA<EditCueFormatException>()),
    );
  });

  test('CUE v1 rejects non-CARD presentation content', () {
    const String source = '''[EDIT:interview]
[TRACK:V1]
[CLIP:talk:video/interview.mp4:0:0:100:1]
[CUE:10]
[TIMELINE:2]
2026 | Event
[/TIMELINE]
[/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final EditClip clip =
        EditDocumentModel.parse(source).edit('interview').track('V1').clip('talk');

    expect(
      () => parseClipCardCues(clip),
      throwsA(
        isA<EditCueFormatException>().having(
          (EditCueFormatException error) => error.message,
          'message',
          'CUE v1 supports CARD only.',
        ),
      ),
    );
  });

  test('CUE rejects extra authored content between CARD and close', () {
    const String source = '''[EDIT:interview]
[TRACK:V1]
[CLIP:talk:video/interview.mp4:0:0:100:1]
[CUE:10]
[CARD:a.png:1]A[/CARD]
extra
[/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final EditClip clip =
        EditDocumentModel.parse(source).edit('interview').track('V1').clip('talk');

    expect(
      () => parseClipCardCues(clip),
      throwsA(isA<EditCueFormatException>()),
    );
  });
}
