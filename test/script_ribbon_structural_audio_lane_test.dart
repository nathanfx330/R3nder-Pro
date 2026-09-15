// ./test/script_ribbon_structural_audio_lane_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/script_nodes.dart';
import 'package:r3nder/script_ribbon.dart';
import 'package:r3nder/structural_sequence.dart';

const String _editRoot = '''[EDIT:main]
[TRACK:V1]
[CLIP:base:video/base.mp4:0:0:90:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';

const String _mosaicRoot = '''[EDIT:child]
[TRACK:V1]
[CLIP:base:video/base.mp4:0:0:90:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:left]
[CLIP:nested:EDIT.child:0:0:90:1]
[/CLIP]
[/PANE]
[/MOSAIC]
''';

List<ScriptNode> _nodes(
  String root,
  String structTag, {
  required int placementLine,
}) {
  final ScriptNode definitions = ScriptNode(
    type: 'RAW',
    rawText: root,
  )
    ..startLine = -1
    ..endLine = -1;

  final ScriptNode placement = ScriptNode(
    type: 'STRUCT',
    rawText: structTag,
  )
    ..startLine = placementLine
    ..endLine = placementLine;

  return <ScriptNode>[definitions, placement];
}

void main() {
  test('AUDIO EDIT STRUCT ribbon span starts at the picture content boundary', () {
    const String structTag = '[STRUCT:EDIT.main:AUDIO]';
    final String document = '$_editRoot$structTag';
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(document).single;

    final List<RibbonBlock> blocks = buildRibbonBlocks(
      _nodes(_editRoot, structTag, placementLine: 6),
      List<int>.filled(placement.durationFrames, 6),
    );

    expect(blocks, hasLength(1));
    final RibbonBlock block = blocks.single;
    expect(block.type, 'STRUCT');
    expect(block.startFrame, 0);
    expect(block.endFrame, placement.durationFrames);
    expect(block.hasClipAudio, isTrue);
    expect(block.clipAudioStartFrame, placement.contentStartFrame);
    expect(
      block.clipAudioEndFrameExclusive,
      placement.contentStartFrame + placement.sourceDurationFrames,
    );
    expect(block.clipAudioFrames, placement.sourceDurationFrames);
  });

  test('AUDIO MOSAIC STRUCT exposes the nested EDIT clip audio ribbon span', () {
    const String structTag = '[STRUCT:MOSAIC.wall:AUDIO]';
    final String document = '$_mosaicRoot$structTag';
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(document).single;

    final List<RibbonBlock> blocks = buildRibbonBlocks(
      _nodes(_mosaicRoot, structTag, placementLine: 12),
      List<int>.filled(placement.durationFrames, 12),
    );

    expect(blocks, hasLength(1));
    final RibbonBlock block = blocks.single;
    expect(block.type, 'STRUCT');
    expect(block.hasClipAudio, isTrue);
    expect(block.clipAudioStartFrame, placement.contentStartFrame);
    expect(
      block.clipAudioEndFrameExclusive,
      placement.contentStartFrame + placement.sourceDurationFrames,
    );
    expect(block.clipAudioFrames, 90);
  });

  test('STRUCT without AUDIO does not create an MP4 audio lane span', () {
    const String structTag = '[STRUCT:EDIT.main]';
    final String document = '$_editRoot$structTag';
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(document).single;

    final List<RibbonBlock> blocks = buildRibbonBlocks(
      _nodes(_editRoot, structTag, placementLine: 6),
      List<int>.filled(placement.durationFrames, 6),
    );

    expect(blocks, hasLength(1));
    expect(blocks.single.hasClipAudio, isFalse);
    expect(blocks.single.clipAudioStartFrame, isNull);
    expect(blocks.single.clipAudioEndFrameExclusive, isNull);
  });
}
