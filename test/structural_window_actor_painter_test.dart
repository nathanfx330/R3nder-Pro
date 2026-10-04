// ./test/structural_window_actor_painter_test.dart

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/mosaic_layout_program.dart';
import 'package:r3nder/mosaic_split_geometry.dart';
import 'package:r3nder/structural_chrome.dart';
import 'package:r3nder/structural_sequence.dart';
import 'package:r3nder/structural_split_window_painter.dart';
import 'package:r3nder/structural_window_actor_painter.dart';
import 'package:r3nder/ui_theme.dart';

Future<ui.Image> _solidImage(Color color, {int width = 16, int height = 16}) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = color,
  );
  final ui.Picture picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}

Future<Uint8List> _paintBytes({
  required int width,
  required int height,
  required void Function(Canvas canvas) paint,
}) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = Colors.black,
  );
  paint(canvas);
  final ui.Picture picture = recorder.endRecording();
  try {
    final ui.Image image = await picture.toImage(width, height);
    try {
      final ByteData? data =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      expect(data, isNotNull);
      return data!.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
    } finally {
      image.dispose();
    }
  } finally {
    picture.dispose();
  }
}

List<int> _pixel(Uint8List rgba, int width, int x, int y) {
  final int at = (y * width + x) * 4;
  return rgba.sublist(at, at + 4);
}

void main() {
  test('legacy seated SPLIT is byte-identical through actor projection', () async {
    const String source = '''[MOSAIC:wall]
[PANE:left]
[CLIP:left_clip:left.mp4:0:0:12:1]
[/CLIP]
[/PANE]
[PANE:right]
[CLIP:right_clip:right.mp4:0:0:12:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall:SPLIT:ASPECT=4X3:OVERLAY=NONE]
''';
    const int width = 640;
    const int height = 360;
    const double chromeScale = 1.0;
    const int sourceFrame = 5;

    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(source).single;
    final MosaicSplitWindowGeometry geometry = mosaicSplitWindowGeometry(
      frame: Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      aspect: placement.splitClientAspect,
      titleHeight: 38.0 * chromeScale,
    );
    final ui.Image red = await _solidImage(const Color(0xFFFF0000));
    final ui.Image blue = await _solidImage(const Color(0xFF0000FF));
    addTearDown(() {
      red.dispose();
      blue.dispose();
    });

    final R3Theme theme = R3Theme.of(Colors.green);
    final StructuralSplitWindowPainter legacy = StructuralSplitWindowPainter(
      geometry: geometry,
      placement: placement,
      sourceFrame: sourceFrame,
      theme: theme,
      fontFamily: 'monospace',
      chromeScale: chromeScale,
      images: <ui.Image?>[red, blue],
      diagnosticLabels: const <String>['LEFT', 'RIGHT'],
    );

    final Uint8List legacyBytes = await _paintBytes(
      width: width,
      height: height,
      paint: (Canvas canvas) {
        legacy.paint(canvas, Size(width.toDouble(), height.toDouble()));
      },
    );

    final Uint8List actorBytes = await _paintBytes(
      width: width,
      height: height,
      paint: (Canvas canvas) {
        for (int paneIndex = 0; paneIndex < 2; paneIndex++) {
          paintStructuralWindowActor(
            canvas: canvas,
            theme: theme,
            chromeScale: chromeScale,
            fontFamily: 'monospace',
            rect: geometry.windowRects[paneIndex],
            opacity: 1.0,
            windowChrome: 1.0,
            visual: StructuralWindowActorVisual(
              sourceImage: paneIndex == 0 ? red : blue,
              sourceFrame: sourceFrame,
              sourceDurationFrames: placement.sourceDurationFrames,
              windowTitle: placement.splitWindowTitleForPane(paneIndex),
              overlayMode: placement.overlayMode,
              topOverlay: placement.topOverlay,
              bottomOverlay: placement.bottomOverlay,
              defaultBottomOverlay: paneIndex == 0 ? 'LEFT' : 'RIGHT',
            ),
          );
        }
      },
    );

    expect(actorBytes, orderedEquals(legacyBytes));
  });

  test('MosaicLayoutWindowPainter obeys actor z instead of input order',
      () async {
    const int width = 160;
    const int height = 100;
    const Rect rect = Rect.fromLTWH(20, 10, 120, 80);
    const MosaicLayoutActorId actorA = MosaicLayoutActorId.pane('A', 1);
    const MosaicLayoutActorId actorB = MosaicLayoutActorId.pane('B', 2);

    final ui.Image red = await _solidImage(const Color(0xFFFF0000));
    final ui.Image blue = await _solidImage(const Color(0xFF0000FF));
    addTearDown(() {
      red.dispose();
      blue.dispose();
    });

    const MosaicLayoutZ lowZ = MosaicLayoutZ(
      band: MosaicLayoutZBand.stable,
      roleRank: 0,
      actorOrdinal: 1,
    );
    const MosaicLayoutZ highZ = MosaicLayoutZ(
      band: MosaicLayoutZBand.stable,
      roleRank: 1,
      actorOrdinal: 2,
    );

    final MosaicLayoutFrame frame = MosaicLayoutFrame(
      sourceFrame: 12,
      // Deliberately put the higher actor first. paintActors must sort it back
      // above A by z before projection.
      actors: const <MosaicLayoutActorFrame>[
        MosaicLayoutActorFrame(
          actorId: actorB,
          presence: MosaicLayoutPresence.present,
          rect: rect,
          opacity: 1.0,
          chrome: 0.0,
          z: highZ,
          activeSegment: null,
        ),
        MosaicLayoutActorFrame(
          actorId: actorA,
          presence: MosaicLayoutPresence.present,
          rect: rect,
          opacity: 1.0,
          chrome: 0.0,
          z: lowZ,
          activeSegment: null,
        ),
      ],
    );

    final MosaicLayoutWindowPainter painter = MosaicLayoutWindowPainter(
      layoutFrame: frame,
      visuals: <MosaicLayoutActorId, StructuralWindowActorVisual>{
        actorA: StructuralWindowActorVisual(
          sourceImage: red,
          sourceFrame: 12,
          sourceDurationFrames: 100,
          windowTitle: 'A',
          overlayMode: StructuralOverlayMode.none,
          topOverlay: '',
          bottomOverlay: '',
          defaultBottomOverlay: '',
        ),
        actorB: StructuralWindowActorVisual(
          sourceImage: blue,
          sourceFrame: 12,
          sourceDurationFrames: 100,
          windowTitle: 'B',
          overlayMode: StructuralOverlayMode.none,
          topOverlay: '',
          bottomOverlay: '',
          defaultBottomOverlay: '',
        ),
      },
      theme: R3Theme.of(Colors.green),
      fontFamily: 'monospace',
      chromeScale: 1.0,
    );

    final Uint8List rgba = await _paintBytes(
      width: width,
      height: height,
      paint: (Canvas canvas) {
        painter.paint(canvas, Size(width.toDouble(), height.toDouble()));
      },
    );

    final List<int> center = _pixel(rgba, width, 80, 50);
    expect(center[0], lessThan(20));
    expect(center[1], lessThan(20));
    expect(center[2], greaterThan(240));
    expect(center[3], 255);
  });

  test('absent layout actor is never projected even with a higher z', () async {
    const int width = 160;
    const int height = 100;
    const Rect rect = Rect.fromLTWH(20, 10, 120, 80);
    const MosaicLayoutActorId actorA = MosaicLayoutActorId.pane('A', 1);
    const MosaicLayoutActorId actorB = MosaicLayoutActorId.pane('B', 2);

    final ui.Image red = await _solidImage(const Color(0xFFFF0000));
    final ui.Image blue = await _solidImage(const Color(0xFF0000FF));
    addTearDown(() {
      red.dispose();
      blue.dispose();
    });

    final MosaicLayoutWindowPainter painter = MosaicLayoutWindowPainter(
      layoutFrame: const MosaicLayoutFrame(
        sourceFrame: 12,
        actors: <MosaicLayoutActorFrame>[
          MosaicLayoutActorFrame(
            actorId: actorA,
            presence: MosaicLayoutPresence.present,
            rect: rect,
            opacity: 1.0,
            chrome: 0.0,
            z: MosaicLayoutZ(
              band: MosaicLayoutZBand.stable,
              roleRank: 0,
              actorOrdinal: 1,
            ),
            activeSegment: null,
          ),
          MosaicLayoutActorFrame(
            actorId: actorB,
            presence: MosaicLayoutPresence.absent,
            rect: rect,
            opacity: 1.0,
            chrome: 0.0,
            z: MosaicLayoutZ(
              band: MosaicLayoutZBand.fullTarget,
              roleRank: 9,
              actorOrdinal: 2,
            ),
            activeSegment: null,
          ),
        ],
      ),
      visuals: <MosaicLayoutActorId, StructuralWindowActorVisual>{
        actorA: StructuralWindowActorVisual(
          sourceImage: red,
          sourceFrame: 12,
          sourceDurationFrames: 100,
          windowTitle: 'A',
          overlayMode: StructuralOverlayMode.none,
          topOverlay: '',
          bottomOverlay: '',
          defaultBottomOverlay: '',
        ),
        actorB: StructuralWindowActorVisual(
          sourceImage: blue,
          sourceFrame: 12,
          sourceDurationFrames: 100,
          windowTitle: 'B',
          overlayMode: StructuralOverlayMode.none,
          topOverlay: '',
          bottomOverlay: '',
          defaultBottomOverlay: '',
        ),
      },
      theme: R3Theme.of(Colors.green),
      fontFamily: 'monospace',
      chromeScale: 1.0,
    );

    final Uint8List rgba = await _paintBytes(
      width: width,
      height: height,
      paint: (Canvas canvas) {
        painter.paint(canvas, Size(width.toDouble(), height.toDouble()));
      },
    );

    final List<int> center = _pixel(rgba, width, 80, 50);
    expect(center[0], greaterThan(240));
    expect(center[1], lessThan(20));
    expect(center[2], lessThan(20));
    expect(center[3], 255);
  });
}
