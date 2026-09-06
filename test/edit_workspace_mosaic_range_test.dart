// ./test/edit_workspace_mosaic_range_test.dart

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/edit_surface_model.dart';
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

const String _trimmedSource = '''[EDIT:main]
[TRACK:V1]
[CLIP:base:video/base.mp4:3:3:8:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';

void main() {
  test('trimmed EDIT remains intact when whole sequence is placed in MOSAIC pane',
      () {
    String next = EditSurfaceDocument.parse(_source, 'main').trimStart(
      'V1',
      'base',
      3,
    );
    next = EditSurfaceDocument.parse(next, 'main').trimEnd(
      'V1',
      'base',
      11,
    );

    EditDocumentModel model = EditDocumentModel.parse(next);
    final EditSequence edit = model.edit('main');
    final EditClip cut = edit.track('V1').clip('base');
    expect(cut.atFrame, 3);
    expect(cut.inFrame, 3);
    expect(cut.durationFrames, 8);
    expect(cut.sourceFrameAtProjectOffset(cut.durationFrames - 1), 10);
    expect(edit.projectFrameCount, 11);

    next = createEmptyMosaic(source: next, mosaicId: 'mosaic');
    MosaicSurfaceDocument mosaic =
        MosaicSurfaceDocument.parse(next, 'mosaic');
    expect(mosaic.mosaic.panes, hasLength(1));
    expect(mosaic.mosaic.panes.single.clips, isEmpty);

    next = mosaic.setPaneCount(3);
    mosaic = MosaicSurfaceDocument.parse(next, 'mosaic');
    expect(mosaic.mosaic.panes, hasLength(3));
    expect(
      mosaic.mosaic.panes.map((MosaicPane pane) => pane.id),
      <String>['pane1', 'pane2', 'pane3'],
    );

    next = mosaic.addClip(
      paneId: 'pane1',
      clipId: 'edit_main',
      structuralSource: 'EDIT.main',
      atFrame: 0,
      inFrame: 0,
      durationFrames: 11,
    );

    model = EditDocumentModel.parse(next);
    final EditClip assigned =
        model.mosaic('mosaic').pane('pane1').clip('edit_main');
    expect(assigned.source, 'EDIT.main');
    expect(assigned.atFrame, 0);
    expect(assigned.inFrame, 0);
    expect(assigned.durationFrames, 11);
    expect(assigned.speed, ExactClipSpeed(1));

    final EditClip preserved = model.edit('main').track('V1').clip('base');
    expect(preserved.atFrame, 3);
    expect(preserved.inFrame, 3);
    expect(preserved.durationFrames, 8);
  });

  testWidgets(
    'workspace shows trim data then places the whole EDIT sequence in a pane',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      String? latestSource;

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 1400,
            height: 900,
            child: EditWorkspace(
              source: _trimmedSource,
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

      final Finder baseLabel = find.text('base');
      expect(baseLabel, findsOneWidget);
      await tester.tapAt(tester.getCenter(baseLabel));
      await tester.pump();

      expect(find.text('SOURCE IN  F3'), findsOneWidget);
      expect(find.text('SOURCE OUT  F10'), findsOneWidget);
      expect(find.text('CUT  8F'), findsOneWidget);
      expect(find.text('TRIM IN'), findsOneWidget);
      expect(find.text('TRIM OUT'), findsOneWidget);
      expect(find.text('SEND TO MOSAIC'), findsNothing);

      await tester.tap(find.text('NEW MOSAIC'));
      await tester.pump();

      expect(find.text('1 PANE'), findsOneWidget);
      expect(find.text('2 PANES'), findsOneWidget);
      expect(find.text('3 PANES'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('mosaic-pane:pane1')),
        findsOneWidget,
      );
      expect(find.text('AT FRAME'), findsNothing);
      expect(find.text('DURATION'), findsNothing);

      await tester.tap(find.text('2 PANES'));
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('mosaic-pane:pane1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('mosaic-pane:pane2')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('mosaic-empty-pane:pane1')),
      );
      await tester.pump();

      final Finder editChoice = find.byKey(
        const ValueKey<String>('mosaic-edit-sequence:main'),
      );
      expect(editChoice, findsOneWidget);
      expect(find.text('EDIT.main'), findsOneWidget);
      expect(find.text('11 FRAMES'), findsOneWidget);
      await tester.tap(editChoice);
      await tester.pump();

      expect(latestSource, isNotNull);
      final EditDocumentModel model = EditDocumentModel.parse(latestSource!);
      final EditClip assigned =
          model.mosaic('mosaic').pane('pane1').clip('edit_main');
      expect(assigned.source, 'EDIT.main');
      expect(assigned.atFrame, 0);
      expect(assigned.inFrame, 0);
      expect(assigned.durationFrames, 11);

      final EditClip preserved = model.edit('main').track('V1').clip('base');
      expect(preserved.atFrame, 3);
      expect(preserved.inFrame, 3);
      expect(preserved.durationFrames, 8);

      final Finder sequenceCard = find.byKey(
        const ValueKey<String>('mosaic-cut-assignment:edit_main'),
      );
      expect(sequenceCard, findsOneWidget);
      expect(
        find.descendant(
          of: sequenceCard,
          matching: find.text('EDIT.main'),
        ),
        findsOneWidget,
      );
    },
  );
}
