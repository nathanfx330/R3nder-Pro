// ./test/edit_video_preview_texture_readiness_test.dart

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_video_preview.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/ui_theme.dart';

class _TextureBackend implements MediaDecoderBackend {
  final _TextureDecoder decoder = _TextureDecoder();

  @override
  MediaDecoder open(String resolvedPath) => decoder;
}

class _TextureDecoder implements TextureMediaDecoder {
  int renderCalls = 0;
  int textureCalls = 0;

  @override
  int get textureId => 77;

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    renderCalls++;
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
  void request(int requestedSourceFrame, int width, int height) {}

  @override
  DecodedMediaFrame? poll(
    int requestedSourceFrame,
    int width,
    int height,
  ) => null;

  @override
  void presentTexture(int requestedSourceFrame, int width, int height) {
    textureCalls++;
  }

  @override
  void dispose() {}
}

const String _source = '''[EDIT:main]
[TRACK:V1]
[CLIP:base:video/base.mp4:0:0:30:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';

void main() {
  testWidgets('parked first frame resolves before native texture handoff',
      (WidgetTester tester) async {
    final _TextureBackend backend = _TextureBackend();
    int readyCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 640,
          height: 360,
          child: EditVideoPreview(
            source: _source,
            editId: 'main',
            currentFrame: 0,
            isPlaying: false,
            fastPreview: false,
            theme: R3Theme.of(Colors.green),
            backend: backend,
            resolveSource: (String value) => '/workspace/$value',
            onFirstFrameReady: () => readyCalls++,
          ),
        ),
      ),
    );

    for (int attempt = 0; attempt < 50 && readyCalls == 0; attempt++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pump();
    }

    expect(backend.decoder.renderCalls, greaterThan(0));
    expect(
      backend.decoder.textureCalls,
      0,
      reason: 'A texture handle is not proof that parked client pixels exist.',
    );
    expect(readyCalls, 1);
    expect(find.textContaining('TEXTURE'), findsNothing);
  });
}
