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
import 'package:r3nder/structural_sequence.dart';

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

    // Solid red makes the center of the authored video client trivial to
    // identify in the fully composited program frame.
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
  testWidgets(
    'whole-program bake overrides only active STRUCT frames and requests exact authored media frame',
    (WidgetTester tester) async {
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
      final ProgramStructuralFrameRenderer renderer =
          ProgramStructuralFrameRenderer(
        rawDocument: source,
        width: 320,
        height: 180,
        backend: backend,
        resolveSource: (String value) => value,
      );

      addTearDown(() {
        renderer.dispose();
        scene.disposeImages();
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

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

      expect(renderer.hasPlacements, isTrue);
      expect(await renderer.renderIfActive(
        scene: scene,
        fontFamily: 'monospace',
      ), isNull);

      int? firstStructProjectFrame;
      int? showingProjectFrame;
      int? firstFrameAfterStruct;
      bool wasInsideStruct = false;

      for (int projectFrame = 0; projectFrame < 300; projectFrame++) {
        final result = scene.evaluate(
          ProjectTime(frame: projectFrame, mode: ProjectClockMode.scrub),
        );
        expect(result.exact, isTrue);

        final StructuralRuntimeMarker? marker =
            parseStructuralRuntimeRegion(scene.terminal.currentRegion);

        if (marker != null) {
          wasInsideStruct = true;
          firstStructProjectFrame ??= projectFrame;
          final int localFrame = _runtimeLocalFrame(scene, marker);
          if (localFrame == kStructuralEntryFrames) {
            showingProjectFrame ??= projectFrame;
            break;
          }
        } else if (wasInsideStruct) {
          firstFrameAfterStruct = projectFrame;
          break;
        }
      }

      expect(firstStructProjectFrame, isNotNull);
      expect(showingProjectFrame, isNotNull);
      final int firstStruct = firstStructProjectFrame!;
      final int showing = showingProjectFrame!;

      // One frame before the runtime marker must stay on the historical
      // SceneCompositor path. The structural renderer is an override only.
      final int before = firstStruct - 1;
      expect(before, greaterThanOrEqualTo(0));
      scene.evaluate(ProjectTime(frame: before, mode: ProjectClockMode.scrub));
      expect(await renderer.renderIfActive(
        scene: scene,
        fontFamily: 'monospace',
      ), isNull);

      // The first SHOWING frame is authored source frame zero.
      scene.evaluate(
        ProjectTime(frame: showing, mode: ProjectClockMode.scrub),
      );
      final ui.Image? composited = await renderer.renderIfActive(
        scene: scene,
        fontFamily: 'monospace',
      );
      expect(composited, isNotNull);
      expect(backend.requests['leaf.mp4'], <int>[0]);
      expect(backend.opens, 1);

      final ByteData? raw =
          await composited!.toByteData(format: ui.ImageByteFormat.rawRgba);
      expect(raw, isNotNull);
      final Uint8List bytes = raw!.buffer.asUint8List(
        raw.offsetInBytes,
        raw.lengthInBytes,
      );
      final int center = ((90 * 320) + 160) * 4;
      expect(bytes.sublist(center, center + 4), <int>[255, 0, 0, 255]);
      composited.dispose();

      // Advance one project frame. Exact source-frame ownership must advance
      // with authored STRUCT time, never with decoder completion order.
      scene.evaluate(
        ProjectTime(frame: showing + 1, mode: ProjectClockMode.scrub),
      );
      final ui.Image? next = await renderer.renderIfActive(
        scene: scene,
        fontFamily: 'monospace',
      );
      expect(next, isNotNull);
      expect(backend.requests['leaf.mp4'], <int>[0, 1]);
      next!.dispose();

      // Find the first project frame after the reserved STRUCT runtime region.
      // Do not assume a hidden parser-tax here; the runtime marker itself is
      // the public contract the exporter observes.
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
      scene.evaluate(
        ProjectTime(frame: firstFrameAfterStruct!, mode: ProjectClockMode.scrub),
      );
      expect(await renderer.renderIfActive(
        scene: scene,
        fontFamily: 'monospace',
      ), isNull);
    },
  );
}
