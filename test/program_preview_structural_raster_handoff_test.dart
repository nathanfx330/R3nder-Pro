// ./test/program_preview_structural_raster_handoff_test.dart

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/program_preview_surface.dart';
import 'package:r3nder/project_clock.dart';
import 'package:r3nder/scene_engine.dart';
import 'package:r3nder/scene_evaluator.dart';
import 'package:r3nder/script_pipeline.dart';
import 'package:r3nder/structural_sequence.dart';
import 'package:r3nder/ui_theme.dart';

const Key _boundaryKey = ValueKey<String>('struct-raster-boundary');

class _OfflineBackend implements MediaDecoderBackend {
  @override
  MediaDecoder open(String resolvedPath) => _OfflineDecoder(resolvedPath);
}

class _OfflineDecoder implements MediaDecoder {
  final String path;

  _OfflineDecoder(this.path);

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    // Keep the gate independent of RGBA source conversion. A stable OFFLINE
    // result resolves preview readiness while the structural shell itself still
    // rasterizes normally, including its title bar and window geometry.
    throw MediaDecodeException('intentional raster-gate offline: $path');
  }

  @override
  void dispose() {}
}

const String _source = '''[CONFIG:APPSWITCH:SLIDE]
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
[STRUCT:MOSAIC.first]
[STRUCT:MOSAIC.second]
''';

const String _paritySource = '''[CONFIG:APPSWITCH:SLIDE]
[EDIT:a]
[TRACK:V1]
[CLIP:a:video/a.mp4:0:0:30:1]
[/CLIP]
[/TRACK]
[/EDIT]
[EDIT:b]
[TRACK:V1]
[CLIP:b:video/b.mp4:0:0:30:1]
[/CLIP]
[/TRACK]
[/EDIT]
[STRUCT:EDIT.a]
[STRUCT:EDIT.b]
''';

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

int _findProjectFrame(
  SceneEngine scene, {
  required int placementIndex,
  required int localFrame,
}) {
  for (int projectFrame = 0; projectFrame < 300; projectFrame++) {
    final SceneEvaluationResult result = scene.evaluate(
      ProjectTime(frame: projectFrame, mode: ProjectClockMode.scrub),
    );
    expect(result.exact, isTrue);

    final StructuralRuntimeMarker? marker =
        parseStructuralRuntimeRegion(scene.terminal.currentRegion);
    if (marker == null || marker.placementIndex != placementIndex) continue;
    if (_runtimeLocalFrame(scene, marker) == localFrame) return projectFrame;
  }

  fail(
    'Did not find STRUCT placement $placementIndex local frame $localFrame.',
  );
}

Finder _readyInside(int placementIndex) {
  return find.descendant(
    of: find.byKey(
      ValueKey<String>('program-struct-layer-$placementIndex'),
    ),
    matching: find.byKey(
      const ValueKey<String>('structural-first-frame-ready'),
    ),
  );
}

Future<void> _waitForReady(WidgetTester tester, int placementIndex) async {
  final Finder ready = _readyInside(placementIndex);
  for (int attempt = 0; attempt < 20 && ready.evaluate().isEmpty; attempt++) {
    await tester.pump();
  }
  expect(ready, findsOneWidget);
}

FractionalTranslation _handoffMotionInside(
  WidgetTester tester,
  int placementIndex,
) {
  final Finder motion = find.descendant(
    of: find.byKey(
      ValueKey<String>('program-struct-layer-$placementIndex'),
    ),
    matching: find.byKey(
      const ValueKey<String>('structural-handoff-incoming'),
    ),
  );
  expect(motion, findsOneWidget);
  return tester.widget<FractionalTranslation>(motion);
}

double _bakeSlideTAt(int sourceFrame, int sourceDurationFrames) {
  final int slideFrames =
      sourceDurationFrames < kStructuralSwitchSlideFrames
          ? sourceDurationFrames
          : kStructuralSwitchSlideFrames;
  if (slideFrames <= 1) return 1.0;
  final double raw =
      (sourceFrame / (slideFrames - 1)).clamp(0.0, 1.0).toDouble();
  return Curves.easeInOutCubic.transform(raw);
}

Future<Uint8List> _captureRgba(WidgetTester tester) async {
  final RenderRepaintBoundary boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(_boundaryKey));

  final Uint8List? rgba = await tester.runAsync<Uint8List?>(() async {
    final ui.Image image = await boundary.toImage(pixelRatio: 1.0);
    try {
      final ByteData? data =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      image.dispose();
    }
  });

  expect(rgba, isNotNull);
  return rgba!;
}

int _structuralTitlePixelCount(Uint8List rgba) {
  // Windowed STRUCT at 320x180 has a broad #222222 title bar near the top
  // center. Count only that region so a desktop-only frame cannot pass merely
  // because the same color appears somewhere unrelated in the program image.
  //
  // This must track the production _StructuralWindow/Yaru plate. The older
  // #33302F probe was stale and had become a permanent false failure on main.
  const int width = 320;
  const int left = 70;
  const int right = 250;
  const int top = 20;
  const int bottom = 58;

  int count = 0;
  for (int y = top; y < bottom; y++) {
    for (int x = left; x < right; x++) {
      final int offset = (y * width + x) * 4;
      if (offset + 3 >= rgba.length) continue;
      if (rgba[offset] == 0x22 &&
          rgba[offset + 1] == 0x22 &&
          rgba[offset + 2] == 0x22 &&
          rgba[offset + 3] == 0xFF) {
        count++;
      }
    }
  }
  return count;
}

void main() {
  testWidgets(
    'seamless STRUCT raster never exposes desktop-only handoff frame',
    (WidgetTester tester) async {
      final Directory root = Directory.systemTemp.createTempSync(
        'r3nder_struct_raster_handoff_',
      );
      final Directory images = Directory('${root.path}/images')
        ..createSync(recursive: true);
      final Directory sprites = Directory('${root.path}/sprites')
        ..createSync(recursive: true);

      final CompiledScript compiled = compileScript(_source);
      final List<StructuralSequencePlacement> placements =
          parseStructuralSequencePlacements(_source);
      expect(placements, hasLength(2));
      expect(placements.first.seamlessToNext, isTrue);
      expect(placements.last.seamlessFromPrevious, isTrue);

      final SceneEngine scene = SceneEngine();
      await tester.runAsync(() async {
        await scene.setup(
          templateText: compiled.engineText,
          fontColor: Colors.green,
          bgColor: Colors.black,
          width: 320,
          height: 180,
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
      });

      final int firstProjectFrame = _findProjectFrame(
        scene,
        placementIndex: 0,
        localFrame: 0,
      );
      final int secondProjectFrame = _findProjectFrame(
        scene,
        placementIndex: 1,
        localFrame: 0,
      );
      final int secondMiddleProjectFrame = _findProjectFrame(
        scene,
        placementIndex: 1,
        localFrame: 1,
      );
      final int secondSlideEndProjectFrame = _findProjectFrame(
        scene,
        placementIndex: 1,
        localFrame: 2,
      );

      final _OfflineBackend backend = _OfflineBackend();
      final ChangeNotifier repaint = ChangeNotifier();

      addTearDown(() {
        repaint.dispose();
        scene.disposeImages();
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      expect(
        scene.evaluate(
          ProjectTime(frame: firstProjectFrame, mode: ProjectClockMode.scrub),
        ).exact,
        isTrue,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: _boundaryKey,
              child: SizedBox(
                width: 320,
                height: 180,
                child: ProgramPreviewSurface(
                  repaint: repaint,
                  scene: scene,
                  rawDocument: _source,
                  fontFamily: 'monospace',
                  theme: R3Theme.of(Colors.green),
                  structuralBackend: backend,
                  structuralResolveSource: _resolveSource,
                ),
              ),
            ),
          ),
        ),
      );

      await _waitForReady(tester, 0);
      await _waitForReady(tester, 1);

      expect(
        scene.evaluate(
          ProjectTime(frame: secondProjectFrame, mode: ProjectClockMode.scrub),
        ).exact,
        isTrue,
      );
      repaint.notifyListeners();

      // First active B frame: B paints underneath while A remains the cover.
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('program-struct-layer-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('program-struct-layer-1')),
        findsOneWidget,
      );

      final Uint8List overlapFrame = await _captureRgba(tester);
      expect(
        _structuralTitlePixelCount(overlapFrame),
        greaterThan(1000),
        reason: 'The first B frame must still rasterize a structural shell.',
      );

      // A second pump at the same authored frame may unlock the visual pan,
      // but it must not consume it. Readiness is a gate, not a timing source.
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('program-struct-layer-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('program-struct-layer-1')),
        findsOneWidget,
      );

      // Source frame 1 is the midpoint of this three-frame clamped switch.
      expect(
        scene.evaluate(
          ProjectTime(
            frame: secondMiddleProjectFrame,
            mode: ProjectClockMode.scrub,
          ),
        ).exact,
        isTrue,
      );
      repaint.notifyListeners();
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('program-struct-layer-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('program-struct-layer-1')),
        findsOneWidget,
      );

      final Finder outgoingMotion = find.descendant(
        of: find.byKey(
          const ValueKey<String>('program-struct-layer-0'),
        ),
        matching: find.byKey(
          const ValueKey<String>('structural-handoff-incoming'),
        ),
      );
      final Finder incomingMotion = find.descendant(
        of: find.byKey(
          const ValueKey<String>('program-struct-layer-1'),
        ),
        matching: find.byKey(
          const ValueKey<String>('structural-handoff-incoming'),
        ),
      );
      expect(outgoingMotion, findsOneWidget);
      expect(incomingMotion, findsOneWidget);

      final FractionalTranslation movingOut =
          tester.widget<FractionalTranslation>(outgoingMotion);
      final FractionalTranslation movingIn =
          tester.widget<FractionalTranslation>(incomingMotion);
      expect(movingOut.translation.dx, lessThan(0.0));
      expect(movingIn.translation.dx, greaterThan(0.0));

      final Uint8List middleFrame = await _captureRgba(tester);
      expect(
        _structuralTitlePixelCount(middleFrame),
        greaterThan(1000),
        reason: 'The midpoint slide must keep the structural shell rasterized.',
      );

      // The last source frame completes this short clamped pan and releases A.
      expect(
        scene.evaluate(
          ProjectTime(
            frame: secondSlideEndProjectFrame,
            mode: ProjectClockMode.scrub,
          ),
        ).exact,
        isTrue,
      );
      repaint.notifyListeners();
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('program-struct-layer-0')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('program-struct-layer-1')),
        findsOneWidget,
      );

      final Uint8List releasedFrame = await _captureRgba(tester);
      expect(
        _structuralTitlePixelCount(releasedFrame),
        greaterThan(1000),
        reason: 'Releasing A must not expose a desktop-only raster frame.',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'Program Preview slide position matches BAKE authored time when readiness is late',
    (WidgetTester tester) async {
      final Directory root = Directory.systemTemp.createTempSync(
        'r3nder_struct_preview_bake_parity_',
      );
      final Directory images = Directory('${root.path}/images')
        ..createSync(recursive: true);
      final Directory sprites = Directory('${root.path}/sprites')
        ..createSync(recursive: true);

      final CompiledScript compiled = compileScript(_paritySource);
      final List<StructuralSequencePlacement> placements =
          parseStructuralSequencePlacements(_paritySource);
      expect(placements, hasLength(2));
      expect(placements.first.seamlessToNext, isTrue);
      expect(placements.last.seamlessFromPrevious, isTrue);

      final SceneEngine scene = SceneEngine();
      await tester.runAsync(() async {
        await scene.setup(
          templateText: compiled.engineText,
          fontColor: Colors.green,
          bgColor: Colors.black,
          width: 320,
          height: 180,
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
      });

      final int firstProjectFrame = _findProjectFrame(
        scene,
        placementIndex: 0,
        localFrame: 0,
      );
      const int sourceFrame = 12;
      final int lateProjectFrame = _findProjectFrame(
        scene,
        placementIndex: 1,
        localFrame: sourceFrame,
      );
      final double expectedSlideT = _bakeSlideTAt(
        sourceFrame,
        placements.last.sourceDurationFrames,
      );

      final _OfflineBackend backend = _OfflineBackend();
      final ChangeNotifier repaint = ChangeNotifier();
      VoidCallback? acceptIncomingReadiness;

      addTearDown(() {
        repaint.dispose();
        scene.disposeImages();
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      expect(
        scene.evaluate(
          ProjectTime(frame: firstProjectFrame, mode: ProjectClockMode.scrub),
        ).exact,
        isTrue,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: _boundaryKey,
              child: SizedBox(
                width: 320,
                height: 180,
                child: ProgramPreviewSurface(
                  repaint: repaint,
                  scene: scene,
                  rawDocument: _paritySource,
                  fontFamily: 'monospace',
                  theme: R3Theme.of(Colors.green),
                  structuralBackend: backend,
                  structuralResolveSource: _resolveSource,
                  structuralReadinessInterceptor: (
                    int placementIndex,
                    VoidCallback accept,
                  ) {
                    if (placementIndex == 1) {
                      acceptIncomingReadiness ??= accept;
                    } else {
                      accept();
                    }
                  },
                ),
              ),
            ),
          ),
        ),
      );

      for (int attempt = 0;
          attempt < 20 && acceptIncomingReadiness == null;
          attempt++) {
        await tester.pump();
      }
      expect(acceptIncomingReadiness, isNotNull);

      expect(
        scene.evaluate(
          ProjectTime(frame: lateProjectFrame, mode: ProjectClockMode.scrub),
        ).exact,
        isTrue,
      );
      repaint.notifyListeners();
      await tester.pump();

      final double outgoingDx =
          _handoffMotionInside(tester, 0).translation.dx;
      final double incomingDx =
          _handoffMotionInside(tester, 1).translation.dx;

      debugPrint(
        'STRUCT preview/BAKE parity: sourceFrame=$sourceFrame '
        'expectedT=$expectedSlideT '
        'outgoingDx=$outgoingDx incomingDx=$incomingDx',
      );

      expect(
        outgoingDx,
        closeTo(-expectedSlideT, 0.0001),
        reason:
            'Preview outgoing position must match BAKE at the same authored frame.',
      );
      expect(
        incomingDx,
        closeTo(1.0 - expectedSlideT, 0.0001),
        reason:
            'Preview incoming position must match BAKE at the same authored frame.',
      );
      expect(
        incomingDx - outgoingDx,
        closeTo(1.0, 0.0001),
        reason: 'Complementary translations must cover the client width.',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
