// ./test/edit_maximize_preview_return_test.dart

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/card_overlay.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/edit_video_preview.dart';
import 'package:r3nder/maximize_presentation.dart';
import 'package:r3nder/media_layer.dart';
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
      rgba[i] = 36;
      rgba[i + 1] = 92;
      rgba[i + 2] = 166;
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
[CUE:10]
  [MAXIMIZE:4]
[/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
''';

Widget _preview(_FakeBackend backend, int frame) {
  return MaterialApp(
    home: SizedBox(
      width: 640,
      height: 360,
      child: EditVideoPreview(
        source: _source,
        editId: 'main',
        currentFrame: frame,
        theme: R3Theme.of(Colors.green),
        backend: backend,
        resolveSource: (String value) => '/workspace/$value',
      ),
    ),
  );
}

void main() {
  test('standalone MAXIMIZE shell geometry has a stable seated return', () {
    const Size size = Size(640, 360);
    final Rect seated = standaloneMaximizeBaseWindowRect(size);
    final before = standaloneMaximizeShellFrameAt(size: size, amount: 0.0);
    final fullscreen = standaloneMaximizeShellFrameAt(size: size, amount: 1.0);
    final after = standaloneMaximizeShellFrameAt(size: size, amount: 0.0);

    expect(before.structuralRect, seated);
    expect(after.structuralRect, seated);
    expect(before.windowChrome, 1.0);
    expect(after.windowChrome, 1.0);
    expect(fullscreen.structuralRect, Offset.zero & size);
    expect(fullscreen.windowChrome, 0.0);
  });

  test('direct EDIT source advertises persistent MAXIMIZE shell context', () {
    final EditDocumentModel model = EditDocumentModel.parse(_source);
    final StructuralSourceRef root = StructuralSourceRef.tryParse('EDIT.main')!;
    expect(structuralSourceHasMaximizeCues(model, root), isTrue);
  });

  testWidgets('EDIT preview keeps shell after MAXIMIZE lifetime ends',
      (WidgetTester tester) async {
    final _FakeBackend backend = _FakeBackend();
    const MaximizePresentationTiming timing =
        MaximizePresentationTiming(holdFrames: 4);

    await tester.pumpWidget(_preview(backend, 0));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('edit-standalone-maximize-shell')),
      findsOneWidget,
    );
    expect(backend.openCount, 1);

    // Trigger F10 + 12 transition frames = first exact fullscreen hold frame.
    await tester.pumpWidget(_preview(backend, 22));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('edit-standalone-maximize-shell')),
      findsOneWidget,
    );

    // One frame beyond the complete cue lifetime must still be the seated fake
    // EDIT window, not the raw full-frame client that looked stuck maximized.
    final int afterCue = 10 + timing.durationFrames;
    await tester.pumpWidget(_preview(backend, afterCue));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('edit-standalone-maximize-shell')),
      findsOneWidget,
    );
    expect(backend.openCount, 1);
    expect(backend.requestedFrames, containsAll(<int>[0, 22, afterCue]));
  });
}
