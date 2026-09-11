// ./test/text_structural_audio_boundary_test.dart
//
// Regression contract for TEXT STRUCT clip-audio placement.
//
// The purple MP4 lane in the TEXT ribbon and the program audio renderer must
// describe one boundary. Everything before that boundary is digital silence;
// the first source sample belongs exactly to the first showing frame.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/program_structural_audio.dart';
import 'package:r3nder/structural_audio_decode.dart';
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

void main() {
  test('TEXT STRUCT program audio starts at the picture content boundary',
      () async {
    final List<StructuralSequencePlacement> placements =
        parseStructuralSequencePlacements(_document);
    expect(placements, hasLength(1));

    final StructuralSequencePlacement placement = placements.single;
    expect(placement.clipAudio, isTrue);
    expect(placement.sourceDurationFrames, 3);

    final StructuralAudioPlan sourcePlan =
        StructuralAudioPlanner.parse(_document).plan('EDIT.main');
    expect(sourcePlan.durationFrames, placement.sourceDurationFrames);

    final Float32List sourcePcm = Float32List(
      sourcePlan.durationSamples * kStructuralAudioChannels,
    );
    for (int sampleFrame = 0;
        sampleFrame < sourcePlan.durationSamples;
        sampleFrame++) {
      sourcePcm[sampleFrame * 2] = 0.25;
      sourcePcm[sampleFrame * 2 + 1] = -0.25;
    }

    final StructuralAudioSourceRender source = StructuralAudioSourceRender(
      plan: sourcePlan,
      interleavedStereo: sourcePcm,
    );
    final ProgramStructuralAudioTimeline timeline = ProgramStructuralAudioTimeline(
      durationFrames: placement.durationFrames,
      occurrences: <ProgramStructuralAudioOccurrence>[
        ProgramStructuralAudioOccurrence(
          placementIndex: 0,
          sourceRef: placement.sourceRef,
          programStartFrame: placement.contentStartFrame,
          sourceDurationFrames: placement.sourceDurationFrames,
        ),
      ],
    );

    final ProgramStructuralAudioRender program =
        await ProgramStructuralAudioRenderer(
      timeline: timeline,
      renderSource: (String structuralSource) async {
        expect(structuralSource, placement.sourceRef.canonicalSource);
        return source;
      },
    ).render();

    final int boundarySample =
        structuralAudioSampleAtProjectFrame(placement.contentStartFrame);
    for (int sampleFrame = 0; sampleFrame < boundarySample; sampleFrame++) {
      expect(
        program.interleavedStereo[sampleFrame * 2],
        0.0,
        reason: 'Left channel became audible before the picture boundary.',
      );
      expect(
        program.interleavedStereo[sampleFrame * 2 + 1],
        0.0,
        reason: 'Right channel became audible before the picture boundary.',
      );
    }

    expect(program.interleavedStereo[boundarySample * 2], 0.25);
    expect(program.interleavedStereo[boundarySample * 2 + 1], -0.25);
  });
}
