// ./test/structural_split_card_preview_test.dart

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/structural_sequence.dart';
import 'package:r3nder/structural_sequence_preview.dart';
import 'package:r3nder/structural_split_window_painter.dart';
import 'package:r3nder/ui_theme.dart';

class _PaneBackend implements MediaDecoderBackend {
  @override
  MediaDecoder open(String resolvedPath) {
    return _SolidDecoder(
      resolvedPath.endsWith('right.mp4')
          ? const <int>[0, 0, 255, 255]
          : const <int>[255, 0, 0, 255],
    );
  }
}

class _SolidDecoder implements MediaDecoder {
  const _SolidDecoder(this.color);

  final List<int> color;

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    final Uint8List rgba = Uint8List(width * height * 4);
    for (int i = 0; i < rgba.length; i += 4) {
      rgba.setRange(i, i + 4, color);
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
[PANE:left]
[CLIP:leftShot:video/left.mp4:0:0:40:1]
[/CLIP]
[/PANE]
[PANE:right]
[CLIP:rightShot:video/right.mp4:0:0:40:1]
[CUE:0]
[CARD:missing-card.png:8:12,34,56:CARD]
CARD BODY
[/CARD]
[/CUE]
[CUE:0]
[SIDECARD:missing-side.png:8:210,30,40:SIDE]
SIDE BODY
[/SIDECARD]
[/CUE]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall:SPLIT:OVERLAY=NONE]
''';

Future<bool> _containsRgb(
  ui.Image image,
  int red,
  int green,
  int blue,
) async {
  final ByteData? bytes =
      await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (bytes == null) return false;
  final Uint8List rgba = bytes.buffer.asUint8List(
    bytes.offsetInBytes,
    bytes.lengthInBytes,
  );
  for (int i = 0; i < rgba.length; i += 4) {
    if (rgba[i] == red &&
        rgba[i + 1] == green &&
        rgba[i + 2] == blue &&
        rgba[i + 3] == 255) {
      return true;
    }
  }
  return false;
}

void main() {
  testWidgets(
    'split Preview paints CARD only in owning pane and suppresses SIDECARD shell',
    (WidgetTester tester) async {
      final StructuralSequencePlacement placement =
          parseStructuralSequencePlacements(_source).single;
      expect(placement.splitWindow, isTrue);

      const int sourceFrame = 16;
      final int localFrame = placement.contentStartFrame + sourceFrame;

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 640,
            height: 360,
            child: StructuralSequencePreview(
              rawDocument: _source,
              placement: placement,
              localFrame: localFrame,
              isPlaying: false,
              theme: R3Theme.of(Colors.green),
              wallpaper: null,
              backend: _PaneBackend(),
              resolveSource: (String value) => value,
            ),
          ),
        ),
      );

      final Finder ready = find.byKey(
        const ValueKey<String>('structural-first-frame-ready'),
      );
      for (int attempt = 0;
          attempt < 60 && ready.evaluate().isEmpty;
          attempt++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        });
        await tester.pump();
      }
      expect(ready, findsOneWidget);
      await tester.pump();

      expect(
        find.byKey(
          const ValueKey<String>('structural-sidecard-panel'),
        ),
        findsNothing,
      );

      final CustomPaint paint = tester.widget<CustomPaint>(
        find.byKey(
          const ValueKey<String>('structural-split-window-frame'),
        ),
      );
      final StructuralSplitWindowPainter painter =
          paint.painter! as StructuralSplitWindowPainter;
      expect(painter.images[0], isNotNull);
      expect(painter.images[1], isNotNull);

      final List<bool>? pixels = await tester.runAsync<List<bool>>(() async {
        return <bool>[
          await _containsRgb(painter.images[0]!, 12, 34, 56),
          await _containsRgb(painter.images[1]!, 12, 34, 56),
          await _containsRgb(painter.images[0]!, 210, 30, 40),
          await _containsRgb(painter.images[1]!, 210, 30, 40),
        ];
      });
      expect(pixels, isNotNull);

      expect(
        pixels![0],
        isFalse,
        reason: 'CARD from the right authored pane must not leak left.',
      );
      expect(
        pixels[1],
        isTrue,
        reason: 'CARD must paint inside the right split client.',
      );
      expect(
        pixels[2],
        isFalse,
        reason: 'SIDECARD is unsupported in SPLIT v1.',
      );
      expect(
        pixels[3],
        isFalse,
        reason: 'SIDECARD is unsupported in SPLIT v1.',
      );
    },
  );
}
