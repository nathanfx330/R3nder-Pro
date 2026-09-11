// ./test/structural_sequence_playing_preload_test.dart

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/structural_sequence.dart';
import 'package:r3nder/structural_sequence_preview.dart';
import 'package:r3nder/ui_theme.dart';

class _StarvingBackend implements MediaDecoderBackend {
  final _StarvingDecoder decoder = _StarvingDecoder();

  @override
  MediaDecoder open(String resolvedPath) => decoder;
}

class _StarvingDecoder implements NonBlockingMediaDecoder {
  int renderCalls = 0;
  int requestCalls = 0;
  int pollCalls = 0;
  final List<String> operations = <String>[];

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    renderCalls++;
    operations.add('render');
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
  void request(int requestedSourceFrame, int width, int height) {
    requestCalls++;
    operations.add('request');
  }

  @override
  DecodedMediaFrame? poll(
    int requestedSourceFrame,
    int width,
    int height,
  ) {
    pollCalls++;
    operations.add('poll');
    return null;
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
[STRUCT:MOSAIC.wall:AUDIO]
''';

String _resolve(String value) => '/workspace/$value';

void main() {
  testWidgets(
      'moving STRUCT entry uses exact preload until first frame is resident',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_source).single;
    final _StarvingBackend backend = _StarvingBackend();

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 800,
          height: 500,
          child: StructuralSequencePreview(
            rawDocument: _source,
            placement: placement,
            localFrame: 5,
            isPlaying: true,
            theme: R3Theme.of(Colors.green),
            wallpaper: null,
            backend: backend,
            resolveSource: _resolve,
          ),
        ),
      ),
    );
    await tester.pump();

    final Finder ready = find.byKey(
      const ValueKey<String>('structural-first-frame-ready'),
    );
    for (int attempt = 0; attempt < 50 && ready.evaluate().isEmpty; attempt++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pump();
    }

    expect(placement.stageAt(5), StructuralSequenceStage.zoomOut);
    expect(backend.decoder.renderCalls, greaterThan(0));
    expect(backend.decoder.operations, isNotEmpty);
    expect(
      backend.decoder.operations.first,
      'render',
      reason: 'The first invisible preload must use the exact parked path. '
          'Once readiness is reported, later moving requests are expected.',
    );
    expect(ready, findsOneWidget);
  });
}
