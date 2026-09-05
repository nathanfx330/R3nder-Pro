// ./test/structural_sequence_decode_timing_determinism_test.dart

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/structural_sequence.dart';
import 'package:r3nder/structural_sequence_preview.dart';
import 'package:r3nder/ui_theme.dart';

class _FakeBackend implements MediaDecoderBackend {
  int openCount = 0;

  @override
  MediaDecoder open(String resolvedPath) {
    openCount++;
    return _FakeDecoder();
  }
}

class _FakeDecoder implements MediaDecoder {
  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    final Uint8List rgba = Uint8List(width * height * 4);
    for (int i = 0; i < rgba.length; i += 4) {
      rgba[i] = 30;
      rgba[i + 1] = 90;
      rgba[i + 2] = 180;
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

Widget _preview({
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

Future<void> _waitForReady(WidgetTester tester) async {
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

Rect _windowRect(WidgetTester tester) => tester.getRect(
      find.byKey(const ValueKey<String>('structural-window-frame')),
    );

double _windowOpacity(WidgetTester tester) => tester
    .widget<Opacity>(
      find.byKey(const ValueKey<String>('structural-window-opacity')),
    )
    .opacity;

void _expectSameRect(Rect a, Rect b) {
  expect(a.left, closeTo(b.left, 0.01));
  expect(a.top, closeTo(b.top, 0.01));
  expect(a.width, closeTo(b.width, 0.01));
  expect(a.height, closeTo(b.height, 0.01));
}

void main() {
  testWidgets(
      'same STRUCT frame has same geometry regardless of decode completion time',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_source).single;
    final int openingFrame =
        kStructuralZoomFrames + (kStructuralWindowFrames ~/ 2);

    expect(
      placement.stageAt(openingFrame),
      StructuralSequenceStage.opening,
    );

    // Fast path: picture becomes ready during zoom-out, well before opening.
    final _FakeBackend earlyBackend = _FakeBackend();
    await tester.pumpWidget(
      _preview(
        placement: placement,
        backend: earlyBackend,
        localFrame: 5,
      ),
    );
    await _waitForReady(tester);
    await tester.pumpWidget(
      _preview(
        placement: placement,
        backend: earlyBackend,
        localFrame: openingFrame,
      ),
    );
    await tester.pumpAndSettle();

    final Rect earlyRect = _windowRect(tester);
    final double earlyOpacity = _windowOpacity(tester);
    expect(earlyBackend.openCount, 1);

    // Destroy the first preview so the second path has no inherited readiness.
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();

    // Late path: first mount occurs at the same opening frame. Readiness is
    // therefore reported at that frame. Once it is resident, the visible
    // state must jump to the authored geometry for openingFrame, not start a
    // new curve from the I/O completion moment.
    final _FakeBackend lateBackend = _FakeBackend();
    await tester.pumpWidget(
      _preview(
        placement: placement,
        backend: lateBackend,
        localFrame: openingFrame,
      ),
    );
    await _waitForReady(tester);

    final Rect lateRect = _windowRect(tester);
    final double lateOpacity = _windowOpacity(tester);
    expect(lateBackend.openCount, 1);

    _expectSameRect(earlyRect, lateRect);
    expect(lateOpacity, closeTo(earlyOpacity, 0.0001));
  });
}
