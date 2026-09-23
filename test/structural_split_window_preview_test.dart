// ./test/structural_split_window_preview_test.dart

import 'dart:typed_data';
import 'dart:ui' as ui;

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

class _HoldRecordingBackend implements MediaDecoderBackend {
  final List<_HoldRecordingDecoder> decoders = <_HoldRecordingDecoder>[];

  @override
  MediaDecoder open(String resolvedPath) {
    final _HoldRecordingDecoder decoder = _HoldRecordingDecoder();
    decoders.add(decoder);
    return decoder;
  }
}

class _HoldRecordingDecoder implements NonBlockingMediaDecoder {
  final List<int> requested = <int>[];
  final List<int> polled = <int>[];
  final List<int> rendered = <int>[];

  DecodedMediaFrame _frame(int frame, int width, int height) {
    final Uint8List rgba = Uint8List(width * height * 4);
    final int value = (frame * 17).clamp(0, 255).toInt();
    for (int i = 0; i < rgba.length; i += 4) {
      rgba[i] = value;
      rgba[i + 1] = 80;
      rgba[i + 2] = 160;
      rgba[i + 3] = 255;
    }
    return DecodedMediaFrame(
      requestedSourceFrame: frame,
      actualSourceFrame: frame,
      width: width,
      height: height,
      stride: width * 4,
      rgba: rgba,
    );
  }

  @override
  void request(int requestedSourceFrame, int width, int height) {
    requested.add(requestedSourceFrame);
  }

  @override
  DecodedMediaFrame? poll(
    int requestedSourceFrame,
    int width,
    int height,
  ) {
    polled.add(requestedSourceFrame);
    return _frame(requestedSourceFrame, width, height);
  }

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    rendered.add(requestedSourceFrame);
    return _frame(requestedSourceFrame, width, height);
  }

  @override
  void dispose() {}
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
    'closing hold keeps the exact resident split pane rasters',
    (WidgetTester tester) async {
      const String source = '''[MOSAIC:wall]
[PANE:left]
[CLIP:red:red.mp4:0:0:12:1]
[/CLIP]
[/PANE]
[PANE:right]
[CLIP:blue:blue.mp4:0:0:12:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall:SPLIT:OVERLAY=NONE]
''';

      final StructuralSequencePlacement placement =
          parseStructuralSequencePlacements(source).single;
      final _HoldRecordingBackend backend = _HoldRecordingBackend();
      bool ready = false;

      Widget preview({
        required int sourceFrame,
        required bool holdRaster,
        double? exitProgress,
      }) {
        return MaterialApp(
          home: SizedBox(
            width: 1280,
            height: 720,
            child: StructuralSplitWindowPreview(
              rawDocument: source,
              placement: placement,
              sourceFrame: sourceFrame,
              theme: R3Theme.of(Colors.green),
              fontFamily: 'monospace',
              chromeScale: 1.0,
              moving: true,
              holdRaster: holdRaster,
              exitProgress: exitProgress,
              backend: backend,
              resolveSource: (String value) => value,
              onFirstFrameReady: () => ready = true,
            ),
          ),
        );
      }

      await tester.pumpWidget(
        preview(sourceFrame: 7, holdRaster: false),
      );
      for (int attempt = 0; attempt < 50 && !ready; attempt++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        });
        await tester.pump();
      }
      expect(ready, isTrue);
      await tester.pump();

      final CustomPaint beforePaint = tester.widget<CustomPaint>(
        find.byKey(
          const ValueKey<String>('structural-split-window-frame'),
        ),
      );
      final StructuralSplitWindowPainter before =
          beforePaint.painter! as StructuralSplitWindowPainter;
      expect(before.images[0], isNotNull);
      expect(before.images[1], isNotNull);
      final ui.Image leftHeld = before.images[0]!;
      final ui.Image rightHeld = before.images[1]!;

      final int requestCountBefore = backend.decoders
          .expand((_HoldRecordingDecoder d) => d.requested)
          .length;
      final int pollCountBefore = backend.decoders
          .expand((_HoldRecordingDecoder d) => d.polled)
          .length;
      final int renderCountBefore = backend.decoders
          .expand((_HoldRecordingDecoder d) => d.rendered)
          .length;

      await tester.pumpWidget(
        preview(
          sourceFrame: placement.sourceDurationFrames - 1,
          holdRaster: true,
          exitProgress: 0.5,
        ),
      );
      await tester.pump();
      await tester.pump();

      final CustomPaint heldPaint = tester.widget<CustomPaint>(
        find.byKey(
          const ValueKey<String>('structural-split-window-frame'),
        ),
      );
      final StructuralSplitWindowPainter held =
          heldPaint.painter! as StructuralSplitWindowPainter;

      expect(identical(held.images[0], leftHeld), isTrue);
      expect(identical(held.images[1], rightHeld), isTrue);
      expect(
        backend.decoders.expand((_HoldRecordingDecoder d) => d.requested).length,
        requestCountBefore,
      );
      expect(
        backend.decoders.expand((_HoldRecordingDecoder d) => d.polled).length,
        pollCountBefore,
      );
      expect(
        backend.decoders.expand((_HoldRecordingDecoder d) => d.rendered).length,
        renderCountBefore,
      );
      expect(
        backend.decoders
            .expand((_HoldRecordingDecoder d) => <int>[
                  ...d.requested,
                  ...d.polled,
                  ...d.rendered,
                ])
            .contains(placement.sourceDurationFrames - 1),
        isFalse,
      );
      expect(held.exitProgress, 0.5);
    },
  );

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

      // onFirstFrameReady is emitted after setState() queues the painter
      // update. Pump once more so the CustomPaint reflects the resident
      // moving pane images before asserting their raster size.
      await tester.pump();

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
