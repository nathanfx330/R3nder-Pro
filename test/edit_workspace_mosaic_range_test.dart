// ./test/edit_workspace_mosaic_range_test.dart

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/edit_workspace.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/mosaic_surface_model.dart';
import 'package:r3nder/ui_theme.dart';

class _RangeTestBackend implements MediaDecoderBackend {
  @override
  MediaDecoder open(String resolvedPath) => _RangeTestDecoder();
}

class _RangeTestDecoder implements MediaDecoder {
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
[CLIP:base:video/base.mp4:0:0:20:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';

void main() {
  test('createMosaicWithSource authors the requested source in frame', () {
    final String next = createMosaicWithSource(
      source: _source,
      mosaicId: 'mosaic',
      paneId: 'pane',
      clipId: 'source',
      structuralSource: 'EDIT.main',
      inFrame: 4,
      durationFrames: 6,
    );

    final EditClip clip = EditDocumentModel.parse(next)
        .mosaic('mosaic')
        .pane('pane')
        .clip('source');

    expect(clip.source, 'EDIT.main');
    expect(clip.atFrame, 0);
    expect(clip.inFrame, 4);
    expect(clip.durationFrames, 6);
  });

  testWidgets(
    'SET IN and SET OUT send only the marked edit range to a new mosaic',
    (WidgetTester tester) async {
      String? latestSource;

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 1400,
            height: 900,
            child: EditWorkspace(
              source: _source,
              currentFrame: 3,
              theme: R3Theme.of(Colors.green),
              onSourceChanged: (String value) => latestSource = value,
              onSeek: (_) {},
              backend: _RangeTestBackend(),
              resolveSource: (String value) => value,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('IN F0   OUT F19   20F'), findsOneWidget);

      await tester.tap(find.text('SET IN'));
      await tester.pump();
      expect(find.text('IN F3   OUT F19   17F'), findsOneWidget);

      final Finder ruler = find.byKey(const ValueKey<String>('edit-timeline-scrub'));
      expect(ruler, findsOneWidget);
      final RenderBox rulerBox = tester.renderObject<RenderBox>(ruler);
      await tester.tapAt(rulerBox.localToGlobal(const Offset(20, 10)));
      await tester.pump();

      await tester.tap(find.text('SET OUT'));
      await tester.pump();
      expect(find.text('IN F3   OUT F10   8F'), findsOneWidget);

      await tester.tap(find.text('SEND TO MOSAIC'));
      await tester.pump();

      expect(latestSource, isNotNull);
      final EditDocumentModel model = EditDocumentModel.parse(latestSource!);
      final EditClip clip = model.mosaic('mosaic').pane('pane').clip('source');
      expect(clip.source, 'EDIT.main');
      expect(clip.inFrame, 3);
      expect(clip.durationFrames, 8);

      expect(find.byKey(const ValueKey<String>('mosaic-pane:pane')), findsOneWidget);
    },
  );
}
