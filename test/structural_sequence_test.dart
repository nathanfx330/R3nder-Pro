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

  test('STRUCT placement separates source hold from desktop event duration', () {
    final placements = parseStructuralSequencePlacements(source);
    expect(placements, hasLength(1));

    final placement = placements.single;
    expect(placement.sourceRef.canonicalSource, 'MOSAIC.wall');
    expect(placement.sourceDurationFrames, 20);
    expect(
      placement.durationFrames,
      kStructuralEntryFrames + 20 + kStructuralExitFrames,
    );
    expect(placement.durationFrames, 80);
    expect(placement.lineIndex, 13);
  });

  test('STRUCT stage map gives source its own uninterrupted showing span', () {
    final placement = parseStructuralSequencePlacements(source).single;

    expect(placement.stageAt(0), StructuralSequenceStage.zoomOut);
    expect(
      placement.stageAt(kStructuralZoomFrames),
      StructuralSequenceStage.opening,
    );
    expect(
      placement.stageAt(kStructuralEntryFrames),
      StructuralSequenceStage.showing,
    );
    expect(placement.sourceFrameAt(kStructuralEntryFrames), 0);
    expect(placement.sourceFrameAt(kStructuralEntryFrames + 5), 5);
    expect(
      placement.stageAt(kStructuralEntryFrames + 20),
      StructuralSequenceStage.closing,
    );
    expect(
      placement.stageAt(placement.durationFrames - 1),
      StructuralSequenceStage.zoomIn,
    );
  });

  test('preview and bake compile an internal runtime STRUCT marker', () {
    final compiled = compileScript(source);

    expect(compiled.engineText, isNot(contains('[EDIT:main]')));
    expect(compiled.engineText, isNot(contains('[MOSAIC:wall]')));
    expect(compiled.engineText, isNot(contains('[STRUCT:MOSAIC.wall]')));
    expect(
      compiled.engineText,
      contains(
        '[REGION:STRUCTSEQ_0_80]'
        '[PAUSE:${80 - kStructuralProjectionFramingFrames}]',
      ),
    );
    expect(compiled.engineText, contains('Intro'));
    expect(compiled.engineText, contains('Outro'));
  });

  test('editor line map keeps plain compensated STRUCT projection', () {
    final compiled = compileScript(source, lineMarkers: true);
    expect(compiled.engineText, isNot(contains('STRUCTSEQ_')));
    expect(
      compiled.engineText,
      contains(
        '[LINE:13][PAUSE:${80 - kStructuralProjectionFramingFrames}]',
      ),
    );
  });

  test('runtime marker round-trips placement index and duration', () {
    final StructuralRuntimeMarker marker = parseStructuralRuntimeRegion(
      'STRUCTSEQ_7_383',
    )!;

    expect(marker.placementIndex, 7);
    expect(marker.durationFrames, 383);
    expect(marker.regionId, 'STRUCTSEQ_7_383');
    expect(parseStructuralRuntimeRegion('ordinary_region'), isNull);
  });

  test('missing structural source burns fallback timing instead of markup', () {
    const String missing = '''Before
[STRUCT:MOSAIC.missing]
After
''';

    final placements = parseStructuralSequencePlacements(missing);
    expect(placements, hasLength(1));
    expect(placements.single.resolves, isFalse);
    expect(placements.single.sourceDurationFrames, 0);
    expect(placements.single.durationFrames, 0);

    final compiled = compileScript(missing);
    expect(compiled.engineText, isNot(contains('[STRUCT:')));
    expect(compiled.engineText, isNot(contains('STRUCTSEQ_')));
    expect(compiled.engineText, contains('[PAUSE:1]'));
  });
}
