// ./test/structural_audio_preview_bake_parity_test.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/engine.dart';
import 'package:r3nder/exporter.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/program_structural_audio_preview_session.dart';
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
      rgba[i] = 90;
      rgba[i + 1] = 35;
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

class _PatternLeafDecoder implements StructuralAudioLeafDecodeBackend {
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

    final double sourceBase = resolvedPath.endsWith('/a.mp4') ? 0.10 : 0.35;
    for (int frame = 0; frame < window.requiredSampleFrames; frame++) {
      final int absoluteSourceSample = window.requiredStartSampleFrame + frame;
      final int wrapped =
          ((absoluteSourceSample % 401) + 401) % 401;
      final double value = sourceBase + wrapped / 2000.0;
      final int base = frame * kStructuralAudioChannels;
      pcm[base] = value;
      pcm[base + 1] = -value;
    }

    return StructuralAudioLeafDecode.decoded(
      sourceInfo: info,
      authoredProjectSampleFrames: segment.sampleCount,
      window: window,
      interleavedStereo: pcm,
    );
  }
}

const String _document = '''[SPEED:MAX]
[EDIT:main]
[TRACK:V1]
[CLIP:a:video/a.mp4:0:0:4:1]
[#EDIT_TRANSITION_OUT:CROSSFADE:2]
[/CLIP]
[CLIP:b:video/b.mp4:2:2:4:3/2:GAIN=-8.0]
[#EDIT_TRANSITION:CROSSFADE:2]
[/CLIP]
[/TRACK]
[/EDIT]
[STRUCT:EDIT.main:AUDIO]
''';

Future<void> _setupScene(
  WidgetTester tester,
  SceneEngine scene,
  Directory images,
  Directory sprites,
) async {
  final CompiledScript compiled = compileScript(_document);
  await tester.runAsync(() async {
    await scene.setup(
      templateText: compiled.engineText,
      fontColor: Colors.green,
      bgColor: Colors.black,
      width: 320,
      height: 180,
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

Uint8List _pcmPayload(Uint8List wav) {
  if (wav.length < 44) {
    throw StateError('Canonical structural WAV is shorter than its header.');
  }
  return Uint8List.fromList(wav.sublist(44));
}

void main() {
  testWidgets(
      'PREVIEW and BAKE prepare byte-identical canonical PCM for gain fade and rational speed',
      (WidgetTester tester) async {
    final ProcessResult ffmpegCheck =
        (await tester.runAsync<ProcessResult>(
      () => Process.run('ffmpeg', const <String>['-version']),
    ))!;
    expect(ffmpegCheck.exitCode, 0, reason: 'ffmpeg is required for BAKE.');

    final Directory root = Directory.systemTemp.createTempSync(
      'r3_struct_audio_preview_bake_parity_',
    );
    final Directory images = Directory('${root.path}/images')..createSync();
    final Directory sprites = Directory('${root.path}/sprites')..createSync();
    final Directory previewTemp = Directory('${root.path}/preview')
      ..createSync();

    final SceneEngine previewScene = SceneEngine();
    final SceneEngine bakeScene = SceneEngine();
    addTearDown(() {
      previewScene.disposeImages();
      bakeScene.disposeImages();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    await _setupScene(tester, previewScene, images, sprites);
    await _setupScene(tester, bakeScene, images, sprites);

    final _PatternLeafDecoder previewDecoder = _PatternLeafDecoder();
    final ProgramStructuralAudioPreviewArtifact? previewArtifact =
        await tester.runAsync<ProgramStructuralAudioPreviewArtifact?>(
      () => prepareProgramStructuralAudioPreviewArtifact(
        scene: previewScene,
        rawDocument: _document,
        resolveSource: (String source) => '/workspace/$source',
        tempDirectory: previewTemp.path,
        leafDecoder: previewDecoder,
      ),
    );

    expect(previewArtifact, isNotNull);
    final ProgramStructuralAudioPreviewArtifact readyPreview = previewArtifact!;
    final Uint8List previewWav = File(readyPreview.path).readAsBytesSync();
    final Uint8List previewPcm = _pcmPayload(previewWav);
    expect(previewPcm, isNotEmpty);
    expect(previewPcm.any((int byte) => byte != 0), isTrue);

    final _PatternLeafDecoder bakeDecoder = _PatternLeafDecoder();
    final ExportCancelToken cancelToken = ExportCancelToken();
    final String bakeOutput = '${root.path}/parity.mp4';
    final String bakeStructuralWav =
        '${root.path}/.r3nder_struct_audio_$pid.wav';
    Uint8List? bakeWav;

    final ExportResult bakeResult = (await tester.runAsync<ExportResult>(() {
      return SceneExporter.export(
        scene: bakeScene,
        fontFamily: 'monospace',
        outputPath: bakeOutput,
        format: VideoExportFormat.h264Solid,
        fps: engineFps,
        width: 320,
        height: 180,
        structuralDocument: _document,
        resolveStructuralSource: (String source) => '/workspace/$source',
        structuralBackend: _SolidBackend(),
        structuralAudioLeafDecoder: bakeDecoder,
        cancelToken: cancelToken,
        onStatus: (String status) {
          if (status != 'Rendering Frames...') return;

          final File seam = File(bakeStructuralWav);
          if (seam.existsSync()) {
            bakeWav = Uint8List.fromList(seam.readAsBytesSync());
          }
          cancelToken.cancel();
        },
      );
    }))!;

    expect(
      bakeResult.cancelled,
      isTrue,
      reason: 'The parity test intentionally stops BAKE after capturing its '
          'canonical structural PCM seam.',
    );
    expect(bakeWav, isNotNull);
    expect(previewDecoder.calls, 2);
    expect(bakeDecoder.calls, 2);

    final Uint8List bakePcm = _pcmPayload(bakeWav!);
    expect(bakePcm.length, previewPcm.length);
    expect(
      bakePcm,
      orderedEquals(previewPcm),
      reason: 'PREVIEW and BAKE must hand identical canonical float PCM to '
          'their transport/encoding boundaries for the same authored program.',
    );

    readyPreview.delete();
    expect(File(readyPreview.path).existsSync(), isFalse);
    expect(File(bakeStructuralWav).existsSync(), isFalse);
  });
}
