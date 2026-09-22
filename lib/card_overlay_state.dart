// ./lib/card_overlay_state.dart
//
// Explicit-time CARD-family placement state for structural video.
//
// This file deliberately owns selection and lifetime projection only. It does
// not load images or paint pixels. Keeping placement state separate from
// card_overlay.dart means future presentations can add timing/choreography
// without turning the painter into another presentation engine.

import 'dart:ui';

import 'edit_cue.dart';
import 'edit_model.dart';
import 'mosaic_layout.dart';
import 'presentation_requests.dart';

/// One active CARD-family presentation plus the structural pixel region it owns.
class StructuralCardOverlayPlacement {
  const StructuralCardOverlayPlacement({
    required this.card,
    required this.slide,
    required this.normalizedRect,
  });

  final CardRequest card;
  final double slide;

  bool get isSideCard => card is SideCardRequest;

  /// Target rectangle in 0..1 coordinates of the structural render surface.
  /// An EDIT owns the whole surface. A MOSAIC pane owns only its pane.
  final Rect normalizedRect;
}

/// CARD-family presentations active at [projectFrame] for one selected
/// structural root.
///
/// Authored order is preserved. Later placements are painted later and
/// therefore appear on top, matching edit_cue.dart's deterministic rule.
List<StructuralCardOverlayPlacement> structuralCardOverlayPlacements(
  EditDocumentModel model,
  StructuralSourceRef root,
  int projectFrame,
) {
  switch (root.kind) {
    case StructuralSourceKind.edit:
      final List<ActiveEditCardCue> active =
          activeCardCuesForEdit(model.edit(root.id), projectFrame);
      return List<StructuralCardOverlayPlacement>.unmodifiable(
        active.map(
          (ActiveEditCardCue cue) => StructuralCardOverlayPlacement(
            card: cue.cue.card,
            slide: cue.presentationFrame.slide,
            normalizedRect: const Rect.fromLTWH(0, 0, 1, 1),
          ),
        ),
      );

    case StructuralSourceKind.mosaic:
      final MosaicSequence mosaic = model.mosaic(root.id);
      final List<Rect> layout = mosaicPaneLayout(mosaic.panes.length);
      final List<StructuralCardOverlayPlacement> result =
          <StructuralCardOverlayPlacement>[];
      for (int i = 0; i < mosaic.panes.length; i++) {
        final MosaicPane pane = mosaic.panes[i];
        final Rect paneRect = layout[i];
        for (final ActiveEditCardCue cue
            in activeCardCuesForPane(pane, projectFrame)) {
          result.add(
            StructuralCardOverlayPlacement(
              card: cue.cue.card,
              slide: cue.presentationFrame.slide,
              normalizedRect: paneRect,
            ),
          );
        }
      }
      return List<StructuralCardOverlayPlacement>.unmodifiable(result);
  }
}

/// CARD-family placements for one authored MOSAIC pane, expressed in the
/// pane's own 0..1 client coordinates.
///
/// SPLIT presents each authored pane as an independent client. Reusing the
/// ordinary MOSAIC normalized layout here would shrink a CARD into its old
/// grid cell a second time, so the top-level pane expands to the complete split
/// client.
///
/// Unlike the legacy root-level overlay lookup, this path follows structural
/// CLIPs recursively. A normal MOSAIC pane usually points at EDIT.foo, and the
/// CARD is commonly authored on a media CLIP inside that EDIT. The nested frame
/// is projected with the parent CLIP's exact AT/IN/speed mapping so presentation
/// time follows the same source frame the compositor is rendering.
List<StructuralCardOverlayPlacement>
    structuralCardOverlayPlacementsForMosaicPane(
  EditDocumentModel model,
  StructuralSourceRef root,
  int paneIndex,
  int projectFrame,
) {
  if (root.kind != StructuralSourceKind.mosaic) {
    return const <StructuralCardOverlayPlacement>[];
  }

  final MosaicSequence mosaic = model.mosaic(root.id);
  if (paneIndex < 0 || paneIndex >= mosaic.panes.length) {
    throw RangeError.range(
      paneIndex,
      0,
      mosaic.panes.length - 1,
      'paneIndex',
    );
  }

  final MosaicPane pane = mosaic.panes[paneIndex];
  if (projectFrame < 0 || projectFrame >= pane.projectFrameCount) {
    return const <StructuralCardOverlayPlacement>[];
  }

  final List<StructuralCardOverlayPlacement> result =
      <StructuralCardOverlayPlacement>[];
  const Rect client = Rect.fromLTWH(0, 0, 1, 1);

  _appendActiveCards(
    result,
    activeCardCuesForPane(pane, projectFrame),
    client,
  );
  _appendNestedCardsFromClips(
    model,
    pane.clips,
    projectFrame,
    client,
    result,
    <StructuralSourceRef>{root},
    1,
  );

  return List<StructuralCardOverlayPlacement>.unmodifiable(result);
}

void _appendActiveCards(
  List<StructuralCardOverlayPlacement> output,
  Iterable<ActiveEditCardCue> active,
  Rect target,
) {
  for (final ActiveEditCardCue cue in active) {
    output.add(
      StructuralCardOverlayPlacement(
        card: cue.cue.card,
        slide: cue.presentationFrame.slide,
        normalizedRect: target,
      ),
    );
  }
}

void _appendNestedCardsFromClips(
  EditDocumentModel model,
  Iterable<EditClip> clips,
  int projectFrame,
  Rect target,
  List<StructuralCardOverlayPlacement> output,
  Set<StructuralSourceRef> path,
  int depth,
) {
  if (depth >= 8) return;

  for (final EditClip clip in clips) {
    if (projectFrame < clip.atFrame ||
        projectFrame >= clip.endFrameExclusive) {
      continue;
    }

    final StructuralSourceRef? nested =
        StructuralSourceRef.tryParse(clip.source);
    if (nested == null ||
        nested.id.isEmpty ||
        !model.containsStructuralSource(nested) ||
        path.contains(nested)) {
      continue;
    }

    final int nestedFrame = clip.sourceFrameAtProjectOffset(
      projectFrame - clip.atFrame,
    );
    _appendCardsForStructuralSource(
      model,
      nested,
      nestedFrame,
      target,
      output,
      <StructuralSourceRef>{...path, nested},
      depth + 1,
    );
  }
}

void _appendCardsForStructuralSource(
  EditDocumentModel model,
  StructuralSourceRef root,
  int projectFrame,
  Rect target,
  List<StructuralCardOverlayPlacement> output,
  Set<StructuralSourceRef> path,
  int depth,
) {
  // The structural compositor and graph linter both allow depth eight.
  // Process that level, but _appendNestedCardsFromClips will not descend to
  // a ninth source.
  if (depth > 8 || projectFrame < 0) return;

  switch (root.kind) {
    case StructuralSourceKind.edit:
      final EditSequence edit = model.edit(root.id);
      if (projectFrame >= edit.projectFrameCount) return;

      _appendActiveCards(
        output,
        activeCardCuesForEdit(edit, projectFrame),
        target,
      );
      _appendNestedCardsFromClips(
        model,
        edit.tracks.expand((EditTrack track) => track.clips),
        projectFrame,
        target,
        output,
        path,
        depth,
      );
      return;

    case StructuralSourceKind.mosaic:
      final MosaicSequence mosaic = model.mosaic(root.id);
      if (projectFrame >= mosaic.projectFrameCount) return;

      final List<Rect> layout = mosaicPaneLayout(mosaic.panes.length);
      for (int i = 0; i < mosaic.panes.length; i++) {
        final MosaicPane pane = mosaic.panes[i];
        final Rect paneTarget = _mapRectInto(target, layout[i]);
        _appendActiveCards(
          output,
          activeCardCuesForPane(pane, projectFrame),
          paneTarget,
        );
        _appendNestedCardsFromClips(
          model,
          pane.clips,
          projectFrame,
          paneTarget,
          output,
          path,
          depth,
        );
      }
      return;
  }
}

Rect _mapRectInto(Rect parent, Rect child) {
  return Rect.fromLTRB(
    parent.left + child.left * parent.width,
    parent.top + child.top * parent.height,
    parent.left + child.right * parent.width,
    parent.top + child.bottom * parent.height,
  );
}

/// The active SIDECARD that owns the outer structural presentation shell.
///
/// V1 deliberately allows only one shell composition at a time. If authored
/// cues overlap, later authored order wins, matching the existing CARD paint
/// rule without inventing z-order controls.
StructuralCardOverlayPlacement? structuralSideCardPlacement(
  EditDocumentModel model,
  StructuralSourceRef root,
  int projectFrame,
) {
  StructuralCardOverlayPlacement? selected;
  for (final StructuralCardOverlayPlacement placement
      in structuralCardOverlayPlacements(model, root, projectFrame)) {
    if (placement.isSideCard && placement.slide > 0.0) selected = placement;
  }
  return selected;
}

/// SIDECARD shell state on the final authored source frame.
///
/// A CUE presentation is clipped by its containing EDIT/PANE. If the source
/// ends while SIDECARD is still open or closing, the card itself disappears at
/// the boundary, but STRUCT may use this final slide value as the origin for its
/// own closing motion. That prevents the real video window from snapping back
/// to its pre-cue position for one frame before the structural app closes.
StructuralCardOverlayPlacement? structuralSideCardPlacementAtSourceEnd(
  EditDocumentModel model,
  StructuralSourceRef root,
  int sourceDurationFrames,
) {
  if (sourceDurationFrames <= 0) return null;
  return structuralSideCardPlacement(
    model,
    root,
    sourceDurationFrames - 1,
  );
}

