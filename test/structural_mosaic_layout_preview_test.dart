// ./test/structural_mosaic_layout_preview_test.dart

import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/mosaic_layout_program.dart';
import 'package:r3nder/mosaic_split_geometry.dart';
import 'package:r3nder/structural_mosaic_layout_preview.dart';
import 'package:r3nder/structural_sequence.dart';
import 'package:r3nder/structural_sequence_preview.dart';
import 'package:r3nder/structural_shell_geometry.dart';
import 'package:r3nder/structural_split_window_preview.dart';
import 'package:r3nder/structural_window_actor_painter.dart';
import 'package:r3nder/ui_theme.dart';

const String _layoutSource = '''[MOSAIC:wall]
[LAYOUT:0:TWOUP:A=left:B=right:DUR=1]
[LAYOUT:4:ONE:PANE=left:DUR=1]
[LAYOUT:6:TWOUP:A=left:B=right:DUR=1]
[PANE:left]
[CLIP:left_clip:left.mp4:0:0:12:1]
[/CLIP]
[/PANE]
[PANE:right]
[CLIP:right_clip:right.mp4:0:0:12:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall:OVERLAY=NONE]
''';

const String _oneExitSource = '''[MOSAIC:wall]
[LAYOUT:0:TWOUP:A=left:B=right:DUR=1]
[LAYOUT:20:ONE:PANE=left:DUR=12]
[PANE:left]
[CLIP:left_clip:left.mp4:0:0:80:1]
[/CLIP]
[/PANE]
[PANE:right]
[CLIP:right_clip:right.mp4:0:0:80:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall:OVERLAY=NONE]
''';

const String _longRecallSource = '''[MOSAIC:wall]
[LAYOUT:0:TWOUP:A=left:B=right:DUR=1]
[LAYOUT:10:ONE:PANE=left:DUR=1]
[LAYOUT:400:TWOUP:A=left:B=right:DUR=1]
[PANE:left]
[CLIP:left_clip:left.mp4:0:0:500:1]
[/CLIP]
[/PANE]
[PANE:right]
[CLIP:right_clip:right.mp4:0:0:500:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall:OVERLAY=NONE]
''';

const String _namedLayoutSource = '''[MOSAIC:wall]
[LAYOUT:0:TWOUP:A=left:B=right:DUR=1]
[PANE:left]
[CLIP:left_clip:left.mp4:0:0:12:1]
[/CLIP]
[/PANE]
[PANE:right]
[CLIP:right_clip:right.mp4:0:0:12:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall:PANENAMES:NAME1="Camera A":NAME2="Witness":OVERLAY=NONE]
''';

const String _legacySplitSource = '''[MOSAIC:wall]
[PANE:left]
[CLIP:left_clip:left.mp4:0:0:12:1]
[/CLIP]
[/PANE]
[PANE:right]
[CLIP:right_clip:right.mp4:0:0:12:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall:SPLIT:OVERLAY=NONE]
''';

String _resolveTestSource(String value) => value;

class _ColorBackend implements MediaDecoderBackend {
  final Map<String, List<int>> requestedFrames = <String, List<int>>{};

  @override
  MediaDecoder open(String resolvedPath) {
    final List<int> frames =
        requestedFrames.putIfAbsent(resolvedPath, () => <int>[]);
    return _ColorDecoder(
      frames,
      resolvedPath.contains('right')
          ? const <int>[0, 0, 255, 255]
          : const <int>[255, 0, 0, 255],
    );
  }
}

class _ColorDecoder implements MediaDecoder {
  final List<int> requestedFrames;
  final List<int> color;

  _ColorDecoder(this.requestedFrames, this.color);

  @override
  DecodedMediaFrame render(
    int requestedSourceFrame,
    int width,
    int height,
  ) {
    requestedFrames.add(requestedSourceFrame);
    final Uint8List rgba = Uint8List(width * height * 4);
    for (int at = 0; at < rgba.length; at += 4) {
      rgba.setRange(at, at + 4, color);
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


class _ControlledPendingBackend implements MediaDecoderBackend {
  bool releaseFrame1 = false;

  @override
  MediaDecoder open(String resolvedPath) =>
      _ControlledPendingDecoder(this, resolvedPath);
}

class _ControlledPendingDecoder implements NonBlockingMediaDecoder {
  final _ControlledPendingBackend owner;
  final String resolvedPath;

  _ControlledPendingDecoder(this.owner, this.resolvedPath);

  @override
  void request(int requestedSourceFrame, int width, int height) {}

  @override
  DecodedMediaFrame? poll(
    int requestedSourceFrame,
    int width,
    int height,
  ) {
    if (requestedSourceFrame == 1 && !owner.releaseFrame1) {
      return null;
    }
    final Uint8List rgba = Uint8List(width * height * 4);
    final List<int> color = resolvedPath.contains('right')
        ? const <int>[0, 0, 255, 255]
        : const <int>[255, 0, 0, 255];
    for (int at = 0; at < rgba.length; at += 4) {
      rgba.setRange(at, at + 4, color);
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
  DecodedMediaFrame render(
    int requestedSourceFrame,
    int width,
    int height,
  ) {
    throw StateError('Residency test must remain on nonblocking decode.');
  }

  @override
  void dispose() {}
}

class _PlaybackLagBackend implements MediaDecoderBackend {
  bool releaseLag = false;

  @override
  MediaDecoder open(String resolvedPath) =>
      _PlaybackLagDecoder(this, resolvedPath);
}

class _PlaybackLagDecoder implements NonBlockingMediaDecoder {
  final _PlaybackLagBackend owner;
  final String resolvedPath;

  _PlaybackLagDecoder(this.owner, this.resolvedPath);

  @override
  void request(int requestedSourceFrame, int width, int height) {}

  @override
  DecodedMediaFrame? poll(
    int requestedSourceFrame,
    int width,
    int height,
  ) {
    if (requestedSourceFrame > 0 && !owner.releaseLag) return null;
    final Uint8List rgba = Uint8List(width * height * 4);
    final List<int> color = resolvedPath.contains('right')
        ? const <int>[0, 0, 255, 255]
        : const <int>[255, 0, 0, 255];
    for (int at = 0; at < rgba.length; at += 4) {
      rgba.setRange(at, at + 4, color);
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
  DecodedMediaFrame render(
    int requestedSourceFrame,
    int width,
    int height,
  ) {
    throw StateError('Playback-lag test must remain on nonblocking decode.');
  }

  @override
  void dispose() {}
}

class _LongRecallPendingBackend implements MediaDecoderBackend {
  bool releaseRecall = false;

  @override
  MediaDecoder open(String resolvedPath) =>
      _LongRecallPendingDecoder(this, resolvedPath);
}

class _LongRecallPendingDecoder implements NonBlockingMediaDecoder {
  final _LongRecallPendingBackend owner;
  final String resolvedPath;

  _LongRecallPendingDecoder(this.owner, this.resolvedPath);

  @override
  void request(int requestedSourceFrame, int width, int height) {}

  @override
  DecodedMediaFrame? poll(
    int requestedSourceFrame,
    int width,
    int height,
  ) {
    if (resolvedPath.contains('right') &&
        requestedSourceFrame >= 395 &&
        !owner.releaseRecall) {
      return null;
    }
    final Uint8List rgba = Uint8List(width * height * 4);
    final List<int> color = resolvedPath.contains('right')
        ? const <int>[0, 0, 255, 255]
        : const <int>[255, 0, 0, 255];
    for (int at = 0; at < rgba.length; at += 4) {
      rgba.setRange(at, at + 4, color);
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
  DecodedMediaFrame render(
    int requestedSourceFrame,
    int width,
    int height,
  ) {
    throw StateError('Long-recall test must remain on nonblocking decode.');
  }

  @override
  void dispose() {}
}

class _PendingBackend implements MediaDecoderBackend {
  @override
  MediaDecoder open(String resolvedPath) => _PendingDecoder();
}

class _PendingDecoder implements NonBlockingMediaDecoder {
  @override
  void request(int requestedSourceFrame, int width, int height) {}

  @override
  DecodedMediaFrame? poll(
    int requestedSourceFrame,
    int width,
    int height,
  ) =>
      null;

  @override
  DecodedMediaFrame render(
    int requestedSourceFrame,
    int width,
    int height,
  ) {
    throw StateError('Pending test decoder must stay on nonblocking path.');
  }

  @override
  void dispose() {}
}

Widget _preview({
  required String source,
  required StructuralSequencePlacement placement,
  required int localFrame,
  required MediaDecoderBackend backend,
  required bool playing,
}) {
  return MaterialApp(
    home: SizedBox(
      width: 800,
      height: 500,
      child: StructuralSequencePreview(
        rawDocument: source,
        placement: placement,
        localFrame: localFrame,
        isPlaying: playing,
        theme: R3Theme.of(Colors.green),
        wallpaper: null,
        backend: backend,
        resolveSource: _resolveTestSource,
      ),
    ),
  );
}

Future<void> _pumpUntilLayoutReady(
  WidgetTester tester,
) async {
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
}

MosaicLayoutWindowPainter _layoutPainter(WidgetTester tester) {
  final CustomPaint paint = tester.widget<CustomPaint>(
    find.byKey(
      const ValueKey<String>('structural-mosaic-layout-frame'),
    ),
  );
  return paint.painter! as MosaicLayoutWindowPainter;
}

void main() {
  testWidgets('authored LAYOUT routes live Preview through actor painter',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_layoutSource).single;
    final _ColorBackend backend = _ColorBackend();
    final int localFrame = placement.contentStartFrame;

    await tester.pumpWidget(
      _preview(
        source: _layoutSource,
        placement: placement,
        localFrame: localFrame,
        backend: backend,
        playing: false,
      ),
    );
    await _pumpUntilLayoutReady(tester);

    expect(find.byType(StructuralMosaicLayoutPreview), findsOneWidget);
    expect(find.byType(StructuralSplitWindowPreview), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('structural-window-frame')),
      findsNothing,
    );

    final MosaicLayoutWindowPainter painter = _layoutPainter(tester);
    final MosaicLayoutFrame frame = painter.layoutFrame;
    expect(frame.sourceFrame, 0);
    expect(frame.pane('left').presence, MosaicLayoutPresence.present);
    expect(frame.pane('right').presence, MosaicLayoutPresence.present);
    expect(frame.composite.presence, MosaicLayoutPresence.absent);
    expect(frame.paintActors, hasLength(2));
    expect(
      painter.visuals.values
          .where((StructuralWindowActorVisual visual) =>
              visual.sourceImage != null),
      hasLength(2),
    );
  });


  testWidgets('dynamic TWO UP uses placement window-slot names',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_namedLayoutSource).single;
    final _ColorBackend backend = _ColorBackend();

    await tester.pumpWidget(
      _preview(
        source: _namedLayoutSource,
        placement: placement,
        localFrame: placement.contentStartFrame,
        backend: backend,
        playing: false,
      ),
    );
    await _pumpUntilLayoutReady(tester);

    final MosaicLayoutWindowPainter painter = _layoutPainter(tester);
    final StructuralWindowActorVisual left = painter.visuals.entries
        .singleWhere(
          (MapEntry<MosaicLayoutActorId, StructuralWindowActorVisual> entry) =>
              entry.key.paneId == 'left',
        )
        .value;
    final StructuralWindowActorVisual right = painter.visuals.entries
        .singleWhere(
          (MapEntry<MosaicLayoutActorId, StructuralWindowActorVisual> entry) =>
              entry.key.paneId == 'right',
        )
        .value;

    expect(left.windowTitle, 'MOSAIC.wall · Camera A');
    expect(right.windowTitle, 'MOSAIC.wall · Witness');
  });

  testWidgets('source-frame cue changes live actor set without recreating source',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_layoutSource).single;
    final _ColorBackend backend = _ColorBackend();

    await tester.pumpWidget(
      _preview(
        source: _layoutSource,
        placement: placement,
        localFrame: placement.contentStartFrame,
        backend: backend,
        playing: false,
      ),
    );
    await _pumpUntilLayoutReady(tester);

    await tester.pumpWidget(
      _preview(
        source: _layoutSource,
        placement: placement,
        localFrame: placement.contentStartFrame + 4,
        backend: backend,
        playing: false,
      ),
    );
    await _pumpUntilLayoutReady(tester);

    final MosaicLayoutFrame frame = _layoutPainter(tester).layoutFrame;
    expect(frame.sourceFrame, 4);
    expect(frame.pane('left').presence, MosaicLayoutPresence.present);
    expect(frame.pane('right').presence, MosaicLayoutPresence.absent);
    expect(frame.pane('left').rect.width, greaterThan(0));
    expect(frame.paintActors, hasLength(1));
  });

  testWidgets('moving Preview warms hidden pane on shared source clock',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_layoutSource).single;
    final _ColorBackend backend = _ColorBackend();

    await tester.pumpWidget(
      _preview(
        source: _layoutSource,
        placement: placement,
        localFrame: placement.contentStartFrame + 4,
        backend: backend,
        playing: true,
      ),
    );

    for (int attempt = 0; attempt < 20; attempt++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      });
      await tester.pump();
      if ((backend.requestedFrames['right.mp4'] ?? const <int>[]).contains(4)) {
        break;
      }
    }

    expect(
      backend.requestedFrames['right.mp4'],
      contains(4),
      reason:
          'right pane returns at F6 and must be warmed at the current F4 clock',
    );
  });


  testWidgets('parked scrub holds current-run resident pixels during decode',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_longRecallSource).single;
    final _ColorBackend backend = _ColorBackend();

    await tester.pumpWidget(
      _preview(
        source: _longRecallSource,
        placement: placement,
        localFrame: placement.contentStartFrame,
        backend: backend,
        playing: false,
      ),
    );
    await _pumpUntilLayoutReady(tester);

    MosaicLayoutWindowPainter painter = _layoutPainter(tester);
    final StructuralWindowActorVisual initialLeft = painter.visuals.entries
        .singleWhere(
          (MapEntry<MosaicLayoutActorId, StructuralWindowActorVisual> entry) =>
              entry.key.paneId == 'left',
        )
        .value;
    expect(initialLeft.sourceImage, isNotNull);

    // Jump far ahead while parked. The rebuild happens before the asynchronous
    // ui.Image conversion for the exact requested frame can repaint. The
    // currently visible actor must keep its current-run resident image through
    // that gap instead of flashing an empty client.
    await tester.pumpWidget(
      _preview(
        source: _longRecallSource,
        placement: placement,
        localFrame: placement.contentStartFrame + 200,
        backend: backend,
        playing: false,
      ),
    );

    painter = _layoutPainter(tester);
    expect(painter.layoutFrame.sourceFrame, 200);
    expect(painter.layoutFrame.pane('left').presence,
        MosaicLayoutPresence.present);
    final StructuralWindowActorVisual scrubLeft = painter.visuals.entries
        .singleWhere(
          (MapEntry<MosaicLayoutActorId, StructuralWindowActorVisual> entry) =>
              entry.key.paneId == 'left',
        )
        .value;
    expect(
      scrubLeft.sourceImage,
      isNotNull,
      reason:
          'parked scrub must hold the visible actor image until exact decode lands',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
      'parked direct recall rejects image from an earlier visibility run',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_longRecallSource).single;
    final _ColorBackend backend = _ColorBackend();

    await tester.pumpWidget(
      _preview(
        source: _longRecallSource,
        placement: placement,
        localFrame: placement.contentStartFrame,
        backend: backend,
        playing: false,
      ),
    );
    await _pumpUntilLayoutReady(tester);

    MosaicLayoutWindowPainter painter = _layoutPainter(tester);
    final StructuralWindowActorVisual initialRight = painter.visuals.entries
        .singleWhere(
          (MapEntry<MosaicLayoutActorId, StructuralWindowActorVisual> entry) =>
              entry.key.paneId == 'right',
        )
        .value;
    expect(initialRight.sourceImage, isNotNull);

    // Scrub directly across the authored hidden interval without ever building
    // an intermediate hidden frame. The old image still exists in the cache at
    // rebuild time, so the visibility-run guard—not tick-time eviction—must
    // reject it until the exact F400 image lands.
    await tester.pumpWidget(
      _preview(
        source: _longRecallSource,
        placement: placement,
        localFrame: placement.contentStartFrame + 400,
        backend: backend,
        playing: false,
      ),
    );

    painter = _layoutPainter(tester);
    expect(painter.layoutFrame.sourceFrame, 400);
    expect(
      painter.layoutFrame.pane('right').presence,
      MosaicLayoutPresence.present,
    );
    final StructuralWindowActorVisual recalledRight = painter.visuals.entries
        .singleWhere(
          (MapEntry<MosaicLayoutActorId, StructuralWindowActorVisual> entry) =>
              entry.key.paneId == 'right',
        )
        .value;
    expect(
      recalledRight.sourceImage,
      isNull,
      reason:
          'parked scrub must not bridge across an authored hidden interval',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
      'retiring TWOUP pane keeps resident pixels through ONE exit motion',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_oneExitSource).single;
    final _PlaybackLagBackend backend = _PlaybackLagBackend();

    await tester.pumpWidget(
      _preview(
        source: _oneExitSource,
        placement: placement,
        localFrame: placement.contentStartFrame,
        backend: backend,
        playing: true,
      ),
    );
    await _pumpUntilLayoutReady(tester);

    await tester.pumpWidget(
      _preview(
        source: _oneExitSource,
        placement: placement,
        localFrame: placement.contentStartFrame + 25,
        backend: backend,
        playing: true,
      ),
    );
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump();

    MosaicLayoutWindowPainter painter = _layoutPainter(tester);
    expect(painter.layoutFrame.sourceFrame, 25);
    expect(
      painter.layoutFrame.pane('right').presence,
      MosaicLayoutPresence.exiting,
    );
    final StructuralWindowActorVisual exitingRight = painter.visuals.entries
        .singleWhere(
          (MapEntry<MosaicLayoutActorId, StructuralWindowActorVisual> entry) =>
              entry.key.paneId == 'right',
        )
        .value;
    expect(
      exitingRight.sourceImage,
      isNotNull,
      reason:
          'an exiting pane must keep its resident pixels until its exit settles',
    );

    await tester.pumpWidget(
      _preview(
        source: _oneExitSource,
        placement: placement,
        localFrame: placement.contentStartFrame + 31,
        backend: backend,
        playing: true,
      ),
    );
    await tester.pump();

    painter = _layoutPainter(tester);
    expect(painter.layoutFrame.sourceFrame, 31);
    expect(
      painter.layoutFrame.pane('right').presence,
      MosaicLayoutPresence.absent,
    );
    expect(
      painter.visuals.keys.any(
        (MosaicLayoutActorId id) => id.paneId == 'right',
      ),
      isFalse,
      reason: 'the retiring pane leaves paint only when the exit settles',
    );

    backend.releaseLag = true;
    for (int attempt = 0; attempt < 10; attempt++) {
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      });
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
      'playback decode lag keeps same-run resident pixels beyond two frames',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_longRecallSource).single;
    final _PlaybackLagBackend backend = _PlaybackLagBackend();

    await tester.pumpWidget(
      _preview(
        source: _longRecallSource,
        placement: placement,
        localFrame: placement.contentStartFrame,
        backend: backend,
        playing: true,
      ),
    );
    await _pumpUntilLayoutReady(tester);

    await tester.pumpWidget(
      _preview(
        source: _longRecallSource,
        placement: placement,
        localFrame: placement.contentStartFrame + 5,
        backend: backend,
        playing: true,
      ),
    );
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump();

    final MosaicLayoutWindowPainter painter = _layoutPainter(tester);
    expect(painter.layoutFrame.sourceFrame, 5);
    expect(
      painter.visuals.values.every(
        (StructuralWindowActorVisual visual) => visual.sourceImage != null,
      ),
      isTrue,
      reason:
          'continuous visible actors must hold the last good image through multi-frame decode lag',
    );

    backend.releaseLag = true;
    for (int attempt = 0; attempt < 10; attempt++) {
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      });
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('pending next frame keeps last resident actor pixels',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_layoutSource).single;
    final _ControlledPendingBackend backend =
        _ControlledPendingBackend();

    await tester.pumpWidget(
      _preview(
        source: _layoutSource,
        placement: placement,
        localFrame: placement.contentStartFrame,
        backend: backend,
        playing: true,
      ),
    );
    await _pumpUntilLayoutReady(tester);

    MosaicLayoutWindowPainter painter = _layoutPainter(tester);
    expect(
      painter.visuals.values.every(
        (StructuralWindowActorVisual visual) => visual.sourceImage != null,
      ),
      isTrue,
    );

    await tester.pumpWidget(
      _preview(
        source: _layoutSource,
        placement: placement,
        localFrame: placement.contentStartFrame + 1,
        backend: backend,
        playing: true,
      ),
    );
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump();

    painter = _layoutPainter(tester);
    expect(painter.layoutFrame.sourceFrame, 1);
    expect(
      painter.visuals.values.every(
        (StructuralWindowActorVisual visual) => visual.sourceImage != null,
      ),
      isTrue,
      reason:
          'pending decode must hold resident pixels instead of flashing black',
    );

    // Let the pending frame resolve so the normal post-frame polling loop can
    // quiesce before widget-test teardown.
    backend.releaseFrame1 = true;
    for (int attempt = 0; attempt < 10; attempt++) {
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      });
      painter = _layoutPainter(tester);
      if (painter.visuals.values.every(
        (StructuralWindowActorVisual visual) => visual.sourceImage != null,
      )) {
        break;
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
      'recalled pane does not reuse ancient pre-exit resident pixels',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_longRecallSource).single;
    final _LongRecallPendingBackend backend = _LongRecallPendingBackend();

    await tester.pumpWidget(
      _preview(
        source: _longRecallSource,
        placement: placement,
        localFrame: placement.contentStartFrame,
        backend: backend,
        playing: true,
      ),
    );
    await _pumpUntilLayoutReady(tester);

    MosaicLayoutWindowPainter painter = _layoutPainter(tester);
    final StructuralWindowActorVisual initialRight = painter.visuals.entries
        .singleWhere(
          (MapEntry<MosaicLayoutActorId, StructuralWindowActorVisual> entry) =>
              entry.key.paneId == 'right',
        )
        .value;
    expect(initialRight.sourceImage, isNotNull);

    // Jump into the 24-frame warm window while the returning pane's decoder is
    // deliberately pending. This specifically proves lookahead cannot preserve
    // the old F0 image merely because the hidden pane is "requested".
    await tester.pumpWidget(
      _preview(
        source: _longRecallSource,
        placement: placement,
        localFrame: placement.contentStartFrame + 395,
        backend: backend,
        playing: true,
      ),
    );
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump();

    painter = _layoutPainter(tester);
    expect(painter.layoutFrame.sourceFrame, 395);
    expect(painter.layoutFrame.pane('right').presence,
        MosaicLayoutPresence.absent);

    await tester.pumpWidget(
      _preview(
        source: _longRecallSource,
        placement: placement,
        localFrame: placement.contentStartFrame + 400,
        backend: backend,
        playing: true,
      ),
    );
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump();

    painter = _layoutPainter(tester);
    expect(painter.layoutFrame.sourceFrame, 400);
    expect(
      painter.layoutFrame.pane('right').presence,
      MosaicLayoutPresence.present,
    );
    final StructuralWindowActorVisual recalledRight = painter.visuals.entries
        .singleWhere(
          (MapEntry<MosaicLayoutActorId, StructuralWindowActorVisual> entry) =>
              entry.key.paneId == 'right',
        )
        .value;
    expect(
      recalledRight.sourceImage,
      isNull,
      reason:
          'a recalled pane with pending decode must not flash its pre-exit image',
    );

    // Release the pending recall so the Preview retry loop can quiesce before
    // widget-test teardown.
    backend.releaseRecall = true;
    for (int attempt = 0; attempt < 10; attempt++) {
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      });
      painter = _layoutPainter(tester);
      final StructuralWindowActorVisual right = painter.visuals.entries
          .singleWhere(
            (MapEntry<MosaicLayoutActorId, StructuralWindowActorVisual> entry) =>
                entry.key.paneId == 'right',
          )
          .value;
      if (right.sourceImage != null) break;
    }

    expect(
      _layoutPainter(tester)
          .visuals
          .entries
          .singleWhere(
            (MapEntry<MosaicLayoutActorId, StructuralWindowActorVisual> entry) =>
                entry.key.paneId == 'right',
          )
          .value
          .sourceImage,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('opening layout geometry advances while decoder stays pending',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_layoutSource).single;
    final int openingFrame =
        placement.entryZoomFrames + (placement.entryWindowFrames ~/ 2);
    expect(
      placement.stageAt(openingFrame),
      StructuralSequenceStage.opening,
    );
    final double linear = placement.stageProgressAt(openingFrame);
    expect(linear, greaterThan(0));
    expect(linear, lessThan(1));

    await tester.pumpWidget(
      _preview(
        source: _layoutSource,
        placement: placement,
        localFrame: openingFrame,
        backend: _PendingBackend(),
        playing: true,
      ),
    );
    await tester.pump();

    final MosaicLayoutFrame display = _layoutPainter(tester).layoutFrame;
    final Rect actual = display.pane('left').rect;

    const Rect program = Rect.fromLTWH(0, 0, 800, 450);
    final MosaicSplitWindowGeometry geometry = mosaicSplitWindowGeometry(
      frame: program,
      aspect: MosaicSplitClientAspect.aspect16x9,
      titleHeight: 38,
    );
    final Rect target = geometry.leftWindowRect;
    final Rect emergence = structuralShellEmergenceRect(target);

    expect(actual, isNot(target));
    expect(actual, isNot(emergence));
    expect(actual.width, greaterThan(emergence.width));
    expect(actual.width, lessThan(target.width));

    expect(
      find.byKey(const ValueKey<String>('structural-first-frame-ready')),
      findsNothing,
      reason: 'readiness gates pixels, not authored opening geometry',
    );
  });

  testWidgets('cue-less legacy SPLIT keeps proven legacy Preview path',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_legacySplitSource).single;
    final _ColorBackend backend = _ColorBackend();

    await tester.pumpWidget(
      _preview(
        source: _legacySplitSource,
        placement: placement,
        localFrame: placement.contentStartFrame,
        backend: backend,
        playing: false,
      ),
    );
    await tester.pump();

    expect(find.byType(StructuralMosaicLayoutPreview), findsNothing);
    expect(find.byType(StructuralSplitWindowPreview), findsOneWidget);
  });
}
