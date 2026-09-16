// ./test/dossier_presentation_timing_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/dossier_presentation.dart';
import 'package:r3nder/presentation_requests.dart';
import 'package:r3nder/scene_engine.dart';

DossierPresentationTiming _timing({
  int holdSplit = 120,
  int holdFull = 120,
  DossierCenterMode centerMode = DossierCenterMode.grid,
  int cardLead = 0,
  int centerPageCount = 1,
}) {
  return DossierPresentationTiming(
    holdSplit: holdSplit,
    holdFull: holdFull,
    centerMode: centerMode,
    cardLead: cardLead,
    centerPageCount: centerPageCount,
    cardSlideFrames: kCardSlideFrames,
    windowAnimFrames: kWindowAnimFrames,
    mosaicPanFrames: kAppPanFrames,
  );
}

void _expectStage(
  DossierPresentationTiming timing,
  int frame,
  DossierPresentationStage stage, {
  int stageFrame = 0,
  int? page,
}) {
  final DossierPresentationFrame? state = timing.frameAt(frame);
  expect(state, isNotNull, reason: 'frame $frame should be visible');
  expect(state!.stage, stage);
  expect(state.stageFrame, stageFrame);
  expect(state.centerPageIndex, page);
}

void main() {
  test('classic GRID DOSSIER has explicit opening split center and exit', () {
    final DossierPresentationTiming timing = _timing();

    expect(timing.hasCardLead, isFalse);
    expect(timing.hasCenterStage, isTrue);
    expect(timing.resolvedCenterPageCount, 1);
    expect(timing.durationFrames, 280);

    _expectStage(timing, 0, DossierPresentationStage.opening);
    _expectStage(
      timing,
      15,
      DossierPresentationStage.opening,
      stageFrame: 15,
    );
    expect(timing.frameAt(15)!.progress, closeTo(15 / 16, 0.000001));

    // cardLead=0 means no cardLead/galleryOpening stage: the gallery arrived
    // during opening and the next exact frame is the seated split.
    _expectStage(timing, 16, DossierPresentationStage.splitShowing);
    _expectStage(
      timing,
      135,
      DossierPresentationStage.splitShowing,
      stageFrame: 119,
    );

    _expectStage(timing, 136, DossierPresentationStage.centerTransition);
    _expectStage(
      timing,
      147,
      DossierPresentationStage.centerTransition,
      stageFrame: 11,
    );

    _expectStage(
      timing,
      148,
      DossierPresentationStage.centerShowing,
      page: 0,
    );
    _expectStage(
      timing,
      267,
      DossierPresentationStage.centerShowing,
      stageFrame: 119,
      page: 0,
    );

    _expectStage(timing, 268, DossierPresentationStage.closing);
    _expectStage(
      timing,
      279,
      DossierPresentationStage.closing,
      stageFrame: 11,
    );

    expect(timing.frameAt(-1), isNull);
    expect(timing.frameAt(280), isNull);
  });

  test('cardLead inserts card-only hold then separate gallery opening', () {
    final DossierPresentationTiming timing = _timing(cardLead: 30);

    expect(timing.durationFrames, 322);

    _expectStage(timing, 15, DossierPresentationStage.opening, stageFrame: 15);
    _expectStage(timing, 16, DossierPresentationStage.cardLead);
    _expectStage(
      timing,
      45,
      DossierPresentationStage.cardLead,
      stageFrame: 29,
    );
    _expectStage(timing, 46, DossierPresentationStage.galleryOpening);
    _expectStage(
      timing,
      57,
      DossierPresentationStage.galleryOpening,
      stageFrame: 11,
    );
    _expectStage(timing, 58, DossierPresentationStage.splitShowing);
  });

  test('SIDE_ONLY skips center stage and exits on the card-slide budget', () {
    final DossierPresentationTiming timing = _timing(
      centerMode: DossierCenterMode.sideOnly,
    );

    expect(timing.hasCenterStage, isFalse);
    expect(timing.resolvedCenterPageCount, 0);
    expect(timing.closingFrames, kCardSlideFrames);
    expect(timing.durationFrames, 152);

    _expectStage(
      timing,
      135,
      DossierPresentationStage.splitShowing,
      stageFrame: 119,
    );
    _expectStage(timing, 136, DossierPresentationStage.closing);
    _expectStage(
      timing,
      151,
      DossierPresentationStage.closing,
      stageFrame: 15,
    );
    expect(timing.frameAt(151)!.progress, closeTo(15 / 16, 0.000001));
    expect(timing.frameAt(152), isNull);
  });

  test('MOSAIC repeats center hold and pan with exact outgoing page index', () {
    final DossierPresentationTiming timing = _timing(
      holdSplit: 10,
      holdFull: 20,
      centerMode: DossierCenterMode.mosaic,
      centerPageCount: 3,
    );

    expect(timing.resolvedCenterPageCount, 3);
    expect(timing.durationFrames, 154);

    _expectStage(timing, 38, DossierPresentationStage.centerShowing, page: 0);
    _expectStage(
      timing,
      57,
      DossierPresentationStage.centerShowing,
      stageFrame: 19,
      page: 0,
    );
    _expectStage(timing, 58, DossierPresentationStage.centerPanning, page: 0);
    _expectStage(
      timing,
      79,
      DossierPresentationStage.centerPanning,
      stageFrame: 21,
      page: 0,
    );

    _expectStage(timing, 80, DossierPresentationStage.centerShowing, page: 1);
    _expectStage(timing, 100, DossierPresentationStage.centerPanning, page: 1);
    _expectStage(timing, 122, DossierPresentationStage.centerShowing, page: 2);
    _expectStage(
      timing,
      141,
      DossierPresentationStage.centerShowing,
      stageFrame: 19,
      page: 2,
    );
    _expectStage(timing, 142, DossierPresentationStage.closing);
    expect(timing.frameAt(154), isNull);
  });

  test('zero split/full holds preserve one visible seated frame each', () {
    final DossierPresentationTiming timing = _timing(
      holdSplit: 0,
      holdFull: 0,
    );

    expect(timing.splitShowingFrames, 1);
    expect(timing.centerShowingFrames, 1);
    expect(timing.durationFrames, 42);

    _expectStage(timing, 16, DossierPresentationStage.splitShowing);
    _expectStage(timing, 17, DossierPresentationStage.centerTransition);
    _expectStage(timing, 29, DossierPresentationStage.centerShowing, page: 0);
    _expectStage(timing, 30, DossierPresentationStage.closing);
    expect(timing.frameAt(42), isNull);
  });

  test('fromRequest preserves authored DOSSIER facts without painter state', () {
    final DossierRequest request = DossierRequest(
      folder: 'evidence',
      image: 'person.png',
      holdSplit: 45,
      holdFull: 60,
      centerMode: DossierCenterMode.mosaic,
      cardLead: 24,
      panelColor: const Color.fromARGB(255, 24, 32, 40),
      heading: 'JOHN SMITH',
      body: 'Biography text.',
    );

    final DossierPresentationTiming timing =
        DossierPresentationTiming.fromRequest(
      request,
      centerPageCount: 2,
      cardSlideFrames: kCardSlideFrames,
      windowAnimFrames: kWindowAnimFrames,
      mosaicPanFrames: kAppPanFrames,
    );

    expect(timing.holdSplit, 45);
    expect(timing.holdFull, 60);
    expect(timing.centerMode, DossierCenterMode.mosaic);
    expect(timing.cardLead, 24);
    expect(timing.resolvedCenterPageCount, 2);

    // Timing knows nothing about image decoding, typography, or geometry.
    // It only resolves authored lifetime into exact stages/pages.
    expect(
      timing.frameAt(kCardSlideFrames)!.stage,
      DossierPresentationStage.cardLead,
    );
  });
}
