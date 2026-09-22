// ./test/structural_split_cue_policy_test.dart

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/card_overlay_state.dart';
import 'package:r3nder/edit_linter.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/presentation_requests.dart';
import 'package:r3nder/structural_sequence.dart';

const String _source = '''[MOSAIC:wall]
[PANE:left]
[CLIP:leftShot:video/left.mp4:0:0:40:1]
[/CLIP]
[/PANE]
[PANE:right]
[CLIP:rightShot:video/right.mp4:0:0:40:1]
[CUE:0]
[CARD:missing-card.png:8:12,34,56:CARD]
CARD BODY
[/CARD]
[/CUE]
[CUE:0]
[SIDECARD:missing-side.png:8:210,30,40:SIDE]
SIDE BODY
[/SIDECARD]
[/CUE]
[CUE:0]
[MAXIMIZE:8]
[/CUE]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall:SPLIT]
''';

void main() {
  test('split CARD maps to owning pane client while shell cues lint', () {
    final EditDocumentModel model = EditDocumentModel.parse(_source);
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_source).single;
    final StructuralSourceRef root =
        StructuralSourceRef.tryParse('MOSAIC.wall')!;

    expect(placement.splitWindow, isTrue);

    final List<StructuralCardOverlayPlacement> left =
        structuralCardOverlayPlacementsForMosaicPane(
      model,
      root,
      0,
      16,
    );
    final List<StructuralCardOverlayPlacement> right =
        structuralCardOverlayPlacementsForMosaicPane(
      model,
      root,
      1,
      16,
    );

    expect(left, isEmpty);
    expect(right, hasLength(2));
    expect(
      right.every(
        (StructuralCardOverlayPlacement p) =>
            p.normalizedRect == const Rect.fromLTWH(0, 0, 1, 1),
      ),
      isTrue,
    );

    final List<StructuralCardOverlayPlacement> cards = right
        .where((StructuralCardOverlayPlacement p) => !p.isSideCard)
        .toList(growable: false);
    expect(cards, hasLength(1));
    expect(cards.single.card.heading, 'CARD');
    expect(cards.single.card, isA<CardRequest>());

    final EditLintResult lint = EditGraphLinter.lint(model);
    expect(lint.isValid, isTrue);

    final List<EditLintIssue> sideWarnings = lint.warnings
        .where(
          (EditLintIssue issue) =>
              issue.code == EditLintCode.unsupportedSplitSideCard,
        )
        .toList(growable: false);
    final List<EditLintIssue> maximizeWarnings = lint.warnings
        .where(
          (EditLintIssue issue) =>
              issue.code == EditLintCode.unsupportedSplitMaximize,
        )
        .toList(growable: false);

    expect(sideWarnings, hasLength(1));
    expect(maximizeWarnings, hasLength(1));
    expect(sideWarnings.single.message, contains('will not paint'));
    expect(maximizeWarnings.single.message, contains('will not paint'));
    expect(
      sideWarnings.single.editPath,
      <String>['STRUCT', 'MOSAIC.wall', 'PANE.right', 'rightShot'],
    );
    expect(
      maximizeWarnings.single.editPath,
      <String>['STRUCT', 'MOSAIC.wall', 'PANE.right', 'rightShot'],
    );
  });

  test('unsupported SPLIT fallback does not apply split cue policy', () {
    const String source = '''[MOSAIC:wall]
[PANE:only]
[CLIP:shot:video/a.mp4:0:0:20:1]
[CUE:0]
[SIDECARD:missing-side.png:8:210,30,40:SIDE]
SIDE
[/SIDECARD]
[/CUE]
[CUE:0]
[MAXIMIZE:8]
[/CUE]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall:SPLIT]
''';

    final EditDocumentModel model = EditDocumentModel.parse(source);
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(source).single;
    expect(placement.splitWindowRequested, isTrue);
    expect(placement.splitWindow, isFalse);

    final EditLintResult lint = EditGraphLinter.lint(model);
    expect(
      lint.warnings.where(
        (EditLintIssue issue) =>
            issue.code == EditLintCode.unsupportedSplitSideCard ||
            issue.code == EditLintCode.unsupportedSplitMaximize,
      ),
      isEmpty,
    );
    expect(
      lint.warnings.any(
        (EditLintIssue issue) =>
            issue.code == EditLintCode.unsupportedSplitPlacement,
      ),
      isTrue,
    );
  });
}
