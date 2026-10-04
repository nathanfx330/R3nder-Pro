// ./lib/structural_mosaic_layout.dart
//
// Shared adapter between authored MOSAIC layout semantics and one STRUCT
// placement. Preview and BAKE both use these helpers so placement geometry and
// outer-shell composition cannot drift.

import 'dart:ui';

import 'mosaic_layout_cue.dart';
import 'mosaic_layout_program.dart';
import 'structural_sequence.dart';
import 'structural_shell_geometry.dart';

MosaicLayoutEvaluationContext structuralMosaicLayoutContext({
  required Rect programRect,
  required StructuralSequencePlacement placement,
  required MosaicLayoutProgram program,
  required double chromeScale,
}) {
  final double titleHeight = 38.0 * chromeScale;
  final Rect ordinaryWindowRect = structuralWindowTargetRect(
    programRect,
    titleHeight: titleHeight,
  );

  MosaicLayoutState? legacySeed;
  if (placement.splitWindow && program.paneIds.length >= 2) {
    legacySeed = MosaicLayoutState.twoUp(
      paneA: program.paneIds[0],
      paneB: program.paneIds[1],
      aspect: placement.splitClientAspect,
      maximized: placement.maximizeSplit,
    );
  }

  return MosaicLayoutEvaluationContext(
    programRect: programRect,
    ordinaryWindowRect: ordinaryWindowRect,
    compositeRect: placement.fullscreen ? programRect : ordinaryWindowRect,
    compositeChrome: placement.fullscreen ? 0.0 : 1.0,
    titleHeight: titleHeight,
    legacySeed: legacySeed,
  );
}

MosaicLayoutFrame structuralMosaicLayoutOuterFrame({
  required MosaicLayoutFrame frame,
  required StructuralSequenceStage stage,
  required double stageProgress,
  required double shellOpacity,
}) {
  final double opacity = shellOpacity.clamp(0.0, 1.0).toDouble();
  final double linear = stageProgress.clamp(0.0, 1.0).toDouble();

  return MosaicLayoutFrame(
    sourceFrame: frame.sourceFrame,
    actors: <MosaicLayoutActorFrame>[
      for (final MosaicLayoutActorFrame actor in frame.actors)
        if (actor.presence == MosaicLayoutPresence.absent)
          actor
        else
          MosaicLayoutActorFrame(
            actorId: actor.actorId,
            presence: actor.presence,
            rect: switch (stage) {
              StructuralSequenceStage.opening => structuralShapeEntryFrameAt(
                  targetRect: actor.rect,
                  linearProgress: linear,
                  contentReady: true,
                ).rect,
              StructuralSequenceStage.closing => structuralShapeExitRectAt(
                  targetRect: actor.rect,
                  linearProgress: linear,
                ),
              _ => actor.rect,
            },
            opacity: actor.opacity * opacity,
            chrome: actor.chrome,
            z: actor.z,
            activeSegment: actor.activeSegment,
          ),
    ],
  );
}
