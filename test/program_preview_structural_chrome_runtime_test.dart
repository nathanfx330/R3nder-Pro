// ./test/program_preview_structural_chrome_runtime_test.dart

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

class _SolidBackend implements MediaDecoderBackend {
  @override
  MediaDecoder open(String resolvedPath) => _SolidDecoder();
}

class _SolidDecoder implements MediaDecoder {
  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    final Uint8List rgba = Uint8List(width * height * 4);
    for (int i = 0; i < rgba.length; i += 4) {
      rgba[i] = 20;
      rgba[i + 1] = 60;
      rgba[i + 2] = 130;
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

const String _source = '''[SPEED:MAX]
[EDIT:main]
[TRACK:V1]
[CLIP:leaf:video/leaf.mp4:0:0:8:1]
[/CLIP]
[/TRACK]
[/EDIT]
[STRUCT:EDIT.main:FULL:OVERLAY=CUSTOM:TITLE="MONITOR [frame]":TOP="FRAME [frame]":BOTTOM="REEL [frame]"]
''';

const String _indexedSource = '''[SPEED:MAX]
[EDIT:main]
[TRACK:V1]
[STRUCT:EDIT.main]
[CLIP:leaf:video/leaf.mp4:0:0:8:1]
[/CLIP]
[/TRACK]
[/EDIT]
[STRUCT:EDIT.main:FULL:OVERLAY=NONE]
[STRUCT:EDIT.main:FULL:OVERLAY=CUSTOM:TITLE="SECOND [frame]":TOP="CUSTOM [frame]":BOTTOM="BOTTOM [frame]"]
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
  StructuralSequencePlacement placement, {
  required int placementIndex,
  required int sourceFrame,
}) {
  for (int projectFrame = 0; projectFrame < 500; projectFrame++) {
    final SceneEvaluationResult result = scene.evaluate(
      ProjectTime(frame: projectFrame, mode: ProjectClockMode.scrub),
    );
    expect(result.exact, isTrue);

    final StructuralRuntimeMarker? marker =
        parseStructuralRuntimeRegion(scene.terminal.currentRegion);
    if (marker == null || marker.placementIndex != placementIndex) continue;
    final int local = _runtimeLocalFrame(scene, marker);
    if (placement.stageAt(local) == StructuralSequenceStage.showing &&
        placement.sourceFrameAt(local) == sourceFrame) {
      return projectFrame;
    }
  }
  fail(
    'Did not find STRUCT placement $placementIndex showing source frame '
    '$sourceFrame.',
  );
}

Future<void> _setupScene(
  WidgetTester tester,
  SceneEngine scene,
  CompiledScript compiled,
  Directory images,
  Directory sprites,
) async {
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
}

void main() {
  testWidgets(
      'ProgramPreviewSurface preserves FULL CUSTOM STRUCT chrome and frame expression',
      (WidgetTester tester) async {
    final Directory root =
        Directory.systemTemp.createTempSync('r3_struct_program_chrome_');
    final Directory images = Directory('${root.path}/images')
      ..createSync(recursive: true);
    final Directory sprites = Directory('${root.path}/sprites')
      ..createSync(recursive: true);

    final CompiledScript compiled = compileScript(_source);
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_source).single;
    expect(placement.presentationMode, StructuralPresentationMode.fullscreen);

    final SceneEngine scene = SceneEngine();
    final ChangeNotifier repaint = ChangeNotifier();
    addTearDown(() {
      repaint.dispose();
      scene.disposeImages();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    await _setupScene(tester, scene, compiled, images, sprites);

    final int projectFrame = _findShowingProjectFrame(
      scene,
      placement,
      placementIndex: 0,
      sourceFrame: 2,
    );
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
            structuralBackend: _SolidBackend(),
            structuralResolveSource: (String value) => '/workspace/$value',
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('program-struct-layer-0')),
      findsOneWidget,
    );
    expect(find.text('MONITOR 2'), findsOneWidget);
    expect(find.text('FRAME 2'), findsOneWidget);
    expect(find.text('REEL 2'), findsOneWidget);
    expect(find.textContaining('[frame]'), findsNothing);
  });

  testWidgets(
      'runtime index ignores source-root STRUCT text before later CUSTOM placement',
      (WidgetTester tester) async {
    final Directory root =
        Directory.systemTemp.createTempSync('r3_struct_program_indexed_');
    final Directory images = Directory('${root.path}/images')
      ..createSync(recursive: true);
    final Directory sprites = Directory('${root.path}/sprites')
      ..createSync(recursive: true);

    final List<StructuralSequencePlacement> placements =
        parseStructuralSequencePlacements(_indexedSource);
    expect(placements, hasLength(2));
    expect(placements.first.overlayMode.name, 'none');
    expect(placements.last.overlayMode.name, 'custom');
    expect(placements.last.windowTitle, 'SECOND [frame]');
    expect(placements.last.topOverlay, 'CUSTOM [frame]');
    expect(placements.last.bottomOverlay, 'BOTTOM [frame]');

    final CompiledScript compiled = compileScript(_indexedSource);
    expect(compiled.engineText, contains('[REGION:STRUCTSEQ_0_'));
    expect(compiled.engineText, contains('[REGION:STRUCTSEQ_1_'));
    expect(compiled.engineText, isNot(contains('[REGION:STRUCTSEQ_2_')));

    final SceneEngine scene = SceneEngine();
    final ChangeNotifier repaint = ChangeNotifier();
    addTearDown(() {
      repaint.dispose();
      scene.disposeImages();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    await _setupScene(tester, scene, compiled, images, sprites);

    final int projectFrame = _findShowingProjectFrame(
      scene,
      placements[1],
      placementIndex: 1,
      sourceFrame: 2,
    );
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
            rawDocument: _indexedSource,
            fontFamily: 'monospace',
            theme: R3Theme.of(Colors.green),
            structuralBackend: _SolidBackend(),
            structuralResolveSource: (String value) => '/workspace/$value',
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('program-struct-layer-1')),
      findsOneWidget,
    );
    expect(find.text('SECOND 2'), findsOneWidget);
    expect(find.text('CUSTOM 2'), findsOneWidget);
    expect(find.text('BOTTOM 2'), findsOneWidget);
    expect(find.textContaining('[frame]'), findsNothing);
  });
}
