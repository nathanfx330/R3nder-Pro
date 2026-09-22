// ./test/program_preview_structural_split_transition_test.dart

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
import 'package:r3nder/structural_sequence_preview.dart';
import 'package:r3nder/structural_split_window_painter.dart';
import 'package:r3nder/structural_split_window_preview.dart';
import 'package:r3nder/ui_theme.dart';

class _TransitionBackend implements MediaDecoderBackend {
  bool releaseSecond = false;
  final Map<String, int> opens = <String, int>{};

  @override
  MediaDecoder open(String resolvedPath) {
    opens[resolvedPath] = (opens[resolvedPath] ?? 0) + 1;
    final bool second = resolvedPath.contains('/video/b');
    if (second) {
      return _GateColorDecoder(
        () => releaseSecond,
        resolvedPath.endsWith('2.mp4')
            ? const <int>[0, 160, 255, 255]
            : const <int>[0, 220, 80, 255],
      );
    }
    return _SolidColorDecoder(
      resolvedPath.endsWith('2.mp4')
          ? const <int>[255, 180, 0, 255]
          : const <int>[240, 30, 30, 255],
    );
  }
}

class _SolidColorDecoder implements MediaDecoder {
  _SolidColorDecoder(this.color);

  final List<int> color;

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) =>
      _frame(requestedSourceFrame, width, height, color);

  @override
  void dispose() {}
}

class _GateColorDecoder implements NonBlockingMediaDecoder {
  _GateColorDecoder(this.released, this.color);

  final bool Function() released;
  final List<int> color;

  @override
  void request(int requestedSourceFrame, int width, int height) {}

  @override
  DecodedMediaFrame? poll(
    int requestedSourceFrame,
    int width,
    int height,
  ) {
    if (!released()) return null;
    return _frame(requestedSourceFrame, width, height, color);
  }

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) =>
      _frame(requestedSourceFrame, width, height, color);

  @override
  void dispose() {}
}

DecodedMediaFrame _frame(
  int requestedSourceFrame,
  int width,
  int height,
  List<int> color,
) {
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

const String _splitToSplitSource = '''[CONFIG:APPSWITCH:SLIDE]
[MOSAIC:first]
[PANE:p1]
[CLIP:a1:video/a1.mp4:0:0:12:1]
[/CLIP]
[/PANE]
[PANE:p2]
[CLIP:a2:video/a2.mp4:0:0:12:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[MOSAIC:second]
[PANE:p1]
[CLIP:b1:video/b1.mp4:0:0:12:1]
[/CLIP]
[/PANE]
[PANE:p2]
[CLIP:b2:video/b2.mp4:0:0:12:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.first:SPLIT]
[STRUCT:MOSAIC.second:SPLIT:ASPECT=4X3]
''';

const String _windowToSplitSource = '''[CONFIG:APPSWITCH:SLIDE]
[EDIT:first]
[TRACK:V1]
[CLIP:a1:video/a1.mp4:0:0:12:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:second]
[PANE:p1]
[CLIP:a2:video/a2.mp4:0:0:12:1]
[/CLIP]
[/PANE]
[PANE:p2]
[CLIP:a3:video/a3.mp4:0:0:12:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:EDIT.first]
[STRUCT:MOSAIC.second:SPLIT]
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
  for (int projectFrame = 0; projectFrame < 500; projectFrame++) {
    final SceneEvaluationResult result = scene.evaluate(
      ProjectTime(frame: projectFrame, mode: ProjectClockMode.scrub),
    );
    expect(result.exact, isTrue);
    final StructuralRuntimeMarker? marker =
        parseStructuralRuntimeRegion(scene.terminal.currentRegion);
    if (marker == null || marker.placementIndex != placementIndex) continue;
    if (_runtimeLocalFrame(scene, marker) == localFrame) return projectFrame;
  }
  fail('Missing placement $placementIndex local frame $localFrame.');
}

Future<Directory> _setupScene(
  WidgetTester tester,
  SceneEngine scene,
  String source,
) async {
  final Directory root =
      Directory.systemTemp.createTempSync('r3nder_w5_split_transition_');
  final Directory images = Directory('${root.path}/images')
    ..createSync(recursive: true);
  final Directory sprites = Directory('${root.path}/sprites')
    ..createSync(recursive: true);
  final CompiledScript compiled = compileScript(source);

  await tester.runAsync(() async {
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
  });
  return root;
}

Widget _program({
  required SceneEngine scene,
  required ChangeNotifier repaint,
  required String source,
  required _TransitionBackend backend,
}) {
  return MaterialApp(
    home: SizedBox(
      width: 640,
      height: 360,
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
  );
}

Finder _layer(int index) =>
    find.byKey(ValueKey<String>('program-struct-layer-$index'));

double _layerOpacity(WidgetTester tester, int index) {
  final Positioned positioned = tester.widget<Positioned>(_layer(index));
  final IgnorePointer ignore = positioned.child as IgnorePointer;
  return (ignore.child as Opacity).opacity;
}

double _splitPresentationOpacity(WidgetTester tester, int index) {
  final Opacity opacity = tester.widget<Opacity>(
    find.descendant(
      of: _layer(index),
      matching: find.byKey(
        const ValueKey<String>('structural-split-window-opacity'),
      ),
    ),
  );
  return opacity.opacity;
}

StructuralSequenceHandoffRole _handoffRole(
  WidgetTester tester,
  int placementIndex,
) {
  final StructuralSequencePreview preview =
      tester.widget<StructuralSequencePreview>(
    find.descendant(
      of: _layer(placementIndex),
      matching: find.byType(StructuralSequencePreview),
    ),
  );
  return preview.handoffRole;
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() done,
) async {
  for (int attempt = 0; attempt < 60 && !done(); attempt++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    });
    await tester.pump();
  }
  expect(done(), isTrue);
}

void main() {
  testWidgets(
    'late split to split readiness holds both old panes then cuts at current source time',
    (WidgetTester tester) async {
      final List<StructuralSequencePlacement> placements =
          parseStructuralSequencePlacements(_splitToSplitSource);
      expect(placements, hasLength(2));
      expect(placements[1].entryWindowFrames, 0);

      final SceneEngine scene = SceneEngine();
      final Directory root =
          await _setupScene(tester, scene, _splitToSplitSource);
      final ChangeNotifier repaint = ChangeNotifier();
      final _TransitionBackend backend = _TransitionBackend();
      addTearDown(() {
        repaint.dispose();
        scene.disposeImages();
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      final int firstShowing = _findProjectFrame(
        scene,
        placementIndex: 0,
        localFrame: placements[0].contentStartFrame,
      );
      final int lateSecond = _findProjectFrame(
        scene,
        placementIndex: 1,
        localFrame: 4,
      );
      final int releasedSecond = _findProjectFrame(
        scene,
        placementIndex: 1,
        localFrame: 5,
      );

      expect(
        scene.evaluate(
          ProjectTime(frame: firstShowing, mode: ProjectClockMode.scrub),
        ).exact,
        isTrue,
      );
      await tester.pumpWidget(
        _program(
          scene: scene,
          repaint: repaint,
          source: _splitToSplitSource,
          backend: backend,
        ),
      );

      await _pumpUntil(
        tester,
        () => find.descendant(
          of: _layer(0),
          matching: find.byKey(
            const ValueKey<String>('structural-first-frame-ready'),
          ),
        ).evaluate().isNotEmpty,
      );

      expect(_layer(1), findsOneWidget);
      expect(_layerOpacity(tester, 1), 0.0);

      expect(
        scene.evaluate(
          ProjectTime(frame: lateSecond, mode: ProjectClockMode.scrub),
        ).exact,
        isTrue,
      );
      repaint.notifyListeners();
      await tester.pump();

      expect(_layer(0), findsOneWidget);
      expect(_layer(1), findsOneWidget);
      expect(_handoffRole(tester, 0), StructuralSequenceHandoffRole.heldOutgoing);
      expect(_handoffRole(tester, 1), StructuralSequenceHandoffRole.none);
      expect(
        find.byKey(const ValueKey<String>('structural-handoff-outgoing')),
        findsNothing,
      );

      final StructuralSplitWindowPreview latePreview =
          tester.widget<StructuralSplitWindowPreview>(
        find.descendant(
          of: _layer(1),
          matching: find.byType(StructuralSplitWindowPreview),
        ),
      );
      expect(latePreview.sourceFrame, 4);

      backend.releaseSecond = true;
      expect(
        scene.evaluate(
          ProjectTime(frame: releasedSecond, mode: ProjectClockMode.scrub),
        ).exact,
        isTrue,
      );
      repaint.notifyListeners();
      await tester.pump();

      await _pumpUntil(
        tester,
        () => find.descendant(
          of: _layer(1),
          matching: find.byKey(
            const ValueKey<String>('structural-first-frame-ready'),
          ),
        ).evaluate().isNotEmpty,
      );

      // One active-ready paint happens under the stationary old split.
      expect(_layer(0), findsOneWidget);
      await tester.pump();

      await _pumpUntil(tester, () => _layer(0).evaluate().isEmpty);
      expect(_layer(1), findsOneWidget);

      final CustomPaint paint = tester.widget<CustomPaint>(
        find.descendant(
          of: _layer(1),
          matching: find.byKey(
            const ValueKey<String>('structural-split-window-frame'),
          ),
        ),
      );
      final StructuralSplitWindowPainter painter =
          paint.painter! as StructuralSplitWindowPainter;
      expect(painter.sourceFrame, 5);
      expect(
        painter.geometry.aspect.name,
        contains('4x3'),
      );
    },
  );

  testWidgets(
    'window to split holds outgoing for exactly the incoming window budget',
    (WidgetTester tester) async {
      final List<StructuralSequencePlacement> placements =
          parseStructuralSequencePlacements(_windowToSplitSource);
      expect(placements, hasLength(2));
      final StructuralSequencePlacement second = placements[1];
      expect(second.entryWindowFrames, kStructuralWindowFrames);

      final SceneEngine scene = SceneEngine();
      final Directory root =
          await _setupScene(tester, scene, _windowToSplitSource);
      final ChangeNotifier repaint = ChangeNotifier();
      final _TransitionBackend backend = _TransitionBackend()
        ..releaseSecond = true;
      addTearDown(() {
        repaint.dispose();
        scene.disposeImages();
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      final int firstShowing = _findProjectFrame(
        scene,
        placementIndex: 0,
        localFrame: placements[0].contentStartFrame,
      );
      final int entryLast = _findProjectFrame(
        scene,
        placementIndex: 1,
        localFrame: kStructuralWindowFrames - 1,
      );
      final int showingStart = _findProjectFrame(
        scene,
        placementIndex: 1,
        localFrame: kStructuralWindowFrames,
      );

      expect(
        scene.evaluate(
          ProjectTime(frame: firstShowing, mode: ProjectClockMode.scrub),
        ).exact,
        isTrue,
      );
      await tester.pumpWidget(
        _program(
          scene: scene,
          repaint: repaint,
          source: _windowToSplitSource,
          backend: backend,
        ),
      );

      await _pumpUntil(
        tester,
        () => find.descendant(
          of: _layer(1),
          matching: find.byKey(
            const ValueKey<String>('structural-first-frame-ready'),
          ),
        ).evaluate().isNotEmpty,
      );

      expect(
        scene.evaluate(
          ProjectTime(frame: entryLast, mode: ProjectClockMode.scrub),
        ).exact,
        isTrue,
      );
      repaint.notifyListeners();
      await tester.pump();

      expect(_layer(0), findsOneWidget);
      expect(_layer(1), findsOneWidget);
      expect(_layerOpacity(tester, 1), 1.0);
      expect(_splitPresentationOpacity(tester, 1), 0.0);
      expect(_handoffRole(tester, 0), StructuralSequenceHandoffRole.heldOutgoing);

      expect(
        scene.evaluate(
          ProjectTime(frame: showingStart, mode: ProjectClockMode.scrub),
        ).exact,
        isTrue,
      );
      repaint.notifyListeners();
      await tester.pump();

      expect(_layerOpacity(tester, 1), 1.0);
      expect(_splitPresentationOpacity(tester, 1), 1.0);
      expect(_layer(0), findsOneWidget);
      await tester.pump();
      await _pumpUntil(tester, () => _layer(0).evaluate().isEmpty);

      final StructuralSplitWindowPreview preview =
          tester.widget<StructuralSplitWindowPreview>(
        find.descendant(
          of: _layer(1),
          matching: find.byType(StructuralSplitWindowPreview),
        ),
      );
      expect(preview.sourceFrame, 0);
    },
  );
}
