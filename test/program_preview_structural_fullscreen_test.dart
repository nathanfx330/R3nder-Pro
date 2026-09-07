// ./test/program_preview_structural_fullscreen_test.dart

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/program_preview_surface.dart';
import 'package:r3nder/scene_engine.dart';
import 'package:r3nder/script_pipeline.dart';
import 'package:r3nder/structural_sequence.dart';
import 'package:r3nder/ui_theme.dart';

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
    final Uint8List rgba = Uint8List(width * height * 4);
    final bool second = path.endsWith('b.mp4');
    for (int i = 0; i < rgba.length; i += 4) {
      rgba[i] = second ? 20 : 220;
      rgba[i + 1] = second ? 160 : 40;
      rgba[i + 2] = second ? 220 : 40;
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

Future<StructuralRuntimeMarker> _advanceTo(
  WidgetTester tester,
  SceneEngine scene,
  ChangeNotifier repaint, {
  required int placementIndex,
  int? localFrame,
}) async {
  for (int guard = 0; guard < 1000; guard++) {
    scene.tick();
    repaint.notifyListeners();
    await tester.pump();

    final StructuralRuntimeMarker? marker =
        parseStructuralRuntimeRegion(scene.terminal.currentRegion);
    if (marker == null || marker.placementIndex != placementIndex) continue;
    if (localFrame == null || _runtimeLocalFrame(scene, marker) == localFrame) {
      return marker;
    }
  }
  fail(
    'Did not reach STRUCT placement $placementIndex'
    '${localFrame == null ? '' : ' local frame $localFrame'}.',
  );
}

Future<void> _waitForIncomingReady(
  WidgetTester tester,
  _RecordingBackend backend,
) async {
  const String path = '/workspace/video/b.mp4';
  final Finder incomingLayer =
      find.byKey(const ValueKey<String>('program-struct-layer-1'));
  final Finder ready = find.descendant(
    of: incomingLayer,
    matching: find.byKey(
      const ValueKey<String>('structural-first-frame-ready'),
    ),
  );

  for (int attempt = 0;
      attempt < 80 &&
          ((backend.opens[path] ?? 0) == 0 || ready.evaluate().isEmpty);
      attempt++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump();
  }

  expect(backend.opens[path], 1, reason: 'incoming source must preload once');
  expect(ready, findsOneWidget, reason: 'incoming source must be picture-ready');
  expect(backend.disposes[path] ?? 0, 0);
}

Finder _incomingWindow() {
  return find.descendant(
    of: find.byKey(const ValueKey<String>('program-struct-layer-1')),
    matching: find.byKey(const ValueKey<String>('structural-window-frame')),
  );
}

Rect _fittedProgramFrame() => const Rect.fromLTWH(0, 25, 800, 450);

Rect _windowRect(Rect frame) {
  const double titleHeight = 38.0;
  final double maxW = frame.width * 0.86;
  final double maxH = frame.height * 0.78;

  double clientW = maxW;
  double clientH = clientW * 9.0 / 16.0;
  if (clientH + titleHeight > maxH) {
    clientH = math.max(1.0, maxH - titleHeight);
    clientW = clientH * 16.0 / 9.0;
  }

  final double windowH = clientH + titleHeight;
  return Rect.fromLTWH(
    frame.left + (frame.width - clientW) / 2.0,
    frame.top + (frame.height - windowH) / 2.0,
    clientW,
    windowH,
  );
}

void _expectSameRect(Rect actual, Rect expected) {
  expect(actual.left, closeTo(expected.left, 0.02));
  expect(actual.top, closeTo(expected.top, 0.02));
  expect(actual.width, closeTo(expected.width, 0.02));
  expect(actual.height, closeTo(expected.height, 0.02));
}

Future<void> _runMixedModeGate(
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

  final StructuralSequencePlacement first = placements[0];
  final StructuralSequencePlacement second = placements[1];
  expect(first.seamlessToNext, isTrue);
  expect(second.seamlessFromPrevious, isTrue);
  expect(second.entryZoomFrames, 0);
  expect(second.entryWindowFrames, kStructuralWindowFrames);
  expect(second.contentStartFrame, kStructuralWindowFrames);
  expect(second.previousPresentationMode, first.presentationMode);
  expect(second.presentationMode == first.presentationMode, isFalse);

  final Directory root =
      await Directory.systemTemp.createTemp('r3nder_struct_full_preview_');
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
    width: 800,
    height: 450,
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
  final ChangeNotifier repaint = ChangeNotifier();

  addTearDown(() {
    repaint.dispose();
    scene.disposeImages();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  await tester.pumpWidget(
    MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 800,
          height: 500,
          child: ProgramPreviewSurface(
            repaint: repaint,
            scene: scene,
            rawDocument: source,
            fontFamily: 'monospace',
            theme: R3Theme.of(Colors.green),
            structuralBackend: backend,
            structuralResolveSource: _resolveSource,
          ),
        ),
      ),
    ),
  );

  await _advanceTo(
    tester,
    scene,
    repaint,
    placementIndex: 0,
  );

  expect(
    find.byKey(const ValueKey<String>('program-struct-layer-0')),
    findsOneWidget,
  );
  expect(
    find.byKey(const ValueKey<String>('program-struct-layer-1')),
    findsOneWidget,
  );

  await _waitForIncomingReady(tester, backend);

  final Rect full = _fittedProgramFrame();
  final Rect window = _windowRect(full);
  final Rect expectedStart = firstFullscreen ? full : window;
  final Rect expectedEnd = secondFullscreen ? full : window;

  final Rect hiddenStart = tester.getRect(_incomingWindow());
  _expectSameRect(hiddenStart, expectedStart);

  final StructuralRuntimeMarker startMarker = await _advanceTo(
    tester,
    scene,
    repaint,
    placementIndex: 1,
    localFrame: 0,
  );
  expect(_runtimeLocalFrame(scene, startMarker), 0);

  final Rect visibleStart = tester.getRect(_incomingWindow());
  _expectSameRect(visibleStart, hiddenStart);
  _expectSameRect(visibleStart, expectedStart);
  expect(backend.opens['/workspace/video/b.mp4'], 1);
  expect(backend.disposes['/workspace/video/b.mp4'] ?? 0, 0);

  final int middleFrame = kStructuralWindowFrames ~/ 2;
  await _advanceTo(
    tester,
    scene,
    repaint,
    placementIndex: 1,
    localFrame: middleFrame,
  );
  final Rect middle = tester.getRect(_incomingWindow());

  if (secondFullscreen) {
    expect(middle.width, greaterThan(visibleStart.width));
    expect(middle.height, greaterThan(visibleStart.height));
    expect(middle.left, lessThan(visibleStart.left));
    expect(middle.top, lessThan(visibleStart.top));
  } else {
    expect(middle.width, lessThan(visibleStart.width));
    expect(middle.height, lessThan(visibleStart.height));
    expect(middle.left, greaterThan(visibleStart.left));
    expect(middle.top, greaterThan(visibleStart.top));
  }
  expect(middle.width, isNot(closeTo(expectedEnd.width, 0.02)));
  expect(middle.height, isNot(closeTo(expectedEnd.height, 0.02)));

  await _advanceTo(
    tester,
    scene,
    repaint,
    placementIndex: 1,
    localFrame: kStructuralWindowFrames - 1,
  );
  final Rect openingEnd = tester.getRect(_incomingWindow());
  _expectSameRect(openingEnd, expectedEnd);

  await _advanceTo(
    tester,
    scene,
    repaint,
    placementIndex: 1,
    localFrame: second.contentStartFrame,
  );
  final Rect showingStart = tester.getRect(_incomingWindow());
  _expectSameRect(showingStart, expectedEnd);

  expect(backend.opens['/workspace/video/b.mp4'], 1);
  expect(backend.disposes['/workspace/video/b.mp4'] ?? 0, 0);
}

void main() {
  testWidgets(
    'seamless STRUCT preview morphs window to fullscreen with preloaded B',
    (WidgetTester tester) async {
      await _runMixedModeGate(
        tester,
        firstFullscreen: false,
        secondFullscreen: true,
      );
    },
  );

  testWidgets(
    'seamless STRUCT preview morphs fullscreen to window with preloaded B',
    (WidgetTester tester) async {
      await _runMixedModeGate(
        tester,
        firstFullscreen: true,
        secondFullscreen: false,
      );
    },
  );
}
