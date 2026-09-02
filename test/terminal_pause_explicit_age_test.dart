// ./test/terminal_pause_explicit_age_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TerminalEngine terminalFor(String script) {
    final TerminalEngine terminal = TerminalEngine();
    terminal.setup(
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
    );
    return terminal;
  }

  test('PAUSE derives remaining frames and resumes on the following tick', () {
    final TerminalEngine terminal =
        terminalFor('[SPEED:MAX]A[PAUSE:3]B');

    terminal.tick();

    final PauseState pause = terminal.activePause!;
    expect(pause.durationFrames, 3);
    expect(pause.startFrame, terminal.frameCount);
    expect(terminal.pauseFrames, 3);
    expect(terminal.currentLine.any((char) => char.char == 'A'), isTrue);
    expect(terminal.currentLine.any((char) => char.char == 'B'), isFalse);

    for (int expected = 2; expected >= 0; expected--) {
      terminal.tick();
      expect(terminal.pauseFrames, expected);
      expect(terminal.currentLine.any((char) => char.char == 'B'), isFalse);
    }

    expect(terminal.activePause, isNull);

    terminal.tick();
    expect(terminal.currentLine.any((char) => char.char == 'B'), isTrue);
  });

  test('end hold derives from age and preserves audio-bed extension', () {
    final TerminalEngine terminal = terminalFor('A');
    terminal.bedTargetFrames = 100;

    terminal.tick(); // Commit A, terminal frame 1.
    expect(terminal.inEndHold, isFalse);

    terminal.tick(); // Script exhaustion starts the hold, terminal frame 2.

    final PauseState hold = terminal.activePause!;
    expect(terminal.inEndHold, isTrue);
    expect(hold.durationFrames, 99);
    expect(hold.startFrame, terminal.frameCount);
    expect(terminal.pauseFrames, 99);
    expect(terminal.isFinished, isFalse);

    int holdTicks = 0;
    while (!terminal.isFinished && holdTicks < 200) {
      terminal.tick();
      holdTicks++;
    }

    expect(holdTicks, 99);
    expect(terminal.pauseFrames, 0);
    expect(terminal.activePause, isNull);
    expect(terminal.isFinished, isTrue);
  });

  test('missing SVG PHOTO and IMG burn their authored gate durations', () {
    final TerminalEngine terminal = terminalFor(
      '[SPEED:MAX]'
      '[SVG:missing.svg:2]A'
      '[PHOTO:missing.png:3]B'
      '[IMG:missing.png:2:R:2]C',
    );

    final List<int> durations = <int>[];
    PauseState? previous;
    int guard = 0;

    while (durations.length < 3 && guard < 100) {
      terminal.tick();
      guard++;

      final PauseState? current = terminal.activePause;
      if (current != null && !identical(current, previous)) {
        durations.add(current.durationFrames);
        previous = current;
      }
    }

    expect(guard, lessThan(100), reason: 'dud timing fixture did not advance');
    expect(durations, <int>[2, 3, 4]);
  });
}
