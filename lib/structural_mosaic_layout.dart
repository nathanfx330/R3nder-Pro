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

  Rect transformedRect(MosaicLayoutActorFrame actor) {
    return switch (stage) {
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
    };
  }

  return MosaicLayoutFrame(
    sourceFrame: frame.sourceFrame,
    actors: <MosaicLayoutActorFrame>[
      for (final MosaicLayoutActorFrame actor in frame.actors)
        if (actor.presence == MosaicLayoutPresence.absent)
          actor
        else
          (() {
            final Rect nextRect = transformedRect(actor);
            return MosaicLayoutActorFrame(
              actorId: actor.actorId,
              presence: actor.presence,
              rect: nextRect,
              opacity: actor.opacity * opacity,
              labelRect: _mapCompanionRect(
                actor.labelRect,
                from: actor.rect,
                to: nextRect,
              ),
              labelOpacity: actor.labelOpacity * opacity,
              chrome: actor.chrome,
              z: actor.z,
              activeSegment: actor.activeSegment,
            );
          })(),
    ],
  );
}

Rect _mapCompanionRect(
  Rect rect, {
  required Rect from,
  required Rect to,
}) {
  if (rect == Rect.zero || from.width == 0.0 || from.height == 0.0) {
    return rect;
  }
  final double scaleX = to.width / from.width;
  final double scaleY = to.height / from.height;
  return Rect.fromLTRB(
    to.left + (rect.left - from.left) * scaleX,
    to.top + (rect.top - from.top) * scaleY,
    to.left + (rect.right - from.left) * scaleX,
    to.top + (rect.bottom - from.top) * scaleY,
  );
}

Map<MosaicLayoutActorId, String> structuralMosaicLayoutWindowTitles({
  required MosaicLayoutFrame frame,
  required StructuralSequencePlacement placement,
}) {
  final Map<MosaicLayoutActorId, String> titles =
      <MosaicLayoutActorId, String>{
    for (final MosaicLayoutActorFrame actor in frame.paintActors)
      actor.actorId: placement.effectiveWindowTitle,
  };

  if (!placement.showPaneNames) return titles;

  final List<MosaicLayoutActorFrame> paneActors = frame.paintActors
      .where(
        (MosaicLayoutActorFrame actor) =>
            actor.actorId.kind == MosaicLayoutActorKind.pane,
      )
      .toList(growable: false);
  if (paneActors.length != 2) return titles;

  Rect slotRect(MosaicLayoutActorFrame actor) {
    final MosaicLayoutActiveSegment? segment = actor.activeSegment;
    if (segment == null) return actor.rect;
    if (actor.presence == MosaicLayoutPresence.exiting) {
      return segment.anchorRect;
    }
    return segment.targetRect;
  }

  final List<MosaicLayoutActorFrame> ordered =
      List<MosaicLayoutActorFrame>.from(paneActors)
        ..sort((MosaicLayoutActorFrame a, MosaicLayoutActorFrame b) {
          final Rect ar = slotRect(a);
          final Rect br = slotRect(b);
          final int byX = ar.center.dx.compareTo(br.center.dx);
          if (byX != 0) return byX;
          final int byY = ar.center.dy.compareTo(br.center.dy);
          if (byY != 0) return byY;
          return a.actorId.actorOrdinal.compareTo(b.actorId.actorOrdinal);
        });

  for (int slot = 0; slot < ordered.length && slot < 2; slot++) {
    titles[ordered[slot].actorId] = placement.windowTitleForSlot(slot);
  }
  return titles;
}

Map<MosaicLayoutActorId, String> structuralMosaicLayoutPaneLabels({
  required MosaicLayoutFrame frame,
  required StructuralSequencePlacement placement,
}) {
  if (!placement.showPaneNames) {
    return const <MosaicLayoutActorId, String>{};
  }

  final List<MosaicLayoutActorFrame> panes = frame.actors
      .where(
        (MosaicLayoutActorFrame actor) =>
            actor.actorId.kind == MosaicLayoutActorKind.pane,
      )
      .toList(growable: false);

  List<MosaicLayoutActorFrame> orderedBy(
    bool Function(MosaicLayoutActorFrame actor) include,
    Rect Function(MosaicLayoutActorFrame actor) rectFor,
  ) {
    final List<MosaicLayoutActorFrame> out =
        panes.where(include).toList(growable: false)
          ..sort((MosaicLayoutActorFrame a, MosaicLayoutActorFrame b) {
            final Rect ar = rectFor(a);
            final Rect br = rectFor(b);
            final int byX = ar.center.dx.compareTo(br.center.dx);
            if (byX != 0) return byX;
            return a.actorId.actorOrdinal.compareTo(b.actorId.actorOrdinal);
          });
    return out;
  }

  final List<MosaicLayoutActorFrame> targetLabels = orderedBy(
    (MosaicLayoutActorFrame actor) {
      final MosaicLayoutActiveSegment? segment = actor.activeSegment;
      return segment == null
          ? actor.labelOpacity > 0.0
          : segment.targetLabelOpacity > 0.0;
    },
    (MosaicLayoutActorFrame actor) =>
        actor.activeSegment?.targetLabelRect ?? actor.labelRect,
  );
  final List<MosaicLayoutActorFrame> startLabels = orderedBy(
    (MosaicLayoutActorFrame actor) {
      final MosaicLayoutActiveSegment? segment = actor.activeSegment;
      return segment != null && segment.startLabelOpacity > 0.0;
    },
    (MosaicLayoutActorFrame actor) =>
        actor.activeSegment?.startLabelRect ?? actor.labelRect,
  );

  final Map<MosaicLayoutActorId, String> out =
      <MosaicLayoutActorId, String>{};
  for (int slot = 0; slot < targetLabels.length; slot++) {
    out[targetLabels[slot].actorId] = placement.paneNameForSlot(slot);
  }
  for (int slot = 0; slot < startLabels.length; slot++) {
    out.putIfAbsent(
      startLabels[slot].actorId,
      () => placement.paneNameForSlot(slot),
    );
  }
  return Map<MosaicLayoutActorId, String>.unmodifiable(out);
}

