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

Widget _preview({
  required StructuralSequencePlacement placement,
  required int localFrame,
  required bool isPlaying,
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
        backend: _FakeBackend(),
        resolveSource: (String value) => '/workspace/$value',
      ),
    ),
  );
}

void main() {
  testWidgets(
      'playing STRUCT holds frame zero during opening without leaving moving decode profile',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_source).single;

    await tester.pumpWidget(
      _preview(
        placement: placement,
        localFrame: kStructuralZoomFrames + 1,
        isPlaying: true,
      ),
    );

    EditVideoPreview video = tester.widget<EditVideoPreview>(
      find.byType(EditVideoPreview),
    );

    expect(placement.stageAt(kStructuralZoomFrames + 1),
        StructuralSequenceStage.opening);
    expect(video.currentFrame, 0);
    expect(video.isPlaying, isFalse);
    expect(video.fastPreview, isTrue);

    await tester.pumpWidget(
      _preview(
        placement: placement,
        localFrame: kStructuralEntryFrames,
        isPlaying: true,
      ),
    );

    video = tester.widget<EditVideoPreview>(find.byType(EditVideoPreview));

    expect(placement.stageAt(kStructuralEntryFrames),
        StructuralSequenceStage.showing);
    expect(video.currentFrame, 0);
    expect(video.isPlaying, isTrue);
    expect(video.fastPreview, isTrue);
  });

  testWidgets('parked STRUCT preview keeps full decode profile',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_source).single;

    await tester.pumpWidget(
      _preview(
        placement: placement,
        localFrame: kStructuralZoomFrames + 1,
        isPlaying: false,
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
