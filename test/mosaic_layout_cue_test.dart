// ./test/mosaic_layout_cue_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/mosaic_layout_cue.dart';
import 'package:r3nder/mosaic_split_geometry.dart';
import 'package:r3nder/mosaic_surface_model.dart';

void main() {
  const String baseSource = '''[MOSAIC:wall]
  [PANE:left]
    [CLIP:l:video/left.mp4:0:0:120:1]
    [/CLIP]
  [/PANE]
  [PANE:right]
    [CLIP:r:video/right.mp4:0:0:120:1]
    [/CLIP]
  [/PANE]
  [PANE:third]
    [CLIP:t:video/third.mp4:0:0:120:1]
    [/CLIP]
  [/PANE]
[/MOSAIC]
''';

  test('parses keyed TWOUP options and preserves syntax span', () {
    const String source = '''[MOSAIC:wall]
  [LAYOUT:30:TWOUP:A=left:B=third:MAX:ASPECT=4X3:DUR=18]
  [PANE:left]
    [CLIP:l:video/left.mp4:0:0:120:1]
    [/CLIP]
  [/PANE]
  [PANE:right]
    [CLIP:r:video/right.mp4:0:0:120:1]
    [/CLIP]
  [/PANE]
  [PANE:third]
    [CLIP:t:video/third.mp4:0:0:120:1]
    [/CLIP]
  [/PANE]
[/MOSAIC]
''';

    final EditDocumentModel model = EditDocumentModel.parse(source);
    final List<MosaicLayoutCue> cues = parseMosaicLayoutCues(
      source: source,
      mosaic: model.mosaic('wall'),
    );

    expect(cues, hasLength(1));
    expect(cues.single.frame, 30);
    expect(cues.single.durationFrames, 18);
    expect(cues.single.state.kind, MosaicLayoutStateKind.twoUp);
    expect(cues.single.state.paneA, 'left');
    expect(cues.single.state.paneB, 'third');
    expect(cues.single.state.maximizeSplit, isTrue);
    expect(cues.single.state.splitAspect, MosaicSplitClientAspect.aspect4x3);
    expect(
      cues.single.formatTag(),
      '[LAYOUT:30:TWOUP:A=left:B=third:MAX:ASPECT=4X3:DUR=18]',
    );
    expect(cues.single.sourceSpan, isNotNull);
  });

  test('unknown pane stays parseable but is a semantic error', () {
    const String source = '''[MOSAIC:wall]
  [LAYOUT:30:ONE:PANE=missing]
  [PANE:left]
    [CLIP:l:video/left.mp4:0:0:120:1]
    [/CLIP]
  [/PANE]
[/MOSAIC]
''';

    final MosaicSurfaceDocument document =
        MosaicSurfaceDocument.parse(source, 'wall');

    expect(document.layoutCues, hasLength(1));
    expect(document.layoutValidation.isValid, isFalse);
    expect(
      document.layoutValidation.errors.single.code,
      MosaicLayoutIssueCode.unknownPane,
    );
  });

  test('authoring expands bare TWOUP to explicit stable pane ids', () {
    final MosaicSurfaceDocument document =
        MosaicSurfaceDocument.parse(baseSource, 'wall');

    final String next = document.addLayoutCue(
      frame: 30,
      state: const MosaicLayoutState.twoUp(),
    );

    expect(
      next,
      contains('[LAYOUT:30:TWOUP:A=left:B=right]'),
    );
    final MosaicSurfaceDocument reparsed =
        MosaicSurfaceDocument.parse(next, 'wall');
    expect(reparsed.layoutValidation.isValid, isTrue);
    expect(reparsed.layoutCues.single.state.paneA, 'left');
    expect(reparsed.layoutCues.single.state.paneB, 'right');
  });

  test('pane rename atomically rewrites explicit LAYOUT references', () {
    final MosaicSurfaceDocument document =
        MosaicSurfaceDocument.parse(baseSource, 'wall');
    final String withCue = document.addLayoutCue(
      frame: 30,
      state: const MosaicLayoutState.twoUp(
        paneA: 'left',
        paneB: 'third',
      ),
    );

    final String renamed =
        MosaicSurfaceDocument.parse(withCue, 'wall').renamePane(
      'third',
      'witness',
    );

    expect(renamed, contains('[PANE:witness]'));
    expect(
      renamed,
      contains('[LAYOUT:30:TWOUP:A=left:B=witness]'),
    );
    final MosaicSurfaceDocument reparsed =
        MosaicSurfaceDocument.parse(renamed, 'wall');
    expect(reparsed.layoutValidation.isValid, isTrue);
    expect(reparsed.pane('witness').id, 'witness');
  });

  test('pane removal refuses to orphan a LAYOUT cue', () {
    final MosaicSurfaceDocument document =
        MosaicSurfaceDocument.parse(baseSource, 'wall');
    final String withCue = document.addLayoutCue(
      frame: 30,
      state: const MosaicLayoutState.full('third'),
    );

    expect(
      () => MosaicSurfaceDocument.parse(withCue, 'wall').setPaneCount(2),
      throwsStateError,
    );
  });

  test('update and remove rewrite only the selected LAYOUT line', () {
    final MosaicSurfaceDocument document =
        MosaicSurfaceDocument.parse(baseSource, 'wall');
    final String withCue = document.addLayoutCue(
      frame: 20,
      state: const MosaicLayoutState.one('left'),
    );
    final MosaicSurfaceDocument once =
        MosaicSurfaceDocument.parse(withCue, 'wall');

    final String updated = once.updateLayoutCue(
      20,
      frame: 24,
      state: const MosaicLayoutState.full('right'),
      durationFrames: 18,
    );
    expect(
      updated,
      contains('[LAYOUT:24:FULL:PANE=right:DUR=18]'),
    );
    expect(updated, isNot(contains('[LAYOUT:20:')));

    final String removed =
        MosaicSurfaceDocument.parse(updated, 'wall').removeLayoutCue(24);
    expect(removed, isNot(contains('[LAYOUT:')));
    expect(EditDocumentModel.parse(removed).mosaic('wall').panes, hasLength(3));
  });
  test('malformed direct LAYOUT is rejected instead of silently ignored', () {
    const String source = '''[MOSAIC:wall]
  [LAYOUT:30:ONE:PANE=left
  [PANE:left]
    [CLIP:l:video/left.mp4:0:0:120:1]
    [/CLIP]
  [/PANE]
[/MOSAIC]
''';

    final EditDocumentModel model = EditDocumentModel.parse(source);
    expect(
      () => parseMosaicLayoutCues(
        source: source,
        mosaic: model.mosaic('wall'),
      ),
      throwsA(isA<MosaicLayoutFormatException>()),
    );
  });

  test('LAYOUT-looking text inside a PANE body is not MOSAIC metadata', () {
    const String source = '''[MOSAIC:wall]
  [PANE:left]
    [CLIP:l:video/left.mp4:0:0:120:1]
[LAYOUT:30:ONE:PANE=missing]
    [/CLIP]
  [/PANE]
[/MOSAIC]
''';

    final EditDocumentModel model = EditDocumentModel.parse(source);
    expect(
      parseMosaicLayoutCues(
        source: source,
        mosaic: model.mosaic('wall'),
      ),
      isEmpty,
    );
  });

}
