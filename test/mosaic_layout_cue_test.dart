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

  test('parses OVERVIEW MAIN, ordered OTHERS, and cue-local ASPECT', () {
    const String source = '''[MOSAIC:wall]
  [LAYOUT:30:OVERVIEW:MAIN=left:OTHERS=right,third:ASPECT=4X3:DUR=18]
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
    final MosaicSequence mosaic = model.mosaic('wall');
    final MosaicLayoutCue cue =
        parseMosaicLayoutCues(source: source, mosaic: mosaic).single;

    expect(cue.state.kind, MosaicLayoutStateKind.overview);
    expect(cue.state.overviewMain, 'left');
    expect(cue.state.overviewOthers, <String>['right', 'third']);
    expect(cue.state.splitAspect, MosaicSplitClientAspect.aspect4x3);
    expect(cue.durationFrames, 18);
    expect(
      cue.formatTag(),
      '[LAYOUT:30:OVERVIEW:MAIN=left:OTHERS=right,third:ASPECT=4X3:DUR=18]',
    );
  });

  test('LAYOUT_START accepts OVERVIEW as a first-class stable state', () {
    final String source = baseSource.replaceFirst(
      '[MOSAIC:wall]\n',
      '[MOSAIC:wall]\n'
          '  [LAYOUT_START:OVERVIEW:MAIN=left:OTHERS=right,third]\n',
    );
    final EditDocumentModel model = EditDocumentModel.parse(source);
    final MosaicLayoutStart start = parseMosaicLayoutStart(
      source: source,
      mosaic: model.mosaic('wall'),
    )!;

    expect(start.state.kind, MosaicLayoutStateKind.overview);
    expect(start.state.overviewMain, 'left');
    expect(start.state.overviewOthers, <String>['right', 'third']);
    expect(
      start.formatTag(),
      '[LAYOUT_START:OVERVIEW:MAIN=left:OTHERS=right,third]',
    );
  });

  test('OVERVIEW parser rejects duplicate, repeated-main, and bad counts', () {
    String sourceWith(String tag) => baseSource.replaceFirst(
          '[MOSAIC:wall]\n',
          '[MOSAIC:wall]\n  $tag\n',
        );

    for (final String tag in <String>[
      '[LAYOUT:30:OVERVIEW:MAIN=left:OTHERS=right,right]',
      '[LAYOUT:30:OVERVIEW:MAIN=left:OTHERS=left,third]',
      '[LAYOUT:30:OVERVIEW:MAIN=left:OTHERS=]',
      '[LAYOUT:30:OVERVIEW:MAIN=left:OTHERS=right,third,left,extra]',
    ]) {
      final String source = sourceWith(tag);
      final EditDocumentModel model = EditDocumentModel.parse(source);
      expect(
        () => parseMosaicLayoutCues(
          source: source,
          mosaic: model.mosaic('wall'),
        ),
        throwsA(isA<MosaicLayoutFormatException>()),
        reason: tag,
      );
    }
  });

  test('OVERVIEW accepts MAIN plus one thumbnail on a two-pane MOSAIC', () {
    const String source = '''[MOSAIC:wall]
  [LAYOUT:30:OVERVIEW:MAIN=left:OTHERS=right]
  [PANE:left]
    [CLIP:l:video/left.mp4:0:0:120:1]
    [/CLIP]
  [/PANE]
  [PANE:right]
    [CLIP:r:video/right.mp4:0:0:120:1]
    [/CLIP]
  [/PANE]
[/MOSAIC]
''';
    final MosaicSequence mosaic = EditDocumentModel.parse(source).mosaic('wall');
    final MosaicLayoutCue cue =
        parseMosaicLayoutCues(source: source, mosaic: mosaic).single;

    expect(cue.state.overviewMain, 'left');
    expect(cue.state.overviewOthers, const <String>['right']);
    expect(
      validateMosaicLayoutCues(
        mosaic: mosaic,
        cues: <MosaicLayoutCue>[cue],
      ).isValid,
      isTrue,
    );
    expect(
      cue.formatTag(),
      '[LAYOUT:30:OVERVIEW:MAIN=left:OTHERS=right]',
    );
  });

  test('OVERVIEW semantic validation requires at least two MOSAIC panes', () {
    const String source = '''[MOSAIC:wall]
  [PANE:left]
    [CLIP:l:video/left.mp4:0:0:120:1]
    [/CLIP]
  [/PANE]
[/MOSAIC]
''';
    final MosaicSequence mosaic = EditDocumentModel.parse(source).mosaic('wall');
    final MosaicLayoutValidationResult validation = validateMosaicLayoutCues(
      mosaic: mosaic,
      cues: <MosaicLayoutCue>[
        MosaicLayoutCue(
          frame: 30,
          state: MosaicLayoutState.overview(
            mainPane: 'left',
            others: const <String>['right'],
          ),
        ),
      ],
    );

    expect(
      validation.errors.map((MosaicLayoutIssue issue) => issue.code),
      contains(MosaicLayoutIssueCode.overviewNeedsTwoPanes),
    );
  });

  test('parses LAYOUT_START separately from timeline cues', () {
    const String source = '''[MOSAIC:wall]
  [LAYOUT_START:TWOUP:A=left:B=third:MAX:ASPECT=4X3]
  [LAYOUT:30:ONE:PANE=left]
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
    final MosaicSequence mosaic = model.mosaic('wall');
    final MosaicLayoutStart? start =
        parseMosaicLayoutStart(source: source, mosaic: mosaic);
    final List<MosaicLayoutCue> cues =
        parseMosaicLayoutCues(source: source, mosaic: mosaic);

    expect(start, isNotNull);
    expect(start!.state.kind, MosaicLayoutStateKind.twoUp);
    expect(start.state.paneA, 'left');
    expect(start.state.paneB, 'third');
    expect(start.state.maximizeSplit, isTrue);
    expect(start.state.splitAspect, MosaicSplitClientAspect.aspect4x3);
    expect(
      start.formatTag(),
      '[LAYOUT_START:TWOUP:A=left:B=third:MAX:ASPECT=4X3]',
    );
    expect(cues, hasLength(1));
    expect(cues.single.frame, 30);
  });

  test('COME IN ON authoring migrates legacy F0 cue to LAYOUT_START', () {
    final String legacy = baseSource.replaceFirst(
      '[MOSAIC:wall]\n',
      '[MOSAIC:wall]\n  [LAYOUT:0:ONE:PANE=left]\n',
    );
    final MosaicSurfaceDocument document =
        MosaicSurfaceDocument.parse(legacy, 'wall');

    final String next = document.setInitialLayout(
      const MosaicLayoutState.one('right'),
    );

    expect(next, contains('[LAYOUT_START:ONE:PANE=right]'));
    expect(next, isNot(contains('[LAYOUT:0:')));
    final MosaicSurfaceDocument reparsed =
        MosaicSurfaceDocument.parse(next, 'wall');
    expect(reparsed.initialLayout!.state, const MosaicLayoutState.one('right'));
    expect(reparsed.layoutCues, isEmpty);
  });

  test('initial layout follows pane rename and blocks orphaning', () {
    final MosaicSurfaceDocument document =
        MosaicSurfaceDocument.parse(baseSource, 'wall');
    final String withStart = document.setInitialLayout(
      const MosaicLayoutState.full('third'),
    );

    final MosaicSurfaceDocument started =
        MosaicSurfaceDocument.parse(withStart, 'wall');
    expect(() => started.setPaneCount(2), throwsStateError);

    final String renamed = started.renamePane('third', 'witness');
    expect(renamed, contains('[LAYOUT_START:FULL:PANE=witness]'));
    expect(renamed, isNot(contains('[LAYOUT_START:FULL:PANE=third]')));
  });

  test('LAYOUT_START rejects transition duration', () {
    const String source = '''[MOSAIC:wall]
  [LAYOUT_START:ONE:PANE=left:DUR=12]
  [PANE:left]
    [CLIP:l:video/left.mp4:0:0:120:1]
    [/CLIP]
  [/PANE]
[/MOSAIC]
''';
    final EditDocumentModel model = EditDocumentModel.parse(source);
    expect(
      () => parseMosaicLayoutStart(
        source: source,
        mosaic: model.mosaic('wall'),
      ),
      throwsA(isA<MosaicLayoutFormatException>()),
    );
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
