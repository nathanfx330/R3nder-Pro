// ./test/card_presentation_timing_test.dart

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/card_presentation.dart' as card;
import 'package:r3nder/scene_engine.dart' as scene;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CardPresentationTiming', () {
    test('preserves exact opening, showing, and closing boundaries', () {
      const card.CardPresentationTiming timing =
          card.CardPresentationTiming(holdFrames: 3);

      expect(timing.showingFrames, 3);
      expect(timing.durationFrames, 35);
      expect(timing.showingStartFrame, 16);
      expect(timing.closingStartFrame, 19);

      expect(timing.frameAt(-1), isNull);

      final card.CardPresentationFrame first = timing.frameAt(0)!;
      expect(first.stage, card.CardPresentationStage.opening);
      expect(first.slide, 0.0);

      final card.CardPresentationFrame lastOpening = timing.frameAt(15)!;
      expect(lastOpening.stage, card.CardPresentationStage.opening);
      expect(lastOpening.slide, 15 / 16);

      final card.CardPresentationFrame firstShowing = timing.frameAt(16)!;
      expect(firstShowing.stage, card.CardPresentationStage.showing);
      expect(firstShowing.slide, 1.0);

      final card.CardPresentationFrame lastShowing = timing.frameAt(18)!;
      expect(lastShowing.stage, card.CardPresentationStage.showing);
      expect(lastShowing.slide, 1.0);

      final card.CardPresentationFrame firstClosing = timing.frameAt(19)!;
      expect(firstClosing.stage, card.CardPresentationStage.closing);
      expect(firstClosing.slide, 1.0);

      final card.CardPresentationFrame lastClosing = timing.frameAt(34)!;
      expect(lastClosing.stage, card.CardPresentationStage.closing);
      expect(lastClosing.slide, 1 / 16);

      expect(timing.frameAt(35), isNull);
    });

    test('zero hold retains one fully seated frame', () {
      const card.CardPresentationTiming timing =
          card.CardPresentationTiming(holdFrames: 0);

      expect(timing.showingFrames, 1);
      expect(timing.durationFrames, 33);
      expect(timing.closingStartFrame, 17);

      expect(
        timing.frameAt(15)!.stage,
        card.CardPresentationStage.opening,
      );
      expect(
        timing.frameAt(16)!.stage,
        card.CardPresentationStage.showing,
      );
      expect(timing.frameAt(16)!.slide, 1.0);
      expect(
        timing.frameAt(17)!.stage,
        card.CardPresentationStage.closing,
      );
      expect(timing.frameAt(32)!.slide, 1 / 16);
      expect(timing.frameAt(33), isNull);
    });

    test('one-frame hold is not extended beyond one seated frame', () {
      const card.CardPresentationTiming timing =
          card.CardPresentationTiming(holdFrames: 1);

      expect(timing.showingFrames, 1);
      expect(timing.durationFrames, 33);
      expect(
        timing.frameAt(16)!.stage,
        card.CardPresentationStage.showing,
      );
      expect(
        timing.frameAt(17)!.stage,
        card.CardPresentationStage.closing,
      );
    });

    test('stage-age arithmetic preserves historical 16-frame ramps', () {
      for (int age = 0; age < card.kCardSlideFrames; age++) {
        expect(
          card.CardPresentationTiming.slideAtStageAge(
            card.CardPresentationStage.opening,
            age,
          ),
          age / card.kCardSlideFrames,
        );
        expect(
          card.CardPresentationTiming.slideAtStageAge(
            card.CardPresentationStage.closing,
            age,
          ),
          1.0 - (age / card.kCardSlideFrames),
        );
      }

      expect(
        card.CardPresentationTiming.slideAtStageAge(
          card.CardPresentationStage.showing,
          999,
        ),
        1.0,
      );
    });
  });

  group('SceneEngine CARD parity', () {
    for (final int hold in <int>[0, 1, 3, 8]) {
      test('hold $hold matches explicit local CARD time exhaustively', () async {
        final _SceneFixture fixture = await _makeScene(hold);
        addTearDown(fixture.dispose);

        final List<_ObservedCardFrame> observed =
            _collectCardFrames(fixture.engine);
        final card.CardPresentationTiming timing =
            card.CardPresentationTiming(holdFrames: hold);

        // This count comes from actually ticking SceneEngine. It is not a
        // second copy of the duration formula, so a phase-boundary change in
        // the legacy TEXT path makes this fail immediately.
        expect(observed.length, timing.durationFrames);

        for (int localFrame = 0;
            localFrame < observed.length;
            localFrame++) {
          final _ObservedCardFrame actual = observed[localFrame];
          final card.CardPresentationFrame expected =
              timing.frameAt(localFrame)!;

          expect(
            actual.stage,
            expected.stage,
            reason: 'stage mismatch at CARD local frame $localFrame '
                'for hold $hold',
          );
          expect(
            actual.slide,
            expected.slide,
            reason: 'slide mismatch at CARD local frame $localFrame '
                'for hold $hold',
          );
        }

        expect(timing.frameAt(-1), isNull);
        expect(timing.frameAt(observed.length), isNull);
      });
    }
  });
}

class _ObservedCardFrame {
  const _ObservedCardFrame({
    required this.stage,
    required this.slide,
  });

  final card.CardPresentationStage stage;
  final double slide;
}

class _SceneFixture {
  const _SceneFixture({
    required this.engine,
    required this.root,
  });

  final scene.SceneEngine engine;
  final Directory root;

  void dispose() {
    engine.disposeImages();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

Future<_SceneFixture> _makeScene(int hold) async {
  final Directory root =
      await Directory.systemTemp.createTemp('r3nder_card_timing_');
  final Directory images = Directory('${root.path}/images')..createSync();
  final Directory sprites = Directory('${root.path}/sprites')..createSync();

  final scene.SceneEngine engine = scene.SceneEngine();
  await engine.setup(
    templateText: '''
[SPEED:MAX]
[CARD:missing.png:$hold:30,30,38:PROFILE]
Card body.
[/CARD]
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

  return _SceneFixture(engine: engine, root: root);
}

List<_ObservedCardFrame> _collectCardFrames(scene.SceneEngine engine) {
  const int guardLimit = 5000;
  final List<_ObservedCardFrame> frames = <_ObservedCardFrame>[];

  engine.reset();
  int guard = 0;
  bool enteredCard = false;

  while (!engine.isFinished && guard < guardLimit) {
    engine.tick();
    guard++;

    final card.CardPresentationStage? stage = _cardStage(engine.phase);
    if (stage != null) {
      enteredCard = true;
      frames.add(
        _ObservedCardFrame(
          stage: stage,
          slide: engine.cardSlide,
        ),
      );
      continue;
    }

    if (enteredCard) break;
  }

  expect(guard, lessThan(guardLimit),
      reason: 'CARD fixture failed to leave the presentation');
  expect(enteredCard, isTrue, reason: 'CARD fixture never entered CARD');
  return frames;
}

card.CardPresentationStage? _cardStage(scene.ScenePhase phase) {
  switch (phase) {
    case scene.ScenePhase.cardOpening:
      return card.CardPresentationStage.opening;
    case scene.ScenePhase.cardShowing:
      return card.CardPresentationStage.showing;
    case scene.ScenePhase.cardClosing:
      return card.CardPresentationStage.closing;
    default:
      return null;
  }
}
