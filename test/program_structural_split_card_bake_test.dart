// ./test/program_structural_split_card_bake_test.dart

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/mosaic_split_geometry.dart';
import 'package:r3nder/program_structural_export.dart';
import 'package:r3nder/project_clock.dart';
import 'package:r3nder/scene_engine.dart';
import 'package:r3nder/scene_evaluator.dart';
import 'package:r3nder/script_pipeline.dart';
import 'package:r3nder/structural_sequence.dart';

class _PaneBackend implements MediaDecoderBackend {
  @override
  MediaDecoder open(String resolvedPath) {
    return _SolidDecoder(
      resolvedPath.endsWith('right.mp4')
          ? const <int>[0, 0, 255, 255]
          : const <int>[255, 0, 0, 255],
    );
  }
}

class _SolidDecoder implements MediaDecoder {
  const _SolidDecoder(this.color);

  final List<int> color;

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    final Uint8List rgba = Uint8List(width * height * 4);
    for (int i = 0; i < rgba.length; i += 4) {
      rgba.setRange(i, i + 4, color);
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

const String _source = '''[SPEED:MAX]
[EDIT:left]
[TRACK:V1]
[CLIP:leftShot:video/left.mp4:0:0:40:1]
[/CLIP]
[/TRACK]
[/EDIT]
[EDIT:right]
[TRACK:V1]
[CLIP:rightShot:video/right.mp4:0:0:40:1]
[CUE:0]
[CARD:missing-card.png:8:12,34,56:CARD]
CARD BODY
[/CARD]
[/CUE]
[CUE:0]
[SIDECARD:missing-side.png:8:210,30,40:SIDE]
SIDE BODY
[/SIDECARD]
[/CUE]
[CUE:0]
[MAXIMIZE:8]
[/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:left]
[CLIP:left:EDIT.left:0:0:40:1]
[/CLIP]
[/PANE]
[PANE:right]
[CLIP:right:EDIT.right:0:0:40:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall:SPLIT:OVERLAY=NONE]
''';

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

int _findProjectFrame(
  SceneEngine scene, {
  required int placementIndex,
  required int localFrame,
}) {
  for (int projectFrame = 0; projectFrame < 500; projectFrame++) {
    final SceneEvaluationResult result = scene.evaluate(
      ProjectTime(frame: projectFrame, mode: ProjectClockMode.scrub),
    );
    expect(result.exact, isTrue);
    final StructuralRuntimeMarker? marker =
        parseStructuralRuntimeRegion(scene.terminal.currentRegion);
    if (marker == null || marker.placementIndex != placementIndex) continue;
    if (_runtimeLocalFrame(scene, marker) == localFrame) return projectFrame;
  }
  fail('Missing placement $placementIndex local frame $localFrame.');
}

bool _containsRgbInRect(
  Uint8List rgba,
  int width,
  int height,
  Rect rect,
  int red,
  int green,
  int blue,
) {
  final int left = rect.left.floor().clamp(0, width - 1).toInt();
  final int top = rect.top.floor().clamp(0, height - 1).toInt();
  final int right = rect.right.ceil().clamp(left + 1, width).toInt();
  final int bottom = rect.bottom.ceil().clamp(top + 1, height).toInt();

  for (int y = top; y < bottom; y++) {
    for (int x = left; x < right; x++) {
      final int at = (y * width + x) * 4;
      if (rgba[at] == red &&
          rgba[at + 1] == green &&
          rgba[at + 2] == blue &&
          rgba[at + 3] == 255) {
        return true;
      }
    }
  }
  return false;
}

void main() {
  test(
    'BAKE routes CARD to owning split client and suppresses SIDECARD/MAXIMIZE',
    () async {
      const int width = 640;
      const int height = 360;
      const int sourceFrame = 16;

      final StructuralSequencePlacement placement =
          parseStructuralSequencePlacements(_source).single;
      expect(placement.splitWindow, isTrue);

      final Directory root =
          await Directory.systemTemp.createTemp('r3nder_w6_split_card_bake_');
      final Directory images = Directory('${root.path}/images')
        ..createSync(recursive: true);
      final Directory sprites = Directory('${root.path}/sprites')
        ..createSync(recursive: true);

      final CompiledScript compiled =
          compileScript(_source, lineMarkers: false);
      final SceneEngine scene = SceneEngine();
      await scene.setup(
        templateText: compiled.engineText,
        fontColor: Colors.green,
        bgColor: Colors.black,
        width: width.toDouble(),
        height: height.toDouble(),
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

      final ProgramStructuralFrameRenderer renderer =
          ProgramStructuralFrameRenderer(
        rawDocument: _source,
        width: width,
        height: height,
        backend: _PaneBackend(),
        resolveSource: (String value) => value,
      );

      addTearDown(() {
        renderer.dispose();
        scene.disposeImages();
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      final int projectFrame = _findProjectFrame(
        scene,
        placementIndex: 0,
        localFrame: placement.contentStartFrame + sourceFrame,
      );
      expect(
        scene.evaluate(
          ProjectTime(frame: projectFrame, mode: ProjectClockMode.scrub),
        ).exact,
        isTrue,
      );

      final ui.Image? image = await renderer.renderIfActive(
        scene: scene,
        fontFamily: 'monospace',
      );
      expect(image, isNotNull);
      final ByteData? bytes =
          await image!.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      expect(bytes, isNotNull);
      final Uint8List rgba = bytes!.buffer.asUint8List(
        bytes.offsetInBytes,
        bytes.lengthInBytes,
      );

      final double chromeScale =
          scene.terminal.scale * width / scene.width;
      final MosaicSplitWindowGeometry geometry = mosaicSplitWindowGeometry(
        frame: const Rect.fromLTWH(0, 0, 640.0, 360.0),
        aspect: placement.splitClientAspect,
        titleHeight: 38.0 * chromeScale,
      );

      expect(
        _containsRgbInRect(
          rgba,
          width,
          height,
          geometry.leftClientRect,
          12,
          34,
          56,
        ),
        isFalse,
        reason: 'Right-pane CARD must not leak into the left split client.',
      );
      expect(
        _containsRgbInRect(
          rgba,
          width,
          height,
          geometry.rightClientRect,
          12,
          34,
          56,
        ),
        isTrue,
        reason: 'Right-pane CARD must paint inside the right split client.',
      );

      const Rect full = Rect.fromLTWH(0, 0, 640.0, 360.0);
      expect(
        _containsRgbInRect(
          rgba,
          width,
          height,
          full,
          210,
          30,
          40,
        ),
        isFalse,
        reason: 'SIDECARD must not paint anywhere in SPLIT v1.',
      );

      expect(
        _containsRgbInRect(
          rgba,
          width,
          height,
          geometry.leftClientRect,
          255,
          0,
          0,
        ),
        isTrue,
      );
      expect(
        _containsRgbInRect(
          rgba,
          width,
          height,
          geometry.rightClientRect,
          0,
          0,
          255,
        ),
        isTrue,
      );
    },
  );
}
