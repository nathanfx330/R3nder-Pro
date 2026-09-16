// ./test/program_structural_export_test.dart

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/program_structural_export.dart';
import 'package:r3nder/project_clock.dart';
import 'package:r3nder/scene_engine.dart';
import 'package:r3nder/scene_evaluator.dart';
import 'package:r3nder/script_pipeline.dart';
import 'package:r3nder/sidecard_geometry.dart';
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

Rect? _solidRedBounds(Uint8List rgba, int width, int height) {
  int minX = width;
  int minY = height;
  int maxX = -1;
  int maxY = -1;

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final int i = (y * width + x) * 4;
      final int r = rgba[i];
      final int g = rgba[i + 1];
      final int b = rgba[i + 2];
      final int a = rgba[i + 3];
      if (r < 240 || g > 20 || b > 20 || a < 240) continue;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
  }

  if (maxX < minX || maxY < minY) return null;
  return Rect.fromLTRB(
    minX.toDouble(),
    minY.toDouble(),
    (maxX + 1).toDouble(),
    (maxY + 1).toDouble(),
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

  test(
    'BAKE uses shared SIDECARD motion at a mid-slide frame',
    () async {
      const String source = '''[SPEED:MAX]BEFORE
[EDIT:main]
[TRACK:V1]
[CLIP:leaf:leaf.mp4:0:0:120:1]
[CUE:0]
[SIDECARD:missing.png:45:24,32,40:JOHN SMITH]
Biography text.
[/SIDECARD]
[/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
[STRUCT:EDIT.main]
AFTER
''';

      const int outputWidth = 320;
      const int outputHeight = 180;
      final Size outputSize = Size(
        outputWidth.toDouble(),
        outputHeight.toDouble(),
      );
      final Directory root = await Directory.systemTemp
          .createTemp('r3nder_program_sidecard_motion_');
      final Directory images = Directory('${root.path}/images')
        ..createSync(recursive: true);
      final Directory sprites = Directory('${root.path}/sprites')
        ..createSync(recursive: true);

      final SceneEngine scene = SceneEngine();
      final _RecordingBackend backend = _RecordingBackend();
      final ProgramStructuralFrameRenderer renderer =
          ProgramStructuralFrameRenderer(
        rawDocument: source,
        width: outputWidth,
        height: outputHeight,
        backend: backend,
        resolveSource: (String value) => value,
      );

      addTearDown(() {
        renderer.dispose();
        scene.disposeImages();
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      final StructuralSequencePlacement placement =
          parseStructuralSequencePlacements(source).single;
      final CompiledScript compiled = compileScript(source, lineMarkers: false);

      // Keep the SceneEngine at authored 1920x1080 while rendering a 320x180
      // bake frame. That gives structural chrome the same output scale used by
      // the SIDECARD geometry helper instead of making a low-resolution test
      // scene carry a 38px title bar.
      await scene.setup(
        templateText: compiled.engineText,
        fontColor: Colors.green,
        bgColor: Colors.black,
        width: 1920,
        height: 1080,
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

      int? targetProjectFrame;
      for (int projectFrame = 0; projectFrame < 500; projectFrame++) {
        scene.evaluate(
          ProjectTime(frame: projectFrame, mode: ProjectClockMode.scrub),
        );
        final StructuralRuntimeMarker? marker =
            parseStructuralRuntimeRegion(scene.terminal.currentRegion);
        if (marker == null) continue;
        final int localFrame = _runtimeLocalFrame(scene, marker);
        if (placement.stageAt(localFrame) == StructuralSequenceStage.showing &&
            placement.sourceFrameAt(localFrame) == 8) {
          targetProjectFrame = projectFrame;
          break;
        }
      }
      expect(targetProjectFrame, isNotNull);

      // The cue starts at source frame zero. At source frame eight, its
      // 16-frame opening has slide=0.5. Keep the scene evaluated at that exact
      // project frame and ask the real program renderer for the bake pixels.
      scene.evaluate(
        ProjectTime(
          frame: targetProjectFrame!,
          mode: ProjectClockMode.scrub,
        ),
      );
      final ui.Image? image = await renderer.renderIfActive(
        scene: scene,
        fontFamily: 'monospace',
      );
      expect(image, isNotNull);
      final ui.Image rendered = image!;
      addTearDown(rendered.dispose);

      final ByteData? data =
          await rendered.toByteData(format: ui.ImageByteFormat.rawRgba);
      expect(data, isNotNull);
      final Uint8List rgba = data!.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final Rect? redBounds = _solidRedBounds(
        rgba,
        outputWidth,
        outputHeight,
      );
      expect(redBounds, isNotNull);

      final double chromeScale =
          scene.terminal.scale * outputWidth / scene.width;
      final Rect baseNormalized = structuralProgramPresentationRectForOutput(
        mode: placement.presentationMode,
        outputWidth: outputWidth,
        outputHeight: outputHeight,
        titleHeight: 38.0 * chromeScale,
      );
      final Rect basePixels = Rect.fromLTRB(
        baseNormalized.left * outputWidth,
        baseNormalized.top * outputHeight,
        baseNormalized.right * outputWidth,
        baseNormalized.bottom * outputHeight,
      );
      final SideCardShellFrame expected = sideCardShellFrameAt(
        size: outputSize,
        preCueRect: basePixels,
        slide: 0.5,
      );

      // Solid red is the structural client, so its horizontal bounds track the
      // real moving outer window. A snap straight to the seated rect differs by
      // several pixels even at this deliberately small render size.
      expect(
        redBounds!.left,
        closeTo(expected.videoWindowRect.left, 2.0),
      );
      expect(
        redBounds.right,
        closeTo(expected.videoWindowRect.right, 2.0),
      );
      expect(
        redBounds.left,
        greaterThan(sideCardSeatedVideoWindowRect(outputSize).left + 2.0),
      );
    },
  );
}
