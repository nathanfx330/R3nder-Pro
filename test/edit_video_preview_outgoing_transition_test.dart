// ./test/edit_video_preview_outgoing_transition_test.dart

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_video_preview.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/ui_theme.dart';

const String _source = '''[EDIT:main]
[TRACK:V1]
[CLIP:leaf:leaf.mp4:0:0:10:1]
[#EDIT_TRANSITION_OUT:CROSSFADE:4]
[/CLIP]
[/TRACK]
[/EDIT]
''';

class _TextureBackend implements MediaDecoderBackend {
  final _TextureDecoder decoder = _TextureDecoder();

  @override
  MediaDecoder open(String resolvedPath) => decoder;
}

class _TextureDecoder implements TextureMediaDecoder {
  int renderCalls = 0;
  int presentCalls = 0;
  int requestCalls = 0;
  int pollCalls = 0;

  @override
  int get textureId => 17;

  DecodedMediaFrame _frame(int requestedSourceFrame, int width, int height) {
    final Uint8List rgba = Uint8List(width * height * 4);
    for (int i = 0; i < rgba.length; i += 4) {
      rgba[i] = 120;
      rgba[i + 1] = 90;
      rgba[i + 2] = 60;
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
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    renderCalls++;
    return _frame(requestedSourceFrame, width, height);
  }

  @override
  void request(int requestedSourceFrame, int width, int height) {
    requestCalls++;
  }

  @override
  DecodedMediaFrame? poll(int requestedSourceFrame, int width, int height) {
    pollCalls++;
    return _frame(requestedSourceFrame, width, height);
  }

  @override
  void presentTexture(int requestedSourceFrame, int width, int height) {
    presentCalls++;
  }

  @override
  void dispose() {}
}

void main() {
  testWidgets('outgoing XFADE stays on compositor path instead of native texture',
      (WidgetTester tester) async {
    final _TextureBackend backend = _TextureBackend();

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 640,
          height: 360,
          child: EditVideoPreview(
            source: _source,
            structuralSource: 'EDIT.main',
            currentFrame: 8,
            theme: R3Theme.of(Colors.green),
            backend: backend,
            resolveSource: (String value) => value,
          ),
        ),
      ),
    );

    for (int i = 0; i < 20 && backend.decoder.renderCalls == 0; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(backend.decoder.renderCalls, greaterThan(0));
    expect(backend.decoder.presentCalls, 0);
  });
}
