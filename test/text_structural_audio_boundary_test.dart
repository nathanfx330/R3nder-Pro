// ./test/text_structural_audio_boundary_test.dart
//
// Regression contract for TEXT STRUCT clip-audio placement.
//
// The purple MP4 lane in the TEXT ribbon and the program audio renderer must
// describe one boundary. Everything before that boundary is digital silence;
// the first source sample belongs exactly to the first showing frame.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/program_structural_audio.dart';
import 'package:r3nder/structural_audio_plan.dart';
import 'package:r3nder/structural_audio_render.dart';
import 'package:r3nder/structural_sequence.dart';

const String _document = '''[EDIT:main]
[TRACK:V1]
[CLIP:base:video/base.mp4:0:0:3:1]
[/CLIP]
[/TRACK]
[/EDIT]
[STRUCT:EDIT.main:AUDIO]
''';

class _ConstantLeafDecoder implements StructuralAudioLeafDecodeBackend {
  @override
  Future<StructuralAudioLeafDecode> decode(
    StructuralAudioSegment segment,
    String resolvedPath,
  ) async {
    final int frames = segment.sampleCount;
    final Float32List stereo = Float32List(frames * 2);
    for (int i = 0; i < frames; i++) {
      stereo[i * 2] = 0.25;
      stereo[i * 2 + 1] = -0.25;
    }

    return StructuralAudioLeafDecode(
      sourceInfo: StructuralAudioSourceInfo(
        path: resolvedPath,
        sourceFpsNumerator: 30,
        sourceFpsDenominator: 1,
        sampleRate: kStructuralAudioSampleRate,
        channels: 2,
        hasAudio: true,
      ),
      window: StructuralAudioDecodeWindow(
        requiredStartSampleFrame: 0,
        requiredSampleFrames: frames,
      ),
      authoredProjectSampleFrames: frames,
      interleavedStereo: stereo,
    );
  }
}

void main() {
  test('TEXT STRUCT audio is silent before the picture content boundary',
      () async {
    final List<StructuralSequencePlacement> placements =
        parseStructuralSequencePlacements(_document);
    expect(placements, hasLength(1));

    final StructuralSequencePlacement placement = placements.single;
    expect(placement.clipAudio, isTrue);
    expect(placement.sourceDurationFrames, 3);

    final StructuralAudioSourceRenderer sourceRenderer =
        StructuralAudioSourceRenderer(
      planner: StructuralAudioPlanner.parse(_document),
      leafDecoder: _ConstantLeafDecoder(),
      resolveSource: (String source) => source,
    );
    final StructuralAudioSourceRender source =
        await sourceRenderer.render('EDIT.main');

    final int programFrames = placement.durationFrames;
    final ProgramStructuralAudioTimeline timeline =
        ProgramStructuralAudioTimeline(
      durationFrames: programFrames,
      occurrences: <ProgramStructuralAudioOccurrence>[
        ProgramStructuralAudioOccurrence(
          placementIndex: 0,
          sourceRef: placement.sourceRef,
          programStartFrame: placement.contentStartFrame,
          sourceDurationFrames: placement.sourceDurationFrames,
        ),
      ],
    );

    final Float32List program = renderProgramStructuralAudio(
      timeline: timeline,
      sourceAudio: <String, StructuralAudioSourceRender>{
        placement.sourceRef.canonicalSource: source,
      },
    );

    final int boundarySample =
        structuralAudioSampleAtProjectFrame(placement.contentStartFrame);
    for (int sampleFrame = 0; sampleFrame < boundarySample; sampleFrame++) {
      expect(
        program[sampleFrame * 2],
        0.0,
        reason: 'Left channel became audible before the picture boundary.',
      );
      expect(
        program[sampleFrame * 2 + 1],
        0.0,
        reason: 'Right channel became audible before the picture boundary.',
      );
    }

    expect(program[boundarySample * 2], 0.25);
    expect(program[boundarySample * 2 + 1], -0.25);
  });
}
