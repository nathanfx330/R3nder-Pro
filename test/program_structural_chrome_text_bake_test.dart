// ./test/program_structural_chrome_text_bake_test.dart

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

class _SolidBackend implements MediaDecoderBackend {
  @override
  MediaDecoder open(String resolvedPath) => _SolidDecoder();
}

class _SolidDecoder implements MediaDecoder {
  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    final Uint8List rgba = Uint8List(width * height * 4);
    for (int i = 0; i < rgba.length; i += 4) {
      rgba[i] = 180;
      rgba[i + 1] = 20;
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

int _lightNeutralPixels(Uint8List rgba, int width, Rect region) {
  final int left = region.left.floor().clamp(0, width - 1);
  final int right = region.right.ceil().clamp(0, width);
  final int height = rgba.length ~/ (width * 4);
  final int top = region.top.floor().clamp(0, height - 1);
  final int bottom = region.bottom.ceil().clamp(0, height);
  int count = 0;

  for (int y = top; y < bottom; y++) {
    for (int x = left; x < right; x++) {
      final int i = (y * width + x) * 4;
      final int r = rgba[i];
      final int g = rgba[i + 1];
      final int b = rgba[i + 2];
      final int hi = r > g ? (r > b ? r : b) : (g > b ? g : b);
      final int lo = r < g ? (r < b ? r : b) : (g < b ? g : b);
      if (r > 90 && g > 90 && b > 90 && hi - lo < 45) count++;
    }
  }
  return count;
}

void main() {
  testWidgets('final STRUCT bake raster contains authored chrome text',
      (WidgetTester tester) async {
    const int width = 640;
    const int height = 360;
    const String source = '''[SPEED:MAX]
[EDIT:main]
[TRACK:V1]
[CLIP:leaf:leaf.mp4:0:0:4:1]
[/CLIP]
[/TRACK]
[/EDIT]
[STRUCT:EDIT.main:OVERLAY=CUSTOM:TITLE="MONITOR [frame]":TOP="FRAME [frame]":BOTTOM="REEL [frame]"]
''';

    final Directory root =
        Directory.systemTemp.createTempSync('r3_struct_chrome_bake_');
    final Directory images = Directory('${root.path}/images')
      ..createSync(recursive: true);
    final Directory sprites = Directory('${root.path}/sprites')
      ..createSync(recursive: true);
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    final CompiledScript compiled = compileScript(source, lineMarkers: false);
    final SceneEngine scene = SceneEngine();
    final ProgramStructuralFrameRenderer renderer =
        ProgramStructuralFrameRenderer(
      rawDocument: source,
      width: width,
      height: height,
      backend: _SolidBackend(),
      resolveSource: (String value) => value,
    );
    addTearDown(() {
      renderer.dispose();
      scene.disposeImages();
    });

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

    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(source).single;
    int? showingProjectFrame;
    for (int projectFrame = 0; projectFrame < 400; projectFrame++) {
      final SceneEvaluationResult result = scene.evaluate(
        ProjectTime(frame: projectFrame, mode: ProjectClockMode.scrub),
      );
      expect(result.exact, isTrue);
      final StructuralRuntimeMarker? marker =
          parseStructuralRuntimeRegion(scene.terminal.currentRegion);
      if (marker == null) continue;
      final int local = _runtimeLocalFrame(scene, marker);
      if (placement.stageAt(local) == StructuralSequenceStage.showing &&
          placement.sourceFrameAt(local) == 1) {
        showingProjectFrame = projectFrame;
        break;
      }
    }
    expect(showingProjectFrame, isNotNull);

    scene.evaluate(
      ProjectTime(
        frame: showingProjectFrame!,
        mode: ProjectClockMode.scrub,
      ),
    );

    final ui.Image? image = await tester.runAsync<ui.Image?>(
      () => renderer.renderIfActive(
        scene: scene,
        fontFamily: 'monospace',
      ),
    );
    expect(image, isNotNull);

    final ByteData? data =
        await image!.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    expect(data, isNotNull);
    final Uint8List rgba = data!.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );

    final Rect window = structuralProgramTargetRectForOutput(
      outputWidth: width,
      outputHeight: height,
      titleHeight: 38,
    );
    final Rect px = Rect.fromLTRB(
      window.left * width,
      window.top * height,
      window.right * width,
      window.bottom * height,
    );

    final Rect header = Rect.fromLTWH(px.left, px.top, px.width, 38);
    final Rect bottomOverlay = Rect.fromLTWH(
      px.left,
      px.bottom - 45,
      px.width * 0.55,
      40,
    );

    expect(
      _lightNeutralPixels(rgba, width, header),
      greaterThan(20),
      reason: 'Window title/top overlay text must rasterize into final BAKE.',
    );
    expect(
      _lightNeutralPixels(rgba, width, bottomOverlay),
      greaterThan(5),
      reason: 'Custom lower overlay text must rasterize into final BAKE.',
    );
  });
}
