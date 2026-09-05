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

void main() {
  testWidgets('TEXT structural window renders MOSAIC at placement-local frame',
      (WidgetTester tester) async {
    const String source = '''[MOSAIC:wall]
[PANE:pane1]
[CLIP:base:video/base.mp4:0:10:20:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall]
''';

    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(source).single;
    final _FakeBackend backend = _FakeBackend();

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 800,
          height: 500,
          child: StructuralSequencePreview(
            rawDocument: source,
            placement: placement,
            localFrame: 5,
            isPlaying: false,
            theme: R3Theme.of(Colors.green),
            wallpaper: null,
            backend: backend,
            resolveSource: (String value) => '/workspace/$value',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('MOSAIC.wall'), findsOneWidget);
    expect(find.text('F5 / 20'), findsOneWidget);
    expect(backend.openCount, 1);
    expect(backend.requestedFrames, contains(15));
    expect(find.textContaining('SRC 15'), findsOneWidget);
  });
}
