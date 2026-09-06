// ./test/structural_sequence_playback_profile_test.dart

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

const String _source = '''[EDIT:main]
[TRACK:V1]
[CLIP:solo:video/solo.mp4:0:0:12:1]
[#EDIT_TRANSITION:CROSSFADE:6]
[/CLIP]
[/TRACK]
[/EDIT]
[STRUCT:EDIT.main]
''';

String _resolveTestSource(String value) => '/workspace/$value';

Widget _preview({
  required StructuralSequencePlacement placement,
  required int localFrame,
  required bool isPlaying,
  required _FakeBackend backend,
}) {
  return MaterialApp(
    home: SizedBox(
      width: 800,
      height: 500,
      child: StructuralSequencePreview(
        rawDocument: _source,
        placement: placement,
        localFrame: localFrame,
        isPlaying: isPlaying,
        theme: R3Theme.of(Colors.green),
        wallpaper: null,
        backend: backend,
        resolveSource: _resolveTestSource,
      ),
    ),
  );
}

Future<void> _waitForFirstFrameReady(WidgetTester tester) async {
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
}

void main() {
  testWidgets(
      'playing STRUCT holds frame zero during opening without leaving moving decode profile',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_source).single;
    final _FakeBackend backend = _FakeBackend();

    await tester.pumpWidget(
      _preview(
        placement: placement,
        localFrame: kStructuralZoomFrames + 1,
        isPlaying: true,
        backend: backend,
      ),
    );

    EditVideoPreview video = tester.widget<EditVideoPreview>(
      find.byType(EditVideoPreview),
    );

    expect(
      placement.stageAt(kStructuralZoomFrames + 1),
      StructuralSequenceStage.opening,
    );
    expect(video.currentFrame, 0);
    expect(video.isPlaying, isFalse);
    expect(video.fastPreview, isTrue);

    // Readiness is deliberately independent from authored time. Wait for the
    // held frame-zero decode to become presentable before entering showing,
    // while keeping backend and resolver identities stable just like product.
    await _waitForFirstFrameReady(tester);

    await tester.pumpWidget(
      _preview(
        placement: placement,
        localFrame: kStructuralEntryFrames,
        isPlaying: true,
        backend: backend,
      ),
    );
    await tester.pump();

    video = tester.widget<EditVideoPreview>(find.byType(EditVideoPreview));

    expect(
      placement.stageAt(kStructuralEntryFrames),
      StructuralSequenceStage.showing,
    );
    expect(video.currentFrame, 0);
    expect(video.isPlaying, isTrue);
    expect(video.fastPreview, isTrue);
  });

  testWidgets('parked STRUCT preview keeps full decode profile',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_source).single;
    final _FakeBackend backend = _FakeBackend();

    await tester.pumpWidget(
      _preview(
        placement: placement,
        localFrame: kStructuralZoomFrames + 1,
        isPlaying: false,
        backend: backend,
      ),
    );

    final EditVideoPreview video = tester.widget<EditVideoPreview>(
      find.byType(EditVideoPreview),
    );

    expect(video.currentFrame, 0);
    expect(video.isPlaying, isFalse);
    expect(video.fastPreview, isFalse);
  });
}
