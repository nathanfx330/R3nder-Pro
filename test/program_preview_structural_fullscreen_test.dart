// ./test/program_preview_structural_fullscreen_test.dart

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/structural_sequence.dart';
import 'package:r3nder/structural_sequence_preview.dart';
import 'package:r3nder/ui_theme.dart';

const double _testWidth = 800.0;
const double _testHeight = 500.0;
const double _titleHeight = 38.0;

class _OfflineBackend implements MediaDecoderBackend {
  @override
  MediaDecoder open(String resolvedPath) => _OfflineDecoder(resolvedPath);
}

class _OfflineDecoder implements MediaDecoder {
  final String path;

  _OfflineDecoder(this.path);

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    // Geometry is the only concern of this gate. Resolve preview readiness to
    // a stable OFFLINE state so the shell can morph without entering RGBA image
    // conversion or coupling this test to decoder lifetime.
    throw MediaDecodeException('intentional geometry-test offline: $path');
  }

  @override
  void dispose() {}
}

String _source({
  required bool firstFullscreen,
  required bool secondFullscreen,
}) {
  final String firstSuffix = firstFullscreen ? ':FULL' : '';
  final String secondSuffix = secondFullscreen ? ':FULL' : '';
  return '''[CONFIG:APPSWITCH:SLIDE]
[MOSAIC:first]
[PANE:pane1]
[CLIP:a:video/a.mp4:0:0:3:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[MOSAIC:second]
[PANE:pane1]
[CLIP:b:video/b.mp4:0:0:3:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.first$firstSuffix]
[STRUCT:MOSAIC.second$secondSuffix]
''';
}

String _resolveSource(String source) => '/workspace/$source';

Rect _fittedProgramFrame() {
  double frameW = _testWidth;
  double frameH = frameW * 9.0 / 16.0;
  if (frameH > _testHeight) {
    frameH = _testHeight;
    frameW = frameH * 16.0 / 9.0;
  }
  return Rect.fromLTWH(
    (_testWidth - frameW) / 2.0,
    (_testHeight - frameH) / 2.0,
    frameW,
    frameH,
  );
}

Rect _windowRect(Rect frame) {
  final double maxW = frame.width * 0.86;
  final double maxH = frame.height * 0.78;

  double clientW = maxW;
  double clientH = clientW * 9.0 / 16.0;
  if (clientH + _titleHeight > maxH) {
    clientH = math.max(1.0, maxH - _titleHeight);
    clientW = clientH * 16.0 / 9.0;
  }

  final double windowH = clientH + _titleHeight;
  return Rect.fromLTWH(
    frame.left + (frame.width - clientW) / 2.0,
    frame.top + (frame.height - windowH) / 2.0,
    clientW,
    windowH,
  );
}

Rect _presentationRect(StructuralPresentationMode mode) {
  final Rect frame = _fittedProgramFrame();
  return mode == StructuralPresentationMode.fullscreen
      ? frame
      : _windowRect(frame);
}

Rect _expectedRect(
  StructuralSequencePlacement placement,
  int localFrame,
) {
  final Rect target = _presentationRect(placement.presentationMode);
  if (localFrame >= placement.contentStartFrame) return target;

  final StructuralPresentationMode previous =
      placement.previousPresentationMode!;
  final Rect start = _presentationRect(previous);
  final double eased = Curves.easeInOutCubic.transform(
    placement.stageProgressAt(localFrame),
  );
  return Rect.lerp(start, target, eased)!;
}

void _expectSameRect(Rect actual, Rect expected) {
  expect(actual.left, closeTo(expected.left, 0.02));
  expect(actual.top, closeTo(expected.top, 0.02));
  expect(actual.width, closeTo(expected.width, 0.02));
  expect(actual.height, closeTo(expected.height, 0.02));
}

Widget _buildPreview({
  required String source,
  required StructuralSequencePlacement placement,
  required _OfflineBackend backend,
  required int localFrame,
}) {
  return MaterialApp(
    home: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: _testWidth,
        height: _testHeight,
        child: StructuralSequencePreview(
          rawDocument: source,
          placement: placement,
          localFrame: localFrame,
          isPlaying: true,
          theme: R3Theme.of(Colors.green),
          wallpaper: null,
          backend: backend,
          resolveSource: _resolveSource,
        ),
      ),
    ),
  );
}

Future<void> _waitForReady(WidgetTester tester) async {
  final Finder ready = find.byKey(
    const ValueKey<String>('structural-first-frame-ready'),
  );
  for (int attempt = 0; attempt < 8 && ready.evaluate().isEmpty; attempt++) {
    await tester.pump();
  }
  expect(ready, findsOneWidget);
}

Rect _structuralRect(WidgetTester tester) {
  return tester.getRect(
    find.byKey(const ValueKey<String>('structural-window-frame')),
  );
}

Future<void> _showLocalFrame(
  WidgetTester tester, {
  required String source,
  required StructuralSequencePlacement placement,
  required _OfflineBackend backend,
  required int localFrame,
}) async {
  await tester.pumpWidget(
    _buildPreview(
      source: source,
      placement: placement,
      backend: backend,
      localFrame: localFrame,
    ),
  );
}

Future<void> _runGeometryGate(
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
  expect(second.previousPresentationMode, first.presentationMode);
  expect(second.entryZoomFrames, 0);
  expect(second.entryWindowFrames, kStructuralWindowFrames);
  expect(second.contentStartFrame, kStructuralWindowFrames);

  final _OfflineBackend backend = _OfflineBackend();

  await _showLocalFrame(
    tester,
    source: source,
    placement: second,
    backend: backend,
    localFrame: 0,
  );
  await _waitForReady(tester);

  const List<int> openingFrames = <int>[
    0,
    kStructuralWindowFrames ~/ 2,
    kStructuralWindowFrames - 1,
  ];

  for (final int localFrame in openingFrames) {
    await _showLocalFrame(
      tester,
      source: source,
      placement: second,
      backend: backend,
      localFrame: localFrame,
    );
    _expectSameRect(
      _structuralRect(tester),
      _expectedRect(second, localFrame),
    );
  }

  await _showLocalFrame(
    tester,
    source: source,
    placement: second,
    backend: backend,
    localFrame: second.contentStartFrame,
  );
  _expectSameRect(
    _structuralRect(tester),
    _presentationRect(second.presentationMode),
  );
}

void main() {
  testWidgets(
    'seamless STRUCT shell morphs window to fullscreen over 12 frames',
    (WidgetTester tester) async {
      await _runGeometryGate(
        tester,
        firstFullscreen: false,
        secondFullscreen: true,
      );
    },
  );

  testWidgets(
    'seamless STRUCT shell morphs fullscreen to window over 12 frames',
    (WidgetTester tester) async {
      await _runGeometryGate(
        tester,
        firstFullscreen: true,
        secondFullscreen: false,
      );
    },
  );
}
