// ./test/structural_sequence_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/script_pipeline.dart';
import 'package:r3nder/structural_sequence.dart';

void main() {
  const String source = '''Intro
[EDIT:main]
  [TRACK:V1]
    [CLIP:base:video/base.mp4:0:10:20:1]
    [/CLIP]
  [/TRACK]
[/EDIT]
[MOSAIC:wall]
  [PANE:pane1]
    [CLIP:base:EDIT.main:0:0:20:1]
    [/CLIP]
  [/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall]
Outro
''';

  test('STRUCT placement inherits duration from its structural source', () {
    final placements = parseStructuralSequencePlacements(source);
    expect(placements, hasLength(1));
    expect(placements.single.sourceRef.canonicalSource, 'MOSAIC.wall');
    expect(placements.single.durationFrames, 20);
    expect(placements.single.lineIndex, 13);
  });

  test('compile removes definitions and schedules STRUCT as source-length pause', () {
    final compiled = compileScript(source);

    expect(compiled.engineText, isNot(contains('[EDIT:main]')));
    expect(compiled.engineText, isNot(contains('[MOSAIC:wall]')));
    expect(compiled.engineText, isNot(contains('[STRUCT:MOSAIC.wall]')));
    expect(compiled.engineText, contains('[PAUSE:20]'));
    expect(compiled.engineText, contains('Intro'));
    expect(compiled.engineText, contains('Outro'));
  });

  test('editor line markers keep the placement on its authored line', () {
    final compiled = compileScript(source, lineMarkers: true);
    expect(compiled.engineText, contains('[LINE:13][PAUSE:20]'));
  });

  test('missing structural source burns one frame instead of typing markup', () {
    const String missing = '''Before
[STRUCT:MOSAIC.missing]
After
''';

    final placements = parseStructuralSequencePlacements(missing);
    expect(placements, hasLength(1));
    expect(placements.single.resolves, isFalse);

    final compiled = compileScript(missing);
    expect(compiled.engineText, isNot(contains('[STRUCT:')));
    expect(compiled.engineText, contains('[PAUSE:1]'));
  });
}
