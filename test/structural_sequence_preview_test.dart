// ./test/structural_sequence_preview_test.dart

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/structural_sequence.dart';
import 'package:r3nder/structural_sequence_preview.dart';
import 'package:r3nder/ui_theme.dart';

class _FakeBackend implements MediaDecoderBackend {
  int openCount = 0;
  final List<int> requestedFrames = <int>[];

  @override
  MediaDecoder open(String resolvedPath) {
    openCount++;
    return _FakeDecoder(requestedFrames);
  }
}

class _FakeDecoder implements MediaDecoder {
  final List<int> requestedFrames;

  _FakeDecoder(this.requestedFrames);

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    requestedFrames.add(requestedSourceFrame);
    final Uint8List rgba = Uint8List(width * height * 4);
    for (int i = 0; i < rgba.length; i += 4) {
      rgba[i] = 40;
      rgba[i + 1] = 120;
      rgba[i + 2] = 220;
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

const String _source = '''[MOSAIC:wall]
[PANE:pane1]
[CLIP:base:video/base.mp4:0:10:20:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall]
''';

String _resolveTestSource(String value) => '/workspace/$value';

Widget _buildPreview({
  required StructuralSequencePlacement placement,
  required _FakeBackend backend,
  required int localFrame,
}) {
  return MaterialApp(
    home: SizedBox(
      width: 800,
      height: 500,
      child: StructuralSequencePreview(
        rawDocument: _source,
        placement: placement,
        localFrame: localFrame,
        isPlaying: false,
        theme: R3Theme.of(Colors.green),
        wallpaper: null,
        backend: backend,
        resolveSource: _resolveTestSource,
      ),
    ),
  );
}

Future<void> _preloadFirstFrame(
  WidgetTester tester,
  StructuralSequencePlacement placement,
  _FakeBackend backend,
) async {
  await tester.pumpWidget(
    _buildPreview(
      placement: placement,
      backend: backend,
      localFrame: 5,
    ),
  );
  await tester.pumpAndSettle();

  expect(placement.stageAt(5), StructuralSequenceStage.zoomOut);
  expect(backend.openCount, 1);
  expect(backend.requestedFrames, contains(10));

  // ui.decodeImageFromPixels completes on the engine async loop rather than
  // Flutter's scheduled-frame queue. pumpAndSettle() can therefore return
  // while the RGBA -> ui.Image conversion is still in flight. Yield to that
  // loop, then pump the setState triggered by onFirstFrameReady. Stop as soon
  // as the same readiness marker used by the product appears.
  final Finder ready = find.byKey(
    const ValueKey<String>('structural-first-frame-ready'),
  );
  for (int attempt = 0; attempt < 50 && ready.evaluate().isEmpty; attempt++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump();
  }

  expect(ready, findsOneWidget);
  await tester.pumpAndSettle();
}

void _expectSameRect(Rect a, Rect b) {
  expect(a.left, closeTo(b.left, 0.01));
  expect(a.top, closeTo(b.top, 0.01));
  expect(a.width, closeTo(b.width, 0.01));
  expect(a.height, closeTo(b.height, 0.01));
}

void main() {
  testWidgets('zoom-out preloads first frame before structural window is visible',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_source).single;
    final _FakeBackend backend = _FakeBackend();

    await _preloadFirstFrame(tester, placement, backend);

    expect(find.text('R3nder : Terminal Engine'), findsOneWidget);

    final Opacity hiddenStructural = tester.widget<Opacity>(
      find.byKey(const ValueKey<String>('structural-window-opacity')),
    );
    expect(hiddenStructural.opacity, 0.0);

    // Enter opening with the same mounted EditVideoPreview and the same
    // resolver function identity. The backend must not reopen; the frame
    // decoded invisibly during zoom-out is the frame revealed by emergence.
    await tester.pumpWidget(
      _buildPreview(
        placement: placement,
        backend: backend,
        localFrame: kStructuralZoomFrames + 1,
      ),
    );
    await tester.pumpAndSettle();

    expect(backend.openCount, 1);
    expect(find.text('F0 / 20'), findsOneWidget);
    expect(find.textContaining('SRC 10'), findsOneWidget);
    expect(backend.requestedFrames.every((int frame) => frame == 10), isTrue);
  });

  testWidgets('terminal zoom lands directly on final video-panel geometry',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_source).single;
    final _FakeBackend backend = _FakeBackend();

    await tester.pumpWidget(
      _buildPreview(
        placement: placement,
        backend: backend,
        localFrame: kStructuralZoomFrames - 1,
      ),
    );
    await tester.pumpAndSettle();

    final Rect zoomTarget = tester.getRect(
      find.byKey(const ValueKey<String>('structural-terminal-window')),
    );

    await tester.pumpWidget(
      _buildPreview(
        placement: placement,
        backend: backend,
        localFrame: kStructuralZoomFrames,
      ),
    );
    await tester.pumpAndSettle();

    final Rect openingTerminal = tester.getRect(
      find.byKey(const ValueKey<String>('structural-terminal-window')),
    );
    _expectSameRect(zoomTarget, openingTerminal);
    expect(backend.openCount, 1);
    expect(backend.requestedFrames, contains(10));
  });

  testWidgets('opening holds first structural video frame while window comes forward',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_source).single;
    final _FakeBackend backend = _FakeBackend();

    await _preloadFirstFrame(tester, placement, backend);

    await tester.pumpWidget(
      _buildPreview(
        placement: placement,
        backend: backend,
        localFrame: kStructuralZoomFrames + 1,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      placement.stageAt(kStructuralZoomFrames + 1),
      StructuralSequenceStage.opening,
    );
    expect(find.text('F0 / 20'), findsOneWidget);
    expect(find.textContaining('SRC 10'), findsOneWidget);
    expect(backend.requestedFrames, isNotEmpty);
    expect(backend.requestedFrames.every((int frame) => frame == 10), isTrue);

    await tester.pumpWidget(
      _buildPreview(
        placement: placement,
        backend: backend,
        localFrame: kStructuralEntryFrames - 1,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('F0 / 20'), findsOneWidget);
    expect(find.textContaining('SRC 10'), findsOneWidget);
    expect(backend.requestedFrames.every((int frame) => frame == 10), isTrue);
  });

  testWidgets('structural window comes forward while terminal fades behind it',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_source).single;
    final _FakeBackend backend = _FakeBackend();

    await _preloadFirstFrame(tester, placement, backend);

    await tester.pumpWidget(
      _buildPreview(
        placement: placement,
        backend: backend,
        localFrame: kStructuralZoomFrames,
      ),
    );
    await tester.pumpAndSettle();

    final Rect rear = tester.getRect(
      find.byKey(const ValueKey<String>('structural-terminal-window')),
    );
    final Rect emergenceStart = tester.getRect(
      find.byKey(const ValueKey<String>('structural-window-frame')),
    );
    final Opacity terminalStart = tester.widget<Opacity>(
      find.byKey(const ValueKey<String>('structural-terminal-opacity')),
    );

    expect(emergenceStart.width, lessThan(rear.width));
    expect(emergenceStart.height, lessThan(rear.height));
    expect(emergenceStart.top, greaterThan(rear.top));
    expect(terminalStart.opacity, closeTo(1.0, 0.001));
    expect(backend.requestedFrames, contains(10));

    final int middleFrame =
        kStructuralZoomFrames + (kStructuralWindowFrames ~/ 2);
    await tester.pumpWidget(
      _buildPreview(
        placement: placement,
        backend: backend,
        localFrame: middleFrame,
      ),
    );
    await tester.pumpAndSettle();

    final Rect emergenceMiddle = tester.getRect(
      find.byKey(const ValueKey<String>('structural-window-frame')),
    );
    final Opacity terminalMiddle = tester.widget<Opacity>(
      find.byKey(const ValueKey<String>('structural-terminal-opacity')),
    );

    expect(emergenceMiddle.width, greaterThan(emergenceStart.width));
    expect(emergenceMiddle.height, greaterThan(emergenceStart.height));
    expect(emergenceMiddle.top, lessThan(emergenceStart.top));
    expect(terminalMiddle.opacity, greaterThan(0.0));
    expect(terminalMiddle.opacity, lessThan(1.0));
    expect(backend.requestedFrames.every((int frame) => frame == 10), isTrue);

    await tester.pumpWidget(
      _buildPreview(
        placement: placement,
        backend: backend,
        localFrame: kStructuralEntryFrames - 1,
      ),
    );
    await tester.pumpAndSettle();

    final Rect emergenceEnd = tester.getRect(
      find.byKey(const ValueKey<String>('structural-window-frame')),
    );
    _expectSameRect(emergenceEnd, rear);
    expect(
      find.byKey(const ValueKey<String>('structural-terminal-window')),
      findsNothing,
    );

    await tester.pumpWidget(
      _buildPreview(
        placement: placement,
        backend: backend,
        localFrame: kStructuralEntryFrames,
      ),
    );
    await tester.pumpAndSettle();

    final Rect showingStart = tester.getRect(
      find.byKey(const ValueKey<String>('structural-window-frame')),
    );
    _expectSameRect(emergenceEnd, showingStart);
  });

  testWidgets('showing stage renders MOSAIC at source-local frame in 16:9 client',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_source).single;
    final _FakeBackend backend = _FakeBackend();

    await _preloadFirstFrame(tester, placement, backend);

    await tester.pumpWidget(
      _buildPreview(
        placement: placement,
        backend: backend,
        localFrame: kStructuralEntryFrames + 5,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('MOSAIC.wall'), findsOneWidget);
    expect(find.text('F5 / 20'), findsOneWidget);
    expect(backend.openCount, 1);
    expect(backend.requestedFrames, contains(15));
    expect(find.textContaining('SRC 15'), findsOneWidget);

    final Size client = tester.getSize(
      find.byKey(const ValueKey<String>('sequence-preview:MOSAIC.wall')),
    );
    expect(client.width / client.height, closeTo(16.0 / 9.0, 0.01));
  });
}
