// ./test/structural_audio_render_test.dart

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/structural_audio_decode.dart';
import 'package:r3nder/structural_audio_plan.dart';
import 'package:r3nder/structural_audio_render.dart';

typedef _SampleValue = double Function(
  String resolvedPath,
  int absoluteSourceSampleFrame,
  int channel,
);

class _FakeLeafDecoder implements StructuralAudioLeafDecodeBackend {
  final _SampleValue sampleValue;
  final Set<String> noAudioPaths;
  final Map<String, (int, int)> fpsByPath;
  final List<String> calls = <String>[];

  _FakeLeafDecoder({
    required this.sampleValue,
    this.noAudioPaths = const <String>{},
    this.fpsByPath = const <String, (int, int)>{},
  });

  @override
  Future<StructuralAudioLeafDecode> decode(
    StructuralAudioSegment segment,
    String resolvedPath,
  ) async {
    calls.add(resolvedPath);
    final (int, int) fps = fpsByPath[resolvedPath] ?? (30, 1);

    if (noAudioPaths.contains(resolvedPath)) {
      return StructuralAudioLeafDecode.noAudio(
        sourceInfo: StructuralAudioSourceInfo.noAudio(
          path: resolvedPath,
          sourceFpsNumerator: fps.$1,
          sourceFpsDenominator: fps.$2,
        ),
        authoredProjectSampleFrames: segment.sampleCount,
      );
    }

    final StructuralAudioSourceInfo info = StructuralAudioSourceInfo.audio(
      path: resolvedPath,
      sourceFpsNumerator: fps.$1,
      sourceFpsDenominator: fps.$2,
      audioSampleRate: 48000,
      audioChannels: 2,
      audioChannelLayout: 'stereo',
    );
    final StructuralAudioDecodeWindow window =
        StructuralAudioDecodeWindow.forSegment(segment, info);
    final Float32List pcm = Float32List(
      window.requiredSampleFrames * kStructuralAudioChannels,
    );

    for (int frame = 0; frame < window.requiredSampleFrames; frame++) {
      final int absolute = window.requiredStartSampleFrame + frame;
      final int base = frame * kStructuralAudioChannels;
      pcm[base] = sampleValue(resolvedPath, absolute, 0);
      pcm[base + 1] = sampleValue(resolvedPath, absolute, 1);
    }

    return StructuralAudioLeafDecode.decoded(
      sourceInfo: info,
      authoredProjectSampleFrames: segment.sampleCount,
      window: window,
      interleavedStereo: pcm,
    );
  }
}

StructuralAudioSourceRenderer _renderer(
  String script,
  _FakeLeafDecoder decoder,
) {
  return StructuralAudioSourceRenderer(
    planner: StructuralAudioPlanner.parse(script),
    leafDecoder: decoder,
    resolveSource: (String source) => '/workspace/$source',
  );
}

double _leftAt(
  StructuralAudioSourceRender render,
  int sampleFrame,
) {
  return render.interleavedStereo[sampleFrame * kStructuralAudioChannels];
}

double _rightAt(
  StructuralAudioSourceRender render,
  int sampleFrame,
) {
  return render.interleavedStereo[
    sampleFrame * kStructuralAudioChannels + 1
  ];
}

void main() {
  test('leaf placement is exact integer project sample geometry', () async {
    const String script = '''[EDIT:main]
[TRACK:V1]
[CLIP:a:video/a.mp4:2:0:2:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';
    final _FakeLeafDecoder decoder = _FakeLeafDecoder(
      sampleValue: (String path, int sample, int channel) =>
          channel == 0 ? 0.25 : -0.25,
    );
    final StructuralAudioSourceRender render =
        await _renderer(script, decoder).render('EDIT.main');

    expect(render.sampleFrames, 4 * 1600);
    expect(_leftAt(render, 2 * 1600 - 1), 0.0);
    expect(_leftAt(render, 2 * 1600), closeTo(0.25, 1e-7));
    expect(_rightAt(render, 2 * 1600), closeTo(-0.25, 1e-7));
    expect(_leftAt(render, 4 * 1600 - 1), closeTo(0.25, 1e-7));
    expect(decoder.calls, <String>['/workspace/video/a.mp4']);
  });

  test('speed two consumes source samples at twice project rate', () async {
    const String script = '''[EDIT:main]
[TRACK:V1]
[CLIP:fast:video/fast.mp4:0:0:1:2]
[/CLIP]
[/TRACK]
[/EDIT]
''';
    final _FakeLeafDecoder decoder = _FakeLeafDecoder(
      sampleValue: (String path, int sample, int channel) => sample / 10000.0,
    );
    final StructuralAudioSourceRender render =
        await _renderer(script, decoder).render('EDIT.main');

    expect(_leftAt(render, 0), 0.0);
    expect(_leftAt(render, 1), closeTo(0.0002, 1e-7));
    expect(_leftAt(render, 799), closeTo(0.1598, 1e-6));
    expect(_leftAt(render, 1599), closeTo(0.3198, 1e-6));
  });

  test('fractional speed uses pinned linear interpolation', () async {
    const String script = '''[EDIT:main]
[TRACK:V1]
[CLIP:slow:video/slow.mp4:0:0:1:1/2]
[/CLIP]
[/TRACK]
[/EDIT]
''';
    final _FakeLeafDecoder decoder = _FakeLeafDecoder(
      sampleValue: (String path, int sample, int channel) => sample.toDouble(),
    );
    final StructuralAudioSourceRender render =
        await _renderer(script, decoder).render('EDIT.main');

    expect(_leftAt(render, 0), 0.0);
    expect(_leftAt(render, 1), closeTo(0.5, 1e-7));
    expect(_leftAt(render, 2), closeTo(1.0, 1e-7));
    expect(_leftAt(render, 1598), closeTo(799.0, 1e-5));
  });

  test('24fps 4/5 conform preserves natural source-time audio rate', () async {
    const String script = '''[EDIT:main]
[TRACK:V1]
[CLIP:conform:video/24fps.mp4:0:0:1:4/5]
[/CLIP]
[/TRACK]
[/EDIT]
''';
    final _FakeLeafDecoder decoder = _FakeLeafDecoder(
      fpsByPath: const <String, (int, int)>{
        '/workspace/video/24fps.mp4': (24, 1),
      },
      sampleValue: (String path, int sample, int channel) => sample / 10000.0,
    );
    final StructuralAudioSourceRender render =
        await _renderer(script, decoder).render('EDIT.main');

    // A 24 fps source authored at 4/5 source frames per 30 fps project frame
    // consumes exactly 1/30 second of source time per project frame. At 48 kHz
    // that is one source sample for every project sample: natural-speed audio.
    expect(_leftAt(render, 0), 0.0);
    expect(_leftAt(render, 1), closeTo(0.0001, 1e-7));
    expect(_leftAt(render, 799), closeTo(0.0799, 1e-6));
    expect(_leftAt(render, 1599), closeTo(0.1599, 1e-6));
  });

  test('overlapping CROSSFADE segments use midpoint equal-power gains', () async {
    const String script = '''[EDIT:main]
[TRACK:V1]
[CLIP:a:video/a.mp4:0:0:4:1]
[#EDIT_TRANSITION_OUT:CROSSFADE:1]
[/CLIP]
[CLIP:b:video/b.mp4:3:0:4:1]
[#EDIT_TRANSITION:CROSSFADE:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';
    final _FakeLeafDecoder decoder = _FakeLeafDecoder(
      sampleValue: (String path, int sample, int channel) => 1.0,
    );
    final StructuralAudioSourceRender render =
        await _renderer(script, decoder).render('EDIT.main');

    final int fadeStart = 3 * 1600;
    final double firstT = 0.5 / 1600.0;
    final double firstExpected =
        math.cos(firstT * math.pi / 2.0) +
            math.sin(firstT * math.pi / 2.0);
    expect(_leftAt(render, fadeStart), closeTo(firstExpected, 1e-6));

    const int middleOffset = 800;
    final double middleT = (middleOffset + 0.5) / 1600.0;
    final double middleExpected =
        math.cos(middleT * math.pi / 2.0) +
            math.sin(middleT * math.pi / 2.0);
    expect(
      _leftAt(render, fadeStart + middleOffset),
      closeTo(middleExpected, 1e-6),
    );
    expect(_leftAt(render, fadeStart - 1), closeTo(1.0, 1e-7));
    expect(_leftAt(render, fadeStart + 1600), closeTo(1.0, 1e-7));
  });

  test('MOSAIC sums simultaneously active pane audio', () async {
    const String script = '''[EDIT:left]
[TRACK:V1]
[CLIP:l:video/left.mp4:0:0:2:1]
[/CLIP]
[/TRACK]
[/EDIT]
[EDIT:right]
[TRACK:V1]
[CLIP:r:video/right.mp4:0:0:2:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:p1]
[CLIP:leftCut:EDIT.left:0:0:2:1]
[/CLIP]
[/PANE]
[PANE:p2]
[CLIP:rightCut:EDIT.right:0:0:2:1]
[/CLIP]
[/PANE]
[/MOSAIC]
''';
    final _FakeLeafDecoder decoder = _FakeLeafDecoder(
      sampleValue: (String path, int sample, int channel) {
        if (path.endsWith('left.mp4')) {
          return 0.25;
        }
        return 0.5;
      },
    );
    final StructuralAudioSourceRender render =
        await _renderer(script, decoder).render('MOSAIC.wall');

    expect(render.sampleFrames, 2 * 1600);
    expect(_leftAt(render, 0), closeTo(0.75, 1e-7));
    expect(_leftAt(render, 2 * 1600 - 1), closeTo(0.75, 1e-7));
    expect(decoder.calls, hasLength(2));
  });

  test('nested structural IN and placement preserve source-relative timing', () async {
    const String script = '''[EDIT:child]
[TRACK:V1]
[CLIP:a:video/a.mp4:0:0:4:1]
[/CLIP]
[/TRACK]
[/EDIT]
[EDIT:parent]
[TRACK:V1]
[CLIP:nested:EDIT.child:1:2:2:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';
    final _FakeLeafDecoder decoder = _FakeLeafDecoder(
      sampleValue: (String path, int sample, int channel) {
        final int sourceProjectFrame = sample ~/ 1600;
        return sourceProjectFrame.toDouble();
      },
    );
    final StructuralAudioSourceRender render =
        await _renderer(script, decoder).render('EDIT.parent');

    expect(render.sampleFrames, 3 * 1600);
    expect(_leftAt(render, 1600 - 1), 0.0);
    expect(_leftAt(render, 1600), closeTo(2.0, 1e-7));
    expect(_leftAt(render, 2 * 1600), closeTo(3.0, 1e-7));
    expect(decoder.calls, <String>['/workspace/video/a.mp4']);
  });

  test('video-only media contributes silence without shortening source', () async {
    const String script = '''[EDIT:main]
[TRACK:V1]
[CLIP:silent:video/broll.mp4:1:0:3:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';
    final _FakeLeafDecoder decoder = _FakeLeafDecoder(
      noAudioPaths: const <String>{'/workspace/video/broll.mp4'},
      sampleValue: (String path, int sample, int channel) => 1.0,
    );
    final StructuralAudioSourceRender render =
        await _renderer(script, decoder).render('EDIT.main');

    expect(render.sampleFrames, 4 * 1600);
    expect(
      render.interleavedStereo.every((double sample) => sample == 0.0),
      isTrue,
    );
  });

  test('float WAV is byte-identical across consecutive renders', () async {
    const String script = '''[EDIT:main]
[TRACK:V1]
[CLIP:a:video/a.mp4:0:0:2:1]
[/CLIP]
[CLIP:b:video/b.mp4:1:0:2:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';
    final _FakeLeafDecoder decoder = _FakeLeafDecoder(
      sampleValue: (String path, int sample, int channel) {
        final double base = path.endsWith('a.mp4') ? 0.2 : 0.3;
        return channel == 0 ? base : -base;
      },
    );
    final StructuralAudioSourceRenderer renderer = _renderer(script, decoder);

    final Uint8List first = await renderer.renderWav('EDIT.main');
    final Uint8List second = await renderer.renderWav('EDIT.main');

    expect(second, orderedEquals(first));
    expect(String.fromCharCodes(first.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(first.sublist(8, 12)), 'WAVE');
    expect(String.fromCharCodes(first.sublist(36, 40)), 'data');

    final ByteData header = ByteData.sublistView(first);
    expect(header.getUint16(20, Endian.little), 3);
    expect(header.getUint16(22, Endian.little), 2);
    expect(header.getUint32(24, Endian.little), 48000);
    expect(header.getUint16(34, Endian.little), 32);
    expect(
      header.getUint32(40, Endian.little),
      3 * 1600 * 2 * 4,
    );
  });
}
