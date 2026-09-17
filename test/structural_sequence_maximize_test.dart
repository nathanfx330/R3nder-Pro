// ./test/structural_sequence_maximize_test.dart

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
  _FakeDecoder(this.requestedFrames);

  final List<int> requestedFrames;

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

const String _source = '''[EDIT:main]
[TRACK:V1]
[CLIP:base:video/base.mp4:0:0:100:1]
[CUE:0]
  [MAXIMIZE:10]
[/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
[STRUCT:EDIT.main]
''';

String _resolve(String value) => '/workspace/$value';

Widget _preview(
  StructuralSequencePlacement placement,
  _FakeBackend backend,
  int localFrame,
) {
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
        resolveSource: _resolve,
      ),
    ),
  );
}

Future<void> _waitReady(WidgetTester tester) async {
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

void _expectSameRect(Rect actual, Rect expected) {
  expect(actual.left, closeTo(expected.left, 0.01));
  expect(actual.top, closeTo(expected.top, 0.01));
  expect(actual.width, closeTo(expected.width, 0.01));
  expect(actual.height, closeTo(expected.height, 0.01));
}

void main() {
  testWidgets('source-frame-zero MAXIMIZE waits for STRUCT showing stage',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_source).single;
    final _FakeBackend backend = _FakeBackend();

    await tester.pumpWidget(_preview(placement, backend, 5));
    await tester.pumpAndSettle();
    await _waitReady(tester);

    final int openingFrame = kStructuralZoomFrames + 1;
    expect(
      placement.stageAt(openingFrame),
      StructuralSequenceStage.opening,
    );
    await tester.pumpWidget(_preview(placement, backend, openingFrame));
    await tester.pumpAndSettle();

    final Rect openingRect = tester.getRect(
      find.byKey(const ValueKey<String>('structural-window-positioned')),
    );
    expect(openingRect.width, lessThan(800));
    expect(backend.openCount, 1);

    // At source frame 12 the MAXIMIZE cue has completed its 12-frame enter and
    // is on its first exact fullscreen hold frame.
    final int fullscreenFrame = placement.contentStartFrame + 12;
    expect(
      placement.stageAt(fullscreenFrame),
      StructuralSequenceStage.showing,
    );
    await tester.pumpWidget(_preview(placement, backend, fullscreenFrame));
    await tester.pumpAndSettle();

    final Rect fullscreenRect = tester.getRect(
      find.byKey(const ValueKey<String>('structural-window-positioned')),
    );

    // FULL means the fitted 16:9 program frame, not the outer test surface.
    // MaterialApp expands its home to the test view (800x600 by default), so
    // hard-coding the child SizedBox's requested 500px height incorrectly
    // expects y=25. The actual fitted program frame is y=75 in that harness.
    final Rect programRect = tester.getRect(
      find.byKey(const ValueKey<String>('structural-desktop-layer')),
    );
    _expectSameRect(fullscreenRect, programRect);

    // Shell movement never replaces the live decoder.
    expect(backend.openCount, 1);
    expect(backend.requestedFrames, contains(12));
  });
}
