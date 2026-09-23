// ./test/structural_sequence_preview_test.dart

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/structural_sequence.dart';
import 'package:r3nder/structural_sequence_preview.dart';
import 'package:r3nder/structural_split_window_preview.dart';
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
  final List<int> requestedFrames;

  _FakeDecoder(this.requestedFrames);

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    requestedFrames.add(requestedSourceFrame);
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
  void dispose() {}
}

class _RasterSensitivePreviewBackend implements MediaDecoderBackend {
  int openCount = 0;
  final List<_RasterSensitivePreviewDecoder> decoders =
      <_RasterSensitivePreviewDecoder>[];

  @override
  MediaDecoder open(String resolvedPath) {
    openCount++;
    final _RasterSensitivePreviewDecoder decoder =
        _RasterSensitivePreviewDecoder();
    decoders.add(decoder);
    return decoder;
  }
}

class _RasterSensitivePreviewDecoder implements NonBlockingMediaDecoder {
  int? width;
  int? height;
  int stableRequests = 0;

  @override
  void request(int requestedSourceFrame, int nextWidth, int nextHeight) {
    if (width != nextWidth || height != nextHeight) {
      width = nextWidth;
      height = nextHeight;
      stableRequests = 0;
    }
    stableRequests++;
  }

  @override
  DecodedMediaFrame? poll(
    int requestedSourceFrame,
    int nextWidth,
    int nextHeight,
  ) {
    if (width != nextWidth ||
        height != nextHeight ||
        stableRequests < 2) {
      return null;
    }
    final Uint8List rgba = Uint8List(nextWidth * nextHeight * 4);
    for (int i = 0; i < rgba.length; i += 4) {
      rgba[i] = 180;
      rgba[i + 1] = 90;
      rgba[i + 2] = 220;
      rgba[i + 3] = 255;
    }
    return DecodedMediaFrame(
      requestedSourceFrame: requestedSourceFrame,
      actualSourceFrame: requestedSourceFrame,
      width: nextWidth,
      height: nextHeight,
      stride: nextWidth * 4,
      rgba: rgba,
    );
  }

  @override
  DecodedMediaFrame render(
    int requestedSourceFrame,
    int nextWidth,
    int nextHeight,
  ) {
    final Uint8List rgba = Uint8List(nextWidth * nextHeight * 4);
    for (int i = 0; i < rgba.length; i += 4) {
      rgba[i] = 180;
      rgba[i + 1] = 90;
      rgba[i + 2] = 220;
      rgba[i + 3] = 255;
    }
    return DecodedMediaFrame(
      requestedSourceFrame: requestedSourceFrame,
      actualSourceFrame: requestedSourceFrame,
      width: nextWidth,
      height: nextHeight,
      stride: nextWidth * 4,
      rgba: rgba,
    );
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
[STRUCT:MOSAIC.wall]
''';

const String _sameNestedEditMosaicSource = '''[EDIT:test2s]
[TRACK:V1]
[CLIP:leaf:video/shared.mp4:0:0:329:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:mosaic]
[PANE:pane1]
[CLIP:edit_test2s:EDIT.test2s:0:0:329:1]
[/CLIP]
[/PANE]
[PANE:pane2]
[CLIP:edit_test2s:EDIT.test2s:0:0:329:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.mosaic:AUDIO]
''';

const String _splitCloseSource = '''[MOSAIC:wall]
[PANE:left]
[CLIP:left_clip:video/left.mp4:0:0:12:1]
[/CLIP]
[/PANE]
[PANE:right]
[CLIP:right_clip:video/right.mp4:0:0:12:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall:SPLIT:OVERLAY=NONE]
''';

const String _slideSource = '''[CONFIG:APPSWITCH:SLIDE]
[EDIT:a]
[TRACK:V1]
[CLIP:a:video/a.mp4:0:0:30:1]
[/CLIP]
[/TRACK]
[/EDIT]
[EDIT:b]
[TRACK:V1]
[CLIP:b:video/b.mp4:0:0:30:1]
[/CLIP]
[/TRACK]
[/EDIT]
[STRUCT:EDIT.a]
[STRUCT:EDIT.b]
''';

String _resolveTestSource(String value) => '/workspace/$value';

Widget _buildPreview({
  required StructuralSequencePlacement placement,
  required _FakeBackend backend,
  required int localFrame,
  String rawDocument = _source,
}) {
  return MaterialApp(
    home: SizedBox(
      width: 800,
      height: 500,
      child: StructuralSequencePreview(
        rawDocument: rawDocument,
        placement: placement,
        localFrame: localFrame,
        isPlaying: false,
        theme: R3Theme.of(Colors.green),
        wallpaper: null,
        backend: backend,
        resolveSource: _resolveTestSource,
      ),
    ),
  );
}

Future<void> _preloadFirstFrame(
  WidgetTester tester,
  StructuralSequencePlacement placement,
  _FakeBackend backend,
) async {
  await tester.pumpWidget(
    _buildPreview(
      placement: placement,
      backend: backend,
      localFrame: 5,
    ),
  );
  await tester.pumpAndSettle();

  expect(placement.stageAt(5), StructuralSequenceStage.zoomOut);
  expect(backend.openCount, 1);
  expect(backend.requestedFrames, contains(10));

  // ui.decodeImageFromPixels completes on the engine async loop rather than
  // Flutter's scheduled-frame queue. pumpAndSettle() can therefore return
  // while the RGBA -> ui.Image conversion is still in flight. Yield to that
  // loop, then pump the setState triggered by onFirstFrameReady. Stop as soon
  // as the same readiness marker used by the product appears.
  final Finder ready = find.byKey(
    const ValueKey<String>('structural-first-frame-ready'),
  );
  for (int attempt = 0; attempt < 50 && ready.evaluate().isEmpty; attempt++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump();
  }

  expect(ready, findsOneWidget);
  await tester.pumpAndSettle();
}

void _expectSameRect(Rect a, Rect b) {
  expect(a.left, closeTo(b.left, 0.01));
  expect(a.top, closeTo(b.top, 0.01));
  expect(a.width, closeTo(b.width, 0.01));
  expect(a.height, closeTo(b.height, 0.01));
}

void main() {
  testWidgets(
    'SPLIT closing mirrors entry while source stays on final frame',
    (WidgetTester tester) async {
      final StructuralSequencePlacement placement =
          parseStructuralSequencePlacements(_splitCloseSource).single;
      final _FakeBackend backend = _FakeBackend();
      final int showingFrame = placement.contentStartFrame + 2;

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 800,
            height: 500,
            child: StructuralSequencePreview(
              rawDocument: _splitCloseSource,
              placement: placement,
              localFrame: showingFrame,
              isPlaying: true,
              theme: R3Theme.of(Colors.green),
              wallpaper: null,
              backend: backend,
              resolveSource: _resolveTestSource,
            ),
          ),
        ),
      );

      final Finder ready = find.byKey(
        const ValueKey<String>('structural-first-frame-ready'),
      );
      for (int attempt = 0; attempt < 50 && ready.evaluate().isEmpty; attempt++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        });
        await tester.pump();
      }
      expect(ready, findsOneWidget);
      await tester.pump();

      StructuralSplitWindowPreview split =
          tester.widget<StructuralSplitWindowPreview>(
        find.byType(StructuralSplitWindowPreview),
      );
      expect(split.moving, isTrue);
      expect(split.sourceFrame, placement.sourceFrameAt(showingFrame));

      final int closingFrame =
          placement.closingStartFrame + (placement.exitWindowFrames ~/ 2);
      expect(
        placement.stageAt(closingFrame),
        StructuralSequenceStage.closing,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 800,
            height: 500,
            child: StructuralSequencePreview(
              rawDocument: _splitCloseSource,
              placement: placement,
              localFrame: closingFrame,
              isPlaying: true,
              theme: R3Theme.of(Colors.green),
              wallpaper: null,
              backend: backend,
              resolveSource: _resolveTestSource,
            ),
          ),
        ),
      );
      await tester.pump();

      split = tester.widget<StructuralSplitWindowPreview>(
        find.byType(StructuralSplitWindowPreview),
      );
      expect(split.sourceFrame, placement.sourceDurationFrames - 1);
      expect(split.moving, isTrue);
      expect(split.holdRaster, isFalse);
      expect(split.closeAsSurfaceTransform, isTrue);
      expect(split.exitProgress, isNull);
      expect(
        split.entryProgress,
        closeTo(1.0 - placement.stageProgressAt(closingFrame), 0.000001),
      );
    },
  );

  testWidgets(
    'windowed live MOSAIC resolves same nested EDIT at both legacy pane rasters',
    (WidgetTester tester) async {
      final StructuralSequencePlacement placement =
          parseStructuralSequencePlacements(
        _sameNestedEditMosaicSource,
      ).single;
      expect(placement.splitWindow, isFalse);

      final _RasterSensitivePreviewBackend backend =
          _RasterSensitivePreviewBackend();
      bool ready = false;
      final int openingFrame = kStructuralZoomFrames + 1;
      expect(
        placement.stageAt(openingFrame),
        StructuralSequenceStage.opening,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 800,
            height: 500,
            child: StructuralSequencePreview(
              rawDocument: _sameNestedEditMosaicSource,
              placement: placement,
              localFrame: openingFrame,
              isPlaying: true,
              theme: R3Theme.of(Colors.green),
              wallpaper: null,
              backend: backend,
              resolveSource: _resolveTestSource,
              onFirstFrameReady: () {
                ready = true;
              },
            ),
          ),
        ),
      );

      for (int attempt = 0; attempt < 60 && !ready; attempt++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        });
        await tester.pump();
      }

      expect(ready, isTrue);
      await tester.pump();

      expect(backend.openCount, 2);
      expect(
        backend.decoders
            .map((_RasterSensitivePreviewDecoder d) => d.width)
            .toSet(),
        hasLength(2),
      );
      expect(
        backend.decoders.every(
          (_RasterSensitivePreviewDecoder d) => d.stableRequests >= 2,
        ),
        isTrue,
      );
      expect(
        find.byKey(
          const ValueKey<String>('structural-first-frame-ready'),
        ),
        findsOneWidget,
      );

      final Opacity structural = tester.widget<Opacity>(
        find.byKey(const ValueKey<String>('structural-window-opacity')),
      );
      expect(structural.opacity, greaterThan(0.0));
    },
  );

  testWidgets('zoom-out preloads first frame before structural window is visible',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_source).single;
    final _FakeBackend backend = _FakeBackend();

    await _preloadFirstFrame(tester, placement, backend);

    expect(find.text('R3nder : Terminal Engine'), findsOneWidget);

    final Opacity hiddenStructural = tester.widget<Opacity>(
      find.byKey(const ValueKey<String>('structural-window-opacity')),
    );
    expect(hiddenStructural.opacity, 0.0);

    // Enter opening with the same mounted EditVideoPreview and the same
    // resolver function identity. The backend must not reopen; the frame
    // decoded invisibly during zoom-out is the frame revealed by emergence.
    await tester.pumpWidget(
      _buildPreview(
        placement: placement,
        backend: backend,
        localFrame: kStructuralZoomFrames + 1,
      ),
    );
    await tester.pumpAndSettle();

    expect(backend.openCount, 1);
    expect(find.text('F0 / 20'), findsOneWidget);
    expect(find.textContaining('SRC 10'), findsOneWidget);
    expect(backend.requestedFrames.every((int frame) => frame == 10), isTrue);
  });

  testWidgets('terminal zoom lands directly on final video-panel geometry',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_source).single;
    final _FakeBackend backend = _FakeBackend();

    await tester.pumpWidget(
      _buildPreview(
        placement: placement,
        backend: backend,
        localFrame: kStructuralZoomFrames - 1,
      ),
    );
    await tester.pumpAndSettle();

    final Rect zoomTarget = tester.getRect(
      find.byKey(const ValueKey<String>('structural-terminal-window')),
    );

    await tester.pumpWidget(
      _buildPreview(
        placement: placement,
        backend: backend,
        localFrame: kStructuralZoomFrames,
      ),
    );
    await tester.pumpAndSettle();

    final Rect openingTerminal = tester.getRect(
      find.byKey(const ValueKey<String>('structural-terminal-window')),
    );
    _expectSameRect(zoomTarget, openingTerminal);
    expect(backend.openCount, 1);
    expect(backend.requestedFrames, contains(10));
  });

  testWidgets('opening holds first structural video frame while window comes forward',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_source).single;
    final _FakeBackend backend = _FakeBackend();

    await _preloadFirstFrame(tester, placement, backend);

    await tester.pumpWidget(
      _buildPreview(
        placement: placement,
        backend: backend,
        localFrame: kStructuralZoomFrames + 1,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      placement.stageAt(kStructuralZoomFrames + 1),
      StructuralSequenceStage.opening,
    );
    expect(find.text('F0 / 20'), findsOneWidget);
    expect(find.textContaining('SRC 10'), findsOneWidget);
    expect(backend.requestedFrames, isNotEmpty);
    expect(backend.requestedFrames.every((int frame) => frame == 10), isTrue);

    await tester.pumpWidget(
      _buildPreview(
        placement: placement,
        backend: backend,
        localFrame: kStructuralEntryFrames - 1,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('F0 / 20'), findsOneWidget);
    expect(find.textContaining('SRC 10'), findsOneWidget);
    expect(backend.requestedFrames.every((int frame) => frame == 10), isTrue);
  });

  testWidgets('structural window comes forward while terminal fades behind it',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_source).single;
    final _FakeBackend backend = _FakeBackend();

    await _preloadFirstFrame(tester, placement, backend);

    await tester.pumpWidget(
      _buildPreview(
        placement: placement,
        backend: backend,
        localFrame: kStructuralZoomFrames,
      ),
    );
    await tester.pumpAndSettle();

    final Rect rear = tester.getRect(
      find.byKey(const ValueKey<String>('structural-terminal-window')),
    );
    final Rect emergenceStart = tester.getRect(
      find.byKey(const ValueKey<String>('structural-window-frame')),
    );
    final Opacity terminalStart = tester.widget<Opacity>(
      find.byKey(const ValueKey<String>('structural-terminal-opacity')),
    );

    expect(emergenceStart.width, lessThan(rear.width));
    expect(emergenceStart.height, lessThan(rear.height));
    expect(emergenceStart.top, greaterThan(rear.top));
    expect(terminalStart.opacity, closeTo(1.0, 0.001));
    expect(backend.requestedFrames, contains(10));

    final int middleFrame =
        kStructuralZoomFrames + (kStructuralWindowFrames ~/ 2);
    await tester.pumpWidget(
      _buildPreview(
        placement: placement,
        backend: backend,
        localFrame: middleFrame,
      ),
    );
    await tester.pumpAndSettle();

    final Rect emergenceMiddle = tester.getRect(
      find.byKey(const ValueKey<String>('structural-window-frame')),
    );
    final Opacity terminalMiddle = tester.widget<Opacity>(
      find.byKey(const ValueKey<String>('structural-terminal-opacity')),
    );

    expect(emergenceMiddle.width, greaterThan(emergenceStart.width));
    expect(emergenceMiddle.height, greaterThan(emergenceStart.height));
    expect(emergenceMiddle.top, lessThan(emergenceStart.top));
    expect(terminalMiddle.opacity, greaterThan(0.0));
    expect(terminalMiddle.opacity, lessThan(1.0));
    expect(backend.requestedFrames.every((int frame) => frame == 10), isTrue);

    await tester.pumpWidget(
      _buildPreview(
        placement: placement,
        backend: backend,
        localFrame: kStructuralEntryFrames - 1,
      ),
    );
    await tester.pumpAndSettle();

    final Rect emergenceEnd = tester.getRect(
      find.byKey(const ValueKey<String>('structural-window-frame')),
    );
    _expectSameRect(emergenceEnd, rear);
    expect(
      find.byKey(const ValueKey<String>('structural-terminal-window')),
      findsNothing,
    );

    await tester.pumpWidget(
      _buildPreview(
        placement: placement,
        backend: backend,
        localFrame: kStructuralEntryFrames,
      ),
    );
    await tester.pumpAndSettle();

    final Rect showingStart = tester.getRect(
      find.byKey(const ValueKey<String>('structural-window-frame')),
    );
    _expectSameRect(emergenceEnd, showingStart);
  });

  testWidgets('showing stage renders MOSAIC at source-local frame in 16:9 client',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_source).single;
    final _FakeBackend backend = _FakeBackend();

    await _preloadFirstFrame(tester, placement, backend);

    await tester.pumpWidget(
      _buildPreview(
        placement: placement,
        backend: backend,
        localFrame: kStructuralEntryFrames + 5,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('MOSAIC.wall'), findsOneWidget);
    expect(find.text('F5 / 20'), findsOneWidget);
    expect(backend.openCount, 1);
    expect(backend.requestedFrames, contains(15));
    expect(find.textContaining('SRC 15'), findsOneWidget);

    final Size client = tester.getSize(
      find.byKey(const ValueKey<String>('sequence-preview:MOSAIC.wall')),
    );
    expect(client.width / client.height, closeTo(16.0 / 9.0, 0.01));
  });

  testWidgets('terminal title bar collapses into fullscreen during structural return',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_source).single;
    final _FakeBackend backend = _FakeBackend();
    final int zoomInStart = placement.contentEndFrameExclusive +
        kStructuralWindowFrames;

    await tester.pumpWidget(
      _buildPreview(
        placement: placement,
        backend: backend,
        localFrame: zoomInStart,
      ),
    );
    await tester.pumpAndSettle();

    expect(placement.stageAt(zoomInStart), StructuralSequenceStage.zoomIn);
    final Rect terminalStart = tester.getRect(
      find.byKey(const ValueKey<String>('structural-terminal-window')),
    );
    final double barStart = tester.getSize(
      find.byKey(const ValueKey<String>('structural-terminal-title-bar')),
    ).height;
    expect(barStart, closeTo(38.0, 0.01));

    final int zoomInMiddle = zoomInStart + (kStructuralZoomFrames ~/ 2);
    await tester.pumpWidget(
      _buildPreview(
        placement: placement,
        backend: backend,
        localFrame: zoomInMiddle,
      ),
    );
    await tester.pumpAndSettle();

    final Rect terminalMiddle = tester.getRect(
      find.byKey(const ValueKey<String>('structural-terminal-window')),
    );
    final double barMiddle = tester.getSize(
      find.byKey(const ValueKey<String>('structural-terminal-title-bar')),
    ).height;
    expect(terminalMiddle.width, greaterThan(terminalStart.width));
    expect(terminalMiddle.height, greaterThan(terminalStart.height));
    expect(barMiddle, greaterThan(0.0));
    expect(barMiddle, lessThan(barStart));

    await tester.pumpWidget(
      _buildPreview(
        placement: placement,
        backend: backend,
        localFrame: placement.durationFrames - 1,
      ),
    );
    await tester.pumpAndSettle();

    final Rect terminalEnd = tester.getRect(
      find.byKey(const ValueKey<String>('structural-terminal-window')),
    );
    expect(terminalEnd.width, greaterThan(terminalMiddle.width));
    expect(terminalEnd.height, greaterThan(terminalMiddle.height));
    expect(
      find.byKey(const ValueKey<String>('structural-terminal-title-bar')),
      findsNothing,
    );
  });
  testWidgets('APPSWITCH SLIDE pans between adjacent STRUCT clients',
      (WidgetTester tester) async {
    final List<StructuralSequencePlacement> placements =
        parseStructuralSequencePlacements(_slideSource);
    expect(placements, hasLength(2));
    expect(placements.first.seamlessToNext, isTrue);
    expect(placements.last.seamlessFromPrevious, isTrue);

    final _FakeBackend backend = _FakeBackend();
    final StructuralSequencePlacement outgoing = placements.first;
    final StructuralSequencePlacement incoming = placements.last;

    await tester.pumpWidget(
      _buildPreview(
        placement: outgoing,
        backend: backend,
        localFrame: outgoing.contentEndFrameExclusive - 1,
        rawDocument: _slideSource,
      ),
    );

    final Finder ready = find.byKey(
      const ValueKey<String>('structural-first-frame-ready'),
    );
    for (int attempt = 0; attempt < 50 && ready.evaluate().isEmpty; attempt++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pump();
    }
    expect(ready, findsOneWidget);

    final int midFrame = kStructuralSwitchSlideFrames ~/ 2;
    await tester.pumpWidget(
      _buildPreview(
        placement: incoming,
        backend: backend,
        localFrame: midFrame,
        rawDocument: _slideSource,
      ),
    );

    final Finder outgoingSlide = find.byKey(
      const ValueKey<String>('structural-handoff-outgoing'),
    );
    final Finder incomingSlide = find.byKey(
      const ValueKey<String>('structural-handoff-incoming'),
    );

    for (int attempt = 0; attempt < 50; attempt++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pump();
      if (outgoingSlide.evaluate().isNotEmpty &&
          incomingSlide.evaluate().isNotEmpty) {
        final FractionalTranslation movingIn =
            tester.widget<FractionalTranslation>(incomingSlide);
        if (movingIn.translation.dx < 0.999) break;
      }
    }

    expect(outgoingSlide, findsOneWidget);
    expect(incomingSlide, findsOneWidget);

    final FractionalTranslation movingOut =
        tester.widget<FractionalTranslation>(outgoingSlide);
    final FractionalTranslation movingIn =
        tester.widget<FractionalTranslation>(incomingSlide);

    expect(movingOut.translation.dx, lessThan(0.0));
    expect(movingOut.translation.dx, greaterThan(-1.0));
    expect(movingIn.translation.dx, greaterThan(0.0));
    expect(movingIn.translation.dx, lessThan(1.0));
    expect(
      movingIn.translation.dx - movingOut.translation.dx,
      closeTo(1.0, 0.0001),
    );

    await tester.pumpWidget(
      _buildPreview(
        placement: incoming,
        backend: backend,
        localFrame: kStructuralSwitchSlideFrames - 1,
        rawDocument: _slideSource,
      ),
    );
    await tester.pump();

    for (int attempt = 0;
        attempt < 50 && outgoingSlide.evaluate().isNotEmpty;
        attempt++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pump();
    }

    expect(outgoingSlide, findsNothing);
    expect(incomingSlide, findsOneWidget);
    final FractionalTranslation seated =
        tester.widget<FractionalTranslation>(incomingSlide);
    expect(seated.translation, Offset.zero);
  });


}
