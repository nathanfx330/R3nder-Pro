// ./test/dossier_presentation_timing_test.dart

import 'dart:convert';
import 'dart:io';

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
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DossierPresentationTiming', () {
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

      _expectStage(
        timing,
        15,
        DossierPresentationStage.opening,
        stageFrame: 15,
      );
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
  });

  group('SceneEngine DOSSIER parity', () {
    final List<_DossierParityCase> cases = <_DossierParityCase>[
      const _DossierParityCase(
        name: 'classic GRID',
        holdSplit: 3,
        holdFull: 4,
        centerMode: DossierCenterMode.grid,
        cardLead: 0,
        imageCount: 1,
        centerPageCount: 1,
      ),
      const _DossierParityCase(
        name: 'card lead GRID',
        holdSplit: 3,
        holdFull: 4,
        centerMode: DossierCenterMode.grid,
        cardLead: 2,
        imageCount: 1,
        centerPageCount: 1,
      ),
      const _DossierParityCase(
        name: 'SIDE_ONLY',
        holdSplit: 3,
        holdFull: 99,
        centerMode: DossierCenterMode.sideOnly,
        cardLead: 0,
        imageCount: 1,
        centerPageCount: 0,
      ),
      const _DossierParityCase(
        name: 'three-page MOSAIC',
        holdSplit: 2,
        holdFull: 3,
        centerMode: DossierCenterMode.mosaic,
        cardLead: 0,
        imageCount: 7,
        centerPageCount: 3,
      ),
      const _DossierParityCase(
        name: 'zero holds GRID',
        holdSplit: 0,
        holdFull: 0,
        centerMode: DossierCenterMode.grid,
        cardLead: 0,
        imageCount: 1,
        centerPageCount: 1,
      ),
    ];

    for (final _DossierParityCase c in cases) {
      test('${c.name} matches explicit local DOSSIER time exhaustively', () async {
        final _DossierSceneFixture fixture = await _makeDossierScene(c);
        addTearDown(fixture.dispose);

        final List<_ObservedDossierFrame> observed =
            _collectDossierFrames(fixture.engine);
        final DossierPresentationTiming timing = DossierPresentationTiming(
          holdSplit: c.holdSplit,
          holdFull: c.holdFull,
          centerMode: c.centerMode,
          cardLead: c.cardLead,
          centerPageCount: c.centerPageCount,
          cardSlideFrames: kCardSlideFrames,
          windowAnimFrames: kWindowAnimFrames,
          mosaicPanFrames: kAppPanFrames,
        );

        // This count comes from ticking the existing SceneEngine, not from a
        // second duration formula. Any old TEXT DOSSIER phase boundary that
        // disagrees with the extracted explicit model fails here immediately.
        expect(observed.length, timing.durationFrames);

        for (int localFrame = 0;
            localFrame < observed.length;
            localFrame++) {
          final _ObservedDossierFrame actual = observed[localFrame];
          final DossierPresentationFrame expected = timing.frameAt(localFrame)!;
          final _ExpectedDossierVisual visual = _expectedDossierVisual(
            timing,
            expected,
          );

          expect(
            actual.stage,
            expected.stage,
            reason: '${c.name}: stage mismatch at DOSSIER local frame '
                '$localFrame',
          );
          expect(
            actual.cardSlide,
            closeTo(visual.cardSlide, 0.000001),
            reason: '${c.name}: card slide mismatch at DOSSIER local frame '
                '$localFrame',
          );
          expect(
            actual.galleryOpenness,
            closeTo(visual.galleryOpenness, 0.000001),
            reason: '${c.name}: gallery openness mismatch at DOSSIER local '
                'frame $localFrame',
          );
          expect(
            actual.mosaicPanT,
            closeTo(visual.mosaicPanT, 0.000001),
            reason: '${c.name}: mosaic pan mismatch at DOSSIER local frame '
                '$localFrame',
          );
          if (expected.centerPageIndex != null) {
            expect(
              actual.centerPageIndex,
              expected.centerPageIndex,
              reason: '${c.name}: center page mismatch at DOSSIER local '
                  'frame $localFrame',
            );
          }
        }

        expect(timing.frameAt(-1), isNull);
        expect(timing.frameAt(observed.length), isNull);
      });
    }
  });
}

class _DossierParityCase {
  const _DossierParityCase({
    required this.name,
    required this.holdSplit,
    required this.holdFull,
    required this.centerMode,
    required this.cardLead,
    required this.imageCount,
    required this.centerPageCount,
  });

  final String name;
  final int holdSplit;
  final int holdFull;
  final DossierCenterMode centerMode;
  final int cardLead;
  final int imageCount;
  final int centerPageCount;
}

class _ObservedDossierFrame {
  const _ObservedDossierFrame({
    required this.stage,
    required this.cardSlide,
    required this.galleryOpenness,
    required this.mosaicPanT,
    required this.centerPageIndex,
  });

  final DossierPresentationStage stage;
  final double cardSlide;
  final double galleryOpenness;
  final double mosaicPanT;
  final int centerPageIndex;
}

class _ExpectedDossierVisual {
  const _ExpectedDossierVisual({
    required this.cardSlide,
    required this.galleryOpenness,
    this.mosaicPanT = 0.0,
  });

  final double cardSlide;
  final double galleryOpenness;
  final double mosaicPanT;
}

_ExpectedDossierVisual _expectedDossierVisual(
  DossierPresentationTiming timing,
  DossierPresentationFrame frame,
) {
  switch (frame.stage) {
    case DossierPresentationStage.opening:
      return _ExpectedDossierVisual(
        cardSlide: frame.progress,
        galleryOpenness: timing.hasCardLead ? 0.0 : frame.progress,
      );
    case DossierPresentationStage.cardLead:
      return const _ExpectedDossierVisual(
        cardSlide: 1.0,
        galleryOpenness: 0.0,
      );
    case DossierPresentationStage.galleryOpening:
      return _ExpectedDossierVisual(
        cardSlide: 1.0,
        galleryOpenness: frame.progress,
      );
    case DossierPresentationStage.splitShowing:
      return const _ExpectedDossierVisual(
        cardSlide: 1.0,
        galleryOpenness: 1.0,
      );
    case DossierPresentationStage.centerTransition:
      return _ExpectedDossierVisual(
        cardSlide: 1.0 - frame.progress,
        galleryOpenness: 1.0,
      );
    case DossierPresentationStage.centerShowing:
      return const _ExpectedDossierVisual(
        cardSlide: 0.0,
        galleryOpenness: 1.0,
      );
    case DossierPresentationStage.centerPanning:
      return _ExpectedDossierVisual(
        cardSlide: 0.0,
        galleryOpenness: 1.0,
        mosaicPanT: frame.progress,
      );
    case DossierPresentationStage.closing:
      if (timing.centerMode == DossierCenterMode.sideOnly) {
        return _ExpectedDossierVisual(
          cardSlide: 1.0 - frame.progress,
          galleryOpenness: 1.0 - frame.progress,
        );
      }
      return _ExpectedDossierVisual(
        cardSlide: 0.0,
        galleryOpenness: 1.0 - frame.progress,
      );
  }
}

DossierPresentationStage? _dossierStage(ScenePhase phase) {
  switch (phase) {
    case ScenePhase.dossierOpening:
      return DossierPresentationStage.opening;
    case ScenePhase.dossierCardLead:
      return DossierPresentationStage.cardLead;
    case ScenePhase.dossierGalleryOpening:
      return DossierPresentationStage.galleryOpening;
    case ScenePhase.dossierSplitShowing:
      return DossierPresentationStage.splitShowing;
    case ScenePhase.dossierTransitioning:
      return DossierPresentationStage.centerTransition;
    case ScenePhase.dossierFullShowing:
      return DossierPresentationStage.centerShowing;
    case ScenePhase.dossierMosaicPanning:
      return DossierPresentationStage.centerPanning;
    case ScenePhase.dossierClosing:
      return DossierPresentationStage.closing;
    default:
      return null;
  }
}

List<_ObservedDossierFrame> _collectDossierFrames(SceneEngine engine) {
  const int guardLimit = 5000;
  final List<_ObservedDossierFrame> frames = <_ObservedDossierFrame>[];

  engine.reset();
  int guard = 0;
  bool enteredDossier = false;

  while (!engine.isFinished && guard < guardLimit) {
    engine.tick();
    guard++;

    final DossierPresentationStage? stage = _dossierStage(engine.phase);
    if (stage != null) {
      enteredDossier = true;
      frames.add(
        _ObservedDossierFrame(
          stage: stage,
          cardSlide: engine.dossierCardSlide,
          galleryOpenness: engine.dossierGalleryOpenness,
          mosaicPanT: engine.dossierMosaicPanT,
          centerPageIndex: engine.dossierMosaicPageIndex,
        ),
      );
      continue;
    }

    if (enteredDossier) break;
  }

  expect(
    guard,
    lessThan(guardLimit),
    reason: 'DOSSIER fixture failed to leave the presentation',
  );
  expect(
    enteredDossier,
    isTrue,
    reason: 'DOSSIER fixture never entered DOSSIER',
  );
  return frames;
}

class _DossierSceneFixture {
  const _DossierSceneFixture({
    required this.engine,
    required this.root,
  });

  final SceneEngine engine;
  final Directory root;

  void dispose() {
    engine.disposeImages();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

Future<_DossierSceneFixture> _makeDossierScene(_DossierParityCase c) async {
  final Directory root =
      await Directory.systemTemp.createTemp('r3nder_dossier_timing_');
  final Directory images = Directory('${root.path}/images')
    ..createSync(recursive: true);
  final Directory evidence = Directory('${images.path}/evidence')
    ..createSync(recursive: true);
  final Directory sprites = Directory('${root.path}/sprites')
    ..createSync(recursive: true);

  final List<int> png = base64Decode(_onePixelPng);
  for (int i = 0; i < c.imageCount; i++) {
    final String name = i.toString().padLeft(2, '0');
    File('${evidence.path}/$name.png').writeAsBytesSync(png);
  }

  final SceneEngine engine = SceneEngine();
  await engine.setup(
    templateText: '''
[SPEED:MAX]
[DOSSIER:evidence:missing.png:${c.holdSplit}:${c.holdFull}:${c.cardLead}:${_centerModeName(c.centerMode)}:30,30,38:PROFILE]
Dossier body.
[/DOSSIER]
DONE
''',
    fontColor: const Color(0xFF00FF00),
    bgColor: const Color(0xFF0A0F0A),
    width: 1280,
    height: 720,
    scale: 1,
    fontPath: 'monospace',
    fontSize: 32,
    lineSpacing: 40,
    tracking: 0,
    marginTop: 60,
    marginSide: 60,
    imagesDir: images.path,
    spritesDir: sprites.path,
  );

  return _DossierSceneFixture(engine: engine, root: root);
}

String _centerModeName(DossierCenterMode mode) {
  switch (mode) {
    case DossierCenterMode.grid:
      return 'GRID';
    case DossierCenterMode.mosaic:
      return 'MOSAIC';
    case DossierCenterMode.sideOnly:
      return 'SIDE_ONLY';
  }
}

// Strictly valid 1x1 RGBA PNG. Flutter's codec validates PNG chunk CRCs, so
// the fixture must use bytes that are valid under the same decoder as setup().
const String _onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==';
