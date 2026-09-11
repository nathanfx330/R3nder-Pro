// ./test/edit_clip_delete_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_surface_model.dart';

const String _source = '''PREFIX\n[EDIT:main]\n  [TRACK:V1]\n    [CLIP:first:video/first.mp4:10:0:20:1]\n      [#EDIT_TRANSITION_OUT:CROSSFADE:6]\n      [#UNKNOWN:FIRST:BODY]\n    [/CLIP]\n    [CLIP:middle:video/middle.mp4:40:5:20:1]\n      [#EDIT_TRANSITION:CROSSFADE:6]\n      [#UNKNOWN:MIDDLE:BODY]\n    [/CLIP]\n    [CLIP:last:video/last.mp4:80:9:10:1]\n      [#UNKNOWN:LAST:BODY]\n    [/CLIP]\n  [/TRACK]\n[/EDIT]\nSUFFIX\n''';

void main() {
  test('delete removes exactly the selected owned CLIP block', () {
    final EditSurfaceDocument document =
        EditSurfaceDocument.parse(_source, 'main');
    final EditSurfaceClip selected = document.clip('V1', 'middle');
    final int start = selected.clip.block.startOffset;
    final int end = selected.clip.block.endOffset;
    final String expected = _source.replaceRange(start, end, '');

    final String next = document.deleteClip('V1', 'middle');

    expect(next, expected);
    final EditSurfaceDocument reparsed =
        EditSurfaceDocument.parse(next, 'main');
    expect(
      reparsed.track('V1').clips.map((EditSurfaceClip clip) => clip.id),
      <String>['first', 'last'],
    );
    expect(next.startsWith('PREFIX\n'), isTrue);
    expect(next.endsWith('SUFFIX\n'), isTrue);
  });

  test('deleting first clip does not ripple or rewrite surviving neighbor', () {
    final EditSurfaceDocument document =
        EditSurfaceDocument.parse(_source, 'main');
    final String middleBlock = document.clip('V1', 'middle').clip.block.source;

    final String next = document.deleteClip('V1', 'first');
    final EditSurfaceDocument reparsed =
        EditSurfaceDocument.parse(next, 'main');
    final EditSurfaceClip middle = reparsed.clip('V1', 'middle');

    expect(middle.atFrame, 40);
    expect(middle.inFrame, 5);
    expect(
      middle.transition,
      const EditTransition.crossfade(6),
    );
    expect(middle.clip.block.source, middleBlock);
    expect(next, isNot(contains('[#UNKNOWN:FIRST:BODY]')));
    expect(next, contains('[#UNKNOWN:MIDDLE:BODY]'));
  });

  test('deleting last clip leaves earlier authored blocks byte identical', () {
    final EditSurfaceDocument document =
        EditSurfaceDocument.parse(_source, 'main');
    final String firstBlock = document.clip('V1', 'first').clip.block.source;
    final String middleBlock = document.clip('V1', 'middle').clip.block.source;

    final String next = document.deleteClip('V1', 'last');
    final EditSurfaceDocument reparsed =
        EditSurfaceDocument.parse(next, 'main');

    expect(reparsed.clip('V1', 'first').clip.block.source, firstBlock);
    expect(reparsed.clip('V1', 'middle').clip.block.source, middleBlock);
    expect(next, isNot(contains('[#UNKNOWN:LAST:BODY]')));
  });

  test('deleting a transition-bearing clip removes its complete body only', () {
    final EditSurfaceDocument document =
        EditSurfaceDocument.parse(_source, 'main');

    final String next = document.deleteClip('V1', 'middle');

    expect(next, isNot(contains('[#EDIT_TRANSITION:CROSSFADE:6]')));
    expect(next, contains('[#EDIT_TRANSITION_OUT:CROSSFADE:6]'));
    expect(next, contains('[#UNKNOWN:FIRST:BODY]'));
    expect(next, contains('[#UNKNOWN:LAST:BODY]'));
  });
}
