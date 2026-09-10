// ./test/program_structural_audio_preview_session_test.dart

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/program_structural_audio_preview_session.dart';
import 'package:r3nder/scene_engine.dart';
import 'package:r3nder/script_pipeline.dart';
import 'package:r3nder/structural_audio_decode.dart';
import 'package:r3nder/structural_audio_plan.dart';
import 'package:r3nder/structural_audio_render.dart';

class _NoAudioLeafDecoder implements StructuralAudioLeafDecodeBackend {
  int calls = 0;

  @override
  Future<StructuralAudioLeafDecode> decode(
    StructuralAudioSegment segment,
    String resolvedPath,
  ) async {
    calls++;
    return StructuralAudioLeafDecode.noAudio(
      sourceInfo: StructuralAudioSourceInfo.noAudio(
        path: resolvedPath,
        sourceFpsNumerator: 30,
        sourceFpsDenominator: 1,
      ),
      authoredProjectSampleFrames: segment.sampleCount,
    );
  }
}

const String _audioDocument = '''[SPEED:MAX]
[EDIT:main]
[TRACK:V1]
[CLIP:leaf:video/leaf.mp4:0:0:3:1]
[/CLIP]
[/TRACK]
[/EDIT]
[STRUCT:EDIT.main:AUDIO]
''';

const String _silentDocument = '''[SPEED:MAX]
[EDIT:main]
[TRACK:V1]
[CLIP:leaf:video/leaf.mp4:0:0:3:1]
[/CLIP]
[/TRACK]
[/EDIT]
[STRUCT:EDIT.main]
''';

Future<void> _setupScene(
  WidgetTester tester,
  SceneEngine scene,
  String document,
  Directory images,
  Directory sprites, {
  bool withPreroll = false,
}) async {
  final CompiledScript compiled = compileScript(document);
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
      withPreroll: withPreroll,
      prerollBgColor: Colors.green,
    );
  });
}

void main() {
  testWidgets('preview timing dry run leaves the scene at frame zero',
      (WidgetTester tester) async {
    final Directory root =
        Directory.systemTemp.createTempSync('r3_struct_preview_timing_');
    final Directory images = Directory('${root.path}/images')..createSync();
    final Directory sprites = Directory('${root.path}/sprites')..createSync();
    final SceneEngine scene = SceneEngine();
    addTearDown(() {
      scene.disposeImages();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    await _setupScene(
      tester,
      scene,
      _audioDocument,
      images,
      sprites,
      withPreroll: true,
    );

    final ProgramStructuralAudioPreviewTiming timing =
        measureProgramStructuralAudioPreviewTiming(scene);

    expect(timing.totalFrames, greaterThan(0));
    expect(timing.audioStartFrame, greaterThan(0));
    expect(
      timing.programSampleFrames,
      timing.totalFrames * kStructuralAudioSamplesPerProjectFrame,
    );
    expect(
      timing.bedDelayMs,
      (timing.audioStartFrame * 1000 / kStructuralAudioProjectFps).round(),
    );
    expect(scene.frameCount, 0);
  });

  testWidgets('preview artifact owns exact program WAV and deletes cleanly',
      (WidgetTester tester) async {
    final Directory root =
        Directory.systemTemp.createTempSync('r3_struct_preview_artifact_');
    final Directory images = Directory('${root.path}/images')..createSync();
    final Directory sprites = Directory('${root.path}/sprites')..createSync();
    final Directory temp = Directory('${root.path}/preview')..createSync();
    final SceneEngine scene = SceneEngine();
    final _NoAudioLeafDecoder decoder = _NoAudioLeafDecoder();
    addTearDown(() {
      scene.disposeImages();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    await _setupScene(
      tester,
      scene,
      _audioDocument,
      images,
      sprites,
    );

    final ProgramStructuralAudioPreviewArtifact? artifact =
        await tester.runAsync(() => prepareProgramStructuralAudioPreviewArtifact(
              scene: scene,
              rawDocument: _audioDocument,
              resolveSource: (String source) => '${root.path}/$source',
              tempDirectory: temp.path,
              leafDecoder: decoder,
            ));

    expect(artifact, isNotNull);
    final ProgramStructuralAudioPreviewArtifact ready = artifact!;
    expect(decoder.calls, 1);
    expect(ready.timeline.occurrences, hasLength(1));
    expect(
      ready.programSampleFrames,
      ready.timeline.durationFrames * kStructuralAudioSamplesPerProjectFrame,
    );
    expect(File(ready.path).existsSync(), isTrue);
    expect(File(ready.path).lengthSync(), 44 + ready.programSampleFrames * 2 * 4);
    expect(scene.frameCount, 0);

    ready.delete();
    expect(File(ready.path).existsSync(), isFalse);
  });

  testWidgets('document without AUDIO skips decode and creates no temp WAV',
      (WidgetTester tester) async {
    final Directory root =
        Directory.systemTemp.createTempSync('r3_struct_preview_none_');
    final Directory images = Directory('${root.path}/images')..createSync();
    final Directory sprites = Directory('${root.path}/sprites')..createSync();
    final Directory temp = Directory('${root.path}/preview')..createSync();
    final SceneEngine scene = SceneEngine();
    final _NoAudioLeafDecoder decoder = _NoAudioLeafDecoder();
    addTearDown(() {
      scene.disposeImages();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    await _setupScene(
      tester,
      scene,
      _silentDocument,
      images,
      sprites,
    );

    final ProgramStructuralAudioPreviewArtifact? artifact =
        await tester.runAsync(() => prepareProgramStructuralAudioPreviewArtifact(
              scene: scene,
              rawDocument: _silentDocument,
              resolveSource: (String source) => '${root.path}/$source',
              tempDirectory: temp.path,
              leafDecoder: decoder,
            ));

    expect(artifact, isNull);
    expect(decoder.calls, 0);
    expect(
      temp
          .listSync()
          .whereType<File>()
          .where((File file) =>
              file.path.contains('.r3nder_struct_preview_audio_')),
      isEmpty,
    );
    expect(scene.frameCount, 0);
  });
}
