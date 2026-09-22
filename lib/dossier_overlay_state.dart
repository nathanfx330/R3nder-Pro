// ./lib/dossier_overlay_state.dart
//
// Explicit-time DOSSIER placement state for continuously-playing structural
// video. This file owns cue selection and timing projection only. Asset lookup
// and painting live in dossier_overlay.dart; outer video-window geometry remains
// owned by sidecard_geometry.dart.
//
// DOSSIER's authored GRID / MOSAIC / SIDE_ONLY tokens are unchanged. Inside the
// structural projection they describe right-hand evidence behavior, not a move
// into a separate center stage. Legacy center* argument/getter spellings remain
// accepted so existing callers and SceneEngine parity fixtures keep compiling.

import 'dart:ui';

import 'dossier_presentation.dart';
import 'edit_cue.dart';
import 'edit_model.dart';
import 'mosaic_layout.dart';
import 'presentation_requests.dart';
import 'scene_engine.dart';

export 'dossier_presentation.dart';

/// One DOSSIER presentation active at an exact structural source frame.
class StructuralDossierOverlayPlacement {
  const StructuralDossierOverlayPlacement({
    required this.dossier,
    required this.localFrame,
    required this.presentationFrame,
    int? evidencePageCount,
    int? centerPageCount,
    required this.normalizedRect,
  })  : evidencePageCount = evidencePageCount ?? centerPageCount ?? 0,
        assert((evidencePageCount ?? centerPageCount ?? 0) >= 0),
        assert(evidencePageCount == null ||
            centerPageCount == null ||
            evidencePageCount == centerPageCount);

  final DossierRequest dossier;
  final int localFrame;
  final DossierPresentationFrame presentationFrame;

  /// Asset-backed right-hand evidence page count.
  final int evidencePageCount;

  /// Historical compatibility alias.
  int get centerPageCount => evidencePageCount;

  /// Region of the structural source that owned the trigger. The outer DOSSIER
  /// shell is still a program-level sibling composition, just like SIDECARD;
  /// this rect is retained for deterministic authored-order selection and future
  /// pane-local presentation work.
  final Rect normalizedRect;
}

/// Builds the one timing authority used by structural DOSSIER Preview and BAKE.
/// New callers should use [evidencePageCount]; [centerPageCount] is accepted for
/// compatibility with the original center-stage vocabulary.
DossierPresentationTiming structuralDossierTiming(
  DossierRequest request, {
  int? evidencePageCount,
  int? centerPageCount,
}) {
  final int pages = evidencePageCount ?? centerPageCount ?? 0;
  return DossierPresentationTiming.fromRequest(
    request,
    evidencePageCount: pages,
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
  switch (frame.evidenceStage) {
    case DossierEvidenceStage.opening:
      return frame.progress;
    case DossierEvidenceStage.cardLead:
    case DossierEvidenceStage.evidencePrepare:
    case DossierEvidenceStage.splitShowing:
    case DossierEvidenceStage.evidenceTransition:
    case DossierEvidenceStage.evidenceShowing:
    case DossierEvidenceStage.evidencePanning:
      return 1.0;
    case DossierEvidenceStage.closing:
      return 1.0 - frame.progress;
  }
}

int Function(DossierRequest request) _evidencePageResolver({
  int Function(DossierRequest request)? evidencePageCountFor,
  int Function(DossierRequest request)? centerPageCountFor,
}) {
  final resolver = evidencePageCountFor ?? centerPageCountFor;
  if (resolver == null) {
    throw ArgumentError(
      'DOSSIER placement requires an evidence page-count resolver.',
    );
  }
  return resolver;
}

/// Resolve one active DOSSIER for the outer structural shell.
///
/// [evidencePageCountFor] is intentionally supplied by the asset-backed caller.
/// CUE parsing cannot know how many files currently exist in an evidence
/// folder, while a mosaic's exact lifetime does depend on that count. The
/// historical [centerPageCountFor] name remains a compatibility alias. Later
/// authored active cues win, matching CARD/SIDECARD's deterministic z-order.
StructuralDossierOverlayPlacement? structuralDossierPlacement(
  EditDocumentModel model,
  StructuralSourceRef root,
  int projectFrame, {
  int Function(DossierRequest request)? evidencePageCountFor,
  int Function(DossierRequest request)? centerPageCountFor,
}) {
  final pageCountFor = _evidencePageResolver(
    evidencePageCountFor: evidencePageCountFor,
    centerPageCountFor: centerPageCountFor,
  );
  StructuralDossierOverlayPlacement? selected;

  switch (root.kind) {
    case StructuralSourceKind.edit:
      for (final ActiveEditDossierCue active
          in activeDossierCuesForEdit(model.edit(root.id), projectFrame)) {
        final int pages = pageCountFor(active.cue.dossier);
        final DossierPresentationFrame? frame = structuralDossierTiming(
          active.cue.dossier,
          evidencePageCount: pages,
        ).frameAt(active.localFrame);
        if (frame == null) continue;
        selected = StructuralDossierOverlayPlacement(
          dossier: active.cue.dossier,
          localFrame: active.localFrame,
          presentationFrame: frame,
          evidencePageCount: pages,
          normalizedRect: const Rect.fromLTWH(0, 0, 1, 1),
        );
      }
      break;

    case StructuralSourceKind.mosaic:
      final MosaicSequence mosaic = model.mosaic(root.id);
      final List<Rect> layout = mosaicPaneLayout(mosaic.panes.length);
      for (int i = 0; i < mosaic.panes.length; i++) {
        for (final ActiveEditDossierCue active
            in activeDossierCuesForPane(mosaic.panes[i], projectFrame)) {
          final int pages = pageCountFor(active.cue.dossier);
          final DossierPresentationFrame? frame = structuralDossierTiming(
            active.cue.dossier,
            evidencePageCount: pages,
          ).frameAt(active.localFrame);
          if (frame == null) continue;
          selected = StructuralDossierOverlayPlacement(
            dossier: active.cue.dossier,
            localFrame: active.localFrame,
            presentationFrame: frame,
            evidencePageCount: pages,
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
  int Function(DossierRequest request)? evidencePageCountFor,
  int Function(DossierRequest request)? centerPageCountFor,
}) {
  if (sourceDurationFrames <= 0) return null;
  return structuralDossierPlacement(
    model,
    root,
    sourceDurationFrames - 1,
    evidencePageCountFor: evidencePageCountFor,
    centerPageCountFor: centerPageCountFor,
  );
}

