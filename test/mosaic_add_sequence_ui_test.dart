// ./test/mosaic_add_sequence_ui_test.dart

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/mosaic_surface.dart';
import 'package:r3nder/ui_theme.dart';

const String _source = '''[MOSAIC:wall]
[PANE:pane1]
[CLIP:a:video/a.mp4:0:0:30:1]
[/CLIP]
[/PANE]
[/MOSAIC]
''';

class _SolidBackend implements MediaDecoderBackend {
  @override
  MediaDecoder open(String resolvedPath) => _SolidDecoder();
}

class _SolidDecoder implements MediaDecoder {
  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    final Uint8List rgba = Uint8List(width * height * 4);
    for (int i = 3; i < rgba.length; i += 4) {
      rgba[i] = 255;
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
  testWidgets('MOSAIC can add itself directly to the TEXT sequence',
      (WidgetTester tester) async {
    String? changed;
    final R3Theme theme = R3Theme.of(const Color(0xFF00FF00));

    await tester.pumpWidget(
      MaterialApp(
        theme: theme.materialTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 1000,
            height: 700,
            child: MosaicSurface(
              source: _source,
              mosaicId: 'wall',
              currentFrame: 0,
              theme: theme,
              backend: _SolidBackend(),
              resolveSource: (String value) => value,
              onSourceChanged: (String value) => changed = value,
              onSeek: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder addSequence = find.byKey(
      const ValueKey<String>('mosaic-add-sequence'),
    );
    expect(addSequence, findsOneWidget);
    expect(find.text('ADD SEQUENCE'), findsOneWidget);

    await tester.tap(addSequence);
    await tester.pumpAndSettle();

    expect(changed, isNotNull);
    expect(changed, contains('[STRUCT:MOSAIC.wall]'));
  });
}
