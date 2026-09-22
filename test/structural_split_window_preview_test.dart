// ./test/structural_split_window_preview_test.dart

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/mosaic_split_geometry.dart';
import 'package:r3nder/program_structural_export.dart';
import 'package:r3nder/project_clock.dart';
import 'package:r3nder/scene_engine.dart';
import 'package:r3nder/scene_evaluator.dart';
import 'package:r3nder/script_pipeline.dart';
import 'package:r3nder/structural_sequence.dart';
import 'package:r3nder/structural_split_window_preview.dart';
import 'package:r3nder/ui_theme.dart';

class _PaneColorBackend implements MediaDecoderBackend {
  final Map<String, int> opens = <String, int>{};

  @override
  MediaDecoder open(String resolvedPath) {
    opens[resolvedPath] = (opens[resolvedPath] ?? 0) + 1;
    return _SolidColorDecoder(
      resolvedPath == 'blue.mp4'
          ? const <int>[0, 0, 255, 255]
          : const <int>[255, 0, 0, 255],
    );
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

Future<Uint8List> _imageBytes(ui.Image image) async {
  final ByteData? data =
      await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  expect(data, isNotNull);
  return data!.buffer.asUint8List(
    data.offsetInBytes,
    data.lengthInBytes,
  );
}

void _expectOpaqueWindowInteriorParity({
  required Uint8List preview,
  required Uint8List bake,
  required int width,
  required List<Rect> windows,
}) {
  int mismatchedChannels = 0;
  int maxChannelDelta = 0;

  for (final Rect window in windows) {
    final Rect interior = window.deflate(2.0);
    final int left = interior.left.ceil();
    final int top = interior.top.ceil();
    final int right = interior.right.floor();
    final int bottom = interior.bottom.floor();

    for (int y = top; y < bottom; y++) {
      for (int x = left; x < right; x++) {
        final int at = (y * width + x) * 4;
        for (int channel = 0; channel < 4; channel++) {
          final int delta = (preview[at + channel] - bake[at + channel]).abs();
          if (delta != 0) {
            mismatchedChannels++;
            if (delta > maxChannelDelta) maxChannelDelta = delta;
          }
        }
      }
    }
  }

  expect(
    mismatchedChannels,
    0,
    reason:
        'Preview and BAKE split window interiors diverged; '
        'max channel delta $maxChannelDelta.',
  );
}

void main() {
  testWidgets(
    'seated split Preview pixels match BAKE through shared window painter',
    (WidgetTester tester) async {
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

      final StructuralSequencePlacement placement =
          parseStructuralSequencePlacements(source).single;
      expect(placement.splitWindow, isTrue);

      final Directory root = await Directory.systemTemp
          .createTemp('r3nder_split_preview_parity_');
      final Directory images = Directory('${root.path}/images')
        ..createSync(recursive: true);
      final Directory sprites = Directory('${root.path}/sprites')
        ..createSync(recursive: true);

      final SceneEngine scene = SceneEngine();
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
      int? showingSourceFrame;
      for (int projectFrame = 0; projectFrame < 300; projectFrame++) {
        expect(
          scene.evaluate(
            ProjectTime(frame: projectFrame, mode: ProjectClockMode.scrub),
          ).exact,
          isTrue,
        );
        final StructuralRuntimeMarker? marker =
            parseStructuralRuntimeRegion(scene.terminal.currentRegion);
        if (marker == null) continue;
        final int localFrame = _runtimeLocalFrame(scene, marker);
        if (placement.stageAt(localFrame) != StructuralSequenceStage.showing) {
          continue;
        }
        showingProjectFrame = projectFrame;
        showingSourceFrame = placement.sourceFrameAt(localFrame);
        break;
      }

      expect(showingProjectFrame, isNotNull);
      expect(showingSourceFrame, isNotNull);

      final double chromeScale =
          scene.terminal.scale * outputWidth / scene.width;
      final MosaicSplitWindowGeometry geometry =
          mosaicSplitWindowGeometry(
        frame: Rect.fromLTWH(
          0,
          0,
          outputWidth.toDouble(),
          outputHeight.toDouble(),
        ),
        aspect: placement.splitClientAspect,
        titleHeight: 38.0 * chromeScale,
      );

      final _PaneColorBackend previewBackend = _PaneColorBackend();
      bool previewReady = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: outputWidth.toDouble(),
              height: outputHeight.toDouble(),
              child: StructuralSplitWindowPreview(
                rawDocument: source,
                placement: placement,
                sourceFrame: showingSourceFrame!,
                theme: R3Theme.of(Colors.green),
                fontFamily: 'monospace',
                chromeScale: chromeScale,
                backend: previewBackend,
                resolveSource: (String value) => value,
                onFirstFrameReady: () {
                  previewReady = true;
                },
              ),
            ),
          ),
        ),
      );

      for (int attempt = 0; attempt < 30 && !previewReady; attempt++) {
        await tester.pump(const Duration(milliseconds: 1));
      }
      expect(previewReady, isTrue);
      await tester.pump();

      expect(previewBackend.opens['red.mp4'], 1);
      expect(previewBackend.opens['blue.mp4'], 1);

      final RenderRepaintBoundary boundary =
          tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey<String>('structural-split-raster')),
      );
      final ui.Image previewImage = await boundary.toImage(pixelRatio: 1.0);
      final Uint8List previewRgba = await _imageBytes(previewImage);
      previewImage.dispose();

      expect(
        scene.evaluate(
          ProjectTime(
            frame: showingProjectFrame!,
            mode: ProjectClockMode.scrub,
          ),
        ).exact,
        isTrue,
      );

      final _PaneColorBackend bakeBackend = _PaneColorBackend();
      final ProgramStructuralFrameRenderer bakeRenderer =
          ProgramStructuralFrameRenderer(
        rawDocument: source,
        width: outputWidth,
        height: outputHeight,
        backend: bakeBackend,
        resolveSource: (String value) => value,
      );

      addTearDown(() {
        bakeRenderer.dispose();
        scene.disposeImages();
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      final ui.Image? bakeImage = await bakeRenderer.renderIfActive(
        scene: scene,
        fontFamily: 'monospace',
      );
      expect(bakeImage, isNotNull);
      final Uint8List bakeRgba = await _imageBytes(bakeImage!);
      bakeImage.dispose();

      _expectOpaqueWindowInteriorParity(
        preview: previewRgba,
        bake: bakeRgba,
        width: outputWidth,
        windows: geometry.windowRects,
      );
    },
  );
}
