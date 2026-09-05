// ./test/program_structural_export_test.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/program_structural_export.dart';
import 'package:r3nder/project_clock.dart';
import 'package:r3nder/scene_engine.dart';
import 'package:r3nder/scene_evaluator.dart';
import 'package:r3nder/script_pipeline.dart';
import 'package:r3nder/structural_sequence.dart';
import 'package:r3nder/structural_source_export.dart';

class _RecordingBackend implements MediaDecoderBackend {
  final Map<String, List<int>> requests = <String, List<int>>{};
  int opens = 0;

  @override
  MediaDecoder open(String resolvedPath) {
    opens++;
    return _RecordingDecoder(
      resolvedPath,
      (int frame) => requests
          .putIfAbsent(resolvedPath, () => <int>[])
          .add(frame),
    );
  }
}

class _RecordingDecoder implements MediaDecoder {
  final String path;
  final void Function(int frame) onRequest;

  _RecordingDecoder(this.path, this.onRequest);

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    onRequest(requestedSourceFrame);

    final Uint8List rgba = Uint8List(width * height * 4);
    for (int i = 0; i < rgba.length; i += 4) {
      rgba[i] = 255;
      rgba[i + 1] = 0;
      rgba[i + 2] = 0;
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

int _runtimeLocalFrame(SceneEngine scene, StructuralRuntimeMarker marker) {
  final terminal = scene.terminal;
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
  test(
    'whole-program STRUCT runtime selects exact authored media frames for bake',
    () async {
      const String source = '''[SPEED:MAX]BEFORE
[EDIT:main]
[TRACK:V1]
[CLIP:leaf:leaf.mp4:0:0:3:1]
[/CLIP]
[/TRACK]
[/EDIT]
[STRUCT:EDIT.main]
AFTER
''';

      final Directory root =
          await Directory.systemTemp.createTemp('r3nder_program_struct_export_');
      final Directory images = Directory('${root.path}/images')
        ..createSync(recursive: true);
      final Directory sprites = Directory('${root.path}/sprites')
        ..createSync(recursive: true);

      final SceneEngine scene = SceneEngine();
      final _RecordingBackend backend = _RecordingBackend();
      final ProgramStructuralFrameRenderer programRenderer =
          ProgramStructuralFrameRenderer(
        rawDocument: source,
        width: 320,
        height: 180,
        backend: backend,
        resolveSource: (String value) => value,
      );
      final StructuralSourceFrameRenderer sourceRenderer =
          StructuralSourceFrameRenderer.create(
        source: source,
        structuralSource: 'EDIT.main',
        width: 4,
        height: 2,
        backend: backend,
        resolveSource: (String value) => value,
      );

      addTearDown(() {
        sourceRenderer.dispose();
        programRenderer.dispose();
        scene.disposeImages();
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      final List<StructuralSequencePlacement> placements =
          parseStructuralSequencePlacements(source);
      expect(placements, hasLength(1));
      final StructuralSequencePlacement placement = placements.single;
      expect(placement.resolves, isTrue);
      expect(programRenderer.hasPlacements, isTrue);
      expect(sourceRenderer.totalFrames, 3);

      final CompiledScript compiled = compileScript(source, lineMarkers: false);
      await scene.setup(
        templateText: compiled.engineText,
        fontColor: Colors.green,
        bgColor: Colors.black,
        width: 320,
        height: 180,
        scale: 1,
        fontPath: 'monospace',
        fontSize: 12,
        lineSpacing: 16,
        tracking: 0,
        marginTop: 10,
        marginSide: 10,
        imagesDir: images.path,
        spritesDir: sprites.path,
        paneLifeConfig: compiled.paneLife,
        captionConfig: compiled.caption,
        appSwitchConfig: compiled.appSwitch,
      );

      int? firstStructProjectFrame;
      int? showingProjectFrame;

      for (int projectFrame = 0; projectFrame < 300; projectFrame++) {
        final SceneEvaluationResult result = scene.evaluate(
          ProjectTime(frame: projectFrame, mode: ProjectClockMode.scrub),
        );
        expect(result.exact, isTrue);

        final StructuralRuntimeMarker? marker =
            parseStructuralRuntimeRegion(scene.terminal.currentRegion);
        if (marker == null) continue;

        firstStructProjectFrame ??= projectFrame;
        expect(marker.placementIndex, 0);
        expect(marker.durationFrames, placement.durationFrames);

        final int localFrame = _runtimeLocalFrame(scene, marker);
        if (localFrame == kStructuralEntryFrames) {
          showingProjectFrame = projectFrame;
          break;
        }
      }

      expect(firstStructProjectFrame, isNotNull);
      expect(showingProjectFrame, isNotNull);
      final int firstStruct = firstStructProjectFrame!;
      final int showing = showingProjectFrame!;

      final int before = firstStruct - 1;
      expect(before, greaterThanOrEqualTo(0));
      scene.evaluate(
        ProjectTime(frame: before, mode: ProjectClockMode.scrub),
      );
      expect(
        parseStructuralRuntimeRegion(scene.terminal.currentRegion),
        isNull,
      );

      scene.evaluate(
        ProjectTime(frame: showing, mode: ProjectClockMode.scrub),
      );
      StructuralRuntimeMarker? marker =
          parseStructuralRuntimeRegion(scene.terminal.currentRegion);
      expect(marker, isNotNull);
      int localFrame = _runtimeLocalFrame(scene, marker!);
      expect(placement.stageAt(localFrame), StructuralSequenceStage.showing);
      expect(placement.sourceFrameAt(localFrame), 0);

      final Uint8List first = sourceRenderer.renderFrame(
        placement.sourceFrameAt(localFrame),
      );
      expect(backend.requests['leaf.mp4'], <int>[0]);
      expect(backend.opens, 1);
      expect(first.sublist(0, 4), <int>[255, 0, 0, 255]);

      scene.evaluate(
        ProjectTime(frame: showing + 1, mode: ProjectClockMode.scrub),
      );
      marker = parseStructuralRuntimeRegion(scene.terminal.currentRegion);
      expect(marker, isNotNull);
      localFrame = _runtimeLocalFrame(scene, marker!);
      expect(placement.stageAt(localFrame), StructuralSequenceStage.showing);
      expect(placement.sourceFrameAt(localFrame), 1);

      sourceRenderer.renderFrame(placement.sourceFrameAt(localFrame));
      expect(backend.requests['leaf.mp4'], <int>[0, 1]);
      expect(backend.opens, 1);

      int? firstFrameAfterStruct;
      for (int projectFrame = showing + 1;
          projectFrame < 300;
          projectFrame++) {
        scene.evaluate(
          ProjectTime(frame: projectFrame, mode: ProjectClockMode.scrub),
        );
        if (parseStructuralRuntimeRegion(scene.terminal.currentRegion) == null) {
          firstFrameAfterStruct = projectFrame;
          break;
        }
      }

      expect(firstFrameAfterStruct, isNotNull);
      expect(firstFrameAfterStruct, greaterThan(showing));
    },
  );
}
