// ./test/dossier_evidence_semantics_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/dossier_overlay.dart';
import 'package:r3nder/dossier_presentation.dart';
import 'package:r3nder/presentation_requests.dart';

DossierRequest _request() => DossierRequest(
      folder: 'evidence',
      image: 'person.png',
      holdSplit: 7,
      holdFull: 9,
      centerMode: DossierCenterMode.mosaic,
      cardLead: 5,
      panelColor: const Color.fromARGB(255, 24, 32, 40),
      heading: 'JOHN SMITH',
      body: 'Biography text.',
    );

DossierPresentationTiming _modern() => DossierPresentationTiming(
      holdSplit: 7,
      holdFull: 9,
      evidenceMode: DossierCenterMode.mosaic,
      cardLead: 5,
      evidencePageCount: 2,
      cardSlideFrames: 16,
      windowAnimFrames: 12,
      mosaicPanFrames: 22,
    );

DossierPresentationTiming _legacy() => DossierPresentationTiming(
      holdSplit: 7,
      holdFull: 9,
      centerMode: DossierCenterMode.mosaic,
      cardLead: 5,
      centerPageCount: 2,
      cardSlideFrames: 16,
      windowAnimFrames: 12,
      mosaicPanFrames: 22,
    );

void main() {
  test('evidence vocabulary preserves legacy timing frame for frame', () {
    final DossierPresentationTiming modern = _modern();
    final DossierPresentationTiming legacy = _legacy();

    expect(modern.durationFrames, legacy.durationFrames);
    expect(modern.evidenceMode, DossierCenterMode.mosaic);
    expect(modern.centerMode, modern.evidenceMode);
    expect(modern.evidencePageCount, 2);
    expect(modern.centerPageCount, modern.evidencePageCount);
    expect(modern.hasEvidenceSequence, isTrue);
    expect(modern.hasCenterStage, modern.hasEvidenceSequence);
    expect(modern.evidenceShowingFrames, 9);
    expect(modern.centerShowingFrames, modern.evidenceShowingFrames);
    expect(modern.resolvedEvidencePageCount, 2);
    expect(modern.resolvedCenterPageCount, modern.resolvedEvidencePageCount);

    for (int frame = 0; frame < modern.durationFrames; frame++) {
      final DossierPresentationFrame a = modern.frameAt(frame)!;
      final DossierPresentationFrame b = legacy.frameAt(frame)!;
      expect(a.stage, b.stage, reason: 'historical slot differs at F$frame');
      expect(
        a.evidenceStage,
        b.evidenceStage,
        reason: 'evidence semantics differ at F$frame',
      );
      expect(a.stageFrame, b.stageFrame, reason: 'stage age differs at F$frame');
      expect(a.progress, b.progress, reason: 'progress differs at F$frame');
      expect(
        a.evidencePageIndex,
        b.centerPageIndex,
        reason: 'page identity differs at F$frame',
      );
    }
  });

  test('legacy gallery-opening slot is explicitly evidence preparation', () {
    final DossierPresentationTiming timing = _modern();

    // opening 16 + cardLead 5 = first frame of the retained 12-frame runway.
    final DossierPresentationFrame prepare = timing.frameAt(21)!;
    expect(prepare.stage, DossierPresentationStage.galleryOpening);
    expect(prepare.evidenceStage, DossierEvidenceStage.evidencePrepare);
    expect(prepare.stageFrame, 0);
    expect(prepare.stageDurationFrames, 12);

    final StructuralDossierPanelFrame visual = structuralDossierPanelFrame(
      StructuralDossierOverlayPlacement(
        dossier: _request(),
        localFrame: 21,
        presentationFrame: prepare,
        evidencePageCount: 2,
        normalizedRect: const Rect.fromLTWH(0, 0, 1, 1),
      ),
    );

    // Current structural product intentionally uses this compatibility runway
    // as a seated biography beat. It no longer claims to open a second gallery.
    expect(visual.cardSlide, 1.0);
    expect(visual.evidenceVisibility, 0.0);
  });

  test('center-transition slot now means biography to evidence transition', () {
    final DossierPresentationTiming timing = _modern();

    // opening 16 + lead 5 + prepare 12 + split hold 7 = transition F40.
    final DossierPresentationFrame first = timing.frameAt(40)!;
    expect(first.stage, DossierPresentationStage.centerTransition);
    expect(first.evidenceStage, DossierEvidenceStage.evidenceTransition);
    expect(first.progress, 0.0);

    final DossierPresentationFrame halfway = timing.frameAt(46)!;
    expect(halfway.evidenceStage, DossierEvidenceStage.evidenceTransition);
    expect(halfway.progress, closeTo(0.5, 0.000001));

    final StructuralDossierPanelFrame visual = structuralDossierPanelFrame(
      StructuralDossierOverlayPlacement(
        dossier: _request(),
        localFrame: 46,
        presentationFrame: halfway,
        evidencePageCount: 2,
        normalizedRect: const Rect.fromLTWH(0, 0, 1, 1),
      ),
    );
    expect(visual.cardSlide, closeTo(0.5, 0.000001));
    expect(visual.evidenceVisibility, closeTo(0.5, 0.000001));
  });

  test('fromRequest accepts modern and historical page-count spellings', () {
    final DossierRequest request = _request();
    final DossierPresentationTiming modern =
        DossierPresentationTiming.fromRequest(
      request,
      evidencePageCount: 3,
      cardSlideFrames: 16,
      windowAnimFrames: 12,
      mosaicPanFrames: 22,
    );
    final DossierPresentationTiming legacy =
        DossierPresentationTiming.fromRequest(
      request,
      centerPageCount: 3,
      cardSlideFrames: 16,
      windowAnimFrames: 12,
      mosaicPanFrames: 22,
    );

    expect(modern.evidenceMode, request.centerMode);
    expect(modern.resolvedEvidencePageCount, 3);
    expect(modern.durationFrames, legacy.durationFrames);
  });

  test('structural timing accepts evidence terminology without changing time', () {
    final DossierPresentationTiming modern = structuralDossierTiming(
      _request(),
      evidencePageCount: 2,
    );
    final DossierPresentationTiming legacy = structuralDossierTiming(
      _request(),
      centerPageCount: 2,
    );

    expect(modern.durationFrames, legacy.durationFrames);
    expect(modern.resolvedEvidencePageCount, 2);
    expect(modern.frameAt(0)!.evidenceStage, DossierEvidenceStage.opening);
  });
}
