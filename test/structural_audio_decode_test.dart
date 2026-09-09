// ./test/structural_audio_decode_test.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/structural_audio_decode.dart';
import 'package:r3nder/structural_audio_plan.dart';

class _Call {
  final String executable;
  final List<String> arguments;
  final bool binaryStdout;

  const _Call(this.executable, this.arguments, this.binaryStdout);
}

class _QueuedResult {
  final String executable;
  final StructuralAudioProcessResult result;

  const _QueuedResult(this.executable, this.result);
}

class _FakeRunner implements StructuralAudioProcessRunner {
  final List<_QueuedResult> queued;
  final List<_Call> calls = <_Call>[];

  _FakeRunner(List<_QueuedResult> results)
      : queued = List<_QueuedResult>.from(results);

  @override
  Future<StructuralAudioProcessResult> run(
    String executable,
    List<String> arguments, {
    bool binaryStdout = false,
  }) async {
    calls.add(_Call(executable, List<String>.from(arguments), binaryStdout));
    if (queued.isEmpty) {
      throw StateError('No fake result queued for $executable.');
    }
    final _QueuedResult next = queued.removeAt(0);
    if (next.executable != executable) {
      throw StateError(
        'Expected ${next.executable} but decoder called $executable.',
      );
    }
    return next.result;
  }
}

StructuralAudioSegment _segment(String source) {
  final StructuralAudioPlan plan =
      StructuralAudioPlanner.parse(source).plan('EDIT.main');
  return plan.lane('V1').segments.single;
}

Uint8List _stereoRamp(int sampleFrames) {
  final ByteData data = ByteData(sampleFrames * 2 * 4);
  for (int frame = 0; frame < sampleFrames; frame++) {
    final double value = frame.toDouble();
    data.setFloat32(frame * 8, value, Endian.little);
    data.setFloat32(frame * 8 + 4, -value, Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  test('decode window extends exact source interval for authored XFADE handles', () {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:a:a.mp4:0:24:180:4/5]
[#EDIT_TRANSITION:CROSSFADE:15]
[#EDIT_TRANSITION_OUT:CROSSFADE:15]
[/CLIP]
[/TRACK]
[/EDIT]
''';
    final StructuralAudioSegment segment = _segment(source);
    const StructuralAudioSourceInfo info = StructuralAudioSourceInfo.audio(
      path: '/workspace/video/a.mp4',
      sourceFpsNumerator: 24,
      sourceFpsDenominator: 1,
      audioSampleRate: 44100,
      audioChannels: 2,
      audioChannelLayout: 'stereo',
    );

    final StructuralAudioDecodeWindow window =
        StructuralAudioDecodeWindow.forSegment(segment, info);

    // IN 24 at 24 fps starts at 1 second. 180 project frames are 6 seconds
    // at natural 4/5 source-frame speed. Each 15-frame XFADE needs a 0.5 s
    // source handle, so the required interval is 0.5 s .. 7.5 s.
    expect(window.contentStartSampleFrame, 48000);
    expect(window.contentEndSampleFrameExclusive, 336000);
    expect(window.requiredStartSampleFrame, 24000);
    expect(window.requiredEndSampleFrameExclusive, 360000);
    expect(window.incomingHandleSampleFrames, 24000);
    expect(window.outgoingHandleSampleFrames, 24000);
    expect(window.requiredSampleFrames, 336000);
    expect(window.decodeStartSampleFrame, 23744);
    expect(window.decodeEndSampleFrameExclusive, 360256);
  });

  test('mono leaf decode pins seek, channel map, resampler, and exact trim', () async {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:a:a.mp4:0:1:1:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';
    final StructuralAudioSegment segment = _segment(source);
    const StructuralAudioSourceInfo info = StructuralAudioSourceInfo.audio(
      path: '/workspace/video/a.mp4',
      sourceFpsNumerator: 30,
      sourceFpsDenominator: 1,
      audioSampleRate: 44100,
      audioChannels: 1,
      audioChannelLayout: 'mono',
    );
    final StructuralAudioDecodeWindow window =
        StructuralAudioDecodeWindow.forSegment(segment, info);
    expect(window.requiredStartSampleFrame, 1600);
    expect(window.requiredEndSampleFrameExclusive, 3200);
    expect(window.decodeStartSampleFrame, 1344);
    expect(window.decodeEndSampleFrameExclusive, 3456);
    expect(window.decodeSampleFrames, 2112);

    final _FakeRunner runner = _FakeRunner(<_QueuedResult>[
      _QueuedResult(
        'ffmpeg',
        StructuralAudioProcessResult(
          exitCode: 0,
          stdoutBytes: _stereoRamp(window.decodeSampleFrames),
        ),
      ),
    ]);
    final StructuralAudioLeafDecoder decoder =
        StructuralAudioLeafDecoder(runner: runner);

    final StructuralAudioLeafDecode result = await decoder.decodeLeaf(
      segment: segment,
      resolvedPath: info.path,
      sourceInfo: info,
    );

    expect(result.status, StructuralAudioLeafDecodeStatus.decoded);
    expect(result.authoredProjectSampleFrames, 1600);
    expect(result.sourceSampleFrames, 1600);
    expect(result.interleavedStereo.first, 256.0);
    expect(result.interleavedStereo[1], -256.0);
    expect(
      result.interleavedStereo[result.interleavedStereo.length - 2],
      1855.0,
    );
    expect(result.interleavedStereo.last, -1855.0);

    expect(runner.calls, hasLength(1));
    final _Call call = runner.calls.single;
    expect(call.executable, 'ffmpeg');
    expect(call.binaryStdout, isTrue);
    expect(call.arguments, containsAllInOrder(<String>[
      '-accurate_seek',
      '-ss',
      '0.028000000000',
      '-i',
      info.path,
    ]));
    final int filterAt = call.arguments.indexOf('-af');
    expect(filterAt, greaterThanOrEqualTo(0));
    final String filter = call.arguments[filterAt + 1];
    expect(filter, startsWith('pan=stereo|c0=c0|c1=c0,'));
    expect(filter, contains(kStructuralAudioResamplerFilter));
    expect(filter, contains(kStructuralAudioOutputFormatFilter));
    expect(filter, contains('atrim=start_sample=0:end_sample=2112'));
  });

  test('probe distinguishes a video-only leaf from decode failure', () async {
    final _FakeRunner runner = _FakeRunner(<_QueuedResult>[
      _QueuedResult(
        'ffprobe',
        StructuralAudioProcessResult(
          exitCode: 0,
          stdoutText: jsonEncode(<String, Object>{
            'streams': <Object>[
              <String, Object>{
                'index': 0,
                'codec_type': 'video',
                'avg_frame_rate': '30000/1001',
                'r_frame_rate': '30000/1001',
              },
            ],
          }),
        ),
      ),
    ]);
    final StructuralAudioLeafDecoder decoder =
        StructuralAudioLeafDecoder(runner: runner);

    final StructuralAudioSourceInfo info =
        await decoder.probe('/workspace/video/silent.mp4');

    expect(info.kind, StructuralAudioSourceKind.noAudio);
    expect(info.sourceFpsNumerator, 30000);
    expect(info.sourceFpsDenominator, 1001);
    expect(info.audioChannels, 0);
  });

  test('no-audio leaf returns authored-duration silence intent without ffmpeg', () async {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:a:a.mp4:0:0:12:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';
    final StructuralAudioSegment segment = _segment(source);
    const StructuralAudioSourceInfo info = StructuralAudioSourceInfo.noAudio(
      path: '/workspace/video/a.mp4',
      sourceFpsNumerator: 30,
      sourceFpsDenominator: 1,
    );
    final _FakeRunner runner = _FakeRunner(const <_QueuedResult>[]);
    final StructuralAudioLeafDecoder decoder =
        StructuralAudioLeafDecoder(runner: runner);

    final StructuralAudioLeafDecode result = await decoder.decodeLeaf(
      segment: segment,
      resolvedPath: info.path,
      sourceInfo: info,
    );

    expect(result.status, StructuralAudioLeafDecodeStatus.noAudio);
    expect(result.authoredProjectSampleFrames, 12 * 1600);
    expect(result.interleavedStereo, isEmpty);
    expect(runner.calls, isEmpty);
  });

  test('5.1 downmix is explicit and LFE does not enter either output', () {
    const StructuralAudioSourceInfo info = StructuralAudioSourceInfo.audio(
      path: '/workspace/video/field.mp4',
      sourceFpsNumerator: 30,
      sourceFpsDenominator: 1,
      audioSampleRate: 48000,
      audioChannels: 6,
      audioChannelLayout: '5.1',
    );

    final String filter = structuralAudioPanFilter(info);
    expect(
      filter,
      'pan=stereo|FL=FL+0.7071067811865476*FC+0.7071067811865476*BL|'
      'FR=FR+0.7071067811865476*FC+0.7071067811865476*BR',
    );
    expect(filter, isNot(contains('LFE')));
  });

  test('unknown multichannel layout fails instead of using ffmpeg defaults', () {
    const StructuralAudioSourceInfo info = StructuralAudioSourceInfo.audio(
      path: '/workspace/video/odd.mp4',
      sourceFpsNumerator: 30,
      sourceFpsDenominator: 1,
      audioSampleRate: 48000,
      audioChannels: 6,
      audioChannelLayout: 'custom-six',
    );

    expect(
      () => structuralAudioPanFilter(info),
      throwsA(isA<StructuralAudioDecodeException>()),
    );
  });

  test('ffmpeg decode failure is not reported as a no-audio source', () async {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:a:a.mp4:0:0:1:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';
    final StructuralAudioSegment segment = _segment(source);
    const StructuralAudioSourceInfo info = StructuralAudioSourceInfo.audio(
      path: '/workspace/video/a.mp4',
      sourceFpsNumerator: 30,
      sourceFpsDenominator: 1,
      audioSampleRate: 48000,
      audioChannels: 2,
      audioChannelLayout: 'stereo',
    );
    final _FakeRunner runner = _FakeRunner(<_QueuedResult>[
      const _QueuedResult(
        'ffmpeg',
        StructuralAudioProcessResult(
          exitCode: 1,
          stderrText: 'decoder exploded',
        ),
      ),
    ]);
    final StructuralAudioLeafDecoder decoder =
        StructuralAudioLeafDecoder(runner: runner);

    await expectLater(
      decoder.decodeLeaf(
        segment: segment,
        resolvedPath: info.path,
        sourceInfo: info,
      ),
      throwsA(
        isA<StructuralAudioDecodeException>().having(
          (StructuralAudioDecodeException error) => error.message,
          'message',
          contains('decoder exploded'),
        ),
      ),
    );
  });

  test('full ffmpeg version output is exposed for future source cache identity', () async {
    const String version =
        'ffmpeg version 9.0.1\nconfiguration: --enable-gpl\nlibswresample 6.0';
    final _FakeRunner runner = _FakeRunner(<_QueuedResult>[
      const _QueuedResult(
        'ffmpeg',
        StructuralAudioProcessResult(
          exitCode: 0,
          stdoutText: version,
        ),
      ),
    ]);
    final StructuralAudioLeafDecoder decoder =
        StructuralAudioLeafDecoder(runner: runner);

    expect(await decoder.ffmpegVersionString(), version);
    expect(await decoder.ffmpegVersionString(), version);
    expect(runner.calls, hasLength(1));
  });
}
