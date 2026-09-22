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

class _ColdSplitBackend implements MediaDecoderBackend {
  bool releaseLeft = false;
  bool releaseRight = false;
  final Map<String, int> opens = <String, int>{};
  final Map<String, _CountingGateDecoder> decoders =
      <String, _CountingGateDecoder>{};

  @override
  MediaDecoder open(String resolvedPath) {
    opens[resolvedPath] = (opens[resolvedPath] ?? 0) + 1;
    final bool left = resolvedPath.endsWith('/video/left.mp4');
    final _CountingGateDecoder decoder = _CountingGateDecoder(
      released: () => left ? releaseLeft : releaseRight,
      color: left
          ? const <int>[220, 40, 40, 255]
          : const <int>[40, 120, 240, 255],
    );
    decoders[resolvedPath] = decoder;
    return decoder;
  }
}

class _ColdSameSourceBackend implements MediaDecoderBackend {
  bool released = false;
  int opens = 0;
  _CountingGateDecoder? decoder;

  @override
  MediaDecoder open(String resolvedPath) {
    opens++;
    final _CountingGateDecoder created = _CountingGateDecoder(
      released: () => released,
      color: const <int>[180, 90, 220, 255],
    );
    decoder = created;
    return created;
  }
}

class _CountingGateDecoder implements NonBlockingMediaDecoder {
  _CountingGateDecoder({
    required this.released,
    required this.color,
  });

  final bool Function() released;
  final List<int> color;
  final List<int> requestFrames = <int>[];
  final List<int> pollFrames = <int>[];

  @override
  void request(int requestedSourceFrame, int width, int height) {
    requestFrames.add(requestedSourceFrame);
  }

  @override
  DecodedMediaFrame? poll(
    int requestedSourceFrame,
    int width,
    int height,
  ) {
    pollFrames.add(requestedSourceFrame);
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

const String _splitToWindowSource = '''[CONFIG:APPSWITCH:SLIDE]
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
[EDIT:second]
[TRACK:V1]
[CLIP:b1:video/b1.mp4:0:0:12:1]
[/CLIP]
[/TRACK]
[/EDIT]
[STRUCT:MOSAIC.first:SPLIT]
[STRUCT:EDIT.second]
''';

String _coldSplitOpeningSource({required bool maximized}) {
  final String max = maximized ? ':MAX' : '';
  return '''[SPEED:MAX]
[EDIT:left_nested]
[TRACK:V1]
[CLIP:left_leaf:video/left.mp4:0:0:12:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:left]
[CLIP:left_nested_ref:EDIT.left_nested:0:0:12:1]
[/CLIP]
[/PANE]
[PANE:right]
[CLIP:right_leaf:video/right.mp4:0:0:12:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall:SPLIT$max:OVERLAY=NONE]
''';
}

String _coldSameSourceSplitOpeningSource() => '''[SPEED:MAX]
[EDIT:shared]
[TRACK:V1]
[CLIP:shared_leaf:video/shared.mp4:0:0:12:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:left]
[CLIP:shared_edit_ref:EDIT.shared:0:0:12:1]
[/CLIP]
[/PANE]
[PANE:right]
[CLIP:shared_edit_ref:EDIT.shared:0:0:12:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall:SPLIT:OVERLAY=NONE]
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
  required MediaDecoderBackend backend,
  ValueChanged<StructuralPreviewBufferingState>? onStructuralBufferingChanged,
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
        onStructuralBufferingChanged: onStructuralBufferingChanged,
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

Rect _ordinaryWindowRect(WidgetTester tester, int index) {
  final Positioned positioned = tester.widget<Positioned>(
    find.descendant(
      of: _layer(index),
      matching: find.byKey(
        const ValueKey<String>('structural-window-positioned'),
      ),
    ),
  );
  return Rect.fromLTWH(
    positioned.left ?? 0.0,
    positioned.top ?? 0.0,
    positioned.width ?? 0.0,
    positioned.height ?? 0.0,
  );
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

int _earlyPartialOpeningLocalFrame(
  StructuralSequencePlacement placement,
) {
  final List<int> opening = <int>[
    for (int frame = 0; frame < placement.effectiveDurationFrames; frame++)
      if (placement.stageAt(frame) == StructuralSequenceStage.opening &&
          placement.stageProgressAt(frame) > 0.0 &&
          placement.stageProgressAt(frame) < 1.0 &&
          placement.sourceFrameAt(frame) == 0)
        frame,
  ];
  expect(opening, isNotEmpty);
  return opening.first;
}

StructuralSplitWindowPainter _splitPainter(
  WidgetTester tester,
  int placementIndex,
) {
  final CustomPaint paint = tester.widget<CustomPaint>(
    find.descendant(
      of: _layer(placementIndex),
      matching: find.byKey(
        const ValueKey<String>('structural-split-window-frame'),
      ),
    ),
  );
  return paint.painter! as StructuralSplitWindowPainter;
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

Future<void> _expectColdSplitOpeningRetries(
  WidgetTester tester, {
  required bool maximized,
}) async {
  final String source = _coldSplitOpeningSource(maximized: maximized);
  final StructuralSequencePlacement placement =
      parseStructuralSequencePlacements(source).single;
  expect(placement.splitWindow, isTrue);
  expect(placement.maximizeSplit, maximized);

  final int openingLocal = _earlyPartialOpeningLocalFrame(placement);
  final double authoredProgress = placement.stageProgressAt(openingLocal);
  expect(authoredProgress, allOf(greaterThan(0.0), lessThan(0.4)));
  expect(placement.sourceFrameAt(openingLocal), 0);

  final SceneEngine scene = SceneEngine();
  final Directory root = await _setupScene(tester, scene, source);
  final ChangeNotifier repaint = ChangeNotifier();
  final _ColdSplitBackend backend = _ColdSplitBackend();
  final List<StructuralPreviewBufferingState> buffering =
      <StructuralPreviewBufferingState>[];
  addTearDown(() {
    repaint.dispose();
    scene.disposeImages();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  final int openingProject = _findProjectFrame(
    scene,
    placementIndex: 0,
    localFrame: openingLocal,
  );
  expect(
    scene.evaluate(
      ProjectTime(frame: openingProject, mode: ProjectClockMode.scrub),
    ).exact,
    isTrue,
  );

  await tester.pumpWidget(
    _program(
      scene: scene,
      repaint: repaint,
      source: source,
      backend: backend,
      onStructuralBufferingChanged: buffering.add,
    ),
  );

  await _pumpUntil(
    tester,
    () => backend.decoders.length == 2 &&
        backend.decoders.values.every(
          (_CountingGateDecoder decoder) => decoder.pollFrames.isNotEmpty,
        ),
  );

  final _CountingGateDecoder left =
      backend.decoders['/workspace/video/left.mp4']!;
  final _CountingGateDecoder right =
      backend.decoders['/workspace/video/right.mp4']!;

  expect(backend.opens['/workspace/video/left.mp4'], 1);
  expect(backend.opens['/workspace/video/right.mp4'], 1);
  expect(
    find.descendant(
      of: _layer(0),
      matching: find.byKey(
        const ValueKey<String>('structural-first-frame-ready'),
      ),
    ),
    findsNothing,
  );
  expect(_splitPresentationOpacity(tester, 0), 0.0);
  await tester.pump();
  expect(buffering, isNotEmpty);
  expect(buffering.last.buffering, isTrue);
  expect(buffering.last.placementIndex, 0);
  expect(
    buffering.last.openingFrame,
    placement.stageFrameAt(openingLocal),
  );

  final int leftPollsBeforeRelease = left.pollFrames.length;
  backend.releaseLeft = true;
  await _pumpUntil(
    tester,
    () => left.pollFrames.length > leftPollsBeforeRelease,
  );

  // One pane becoming resident is not enough to expose a mismatched pair.
  expect(
    find.descendant(
      of: _layer(0),
      matching: find.byKey(
        const ValueKey<String>('structural-first-frame-ready'),
      ),
    ),
    findsNothing,
  );
  expect(_splitPresentationOpacity(tester, 0), 0.0);

  final int rightPollsBeforeRelease = right.pollFrames.length;
  backend.releaseRight = true;

  // Do not evaluate another project frame, notify repaint, or replace the
  // widget here. The split preview's own pending retry must discover readiness
  // at the same authored opening/source frame.
  await _pumpUntil(
    tester,
    () => find.descendant(
      of: _layer(0),
      matching: find.byKey(
        const ValueKey<String>('structural-first-frame-ready'),
      ),
    ).evaluate().isNotEmpty,
  );
  expect(right.pollFrames.length, greaterThan(rightPollsBeforeRelease));
  await tester.pump();
  expect(buffering.last, StructuralPreviewBufferingState.idle);

  final StructuralSplitWindowPreview preview =
      tester.widget<StructuralSplitWindowPreview>(
    find.descendant(
      of: _layer(0),
      matching: find.byType(StructuralSplitWindowPreview),
    ),
  );
  expect(preview.sourceFrame, 0);
  expect(preview.entryProgress, closeTo(authoredProgress, 0.000001));

  final StructuralSplitWindowPainter painter = _splitPainter(tester, 0);
  expect(painter.sourceFrame, 0);
  expect(painter.entryProgress, closeTo(authoredProgress, 0.000001));
  expect(painter.images, hasLength(2));
  expect(painter.images[0], isNotNull);
  expect(painter.images[1], isNotNull);
  expect(
    _splitPresentationOpacity(tester, 0),
    allOf(greaterThan(0.0), lessThan(1.0)),
  );

  expect(left.requestFrames, isNotEmpty);
  expect(right.requestFrames, isNotEmpty);
  expect(left.requestFrames.every((int frame) => frame == 0), isTrue);
  expect(right.requestFrames.every((int frame) => frame == 0), isTrue);
  expect(left.pollFrames.every((int frame) => frame == 0), isTrue);
  expect(right.pollFrames.every((int frame) => frame == 0), isTrue);
  expect(backend.opens['/workspace/video/left.mp4'], 1);
  expect(backend.opens['/workspace/video/right.mp4'], 1);

  // Let readiness/setState/post-frame bookkeeping settle, then prove the
  // pending self-poll loop stopped once both panes resolved.
  await tester.pump();
  await tester.pump();
  final int leftPollsReady = left.pollFrames.length;
  final int rightPollsReady = right.pollFrames.length;
  await tester.pump();
  await tester.pump();
  await tester.pump();
  expect(left.pollFrames.length, leftPollsReady);
  expect(right.pollFrames.length, rightPollsReady);
}

Future<void> _expectColdSameSourceSplitRetries(
  WidgetTester tester,
) async {
  final String source = _coldSameSourceSplitOpeningSource();
  final StructuralSequencePlacement placement =
      parseStructuralSequencePlacements(source).single;
  final int openingLocal = _earlyPartialOpeningLocalFrame(placement);
  final double authoredProgress = placement.stageProgressAt(openingLocal);

  final SceneEngine scene = SceneEngine();
  final Directory root = await _setupScene(tester, scene, source);
  final ChangeNotifier repaint = ChangeNotifier();
  final _ColdSameSourceBackend backend = _ColdSameSourceBackend();
  addTearDown(() {
    repaint.dispose();
    scene.disposeImages();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  final int openingProject = _findProjectFrame(
    scene,
    placementIndex: 0,
    localFrame: openingLocal,
  );
  expect(
    scene.evaluate(
      ProjectTime(frame: openingProject, mode: ProjectClockMode.scrub),
    ).exact,
    isTrue,
  );

  await tester.pumpWidget(
    _program(
      scene: scene,
      repaint: repaint,
      source: source,
      backend: backend,
    ),
  );

  await _pumpUntil(
    tester,
    () => backend.decoder != null &&
        backend.decoder!.pollFrames.isNotEmpty,
  );

  // Both panes reference the same resolved path, so MediaLayer must reuse one
  // persistent decoder instead of opening competing workers for the same file.
  expect(backend.opens, 1);
  final _CountingGateDecoder decoder = backend.decoder!;
  expect(
    find.descendant(
      of: _layer(0),
      matching: find.byKey(
        const ValueKey<String>('structural-first-frame-ready'),
      ),
    ),
    findsNothing,
  );

  final int pollsBeforeRelease = decoder.pollFrames.length;
  backend.released = true;

  // No project-frame advance or repaint notification: the pending retry must
  // discover the shared decoder's resident frame for both panes.
  await _pumpUntil(
    tester,
    () => find.descendant(
      of: _layer(0),
      matching: find.byKey(
        const ValueKey<String>('structural-first-frame-ready'),
      ),
    ).evaluate().isNotEmpty,
  );
  expect(decoder.pollFrames.length, greaterThan(pollsBeforeRelease));

  final StructuralSplitWindowPainter painter = _splitPainter(tester, 0);
  expect(painter.sourceFrame, 0);
  expect(painter.entryProgress, closeTo(authoredProgress, 0.000001));
  expect(painter.images[0], isNotNull);
  expect(painter.images[1], isNotNull);
  expect(backend.opens, 1);
  expect(decoder.requestFrames.every((int frame) => frame == 0), isTrue);
  expect(decoder.pollFrames.every((int frame) => frame == 0), isTrue);

  await tester.pump();
  await tester.pump();
  final int pollsReady = decoder.pollFrames.length;
  await tester.pump();
  await tester.pump();
  expect(decoder.pollFrames.length, pollsReady);
}

void main() {
  testWidgets(
    'cold SPLIT opening retries pending panes without advancing source time',
    (WidgetTester tester) async {
      await _expectColdSplitOpeningRetries(
        tester,
        maximized: false,
      );
    },
  );

  testWidgets(
    'cold SPLIT MAX opening retries pending panes without advancing source time',
    (WidgetTester tester) async {
      await _expectColdSplitOpeningRetries(
        tester,
        maximized: true,
      );
    },
  );

  testWidgets(
    'cold SPLIT supports the same nested EDIT and CLIP id in both panes',
    (WidgetTester tester) async {
      await _expectColdSameSourceSplitRetries(tester);
    },
  );

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
    'window to split opens both incoming panes over a fading outgoing window',
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
      final int entryMiddle = _findProjectFrame(
        scene,
        placementIndex: 1,
        localFrame: kStructuralWindowFrames ~/ 2,
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
          ProjectTime(frame: entryMiddle, mode: ProjectClockMode.scrub),
        ).exact,
        isTrue,
      );
      repaint.notifyListeners();
      await tester.pump();

      expect(_layer(0), findsOneWidget);
      expect(_layer(1), findsOneWidget);
      expect(_layerOpacity(tester, 1), 1.0);
      expect(_layerOpacity(tester, 0), allOf(greaterThan(0.0), lessThan(1.0)));
      expect(_splitPresentationOpacity(tester, 1), greaterThan(0.0));
      expect(_handoffRole(tester, 0), StructuralSequenceHandoffRole.heldOutgoing);

      final CustomPaint entryPaint = tester.widget<CustomPaint>(
        find.descendant(
          of: _layer(1),
          matching: find.byKey(
            const ValueKey<String>('structural-split-window-frame'),
          ),
        ),
      );
      final StructuralSplitWindowPainter entryPainter =
          entryPaint.painter! as StructuralSplitWindowPainter;
      expect(entryPainter.sourceFrame, 0);
      expect(entryPainter.entryProgress, allOf(greaterThan(0.0), lessThan(1.0)));

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

  testWidgets(
    'split to window opens the incoming window over fading split panes',
    (WidgetTester tester) async {
      final List<StructuralSequencePlacement> placements =
          parseStructuralSequencePlacements(_splitToWindowSource);
      expect(placements, hasLength(2));
      final StructuralSequencePlacement second = placements[1];
      expect(second.entryWindowFrames, kStructuralWindowFrames);

      final SceneEngine scene = SceneEngine();
      final Directory root =
          await _setupScene(tester, scene, _splitToWindowSource);
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
      final int entryMiddle = _findProjectFrame(
        scene,
        placementIndex: 1,
        localFrame: kStructuralWindowFrames ~/ 2,
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
          source: _splitToWindowSource,
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
          ProjectTime(frame: entryMiddle, mode: ProjectClockMode.scrub),
        ).exact,
        isTrue,
      );
      repaint.notifyListeners();
      await tester.pump();

      expect(_layer(0), findsOneWidget);
      expect(_layer(1), findsOneWidget);
      expect(_layerOpacity(tester, 0), allOf(greaterThan(0.0), lessThan(1.0)));
      final Rect middleRect = _ordinaryWindowRect(tester, 1);
      expect(middleRect.width, greaterThan(0.0));

      expect(
        scene.evaluate(
          ProjectTime(frame: showingStart, mode: ProjectClockMode.scrub),
        ).exact,
        isTrue,
      );
      repaint.notifyListeners();
      await tester.pump();
      await _pumpUntil(tester, () => _layer(0).evaluate().isEmpty);

      final Rect seatedRect = _ordinaryWindowRect(tester, 1);
      expect(middleRect.width, lessThan(seatedRect.width));
      expect(middleRect.height, lessThan(seatedRect.height));

      final StructuralSequencePreview preview =
          tester.widget<StructuralSequencePreview>(
        find.descendant(
          of: _layer(1),
          matching: find.byType(StructuralSequencePreview),
        ),
      );
      expect(preview.localFrame, kStructuralWindowFrames);
    },
  );
}
