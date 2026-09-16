// ./lib/dossier_overlay_state.dart
//
// Explicit-time DOSSIER placement state for continuously-playing structural
// video. This file owns cue selection and timing projection only. Asset lookup
// and painting live in dossier_overlay.dart; outer video-window geometry remains
// owned by sidecard_geometry.dart.

import 'dart:ui';

import 'dossier_presentation.dart';
import 'edit_cue.dart';
import 'edit_model.dart';
import 'presentation_requests.dart';
import 'scene_engine.dart';

/// One DOSSIER presentation active at an exact structural source frame.
class StructuralDossierOverlayPlacement {
  const StructuralDossierOverlayPlacement({
    required this.dossier,
    required this.localFrame,
    required this.presentationFrame,
    required this.centerPageCount,
    required this.normalizedRect,
  });

  final DossierRequest dossier;
  final int localFrame;
  final DossierPresentationFrame presentationFrame;
  final int centerPageCount;

  /// Region of the structural source that owned the trigger. The outer DOSSIER
  /// shell is still a program-level sibling composition, just like SIDECARD;
  /// this rect is retained for deterministic authored-order selection and future
  /// pane-local presentation work.
  final Rect normalizedRect;
}

/// Builds the one timing authority used by structural DOSSIER Preview and BAKE.
DossierPresentationTiming structuralDossierTiming(
  DossierRequest request, {
  required int centerPageCount,
}) {
  return DossierPresentationTiming.fromRequest(
    request,
    centerPageCount: centerPageCount,
    cardSlideFrames: kCardSlideFrames,
    windowAnimFrames: kWindowAnimFrames,
    mosaicPanFrames: kAppPanFrames,
  );
}

/// DOSSIER shell displacement expressed in the same 0..1 coordinate consumed
/// by sidecard_geometry.dart. The structural video enters the left seat with
/// the biography card and remains there while evidence replaces the right-hand
/// panel. During DOSSIER's own close it returns continuously to its pre-cue
/// window instead of waiting for STRUCT to end.
double structuralDossierShellSlide(StructuralDossierOverlayPlacement placement) {
  final DossierPresentationFrame frame = placement.presentationFrame;
  switch (frame.stage) {
    case DossierPresentationStage.opening:
      return frame.progress;
    case DossierPresentationStage.cardLead:
    case DossierPresentationStage.galleryOpening:
    case DossierPresentationStage.splitShowing:
    case DossierPresentationStage.centerTransition:
    case DossierPresentationStage.centerShowing:
    case DossierPresentationStage.centerPanning:
      return 1.0;
    case DossierPresentationStage.closing:
      return 1.0 - frame.progress;
  }
}

/// Resolve one active DOSSIER for the outer structural shell.
///
/// [centerPageCountFor] is intentionally supplied by the asset-backed caller.
/// CUE parsing cannot know how many files currently exist in an evidence
/// folder, while a mosaic's exact lifetime does depend on that count. Later
/// authored active cues win, matching CARD/SIDECARD's deterministic z-order.
StructuralDossierOverlayPlacement? structuralDossierPlacement(
  EditDocumentModel model,
  StructuralSourceRef root,
  int projectFrame, {
  required int Function(DossierRequest request) centerPageCountFor,
}) {
  StructuralDossierOverlayPlacement? selected;

  switch (root.kind) {
    case StructuralSourceKind.edit:
      for (final ActiveEditDossierCue active
          in activeDossierCuesForEdit(model.edit(root.id), projectFrame)) {
        final int pages = centerPageCountFor(active.cue.dossier);
        final DossierPresentationFrame? frame = structuralDossierTiming(
          active.cue.dossier,
          centerPageCount: pages,
        ).frameAt(active.localFrame);
        if (frame == null) continue;
        selected = StructuralDossierOverlayPlacement(
          dossier: active.cue.dossier,
          localFrame: active.localFrame,
          presentationFrame: frame,
          centerPageCount: pages,
          normalizedRect: const Rect.fromLTWH(0, 0, 1, 1),
        );
      }
      break;

    case StructuralSourceKind.mosaic:
      final MosaicSequence mosaic = model.mosaic(root.id);
      final List<Rect> layout = _mosaicLayout(mosaic.panes.length);
      for (int i = 0; i < mosaic.panes.length; i++) {
        for (final ActiveEditDossierCue active
            in activeDossierCuesForPane(mosaic.panes[i], projectFrame)) {
          final int pages = centerPageCountFor(active.cue.dossier);
          final DossierPresentationFrame? frame = structuralDossierTiming(
            active.cue.dossier,
            centerPageCount: pages,
          ).frameAt(active.localFrame);
          if (frame == null) continue;
          selected = StructuralDossierOverlayPlacement(
            dossier: active.cue.dossier,
            localFrame: active.localFrame,
            presentationFrame: frame,
            centerPageCount: pages,
            normalizedRect: layout[i],
          );
        }
      }
      break;
  }

  return selected;
}

/// Final authored source-frame DOSSIER state used when STRUCT itself closes
/// before the presentation naturally finishes. The right-hand panel is clipped
/// by source lifetime, while STRUCT begins its close from the exact displaced
/// video-window position occupied on that final source frame.
StructuralDossierOverlayPlacement? structuralDossierPlacementAtSourceEnd(
  EditDocumentModel model,
  StructuralSourceRef root,
  int sourceDurationFrames, {
  required int Function(DossierRequest request) centerPageCountFor,
}) {
  if (sourceDurationFrames <= 0) return null;
  return structuralDossierPlacement(
    model,
    root,
    sourceDurationFrames - 1,
    centerPageCountFor: centerPageCountFor,
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
