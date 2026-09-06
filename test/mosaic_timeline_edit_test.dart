// ./test/mosaic_timeline_edit_test.dart

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/mosaic_surface.dart';
import 'package:r3nder/mosaic_surface_model.dart';
import 'package:r3nder/ui_theme.dart';

const String _source = '''[EDIT:cuts]
[TRACK:V1]
[CLIP:a:video/a.mp4:0:0:80:1]
[/CLIP]
[CLIP:b:video/b.mp4:80:0:80:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:pane1]
[CLIP:a:video/a.mp4:0:0:80:1]
[/CLIP]
[CLIP:b:video/b.mp4:80:0:80:1]
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

Widget _host(ValueChanged<String> onSourceChanged) {
  final R3Theme theme = R3Theme.of(const Color(0xFF00FF00));
  return MaterialApp(
    theme: theme.materialTheme(),
    home: Scaffold(
      body: SizedBox(
        width: 1280,
        height: 720,
        child: MosaicSurface(
          source: _source,
          mosaicId: 'wall',
          currentFrame: 0,
          theme: theme,
          backend: _SolidBackend(),
          resolveSource: (String value) => value,
          onSourceChanged: onSourceChanged,
          onSeek: (_) {},
        ),
      ),
    ),
  );
}

Future<void> _dragVisibleRegion(
  WidgetTester tester,
  Finder finder,
  Offset delta,
) async {
  final Rect rect = tester.getRect(finder);

  // The between-cut XFADE badge deliberately occupies the upper part of a
  // boundary. Real trim handles remain exposed below it. Starting the gesture
  // three-quarters down the visible region exercises the actual user-accessible
  // drag target rather than assuming the wrapper widget's center owns input.
  final Offset start = Offset(
    rect.center.dx,
    rect.top + rect.height * 0.75,
  );

  final TestGesture gesture = await tester.startGesture(start);
  await gesture.moveBy(delta);
  await gesture.up();
}

void main() {
  test('crossfade normalizes arbitrary dragged geometry to real overlap', () {
    final MosaicSurfaceDocument document =
        MosaicSurfaceDocument.parse(_source, 'wall');
    final String moved = document.moveClip('pane1', 'b', 70);
    final MosaicSurfaceDocument afterMove =
        MosaicSurfaceDocument.parse(moved, 'wall');

    expect(afterMove.clip('pane1', 'b').atFrame, 70);

    final String faded =
        afterMove.setCrossfadeBetween('pane1', 'a', 'b', 24);
    final MosaicSurfaceDocument afterFade =
        MosaicSurfaceDocument.parse(faded, 'wall');

    expect(afterFade.clip('pane1', 'a').endFrameExclusive, 80);
    expect(afterFade.clip('pane1', 'b').atFrame, 56);
    expect(afterFade.incomingCrossfadeFrames('pane1', 'b'), 24);
  });

  test('pane trim start advances source IN and preserves source OUT', () {
    final MosaicSurfaceDocument document =
        MosaicSurfaceDocument.parse(_source, 'wall');
    final EditClip before = document.clip('pane1', 'a');
    final int beforeOut =
        before.sourceFrameAtProjectOffset(before.durationFrames - 1);

    final String next = document.trimClipStart('pane1', 'a', 10);
    final EditClip after =
        MosaicSurfaceDocument.parse(next, 'wall').clip('pane1', 'a');

    expect(after.atFrame, 10);
    expect(after.inFrame, 10);
    expect(after.durationFrames, 70);
    expect(after.sourceFrameAtProjectOffset(after.durationFrames - 1), beforeOut);
  });

  testWidgets('pane timeline exposes ruler and draggable CLIPs',
      (WidgetTester tester) async {
    String? changed;
    await tester.pumpWidget(_host((String value) => changed = value));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('mosaic-ruler:pane1')),
      findsOneWidget,
    );
    final Finder clip = find.byKey(
      const ValueKey<String>('mosaic-cut-assignment:b'),
    );
    expect(clip, findsOneWidget);

    // Default MOSAIC timeline scale is 2 px/frame, so 20 px = 10 frames.
    await _dragVisibleRegion(tester, clip, const Offset(-20, 0));
    await tester.pumpAndSettle();

    expect(changed, isNotNull);
    final EditClip moved =
        MosaicSurfaceDocument.parse(changed!, 'wall').clip('pane1', 'b');
    expect(moved.atFrame, 70);
  });

  testWidgets('pane timeline left trim changes AT, IN, and duration together',
      (WidgetTester tester) async {
    String? changed;
    await tester.pumpWidget(_host((String value) => changed = value));
    await tester.pumpAndSettle();

    final Finder handle = find.byKey(
      const ValueKey<String>('mosaic-clip:pane1:a-in-handle'),
    );
    expect(handle, findsOneWidget);

    await _dragVisibleRegion(tester, handle, const Offset(20, 0));
    await tester.pumpAndSettle();

    expect(changed, isNotNull);
    final EditClip trimmed =
        MosaicSurfaceDocument.parse(changed!, 'wall').clip('pane1', 'a');
    expect(trimmed.atFrame, 10);
    expect(trimmed.inFrame, 10);
    expect(trimmed.durationFrames, 70);
  });

  testWidgets('pane timeline right trim changes only project duration',
      (WidgetTester tester) async {
    String? changed;
    await tester.pumpWidget(_host((String value) => changed = value));
    await tester.pumpAndSettle();

    final Finder handle = find.byKey(
      const ValueKey<String>('mosaic-clip:pane1:a-out-handle'),
    );
    expect(handle, findsOneWidget);

    await _dragVisibleRegion(tester, handle, const Offset(-20, 0));
    await tester.pumpAndSettle();

    expect(changed, isNotNull);
    final EditClip trimmed =
        MosaicSurfaceDocument.parse(changed!, 'wall').clip('pane1', 'a');
    expect(trimmed.atFrame, 0);
    expect(trimmed.inFrame, 0);
    expect(trimmed.durationFrames, 70);
  });
}
