// ./test/structural_sequence_dossier_shell_test.dart

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/card_overlay.dart';
import 'package:r3nder/edit_video_preview.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/structural_sequence.dart';
import 'package:r3nder/structural_sequence_preview.dart';
import 'package:r3nder/ui_theme.dart';

class _FakeBackend implements MediaDecoderBackend {
  @override
  MediaDecoder open(String resolvedPath) => _FakeDecoder();
}

class _FakeDecoder implements MediaDecoder {
  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    final Uint8List rgba = Uint8List(width * height * 4);
    for (int i = 0; i < rgba.length; i += 4) {
      rgba[i] = 38;
      rgba[i + 1] = 92;
      rgba[i + 2] = 158;
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

const String _source = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:shot:video/shot.mp4:0:0:300:1]
      [CUE:90]
        [DOSSIER:evidence:person.png:10:20:0:GRID:24,32,40:JOHN SMITH]
          Biography text.
        [/DOSSIER]
      [/CUE]
    [/CLIP]
  [/TRACK]
[/EDIT]
[STRUCT:EDIT.main]
''';

const String _truncatedSource = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:shot:video/shot.mp4:0:0:12:1]
      [CUE:8]
        [DOSSIER:evidence:person.png:10:20:0:SIDE_ONLY:24,32,40:JOHN SMITH]
          Biography text.
        [/DOSSIER]
      [/CUE]
    [/CLIP]
  [/TRACK]
[/EDIT]
[STRUCT:EDIT.main]
''';

String _resolve(String source) => '/workspace/$source';

Widget _preview({
  required String source,
  required StructuralSequencePlacement placement,
  required int localFrame,
  required MediaDecoderBackend backend,
}) {
  return MaterialApp(
    home: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 800,
        height: 500,
        child: StructuralSequencePreview(
          rawDocument: source,
          placement: placement,
          localFrame: localFrame,
          isPlaying: false,
          theme: R3Theme.of(Colors.green),
          wallpaper: null,
          backend: backend,
          resolveSource: _resolve,
        ),
      ),
    ),
  );
}

Future<void> _waitForReady(
  WidgetTester tester,
  String source,
  StructuralSequencePlacement placement,
  MediaDecoderBackend backend,
) async {
  await tester.pumpWidget(
    _preview(
      source: source,
      placement: placement,
      localFrame: 5,
      backend: backend,
    ),
  );
  await tester.pumpAndSettle();

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

void _expectRect(Rect actual, Rect expected) {
  expect(actual.left, closeTo(expected.left, 0.01));
  expect(actual.top, closeTo(expected.top, 0.01));
  expect(actual.width, closeTo(expected.width, 0.01));
  expect(actual.height, closeTo(expected.height, 0.01));
}

void main() {
  testWidgets(
    'DOSSIER evidence stage keeps one real STRUCT window in the left seat',
    (WidgetTester tester) async {
      final StructuralSequencePlacement placement =
          parseStructuralSequencePlacements(_source).single;
      final _FakeBackend backend = _FakeBackend();
      await _waitForReady(tester, _source, placement, backend);

      // DOSSIER local 38 is the first center/evidence showing frame:
      // opening 16 + split 10 + center transition 12.
      await tester.pumpWidget(
        _preview(
          source: _source,
          placement: placement,
          localFrame: placement.contentStartFrame + 128,
          backend: backend,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('structural-window-frame')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('structural-dossier-panel')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('structural-sidecard-panel')),
        findsNothing,
      );

      final EditVideoPreview client = tester.widget<EditVideoPreview>(
        find.byType(EditVideoPreview).first,
      );
      expect(client.renderSideCardsInClient, isFalse);

      const Rect renderFrame = Rect.fromLTWH(0, 25, 800, 450);
      final Rect expectedWindow = sideCardSeatedVideoWindowRect(
        renderFrame.size,
      ).shift(renderFrame.topLeft);
      final Rect actualWindow = tester.getRect(
        find.byKey(const ValueKey<String>('structural-window-positioned')),
      );
      _expectRect(actualWindow, expectedWindow);
    },
  );

  testWidgets(
    'EDIT end clips DOSSIER but STRUCT close starts from its displaced shell',
    (WidgetTester tester) async {
      final StructuralSequencePlacement placement =
          parseStructuralSequencePlacements(_truncatedSource).single;
      final _FakeBackend backend = _FakeBackend();
      await _waitForReady(tester, _truncatedSource, placement, backend);

      final int lastShowing = placement.contentStartFrame + 11;
      await tester.pumpWidget(
        _preview(
          source: _truncatedSource,
          placement: placement,
          localFrame: lastShowing,
          backend: backend,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('structural-dossier-panel')),
        findsOneWidget,
      );
      final Rect finalShowingRect = tester.getRect(
        find.byKey(const ValueKey<String>('structural-window-positioned')),
      );

      final int firstClosing = placement.closingStartFrame;
      await tester.pumpWidget(
        _preview(
          source: _truncatedSource,
          placement: placement,
          localFrame: firstClosing,
          backend: backend,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('structural-dossier-panel')),
        findsNothing,
      );
      final Rect firstClosingRect = tester.getRect(
        find.byKey(const ValueKey<String>('structural-window-positioned')),
      );
      _expectRect(firstClosingRect, finalShowingRect);
    },
  );
}
