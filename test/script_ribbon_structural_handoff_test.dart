// ./test/script_ribbon_structural_handoff_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/script_nodes.dart';
import 'package:r3nder/script_ribbon.dart';

void main() {
  test('unmapped presentation handoff stays with previous ribbon event', () {
    final ScriptNode app = ScriptNode(
      type: 'APP',
      rawText: '[APP:dos:40:Photos:MOSAIC]',
    )
      ..startLine = 0
      ..endLine = 0;

    final ScriptNode structural = ScriptNode(
      type: 'STRUCT',
      rawText: '[STRUCT:EDIT.main]',
    )
      ..startLine = 1
      ..endLine = 1;

    final List<RibbonBlock> blocks = buildRibbonBlocks(
      <ScriptNode>[app, structural],
      <int>[
        0,
        0,
        0,
        -1,
        -1,
        -1,
        1,
        1,
        1,
        1,
      ],
    );

    expect(blocks, hasLength(2));

    expect(blocks[0].type, 'APP');
    expect(blocks[0].startFrame, 0);
    expect(blocks[0].endFrame, 6);

    expect(blocks[1].type, 'STRUCT');
    expect(blocks[1].startFrame, 6);
    expect(blocks[1].endFrame, 10);

    expect(blocks[0].endFrame, blocks[1].startFrame);
  });

  test('leading unmapped time is not invented onto the first node', () {
    final ScriptNode app = ScriptNode(
      type: 'APP',
      rawText: '[APP:dos:40:Photos:MOSAIC]',
    )
      ..startLine = 0
      ..endLine = 0;

    final List<RibbonBlock> blocks = buildRibbonBlocks(
      <ScriptNode>[app],
      <int>[-1, -1, 0, 0],
    );

    expect(blocks, hasLength(1));
    expect(blocks.single.startFrame, 2);
    expect(blocks.single.endFrame, 4);
  });

  test('engine end hold remains outside authored ribbon ownership', () {
    final ScriptNode structural = ScriptNode(
      type: 'STRUCT',
      rawText: '[STRUCT:EDIT.main]',
    )
      ..startLine = 0
      ..endLine = 0;

    final List<RibbonBlock> blocks = buildRibbonBlocks(
      <ScriptNode>[structural],
      <int>[0, 0, -1, -1, -1],
      endHoldStartFrame: 2,
    );

    expect(blocks, hasLength(1));
    expect(blocks.single.startFrame, 0);
    expect(blocks.single.endFrame, 2);
  });
}
