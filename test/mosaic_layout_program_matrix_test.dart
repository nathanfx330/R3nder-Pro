// ./test/mosaic_layout_program_matrix_test.dart

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/mosaic_layout_cue.dart';
import 'package:r3nder/mosaic_layout_program.dart';
import 'package:r3nder/mosaic_split_geometry.dart';

void main() {
  const Rect programRect = Rect.fromLTWH(0, 0, 1920, 1080);
  const Rect windowRect = Rect.fromLTWH(400, 200, 1120, 680);
  const double titleHeight = 36;

  MosaicLayoutEvaluationContext context({
    MosaicLayoutState? legacySeed,
    Rect? compositeRect,
    double compositeChrome = 1.0,
  }) =>
      MosaicLayoutEvaluationContext(
        programRect: programRect,
        ordinaryWindowRect: windowRect,
        compositeRect: compositeRect ?? windowRect,
        compositeChrome: compositeChrome,
        titleHeight: titleHeight,
        legacySeed: legacySeed,
      );

  String sourceFor(
    String layoutLines, {
    int durationFrames = 1200,
    int paneCount = 3,
  }) {
    final StringBuffer out = StringBuffer()
      ..writeln('[MOSAIC:wall]');
    if (layoutLines.isNotEmpty) {
      out.writeln(layoutLines);
    }
    const List<String> ids = <String>['A', 'B', 'C'];
    for (int i = 0; i < paneCount; i++) {
      final String id = ids[i];
      out
        ..writeln('  [PANE:$id]')
        ..writeln(
          '    [CLIP:${id.toLowerCase()}:video/${id.toLowerCase()}.mp4:0:0:$durationFrames:1]',
        )
        ..writeln('    [/CLIP]')
        ..writeln('  [/PANE]');
    }
    out.writeln('[/MOSAIC]');
    return out.toString();
  }

  MosaicLayoutProgram programFor(
    String layoutLines, {
    int durationFrames = 1200,
    int paneCount = 3,
  }) {
    final String source = sourceFor(
      layoutLines,
      durationFrames: durationFrames,
      paneCount: paneCount,
    );
    final EditDocumentModel model = EditDocumentModel.parse(source);
    return MosaicLayoutProgram.fromMosaic(
      source: source,
      mosaic: model.mosaic('wall'),
    );
  }

  MosaicSplitWindowGeometry splitGeometry({
    MosaicSplitClientAspect aspect = MosaicSplitClientAspect.aspect16x9,
    bool maximized = false,
  }) =>
      mosaicSplitWindowGeometry(
        frame: programRect,
        aspect: aspect,
        titleHeight: titleHeight,
        maximized: maximized,
      );

  void expectAbsent(MosaicLayoutActorFrame actor) {
    expect(actor.presence, MosaicLayoutPresence.absent);
    expect(actor.activeSegment, isNull);
    expect(actor.rect, Rect.zero);
    expect(actor.opacity, 0.0);
  }

  void expectCanonical(
    MosaicLayoutFrame frame,
    MosaicLayoutState state, {
    Rect? compositeRect,
    double compositeChrome = 1.0,
  }) {
    final MosaicLayoutActorFrame composite = frame.composite;
    final MosaicLayoutActorFrame a = frame.pane('A');
    final MosaicLayoutActorFrame b = frame.pane('B');
    final MosaicLayoutActorFrame c = frame.pane('C');

    switch (state.kind) {
      case MosaicLayoutStateKind.composite:
        expect(composite.presence, MosaicLayoutPresence.present);
        expect(composite.activeSegment, isNull);
        expect(composite.rect, compositeRect ?? windowRect);
        expect(composite.opacity, 1.0);
        expect(composite.chrome, compositeChrome);
        expect(composite.z.band, MosaicLayoutZBand.stable);
        expectAbsent(a);
        expectAbsent(b);
        expectAbsent(c);
        break;

      case MosaicLayoutStateKind.twoUp:
        final MosaicSplitWindowGeometry geometry = splitGeometry(
          aspect: state.splitAspect,
          maximized: state.maximizeSplit,
        );
        expectAbsent(composite);
        expect(a.presence, MosaicLayoutPresence.present);
        expect(a.activeSegment, isNull);
        expect(a.rect, geometry.leftWindowRect);
        expect(a.opacity, 1.0);
        expect(a.chrome, 1.0);
        expect(a.z.band, MosaicLayoutZBand.stable);
        expect(a.z.roleRank, 0);
        expect(b.presence, MosaicLayoutPresence.present);
        expect(b.activeSegment, isNull);
        expect(b.rect, geometry.rightWindowRect);
        expect(b.opacity, 1.0);
        expect(b.chrome, 1.0);
        expect(b.z.band, MosaicLayoutZBand.stable);
        expect(b.z.roleRank, 1);
        expectAbsent(c);
        break;

      case MosaicLayoutStateKind.one:
        expectAbsent(composite);
        expect(a.presence, MosaicLayoutPresence.present);
        expect(a.activeSegment, isNull);
        expect(a.rect, windowRect);
        expect(a.opacity, 1.0);
        expect(a.chrome, 1.0);
        expect(a.z.band, MosaicLayoutZBand.stable);
        expectAbsent(b);
        expectAbsent(c);
        break;

      case MosaicLayoutStateKind.full:
        expectAbsent(composite);
        expect(a.presence, MosaicLayoutPresence.present);
        expect(a.activeSegment, isNull);
        expect(a.rect, programRect);
        expect(a.opacity, 1.0);
        expect(a.chrome, 0.0);
        expect(a.z.band, MosaicLayoutZBand.fullTarget);
        expectAbsent(b);
        expectAbsent(c);
        break;
    }
  }

  group('Family 1 - settled state transitions', () {
    final Map<String, MosaicLayoutState> states =
        <String, MosaicLayoutState>{
      'COMPOSITE': const MosaicLayoutState.composite(),
      'TWOUP': const MosaicLayoutState.twoUp(
        paneA: 'A',
        paneB: 'B',
      ),
      'ONE': const MosaicLayoutState.one('A'),
      'FULL': const MosaicLayoutState.full('A'),
    };

    for (final MapEntry<String, MosaicLayoutState> from in states.entries) {
      for (final MapEntry<String, MosaicLayoutState> to in states.entries) {
        if (from.key == to.key) continue;

        test('${from.key} -> ${to.key} canonicalizes to target', () {
          final String first = MosaicLayoutCue(
            frame: 100,
            state: from.value,
            durationFrames: 1,
          ).formatTag();
          final String second = MosaicLayoutCue(
            frame: 200,
            state: to.value,
            durationFrames: 12,
          ).formatTag();

          final MosaicResolvedLayoutProgram resolved =
              programFor('  $first\n  $second').resolve(context());

          expectCanonical(resolved.evaluate(100), from.value);
          expect(resolved.evaluate(200).actors.any(
            (MosaicLayoutActorFrame actor) => actor.activeSegment != null,
          ), isTrue);
          expectCanonical(resolved.evaluate(211), to.value);
        });
      }
    }

    test('TWOUP A/B -> A/C keeps A continuous and settles C in right slot', () {
      final MosaicResolvedLayoutProgram resolved = programFor('''
  [LAYOUT:100:TWOUP:A=A:B=B:DUR=1]
  [LAYOUT:200:TWOUP:A=A:B=C:DUR=12]''').resolve(context());

      final MosaicLayoutActorFrame a199 = resolved.evaluate(199).pane('A');
      final MosaicLayoutActorFrame a200 = resolved.evaluate(200).pane('A');
      expect(a199.activeSegment, isNull);
      expect(a200.activeSegment, isNull);
      expect(a200, a199);

      final MosaicLayoutFrame settled = resolved.evaluate(211);
      expect(settled.pane('A').rect, splitGeometry().leftWindowRect);
      expect(settled.pane('B').presence, MosaicLayoutPresence.absent);
      expect(settled.pane('C').presence, MosaicLayoutPresence.present);
      expect(settled.pane('C').rect, splitGeometry().rightWindowRect);
    });

    test('PR1 preserves settled transition CREATE/REDIRECT classification', () {
      final Map<String, Set<String>> expectedCreates = <String, Set<String>>{
        'COMPOSITE>TWOUP': <String>{'A', 'B'},
        'COMPOSITE>ONE': <String>{'A'},
        'COMPOSITE>FULL': <String>{'A'},
        'TWOUP>COMPOSITE': <String>{'COMPOSITE'},
        'TWOUP>ONE': <String>{},
        'TWOUP>FULL': <String>{},
        'ONE>COMPOSITE': <String>{'COMPOSITE'},
        'ONE>TWOUP': <String>{'B'},
        'ONE>FULL': <String>{},
        'FULL>COMPOSITE': <String>{'COMPOSITE'},
        'FULL>TWOUP': <String>{'B'},
        'FULL>ONE': <String>{},
      };
      final Map<String, Set<String>> expectedRedirects =
          <String, Set<String>>{
        'COMPOSITE>TWOUP': <String>{'COMPOSITE'},
        'COMPOSITE>ONE': <String>{'COMPOSITE'},
        'COMPOSITE>FULL': <String>{'COMPOSITE'},
        'TWOUP>COMPOSITE': <String>{'A', 'B'},
        'TWOUP>ONE': <String>{'A', 'B'},
        'TWOUP>FULL': <String>{'A', 'B'},
        'ONE>COMPOSITE': <String>{'A'},
        'ONE>TWOUP': <String>{'A'},
        'ONE>FULL': <String>{'A'},
        'FULL>COMPOSITE': <String>{'A'},
        'FULL>TWOUP': <String>{'A'},
        'FULL>ONE': <String>{'A'},
      };

      String actorKey(MosaicLayoutActorFrame actor) {
        if (actor.actorId.kind == MosaicLayoutActorKind.composite) {
          return 'COMPOSITE';
        }
        return actor.actorId.paneId!;
      }

      for (final MapEntry<String, MosaicLayoutState> from in states.entries) {
        for (final MapEntry<String, MosaicLayoutState> to in states.entries) {
          if (from.key == to.key) continue;
          final String key = '${from.key}>${to.key}';
          final String first = MosaicLayoutCue(
            frame: 100,
            state: from.value,
            durationFrames: 1,
          ).formatTag();
          final String second = MosaicLayoutCue(
            frame: 200,
            state: to.value,
            durationFrames: 12,
          ).formatTag();
          final MosaicLayoutFrame frame =
              programFor('  $first\n  $second')
                  .resolve(context())
                  .evaluate(200);

          final Set<String> creates = <String>{};
          final Set<String> redirects = <String>{};
          for (final MosaicLayoutActorFrame actor in frame.actors) {
            final MosaicLayoutActiveSegment? segment = actor.activeSegment;
            if (segment == null) continue;
            if (segment.startPresence == MosaicLayoutPresence.absent &&
                segment.targetPresence != MosaicLayoutPresence.absent) {
              creates.add(actorKey(actor));
            } else {
              redirects.add(actorKey(actor));
            }
          }

          expect(
            creates,
            expectedCreates[key],
            reason: '$key changed CREATE classification',
          );
          expect(
            redirects,
            expectedRedirects[key],
            reason: '$key changed REDIRECT classification',
          );
        }
      }
    });
  });

  group('Family 2 - geometry-only survivors', () {
    test('TWOUP normal -> MAX redirects both actors without entry/exit', () {
      final MosaicResolvedLayoutProgram resolved = programFor('''
  [LAYOUT:500:TWOUP:A=A:B=B:MAX:DUR=12]''').resolve(
        context(
          legacySeed: const MosaicLayoutState.twoUp(
            paneA: 'A',
            paneB: 'B',
          ),
        ),
      );

      final MosaicSplitWindowGeometry normal = splitGeometry();
      final MosaicSplitWindowGeometry maximized = splitGeometry(maximized: true);

      final MosaicLayoutActorFrame a = resolved.evaluate(500).pane('A');
      final MosaicLayoutActorFrame b = resolved.evaluate(500).pane('B');
      expect(a.presence, MosaicLayoutPresence.present);
      expect(b.presence, MosaicLayoutPresence.present);
      expect(a.activeSegment!.startPresence, MosaicLayoutPresence.present);
      expect(a.activeSegment!.targetPresence, MosaicLayoutPresence.present);
      expect(b.activeSegment!.startPresence, MosaicLayoutPresence.present);
      expect(b.activeSegment!.targetPresence, MosaicLayoutPresence.present);
      expect(a.activeSegment!.startRect, normal.leftWindowRect);
      expect(a.activeSegment!.targetRect, maximized.leftWindowRect);
      expect(b.activeSegment!.startRect, normal.rightWindowRect);
      expect(b.activeSegment!.targetRect, maximized.rightWindowRect);

      expect(resolved.evaluate(511).pane('A').rect, maximized.leftWindowRect);
      expect(resolved.evaluate(511).pane('B').rect, maximized.rightWindowRect);
    });

    test('FULL -> TWOUP MAX 4X3 settles exact split geometry and z', () {
      final MosaicResolvedLayoutProgram resolved = programFor('''
  [LAYOUT:100:FULL:PANE=A:DUR=1]
  [LAYOUT:500:TWOUP:A=A:B=B:MAX:ASPECT=4X3:DUR=12]''').resolve(context());

      final MosaicSplitWindowGeometry target = splitGeometry(
        aspect: MosaicSplitClientAspect.aspect4x3,
        maximized: true,
      );

      final MosaicLayoutFrame start = resolved.evaluate(500);
      expect(start.pane('A').activeSegment, isNotNull);
      expect(start.pane('A').activeSegment!.startRect, programRect);
      expect(start.pane('A').activeSegment!.targetRect, target.leftWindowRect);
      expect(start.pane('A').z.band, MosaicLayoutZBand.fullTarget);
      expect(start.pane('B').presence, MosaicLayoutPresence.entering);

      final MosaicLayoutFrame settled = resolved.evaluate(511);
      expect(settled.pane('A').activeSegment, isNull);
      expect(settled.pane('B').activeSegment, isNull);
      expect(settled.pane('A').rect, target.leftWindowRect);
      expect(settled.pane('B').rect, target.rightWindowRect);
      expect(settled.pane('A').z.band, MosaicLayoutZBand.stable);
      expect(settled.pane('B').z.band, MosaicLayoutZBand.stable);
      expect(settled.pane('A').z.roleRank, 0);
      expect(settled.pane('B').z.roleRank, 1);
      expect(settled.paintActors.last.actorId.paneId, 'B');
    });

    test('TWOUP 16X9 -> 4X3 redirects both actors only by geometry', () {
      final MosaicResolvedLayoutProgram resolved = programFor('''
  [LAYOUT:500:TWOUP:A=A:B=B:ASPECT=4X3:DUR=12]''').resolve(
        context(
          legacySeed: const MosaicLayoutState.twoUp(
            paneA: 'A',
            paneB: 'B',
          ),
        ),
      );

      final MosaicSplitWindowGeometry oldGeometry = splitGeometry();
      final MosaicSplitWindowGeometry newGeometry =
          splitGeometry(aspect: MosaicSplitClientAspect.aspect4x3);

      final MosaicLayoutActorFrame a = resolved.evaluate(500).pane('A');
      final MosaicLayoutActorFrame b = resolved.evaluate(500).pane('B');
      expect(a.presence, MosaicLayoutPresence.present);
      expect(b.presence, MosaicLayoutPresence.present);
      expect(a.activeSegment!.startRect, oldGeometry.leftWindowRect);
      expect(a.activeSegment!.targetRect, newGeometry.leftWindowRect);
      expect(b.activeSegment!.startRect, oldGeometry.rightWindowRect);
      expect(b.activeSegment!.targetRect, newGeometry.rightWindowRect);
      expect(resolved.evaluate(511).pane('A').rect, newGeometry.leftWindowRect);
      expect(resolved.evaluate(511).pane('B').rect, newGeometry.rightWindowRect);
    });
  });

  group('Family 4 - duration edges', () {
    for (final int duration in <int>[0, 1]) {
      test('D=$duration canonicalizes immediately at cue frame', () {
        final MosaicResolvedLayoutProgram resolved = programFor(
          '  [LAYOUT:500:ONE:PANE=A:DUR=$duration]',
        ).resolve(context());

        final MosaicLayoutFrame frame = resolved.evaluate(500);
        expectCanonical(frame, const MosaicLayoutState.one('A'));
      });
    }

    for (final int duration in <int>[11, 12]) {
      test('D=$duration keeps band midpoint while FULL target owns front',
          () {
        final int switchFrame = 500 + duration ~/ 2;
        final int endFrame = 500 + duration - 1;
        final MosaicResolvedLayoutProgram resolved = programFor('''
  [LAYOUT:100:ONE:PANE=A:DUR=1]
  [LAYOUT:500:FULL:PANE=A:DUR=$duration]''').resolve(context());

        final MosaicLayoutActorFrame start = resolved.evaluate(500).pane('A');
        expect(start.activeSegment, isNotNull);
        expect(start.activeSegment!.zSwitchFrame, switchFrame);
        expect(start.activeSegment!.endFrame, endFrame);
        expect(start.activeSegment!.startZ.band, MosaicLayoutZBand.stable);
        expect(start.activeSegment!.targetZ.band, MosaicLayoutZBand.fullTarget);
        expect(start.activeSegment!.startDominant, isTrue);
        expect(start.activeSegment!.targetDominant, isTrue);
        expect(start.dominantMorphPriority, 2);

        // Dominance owns focal front-layer semantics. Band keeps its ordinary
        // midpoint transition and no longer carries the FULL-specific hold.
        expect(start.z.band, MosaicLayoutZBand.stable);
        expect(
          resolved.evaluate(switchFrame - 1).pane('A').z.band,
          MosaicLayoutZBand.stable,
        );
        expect(
          resolved.evaluate(switchFrame).pane('A').z.band,
          MosaicLayoutZBand.fullTarget,
        );
        expect(resolved.evaluate(endFrame).pane('A').activeSegment, isNull);
        expect(
          resolved.evaluate(endFrame).pane('A').dominantMorphPriority,
          0,
        );
        expect(resolved.evaluate(endFrame).pane('A').z.band,
            MosaicLayoutZBand.fullTarget);
      });
    }

    test('no-op cue DUR does not re-time continuing actors', () {
      final MosaicResolvedLayoutProgram resolved = programFor('''
  [LAYOUT:500:TWOUP:A=A:B=B:DUR=20]
  [LAYOUT:505:TWOUP:A=A:B=B:DUR=4]''').resolve(context());

      final MosaicLayoutActiveSegment? a500 =
          resolved.evaluate(500).pane('A').activeSegment;
      final MosaicLayoutActiveSegment? a505 =
          resolved.evaluate(505).pane('A').activeSegment;
      expect(a500, isNotNull);
      expect(a505, a500);
      expect(a505!.startFrame, 500);
      expect(a505.durationFrames, 20);
      expect(
        resolved.issues.any(
          (MosaicLayoutIssue issue) =>
              issue.code == MosaicLayoutIssueCode.noEffect &&
              issue.frame == 505,
        ),
        isTrue,
      );
    });
  });

  group('Family 5 - source boundaries', () {
    test('MOSAIC end truncates a transition without extending duration', () {
      final MosaicLayoutProgram program = programFor(
        '  [LAYOUT:500:FULL:PANE=A:DUR=12]',
        durationFrames: 506,
      );
      final MosaicResolvedLayoutProgram resolved = program.resolve(context());

      expect(program.projectFrameCount, 506);
      final MosaicLayoutActorFrame last = resolved.evaluate(505).pane('A');
      expect(last.activeSegment, isNotNull);
      expect(last.activeSegment!.startFrame, 500);
      expect(last.activeSegment!.endFrame, 511);
      expect(last.rect, isNot(programRect));
    });

    test('mid-transition in-point observes original segment instead of restart', () {
      final MosaicResolvedLayoutProgram resolved = programFor('''
  [LAYOUT:500:TWOUP:A=A:B=B:DUR=20]''').resolve(context());

      final MosaicLayoutActorFrame atInPoint = resolved.evaluate(507).pane('A');
      expect(atInPoint.activeSegment, isNotNull);
      expect(atInPoint.activeSegment!.startFrame, 500);
      expect(atInPoint.activeSegment!.durationFrames, 20);
    });
  });

  group('Family 7 - validation and lookup', () {

    test('frame-zero cue is canonical immediately and overrides legacy seed', () {
      final MosaicResolvedLayoutProgram resolved = programFor('''
  [LAYOUT:0:FULL:PANE=A:DUR=12]''').resolve(
        context(
          legacySeed: const MosaicLayoutState.twoUp(
            paneA: 'A',
            paneB: 'B',
          ),
        ),
      );

      final MosaicLayoutFrame frame = resolved.evaluate(0);
      expectCanonical(frame, const MosaicLayoutState.full('A'));
      expect(frame.pane('A').activeSegment, isNull);
      expect(frame.pane('B').presence, MosaicLayoutPresence.absent);
    });

    test('duplicate cue frame is an evaluator error', () {
      final String source = sourceFor('''
  [LAYOUT:10:ONE:PANE=A]
  [LAYOUT:10:FULL:PANE=A]''');
      final EditDocumentModel model = EditDocumentModel.parse(source);
      expect(
        () => MosaicLayoutProgram.fromMosaic(
          source: source,
          mosaic: model.mosaic('wall'),
        ),
        throwsStateError,
      );
    });

    test('unknown pane is an evaluator error', () {
      final String source = sourceFor(
        '  [LAYOUT:10:ONE:PANE=missing]',
      );
      final EditDocumentModel model = EditDocumentModel.parse(source);
      expect(
        () => MosaicLayoutProgram.fromMosaic(
          source: source,
          mosaic: model.mosaic('wall'),
        ),
        throwsStateError,
      );
    });

    test('bare TWOUP with fewer than two panes is an evaluator error', () {
      final String source = sourceFor(
        '  [LAYOUT:10:TWOUP]',
        paneCount: 1,
      );
      final EditDocumentModel model = EditDocumentModel.parse(source);
      expect(
        () => MosaicLayoutProgram.fromMosaic(
          source: source,
          mosaic: model.mosaic('wall'),
        ),
        throwsStateError,
      );
    });

    test('dead cue remains parseable and reports a warning', () {
      final MosaicLayoutProgram program = programFor(
        '  [LAYOUT:100:ONE:PANE=A]',
        durationFrames: 100,
      );
      expect(
        program.sourceIssues.any(
          (MosaicLayoutIssue issue) =>
              issue.code == MosaicLayoutIssueCode.deadCue &&
              issue.severity == MosaicLayoutIssueSeverity.warning,
        ),
        isTrue,
      );
    });

    test('lookahead reports hidden panes that will reappear', () {
      final MosaicResolvedLayoutProgram resolved = programFor('''
  [LAYOUT:500:TWOUP:A=A:B=B:DUR=12]
  [LAYOUT:700:ONE:PANE=A:DUR=12]
  [LAYOUT:900:TWOUP:A=A:B=C:DUR=12]''').resolve(context());

      expect(resolved.nextAppearanceFrame('A', afterFrame: 400), 500);
      expect(resolved.nextAppearanceFrame('B', afterFrame: 400), 500);
      expect(resolved.nextAppearanceFrame('C', afterFrame: 400), 900);
      expect(
        resolved.paneIdsEnteringBetween(
          afterFrame: 800,
          throughFrame: 950,
        ),
        <String>{'C'},
      );
    });

    test('mixed-age actors still have unique lexicographic z tuples', () {
      final MosaicResolvedLayoutProgram resolved = programFor('''
  [LAYOUT:500:TWOUP:A=A:B=B:DUR=20]
  [LAYOUT:505:TWOUP:A=A:B=C:DUR=4]
  [LAYOUT:507:FULL:PANE=A:DUR=12]''').resolve(context());

      final List<MosaicLayoutActorFrame> actors =
          resolved.evaluate(507).paintActors;
      final Set<String> zValues =
          actors.map((MosaicLayoutActorFrame actor) => actor.z.toString()).toSet();
      expect(zValues, hasLength(actors.length));
    });
  });
}
