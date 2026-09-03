// ./test/edit_surface_model_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/edit_surface_model.dart';

const String _source = '''PREFIX\n[EDIT:main]\n  [TRACK:V1]\n    [CLIP:intro:video/intro.mp4:10:20:40:1]\n      [#EDIT_TRANSITION:CROSSFADE:8]\n    [/CLIP]\n    [CLIP:broll:video/broll.mp4:60:100:30:0.5]\n    [/CLIP]\n  [/TRACK]\n  [TRACK:V2]\n    [CLIP:overlay:video/overlay.mp4:15:5:50:2]\n    [/CLIP]\n  [/TRACK]\n[/EDIT]\nSUFFIX\n''';

void main() {
  test('surface model reads V1 V2 clips and transition metadata', () {
    final EditSurfaceDocument doc = EditSurfaceDocument.parse(_source, 'main');

    expect(doc.projectFrameCount, 90);
    expect(doc.tracks.map((EditSurfaceTrack track) => track.id), <String>['V1', 'V2']);
    expect(doc.track('V1').clips.length, 2);
    expect(doc.clip('V1', 'intro').transition, const EditTransition.crossfade(8));
    expect(doc.clip('V1', 'broll').speed, ExactClipSpeed.parse('0.5'));
  });

  test('move rewrites only the selected CLIP opening tag field', () {
    final EditSurfaceDocument doc = EditSurfaceDocument.parse(_source, 'main');
    final String next = doc.moveClip('V1', 'broll', 72);

    expect(next.startsWith('PREFIX\n[EDIT:main]\n'), isTrue);
    expect(next.endsWith('[/EDIT]\nSUFFIX\n'), isTrue);
    expect(
      next,
      contains('[CLIP:broll:video/broll.mp4:72:100:30:0.5]'),
    );
    expect(
      next,
      contains('[CLIP:intro:video/intro.mp4:10:20:40:1]'),
    );
  });

  test('trim start preserves sampled source position at exact clip speed', () {
    final EditSurfaceDocument doc = EditSurfaceDocument.parse(_source, 'main');
    final String next = doc.trimStart('V1', 'broll', 65);
    final EditSurfaceDocument reparsed = EditSurfaceDocument.parse(next, 'main');
    final EditSurfaceClip clip = reparsed.clip('V1', 'broll');

    expect(clip.atFrame, 65);
    expect(clip.inFrame, 102);
    expect(clip.durationFrames, 25);
    expect(clip.endFrameExclusive, 90);
  });

  test('trim start can extend left when source frames remain available', () {
    final EditSurfaceDocument doc = EditSurfaceDocument.parse(_source, 'main');
    final String next = doc.trimStart('V1', 'broll', 56);
    final EditSurfaceClip clip =
        EditSurfaceDocument.parse(next, 'main').clip('V1', 'broll');

    expect(clip.atFrame, 56);
    expect(clip.inFrame, 98);
    expect(clip.durationFrames, 34);
  });

  test('trim end and slip preserve project placement independently', () {
    final EditSurfaceDocument doc = EditSurfaceDocument.parse(_source, 'main');
    final String trimmed = doc.trimEnd('V2', 'overlay', 50);
    final EditSurfaceDocument afterTrim =
        EditSurfaceDocument.parse(trimmed, 'main');
    final EditSurfaceClip trimClip = afterTrim.clip('V2', 'overlay');

    expect(trimClip.atFrame, 15);
    expect(trimClip.inFrame, 5);
    expect(trimClip.durationFrames, 35);

    final String slipped = afterTrim.slipClip('V2', 'overlay', 11);
    final EditSurfaceClip slipClip =
        EditSurfaceDocument.parse(slipped, 'main').clip('V2', 'overlay');
    expect(slipClip.atFrame, 15);
    expect(slipClip.inFrame, 16);
    expect(slipClip.durationFrames, 35);
  });

  test('speed edit changes source mapping without changing project duration', () {
    final EditSurfaceDocument doc = EditSurfaceDocument.parse(_source, 'main');
    final String next =
        doc.setSpeed('V1', 'intro', ExactClipSpeed.parse('5/4'));
    final EditSurfaceClip clip =
        EditSurfaceDocument.parse(next, 'main').clip('V1', 'intro');

    expect(clip.speed, ExactClipSpeed.parse('5/4'));
    expect(clip.atFrame, 10);
    expect(clip.durationFrames, 40);
    expect(clip.endFrameExclusive, 50);
  });

  test('split produces two authored CLIPs with exact right source in', () {
    final EditSurfaceDocument doc = EditSurfaceDocument.parse(_source, 'main');
    final String next = doc.splitClip('V1', 'broll', 71);
    final EditSurfaceDocument reparsed = EditSurfaceDocument.parse(next, 'main');
    final EditSurfaceTrack track = reparsed.track('V1');

    expect(track.clips.map((EditSurfaceClip clip) => clip.id),
        <String>['intro', 'broll', 'broll_2']);

    final EditSurfaceClip left = reparsed.clip('V1', 'broll');
    final EditSurfaceClip right = reparsed.clip('V1', 'broll_2');

    expect(left.atFrame, 60);
    expect(left.durationFrames, 11);
    expect(left.inFrame, 100);
    expect(right.atFrame, 71);
    expect(right.durationFrames, 19);
    expect(right.inFrame, 105);
    expect(right.speed, ExactClipSpeed.parse('1/2'));
    expect(right.transition, const EditTransition.none());
  });

  test('split keeps incoming transition only on the original left segment', () {
    final EditSurfaceDocument doc = EditSurfaceDocument.parse(_source, 'main');
    final String next = doc.splitClip('V1', 'intro', 30);
    final EditSurfaceDocument reparsed = EditSurfaceDocument.parse(next, 'main');

    expect(
      reparsed.clip('V1', 'intro').transition,
      const EditTransition.crossfade(8),
    );
    expect(
      reparsed.clip('V1', 'intro_2').transition,
      const EditTransition.none(),
    );
  });

  test('crossfade and luma transitions serialize as script comments', () {
    final EditSurfaceDocument doc = EditSurfaceDocument.parse(_source, 'main');
    final String crossfade = doc.setTransition(
      'V1',
      'broll',
      const EditTransition.crossfade(12),
    );
    final EditSurfaceDocument afterCrossfade =
        EditSurfaceDocument.parse(crossfade, 'main');
    expect(
      afterCrossfade.clip('V1', 'broll').transition,
      const EditTransition.crossfade(12),
    );
    expect(crossfade, contains('[#EDIT_TRANSITION:CROSSFADE:12]'));

    final String luma = afterCrossfade.setTransition(
      'V1',
      'broll',
      const EditTransition.luma('wipes/soft.png', 10),
    );
    final EditSurfaceDocument afterLuma =
        EditSurfaceDocument.parse(luma, 'main');
    expect(
      afterLuma.clip('V1', 'broll').transition,
      const EditTransition.luma('wipes/soft.png', 10),
    );
    expect(luma, isNot(contains('[#EDIT_TRANSITION:CROSSFADE:12]')));
  });

  test('transition can be cleared without touching clip geometry', () {
    final EditSurfaceDocument doc = EditSurfaceDocument.parse(_source, 'main');
    final String next = doc.setTransition(
      'V1',
      'intro',
      const EditTransition.none(),
    );
    final EditSurfaceClip clip =
        EditSurfaceDocument.parse(next, 'main').clip('V1', 'intro');

    expect(clip.transition, const EditTransition.none());
    expect(clip.atFrame, 10);
    expect(clip.inFrame, 20);
    expect(clip.durationFrames, 40);
    expect(next, isNot(contains('[#EDIT_TRANSITION:CROSSFADE:8]')));
  });
}
