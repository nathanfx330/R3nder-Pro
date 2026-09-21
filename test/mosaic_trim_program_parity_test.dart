// ./test/mosaic_trim_program_parity_test.dart

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/mosaic_trim.dart';
import 'package:r3nder/program_structural_audio.dart';
import 'package:r3nder/scene_engine.dart';
import 'package:r3nder/script_pipeline.dart';
import 'package:r3nder/structural_audio_plan.dart';
import 'package:r3nder/structural_sequence.dart';

const String _source = '''[SPEED:MAX]
[EDIT:child]
[TRACK:V1]
[CLIP:leaf:video/leaf.mp4:0:0:8:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:short]
[CLIP:short:EDIT.child:0:0:3:1]
[/CLIP]
[/PANE]
[PANE:long]
[CLIP:long:EDIT.child:0:0:6:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall:AUDIO]
''';

int _programDuration(SceneEngine scene) {
  scene.reset();
  int frames = 0;
  while (!scene.isFinished) {
    scene.tick();
    frames++;
    if (frames > 1000) {
      fail('Scene did not finish while measuring program duration.');
    }
  }
  scene.reset();
  return frames;
}

Future<({int totalFrames, ProgramStructuralAudioTimeline timeline})>
    _traceAudio(
  WidgetTester tester,
  String source,
  Directory images,
  Directory sprites,
) async {
  final CompiledScript compiled = compileScript(source);
  final SceneEngine scene = SceneEngine();
  try {
    await tester.runAsync(() async {
      await scene.setup(
        templateText: compiled.engineText,
        fontColor: Colors.green,
        bgColor: Colors.black,
        width: 640,
        height: 360,
        scale: 1,
        fontPath: 'monospace',
        fontSize: 18,
        lineSpacing: 22,
        tracking: 0,
        marginTop: 20,
        marginSide: 20,
        imagesDir: images.path,
        spritesDir: sprites.path,
        paneLifeConfig: compiled.paneLife,
        captionConfig: compiled.caption,
        appSwitchConfig: compiled.appSwitch,
      );
    });

    final int totalFrames = _programDuration(scene);
    final ProgramStructuralAudioTimeline timeline =
        traceProgramStructuralAudioTimeline(
      scene: scene,
      rawDocument: source,
      totalFrames: totalFrames,
    );
    return (totalFrames: totalFrames, timeline: timeline);
  } finally {
    scene.disposeImages();
  }
}

void main() {
  test('trimmed MOSAIC shortens the structural presentation at the same boundary',
      () {
    final StructuralSequencePlacement before =
        parseStructuralSequencePlacements(_source).single;
    expect(before.sourceRef.canonicalSource, 'MOSAIC.wall');
    expect(before.sourceDurationFrames, 6);

    final String trimmed = trimMosaicToShortest(_source, 'wall');
    final StructuralSequencePlacement after =
        parseStructuralSequencePlacements(trimmed).single;

    expect(after.sourceDurationFrames, 3);
    expect(before.durationFrames - after.durationFrames, 3);
    expect(after.contentStartFrame, before.contentStartFrame);
    expect(after.sourceFrameAt(after.contentStartFrame), 0);
    expect(after.sourceFrameAt(after.contentStartFrame + 2), 2);
    expect(
      after.stageAt(after.contentStartFrame + 2),
      StructuralSequenceStage.showing,
    );
    expect(
      after.stageAt(after.contentStartFrame + 3),
      StructuralSequenceStage.closing,
    );
  });

  testWidgets('trimmed MOSAIC program audio uses the same shortened source span',
      (WidgetTester tester) async {
    final Directory root =
        Directory.systemTemp.createTempSync('r3_mosaic_trim_program_parity_');
    final Directory images = Directory('${root.path}/images')
      ..createSync(recursive: true);
    final Directory sprites = Directory('${root.path}/sprites')
      ..createSync(recursive: true);
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    final String trimmed = trimMosaicToShortest(_source, 'wall');
    final before = await _traceAudio(tester, _source, images, sprites);
    final after = await _traceAudio(tester, trimmed, images, sprites);

    expect(before.timeline.occurrences, hasLength(1));
    expect(after.timeline.occurrences, hasLength(1));

    final ProgramStructuralAudioOccurrence beforeAudio =
        before.timeline.occurrences.single;
    final ProgramStructuralAudioOccurrence afterAudio =
        after.timeline.occurrences.single;
    final StructuralSequencePlacement afterPlacement =
        parseStructuralSequencePlacements(trimmed).single;

    expect(beforeAudio.sourceDurationFrames, 6);
    expect(afterAudio.sourceDurationFrames, 3);
    expect(
      afterAudio.sourceDurationFrames,
      afterPlacement.sourceDurationFrames,
    );
    expect(afterAudio.programStartFrame, beforeAudio.programStartFrame);
    expect(
      beforeAudio.programEndFrameExclusive - afterAudio.programEndFrameExclusive,
      3,
    );
    expect(
      before.totalFrames - after.totalFrames,
      3,
      reason: 'Shortening the reusable MOSAIC must shorten program time once.',
    );
    expect(
      afterAudio.sampleCount,
      structuralAudioSamplesForProjectFrames(3),
    );
  });
}
