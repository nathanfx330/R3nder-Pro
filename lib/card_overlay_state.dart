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
      final List<Rect> layout = _mosaicLayout(mosaic.panes.length);
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

List<Rect> _mosaicLayout(int count) {
  if (count <= 0) return const <Rect>[];
  if (count == 1) return const <Rect>[Rect.fromLTRB(0, 0, 1, 1)];
  if (count == 2) {
    return const <Rect>[
      Rect.fromLTRB(0, 0, 0.56, 1),
      Rect.fromLTRB(0.56, 0, 1, 1),
    ];
  }
  return const <Rect>[
    Rect.fromLTRB(0, 0, 0.56, 1),
    Rect.fromLTRB(0.56, 0, 1, 0.5),
    Rect.fromLTRB(0.56, 0.5, 1, 1),
  ];
}
