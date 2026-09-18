// ./test/edit_cue_sliding_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_cue.dart';
import 'package:r3nder/edit_cue_authoring.dart';
import 'package:r3nder/edit_cue_overlap.dart';
import 'package:r3nder/edit_cue_sliding.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/edit_surface_model.dart';

CueOccupiedSpan _span({
  required int offset,
  required int start,
  required int end,
  CueCollisionLane lane = CueCollisionLane.presentation,
  CuePayloadKind kind = CuePayloadKind.card,
  String trackId = 'V1',
  String clipId = 'shot',
}) {
  return CueOccupiedSpan(
    lane: lane,
    kind: kind,
    trackId: trackId,
    clipId: clipId,
    sourceFrame: start,
    range: CueOccupiedRange(
      startFrame: start,
      endFrameExclusive: end,
    ),
    sourceStartOffset: offset,
  );
}

EditSurfaceClip _clip({
  String speed = '1',
  int duration = 300,
}) {
  final String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:shot:video/shot.mp4:0:0:$duration:$speed]
[/CLIP]
[/TRACK]
[/EDIT]
''';
  return EditSurfaceDocument.parse(source, 'main').clip('V1', 'shot');
}

void main() {
  group('reachable CUE project offsets', () {
    test('4/5 reachable set matches exact source projection', () {
      final ExactClipSpeed speed = ExactClipSpeed(4, 5);
      final List<int> projected = <int>[
        for (int sourceDelta = 0; sourceDelta < 10; sourceDelta++)
          (sourceDelta * speed.denominator + speed.numerator - 1) ~/
              speed.numerator,
      ];

      expect(projected, <int>[0, 2, 3, 4, 5, 7, 8, 9, 10, 12]);
    });

    test('directional quantizers are idempotent on reachable input', () {
      final ExactClipSpeed speed = ExactClipSpeed(4, 5);
      for (final int offset in <int>[0, 2, 3, 4, 5, 7, 8, 9, 10, 12]) {
        expect(reachableCueProjectOffsetAtOrAfter(speed, offset), offset);
        expect(reachableCueProjectOffsetAtOrBefore(speed, offset), offset);
      }

      expect(reachableCueProjectOffsetAtOrAfter(speed, 6), 7);
      expect(reachableCueProjectOffsetAtOrBefore(speed, 6), 5);
    });

    test('nearest reachable chooses lower on an exact tie', () {
      final ExactClipSpeed speed = ExactClipSpeed(1, 2);
      expect(nearestReachableCueProjectOffset(speed, 1), 0);
      expect(nearestReachableCueProjectOffset(speed, 3), 2);
    });

    test('2/1 canonical encoding picks smallest equivalent source frame', () {
      final ExactClipSpeed speed = ExactClipSpeed(2, 1);
      expect(isReachableCueProjectOffset(speed, 1), isTrue);
      expect(canonicalCueSourceDeltaForProjectOffset(speed, 1), 1);
      expect(canonicalCueSourceDeltaForProjectOffset(speed, 2), 3);
    });

    test('right CLIP limit quantizes downward below durationFrames', () {
      final EditSurfaceClip clip = _clip(speed: '4/5', duration: 7);
      final CueOccupiedSpan moving = _span(
        offset: 10,
        start: 0,
        end: 2,
      );
      final CueMoveBaseline baseline = beginCueMove(
        moving: moving,
        clip: clip,
        spans: <CueOccupiedSpan>[moving],
      );

      expect(baseline.minimumStartFrame, 0);
      expect(baseline.maximumStartFrame, 5);
      expect(isReachableCueProjectOffset(clip.clip.speed, 5), isTrue);
      expect(isReachableCueProjectOffset(clip.clip.speed, 6), isFalse);
    });
  });

  group('drag-start collision snapshot', () {
    test('legal cue clamps at conflicting CUE abutment', () {
      final EditSurfaceClip clip = _clip();
      final CueOccupiedSpan moving = _span(
        offset: 10,
        start: 0,
        end: 40,
      );
      final CueOccupiedSpan next = _span(
        offset: 20,
        start: 50,
        end: 90,
      );
      final CueMoveBaseline baseline = beginCueMove(
        moving: moving,
        clip: clip,
        spans: <CueOccupiedSpan>[moving, next],
      );

      final CueMovePreview preview = evaluateCueMove(baseline, 25);
      expect(preview.state, CueMovePreviewState.blocked);
      expect(preview.startFrame, 10);
      expect(preview.range.endFrameExclusive, 50);
      expect(preview.canCommit, isTrue);
    });

    test('MAXIMIZE is a hard wall for a CARD despite semantic lane split', () {
      final EditSurfaceClip clip = _clip();
      final CueOccupiedSpan moving = _span(
        offset: 10,
        start: 0,
        end: 40,
      );
      final CueOccupiedSpan maximize = _span(
        offset: 20,
        start: 50,
        end: 90,
        lane: CueCollisionLane.shell,
        kind: CuePayloadKind.maximize,
      );
      final CueMoveBaseline baseline = beginCueMove(
        moving: moving,
        clip: clip,
        spans: <CueOccupiedSpan>[moving, maximize],
      );

      final CueMovePreview preview = evaluateCueMove(baseline, 25);
      expect(preview.state, CueMovePreviewState.blocked);
      expect(preview.startFrame, 10);
      expect(preview.range.endFrameExclusive, 50);
    });

    test('legacy partner is passable but worsening overlap is invalid', () {
      final EditSurfaceClip clip = _clip();
      final CueOccupiedSpan partner = _span(
        offset: 10,
        start: 100,
        end: 200,
      );
      final CueOccupiedSpan moving = _span(
        offset: 20,
        start: 190,
        end: 210,
      );
      final CueMoveBaseline baseline = beginCueMove(
        moving: moving,
        clip: clip,
        spans: <CueOccupiedSpan>[partner, moving],
      );

      expect(baseline.startingPartnerStartOffsets, <int>{10});
      expect(baseline.startingTotalOverlapFrames, 10);

      final CueMovePreview worse = evaluateCueMove(baseline, 180);
      expect(worse.startFrame, 180);
      expect(worse.state, CueMovePreviewState.invalidPassable);
      expect(worse.totalOverlapFrames, 20);
      expect(worse.canCommit, isFalse);

      final CueMovePreview farSide = evaluateCueMove(baseline, 90);
      expect(farSide.startFrame, 90);
      expect(farSide.state, CueMovePreviewState.valid);
      expect(farSide.totalOverlapFrames, 10);

      final CueMovePreview clear = evaluateCueMove(baseline, 80);
      expect(clear.state, CueMovePreviewState.valid);
      expect(clear.totalOverlapFrames, 0);
    });

    test('legal cue can never enter invalid-passable state at neighbor', () {
      final EditSurfaceClip clip = _clip();
      final CueOccupiedSpan moving = _span(
        offset: 10,
        start: 0,
        end: 20,
      );
      final CueOccupiedSpan next = _span(
        offset: 20,
        start: 30,
        end: 50,
      );
      final CueMoveBaseline baseline = beginCueMove(
        moving: moving,
        clip: clip,
        spans: <CueOccupiedSpan>[moving, next],
      );

      final CueMovePreview preview = evaluateCueMove(baseline, 20);
      expect(baseline.startingPartnerStartOffsets, isEmpty);
      expect(baseline.startingTotalOverlapFrames, 0);
      expect(preview.state, CueMovePreviewState.blocked);
      expect(preview.startFrame, 10);
      expect(preview.state, isNot(CueMovePreviewState.invalidPassable));
    });

    test('fresh commit rejects acquiring a second neighbor', () {
      final EditSurfaceClip clip = _clip();
      final CueOccupiedSpan partner = _span(
        offset: 10,
        start: 100,
        end: 200,
      );
      final CueOccupiedSpan moving = _span(
        offset: 20,
        start: 190,
        end: 210,
      );
      final CueOccupiedSpan second = _span(
        offset: 30,
        start: 220,
        end: 260,
      );
      final CueMoveBaseline baseline = beginCueMove(
        moving: moving,
        clip: clip,
        spans: <CueOccupiedSpan>[partner, moving, second],
      );
      final CueOccupiedSpan candidate = _span(
        offset: 20,
        start: 205,
        end: 225,
      );

      final CueMoveCommitValidation validation = validateCueMoveCommit(
        baseline: baseline,
        candidate: candidate,
        freshSpans: <CueOccupiedSpan>[partner, moving, second],
      );

      expect(validation.isLegal, isFalse);
      expect(validation.message, contains('new conflicting overlap'));
    });
  });

  group('trigger-only source commit', () {
    test('99 to 100 preserves own offset and rederives later offsets', () {
      const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:shot:video/shot.mp4:0:0:300:1]
[CUE:99]
[CARD:first.png:0]
FIRST PAYLOAD
[/CARD]
[/CUE]
opaque bytes stay exactly here
[CUE:200]
[CARD:second.png:0]
SECOND PAYLOAD
[/CARD]
[/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
''';
      final EditSurfaceDocument document =
          EditSurfaceDocument.parse(source, 'main');
      final List<CueOccupiedSpan> spans = projectCueOccupiedSpans(document);
      final CueOccupiedSpan moving =
          spans.singleWhere((CueOccupiedSpan span) => span.sourceFrame == 99);
      final CueOccupiedSpan later =
          spans.singleWhere((CueOccupiedSpan span) => span.sourceFrame == 200);
      final CueMoveBaseline baseline = beginCueMove(
        moving: moving,
        clip: document.clip('V1', 'shot'),
        spans: spans,
      );

      final String next = moveCueTrigger(
        document: document,
        trackId: 'V1',
        clipId: 'shot',
        baseline: baseline,
        targetProjectFrame: 100,
      );

      final int oldOffset = moving.sourceStartOffset!;
      final int oldLaterOffset = later.sourceStartOffset!;
      expect(next, source.replaceFirst('[CUE:99]', '[CUE:100]'));
      expect(next.indexOf('[CUE:100]'), oldOffset);
      expect(next.indexOf('[CUE:200]'), oldLaterOffset + 1);
      expect(next, contains('opaque bytes stay exactly here'));

      final List<CueOccupiedSpan> reparsed = projectCueOccupiedSpans(
        EditSurfaceDocument.parse(next, 'main'),
      );
      expect(
        reparsed
            .singleWhere(
              (CueOccupiedSpan span) =>
                  span.sourceStartOffset == oldOffset,
            )
            .sourceFrame,
        100,
      );
    });

    test('2/1 move writes canonical smallest source frame', () {
      const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:shot:video/shot.mp4:0:100:100:2/1]
[CUE:100][CARD:a.png:0]A[/CARD][/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
''';
      final EditSurfaceDocument document =
          EditSurfaceDocument.parse(source, 'main');
      final List<CueOccupiedSpan> spans = projectCueOccupiedSpans(document);
      final CueMoveBaseline baseline = beginCueMove(
        moving: spans.single,
        clip: document.clip('V1', 'shot'),
        spans: spans,
      );

      final String next = moveCueTrigger(
        document: document,
        trackId: 'V1',
        clipId: 'shot',
        baseline: baseline,
        targetProjectFrame: 1,
      );

      expect(next, contains('[CUE:101]'));
      expect(next, isNot(contains('[CUE:102]')));
    });

    test('fresh DOSSIER duration can reject stale-valid release', () {
      const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:shot:video/shot.mp4:0:0:200:1]
[CUE:0]
[DOSSIER:evidence:person.png:0:0:0:MOSAIC:24,32,40:D]
D
[/DOSSIER]
[/CUE]
[CUE:80][CARD:c.png:0]C[/CARD][/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
''';
      int dossierDuration = 40;
      int resolver(_) => dossierDuration;

      final EditSurfaceDocument document =
          EditSurfaceDocument.parse(source, 'main');
      final List<CueOccupiedSpan> spans = projectCueOccupiedSpans(
        document,
        dossierDurationFramesFor: resolver,
      );
      final CueOccupiedSpan moving = spans.singleWhere(
        (CueOccupiedSpan span) => span.kind == CuePayloadKind.dossier,
      );
      final CueMoveBaseline baseline = beginCueMove(
        moving: moving,
        clip: document.clip('V1', 'shot'),
        spans: spans,
      );
      expect(evaluateCueMove(baseline, 40).state, CueMovePreviewState.valid);

      dossierDuration = 50;
      expect(
        () => moveCueTrigger(
          document: document,
          trackId: 'V1',
          clipId: 'shot',
          baseline: baseline,
          targetProjectFrame: 40,
          dossierDurationFramesFor: resolver,
        ),
        throwsA(
          isA<EditCueAuthoringException>().having(
            (EditCueAuthoringException error) => error.message,
            'message',
            contains('new conflicting overlap'),
          ),
        ),
      );
    });
  });
}
