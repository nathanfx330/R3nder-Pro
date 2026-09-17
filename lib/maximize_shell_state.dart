// ./lib/maximize_shell_state.dart
//
// Explicit-time shell state for clip-local MAXIMIZE cues.
//
// MAXIMIZE owns no pixels and no desktop coordinates. This file projects the
// source-relative EDIT cue onto one structural source frame. STRUCT later turns
// the resulting 0..1 amount into window geometry.

import 'edit_cue.dart';
import 'edit_model.dart';
import 'maximize_presentation.dart';

class StructuralMaximizePlacement {
  const StructuralMaximizePlacement({
    required this.cue,
    required this.frame,
    required this.triggerProjectFrame,
  });

  final EditMaximizeCue cue;
  final MaximizePresentationFrame frame;
  final int triggerProjectFrame;

  double get amount => frame.amount;
}

/// Returns the shell-only MAXIMIZE state for an EDIT root at [projectFrame].
///
/// V1 deliberately ignores MAXIMIZE authored inside MOSAIC panes. A pane owns
/// pixels within the MOSAIC composition, not the geometry of the one outer
/// structural application window.
///
/// If multiple MAXIMIZE cues overlap, later traversal order wins. This mirrors
/// the existing deterministic shell selection rule for SIDECARD without adding
/// z-order or shell-track concepts.
StructuralMaximizePlacement? structuralMaximizePlacement(
  EditDocumentModel model,
  StructuralSourceRef root,
  int projectFrame,
) {
  if (root.kind != StructuralSourceKind.edit) return null;

  StructuralMaximizePlacement? selected;
  for (final ActiveEditMaximizeCue active
      in activeMaximizeCuesForEdit(model.edit(root.id), projectFrame)) {
    selected = StructuralMaximizePlacement(
      cue: active.cue,
      frame: active.presentationFrame,
      triggerProjectFrame: active.triggerProjectFrame,
    );
  }
  return selected;
}

/// MAXIMIZE state on the final authored source frame.
///
/// If the structural source ends before the cue returns to its normal seat,
/// STRUCT uses this amount to begin its own closing choreography from the exact
/// final MAXIMIZE rectangle instead of snapping the video window back first.
StructuralMaximizePlacement? structuralMaximizePlacementAtSourceEnd(
  EditDocumentModel model,
  StructuralSourceRef root,
  int sourceDurationFrames,
) {
  if (sourceDurationFrames <= 0) return null;
  return structuralMaximizePlacement(
    model,
    root,
    sourceDurationFrames - 1,
  );
}
