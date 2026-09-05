// ./test/structural_sequence_resolved_empty_gate_test.dart

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_video_preview.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/structural_sequence.dart';
import 'package:r3nder/structural_sequence_preview.dart';
import 'package:r3nder/ui_theme.dart';

class _NeverNeededBackend implements MediaDecoderBackend {
  int opens = 0;

  @override
  MediaDecoder open(String resolvedPath) {
    opens += 1;
    return _NeverNeededDecoder();
  }
}

class _NeverNeededDecoder implements MediaDecoder {
  @override
  DecodedMediaFrame render(
    int requestedSourceFrame,
    int width,
    int height,
  ) {
    return DecodedMediaFrame(
      requestedSourceFrame: requestedSourceFrame,
      actualSourceFrame: requestedSourceFrame,
      width: width,
      height: height,
      stride: width * 4,
      rgba: Uint8List(width * height * 4),
    );
  }

  @override
  void dispose() {}
}

const String _source = '''[EDIT:main]
[TRACK:V1]
[CLIP:late:video/late.mp4:5:0:3:1]
[/CLIP]
[/TRACK]
[/EDIT]
[STRUCT:EDIT.main]
''';

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  int maxPumps = 20,
}) async {
  for (int i = 0; i < maxPumps && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

void main() {
  testWidgets(
    'EditVideoPreview reports a confirmed empty authored frame as resolved',
    (WidgetTester tester) async {
      final _NeverNeededBackend backend = _NeverNeededBackend();
      int ready = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 640,
            height: 360,
            child: EditVideoPreview(
              source: _source,
              structuralSource: 'EDIT.main',
              currentFrame: 0,
              theme: R3Theme.of(Colors.green),
              backend: backend,
              resolveSource: (String value) => value,
              onFirstFrameReady: () => ready += 1,
            ),
          ),
        ),
      );

      for (int i = 0; i < 20 && ready == 0; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }

      expect(ready, 1);
      expect(find.text('NO VIDEO AT FRAME 0'), findsOneWidget);
      expect(backend.opens, 0);
    },
  );

  testWidgets(
    'STRUCT opening releases terminal after empty frame zero resolves',
    (WidgetTester tester) async {
      final _NeverNeededBackend backend = _NeverNeededBackend();
      final StructuralSequencePlacement placement =
          parseStructuralSequencePlacements(_source).single;

      // Midway through authored opening. sourceFrameAt is still exactly zero,
      // which is intentionally empty because the first clip starts at frame 5.
      final int localFrame = kStructuralZoomFrames + 5;
      expect(placement.stageAt(localFrame), StructuralSequenceStage.opening);
      expect(placement.sourceFrameAt(localFrame), 0);

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 800,
            height: 450,
            child: StructuralSequencePreview(
              rawDocument: _source,
              placement: placement,
              localFrame: localFrame,
              isPlaying: false,
              theme: R3Theme.of(Colors.green),
              wallpaper: null,
              backend: backend,
              resolveSource: (String value) => value,
            ),
          ),
        ),
      );

      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('structural-first-frame-ready')),
      );

      expect(
        find.byKey(const ValueKey<String>('structural-first-frame-ready')),
        findsOneWidget,
      );

      final Opacity structuralOpacity = tester.widget<Opacity>(
        find.byKey(const ValueKey<String>('structural-window-opacity')),
      );
      final Opacity terminalOpacity = tester.widget<Opacity>(
        find.byKey(const ValueKey<String>('structural-terminal-opacity')),
      );

      expect(structuralOpacity.opacity, greaterThan(0.0));
      expect(terminalOpacity.opacity, lessThan(1.0));
      expect(find.text('NO VIDEO AT FRAME 0'), findsOneWidget);
      expect(backend.opens, 0);
    },
  );
}
