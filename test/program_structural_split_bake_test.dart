// ./test/program_structural_split_bake_test.dart

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

class _PaneColorBackend implements MediaDecoderBackend {
  final Map<String, int> opens = <String, int>{};

  @override
  MediaDecoder open(String resolvedPath) {
    opens[resolvedPath] = (opens[resolvedPath] ?? 0) + 1;
    if (resolvedPath == 'blue.mp4') {
      return _SolidColorDecoder(const <int>[0, 0, 255, 255]);
    }
    return _SolidColorDecoder(const <int>[255, 0, 0, 255]);
  }
}

class _SolidColorDecoder implements MediaDecoder {
  _SolidColorDecoder(this.color);

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

Rect? _paneColorBounds(
  Uint8List rgba,
  int width,
  int height, {
  required bool red,
}) {
  int minX = width;
  int minY = height;
  int maxX = -1;
  int maxY = -1;

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final int at = (y * width + x) * 4;
      final int r = rgba[at];
      final int g = rgba[at + 1];
      final int b = rgba[at + 2];
      final int a = rgba[at + 3];

      // The right window's normal blurred desktop shadow can fall across the
      // last few pixels of the left client. That darkens a pure-red fixture
      // without changing its hue. Measure pane ownership by dominant color
      // rather than requiring exact unshadowed RGB.
      final bool matches = red
          ? a >= 240 && r >= 80 && r >= g + 60 && r >= b + 60
          : a >= 240 && b >= 80 && b >= r + 60 && b >= g + 60;
      if (!matches) continue;

      minX = x < minX ? x : minX;
      minY = y < minY ? y : minY;
      maxX = x > maxX ? x : maxX;
      maxY = y > maxY ? y : maxY;
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

int _middleLocalFrameForStage(
  StructuralSequencePlacement placement,
  StructuralSequenceStage stage,
) {
  final List<int> frames = <int>[
    for (int frame = 0; frame < placement.effectiveDurationFrames; frame++)
      if (placement.stageAt(frame) == stage) frame,
  ];
  expect(frames, isNotEmpty);
  return frames[frames.length ~/ 2];
}

int _findProjectFrame(
  SceneEngine scene, {
  required int placementIndex,
  required int localFrame,
}) {
  for (int projectFrame = 0; projectFrame < 400; projectFrame++) {
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

Future<Uint8List> _renderRgba(
  ProgramStructuralFrameRenderer renderer,
  SceneEngine scene,
) async {
  final ui.Image? image = await renderer.renderIfActive(
    scene: scene,
    fontFamily: 'monospace',
  );
  expect(image, isNotNull);
  final ByteData? data =
      await image!.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  expect(data, isNotNull);
  return data!.buffer.asUint8List(
    data.offsetInBytes,
    data.lengthInBytes,
  );
}

void main() {
  test(
    'BAKE paints supported SPLIT MOSAIC panes as independent clients',
    () async {
      const String source = '''[SPEED:MAX]
[EDIT:left_source]
[TRACK:V1]
[CLIP:red:red.mp4:0:0:6:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:left]
[CLIP:nested:EDIT.left_source:0:0:6:1]
[/CLIP]
[/PANE]
[PANE:right]
[CLIP:blue:blue.mp4:0:0:6:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall:SPLIT:OVERLAY=NONE]
''';

      const int outputWidth = 640;
      const int outputHeight = 360;
      final Directory root = await Directory.systemTemp
          .createTemp('r3nder_program_split_bake_');
      final Directory images = Directory('${root.path}/images')
        ..createSync(recursive: true);
      final Directory sprites = Directory('${root.path}/sprites')
        ..createSync(recursive: true);

      final SceneEngine scene = SceneEngine();
      final _PaneColorBackend backend = _PaneColorBackend();
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

      final List<StructuralSequencePlacement> placements =
          parseStructuralSequencePlacements(source);
      expect(placements, hasLength(1));
      final StructuralSequencePlacement placement = placements.single;
      expect(placement.splitWindowRequested, isTrue);
      expect(placement.splitWindowSupported, isTrue);
      expect(placement.splitWindow, isTrue);

      final CompiledScript compiled = compileScript(source, lineMarkers: false);
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

      int? showingProjectFrame;
      for (int projectFrame = 0; projectFrame < 300; projectFrame++) {
        scene.evaluate(
          ProjectTime(frame: projectFrame, mode: ProjectClockMode.scrub),
        );
        final StructuralRuntimeMarker? marker =
            parseStructuralRuntimeRegion(scene.terminal.currentRegion);
        if (marker == null || marker.placementIndex != 0) continue;
        final int localFrame = _runtimeLocalFrame(scene, marker);
        if (placement.stageAt(localFrame) == StructuralSequenceStage.showing) {
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
      final ui.Image? image = await renderer.renderIfActive(
        scene: scene,
        fontFamily: 'monospace',
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

      final Rect? red = _paneColorBounds(
        rgba,
        outputWidth,
        outputHeight,
        red: true,
      );
      final Rect? blue = _paneColorBounds(
        rgba,
        outputWidth,
        outputHeight,
        red: false,
      );
      expect(red, isNotNull);
      expect(blue, isNotNull);

      final double chromeScale =
          scene.terminal.scale * outputWidth / scene.width;
      final MosaicSplitWindowGeometry geometry = mosaicSplitWindowGeometry(
        frame: Rect.fromLTWH(
          0,
          0,
          outputWidth.toDouble(),
          outputHeight.toDouble(),
        ),
        aspect: placement.splitClientAspect,
        titleHeight: 38.0 * chromeScale,
      );

      expect(red!.left, closeTo(geometry.leftClientRect.left, 2.0));
      expect(red.top, closeTo(geometry.leftClientRect.top, 2.0));
      expect(red.right, closeTo(geometry.leftClientRect.right, 2.0));
      expect(red.bottom, closeTo(geometry.leftClientRect.bottom, 2.0));

      expect(blue!.left, closeTo(geometry.rightClientRect.left, 2.0));
      expect(blue.top, closeTo(geometry.rightClientRect.top, 2.0));
      expect(blue.right, closeTo(geometry.rightClientRect.right, 2.0));
      expect(blue.bottom, closeTo(geometry.rightClientRect.bottom, 2.0));

      expect(red.right, lessThan(blue.left));
      expect(backend.opens['red.mp4'], 1);
      expect(backend.opens['blue.mp4'], 1);
    },
  );

  test(
    'BAKE gives SPLIT the normal window open and close geometry',
    () async {
      const String source = '''[SPEED:MAX]
[MOSAIC:wall]
[PANE:left]
[CLIP:red:red.mp4:0:0:12:1]
[/CLIP]
[/PANE]
[PANE:right]
[CLIP:blue:blue.mp4:0:0:12:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall:SPLIT:OVERLAY=NONE]
''';

      const int outputWidth = 640;
      const int outputHeight = 360;
      final Directory root = await Directory.systemTemp
          .createTemp('r3nder_program_split_motion_bake_');
      final Directory images = Directory('${root.path}/images')
        ..createSync(recursive: true);
      final Directory sprites = Directory('${root.path}/sprites')
        ..createSync(recursive: true);

      final StructuralSequencePlacement placement =
          parseStructuralSequencePlacements(source).single;
      final int openingLocal =
          _middleLocalFrameForStage(placement, StructuralSequenceStage.opening);
      final int showingLocal = _middleLocalFrameForStage(
        placement,
        StructuralSequenceStage.showing,
      );
      final int closingLocal =
          _middleLocalFrameForStage(placement, StructuralSequenceStage.closing);

      final CompiledScript compiled = compileScript(source, lineMarkers: false);
      final SceneEngine scene = SceneEngine();
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

      final ProgramStructuralFrameRenderer renderer =
          ProgramStructuralFrameRenderer(
        rawDocument: source,
        width: outputWidth,
        height: outputHeight,
        backend: _PaneColorBackend(),
        resolveSource: (String value) => value,
      );
      addTearDown(() {
        renderer.dispose();
        scene.disposeImages();
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      Future<Rect> renderRedBounds(int localFrame) async {
        final int projectFrame = _findProjectFrame(
          scene,
          placementIndex: 0,
          localFrame: localFrame,
        );
        expect(
          scene.evaluate(
            ProjectTime(frame: projectFrame, mode: ProjectClockMode.scrub),
          ).exact,
          isTrue,
        );
        final Uint8List rgba = await _renderRgba(renderer, scene);
        final Rect? red = _paneColorBounds(
          rgba,
          outputWidth,
          outputHeight,
          red: true,
        );
        expect(red, isNotNull);
        return red!;
      }

      final Rect opening = await renderRedBounds(openingLocal);
      final Rect seated = await renderRedBounds(showingLocal);
      final Rect closing = await renderRedBounds(closingLocal);

      expect(opening.width, lessThan(seated.width));
      expect(opening.height, lessThan(seated.height));
      expect(closing.width, lessThan(seated.width));
      expect(closing.height, lessThan(seated.height));
    },
  );

  test('unsupported authored SPLIT keeps ordinary BAKE path', () async {
    const String source = '''[SPEED:MAX]
[MOSAIC:wall]
[PANE:only]
[CLIP:red:red.mp4:0:0:4:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall:SPLIT:OVERLAY=NONE]
''';

    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(source).single;
    expect(placement.splitWindowRequested, isTrue);
    expect(placement.splitWindowSupported, isFalse);
    expect(placement.splitWindow, isFalse);
    expect(
      placement.presentationMode,
      StructuralPresentationMode.windowed,
    );
  });
}
