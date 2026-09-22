// ./test/structural_split_window_preview_test.dart

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/mosaic_split_geometry.dart';
import 'package:r3nder/structural_sequence.dart';
import 'package:r3nder/structural_split_window_painter.dart';
import 'package:r3nder/structural_split_window_preview.dart';
import 'package:r3nder/ui_theme.dart';

class _PaneColorBackend implements MediaDecoderBackend {
  final Map<String, int> opens = <String, int>{};

  @override
  MediaDecoder open(String resolvedPath) {
    opens[resolvedPath] = (opens[resolvedPath] ?? 0) + 1;
    return _SolidColorDecoder(
      resolvedPath == 'blue.mp4'
          ? const <int>[0, 0, 255, 255]
          : const <int>[255, 0, 0, 255],
    );
  }
}

class _RecordingSizeBackend implements MediaDecoderBackend {
  final List<Size> sizes = <Size>[];

  @override
  MediaDecoder open(String resolvedPath) =>
      _RecordingSizeDecoder(sizes);
}

class _RecordingSizeDecoder implements MediaDecoder {
  _RecordingSizeDecoder(this.sizes);

  final List<Size> sizes;

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    sizes.add(Size(width.toDouble(), height.toDouble()));
    final Uint8List rgba = Uint8List(width * height * 4);
    for (int i = 0; i < rgba.length; i += 4) {
      rgba[i] = 80;
      rgba[i + 1] = 160;
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

class _SolidColorDecoder implements MediaDecoder {
  _SolidColorDecoder(this.color);

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

void main() {
  testWidgets(
    'moving MAX split caps pane decode to EDIT fast-preview pixel budget',
    (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 720);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });

      const String source = '''[MOSAIC:wall]
[PANE:left]
[CLIP:red:red.mp4:0:0:6:1]
[/CLIP]
[/PANE]
[PANE:right]
[CLIP:blue:blue.mp4:0:0:6:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall:SPLIT:MAX:OVERLAY=NONE]
''';

      final StructuralSequencePlacement placement =
          parseStructuralSequencePlacements(source).single;
      final _RecordingSizeBackend backend = _RecordingSizeBackend();
      bool ready = false;

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 1280,
            height: 720,
            child: StructuralSplitWindowPreview(
              rawDocument: source,
              placement: placement,
              sourceFrame: 0,
              theme: R3Theme.of(Colors.green),
              fontFamily: 'monospace',
              chromeScale: 1.0,
              moving: true,
              backend: backend,
              resolveSource: (String value) => value,
              onFirstFrameReady: () => ready = true,
            ),
          ),
        ),
      );

      for (int attempt = 0; attempt < 50 && !ready; attempt++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        });
        await tester.pump();
      }

      expect(ready, isTrue);
      expect(backend.sizes, isNotEmpty);
      expect(
        backend.sizes.where((Size size) => size == const Size(480, 270)).length,
        greaterThanOrEqualTo(2),
      );

      final CustomPaint movingPaint = tester.widget<CustomPaint>(
        find.byKey(
          const ValueKey<String>('structural-split-window-frame'),
        ),
      );
      final StructuralSplitWindowPainter movingPainter =
          movingPaint.painter! as StructuralSplitWindowPainter;
      expect(
        movingPainter.geometry.clientSize,
        const Size(640, 360),
      );
      expect(movingPainter.images[0]!.width, 480);
      expect(movingPainter.images[0]!.height, 270);

      ready = false;
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 1280,
            height: 720,
            child: StructuralSplitWindowPreview(
              rawDocument: source,
              placement: placement,
              sourceFrame: 0,
              theme: R3Theme.of(Colors.green),
              fontFamily: 'monospace',
              chromeScale: 1.0,
              moving: false,
              backend: backend,
              resolveSource: (String value) => value,
              onFirstFrameReady: () => ready = true,
            ),
          ),
        ),
      );

      for (int attempt = 0; attempt < 50; attempt++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        });
        await tester.pump();
        final CustomPaint paint = tester.widget<CustomPaint>(
          find.byKey(
            const ValueKey<String>('structural-split-window-frame'),
          ),
        );
        final StructuralSplitWindowPainter painter =
            paint.painter! as StructuralSplitWindowPainter;
        if (painter.images[0]?.width == 640 &&
            painter.images[0]?.height == 360) {
          break;
        }
      }

      final CustomPaint parkedPaint = tester.widget<CustomPaint>(
        find.byKey(
          const ValueKey<String>('structural-split-window-frame'),
        ),
      );
      final StructuralSplitWindowPainter parkedPainter =
          parkedPaint.painter! as StructuralSplitWindowPainter;
      expect(parkedPainter.geometry.clientSize, const Size(640, 360));
      expect(parkedPainter.images[0]!.width, 640);
      expect(parkedPainter.images[0]!.height, 360);
      expect(
        backend.sizes.where((Size size) => size == const Size(640, 360)).length,
        greaterThanOrEqualTo(2),
      );
    },
  );

  testWidgets(
    'seated split Preview uses shared painter with both compositor pane images',
    (WidgetTester tester) async {
      const String source = '''[EDIT:left_source]
[TRACK:V1]
[CLIP:red:red.mp4:0:0:6:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:left]
[CLIP:nested:EDIT.left_source:0:0:6:1]
[/CLIP]
[/PANE]
[PANE:right]
[CLIP:blue:blue.mp4:0:0:6:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall:SPLIT:ASPECT=4X3:OVERLAY=NONE]
''';

      const double outputWidth = 640;
      const double outputHeight = 360;
      const double chromeScale = 1.0;
      const int sourceFrame = 2;

      final StructuralSequencePlacement placement =
          parseStructuralSequencePlacements(source).single;
      expect(placement.splitWindow, isTrue);

      final _PaneColorBackend backend = _PaneColorBackend();
      bool ready = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: outputWidth,
              height: outputHeight,
              child: StructuralSplitWindowPreview(
                rawDocument: source,
                placement: placement,
                sourceFrame: sourceFrame,
                theme: R3Theme.of(Colors.green),
                fontFamily: 'monospace',
                chromeScale: chromeScale,
                moving: false,
                backend: backend,
                resolveSource: (String value) => value,
                onFirstFrameReady: () {
                  ready = true;
                },
              ),
            ),
          ),
        ),
      );

      for (int attempt = 0; attempt < 50 && !ready; attempt++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        });
        await tester.pump();
      }

      expect(ready, isTrue);

      // onFirstFrameReady is emitted after setState() queues the painter
      // update. Pump once more so the CustomPaint below reflects the resident
      // pane images rather than the previous null-image painter instance.
      await tester.pump();

      expect(backend.opens['red.mp4'], 1);
      expect(backend.opens['blue.mp4'], 1);

      final CustomPaint paint = tester.widget<CustomPaint>(
        find.byKey(
          const ValueKey<String>('structural-split-window-frame'),
        ),
      );
      expect(paint.painter, isA<StructuralSplitWindowPainter>());

      final StructuralSplitWindowPainter painter =
          paint.painter! as StructuralSplitWindowPainter;
      final MosaicSplitWindowGeometry expected =
          mosaicSplitWindowGeometry(
        frame: const Rect.fromLTWH(
          0,
          0,
          outputWidth,
          outputHeight,
        ),
        aspect: placement.splitClientAspect,
        titleHeight: 38.0 * chromeScale,
      );

      expect(painter.geometry.clientSize, expected.clientSize);
      expect(painter.geometry.leftWindowRect, expected.leftWindowRect);
      expect(painter.geometry.rightWindowRect, expected.rightWindowRect);
      expect(painter.geometry.leftClientRect, expected.leftClientRect);
      expect(painter.geometry.rightClientRect, expected.rightClientRect);
      expect(painter.placement, same(placement));
      expect(painter.sourceFrame, sourceFrame);
      expect(painter.images, hasLength(2));
      expect(painter.images[0], isNotNull);
      expect(painter.images[1], isNotNull);
      expect(
        painter.images[0]!.width,
        expected.clientSize.width.round(),
      );
      expect(
        painter.images[0]!.height,
        expected.clientSize.height.round(),
      );
      expect(
        painter.images[1]!.width,
        expected.clientSize.width.round(),
      );
      expect(
        painter.images[1]!.height,
        expected.clientSize.height.round(),
      );
    },
  );

  testWidgets(
    'MAX split Preview fills horizontal halves without a tall 16X9 client',
    (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(640, 360);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });

      const String source = '''[MOSAIC:wall]
[PANE:left]
[CLIP:red:red.mp4:0:0:6:1]
[/CLIP]
[/PANE]
[PANE:right]
[CLIP:blue:blue.mp4:0:0:6:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall:SPLIT:MAX:OVERLAY=NONE]
''';

      const double outputWidth = 640;
      const double outputHeight = 360;
      final StructuralSequencePlacement placement =
          parseStructuralSequencePlacements(source).single;
      expect(placement.maximizeSplit, isTrue);
      expect(
        placement.splitClientAspect,
        MosaicSplitClientAspect.aspect16x9,
      );

      final _PaneColorBackend backend = _PaneColorBackend();
      bool ready = false;
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: outputWidth,
            height: outputHeight,
            child: StructuralSplitWindowPreview(
              rawDocument: source,
              placement: placement,
              sourceFrame: 2,
              theme: R3Theme.of(Colors.green),
              fontFamily: 'monospace',
              chromeScale: 1.0,
              moving: false,
              backend: backend,
              resolveSource: (String value) => value,
              onFirstFrameReady: () => ready = true,
            ),
          ),
        ),
      );

      for (int attempt = 0; attempt < 50 && !ready; attempt++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        });
        await tester.pump();
      }
      expect(ready, isTrue);
      await tester.pump();

      final CustomPaint paint = tester.widget<CustomPaint>(
        find.byKey(
          const ValueKey<String>('structural-split-window-frame'),
        ),
      );
      final StructuralSplitWindowPainter painter =
          paint.painter! as StructuralSplitWindowPainter;
      expect(painter.geometry.maximized, isTrue);
      expect(
        painter.geometry.leftWindowRect,
        const Rect.fromLTWH(0, 71, 320, 218),
      );
      expect(
        painter.geometry.rightWindowRect,
        const Rect.fromLTWH(320, 71, 320, 218),
      );
      expect(painter.geometry.gap, 0.0);
      expect(painter.geometry.edgeMargin, 0.0);
      expect(
        painter.geometry.clientSize,
        const Size(320, 180),
      );
      expect(
        painter.geometry.leftClientRect,
        const Rect.fromLTWH(0, 109, 320, 180),
      );
    },
  );
}
