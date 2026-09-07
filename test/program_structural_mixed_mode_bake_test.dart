// ./test/program_structural_mixed_mode_bake_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/program_structural_export.dart';
import 'package:r3nder/structural_sequence.dart';
import 'package:r3nder/structural_sequence_preview.dart';
import 'package:r3nder/ui_theme.dart';

const double _testWidth = 800.0;
const double _testHeight = 450.0;
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
    // This gate compares PREVIEW geometry with BAKE's public normalized
    // geometry contract. It deliberately avoids source pixels and rasterization.
    throw MediaDecodeException('intentional bake-parity offline: $path');
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

Rect _previewRectNormalized(WidgetTester tester) {
  final Rect actual = tester.getRect(
    find.byKey(const ValueKey<String>('structural-window-frame')),
  );
  return Rect.fromLTRB(
    actual.left / _testWidth,
    actual.top / _testHeight,
    actual.right / _testWidth,
    actual.bottom / _testHeight,
  );
}

Rect _bakePresentationRect(StructuralPresentationMode mode) {
  return structuralProgramPresentationRectForOutput(
    mode: mode,
    outputWidth: _testWidth.toInt(),
    outputHeight: _testHeight.toInt(),
    titleHeight: _titleHeight,
  );
}

Rect _bakeExpectedRect(
  StructuralSequencePlacement placement,
  int localFrame,
) {
  final Rect target = _bakePresentationRect(placement.presentationMode);
  if (localFrame >= placement.contentStartFrame) return target;

  final StructuralPresentationMode previous =
      placement.previousPresentationMode!;
  final Rect start = _bakePresentationRect(previous);
  final double eased = Curves.easeInOutCubic.transform(
    placement.stageProgressAt(localFrame),
  );
  return Rect.lerp(start, target, eased)!;
}

void _expectSameRect(Rect actual, Rect expected) {
  expect(actual.left, closeTo(expected.left, 0.0001));
  expect(actual.top, closeTo(expected.top, 0.0001));
  expect(actual.right, closeTo(expected.right, 0.0001));
  expect(actual.bottom, closeTo(expected.bottom, 0.0001));
}

Future<void> _runParityGate(
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

  const List<int> frames = <int>[
    0,
    kStructuralWindowFrames ~/ 2,
    kStructuralWindowFrames - 1,
    kStructuralWindowFrames,
  ];

  for (final int localFrame in frames) {
    await _showLocalFrame(
      tester,
      source: source,
      placement: second,
      backend: backend,
      localFrame: localFrame,
    );

    _expectSameRect(
      _previewRectNormalized(tester),
      _bakeExpectedRect(second, localFrame),
    );
  }
}

void main() {
  testWidgets(
    'BAKE geometry matches PREVIEW window to fullscreen STRUCT morph',
    (WidgetTester tester) async {
      await _runParityGate(
        tester,
        firstFullscreen: false,
        secondFullscreen: true,
      );
    },
  );

  testWidgets(
    'BAKE geometry matches PREVIEW fullscreen to window STRUCT morph',
    (WidgetTester tester) async {
      await _runParityGate(
        tester,
        firstFullscreen: true,
        secondFullscreen: false,
      );
    },
  );
}
