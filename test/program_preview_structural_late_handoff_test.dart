// ./test/program_preview_structural_late_handoff_test.dart

import 'dart:io';

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

class _GateBackend implements MediaDecoderBackend {
  bool releaseB = false;
  final Map<String, int> opens = <String, int>{};

  @override
  MediaDecoder open(String resolvedPath) {
    opens[resolvedPath] = (opens[resolvedPath] ?? 0) + 1;
    if (resolvedPath.endsWith('/video/b.mp4')) {
      return _GateDecoder(() => releaseB);
    }
    return _OfflineDecoder(resolvedPath);
  }
}

class _OfflineDecoder implements MediaDecoder {
  final String path;

  _OfflineDecoder(this.path);

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    throw MediaDecodeException('intentional A offline: $path');
  }

  @override
  void dispose() {}
}

class _GateDecoder implements NonBlockingMediaDecoder {
  final bool Function() released;

  _GateDecoder(this.released);

  @override
  void request(int requestedSourceFrame, int width, int height) {}

  @override
  DecodedMediaFrame? poll(
    int requestedSourceFrame,
    int width,
    int height,
  ) {
    if (!released()) return null;
    throw const MediaDecodeException('intentional B resolved offline');
  }

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    throw const MediaDecodeException('intentional B blocking offline');
  }

  @override
  void dispose() {}
}

const String _source = '''[CONFIG:APPSWITCH:SLIDE]
[EDIT:first]
[TRACK:V1]
[CLIP:first:video/a.mp4:0:0:20:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:first]
[PANE:pane1]
[CLIP:first_edit:EDIT.first:0:0:20:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.first]

[EDIT:second]
[TRACK:V1]
[CLIP:second:video/b.mp4:0:0:15:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:second]
[PANE:pane1]
[CLIP:second_edit:EDIT.second:0:0:15:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.second]
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

double _programLayerOpacity(WidgetTester tester, int placementIndex) {
  final Positioned positioned = tester.widget<Positioned>(
    find.byKey(ValueKey<String>('program-struct-layer-$placementIndex')),
  );
  final IgnorePointer ignore = positioned.child as IgnorePointer;
  final Opacity opacity = ignore.child as Opacity;
  return opacity.opacity;
}

Stack _programStack(WidgetTester tester, int placementIndex) {
  final Finder ancestors = find.ancestor(
    of: find.byKey(
      ValueKey<String>('program-struct-layer-$placementIndex'),
    ),
    matching: find.byType(Stack),
  );
  expect(ancestors, findsWidgets);
  return tester.widget<Stack>(ancestors.first);
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

void main() {
  testWidgets(
    'late seamless B paints under A before A is released',
    (WidgetTester tester) async {
      final Directory root = Directory.systemTemp.createTempSync(
        'r3nder_struct_late_handoff_',
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

      expect(
        scene.evaluate(
          ProjectTime(frame: firstProjectFrame, mode: ProjectClockMode.scrub),
        ).exact,
        isTrue,
      );

      final _GateBackend backend = _GateBackend();
      final ChangeNotifier repaint = ChangeNotifier();

      addTearDown(() {
        repaint.dispose();
        scene.disposeImages();
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
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
      );

      for (int attempt = 0;
          attempt < 20 && _readyInside(0).evaluate().isEmpty;
          attempt++) {
        await tester.pump();
      }

      expect(_readyInside(0), findsOneWidget);
      expect(backend.opens['/workspace/video/b.mp4'], 1);
      expect(_readyInside(1), findsNothing);

      expect(
        scene.evaluate(
          ProjectTime(frame: secondProjectFrame, mode: ProjectClockMode.scrub),
        ).exact,
        isTrue,
      );
      repaint.notifyListeners();
      await tester.pump();

      // B is active and fully paintable underneath, even while its media is
      // unresolved. A remains the topmost opaque cover, so the desktop inside
      // B cannot leak into the finished program plane.
      expect(
        find.byKey(const ValueKey<String>('program-struct-layer-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('program-struct-layer-1')),
        findsOneWidget,
      );
      expect(_programLayerOpacity(tester, 0), 1.0);
      expect(_programLayerOpacity(tester, 1), 1.0);
      expect(
        _programStack(tester, 0).children.last.key,
        const ValueKey<String>('program-struct-layer-0'),
      );

      backend.releaseB = true;
      for (int attempt = 0;
          attempt < 20 && _readyInside(1).evaluate().isEmpty;
          attempt++) {
        await tester.pump();
      }

      // Logical readiness alone is not enough to remove A. B must paint one
      // active ready frame underneath A first; the post-frame commit removes A
      // on the following build.
      expect(_readyInside(1), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('program-struct-layer-0')),
        findsOneWidget,
      );
      expect(_programLayerOpacity(tester, 0), 1.0);
      expect(_programLayerOpacity(tester, 1), 1.0);
      expect(
        _programStack(tester, 0).children.last.key,
        const ValueKey<String>('program-struct-layer-0'),
      );

      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('program-struct-layer-0')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('program-struct-layer-1')),
        findsOneWidget,
      );
      expect(_programLayerOpacity(tester, 1), 1.0);
      expect(backend.opens['/workspace/video/b.mp4'], 1);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
