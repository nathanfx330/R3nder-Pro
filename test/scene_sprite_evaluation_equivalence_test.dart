// ./test/scene_sprite_evaluation_equivalence_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/project_clock.dart';
import 'package:r3nder/scene_engine.dart';
import 'package:r3nder/scene_evaluator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sprite scene evaluation matches reset plus ticks across PHOTO freeze',
      () async {
    final Directory root =
        await Directory.systemTemp.createTemp('r3nder_sprite_eval_');
    final Directory images = Directory('${root.path}/images')..createSync();
    final Directory sprites = Directory('${root.path}/sprites')..createSync();

    const String onePixelPng =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZVt8AAAAASUVORK5CYII=';
    final List<int> pngBytes = base64Decode(onePixelPng);
    File('${images.path}/base.png').writeAsBytesSync(pngBytes);
    File('${images.path}/overlay.png').writeAsBytesSync(pngBytes);

    File('${sprites.path}/spin.txt').writeAsStringSync(
      '0\n[FRAME]\n1\n[FRAME]\n2',
    );

    const String script = '''
[SPEED:MAX]
[PHOTO:base.png:1:R:0,255,0:1]
[SPRITE:spin.txt:2]
[PAUSE:3]
[PHOTO:overlay.png:1:R:0,255,0:50]
[PAUSE:6]
[SPRITE_OFF:spin.txt]
DONE
''';

    final SceneEngine scene = SceneEngine();
    addTearDown(() {
      scene.disposeImages();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    await scene.setup(
      templateText: script,
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

    const List<int> targets = <int>[
      0,
      1,
      2,
      3,
      4,
      5,
      7,
      8,
      9,
      15,
      22,
      23,
      24,
      25,
      30,
      35,
    ];

    scene.reset();
    for (final int target in targets) {
      final SceneEvaluationResult result = scene.evaluate(
        ProjectTime(frame: target, mode: ProjectClockMode.scrub),
      );
      expect(result.exact, isTrue, reason: 'evaluate missed frame $target');
      final Map<String, Object?> evaluated = _fingerprint(scene);

      scene.reset();
      while (scene.frameCount < target && !scene.isFinished) {
        scene.tick();
      }
      expect(scene.frameCount, target);
      final Map<String, Object?> replayed = _fingerprint(scene);

      expect(
        evaluated,
        replayed,
        reason: 'sprite scene diverged at project frame $target',
      );
    }
  });
}

Map<String, Object?> _fingerprint(SceneEngine scene) {
  final terminal = scene.terminal;
  return <String, Object?>{
    'sceneFrame': scene.frameCount,
    'terminalFrame': terminal.frameCount,
    'charIndex': terminal.charIndex,
    'pause': terminal.pauseFrames,
    'finished': terminal.isFinished,
    'photos': <Object?>[
      for (final photo in terminal.photoStack)
        <String, Object?>{
          'key': photo.key,
          'start': photo.startFrame,
          'release': photo.releaseAt,
          'elapsed': photo.elapsedAt(terminal.frameCount),
        },
    ],
    'rendered': <String>[
      for (final line in terminal.renderedLines)
        line.chars.map((char) => char.char).join(),
    ],
    'current': terminal.currentLine.map((char) => char.char).join(),
  };
}
