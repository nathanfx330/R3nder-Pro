// ./test/structural_sequence_definition_gap_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/script_pipeline.dart';
import 'package:r3nder/structural_sequence.dart';

const String _source = '''[CONFIG:APPSWITCH:SLIDE]
[EDIT:first]
[TRACK:V1]
[CLIP:first:video/a.mp4:0:0:20:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:first]
[PANE:pane1]
[CLIP:first_edit:EDIT.first:0:0:20:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.first]

[EDIT:second]
[TRACK:V1]
[CLIP:second:video/b.mp4:0:0:15:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:second]
[PANE:pane1]
[CLIP:second_edit:EDIT.second:0:0:15:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.second]
''';

void main() {
  test('SLIDE chains STRUCTs across intervening EDIT and MOSAIC definitions', () {
    final List<StructuralSequencePlacement> placements =
        parseStructuralSequencePlacements(_source);

    expect(placements, hasLength(2));
    final StructuralSequencePlacement first = placements[0];
    final StructuralSequencePlacement second = placements[1];

    expect(first.sourceRef.canonicalSource, 'MOSAIC.first');
    expect(second.sourceRef.canonicalSource, 'MOSAIC.second');

    expect(first.chainedToNext, isTrue);
    expect(second.chainedFromPrevious, isTrue);
    expect(first.seamlessToNext, isTrue);
    expect(second.seamlessFromPrevious, isTrue);

    expect(first.exitWindowFrames, 0);
    expect(first.exitZoomFrames, 0);
    expect(second.entryZoomFrames, 0);
    expect(second.entryWindowFrames, 0);

    expect(first.durationFrames, 50);
    expect(second.durationFrames, 45);
  });

  test('runtime projection has no terminal frame between definition-separated STRUCTs', () {
    final List<StructuralSequencePlacement> placements =
        parseStructuralSequencePlacements(_source);
    final compiled = compileScript(_source);

    final StructuralSequencePlacement first = placements[0];
    final StructuralSequencePlacement second = placements[1];
    final String firstRuntime =
        '[REGION:STRUCTSEQ_0_${first.durationFrames}]'
        '[PAUSE:${first.durationFrames - kStructuralProjectionFramingFrames}]';
    final String secondRuntime =
        '[REGION:STRUCTSEQ_1_${second.durationFrames}]'
        '[PAUSE:${second.durationFrames - kStructuralProjectionFramingFrames}]';

    expect(compiled.engineText, isNot(contains('[EDIT:second]')));
    expect(compiled.engineText, isNot(contains('[MOSAIC:second]')));
    expect(compiled.engineText, contains('$firstRuntime$secondRuntime'));
  });

  test('source definitions do not hide real terminal text in the gap', () {
    final String broken = _source.replaceFirst(
      '[MOSAIC:second]\n',
      'Back at terminal.\n[MOSAIC:second]\n',
    );

    final List<StructuralSequencePlacement> placements =
        parseStructuralSequencePlacements(broken);

    expect(placements, hasLength(2));
    expect(placements.first.chainedToNext, isFalse);
    expect(placements.last.chainedFromPrevious, isFalse);
    expect(placements.first.seamlessToNext, isFalse);
    expect(placements.last.seamlessFromPrevious, isFalse);
  });

  test('default switching also suppresses terminal zoom across source definitions', () {
    final String ordinary = _source.replaceFirst(
      '[CONFIG:APPSWITCH:SLIDE]\n',
      '',
    );
    final List<StructuralSequencePlacement> placements =
        parseStructuralSequencePlacements(ordinary);

    expect(placements, hasLength(2));
    expect(placements.first.chainedToNext, isTrue);
    expect(placements.last.chainedFromPrevious, isTrue);
    expect(placements.first.seamlessToNext, isFalse);
    expect(placements.last.seamlessFromPrevious, isFalse);

    expect(placements.first.exitZoomFrames, 0);
    expect(placements.last.entryZoomFrames, 0);
    expect(placements.first.exitWindowFrames, kStructuralWindowFrames);
    expect(placements.last.entryWindowFrames, kStructuralWindowFrames);
  });
}
