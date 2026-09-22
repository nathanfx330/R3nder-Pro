// ./test/structural_split_transition_plan_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/structural_sequence.dart';

const String _roots = '''[EDIT:a]
[TRACK:V1]
[CLIP:a:video/a.mp4:0:0:12:1]
[/CLIP]
[/TRACK]
[/EDIT]
[EDIT:b]
[TRACK:V1]
[CLIP:b:video/b.mp4:0:0:12:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:left]
[PANE:p1]
[CLIP:a1:EDIT.a:0:0:12:1]
[/CLIP]
[/PANE]
[PANE:p2]
[CLIP:a2:EDIT.b:0:0:12:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[MOSAIC:right]
[PANE:p1]
[CLIP:b1:EDIT.b:0:0:12:1]
[/CLIP]
[/PANE]
[PANE:p2]
[CLIP:b2:EDIT.a:0:0:12:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[MOSAIC:unsupported]
[PANE:p1]
[CLIP:u1:EDIT.a:0:0:12:1]
[/CLIP]
[/PANE]
[/MOSAIC]
''';

List<StructuralSequencePlacement> _placements(String sequence) {
  return parseStructuralSequencePlacements(
    '[CONFIG:APPSWITCH:SLIDE]\n$_roots$sequence',
  );
}

void main() {
  test('split to split aspect change is an immediate simultaneous cut', () {
    final List<StructuralSequencePlacement> placements = _placements(
      '''[STRUCT:MOSAIC.left:SPLIT]
[STRUCT:MOSAIC.right:SPLIT:ASPECT=4X3]
''',
    );

    expect(placements, hasLength(2));
    final StructuralSequencePlacement first = placements[0];
    final StructuralSequencePlacement second = placements[1];

    expect(first.presentationShape, StructuralPresentationShape.split);
    expect(second.presentationShape, StructuralPresentationShape.split);
    expect(second.previousPresentationShape, StructuralPresentationShape.split);
    expect(first.seamlessToNext, isTrue);
    expect(second.seamlessFromPrevious, isTrue);
    expect(first.exitWindowFrames, 0);
    expect(second.entryZoomFrames, 0);
    expect(second.entryWindowFrames, 0);
    expect(second.contentStartFrame, 0);
    expect(second.stageAt(0), StructuralSequenceStage.showing);
    expect(second.sourceFrameAt(0), 0);
  });

  test('window to split pays only the existing incoming window budget', () {
    final List<StructuralSequencePlacement> placements = _placements(
      '''[STRUCT:EDIT.a]
[STRUCT:MOSAIC.right:SPLIT]
''',
    );

    final StructuralSequencePlacement first = placements[0];
    final StructuralSequencePlacement second = placements[1];

    expect(first.presentationShape, StructuralPresentationShape.windowed);
    expect(second.presentationShape, StructuralPresentationShape.split);
    expect(
      second.previousPresentationShape,
      StructuralPresentationShape.windowed,
    );
    expect(first.exitWindowFrames, 0);
    expect(second.entryZoomFrames, 0);
    expect(second.entryWindowFrames, kStructuralWindowFrames);
    expect(second.contentStartFrame, kStructuralWindowFrames);
    expect(second.stageAt(0), StructuralSequenceStage.opening);
    expect(second.sourceFrameAt(0), 0);
    expect(
      second.durationFrames,
      kStructuralWindowFrames +
          second.sourceDurationFrames +
          kStructuralWindowFrames +
          kStructuralZoomFrames,
    );
  });

  test('split to window pays only the existing incoming window budget', () {
    final List<StructuralSequencePlacement> placements = _placements(
      '''[STRUCT:MOSAIC.left:SPLIT]
[STRUCT:EDIT.b]
''',
    );

    final StructuralSequencePlacement first = placements[0];
    final StructuralSequencePlacement second = placements[1];

    expect(first.presentationShape, StructuralPresentationShape.split);
    expect(second.presentationShape, StructuralPresentationShape.windowed);
    expect(
      second.previousPresentationShape,
      StructuralPresentationShape.split,
    );
    expect(first.exitWindowFrames, 0);
    expect(second.entryZoomFrames, 0);
    expect(second.entryWindowFrames, kStructuralWindowFrames);
    expect(second.contentStartFrame, kStructuralWindowFrames);
  });

  test('unsupported authored split keeps ordinary-window timing identity', () {
    final List<StructuralSequencePlacement> placements = _placements(
      '''[STRUCT:EDIT.a]
[STRUCT:MOSAIC.unsupported:SPLIT]
''',
    );

    final StructuralSequencePlacement second = placements[1];
    expect(second.splitWindowRequested, isTrue);
    expect(second.splitWindowSupported, isFalse);
    expect(second.splitWindow, isFalse);
    expect(second.presentationShape, StructuralPresentationShape.windowed);
    expect(second.entryWindowFrames, 0);
    expect(second.contentStartFrame, 0);
  });

  test('split aspect alone never adds project frames', () {
    final List<StructuralSequencePlacement> sameAspect = _placements(
      '''[STRUCT:MOSAIC.left:SPLIT]
[STRUCT:MOSAIC.right:SPLIT]
''',
    );
    final List<StructuralSequencePlacement> changedAspect = _placements(
      '''[STRUCT:MOSAIC.left:SPLIT]
[STRUCT:MOSAIC.right:SPLIT:ASPECT=9X16]
''',
    );

    expect(
      changedAspect[1].durationFrames,
      sameAspect[1].durationFrames,
    );
    expect(changedAspect[1].entryWindowFrames, 0);
    expect(changedAspect[1].contentStartFrame, 0);
  });
}
