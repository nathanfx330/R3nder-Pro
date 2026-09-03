// ./test/edit_video_preview_test.dart

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_video_preview.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/ui_theme.dart';

class _FakeBackend implements MediaDecoderBackend {
  int openCount = 0;
  final List<_FakeDecoder> decoders = <_FakeDecoder>[];

  @override
  MediaDecoder open(String resolvedPath) {
    openCount++;
    final _FakeDecoder decoder = _FakeDecoder(resolvedPath);
    decoders.add(decoder);
    return decoder;
  }
}

class _FakeDecoder implements MediaDecoder {
  final String path;
  final List<int> requested = <int>[];
  bool disposed = false;

  _FakeDecoder(this.path);

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    requested.add(requestedSourceFrame);
    return DecodedMediaFrame(
      requestedSourceFrame: requestedSourceFrame,
      actualSourceFrame: requestedSourceFrame,
      width: 2,
      height: 2,
      stride: 8,
      rgba: Uint8List.fromList(<int>[
        255, 0, 0, 255,
        0, 255, 0, 255,
        0, 0, 255, 255,
        255, 255, 255, 255,
      ]),
    );
  }

  @override
  void dispose() {
    disposed = true;
  }
}

MediaFrame _frame(String trackId, String clipId, int sourceFrame) {
  return MediaFrame.decoded(
    trackId: trackId,
    clipId: clipId,
    source: '$clipId.mp4',
    decoded: DecodedMediaFrame(
      requestedSourceFrame: sourceFrame,
      actualSourceFrame: sourceFrame,
      width: 1,
      height: 1,
      stride: 4,
      rgba: Uint8List.fromList(<int>[255, 255, 255, 255]),
    ),
  );
}

void main() {
  test('visible edit frame selects highest numbered V track', () {
    final MediaFrame v1 = _frame('V1', 'base', 10);
    final MediaFrame v3 = _frame('V3', 'top', 10);
    final MediaFrame v2 = _frame('V2', 'middle', 10);

    expect(selectVisibleEditFrame(<MediaFrame>[v1, v3, v2]), same(v3));
  });

  testWidgets('scrubbing reuses persistent decoder and maps source frame',
      (WidgetTester tester) async {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:intro:video/intro.mp4:0:24:90:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final _FakeBackend backend = _FakeBackend();
    final String Function(String) resolver =
        (String value) => '/workspace/$value';

    Widget build(int frame) {
      return MaterialApp(
        home: SizedBox(
          width: 640,
          height: 360,
          child: EditVideoPreview(
            source: source,
            editId: 'main',
            currentFrame: frame,
            theme: R3Theme.of(Colors.green),
            backend: backend,
            resolveSource: resolver,
          ),
        ),
      );
    }

    await tester.pumpWidget(build(5));
    await tester.pumpAndSettle();

    expect(backend.openCount, 1);
    expect(backend.decoders.single.requested, contains(29));
    expect(find.textContaining('V1 / intro'), findsOneWidget);
    expect(find.textContaining('SRC 29'), findsOneWidget);

    await tester.pumpWidget(build(8));
    await tester.pumpAndSettle();

    expect(backend.openCount, 1);
    expect(backend.decoders.single.requested, containsAll(<int>[29, 32]));
    expect(find.textContaining('SRC 32'), findsOneWidget);
  });
}
