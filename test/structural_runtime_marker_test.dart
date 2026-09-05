// ./test/structural_runtime_marker_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/engine.dart';
import 'package:r3nder/script_pipeline.dart';
import 'package:r3nder/structural_sequence.dart';

void main() {
  test('runtime STRUCT marker owns exact local frames at SPEED MAX', () {
    const String source = '''[SPEED:MAX]
BEFORE
[EDIT:main]
[TRACK:V1]
[CLIP:c:video/c.mp4:0:0:3:1]
[/CLIP]
[/TRACK]
[/EDIT]
[STRUCT:EDIT.main]
AFTER
''';

    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(source).single;
    final CompiledScript compiled = compileScript(source);
    final TerminalEngine terminal = TerminalEngine();

    terminal.setup(
      templateText: compiled.engineText,
      fontColor: Colors.green,
      bgColor: Colors.black,
      width: 1920,
      height: 1080,
      scale: 1,
      fontPath: 'monospace',
      fontSize: 24,
      lineSpacing: 30,
      tracking: 0,
      marginTop: 40,
      marginSide: 40,
    );

    final List<int> localFrames = <int>[];
    int guard = 0;
    while (!terminal.isFinished && guard < 1000) {
      terminal.tick();
      guard++;

      final StructuralRuntimeMarker? marker =
          parseStructuralRuntimeRegion(terminal.currentRegion);
      if (marker == null) continue;

      final bool awaitingPauseTag = terminal.activePause == null &&
          terminal.charIndex < terminal.text.length &&
          terminal.text.startsWith('[PAUSE:', terminal.charIndex);

      localFrames.add(
        structuralRuntimeLocalFrame(
          marker: marker,
          pauseFramesRemaining: terminal.pauseFrames,
          awaitingPauseTag: awaitingPauseTag,
        ),
      );
    }

    expect(guard, lessThan(1000));
    expect(localFrames.length, placement.durationFrames);
    expect(
      localFrames,
      List<int>.generate(placement.durationFrames, (int i) => i),
    );
    expect(terminal.currentRegion, isNull);
  });
}
