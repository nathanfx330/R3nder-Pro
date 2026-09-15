// ./test/program_structural_audio_mosaic_nested_test.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/program_structural_audio.dart';
import 'package:r3nder/scene_engine.dart';
import 'package:r3nder/script_pipeline.dart';
import 'package:r3nder/structural_audio_decode.dart';
import 'package:r3nder/structural_audio_plan.dart';
import 'package:r3nder/structural_audio_render.dart';

const String _source = '''[SPEED:MAX]
[EDIT:child]
[TRACK:V1]
[CLIP:leaf:video/leaf.mp4:0:0:2:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:left]
[CLIP:nested:EDIT.child:0:0:2:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall:AUDIO]
''';

class _ConstantLeafDecoder implements StructuralAudioLeafDecodeBackend {
  final List<String> calls = <String>[];

  @override
  Future<StructuralAudioLeafDecode> decode(
    StructuralAudioSegment segment,
    String resolvedPath,
  ) async {
    calls.add(resolvedPath);

    final StructuralAudioSourceInfo info = StructuralAudioSourceInfo.audio(
      path: resolvedPath,
      sourceFpsNumerator: 30,
      sourceFpsDenominator: 1,
      audioSampleRate: 48000,
      audioChannels: 2,
      audioChannelLayout: 'stereo',
    );
    final StructuralAudioDecodeWindow window =
        StructuralAudioDecodeWindow.forSegment(segment, info);
    final Float32List pcm = Float32List(
      window.requiredSampleFrames * kStructuralAudioChannels,
    );

    for (int sample = 0; sample < window.requiredSampleFrames; sample++) {
      final int base = sample * kStructuralAudioChannels;
      pcm[base] = 0.375;
      pcm[base + 1] = -0.125;
    }

    return StructuralAudioLeafDecode.decoded(
      sourceInfo: info,
      authoredProjectSampleFrames: segment.sampleCount,
      window: window,
      interleavedStereo: pcm,
    );
  }
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
  testWidgets(
      'AUDIO MOSAIC placement reaches EDIT leaf media at exact program sample',
      (WidgetTester tester) async {
    final Directory root =
        Directory.systemTemp.createTempSync('r3_mosaic_struct_audio_');
    final Directory images = Directory('${root.path}/images')
      ..createSync(recursive: true);
    final Directory sprites = Directory('${root.path}/sprites')
      ..createSync(recursive: true);
    final SceneEngine scene = SceneEngine();

    addTearDown(() {
      scene.disposeImages();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    final CompiledScript compiled = compileScript(_source);
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
      rawDocument: _source,
      totalFrames: totalFrames,
    );

    expect(timeline.occurrences, hasLength(1));
    final ProgramStructuralAudioOccurrence occurrence =
        timeline.occurrences.single;
    expect(occurrence.sourceRef.canonicalSource, 'MOSAIC.wall');
    expect(occurrence.sourceDurationFrames, 2);

    final _ConstantLeafDecoder decoder = _ConstantLeafDecoder();
    final StructuralAudioSourceRenderer sourceRenderer =
        StructuralAudioSourceRenderer(
      planner: StructuralAudioPlanner.parse(_source),
      leafDecoder: decoder,
      resolveSource: (String source) => '/workspace/$source',
    );
    final ProgramStructuralAudioRender rendered =
        await ProgramStructuralAudioRenderer(
      timeline: timeline,
      renderSource: sourceRenderer.render,
    ).render();

    final int first = occurrence.programStartSample * kStructuralAudioChannels;
    expect(rendered.interleavedStereo[first], closeTo(0.375, 1e-7));
    expect(rendered.interleavedStereo[first + 1], closeTo(-0.125, 1e-7));
    if (first >= kStructuralAudioChannels) {
      expect(rendered.interleavedStereo[first - kStructuralAudioChannels], 0.0);
    }
    expect(decoder.calls, <String>['/workspace/video/leaf.mp4']);
  });
}
