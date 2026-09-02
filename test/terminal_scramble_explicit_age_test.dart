// ./test/terminal_scramble_explicit_age_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('SCRAMBLE preserves visible glyph frames and zero-left transition', () {
    final TerminalEngine terminal = TerminalEngine();
    terminal.setup(
      templateText: '[SPEED:MAX][SCRAMBLE:on]A[SCRAMBLE:off]B',
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
    );

    terminal.tick();

    final ScrambleState first = terminal.activeScramble!;
    final int duration = first.durationFrames;

    expect(first.targetChar, 'A');
    expect(first.startFrame, terminal.frameCount);
    expect(duration, inInclusiveRange(2, 6));

    for (int expected = duration; expected > 0; expected--) {
      expect(terminal.scrambleFramesLeft, expected);
      expect(terminal.scrambleTargetChar, 'A');
      expect(first.glyphVisibleAt(terminal.frameCount), isTrue);
      expect(
        terminal.currentLine.any((char) => char.char == 'A'),
        isFalse,
      );
      terminal.tick();
    }

    // Legacy behavior has one complete frame at zero before A commits.
    expect(terminal.scrambleFramesLeft, 0);
    expect(terminal.scrambleTargetChar, 'A');
    expect(first.glyphVisibleAt(terminal.frameCount), isFalse);
    expect(first.commitReadyAt(terminal.frameCount), isTrue);
    expect(
      terminal.currentLine.any((char) => char.char == 'A'),
      isFalse,
    );

    terminal.tick();

    expect(terminal.activeScramble, isNull);
    expect(terminal.scrambleFramesLeft, 0);
    expect(
      terminal.currentLine.any((char) => char.char == 'A'),
      isTrue,
    );
  });

  test('SCRAMBLE seeded duration sequence replays exactly after reset', () {
    final TerminalEngine terminal = TerminalEngine();
    terminal.setup(
      templateText: '[SPEED:MAX][SCRAMBLE:on]AB[SCRAMBLE:off]C',
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
    );

    List<int> collectDurations() {
      terminal.reset();
      final List<int> durations = <int>[];
      ScrambleState? previous;
      int guard = 0;

      while (durations.length < 2 && guard < 100) {
        terminal.tick();
        guard++;

        final ScrambleState? current = terminal.activeScramble;
        if (current != null && !identical(current, previous)) {
          durations.add(current.durationFrames);
          previous = current;
        }
      }

      expect(guard, lessThan(100), reason: 'SCRAMBLE fixture did not advance');
      return durations;
    }

    final List<int> firstPass = collectDurations();
    final List<int> replay = collectDurations();

    expect(firstPass, hasLength(2));
    expect(replay, firstPass);
  });
}
