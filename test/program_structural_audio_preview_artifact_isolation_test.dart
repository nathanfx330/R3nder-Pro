// ./test/program_structural_audio_preview_artifact_isolation_test.dart

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
  @override
  Future<StructuralAudioLeafDecode> decode(
    StructuralAudioSegment segment,
    String resolvedPath,
  ) async {
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

const String _document = '''[SPEED:MAX]
[EDIT:main]
[TRACK:V1]
[CLIP:leaf:video/leaf.mp4:0:0:3:1]
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
      withPreroll: false,
      prerollBgColor: Colors.green,
    );
  });
}

void main() {
  testWidgets('independent preview artifacts never share a temp path',
      (WidgetTester tester) async {
    final Directory root =
        Directory.systemTemp.createTempSync('r3_struct_preview_isolation_');
    final Directory images = Directory('${root.path}/images')..createSync();
    final Directory sprites = Directory('${root.path}/sprites')..createSync();
    final Directory temp = Directory('${root.path}/preview')..createSync();
    final SceneEngine scene = SceneEngine();
    final _NoAudioLeafDecoder decoder = _NoAudioLeafDecoder();

    addTearDown(() {
      scene.disposeImages();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    await _setupScene(tester, scene, images, sprites);

    Future<ProgramStructuralAudioPreviewArtifact?> prepare() {
      return tester.runAsync<ProgramStructuralAudioPreviewArtifact?>(
        () => prepareProgramStructuralAudioPreviewArtifact(
          scene: scene,
          rawDocument: _document,
          resolveSource: (String source) => '${root.path}/$source',
          tempDirectory: temp.path,
          leafDecoder: decoder,
        ),
      );
    }

    final ProgramStructuralAudioPreviewArtifact first = (await prepare())!;
    final ProgramStructuralAudioPreviewArtifact second = (await prepare())!;

    expect(first.path, isNot(second.path));
    expect(File(first.path).existsSync(), isTrue);
    expect(File(second.path).existsSync(), isTrue);

    first.delete();
    expect(File(first.path).existsSync(), isFalse);
    expect(File(second.path).existsSync(), isTrue);

    second.delete();
    expect(File(second.path).existsSync(), isFalse);
  });
}
