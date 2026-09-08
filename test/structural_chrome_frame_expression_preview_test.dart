// ./test/structural_chrome_frame_expression_preview_test.dart

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/structural_sequence.dart';
import 'package:r3nder/structural_sequence_preview.dart';
import 'package:r3nder/ui_theme.dart';

class _FakeBackend implements MediaDecoderBackend {
  @override
  MediaDecoder open(String resolvedPath) => _FakeDecoder();
}

class _FakeDecoder implements MediaDecoder {
  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    final Uint8List rgba = Uint8List(width * height * 4);
    for (int i = 0; i < rgba.length; i += 4) {
      rgba[i] = 30;
      rgba[i + 1] = 90;
      rgba[i + 2] = 170;
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
[CLIP:clip:video/file.mp4:0:10:20:1]
[/CLIP]
[/TRACK]
[/EDIT]
[STRUCT:EDIT.main:OVERLAY=CUSTOM:TITLE="Monitor [frame]":TOP="F[frame]":BOTTOM="SRC [frame]"]
''';

String _resolve(String value) => '/workspace/$value';

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
        resolveSource: _resolve,
      ),
    ),
  );
}

Future<void> _waitUntilReady(WidgetTester tester) async {
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
}

void main() {
  testWidgets('STRUCT [frame] expressions follow live source frame',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_source).single;
    final _FakeBackend backend = _FakeBackend();

    // Mount during the predecode phase so the same preview State survives into
    // showing, exactly like production STRUCT playback.
    await tester.pumpWidget(
      _preview(
        placement: placement,
        backend: backend,
        localFrame: 5,
      ),
    );
    await tester.pumpAndSettle();
    await _waitUntilReady(tester);

    final int frame2 = kStructuralEntryFrames + 2;
    expect(placement.stageAt(frame2), StructuralSequenceStage.showing);
    expect(placement.sourceFrameAt(frame2), 2);

    await tester.pumpWidget(
      _preview(
        placement: placement,
        backend: backend,
        localFrame: frame2,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Monitor 2'), findsOneWidget);
    expect(find.text('F2'), findsOneWidget);
    expect(find.text('SRC 2'), findsOneWidget);
    expect(find.textContaining('[frame]'), findsNothing);

    final int frame3 = kStructuralEntryFrames + 3;
    expect(placement.sourceFrameAt(frame3), 3);

    await tester.pumpWidget(
      _preview(
        placement: placement,
        backend: backend,
        localFrame: frame3,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Monitor 3'), findsOneWidget);
    expect(find.text('F3'), findsOneWidget);
    expect(find.text('SRC 3'), findsOneWidget);
    expect(find.text('Monitor 2'), findsNothing);
    expect(find.text('F2'), findsNothing);
    expect(find.text('SRC 2'), findsNothing);
  });
}
