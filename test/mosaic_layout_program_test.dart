// ./test/mosaic_layout_program_test.dart

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/mosaic_layout_cue.dart';
import 'package:r3nder/mosaic_layout_program.dart';
import 'package:r3nder/mosaic_split_geometry.dart';
import 'package:r3nder/structural_shell_geometry.dart';

void main() {
  const Rect programRect = Rect.fromLTWH(0, 0, 1920, 1080);
  const Rect windowRect = Rect.fromLTWH(400, 200, 1120, 680);

  MosaicLayoutEvaluationContext context({
    MosaicLayoutState? legacySeed,
    Rect? compositeRect,
    double compositeChrome = 1.0,
  }) {
    return MosaicLayoutEvaluationContext(
      programRect: programRect,
      ordinaryWindowRect: windowRect,
      compositeRect: compositeRect ?? windowRect,
      compositeChrome: compositeChrome,
      titleHeight: 36,
      legacySeed: legacySeed,
    );
  }

  MosaicLayoutProgram programFor(
    String layoutLines, {
    int durationFrames = 1200,
  }) {
    final String source = '''[MOSAIC:wall]
$layoutLines
  [PANE:A]
    [CLIP:a:video/a.mp4:0:0:$durationFrames:1]
    [/CLIP]
  [/PANE]
  [PANE:B]
    [CLIP:b:video/b.mp4:0:0:$durationFrames:1]
    [/CLIP]
  [/PANE]
  [PANE:C]
    [CLIP:c:video/c.mp4:0:0:$durationFrames:1]
    [/CLIP]
  [/PANE]
[/MOSAIC]
''';
    final EditDocumentModel model = EditDocumentModel.parse(source);
    return MosaicLayoutProgram.fromMosaic(
      source: source,
      mosaic: model.mosaic('wall'),
    );
  }

  Rect leftRect({
    MosaicSplitClientAspect aspect = MosaicSplitClientAspect.aspect16x9,
    bool maximized = false,
  }) =>
      mosaicSplitWindowGeometry(
        frame: programRect,
        aspect: aspect,
        titleHeight: 36,
        maximized: maximized,
      ).leftWindowRect;

  Rect rightRect({
    MosaicSplitClientAspect aspect = MosaicSplitClientAspect.aspect16x9,
    bool maximized = false,
  }) =>
      mosaicSplitWindowGeometry(
        frame: programRect,
        aspect: aspect,
        titleHeight: 36,
        maximized: maximized,
      ).rightWindowRect;

  void expectDominanceInvariants(
    MosaicLayoutFrame frame, {
    String? reason,
  }) {
    final List<MosaicLayoutActiveSegment> segments = frame.actors
        .map(
          (MosaicLayoutActorFrame actor) => actor.activeSegment,
        )
        .whereType<MosaicLayoutActiveSegment>()
        .toList(growable: false);

    final int targetDominantCount =
        segments.where((MosaicLayoutActiveSegment segment) {
      return segment.targetDominant;
    }).length;
    expect(
      targetDominantCount,
      lessThanOrEqualTo(1),
      reason: reason ??
          'multiple target-dominant actors at F' +
              frame.sourceFrame.toString(),
    );

    final int eligibleStartDominantCount =
        segments.where((MosaicLayoutActiveSegment segment) {
      return segment.startDominant &&
          segment.targetPresence != MosaicLayoutPresence.absent;
    }).length;
    expect(
      eligibleStartDominantCount,
      lessThanOrEqualTo(1),
      reason: reason ??
          'multiple target-present start-dominant actors at F' +
              frame.sourceFrame.toString(),
    );

    for (final MosaicLayoutActiveSegment segment in segments) {
      if (segment.targetDominant) {
        expect(
          segment.targetPresence,
          isNot(MosaicLayoutPresence.absent),
          reason: reason ??
              'target dominance without target presence at F' +
                  frame.sourceFrame.toString(),
        );
      }
    }

    int highestPriority = 0;
    for (final MosaicLayoutActorFrame actor in frame.actors) {
      if (actor.dominantMorphPriority > highestPriority) {
        highestPriority = actor.dominantMorphPriority;
      }
    }
    if (highestPriority > 0) {
      final int winnerCount = frame.actors.where(
        (MosaicLayoutActorFrame actor) =>
            actor.dominantMorphPriority == highestPriority,
      ).length;
      expect(
        winnerCount,
        1,
        reason: reason ??
            'dominant morph ownership tied at F' +
                frame.sourceFrame.toString(),
      );
    }
  }

  group('Initial layout metadata', () {
    test('LAYOUT_START establishes opening TWOUP without a frame-zero cue', () {
      final MosaicLayoutProgram program = programFor('''
  [LAYOUT_START:TWOUP:A=A:B=B:ASPECT=4X3]''');
      final MosaicResolvedLayoutProgram resolved = program.resolve(
        context(
          legacySeed: const MosaicLayoutState.full('C'),
        ),
      );

      final MosaicLayoutFrame frame0 = resolved.evaluate(0);
      expect(frame0.pane('A').presence, MosaicLayoutPresence.present);
      expect(frame0.pane('B').presence, MosaicLayoutPresence.present);
      expect(frame0.pane('A').rect, leftRect(
        aspect: MosaicSplitClientAspect.aspect4x3,
      ));
      expect(frame0.pane('B').rect, rightRect(
        aspect: MosaicSplitClientAspect.aspect4x3,
      ));
      expect(frame0.composite.presence, MosaicLayoutPresence.absent);
      expect(frame0.pane('C').presence, MosaicLayoutPresence.absent);
    });

    test('LAYOUT_START is the seed and later cues remain transitions', () {
      final MosaicResolvedLayoutProgram resolved = programFor('''
  [LAYOUT_START:ONE:PANE=A]
  [LAYOUT:100:TWOUP:A=A:B=B:DUR=12]''').resolve(context());

      final MosaicLayoutFrame before = resolved.evaluate(99);
      expect(before.pane('A').presence, MosaicLayoutPresence.present);
      expect(before.pane('A').rect, windowRect);
      expect(before.pane('B').presence, MosaicLayoutPresence.absent);

      final MosaicLayoutFrame atCue = resolved.evaluate(100);
      expect(atCue.pane('A').activeSegment, isNotNull);
      expect(atCue.pane('B').presence, MosaicLayoutPresence.entering);
    });

    test('legacy frame-zero cue still establishes initial layout when no start metadata exists',
        () {
      final MosaicResolvedLayoutProgram resolved = programFor('''
  [LAYOUT:0:FULL:PANE=B]''').resolve(context());

      final MosaicLayoutFrame frame0 = resolved.evaluate(0);
      expect(frame0.pane('B').presence, MosaicLayoutPresence.present);
      expect(frame0.pane('B').rect, programRect);
      expect(frame0.composite.presence, MosaicLayoutPresence.absent);
    });

    test('LAYOUT_START wins over legacy frame-zero cue and reports it', () {
      final MosaicResolvedLayoutProgram resolved = programFor('''
  [LAYOUT_START:ONE:PANE=A]
  [LAYOUT:0:FULL:PANE=B]''').resolve(context());

      final MosaicLayoutFrame frame0 = resolved.evaluate(0);
      expect(frame0.pane('A').presence, MosaicLayoutPresence.present);
      expect(frame0.pane('A').rect, windowRect);
      expect(frame0.pane('B').presence, MosaicLayoutPresence.absent);
      expect(
        resolved.issues.any(
          (MosaicLayoutIssue issue) =>
              issue.code == MosaicLayoutIssueCode.initialWithFrameZeroCue,
        ),
        isTrue,
      );
    });
  });

  group('Family 3 - per-actor interruption', () {
    test('A is a CONTINUE sentinel across TWOUP A/B to TWOUP A/C', () {
      final MosaicResolvedLayoutProgram resolved = programFor('''
  [LAYOUT:500:TWOUP:A=A:B=B:DUR=20]
  [LAYOUT:505:TWOUP:A=A:B=C:DUR=4]''').resolve(context());

      final MosaicLayoutActiveSegment? before =
          resolved.evaluate(504).pane('A').activeSegment;
      final MosaicLayoutActiveSegment? after =
          resolved.evaluate(505).pane('A').activeSegment;

      expect(before, isNotNull);
      expect(after, before);
      expect(after!.startFrame, 500);
      expect(after.durationFrames, 20);

      final MosaicLayoutActorFrame b = resolved.evaluate(505).pane('B');
      final MosaicLayoutActorFrame c = resolved.evaluate(505).pane('C');
      expect(b.presence, MosaicLayoutPresence.exiting);
      expect(b.activeSegment!.startFrame, 505);
      expect(b.activeSegment!.durationFrames, 4);
      expect(b.activeSegment!.anchorRect, rightRect());
      expect(
        b.activeSegment!.targetRect,
        structuralShellEmergenceRect(rightRect()),
      );
      expect(c.presence, MosaicLayoutPresence.entering);
      expect(c.activeSegment!.startFrame, 505);
      expect(c.activeSegment!.durationFrames, 4);

      // COMPOSITE was already exiting on the F500 cue. F505 does not re-time it.
      final MosaicLayoutActiveSegment? composite =
          resolved.evaluate(505).composite.activeSegment;
      expect(composite, isNotNull);
      expect(composite!.startFrame, 500);
      expect(composite.durationFrames, 20);
    });

    test('mid-exit recall preserves current z until new midpoint', () {
      final MosaicResolvedLayoutProgram resolved = programFor('''
  [LAYOUT:500:ONE:PANE=A:DUR=12]
  [LAYOUT:508:TWOUP:A=A:B=B:DUR=12]''').resolve(
        context(
          legacySeed: const MosaicLayoutState.twoUp(
            paneA: 'A',
            paneB: 'B',
          ),
        ),
      );

      final MosaicLayoutActorFrame b507 = resolved.evaluate(507).pane('B');
      expect(b507.presence, MosaicLayoutPresence.exiting);
      expect(b507.z.band, MosaicLayoutZBand.exiting);

      final MosaicResolvedLayoutProgram withoutRecall = programFor('''
  [LAYOUT:500:ONE:PANE=A:DUR=12]''').resolve(
        context(
          legacySeed: const MosaicLayoutState.twoUp(
            paneA: 'A',
            paneB: 'B',
          ),
        ),
      );
      final MosaicLayoutActorFrame oldAt508 =
          withoutRecall.evaluate(508).pane('B');

      final MosaicLayoutActorFrame b508 = resolved.evaluate(508).pane('B');
      expect(b508.presence, MosaicLayoutPresence.present);
      expect(b508.activeSegment, isNotNull);
      expect(b508.activeSegment!.startFrame, 508);
      expect(b508.activeSegment!.startZ, oldAt508.z);
      expect(b508.z, oldAt508.z);
      expect(b508.rect, oldAt508.rect);
      expect(b508.opacity, oldAt508.opacity);
      expect(b508.chrome, oldAt508.chrome);

      expect(resolved.evaluate(513).pane('B').z.band, MosaicLayoutZBand.exiting);
      expect(resolved.evaluate(514).pane('B').z.band, MosaicLayoutZBand.stable);
      expect(resolved.evaluate(519).pane('B').presence,
          MosaicLayoutPresence.present);
      expect(resolved.evaluate(519).pane('B').activeSegment, isNull);
      expect(resolved.evaluate(519).pane('B').rect, rightRect());
    });

    test('unchanged exiting COMPOSITE continues instead of re-timing', () {
      final MosaicResolvedLayoutProgram resolved = programFor('''
  [LAYOUT:500:TWOUP:A=A:B=B:DUR=12]
  [LAYOUT:508:ONE:PANE=A:DUR=12]''').resolve(context());

      final MosaicLayoutActorFrame c508 = resolved.evaluate(508).composite;
      expect(c508.presence, MosaicLayoutPresence.exiting);
      expect(c508.activeSegment, isNotNull);
      expect(c508.activeSegment!.startFrame, 500);
      expect(c508.activeSegment!.endFrame, 511);
      expect(c508.activeSegment!.anchorRect, windowRect);
      expect(
        c508.activeSegment!.targetRect,
        structuralShellEmergenceRect(windowRect),
      );

      // Cue 2 does not generate E(E(W)) and does not move the end to F519.
      expect(resolved.evaluate(510).composite.presence,
          MosaicLayoutPresence.exiting);
      expect(resolved.evaluate(511).composite.presence,
          MosaicLayoutPresence.absent);
      expect(resolved.evaluate(511).composite.activeSegment, isNull);
    });

    test('enter redirect dismiss chain uses only the current segment anchor', () {
      final MosaicResolvedLayoutProgram resolved = programFor('''
  [LAYOUT:500:TWOUP:A=A:B=B:DUR=12]
  [LAYOUT:505:ONE:PANE=B:DUR=12]
  [LAYOUT:510:ONE:PANE=A:DUR=12]''').resolve(context());

      final MosaicLayoutActorFrame a505 = resolved.evaluate(505).pane('A');
      expect(a505.presence, MosaicLayoutPresence.exiting);
      expect(a505.activeSegment!.anchorRect, leftRect());
      expect(
        a505.activeSegment!.targetRect,
        structuralShellEmergenceRect(leftRect()),
      );

      // A is recalled while still exiting, but its new ONE target is W.
      final MosaicLayoutActorFrame a510 = resolved.evaluate(510).pane('A');
      expect(a510.presence, MosaicLayoutPresence.present);
      expect(a510.activeSegment!.startFrame, 510);
      expect(a510.activeSegment!.startPresence, MosaicLayoutPresence.exiting);
      expect(a510.activeSegment!.anchorRect, windowRect);
      expect(a510.activeSegment!.targetRect, windowRect);

      // B had redirected toward W at F505, so dismissal uses E(W), not E(R).
      final MosaicLayoutActorFrame b510 = resolved.evaluate(510).pane('B');
      expect(b510.presence, MosaicLayoutPresence.exiting);
      expect(b510.activeSegment!.anchorRect, windowRect);
      expect(
        b510.activeSegment!.targetRect,
        structuralShellEmergenceRect(windowRect),
      );
      expect(
        b510.activeSegment!.targetRect,
        isNot(structuralShellEmergenceRect(rightRect())),
      );
    });

    test('cue on prior end settles before reconciliation', () {
      final MosaicResolvedLayoutProgram resolved = programFor('''
  [LAYOUT:500:ONE:PANE=A:DUR=12]
  [LAYOUT:511:TWOUP:A=A:B=B:DUR=12]''').resolve(
        context(
          legacySeed: const MosaicLayoutState.twoUp(
            paneA: 'A',
            paneB: 'B',
          ),
        ),
      );

      final MosaicLayoutActorFrame b = resolved.evaluate(511).pane('B');
      // B's F500 exit has settled at this exact frame. The F511 cue therefore
      // sees canonical ABSENT and creates a fresh entry.
      expect(b.presence, MosaicLayoutPresence.entering);
      expect(b.activeSegment!.startPresence, MosaicLayoutPresence.absent);
      expect(b.activeSegment!.startFrame, 511);
      expect(b.activeSegment!.startRect, structuralShellEmergenceRect(rightRect()));
    });
  });

  group('Focal dominance and peer ordering', () {
    test('ONE source focus stays above an entering TWOUP peer', () {
      final MosaicResolvedLayoutProgram resolved = programFor('''
  [LAYOUT_START:ONE:PANE=A]
  [LAYOUT:100:TWOUP:A=A:B=B:DUR=12]''').resolve(context());

      for (int frame = 100; frame < 111; frame++) {
        final MosaicLayoutFrame layout = resolved.evaluate(frame);
        final MosaicLayoutActorFrame a = layout.pane('A');
        final MosaicLayoutActorFrame b = layout.pane('B');

        expect(a.activeSegment, isNotNull);
        expect(a.activeSegment!.startDominant, isTrue);
        expect(a.activeSegment!.targetDominant, isFalse);
        expect(a.dominantMorphPriority, 1);
        expect(b.dominantMorphPriority, 0);
        expect(
          layout.paintActors.last.actorId,
          a.actorId,
          reason: 'ONE source focus fell behind entering peer at F$frame',
        );
        expectDominanceInvariants(layout);
      }

      final MosaicLayoutFrame settled = resolved.evaluate(111);
      expect(settled.pane('A').dominantMorphPriority, 0);
      expect(settled.paintActors.last.actorId.paneId, 'B');
    });

    test('TWOUP to ONE promotes the target focus from the first frame', () {
      final MosaicResolvedLayoutProgram resolved = programFor('''
  [LAYOUT_START:TWOUP:A=A:B=B]
  [LAYOUT:100:ONE:PANE=A:DUR=12]''').resolve(context());

      for (int frame = 100; frame < 111; frame++) {
        final MosaicLayoutFrame layout = resolved.evaluate(frame);
        final MosaicLayoutActorFrame a = layout.pane('A');

        expect(a.activeSegment, isNotNull);
        expect(a.activeSegment!.startDominant, isFalse);
        expect(a.activeSegment!.targetDominant, isTrue);
        expect(a.dominantMorphPriority, 2);
        expect(
          layout.paintActors.last.actorId,
          a.actorId,
          reason: 'ONE target focus did not own front at F$frame',
        );
        expectDominanceInvariants(layout);
      }
    });

    test('FULL A to ONE B drops ownership from the target-absent exit', () {
      final MosaicResolvedLayoutProgram resolved = programFor('''
  [LAYOUT_START:FULL:PANE=A]
  [LAYOUT:100:ONE:PANE=B:DUR=12]''').resolve(context());

      final MosaicLayoutFrame start = resolved.evaluate(100);
      final MosaicLayoutActorFrame a = start.pane('A');
      final MosaicLayoutActorFrame b = start.pane('B');

      expect(a.activeSegment!.startDominant, isTrue);
      expect(a.activeSegment!.targetDominant, isFalse);
      expect(
        a.activeSegment!.targetPresence,
        MosaicLayoutPresence.absent,
      );
      expect(a.dominantMorphPriority, 0);

      expect(b.activeSegment!.startDominant, isFalse);
      expect(b.activeSegment!.targetDominant, isTrue);
      expect(b.dominantMorphPriority, 2);
      expect(start.paintActors.last.actorId, b.actorId);
      expectDominanceInvariants(start);
    });

    test('same-band TWOUP reorder keeps source roleRank until settlement', () {
      final MosaicResolvedLayoutProgram resolved = programFor('''
  [LAYOUT_START:TWOUP:A=A:B=B]
  [LAYOUT:100:TWOUP:A=B:B=A:DUR=12]''').resolve(context());

      final MosaicLayoutActorFrame a100 = resolved.evaluate(100).pane('A');
      final MosaicLayoutActorFrame b100 = resolved.evaluate(100).pane('B');
      expect(a100.activeSegment!.startZ.roleRank, 0);
      expect(a100.activeSegment!.targetZ.roleRank, 1);
      expect(b100.activeSegment!.startZ.roleRank, 1);
      expect(b100.activeSegment!.targetZ.roleRank, 0);

      for (int frame = 100; frame < 111; frame++) {
        final MosaicLayoutFrame layout = resolved.evaluate(frame);
        expect(layout.pane('A').z.roleRank, 0);
        expect(layout.pane('B').z.roleRank, 1);
        expect(
          layout.paintActors.last.actorId.paneId,
          'B',
          reason: 'peer roleRank switched before settlement at F$frame',
        );
      }

      final MosaicLayoutFrame settled = resolved.evaluate(111);
      expect(settled.pane('A').activeSegment, isNull);
      expect(settled.pane('B').activeSegment, isNull);
      expect(settled.pane('A').z.roleRank, 1);
      expect(settled.pane('B').z.roleRank, 0);
      expect(settled.paintActors.last.actorId.paneId, 'A');
    });

    test('interruption snapshots the globally resolved owner, not stale exits',
        () {
      final MosaicResolvedLayoutProgram resolved = programFor('''
  [LAYOUT_START:ONE:PANE=A]
  [LAYOUT:100:ONE:PANE=B:DUR=20]
  [LAYOUT:105:ONE:PANE=C:DUR=12]''').resolve(context());

      expect(resolved.evaluate(104).pane('B').dominantMorphPriority, 2);

      final MosaicLayoutFrame redirected = resolved.evaluate(105);
      final MosaicLayoutActorFrame a = redirected.pane('A');
      final MosaicLayoutActorFrame b = redirected.pane('B');
      final MosaicLayoutActorFrame c = redirected.pane('C');

      // A's old exit CONTINUEs exactly. Its raw source-end fact is allowed to
      // remain true because target-absence makes it ineligible (priority zero).
      expect(a.activeSegment!.startFrame, 100);
      expect(a.activeSegment!.startDominant, isTrue);
      expect(
        a.activeSegment!.targetPresence,
        MosaicLayoutPresence.absent,
      );
      expect(a.dominantMorphPriority, 0);

      // B was the globally resolved owner immediately before F105, so only B
      // snapshots current ownership into the new redirect.
      expect(b.activeSegment!.startFrame, 105);
      expect(b.activeSegment!.startDominant, isTrue);
      expect(
        b.activeSegment!.targetPresence,
        MosaicLayoutPresence.absent,
      );
      expect(b.dominantMorphPriority, 0);

      expect(c.activeSegment!.targetDominant, isTrue);
      expect(c.dominantMorphPriority, 2);
      expect(redirected.paintActors.last.actorId, c.actorId);

      final int rawStartDominantCount = redirected.actors
          .map((MosaicLayoutActorFrame actor) => actor.activeSegment)
          .whereType<MosaicLayoutActiveSegment>()
          .where((MosaicLayoutActiveSegment segment) => segment.startDominant)
          .length;
      expect(
        rawStartDominantCount,
        2,
        reason:
            'target-absent CONTINUE metadata may span cue generations without '
            'creating a second eligible owner',
      );

      for (int frame = 100; frame < 116; frame++) {
        expectDominanceInvariants(
          resolved.evaluate(frame),
          reason: 'dominance invariant failed at F$frame',
        );
      }
    });
  });

  group('Family 6 - placement context and canonical settlement', () {
    test('different seeds converge only when ONE settles', () {
      final MosaicLayoutProgram program = programFor('''
  [LAYOUT:500:ONE:PANE=A:DUR=12]
  [LAYOUT:700:FULL:PANE=A:DUR=12]
  [LAYOUT:900:COMPOSITE:DUR=12]''');

      final MosaicResolvedLayoutProgram placementA = program.resolve(
        context(
          legacySeed: const MosaicLayoutState.twoUp(
            paneA: 'A',
            paneB: 'B',
          ),
        ),
      );
      final MosaicResolvedLayoutProgram placementB = program.resolve(
        context(
          compositeRect: programRect,
          compositeChrome: 0.0,
        ),
      );

      expect(placementA.evaluate(499), isNot(placementB.evaluate(499)));
      expect(placementA.evaluate(500), isNot(placementB.evaluate(500)));
      expect(placementA.evaluate(505), isNot(placementB.evaluate(505)));
      expect(placementA.evaluate(511), placementB.evaluate(511));

      // Settled equality propagates through every subsequent pane-owned frame.
      for (int frame = 511; frame < 900; frame++) {
        expect(
          placementA.evaluate(frame),
          placementB.evaluate(frame),
          reason: 'placement histories diverged again at F$frame',
        );
      }

      // COMPOSITE consults placement-specific context again.
      expect(placementA.evaluate(900), isNot(placementB.evaluate(900)));
      expect(placementA.evaluate(905), isNot(placementB.evaluate(905)));
      expect(placementA.evaluate(911), isNot(placementB.evaluate(911)));
      expect(placementA.evaluate(911).composite.rect, windowRect);
      expect(placementB.evaluate(911).composite.rect, programRect);
    });

    test('pane audio gain is independent of resolved geometry', () {
      final MosaicLayoutProgram program = programFor('''
  [LAYOUT_START:COMPOSITE]
  [LAYOUT:100:TWOUP:A=A:B=B:DUR=12]
  [LAYOUT:140:ONE:PANE=A:DUR=20]
  [LAYOUT:190:FULL:PANE=A:DUR=12]
  [LAYOUT:230:COMPOSITE:DUR=12]''', durationFrames: 280);

      const MosaicLayoutEvaluationContext landscape =
          MosaicLayoutEvaluationContext(
        programRect: Rect.fromLTWH(0, 0, 1920, 1080),
        ordinaryWindowRect: Rect.fromLTWH(400, 200, 1120, 680),
        compositeRect: Rect.fromLTWH(400, 200, 1120, 680),
        compositeChrome: 1.0,
        titleHeight: 36,
      );
      const MosaicLayoutEvaluationContext portrait =
          MosaicLayoutEvaluationContext(
        programRect: Rect.fromLTWH(0, 0, 720, 1440),
        ordinaryWindowRect: Rect.fromLTWH(40, 600, 640, 360),
        compositeRect: Rect.fromLTWH(10, 20, 700, 1400),
        compositeChrome: 0.0,
        titleHeight: 84,
      );

      final MosaicResolvedLayoutProgram a = program.resolve(landscape);
      final MosaicResolvedLayoutProgram b = program.resolve(portrait);

      // Prove the two resolutions really are using different geometry.
      expect(a.evaluate(110).pane('A').rect, isNot(b.evaluate(110).pane('A').rect));
      expect(
        a.evaluate(235).composite.rect,
        isNot(b.evaluate(235).composite.rect),
      );

      for (int frame = 0; frame < 280; frame++) {
        for (final String paneId in <String>['A', 'B', 'C']) {
          expect(
            a.paneAudioFrame(paneId, sourceFrame: frame),
            b.paneAudioFrame(paneId, sourceFrame: frame),
            reason: 'pane audio became geometry-dependent for $paneId at F$frame',
          );
        }
      }
    });

    test('separate resolution builds serialize identically', () {
      final MosaicLayoutEvaluationContext placement = context();
      final MosaicLayoutProgram previewProgram = programFor('''
  [LAYOUT:500:TWOUP:A=A:B=B:DUR=20]
  [LAYOUT:505:TWOUP:A=A:B=C:DUR=4]
  [LAYOUT:700:FULL:PANE=A:DUR=12]''');
      final MosaicLayoutProgram bakeProgram = programFor('''
  [LAYOUT:500:TWOUP:A=A:B=B:DUR=20]
  [LAYOUT:505:TWOUP:A=A:B=C:DUR=4]
  [LAYOUT:700:FULL:PANE=A:DUR=12]''');

      final String previewCopy =
          previewProgram.resolve(placement).canonicalSerialization();
      final String bakeCopy =
          bakeProgram.resolve(placement).canonicalSerialization();

      expect(previewCopy, bakeCopy);
    });
  });

  test('FULL -> TWOUP -> FULL keeps focal ownership separate from band',
      () {
    final MosaicResolvedLayoutProgram resolved = programFor('''
  [LAYOUT:100:FULL:PANE=A:DUR=1]
  [LAYOUT:200:TWOUP:A=A:B=B:DUR=12]
  [LAYOUT:300:FULL:PANE=A:DUR=12]''').resolve(context());

    for (int frame = 200; frame < 211; frame++) {
      final MosaicLayoutFrame layout = resolved.evaluate(frame);
      final MosaicLayoutActorFrame a = layout.pane('A');
      final MosaicLayoutActorFrame b = layout.pane('B');
      expect(a.activeSegment, isNotNull);
      expect(a.dominantMorphPriority, 1);
      expect(
        layout.paintActors.last.actorId,
        a.actorId,
        reason: 'shrinking focal pane fell behind peer at F$frame',
      );
      expect(b.presence, isNot(MosaicLayoutPresence.absent));
    }
    expect(resolved.evaluate(205).pane('A').z.band,
        MosaicLayoutZBand.fullTarget);
    expect(resolved.evaluate(206).pane('A').z.band,
        MosaicLayoutZBand.stable);

    final MosaicLayoutFrame settledTwoUp = resolved.evaluate(211);
    expect(settledTwoUp.pane('A').dominantMorphPriority, 0);
    expect(settledTwoUp.pane('A').z.band, MosaicLayoutZBand.stable);
    expect(settledTwoUp.paintActors.last.actorId.paneId, 'B');

    for (int frame = 300; frame < 311; frame++) {
      final MosaicLayoutFrame layout = resolved.evaluate(frame);
      final MosaicLayoutActorFrame a = layout.pane('A');
      expect(a.activeSegment, isNotNull);
      expect(a.dominantMorphPriority, 2);
      expect(
        layout.paintActors.last.actorId,
        a.actorId,
        reason: 'expanding focal pane fell behind peer at F$frame',
      );
    }
    expect(resolved.evaluate(305).pane('A').z.band,
        MosaicLayoutZBand.stable);
    expect(resolved.evaluate(306).pane('A').z.band,
        MosaicLayoutZBand.fullTarget);

    final MosaicLayoutFrame settledFull = resolved.evaluate(311);
    expect(settledFull.pane('A').activeSegment, isNull);
    expect(settledFull.pane('A').dominantMorphPriority, 0);
    expect(settledFull.pane('A').z.band, MosaicLayoutZBand.fullTarget);
    expect(settledFull.pane('B').presence, MosaicLayoutPresence.absent);
  });

  group('Duration edge pin', () {
    test('D=2 has no transitional target-z-only frame', () {
      final MosaicResolvedLayoutProgram resolved = programFor('''
  [LAYOUT:500:ONE:PANE=A:DUR=2]''').resolve(
        context(
          legacySeed: const MosaicLayoutState.twoUp(
            paneA: 'A',
            paneB: 'B',
          ),
        ),
      );

      final MosaicLayoutActorFrame a500 = resolved.evaluate(500).pane('A');
      expect(a500.activeSegment, isNotNull);
      expect(a500.activeSegment!.zSwitchFrame, 501);
      expect(a500.activeSegment!.endFrame, 501);
      expect(a500.z, a500.activeSegment!.startZ);

      final MosaicLayoutActorFrame a501 = resolved.evaluate(501).pane('A');
      expect(a501.activeSegment, isNull);
      expect(a501.presence, MosaicLayoutPresence.present);
      expect(a501.z.band, MosaicLayoutZBand.stable);
      expect(a501.rect, windowRect);
    });
  });
}
