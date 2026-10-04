// ./test/mosaic_overview_label_test.dart

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/mosaic_layout_program.dart';
import 'package:r3nder/structural_mosaic_layout.dart';
import 'package:r3nder/structural_sequence.dart';

const String _namedSource = '''[MOSAIC:wall]
[LAYOUT_START:OVERVIEW:MAIN=A:OTHERS=B,C,D]
[PANE:A]
[CLIP:a:video/a.mp4:0:0:120:1]
[/CLIP]
[/PANE]
[PANE:B]
[CLIP:b:video/b.mp4:0:0:120:1]
[/CLIP]
[/PANE]
[PANE:C]
[CLIP:c:video/c.mp4:0:0:120:1]
[/CLIP]
[/PANE]
[PANE:D]
[CLIP:d:video/d.mp4:0:0:120:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall:PANENAMES:NAME1="Camera A":NAME2="Witness":OVERLAY=NONE]
''';

const String _unnamedSource = '''[MOSAIC:wall]
[LAYOUT_START:OVERVIEW:MAIN=A:OTHERS=B,C,D]
[PANE:A]
[CLIP:a:video/a.mp4:0:0:120:1]
[/CLIP]
[/PANE]
[PANE:B]
[CLIP:b:video/b.mp4:0:0:120:1]
[/CLIP]
[/PANE]
[PANE:C]
[CLIP:c:video/c.mp4:0:0:120:1]
[/CLIP]
[/PANE]
[PANE:D]
[CLIP:d:video/d.mp4:0:0:120:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall:OVERLAY=NONE]
''';

MosaicLayoutFrame _frameFor(
  String source,
  StructuralSequencePlacement placement,
) {
  final EditDocumentModel model = EditDocumentModel.parse(source);
  final MosaicLayoutProgram program = MosaicLayoutProgram.fromMosaic(
    source: source,
    mosaic: model.mosaic('wall'),
  );
  final MosaicLayoutEvaluationContext context = structuralMosaicLayoutContext(
    programRect: const Rect.fromLTWH(0, 0, 1920, 1080),
    placement: placement,
    program: program,
    chromeScale: 1.0,
  );
  return program.resolve(context).evaluate(0);
}

void main() {
  test('OVERVIEW shelf labels reuse placement slot naming authority', () {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_namedSource).single;
    final MosaicLayoutFrame frame = _frameFor(_namedSource, placement);
    final Map<MosaicLayoutActorId, String> labels =
        structuralMosaicLayoutPaneLabels(
      frame: frame,
      placement: placement,
    );
    final Map<MosaicLayoutActorId, String> titles =
        structuralMosaicLayoutWindowTitles(
      frame: frame,
      placement: placement,
    );

    expect(labels[frame.pane('A').actorId], isNull);
    expect(labels[frame.pane('B').actorId], 'Camera A');
    expect(labels[frame.pane('C').actorId], 'Witness');
    expect(labels[frame.pane('D').actorId], 'PANE 3');
    expect(
      titles[frame.pane('A').actorId],
      placement.effectiveWindowTitle,
      reason: 'OVERVIEW MAIN keeps normal chrome title ownership',
    );
  });

  test('pane-name toggle changes text only, never OVERVIEW geometry', () {
    final StructuralSequencePlacement named =
        parseStructuralSequencePlacements(_namedSource).single;
    final StructuralSequencePlacement unnamed =
        parseStructuralSequencePlacements(_unnamedSource).single;
    final MosaicLayoutFrame namedFrame = _frameFor(_namedSource, named);
    final MosaicLayoutFrame unnamedFrame = _frameFor(_unnamedSource, unnamed);

    for (final String paneId in <String>['A', 'B', 'C', 'D']) {
      expect(namedFrame.pane(paneId).rect, unnamedFrame.pane(paneId).rect);
      expect(
        namedFrame.pane(paneId).labelRect,
        unnamedFrame.pane(paneId).labelRect,
      );
      expect(
        namedFrame.pane(paneId).labelOpacity,
        unnamedFrame.pane(paneId).labelOpacity,
      );
    }
    expect(
      structuralMosaicLayoutPaneLabels(
        frame: unnamedFrame,
        placement: unnamed,
      ),
      isEmpty,
    );
  });

  test('outer shell preserves label geometry and composes label opacity', () {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_namedSource).single;
    final MosaicLayoutFrame frame = _frameFor(_namedSource, placement);
    final MosaicLayoutFrame display = structuralMosaicLayoutOuterFrame(
      frame: frame,
      stage: StructuralSequenceStage.showing,
      stageProgress: 1.0,
      shellOpacity: 0.5,
    );

    expect(display.pane('B').labelRect, frame.pane('B').labelRect);
    expect(display.pane('B').labelOpacity, 0.5);
    expect(display.pane('A').labelOpacity, 0.0);
  });
}
