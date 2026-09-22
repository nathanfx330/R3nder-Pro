// ./test/program_structural_split_transition_bake_test.dart

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

class _ColorBackend implements MediaDecoderBackend {
  @override
  MediaDecoder open(String resolvedPath) {
    if (resolvedPath.endsWith('green.mp4')) {
      return _ColorDecoder(const <int>[0, 255, 0, 255]);
    }
    if (resolvedPath.endsWith('blue.mp4')) {
      return _ColorDecoder(const <int>[0, 0, 255, 255]);
    }
    return _ColorDecoder(const <int>[255, 0, 0, 255]);
  }
}

class _ColorDecoder implements MediaDecoder {
  _ColorDecoder(this.color);

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

const String _source = '''[CONFIG:APPSWITCH:SLIDE]
[EDIT:first]
[TRACK:V1]
[CLIP:red:red.mp4:0:0:12:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:second]
[PANE:left]
[CLIP:green:green.mp4:0:0:12:1]
[/CLIP]
[/PANE]
[PANE:right]
[CLIP:blue:blue.mp4:0:0:12:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:EDIT.first:OVERLAY=NONE]
[STRUCT:MOSAIC.second:SPLIT:OVERLAY=NONE]
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
    expect(
      scene.evaluate(
        ProjectTime(frame: projectFrame, mode: ProjectClockMode.scrub),
      ).exact,
      isTrue,
    );
    final StructuralRuntimeMarker? marker =
        parseStructuralRuntimeRegion(scene.terminal.currentRegion);
    if (marker == null || marker.placementIndex != placementIndex) continue;
    if (_runtimeLocalFrame(scene, marker) == localFrame) return projectFrame;
  }
  fail('Missing placement $placementIndex local frame $localFrame.');
}

Future<Uint8List> _rgba(ui.Image image) async {
  final ByteData? data =
      await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  expect(data, isNotNull);
  return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

List<int> _pixelAt(
  Uint8List rgba,
  int width,
  Offset point,
) {
  final int x = point.dx.round().clamp(0, width - 1);
  final int y = point.dy.round().clamp(0, (rgba.length ~/ 4 ~/ width) - 1);
  final int at = (y * width + x) * 4;
  return <int>[
    rgba[at],
    rgba[at + 1],
    rgba[at + 2],
    rgba[at + 3],
  ];
}

void main() {
  test(
    'BAKE holds outgoing window for split shape budget then cuts both panes',
    () async {
      final List<StructuralSequencePlacement> placements =
          parseStructuralSequencePlacements(_source);
      expect(placements, hasLength(2));
      final StructuralSequencePlacement second = placements[1];
      expect(second.entryWindowFrames, kStructuralWindowFrames);

      final Directory root =
          await Directory.systemTemp.createTemp('r3nder_w5_split_bake_');
      final Directory images = Directory('${root.path}/images')
        ..createSync(recursive: true);
      final Directory sprites = Directory('${root.path}/sprites')
        ..createSync(recursive: true);

      final SceneEngine scene = SceneEngine();
      final CompiledScript compiled = compileScript(_source, lineMarkers: false);
      await scene.setup(
        templateText: compiled.engineText,
        fontColor: Colors.green,
        bgColor: Colors.black,
        width: 640,
        height: 360,
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
        width: 640,
        height: 360,
        backend: _ColorBackend(),
        resolveSource: (String value) => value,
      );

      addTearDown(() {
        renderer.dispose();
        scene.disposeImages();
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      final int openingProjectFrame = _findProjectFrame(
        scene,
        placementIndex: 1,
        localFrame: kStructuralWindowFrames ~/ 2,
      );
      expect(
        scene.evaluate(
          ProjectTime(
            frame: openingProjectFrame,
            mode: ProjectClockMode.scrub,
          ),
        ).exact,
        isTrue,
      );

      final ui.Image? openingImage = await renderer.renderIfActive(
        scene: scene,
        fontFamily: 'monospace',
      );
      expect(openingImage, isNotNull);
      final Uint8List opening = await _rgba(openingImage!);
      openingImage.dispose();

      const double titleHeight = 38.0;
      final Rect heldWindow = structuralProgramTargetRectForOutput(
        outputWidth: 640,
        outputHeight: 360,
        titleHeight: titleHeight,
      );
      final Rect heldWindowPixels = Rect.fromLTRB(
        heldWindow.left * 640,
        heldWindow.top * 360,
        heldWindow.right * 640,
        heldWindow.bottom * 360,
      );
      final Rect heldClient = Rect.fromLTRB(
        heldWindowPixels.left,
        heldWindowPixels.top + titleHeight,
        heldWindowPixels.right,
        heldWindowPixels.bottom,
      );
      expect(
        _pixelAt(opening, 640, heldClient.center),
        const <int>[255, 0, 0, 255],
      );

      final int showingProjectFrame = _findProjectFrame(
        scene,
        placementIndex: 1,
        localFrame: kStructuralWindowFrames,
      );
      expect(
        scene.evaluate(
          ProjectTime(
            frame: showingProjectFrame,
            mode: ProjectClockMode.scrub,
          ),
        ).exact,
        isTrue,
      );

      final ui.Image? showingImage = await renderer.renderIfActive(
        scene: scene,
        fontFamily: 'monospace',
      );
      expect(showingImage, isNotNull);
      final Uint8List showing = await _rgba(showingImage!);
      showingImage.dispose();

      final MosaicSplitWindowGeometry splitGeometry =
          mosaicSplitWindowGeometry(
        frame: const Rect.fromLTWH(0, 0, 640, 360),
        aspect: second.splitClientAspect,
        titleHeight: titleHeight,
      );
      expect(
        _pixelAt(showing, 640, splitGeometry.leftClientRect.center),
        const <int>[0, 255, 0, 255],
      );
      expect(
        _pixelAt(showing, 640, splitGeometry.rightClientRect.center),
        const <int>[0, 0, 255, 255],
      );
    },
  );
}
