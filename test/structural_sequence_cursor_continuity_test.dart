// ./test/structural_sequence_cursor_continuity_test.dart

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
  DecodedMediaFrame render(
    int requestedSourceFrame,
    int width,
    int height,
  ) {
    final Uint8List rgba = Uint8List(width * height * 4);
    for (int i = 0; i < rgba.length; i += 4) {
      rgba[i] = 20;
      rgba[i + 1] = 80;
      rgba[i + 2] = 140;
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
[CLIP:base:video/base.mp4:0:0:20:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall]
''';

String _resolve(String source) => '/workspace/$source';

Widget _preview({
  required StructuralSequencePlacement placement,
  required _FakeBackend backend,
  required int localFrame,
  Size? terminalCursorFraction = const Size(0.01, 0.02),
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
        terminalCursorFraction: terminalCursorFraction,
        backend: backend,
        resolveSource: _resolve,
      ),
    ),
  );
}

Future<(Size, Size)> _measureCursorShrink(
  WidgetTester tester, {
  required StructuralSequencePlacement placement,
  required _FakeBackend backend,
  required Size? terminalCursorFraction,
}) async {
  final Finder cursor = find.byKey(
    const ValueKey<String>('structural-terminal-cursor'),
  );

  await tester.pumpWidget(
    _preview(
      placement: placement,
      backend: backend,
      localFrame: 0,
      terminalCursorFraction: terminalCursorFraction,
    ),
  );
  await tester.pump();
  final Size full = tester.getSize(cursor);

  await tester.pumpWidget(
    _preview(
      placement: placement,
      backend: backend,
      localFrame: kStructuralZoomFrames - 1,
      terminalCursorFraction: terminalCursorFraction,
    ),
  );
  await tester.pump();
  final Size shrunk = tester.getSize(cursor);

  return (full, shrunk);
}

void main() {
  testWidgets('structural terminal cursor keeps supplied aspect while terminal shrinks',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_source).single;
    final _FakeBackend backend = _FakeBackend();

    final (Size full, Size shrunk) = await _measureCursorShrink(
      tester,
      placement: placement,
      backend: backend,
      terminalCursorFraction: const Size(0.01, 0.02),
    );

    expect(full.width, closeTo(8.0, 0.01));
    expect(full.height, closeTo(9.0, 0.01));
    final double fullAspect = full.width / full.height;
    expect(shrunk.width, lessThan(full.width));
    expect(shrunk.height, lessThan(full.height));
    expect(shrunk.width / shrunk.height, closeTo(fullAspect, 0.01));
  });

  testWidgets('editor fallback cursor also keeps aspect while terminal shrinks',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_source).single;
    final _FakeBackend backend = _FakeBackend();

    final (Size full, Size shrunk) = await _measureCursorShrink(
      tester,
      placement: placement,
      backend: backend,
      terminalCursorFraction: null,
    );

    final double fullAspect = full.width / full.height;
    expect(full.width, greaterThan(0.0));
    expect(full.height, greaterThan(0.0));
    expect(shrunk.width, lessThan(full.width));
    expect(shrunk.height, lessThan(full.height));
    expect(shrunk.width / shrunk.height, closeTo(fullAspect, 0.01));
  });
}
