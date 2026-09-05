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
        resolveSource: (String value) => '/workspace/$value',
      ),
    ),
  );
}

void main() {
  testWidgets('zoom-out owns presentation time before source decoder opens',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_source).single;
    final _FakeBackend backend = _FakeBackend();

    await tester.pumpWidget(
      _buildPreview(
        placement: placement,
        backend: backend,
        localFrame: 5,
      ),
    );
    await tester.pumpAndSettle();

    expect(placement.stageAt(5), StructuralSequenceStage.zoomOut);
    expect(find.text('R3nder : Terminal Engine'), findsOneWidget);
    expect(find.text('MOSAIC.wall'), findsNothing);
    expect(backend.openCount, 0);
  });

  testWidgets('structural opening starts at parked terminal and ends at show rect',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_source).single;
    final _FakeBackend backend = _FakeBackend();

    await tester.pumpWidget(
      _buildPreview(
        placement: placement,
        backend: backend,
        localFrame: kStructuralZoomFrames,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      placement.stageAt(kStructuralZoomFrames),
      StructuralSequenceStage.opening,
    );

    final Rect parked = tester.getRect(
      find.byKey(const ValueKey<String>('structural-terminal-window')),
    );
    final Rect openingStart = tester.getRect(
      find.byKey(const ValueKey<String>('structural-window-frame')),
    );

    expect(openingStart.left, closeTo(parked.left, 0.01));
    expect(openingStart.top, closeTo(parked.top, 0.01));
    expect(openingStart.width, closeTo(parked.width, 0.01));
    expect(openingStart.height, closeTo(parked.height, 0.01));
    expect(backend.openCount, 0);

    await tester.pumpWidget(
      _buildPreview(
        placement: placement,
        backend: backend,
        localFrame: kStructuralEntryFrames - 1,
      ),
    );
    await tester.pumpAndSettle();

    final Rect openingEnd = tester.getRect(
      find.byKey(const ValueKey<String>('structural-window-frame')),
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

    expect(showingStart.left, closeTo(openingEnd.left, 0.01));
    expect(showingStart.top, closeTo(openingEnd.top, 0.01));
    expect(showingStart.width, closeTo(openingEnd.width, 0.01));
    expect(showingStart.height, closeTo(openingEnd.height, 0.01));
  });

  testWidgets('showing stage renders MOSAIC at source-local frame in 16:9 client',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_source).single;
    final _FakeBackend backend = _FakeBackend();

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
