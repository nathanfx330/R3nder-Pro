// ./test/structural_runtime_marker_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/engine.dart';
import 'package:r3nder/script_pipeline.dart';
import 'package:r3nder/structural_sequence.dart';

TerminalEngine _terminalFor(String engineText) {
  final TerminalEngine terminal = TerminalEngine();
  terminal.setup(
    templateText: engineText,
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
  return terminal;
}

int _localFrame(TerminalEngine terminal, StructuralRuntimeMarker marker) {
  final bool awaitingPauseTag = terminal.activePause == null &&
      terminal.charIndex >= 0 &&
      terminal.charIndex < terminal.text.length &&
      terminal.text.startsWith('[PAUSE:', terminal.charIndex);

  return structuralRuntimeLocalFrame(
    marker: marker,
    pauseFramesRemaining: terminal.pauseFrames,
    awaitingPauseTag: awaitingPauseTag,
  );
}

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
    final TerminalEngine terminal = _terminalFor(compiled.engineText);

    final List<int> localFrames = <int>[];
    int guard = 0;
    while (!terminal.isFinished && guard < 1000) {
      terminal.tick();
      guard++;

      final StructuralRuntimeMarker? marker =
          parseStructuralRuntimeRegion(terminal.currentRegion);
      if (marker == null) continue;
      localFrames.add(_localFrame(terminal, marker));
    }

    expect(guard, lessThan(1000));
    expect(localFrames.length, placement.durationFrames);
    expect(
      localFrames,
      List<int>.generate(placement.durationFrames, (int i) => i),
    );
    expect(terminal.currentRegion, isNull);
  });

  test('adjacent STRUCT markers hand off with no null frame at normal speed', () {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:c:video/c.mp4:0:0:3:1]
[/CLIP]
[/TRACK]
[/EDIT]
[STRUCT:EDIT.main]
[STRUCT:EDIT.main]
''';

    final List<StructuralSequencePlacement> placements =
        parseStructuralSequencePlacements(source);
    expect(placements, hasLength(2));
    expect(placements[0].durationFrames, 45);
    expect(placements[1].durationFrames, 45);

    final CompiledScript compiled = compileScript(source);
    expect(
      compiled.engineText,
      contains(
        '[REGION:STRUCTSEQ_0_45][PAUSE:43]'
        '[REGION:STRUCTSEQ_1_45][PAUSE:43]',
      ),
    );

    final TerminalEngine terminal = _terminalFor(compiled.engineText);
    final Map<int, List<int>> localFrames = <int, List<int>>{
      0: <int>[],
      1: <int>[],
    };

    bool sawFirst = false;
    bool sawSecond = false;
    bool nullBetweenPlacements = false;
    int guard = 0;

    while (!terminal.isFinished && guard < 1000) {
      terminal.tick();
      guard++;

      final StructuralRuntimeMarker? marker =
          parseStructuralRuntimeRegion(terminal.currentRegion);
      if (marker == null) {
        if (sawFirst && !sawSecond) nullBetweenPlacements = true;
        continue;
      }

      if (marker.placementIndex == 0) sawFirst = true;
      if (marker.placementIndex == 1) sawSecond = true;
      localFrames[marker.placementIndex]?.add(_localFrame(terminal, marker));
    }

    expect(guard, lessThan(1000));
    expect(sawFirst, isTrue);
    expect(sawSecond, isTrue);
    expect(nullBetweenPlacements, isFalse);

    for (int index = 0; index < placements.length; index++) {
      expect(
        localFrames[index],
        List<int>.generate(
          placements[index].durationFrames,
          (int frame) => frame,
        ),
        reason: 'STRUCT placement $index must own every planned frame once.',
      );
    }
  });
}
