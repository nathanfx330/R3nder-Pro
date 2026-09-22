// ./test/structural_split_placement_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_linter.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/mosaic_split_geometry.dart';
import 'package:r3nder/structural_chrome.dart';
import 'package:r3nder/structural_sequence.dart';

const String _supportedSource = '''[EDIT:left]
[TRACK:V1]
[CLIP:left_clip:video/left.mp4:0:0:30:1]
[/CLIP]
[/TRACK]
[/EDIT]
[EDIT:right]
[TRACK:V1]
[CLIP:right_clip:video/right.mp4:0:0:30:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:pane1]
[CLIP:left:EDIT.left:0:0:30:1]
[/CLIP]
[/PANE]
[PANE:pane2]
[CLIP:right:EDIT.right:0:0:30:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall:SPLIT:ASPECT=4X3:TITLE="Archive Monitor"]
''';

void main() {
  test('SPLIT grammar uses keyed aspect with implicit 16X9 default', () {
    final StructuralChromeSpec? defaultSplit =
        parseStructuralChromeTag('[STRUCT:MOSAIC.wall:SPLIT]');
    expect(defaultSplit, isNotNull);
    expect(defaultSplit!.splitWindows, isTrue);
    expect(defaultSplit.fullscreen, isFalse);
    expect(
      defaultSplit.splitAspect,
      MosaicSplitClientAspect.aspect16x9,
    );
    expect(
      formatStructuralChromeTag(defaultSplit),
      '[STRUCT:MOSAIC.wall:SPLIT]',
    );

    final StructuralChromeSpec? portrait = parseStructuralChromeTag(
      '[STRUCT:MOSAIC.wall:SPLIT:ASPECT=9X16:AUDIO]',
    );
    expect(portrait, isNotNull);
    expect(
      portrait!.splitAspect,
      MosaicSplitClientAspect.aspect9x16,
    );
    expect(portrait.clipAudio, isTrue);
    expect(
      formatStructuralChromeTag(portrait),
      '[STRUCT:MOSAIC.wall:SPLIT:ASPECT=9X16:AUDIO]',
    );
  });

  test('FULL and SPLIT are exclusive and ASPECT requires SPLIT', () {
    expect(
      parseStructuralChromeTag('[STRUCT:MOSAIC.wall:FULL:SPLIT]'),
      isNull,
    );
    expect(
      parseStructuralChromeTag('[STRUCT:MOSAIC.wall:ASPECT=4X3]'),
      isNull,
    );
    expect(
      parseStructuralChromeTag('[STRUCT:MOSAIC.wall:SPLIT:ASPECT=1X1]'),
      isNull,
    );
  });

  test('supported two-pane MOSAIC carries split state and stable titles', () {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_supportedSource).single;

    expect(placement.sourceRef.canonicalSource, 'MOSAIC.wall');
    expect(placement.presentationMode, StructuralPresentationMode.windowed);
    expect(placement.splitWindowRequested, isTrue);
    expect(placement.splitWindowSupported, isTrue);
    expect(placement.splitWindow, isTrue);
    expect(
      placement.splitClientAspect,
      MosaicSplitClientAspect.aspect4x3,
    );
    expect(placement.effectiveWindowTitle, 'Archive Monitor');
    expect(
      placement.splitWindowTitleForPane(0),
      'Archive Monitor · PANE 1',
    );
    expect(
      placement.splitWindowTitleForPane(1),
      'Archive Monitor · PANE 2',
    );
    expect(() => placement.splitWindowTitleForPane(2), throwsRangeError);
  });

  test('default split titles derive from canonical placement title convention',
      () {
    final String source = _supportedSource.replaceFirst(
      ':ASPECT=4X3:TITLE="Archive Monitor"',
      '',
    );
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(source).single;

    expect(placement.effectiveWindowTitle, 'MOSAIC.wall');
    expect(
      placement.splitWindowTitleForPane(0),
      'MOSAIC.wall · PANE 1',
    );
    expect(
      placement.splitWindowTitleForPane(1),
      'MOSAIC.wall · PANE 2',
    );
  });

  test('unsupported split requests stay authored and fall back windowed', () {
    const String source = '''[EDIT:single]
[TRACK:V1]
[CLIP:single_clip:video/single.mp4:0:0:30:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:one]
[PANE:pane1]
[CLIP:a:EDIT.single:0:0:30:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[MOSAIC:empty_right]
[PANE:pane1]
[CLIP:a:EDIT.single:0:0:30:1]
[/CLIP]
[/PANE]
[PANE:pane2]
[/PANE]
[/MOSAIC]
[STRUCT:EDIT.single:SPLIT]
[STRUCT:MOSAIC.one:SPLIT]
[STRUCT:MOSAIC.empty_right:SPLIT:ASPECT=9X16]
''';

    final List<StructuralSequencePlacement> placements =
        parseStructuralSequencePlacements(source);
    expect(placements, hasLength(3));

    for (final StructuralSequencePlacement placement in placements) {
      expect(placement.splitWindowRequested, isTrue);
      expect(placement.splitWindowSupported, isFalse);
      expect(placement.splitWindow, isFalse);
      expect(placement.fullscreen, isFalse);
      expect(
        placement.presentationMode,
        StructuralPresentationMode.windowed,
      );
    }
    expect(
      placements.last.splitClientAspect,
      MosaicSplitClientAspect.aspect9x16,
    );

    final EditLintResult lint =
        EditGraphLinter.lint(EditDocumentModel.parse(source));
    final List<EditLintIssue> splitWarnings = lint.warnings
        .where(
          (EditLintIssue issue) =>
              issue.code == EditLintCode.unsupportedSplitPlacement,
        )
        .toList(growable: false);

    expect(lint.isValid, isTrue);
    expect(splitWarnings, hasLength(3));
    expect(splitWarnings[0].message, contains('source is not a MOSAIC'));
    expect(splitWarnings[1].message, contains('1 panes instead of 2'));
    expect(splitWarnings[2].message, contains('one MOSAIC pane is empty'));
    expect(
      splitWarnings.every(
        (EditLintIssue issue) =>
            issue.message.contains('ordinary windowed presentation'),
      ),
      isTrue,
    );
  });
}
