// ./test/program_structural_audio_test.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/program_structural_audio.dart';
import 'package:r3nder/scene_engine.dart';
import 'package:r3nder/script_pipeline.dart';
import 'package:r3nder/structural_audio_decode.dart';
import 'package:r3nder/structural_audio_plan.dart';
import 'package:r3nder/structural_audio_render.dart';
import 'package:r3nder/structural_sequence.dart';

StructuralAudioSourceRender _constantSourceRender(
  String source, {
  required int frames,
  required double left,
  required double right,
}) {
  final StructuralSourceRef ref = StructuralSourceRef.tryParse(source)!;
  final int sampleFrames =
      structuralAudioSamplesForProjectFrames(frames);
  final Float32List pcm = Float32List(
    sampleFrames * kStructuralAudioChannels,
  );
  for (int sample = 0; sample < sampleFrames; sample++) {
    final int base = sample * kStructuralAudioChannels;
    pcm[base] = left;
    pcm[base + 1] = right;
  }

  return StructuralAudioSourceRender(
    plan: StructuralAudioPlan(
      sourceRef: ref,
      durationFrames: frames,
      lanes: const <StructuralAudioLanePlan>[],
    ),
    interleavedStereo: pcm,
  );
}

double _sampleAt(
  ProgramStructuralAudioRender render,
  int projectFrame,
  int channel,
) {
  final int sampleFrame =
      structuralAudioSampleAtProjectFrame(projectFrame);
  return render.interleavedStereo[
    sampleFrame * kStructuralAudioChannels + channel
  ];
}

const String _runtimeSource = '''[SPEED:MAX]
[EDIT:main]
[TRACK:V1]
[CLIP:leaf:video/leaf.mp4:0:0:3:1]
[/CLIP]
[/TRACK]
[/EDIT]
[STRUCT:EDIT.main:AUDIO]
[STRUCT:EDIT.main]
[STRUCT:EDIT.main:AUDIO]
''';

Future<void> _setupScene(
  WidgetTester tester,
  SceneEngine scene,
  Directory images,
  Directory sprites, {
  bool lineMarkers = false,
}) async {
  final CompiledScript compiled =
      compileScript(_runtimeSource, lineMarkers: lineMarkers);
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
}

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

void main() {
  test('program renderer places source PCM on exact project-frame boundaries',
      () async {
    final StructuralSourceRef ref = StructuralSourceRef.tryParse('EDIT.main')!;
    final ProgramStructuralAudioTimeline timeline =
        ProgramStructuralAudioTimeline(
      durationFrames: 8,
      occurrences: <ProgramStructuralAudioOccurrence>[
        ProgramStructuralAudioOccurrence(
          placementIndex: 0,
          sourceRef: ref,
          programStartFrame: 2,
          sourceDurationFrames: 2,
        ),
        ProgramStructuralAudioOccurrence(
          placementIndex: 1,
          sourceRef: ref,
          programStartFrame: 5,
          sourceDurationFrames: 2,
        ),
      ],
    );

    int renderCalls = 0;
    final ProgramStructuralAudioRender rendered =
        await ProgramStructuralAudioRenderer(
      timeline: timeline,
      renderSource: (String source) async {
        renderCalls++;
        return _constantSourceRender(
          source,
          frames: 2,
          left: 0.25,
          right: -0.5,
        );
      },
    ).render();

    expect(renderCalls, 1,
        reason: 'Repeated placements must reuse one source render per pass.');
    expect(
      rendered.sampleFrames,
      structuralAudioSamplesForProjectFrames(8),
    );

    expect(_sampleAt(rendered, 0, 0), 0.0);
    expect(_sampleAt(rendered, 1, 0), 0.0);
    expect(_sampleAt(rendered, 2, 0), 0.25);
    expect(_sampleAt(rendered, 2, 1), -0.5);
    expect(_sampleAt(rendered, 3, 0), 0.25);
    expect(_sampleAt(rendered, 4, 0), 0.0);
    expect(_sampleAt(rendered, 5, 0), 0.25);
    expect(_sampleAt(rendered, 6, 1), -0.5);
    expect(_sampleAt(rendered, 7, 0), 0.0);

    final Uint8List wav = rendered.toWavBytes();
    expect(wav.sublist(0, 4), <int>[82, 73, 70, 70]);
    expect(
      wav.length,
      44 + rendered.interleavedStereo.length * 4,
    );
  });

  testWidgets(
      'runtime trace starts audio at SHOWING and omits AUDIO-disabled placements',
      (WidgetTester tester) async {
    final Directory root =
        Directory.systemTemp.createTempSync('r3_program_struct_audio_');
    final Directory images = Directory('${root.path}/images')
      ..createSync(recursive: true);
    final Directory sprites = Directory('${root.path}/sprites')
      ..createSync(recursive: true);
    final SceneEngine scene = SceneEngine();
    addTearDown(() {
      scene.disposeImages();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    await _setupScene(tester, scene, images, sprites);
    final int totalFrames = _programDuration(scene);
    final List<StructuralSequencePlacement> placements =
        parseStructuralSequencePlacements(_runtimeSource);

    expect(placements, hasLength(3));
    expect(placements[0].clipAudio, isTrue);
    expect(placements[1].clipAudio, isFalse);
    expect(placements[2].clipAudio, isTrue);

    final ProgramStructuralAudioTimeline timeline =
        traceProgramStructuralAudioTimeline(
      scene: scene,
      rawDocument: _runtimeSource,
      totalFrames: totalFrames,
    );

    expect(timeline.durationFrames, totalFrames);
    expect(timeline.occurrences, hasLength(2));
    expect(
      timeline.occurrences.map((occurrence) => occurrence.placementIndex),
      <int>[0, 2],
    );
    expect(
      timeline.occurrences.map((occurrence) => occurrence.sourceDurationFrames),
      <int>[3, 3],
    );

    final ProgramStructuralAudioOccurrence first = timeline.occurrences[0];
    final ProgramStructuralAudioOccurrence second = timeline.occurrences[1];

    expect(first.programStartFrame, greaterThan(0));
    expect(
      second.programStartFrame - first.programStartFrame,
      placements[0].durationFrames +
          placements[1].durationFrames +
          placements[2].contentStartFrame -
          placements[0].contentStartFrame,
      reason: 'The silent middle STRUCT still owns its full program time.',
    );
    expect(
      first.programStartFrame,
      lessThan(first.programEndFrameExclusive),
    );
    expect(
      second.programEndFrameExclusive,
      lessThanOrEqualTo(totalFrames),
    );
    expect(scene.frameCount, 0,
        reason: 'Tracing must leave the caller scene reset.');
  });

  testWidgets(
      'editor line-map trace finds AUDIO placements without runtime regions',
      (WidgetTester tester) async {
    final Directory root =
        Directory.systemTemp.createTempSync('r3_text_struct_audio_');
    final Directory images = Directory('${root.path}/images')
      ..createSync(recursive: true);
    final Directory sprites = Directory('${root.path}/sprites')
      ..createSync(recursive: true);
    final SceneEngine scene = SceneEngine();
    addTearDown(() {
      scene.disposeImages();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    await _setupScene(
      tester,
      scene,
      images,
      sprites,
      lineMarkers: true,
    );
    final int totalFrames = _programDuration(scene);
    final List<StructuralSequencePlacement> placements =
        parseStructuralSequencePlacements(_runtimeSource);

    final Map<int, int> eventStarts = <int, int>{};
    scene.reset();
    for (int frame = 0; frame < totalFrames; frame++) {
      scene.tick();
      for (int index = 0; index < placements.length; index++) {
        if (scene.terminal.currentRawLine == placements[index].lineIndex) {
          eventStarts.putIfAbsent(index, () => frame);
        }
      }
    }
    scene.reset();

    expect(eventStarts.keys, containsAll(<int>[0, 1, 2]));
    expect(scene.terminal.currentRegion, isNot(startsWith('STRUCTSEQ_')));

    final ProgramStructuralAudioTimeline timeline =
        traceProgramStructuralAudioTimeline(
      scene: scene,
      rawDocument: _runtimeSource,
      totalFrames: totalFrames,
      useEditorLineMap: true,
    );

    expect(timeline.durationFrames, totalFrames);
    expect(timeline.occurrences, hasLength(2));
    expect(
      timeline.occurrences.map((occurrence) => occurrence.placementIndex),
      <int>[0, 2],
    );
    expect(
      timeline.occurrences.map((occurrence) => occurrence.sourceDurationFrames),
      <int>[3, 3],
    );
    expect(
      timeline.occurrences[0].programStartFrame,
      eventStarts[0]! + placements[0].contentStartFrame,
    );
    expect(
      timeline.occurrences[1].programStartFrame,
      eventStarts[2]! + placements[2].contentStartFrame,
    );
    expect(scene.frameCount, 0,
        reason: 'Editor tracing must leave the caller scene reset.');
  });
}
