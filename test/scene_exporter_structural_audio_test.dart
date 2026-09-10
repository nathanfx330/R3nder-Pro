// ./test/scene_exporter_structural_audio_test.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/engine.dart';
import 'package:r3nder/exporter.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/program_structural_audio.dart';
import 'package:r3nder/scene_engine.dart';
import 'package:r3nder/script_pipeline.dart';
import 'package:r3nder/structural_audio_decode.dart';
import 'package:r3nder/structural_audio_plan.dart';
import 'package:r3nder/structural_audio_render.dart';

class _SolidBackend implements MediaDecoderBackend {
  @override
  MediaDecoder open(String resolvedPath) => _SolidDecoder();
}

class _SolidDecoder implements MediaDecoder {
  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    final Uint8List rgba = Uint8List(width * height * 4);
    for (int i = 0; i < rgba.length; i += 4) {
      rgba[i] = 100;
      rgba[i + 1] = 30;
      rgba[i + 2] = 20;
      rgba[i + 3] = 255;
    }
    return DecodedMediaFrame(
      requestedSourceFrame: requestedSourceFrame,
      actualSourceFrame: requestedSourceFrame,
      width: width,
      height: height,
      stride: width * 4,
      rgba: rgba,
    );
  }

  @override
  void dispose() {}
}

class _ConstantLeafDecoder implements StructuralAudioLeafDecodeBackend {
  int calls = 0;

  @override
  Future<StructuralAudioLeafDecode> decode(
    StructuralAudioSegment segment,
    String resolvedPath,
  ) async {
    calls++;
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
    for (int frame = 0; frame < window.requiredSampleFrames; frame++) {
      final int base = frame * kStructuralAudioChannels;
      pcm[base] = 0.25;
      pcm[base + 1] = -0.25;
    }
    return StructuralAudioLeafDecode.decoded(
      sourceInfo: info,
      authoredProjectSampleFrames: segment.sampleCount,
      window: window,
      interleavedStereo: pcm,
    );
  }
}

int _sceneFrameCount(SceneEngine scene) {
  scene.reset();
  int frames = 0;
  while (!scene.isFinished) {
    scene.tick();
    frames++;
  }
  scene.reset();
  return frames;
}

double _floatSample(Uint8List bytes, int sampleFrame, int channel) {
  final int byteOffset =
      (sampleFrame * kStructuralAudioChannels + channel) * 4;
  return ByteData.sublistView(bytes).getFloat32(byteOffset, Endian.little);
}

void main() {
  testWidgets('SceneExporter muxes program STRUCT audio at program time',
      (WidgetTester tester) async {
    const int width = 320;
    const int height = 180;
    const String source = '''[SPEED:MAX]
[EDIT:main]
[TRACK:V1]
[CLIP:leaf:video/leaf.mp4:0:0:4:1]
[/CLIP]
[/TRACK]
[/EDIT]
[STRUCT:EDIT.main:AUDIO]
''';

    final ProcessResult ffmpegCheck =
        (await tester.runAsync<ProcessResult>(
      () => Process.run('ffmpeg', ['-version']),
    ))!;
    expect(ffmpegCheck.exitCode, 0, reason: 'ffmpeg is required for BAKE.');

    final Directory root =
        Directory.systemTemp.createTempSync('r3_struct_audio_bake_');
    final Directory images = Directory('${root.path}/images')
      ..createSync(recursive: true);
    final Directory sprites = Directory('${root.path}/sprites')
      ..createSync(recursive: true);
    final String output = '${root.path}/struct_audio.mov';
    final String decodedAudio = '${root.path}/decoded.f32';
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    final CompiledScript compiled = compileScript(source, lineMarkers: false);
    final SceneEngine scene = SceneEngine();
    addTearDown(scene.disposeImages);

    await tester.runAsync(() async {
      await scene.setup(
        templateText: compiled.engineText,
        fontColor: Colors.green,
        bgColor: Colors.black,
        width: width.toDouble(),
        height: height.toDouble(),
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

    final int totalFrames = _sceneFrameCount(scene);
    final ProgramStructuralAudioTimeline timeline =
        traceProgramStructuralAudioTimeline(
      scene: scene,
      rawDocument: source,
      totalFrames: totalFrames,
    );
    expect(timeline.occurrences, hasLength(1));
    final ProgramStructuralAudioOccurrence occurrence =
        timeline.occurrences.single;

    final _ConstantLeafDecoder audioDecoder = _ConstantLeafDecoder();
    final ExportResult result = (await tester.runAsync<ExportResult>(() {
      return SceneExporter.export(
        scene: scene,
        fontFamily: 'monospace',
        outputPath: output,
        format: VideoExportFormat.proresAlpha,
        fps: engineFps,
        width: width,
        height: height,
        structuralDocument: source,
        resolveStructuralSource: (String value) => '/workspace/$value',
        structuralBackend: _SolidBackend(),
        structuralAudioLeafDecoder: audioDecoder,
      );
    }))!;

    expect(result.success, isTrue, reason: result.error);
    expect(File(output).existsSync(), isTrue);
    expect(audioDecoder.calls, 1);
    expect(
      root.listSync().where((FileSystemEntity entity) {
        final String name = entity.uri.pathSegments.last;
        return name.startsWith('.r3nder_struct_audio_');
      }),
      isEmpty,
      reason: 'The program STRUCT WAV is a BAKE temporary and must be removed.',
    );

    final ProcessResult decodeResult =
        (await tester.runAsync<ProcessResult>(() {
      return Process.run('ffmpeg', <String>[
        '-y',
        '-v',
        'error',
        '-i',
        output,
        '-map',
        '0:a:0',
        '-f',
        'f32le',
        '-ac',
        '2',
        '-ar',
        '48000',
        decodedAudio,
      ]);
    }))!;
    expect(decodeResult.exitCode, 0, reason: '${decodeResult.stderr}');

    final Uint8List pcm = File(decodedAudio).readAsBytesSync();
    final int sampleFrames = pcm.length ~/ (kStructuralAudioChannels * 4);
    expect(sampleFrames, greaterThanOrEqualTo(timeline.durationSamples));

    if (occurrence.programStartSample > 0) {
      expect(
        _floatSample(pcm, occurrence.programStartSample - 1, 0).abs(),
        lessThan(1e-6),
      );
    }
    expect(
      _floatSample(pcm, occurrence.programStartSample, 0),
      closeTo(0.25, 2e-4),
    );
    expect(
      _floatSample(pcm, occurrence.programStartSample, 1),
      closeTo(-0.25, 2e-4),
    );
    expect(
      _floatSample(
        pcm,
        occurrence.programStartSample + occurrence.sampleCount - 1,
        0,
      ),
      closeTo(0.25, 2e-4),
    );
  });
}
