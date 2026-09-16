// ./test/program_structural_dossier_export_test.dart

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/program_structural_export.dart';
import 'package:r3nder/scene_engine.dart';
import 'package:r3nder/script_pipeline.dart';
import 'package:r3nder/sidecard_geometry.dart';
import 'package:r3nder/structural_sequence.dart';

class _RecordingBackend implements MediaDecoderBackend {
  final List<int> requests = <int>[];

  @override
  MediaDecoder open(String resolvedPath) => _RecordingDecoder(requests);
}

class _RecordingDecoder implements MediaDecoder {
  _RecordingDecoder(this.requests);

  final List<int> requests;

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    requests.add(requestedSourceFrame);
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
      if (rgba[i] < 240 ||
          rgba[i + 1] > 20 ||
          rgba[i + 2] > 20 ||
          rgba[i + 3] < 240) {
        continue;
      }
      minX = x < minX ? x : minX;
      maxX = x > maxX ? x : maxX;
      minY = y < minY ? y : minY;
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

Future<Uint8List> _rgba(ui.Image image) async {
  final ByteData? data =
      await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  expect(data, isNotNull);
  return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

Future<SceneEngine> _sceneFor(
  String source,
  Directory root,
) async {
  final CompiledScript compiled = compileScript(source, lineMarkers: false);
  final SceneEngine scene = SceneEngine();
  await scene.setup(
    templateText: compiled.engineText,
    fontColor: Colors.green,
    bgColor: Colors.black,
    // ProgramStructuralFrameRenderer deliberately scales native chrome from
    // the logical SceneEngine canvas into the requested BAKE output. Keep the
    // engine at the normal 1080p logical canvas while this focused test renders
    // a tiny 320x180 image. Setting both to 320x180 would make the title bar
    // remain 38 output pixels tall and invalidate the shared SIDECARD geometry.
    width: 1920,
    height: 1080,
    scale: 1,
    fontPath: 'monospace',
    fontSize: 12,
    lineSpacing: 16,
    tracking: 0,
    marginTop: 10,
    marginSide: 10,
    imagesDir: '${root.path}/images',
    spritesDir: '${root.path}/sprites',
  );
  return scene;
}

Future<ui.Image> _renderAtSourceFrame({
  required SceneEngine scene,
  required ProgramStructuralFrameRenderer renderer,
  required StructuralSequencePlacement placement,
  required int sourceFrame,
}) async {
  scene.reset();
  for (int guard = 0; guard < 3000 && !scene.isFinished; guard++) {
    scene.tick();
    final StructuralRuntimeMarker? marker =
        parseStructuralRuntimeRegion(scene.terminal.currentRegion);
    if (marker == null) continue;
    final int localFrame = _runtimeLocalFrame(scene, marker);
    if (placement.stageAt(localFrame) != StructuralSequenceStage.showing) {
      continue;
    }
    if (placement.sourceFrameAt(localFrame) != sourceFrame) continue;
    final ui.Image? image = await renderer.renderIfActive(
      scene: scene,
      fontFamily: 'monospace',
    );
    expect(image, isNotNull);
    return image!;
  }
  fail('Unable to reach STRUCT source frame $sourceFrame.');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('BAKE keeps live structural video seated left during DOSSIER evidence',
      () async {
    const String source = '''[SPEED:MAX]BEFORE
[EDIT:main]
[TRACK:V1]
[CLIP:leaf:leaf.mp4:0:0:180:1]
[CUE:90]
[DOSSIER:evidence:missing.png:10:20:0:GRID:24,32,40:JOHN SMITH]
Biography text.
[/DOSSIER]
[/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
[STRUCT:EDIT.main]
AFTER
''';

    final Directory root =
        await Directory.systemTemp.createTemp('r3nder_program_dossier_');
    Directory('${root.path}/images').createSync(recursive: true);
    Directory('${root.path}/sprites').createSync(recursive: true);
    final _RecordingBackend backend = _RecordingBackend();
    final SceneEngine scene = await _sceneFor(source, root);
    final ProgramStructuralFrameRenderer renderer =
        ProgramStructuralFrameRenderer(
      rawDocument: source,
      width: 320,
      height: 180,
      backend: backend,
      resolveSource: (String value) => '${root.path}/$value',
    );
    addTearDown(() {
      renderer.dispose();
      scene.disposeImages();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(source).single;

    // DOSSIER local 38 = first center/evidence frame:
    // opening 16 + split 10 + center transition 12.
    final ui.Image frame = await _renderAtSourceFrame(
      scene: scene,
      renderer: renderer,
      placement: placement,
      sourceFrame: 128,
    );
    addTearDown(frame.dispose);
    final Rect? red = _solidRedBounds(await _rgba(frame), 320, 180);
    expect(red, isNotNull);

    final Rect expectedWindow =
        sideCardSeatedVideoWindowRect(const Size(320, 180));
    expect(red!.left, closeTo(expectedWindow.left, 2.0));
    expect(red.right, closeTo(expectedWindow.right, 2.0));
    expect(backend.requests, contains(128));
  });

  test('BAKE preserves truncated DOSSIER shell into first STRUCT closing frame',
      () async {
    const String source = '''[SPEED:MAX]BEFORE
[EDIT:main]
[TRACK:V1]
[CLIP:leaf:leaf.mp4:0:0:12:1]
[CUE:8]
[DOSSIER:evidence:missing.png:10:20:0:SIDE_ONLY:24,32,40:JOHN SMITH]
Biography text.
[/DOSSIER]
[/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
[STRUCT:EDIT.main]
AFTER
''';

    final Directory root =
        await Directory.systemTemp.createTemp('r3nder_program_dossier_end_');
    Directory('${root.path}/images').createSync(recursive: true);
    Directory('${root.path}/sprites').createSync(recursive: true);
    final _RecordingBackend backend = _RecordingBackend();
    final SceneEngine scene = await _sceneFor(source, root);
    final ProgramStructuralFrameRenderer renderer =
        ProgramStructuralFrameRenderer(
      rawDocument: source,
      width: 320,
      height: 180,
      backend: backend,
      resolveSource: (String value) => '${root.path}/$value',
    );
    addTearDown(() {
      renderer.dispose();
      scene.disposeImages();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(source).single;

    // Capture final showing source frame 11.
    final ui.Image lastShowing = await _renderAtSourceFrame(
      scene: scene,
      renderer: renderer,
      placement: placement,
      sourceFrame: 11,
    );
    final Rect? showingRed =
        _solidRedBounds(await _rgba(lastShowing), 320, 180);
    lastShowing.dispose();
    expect(showingRed, isNotNull);

    // Restart and stop on the first closing frame. Its eased close progress is
    // zero, so the shell origin must be byte-position continuous with the final
    // source frame even though the DOSSIER panel itself has been clipped.
    scene.reset();
    ui.Image? firstClosing;
    for (int guard = 0; guard < 3000 && !scene.isFinished; guard++) {
      scene.tick();
      final StructuralRuntimeMarker? marker =
          parseStructuralRuntimeRegion(scene.terminal.currentRegion);
      if (marker == null) continue;
      final int localFrame = _runtimeLocalFrame(scene, marker);
      if (localFrame != placement.closingStartFrame) continue;
      firstClosing = await renderer.renderIfActive(
        scene: scene,
        fontFamily: 'monospace',
      );
      break;
    }
    expect(firstClosing, isNotNull);
    final Rect? closingRed =
        _solidRedBounds(await _rgba(firstClosing!), 320, 180);
    firstClosing.dispose();
    expect(closingRed, isNotNull);
    expect(closingRed!.left, closeTo(showingRed!.left, 1.0));
    expect(closingRed.right, closeTo(showingRed.right, 1.0));
  });
}
