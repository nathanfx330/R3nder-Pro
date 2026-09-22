// ./test/program_preview_structural_split_test.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/program_preview_surface.dart';
import 'package:r3nder/project_clock.dart';
import 'package:r3nder/scene_engine.dart';
import 'package:r3nder/scene_evaluator.dart';
import 'package:r3nder/script_pipeline.dart';
import 'package:r3nder/structural_sequence.dart';
import 'package:r3nder/ui_theme.dart';

class _SplitBackend implements MediaDecoderBackend {
  final Map<String, int> opens = <String, int>{};

  @override
  MediaDecoder open(String resolvedPath) {
    opens[resolvedPath] = (opens[resolvedPath] ?? 0) + 1;
    final bool blue = resolvedPath.endsWith('blue.mp4');
    return _SolidDecoder(
      blue
          ? const <int>[0, 0, 255, 255]
          : const <int>[255, 0, 0, 255],
    );
  }
}

class _SolidDecoder implements MediaDecoder {
  _SolidDecoder(this.color);

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
[MOSAIC:wall]
[PANE:left]
[CLIP:red:video/red.mp4:0:0:6:1]
[/CLIP]
[/PANE]
[PANE:right]
[CLIP:blue:video/blue.mp4:0:0:6:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall:SPLIT:ASPECT=4X3:OVERLAY=NONE]
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

int _findShowingProjectFrame(
  SceneEngine scene,
  StructuralSequencePlacement placement,
) {
  for (int projectFrame = 0; projectFrame < 400; projectFrame++) {
    final SceneEvaluationResult result = scene.evaluate(
      ProjectTime(frame: projectFrame, mode: ProjectClockMode.scrub),
    );
    expect(result.exact, isTrue);

    final StructuralRuntimeMarker? marker =
        parseStructuralRuntimeRegion(scene.terminal.currentRegion);
    if (marker == null || marker.placementIndex != 0) continue;

    final int localFrame = _runtimeLocalFrame(scene, marker);
    if (placement.stageAt(localFrame) == StructuralSequenceStage.showing) {
      return projectFrame;
    }
  }

  fail('Did not find showing frame for split STRUCT placement.');
}

void main() {
  testWidgets(
    'Program Preview runtime mounts supported SPLIT as two compositor panes',
    (WidgetTester tester) async {
      final Directory root = Directory.systemTemp.createTempSync(
        'r3nder_program_split_preview_',
      );
      final Directory images = Directory('${root.path}/images')
        ..createSync(recursive: true);
      final Directory sprites = Directory('${root.path}/sprites')
        ..createSync(recursive: true);

      final StructuralSequencePlacement placement =
          parseStructuralSequencePlacements(_source).single;
      expect(placement.splitWindowRequested, isTrue);
      expect(placement.splitWindowSupported, isTrue);
      expect(placement.splitWindow, isTrue);

      final CompiledScript compiled = compileScript(_source);
      expect(compiled.engineText, contains('[REGION:STRUCTSEQ_0_'));

      final SceneEngine scene = SceneEngine();
      final ChangeNotifier repaint = ChangeNotifier();
      final _SplitBackend backend = _SplitBackend();

      addTearDown(() {
        repaint.dispose();
        scene.disposeImages();
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

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
        );
      });

      final int projectFrame = _findShowingProjectFrame(scene, placement);
      expect(
        scene.evaluate(
          ProjectTime(frame: projectFrame, mode: ProjectClockMode.scrub),
        ).exact,
        isTrue,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 640,
            height: 360,
            child: ProgramPreviewSurface(
              repaint: repaint,
              scene: scene,
              rawDocument: _source,
              fontFamily: 'monospace',
              theme: R3Theme.of(Colors.green),
              structuralBackend: backend,
              structuralResolveSource: (String value) => '/workspace/$value',
            ),
          ),
        ),
      );

      for (int attempt = 0; attempt < 30; attempt++) {
        if ((backend.opens['/workspace/video/red.mp4'] ?? 0) == 1 &&
            (backend.opens['/workspace/video/blue.mp4'] ?? 0) == 1 &&
            find
                .byKey(const ValueKey<String>('structural-first-frame-ready'))
                .evaluate()
                .isNotEmpty) {
          break;
        }
        await tester.pump(const Duration(milliseconds: 1));
      }

      expect(
        find.byKey(const ValueKey<String>('program-struct-layer-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('structural-split-raster')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('structural-window-frame')),
        findsNothing,
      );
      expect(backend.opens['/workspace/video/red.mp4'], 1);
      expect(backend.opens['/workspace/video/blue.mp4'], 1);
      expect(
        find.byKey(const ValueKey<String>('structural-first-frame-ready')),
        findsOneWidget,
      );
    },
  );
}
