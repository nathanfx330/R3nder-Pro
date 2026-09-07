// ./test/program_structural_mixed_mode_bake_test.dart

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

const int _testWidth = 320;
const int _testHeight = 180;

class _RecordingBackend implements MediaDecoderBackend {
  final Map<String, int> opens = <String, int>{};
  final Map<String, int> disposes = <String, int>{};

  @override
  MediaDecoder open(String resolvedPath) {
    opens[resolvedPath] = (opens[resolvedPath] ?? 0) + 1;
    return _RecordingDecoder(
      path: resolvedPath,
      onDispose: () {
        disposes[resolvedPath] = (disposes[resolvedPath] ?? 0) + 1;
      },
    );
  }
}

class _RecordingDecoder implements MediaDecoder {
  final String path;
  final VoidCallback onDispose;
  bool _disposed = false;

  _RecordingDecoder({required this.path, required this.onDispose});

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    // The parity gate reads structural chrome geometry, not source picture
    // content. A zeroed RGBA frame keeps the decoder path real without paying
    // for synthetic per-pixel painting in the test harness.
    final Uint8List rgba = Uint8List(width * height * 4);
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
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    onDispose();
  }
}

String _source({
  required bool firstFullscreen,
  required bool secondFullscreen,
}) {
  final String firstSuffix = firstFullscreen ? ':FULL' : '';
  final String secondSuffix = secondFullscreen ? ':FULL' : '';
  return '''[CONFIG:APPSWITCH:SLIDE]
[EDIT:a]
[TRACK:V1]
[CLIP:a:video/a.mp4:0:0:3:1]
[/CLIP]
[/TRACK]
[/EDIT]
[EDIT:b]
[TRACK:V1]
[CLIP:b:video/b.mp4:0:0:3:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:first]
[PANE:pane1]
[CLIP:edit_a:EDIT.a:0:0:3:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[MOSAIC:second]
[PANE:pane1]
[CLIP:edit_b:EDIT.b:0:0:3:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.first$firstSuffix]
[STRUCT:MOSAIC.second$secondSuffix]
''';
}

String _resolveSource(String source) => '/workspace/$source';

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

Future<ui.Image> _renderAtLocalFrame({
  required SceneEngine scene,
  required ProgramStructuralFrameRenderer renderer,
  required int placementIndex,
  required int localFrame,
}) async {
  for (int projectFrame = 0; projectFrame < 500; projectFrame++) {
    final SceneEvaluationResult result = scene.evaluate(
      ProjectTime(frame: projectFrame, mode: ProjectClockMode.scrub),
    );
    expect(result.exact, isTrue);

    final StructuralRuntimeMarker? marker =
        parseStructuralRuntimeRegion(scene.terminal.currentRegion);
    if (marker == null || marker.placementIndex != placementIndex) continue;
    if (_runtimeLocalFrame(scene, marker) != localFrame) continue;

    final ui.Image? image = await renderer.renderIfActive(
      scene: scene,
      fontFamily: 'monospace',
    );
    expect(image, isNotNull);
    return image!;
  }

  fail(
    'Did not render STRUCT placement $placementIndex local frame $localFrame.',
  );
}

Future<Rect> _headerBounds(ui.Image image) async {
  final ByteData? data = await image.toByteData(
    format: ui.ImageByteFormat.rawRgba,
  );
  expect(data, isNotNull);
  final Uint8List rgba = data!.buffer.asUint8List();

  int minX = image.width;
  int minY = image.height;
  int maxX = -1;
  int maxY = -1;

  for (int y = 0; y < image.height; y++) {
    for (int x = 0; x < image.width; x++) {
      final int offset = (y * image.width + x) * 4;
      if (rgba[offset] != 0x33 ||
          rgba[offset + 1] != 0x30 ||
          rgba[offset + 2] != 0x2F ||
          rgba[offset + 3] != 0xFF) {
        continue;
      }

      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;
    }
  }

  expect(maxX, greaterThanOrEqualTo(0), reason: 'structural header not found');
  expect(maxY, greaterThanOrEqualTo(0), reason: 'structural header not found');

  return Rect.fromLTRB(
    minX.toDouble(),
    minY.toDouble(),
    (maxX + 1).toDouble(),
    (maxY + 1).toDouble(),
  );
}

Future<Rect> _renderHeaderAtLocalFrame({
  required SceneEngine scene,
  required ProgramStructuralFrameRenderer renderer,
  required int placementIndex,
  required int localFrame,
}) async {
  final ui.Image image = await _renderAtLocalFrame(
    scene: scene,
    renderer: renderer,
    placementIndex: placementIndex,
    localFrame: localFrame,
  );
  try {
    return await _headerBounds(image);
  } finally {
    image.dispose();
  }
}

Rect _pixelRect(Rect normalized) => Rect.fromLTRB(
      normalized.left * _testWidth,
      normalized.top * _testHeight,
      normalized.right * _testWidth,
      normalized.bottom * _testHeight,
    );

Rect _plannedMorphRect(
  StructuralSequencePlacement placement,
  int localFrame,
) {
  final StructuralPresentationMode previous =
      placement.previousPresentationMode!;
  final Rect from = structuralProgramPresentationRectForOutput(
    mode: previous,
    outputWidth: _testWidth,
    outputHeight: _testHeight,
    titleHeight: 38.0,
  );
  final Rect to = structuralProgramPresentationRectForOutput(
    mode: placement.presentationMode,
    outputWidth: _testWidth,
    outputHeight: _testHeight,
    titleHeight: 38.0,
  );
  final double eased = Curves.easeInOutCubic.transform(
    placement.stageProgressAt(localFrame),
  );
  return _pixelRect(Rect.lerp(from, to, eased)!);
}

void _expectSameRect(Rect actual, Rect expected) {
  expect(actual.left, closeTo(expected.left, 1.5));
  expect(actual.top, closeTo(expected.top, 1.5));
  expect(actual.right, closeTo(expected.right, 1.5));

  // The exact header-color scan covers the title bar itself. Its bottom is
  // therefore structuralRect.top + 38 rather than structuralRect.bottom.
  expect(actual.bottom, closeTo(expected.top + 38.0, 1.5));
}

Future<void> _runBakeGate(
  WidgetTester tester, {
  required bool firstFullscreen,
  required bool secondFullscreen,
}) async {
  final String source = _source(
    firstFullscreen: firstFullscreen,
    secondFullscreen: secondFullscreen,
  );
  final List<StructuralSequencePlacement> placements =
      parseStructuralSequencePlacements(source);
  expect(placements, hasLength(2));

  final StructuralSequencePlacement second = placements[1];
  expect(second.seamlessFromPrevious, isTrue);
  expect(second.entryWindowFrames, kStructuralWindowFrames);
  expect(second.previousPresentationMode, placements[0].presentationMode);
  expect(second.presentationMode == placements[0].presentationMode, isFalse);

  final Directory root =
      await Directory.systemTemp.createTemp('r3nder_struct_mixed_bake_');
  final Directory images = Directory('${root.path}/images')
    ..createSync(recursive: true);
  final Directory sprites = Directory('${root.path}/sprites')
    ..createSync(recursive: true);

  final CompiledScript compiled = compileScript(source);
  final SceneEngine scene = SceneEngine();
  await scene.setup(
    templateText: compiled.engineText,
    fontColor: Colors.green,
    bgColor: Colors.black,
    width: _testWidth.toDouble(),
    height: _testHeight.toDouble(),
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

  final _RecordingBackend backend = _RecordingBackend();
  final ProgramStructuralFrameRenderer renderer = ProgramStructuralFrameRenderer(
    rawDocument: source,
    width: _testWidth,
    height: _testHeight,
    backend: backend,
    resolveSource: _resolveSource,
  );

  addTearDown(() {
    renderer.dispose();
    scene.disposeImages();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  final List<int> localFrames = <int>[
    0,
    kStructuralWindowFrames ~/ 2,
    kStructuralWindowFrames - 1,
  ];

  for (final int localFrame in localFrames) {
    // ProgramStructuralFrameRenderer uses both decodeImageFromPixels() and
    // Picture.toImage(). Those complete on Flutter's real engine async loop,
    // not the widget-test fake clock. Run the complete image round trip there
    // and return only the measured geometry to the deterministic test zone.
    final Rect? header = await tester.runAsync<Rect>(() async {
      return _renderHeaderAtLocalFrame(
        scene: scene,
        renderer: renderer,
        placementIndex: 1,
        localFrame: localFrame,
      );
    });
    expect(header, isNotNull);

    final Rect planned = _plannedMorphRect(second, localFrame);
    _expectSameRect(header!, planned);
  }

  expect(backend.opens['/workspace/video/b.mp4'], 1);
  expect(backend.disposes['/workspace/video/b.mp4'] ?? 0, 0);
}

void main() {
  testWidgets(
    'whole-program bake matches planned window to fullscreen STRUCT morph',
    (WidgetTester tester) async {
      await _runBakeGate(
        tester,
        firstFullscreen: false,
        secondFullscreen: true,
      );
    },
  );

  testWidgets(
    'whole-program bake matches planned fullscreen to window STRUCT morph',
    (WidgetTester tester) async {
      await _runBakeGate(
        tester,
        firstFullscreen: true,
        secondFullscreen: false,
      );
    },
  );
}
