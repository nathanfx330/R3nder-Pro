// ./test/edit_model_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_model.dart';

const String _source = '''PREFIX BYTES
[EDIT:main]
  [TRACK:V1]
    [CLIP:intro:video/intro.mp4:0:24:90:1]
future effect bytes stay opaque
[/CLIP]
    [CLIP:broll:video/broll.mp4:120:0:60:0.5]
[/CLIP]
  [/TRACK]
  [TRACK:V2]
    [CLIP:overlay:video/overlay.mov:30:5:200:2]
opaque clip body
[/CLIP]
  [/TRACK]
[/EDIT]
SUFFIX BYTES
''';

void main() {
  test('EDIT TRACK CLIP geometry parses into authored project time', () {
    final EditDocumentModel document = EditDocumentModel.parse(_source);
    final EditSequence edit = document.edit('main');

    expect(edit.tracks.map((EditTrack track) => track.id), <String>['V1', 'V2']);

    final EditClip intro = edit.track('V1').clip('intro');
    expect(intro.source, 'video/intro.mp4');
    expect(intro.atFrame, 0);
    expect(intro.inFrame, 24);
    expect(intro.durationFrames, 90);
    expect(intro.speed, ExactClipSpeed(1));
    expect(intro.endFrameExclusive, 90);

    final EditClip overlay = edit.track('V2').clip('overlay');
    expect(overlay.endFrameExclusive, 230);

    // Project duration is the furthest authored clip end across all tracks.
    expect(edit.track('V1').projectFrameCount, 180);
    expect(edit.track('V2').projectFrameCount, 230);
    expect(edit.projectFrameCount, 230);
  });

  test('clip speed is exact rational source sampling, not project duration', () {
    final EditDocumentModel document = EditDocumentModel.parse(_source);
    final EditClip broll = document.edit('main').track('V1').clip('broll');
    final EditClip overlay = document.edit('main').track('V2').clip('overlay');

    expect(broll.speed, ExactClipSpeed(1, 2));
    expect(broll.sourceFrameAtProjectOffset(0), 0);
    expect(broll.sourceFrameAtProjectOffset(1), 0);
    expect(broll.sourceFrameAtProjectOffset(2), 1);
    expect(broll.sourceFrameAtProjectOffset(59), 29);

    expect(overlay.speed, ExactClipSpeed(2));
    expect(overlay.sourceFrameAtProjectOffset(0), 5);
    expect(overlay.sourceFrameAtProjectOffset(10), 25);

    // Speed never changes authored project length.
    expect(broll.durationFrames, 60);
    expect(overlay.durationFrames, 200);
  });

  test('media online and media offline produce identical dry-run frame count', () {
    final EditDocumentModel document = EditDocumentModel.parse(_source);

    final EditDryRun online = document.dryRun(
      'main',
      mediaExists: (String _) => true,
    );
    final EditDryRun offline = document.dryRun(
      'main',
      mediaExists: (String _) => false,
    );

    expect(online.frameCount, 230);
    expect(online.allMediaOnline, isTrue);

    expect(offline.frameCount, 230);
    expect(offline.allMediaOnline, isFalse);
    expect(
      offline.offlineSources,
      <String>[
        'video/intro.mp4',
        'video/broll.mp4',
        'video/overlay.mov',
      ],
    );
  });

  test('editing one CLIP field preserves enclosing and untouched source bytes', () {
    final EditDocumentModel document = EditDocumentModel.parse(_source);
    final EditClip broll = document.edit('main').track('V1').clip('broll');

    final String before = _source.substring(0, broll.block.startOffset);
    final String afterOpening = _source.substring(broll.block.openEndOffset);

    final String rewritten = document.rewriteClip(
      broll,
      durationFrames: 75,
    );

    expect(rewritten.startsWith(before), isTrue);
    expect(rewritten.endsWith(afterOpening), isTrue);
    expect(
      rewritten,
      contains('[CLIP:broll:video/broll.mp4:120:0:75:0.5]'),
    );

    // Reparse proves the changed source remains a valid structural document.
    final EditClip reparsed = EditDocumentModel.parse(rewritten)
        .edit('main')
        .track('V1')
        .clip('broll');
    expect(reparsed.durationFrames, 75);
    expect(reparsed.speed, ExactClipSpeed(1, 2));
  });

  test('CLIP has no canonical out field', () {
    const String withOut = '''[EDIT:main]
[TRACK:V1]
[CLIP:a:a.mp4:0:0:30:1:999]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    expect(
      () => EditDocumentModel.parse(withOut),
      throwsA(isA<EditLanguageFormatException>()),
    );
  });

  test('duplicate structural ids are rejected in their ownership scope', () {
    const String duplicate = '''[EDIT:main]
[TRACK:V1]
[CLIP:a:a.mp4:0:0:30:1]
[/CLIP]
[CLIP:a:b.mp4:30:0:30:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    expect(
      () => EditDocumentModel.parse(duplicate),
      throwsA(isA<EditLanguageFormatException>()),
    );
  });
}
