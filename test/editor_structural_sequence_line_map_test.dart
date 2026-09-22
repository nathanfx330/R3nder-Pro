// ./test/editor_structural_sequence_line_map_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/editor_warmup.dart';
import 'package:r3nder/scene_engine.dart';
import 'package:r3nder/structural_sequence.dart';

void main() {
  test('editor simulation maps full STRUCT event to its authored line', () async {
    const String source = '''TEXT BEFORE
[EDIT:main]
[TRACK:V1]
[CLIP:late:video/late.mp4:5:0:3:1]
[/CLIP]
[/TRACK]
[/EDIT]
[STRUCT:EDIT.main]
TEXT AFTER
''';

    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(source).single;
    final SceneEngine scene = SceneEngine();

    try {
      final EditorSimResult result = await runEditorSimulation(
        scene,
        const EditorSimRequest(
          docText: source,
          fontColor: Colors.green,
          bgColor: Colors.black,
          engineWidth: 1920,
          engineHeight: 1080,
          engineScale: 1,
          fontFamily: 'monospace',
          fontSize: 24,
          lineSpacing: 1,
          tracking: 0,
          marginTop: 40,
          marginSide: 40,
          imagesDir: '/tmp/r3nder_struct_line_map_images',
          spritesDir: '/tmp/r3nder_struct_line_map_sprites',
          bedTargetFrames: 0,
        ),
      );

      final List<int?> starts = editorStructuralPlacementStarts(
        placements: <StructuralSequencePlacement>[placement],
        rawLineAtFrame: result.rawLineAtFrame,
      );
      final List<int> authoredFrames = <int>[
        for (int frame = 0; frame < result.rawLineAtFrame.length; frame++)
          if (editorStructuralPlacementAtFrame(
                placements: <StructuralSequencePlacement>[placement],
                placementStarts: starts,
                projectFrame: frame,
              ) !=
              null)
            frame,
      ];

      expect(placement.resolves, isTrue);
      expect(starts.single, isNotNull);
      expect(authoredFrames, isNotEmpty);
      expect(authoredFrames.length, placement.durationFrames);
      expect(authoredFrames.first, starts.single);

      for (int i = 1; i < authoredFrames.length; i++) {
        expect(authoredFrames[i], authoredFrames[i - 1] + 1);
      }

      // rawLineAtFrame is a parser/read-head navigation map, not the authored
      // structural clock. It may dwell on the STRUCT line for an extra
      // control-only parser frame, but every authored STRUCT frame must still
      // navigate back to the placement's source line.
      for (final int frame in authoredFrames) {
        expect(result.rawLineAtFrame[frame], placement.lineIndex);
      }
    } finally {
      scene.disposeImages();
    }
  });
}
