// ./test/structural_audio_gain_test.dart

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/program_structural_audio.dart';
import 'package:r3nder/structural_audio_decode.dart';
import 'package:r3nder/structural_audio_plan.dart';
import 'package:r3nder/structural_audio_render.dart';

class _ConstantLeafDecoder implements StructuralAudioLeafDecodeBackend {
  final double Function(String path) valueForPath;

  const _ConstantLeafDecoder(this.valueForPath);

  @override
  Future<StructuralAudioLeafDecode> decode(
    StructuralAudioSegment segment,
    String resolvedPath,
  ) async {
    final StructuralAudioSourceInfo info = StructuralAudioSourceInfo.audio(
      path: resolvedPath,
      sourceFpsNumerator: 30,
      sourceFpsDenominator: 1,
      audioSampleRate: 48000,
      audioChannels: 2,
      audioChannelLayout: 'stereo',
    );
    final StructuralAudioDecodeWindow window =
        StructuralAudioDecodeWindow.forSegment(segment, info);
    final double value = valueForPath(resolvedPath);
    final Float32List pcm = Float32List(
      window.requiredSampleFrames * kStructuralAudioChannels,
    );
    for (int i = 0; i < pcm.length; i++) {
      pcm[i] = value;
    }
    return StructuralAudioLeafDecode.decoded(
      sourceInfo: info,
      authoredProjectSampleFrames: segment.sampleCount,
      window: window,
      interleavedStereo: pcm,
    );
  }
}

Future<StructuralAudioSourceRender> _render(
  String script,
  String source, {
  double Function(String path)? valueForPath,
}) {
  return StructuralAudioSourceRenderer(
    planner: StructuralAudioPlanner.parse(script),
    leafDecoder: _ConstantLeafDecoder(valueForPath ?? (_) => 1.0),
    resolveSource: (String authored) => '/workspace/$authored',
  ).render(source);
}

double _leftAt(StructuralAudioSourceRender render, int sampleFrame) {
  return render.interleavedStereo[sampleFrame * kStructuralAudioChannels];
}

void main() {
  test('-6.0 dB maps a unit source sample to the exact logarithmic scalar',
      () async {
    const String script = '''[EDIT:main]
[TRACK:V1]
[CLIP:a:video/a.mp4:0:0:1:1:GAIN=-6.0]
[/CLIP]
[/TRACK]
[/EDIT]
''';
    final StructuralAudioSourceRender render =
        await _render(script, 'EDIT.main');
    final double expected = math.pow(10.0, -6.0 / 20.0).toDouble();

    expect(_leftAt(render, 0), closeTo(expected, 1e-7));
    expect(_leftAt(render, 799), closeTo(expected, 1e-7));
    expect(_leftAt(render, 1599), closeTo(expected, 1e-7));
  });

  test('constant gain composes multiplicatively with the fade envelope',
      () async {
    const String script = '''[EDIT:main]
[TRACK:V1]
[CLIP:a:video/a.mp4:0:0:2:1]
[#EDIT_TRANSITION_OUT:CROSSFADE:1]
[/CLIP]
[CLIP:b:video/b.mp4:1:0:2:1:GAIN=-6.0]
[#EDIT_TRANSITION:CROSSFADE:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';
    final StructuralAudioSourceRender render = await _render(
      script,
      'EDIT.main',
      valueForPath: (String path) => path.endsWith('/a.mp4') ? 0.0 : 1.0,
    );
    final double gain = math.pow(10.0, -6.0 / 20.0).toDouble();
    const int fadeOffset = 800;
    final double t = (fadeOffset + 0.5) / 1600.0;
    final double expected = gain * math.sin(t * math.pi / 2.0);

    expect(
      _leftAt(render, 1600 + fadeOffset),
      closeTo(expected, 1e-6),
    );
  });

  test('MUTE wins over GAIN and produces exact digital zero', () async {
    const String script = '''[EDIT:main]
[TRACK:V1]
[CLIP:a:video/a.mp4:0:0:1:1:GAIN=12.0:MUTE]
[/CLIP]
[/TRACK]
[/EDIT]
''';
    final StructuralAudioSourceRender render =
        await _render(script, 'EDIT.main');

    expect(
      render.interleavedStereo.every((double sample) => sample == 0.0),
      isTrue,
    );
  });

  test('nested structural gain composes at child and parent placements',
      () async {
    const String script = '''[EDIT:child]
[TRACK:V1]
[CLIP:leaf:video/a.mp4:0:0:1:1:GAIN=-6.0]
[/CLIP]
[/TRACK]
[/EDIT]
[EDIT:parent]
[TRACK:V1]
[CLIP:nested:EDIT.child:0:0:1:1:GAIN=-6.0]
[/CLIP]
[/TRACK]
[/EDIT]
''';
    final StructuralAudioSourceRender render =
        await _render(script, 'EDIT.parent');
    final double oneGain = math.pow(10.0, -6.0 / 20.0).toDouble();

    expect(_leftAt(render, 0), closeTo(oneGain * oneGain, 1e-7));
  });

  test('program PCM receives gained source PCM before preview or bake diverge',
      () async {
    const String script = '''[EDIT:main]
[TRACK:V1]
[CLIP:a:video/a.mp4:0:0:1:1:GAIN=-6.0]
[/CLIP]
[/TRACK]
[/EDIT]
''';
    final StructuralAudioSourceRender sourceRender =
        await _render(script, 'EDIT.main');
    final ProgramStructuralAudioTimeline timeline = ProgramStructuralAudioTimeline(
      durationFrames: 2,
      occurrences: <ProgramStructuralAudioOccurrence>[
        ProgramStructuralAudioOccurrence(
          placementIndex: 0,
          sourceRef: sourceRender.plan.sourceRef,
          programStartFrame: 1,
          sourceDurationFrames: 1,
        ),
      ],
    );
    final ProgramStructuralAudioRender program =
        await ProgramStructuralAudioRenderer(
      timeline: timeline,
      renderSource: (_) async => sourceRender,
    ).render();

    expect(program.interleavedStereo[0], 0.0);
    expect(
      program.interleavedStereo[1600 * kStructuralAudioChannels],
      sourceRender.interleavedStereo[0],
    );
  });
}
