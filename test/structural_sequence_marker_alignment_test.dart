// ./test/structural_sequence_marker_alignment_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/script_pipeline.dart';
import 'package:r3nder/structural_sequence.dart';

void main() {
  test('malformed STRUCT does not consume a runtime placement index', () {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:base:video/base.mp4:0:0:8:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:pane1]
[CLIP:base:EDIT.main:0:0:8:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall:OVERLAY=BOGUS]
[STRUCT:MOSAIC.wall:FULL:OVERLAY=CUSTOM:TOP="CUSTOM [frame]"]
''';

    final List<StructuralSequencePlacement> placements =
        parseStructuralSequencePlacements(source);
    expect(placements, hasLength(1));
    expect(placements.single.fullscreen, isTrue);
    expect(placements.single.overlayMode.name, 'custom');
    expect(placements.single.topOverlay, 'CUSTOM [frame]');

    final CompiledScript compiled = compileScript(source);
    expect(
      compiled.engineText,
      contains('[STRUCT:MOSAIC.wall:OVERLAY=BOGUS]'),
      reason: 'Malformed author markup must remain visible for repair.',
    );
    expect(compiled.engineText, contains('[REGION:STRUCTSEQ_0_'));
    expect(compiled.engineText, isNot(contains('[REGION:STRUCTSEQ_1_')));
  });

  test('STRUCT-looking source metadata cannot shift executable chrome index', () {
    const String source = '''[EDIT:main]
[TRACK:V1]
[STRUCT:EDIT.main]
[CLIP:base:video/base.mp4:0:0:8:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:pane1]
[CLIP:base:EDIT.main:0:0:8:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall:FULL:OVERLAY=CUSTOM:TITLE="MONITOR":TOP="CUSTOM [frame]"]
''';

    final List<StructuralSequencePlacement> placements =
        parseStructuralSequencePlacements(source);
    expect(placements, hasLength(1));
    expect(placements.single.sourceRef.canonicalSource, 'MOSAIC.wall');
    expect(placements.single.overlayMode.name, 'custom');
    expect(placements.single.windowTitle, 'MONITOR');
    expect(placements.single.topOverlay, 'CUSTOM [frame]');

    final CompiledScript compiled = compileScript(source);
    expect(compiled.engineText, contains('[REGION:STRUCTSEQ_0_'));
    expect(compiled.engineText, isNot(contains('[REGION:STRUCTSEQ_1_')));
  });
}
