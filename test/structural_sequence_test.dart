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

  const String adjacent = '''[EDIT:main]
[TRACK:V1]
[CLIP:base:video/base.mp4:0:0:20:1]
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
[STRUCT:MOSAIC.wall]
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
    expect(placement.presentationMode, StructuralPresentationMode.windowed);
    expect(placement.chainedFromPrevious, isFalse);
    expect(placement.chainedToNext, isFalse);
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

  test('FULL is a STRUCT placement fact, not a MOSAIC source fact', () {
    final String full = adjacent.replaceFirst(
      '[STRUCT:MOSAIC.wall]',
      '[STRUCT:MOSAIC.wall:FULL]',
    );
    final placements = parseStructuralSequencePlacements(full);

    expect(placements, hasLength(2));
    expect(placements.first.fullscreen, isTrue);
    expect(
      placements.first.presentationMode,
      StructuralPresentationMode.fullscreen,
    );
    expect(placements.last.fullscreen, isFalse);
  });

  test('adjacent STRUCTs close and reopen on desktop without terminal zoom', () {
    final placements = parseStructuralSequencePlacements(adjacent);
    expect(placements, hasLength(2));

    final first = placements[0];
    final second = placements[1];

    expect(first.chainedFromPrevious, isFalse);
    expect(first.chainedToNext, isTrue);
    expect(first.seamlessToNext, isFalse);
    expect(first.entryZoomFrames, kStructuralZoomFrames);
    expect(first.entryWindowFrames, kStructuralWindowFrames);
    expect(first.exitWindowFrames, kStructuralWindowFrames);
    expect(first.exitZoomFrames, 0);
    expect(first.durationFrames, 62);
    expect(
      first.stageAt(first.durationFrames - 1),
      StructuralSequenceStage.closing,
    );

    expect(second.chainedFromPrevious, isTrue);
    expect(second.chainedToNext, isFalse);
    expect(second.seamlessFromPrevious, isFalse);
    expect(second.entryZoomFrames, 0);
    expect(second.entryWindowFrames, kStructuralWindowFrames);
    expect(second.contentStartFrame, kStructuralWindowFrames);
    expect(second.exitWindowFrames, kStructuralWindowFrames);
    expect(second.exitZoomFrames, kStructuralZoomFrames);
    expect(second.durationFrames, 62);
    expect(second.stageAt(0), StructuralSequenceStage.opening);
  });

  test('APPSWITCH SLIDE makes adjacent same-mode STRUCTs seamless', () {
    final String slide = '[CONFIG:APPSWITCH:SLIDE]\n$adjacent';
    final placements = parseStructuralSequencePlacements(slide);
    expect(placements, hasLength(2));

    final first = placements[0];
    final second = placements[1];

    expect(first.seamlessToNext, isTrue);
    expect(first.exitWindowFrames, 0);
    expect(first.exitZoomFrames, 0);
    expect(first.durationFrames, 50);
    expect(
      first.stageAt(first.durationFrames - 1),
      StructuralSequenceStage.showing,
    );

    expect(second.seamlessFromPrevious, isTrue);
    expect(second.previousPresentationMode,
        StructuralPresentationMode.windowed);
    expect(second.entryZoomFrames, 0);
    expect(second.entryWindowFrames, 0);
    expect(second.contentStartFrame, 0);
    expect(second.durationFrames, 50);
    expect(second.stageAt(0), StructuralSequenceStage.showing);
    expect(second.sourceFrameAt(0), 0);
  });

  test('seamless window to fullscreen gives incoming STRUCT a morph budget', () {
    final String mixed = '''[CONFIG:APPSWITCH:SLIDE]
[EDIT:main]
[TRACK:V1]
[CLIP:base:video/base.mp4:0:0:20:1]
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
[STRUCT:MOSAIC.wall:FULL]
''';

    final placements = parseStructuralSequencePlacements(mixed);
    expect(placements, hasLength(2));

    final first = placements[0];
    final second = placements[1];

    expect(first.seamlessToNext, isTrue);
    expect(first.durationFrames, 50);

    expect(second.seamlessFromPrevious, isTrue);
    expect(second.fullscreen, isTrue);
    expect(second.previousPresentationMode,
        StructuralPresentationMode.windowed);
    expect(second.entryZoomFrames, 0);
    expect(second.entryWindowFrames, kStructuralWindowFrames);
    expect(second.contentStartFrame, kStructuralWindowFrames);
    expect(second.stageAt(0), StructuralSequenceStage.opening);
    expect(second.durationFrames, 62);
  });

  test('comment and CONFIG-only gap does not break structural app chaining', () {
    final String chained = adjacent.replaceFirst(
      '[STRUCT:MOSAIC.wall]\n[STRUCT:MOSAIC.wall]',
      '[STRUCT:MOSAIC.wall]\n'
          '[# an invisible note]\n'
          '[CONFIG:FG:0,255,0]\n'
          '[STRUCT:MOSAIC.wall]',
    );

    final placements = parseStructuralSequencePlacements(chained);
    expect(placements, hasLength(2));
    expect(placements.first.chainedToNext, isTrue);
    expect(placements.last.chainedFromPrevious, isTrue);
  });

  test('real TEXT between STRUCTs breaks the application chain', () {
    final String broken = adjacent.replaceFirst(
      '[STRUCT:MOSAIC.wall]\n[STRUCT:MOSAIC.wall]',
      '[STRUCT:MOSAIC.wall]\nBack at terminal.\n[STRUCT:MOSAIC.wall]',
    );

    final placements = parseStructuralSequencePlacements(broken);
    expect(placements, hasLength(2));
    expect(placements.first.chainedToNext, isFalse);
    expect(placements.last.chainedFromPrevious, isFalse);
    expect(placements.first.durationFrames, 80);
    expect(placements.last.durationFrames, 80);
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

  test('runtime projection uses planned durations for adjacent STRUCT apps', () {
    final compiled = compileScript(adjacent);

    expect(
      compiled.engineText,
      contains(
        '[REGION:STRUCTSEQ_0_62]'
        '[PAUSE:${62 - kStructuralProjectionFramingFrames}]',
      ),
    );
    expect(
      compiled.engineText,
      contains(
        '[REGION:STRUCTSEQ_1_62]'
        '[PAUSE:${62 - kStructuralProjectionFramingFrames}]',
      ),
    );
  });

  test('runtime projection accepts FULL without leaking authored markup', () {
    final String full = source.replaceFirst(
      '[STRUCT:MOSAIC.wall]',
      '[STRUCT:MOSAIC.wall:FULL]',
    );
    final compiled = compileScript(full);

    expect(compiled.engineText, isNot(contains('[STRUCT:MOSAIC.wall:FULL]')));
    expect(compiled.engineText, contains('[REGION:STRUCTSEQ_0_80]'));
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
