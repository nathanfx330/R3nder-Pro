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
    expect(defaultSplit.showPaneNames, isFalse);
    expect(defaultSplit.pane1Name, isEmpty);
    expect(defaultSplit.pane2Name, isEmpty);
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

  test('pane names are opt-in and preserve dormant authored values', () {
    final StructuralChromeSpec? hidden = parseStructuralChromeTag(
      '[STRUCT:MOSAIC.wall:SPLIT:NAME1="Camera A":NAME2="Witness"]',
    );
    expect(hidden, isNotNull);
    expect(hidden!.showPaneNames, isFalse);
    expect(hidden.pane1Name, 'Camera A');
    expect(hidden.pane2Name, 'Witness');
    expect(
      formatStructuralChromeTag(hidden),
      '[STRUCT:MOSAIC.wall:SPLIT:NAME1="Camera A":NAME2="Witness"]',
    );

    final StructuralChromeSpec? shown = parseStructuralChromeTag(
      '[STRUCT:MOSAIC.wall:SPLIT:PANENAMES:NAME1="Camera A":NAME2="Witness"]',
    );
    expect(shown, isNotNull);
    expect(shown!.showPaneNames, isTrue);
    expect(shown.pane1Name, 'Camera A');
    expect(shown.pane2Name, 'Witness');

    final StructuralChromeSpec? dormant = parseStructuralChromeTag(
      '[STRUCT:MOSAIC.wall:FULL:PANENAMES:NAME1="Camera A":NAME2="Witness"]',
    );
    expect(dormant, isNotNull);
    expect(dormant!.fullscreen, isTrue);
    expect(dormant.splitWindows, isFalse);
    expect(dormant.showPaneNames, isTrue);
    expect(
      formatStructuralChromeTag(dormant),
      '[STRUCT:MOSAIC.wall:FULL:PANENAMES:NAME1="Camera A":NAME2="Witness"]',
    );
  });

  test('MAX is placement-owned, SPLIT-only, and preserves dormant aspect', () {
    final StructuralChromeSpec? max = parseStructuralChromeTag(
      '[STRUCT:MOSAIC.wall:SPLIT:MAX:ASPECT=4X3]',
    );
    expect(max, isNotNull);
    expect(max!.splitWindows, isTrue);
    expect(max.maximizeSplit, isTrue);
    expect(max.splitAspect, MosaicSplitClientAspect.aspect4x3);
    expect(
      formatStructuralChromeTag(max),
      '[STRUCT:MOSAIC.wall:SPLIT:MAX:ASPECT=4X3]',
    );

    expect(
      parseStructuralChromeTag('[STRUCT:MOSAIC.wall:MAX]'),
      isNull,
    );
    expect(
      () => formatStructuralChromeTag(
        const StructuralChromeSpec(
          source: 'MOSAIC.wall',
          maximizeSplit: true,
        ),
      ),
      throwsArgumentError,
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

  test('supported two-pane MOSAIC hides pane-name suffixes by default', () {
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
    expect(placement.showPaneNames, isFalse);
    expect(placement.splitWindowTitleForPane(0), 'Archive Monitor');
    expect(placement.splitWindowTitleForPane(1), 'Archive Monitor');
    expect(() => placement.splitWindowTitleForPane(2), throwsRangeError);
  });

  test('enabled pane names use authored values and blank fallbacks', () {
    final String customSource = _supportedSource.replaceFirst(
      ':SPLIT:ASPECT=4X3:TITLE="Archive Monitor"',
      ':SPLIT:ASPECT=4X3:PANENAMES:NAME1="Camera A":NAME2="Witness":TITLE="Archive Monitor"',
    );
    final StructuralSequencePlacement custom =
        parseStructuralSequencePlacements(customSource).single;

    expect(custom.showPaneNames, isTrue);
    expect(custom.pane1Name, 'Camera A');
    expect(custom.pane2Name, 'Witness');
    expect(custom.splitWindowTitleForPane(0), 'Archive Monitor · Camera A');
    expect(custom.splitWindowTitleForPane(1), 'Archive Monitor · Witness');

    final String fallbackSource = _supportedSource.replaceFirst(
      ':SPLIT:ASPECT=4X3:TITLE="Archive Monitor"',
      ':SPLIT:ASPECT=4X3:PANENAMES:TITLE="Archive Monitor"',
    );
    final StructuralSequencePlacement fallback =
        parseStructuralSequencePlacements(fallbackSource).single;

    expect(fallback.splitWindowTitleForPane(0), 'Archive Monitor · PANE 1');
    expect(fallback.splitWindowTitleForPane(1), 'Archive Monitor · PANE 2');
  });

  test('supported MAX split reaches the effective placement', () {
    final String source = _supportedSource.replaceFirst(
      ':SPLIT:ASPECT=4X3',
      ':SPLIT:MAX:ASPECT=4X3',
    );
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(source).single;

    expect(placement.splitWindow, isTrue);
    expect(placement.maximizeSplit, isTrue);
    expect(
      placement.splitClientAspect,
      MosaicSplitClientAspect.aspect4x3,
    );
    expect(placement.presentationShape, StructuralPresentationShape.split);
  });

  test('hidden pane names keep the canonical placement title on both windows',
      () {
    final String source = _supportedSource.replaceFirst(
      ':ASPECT=4X3:TITLE="Archive Monitor"',
      '',
    );
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(source).single;

    expect(placement.effectiveWindowTitle, 'MOSAIC.wall');
    expect(placement.splitWindowTitleForPane(0), 'MOSAIC.wall');
    expect(placement.splitWindowTitleForPane(1), 'MOSAIC.wall');
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
    expect(
      splitWarnings.every(
        (EditLintIssue issue) =>
            issue.message.contains(
              '${kStructuralWindowFrames * 2} frames across two neighbors',
            ),
      ),
      isTrue,
    );
  });
}
