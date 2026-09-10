// ./test/program_structural_audio_preview_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/audio_sink.dart';
import 'package:r3nder/program_structural_audio_preview.dart';

void main() {
  test('preview graph mixes voice music and absolute STRUCT program audio', () {
    final List<String> args = buildProgramStructuralAudioPreviewArgs(
      structuralAudioPath: '/tmp/program.wav',
      programSampleFrames: 96000,
      bedDelayMs: 2000,
      voicePath: '/workspace/audio/voice.wav',
      voiceGainDb: -3.0,
      musicPath: '/workspace/audio/music.wav',
      musicGainDb: -6.0,
      musicLoop: true,
    );

    expect(
      args,
      <String>[
        '-v',
        'error',
        '-i',
        '/workspace/audio/voice.wav',
        '-stream_loop',
        '-1',
        '-i',
        '/workspace/audio/music.wav',
        '-i',
        '/tmp/program.wav',
        '-filter_complex',
        '[0:a]adelay=2000:all=1,volume=-3.00dB[r3prevvoice];'
            '[1:a]adelay=2000:all=1,volume=-6.00dB[r3prevmusic];'
            '[2:a]volume=0.00dB[r3prevstruct];'
            '[r3prevvoice][r3prevmusic][r3prevstruct]'
            'amix=inputs=3:normalize=0:dropout_transition=0:'
            'duration=longest[r3mixpre];'
            '[r3mixpre]atrim=end_sample=96000,asetpts=N/SR/TB'
            '[r3previewmix]',
        '-map',
        '[r3previewmix]',
        '-f',
        's16le',
        '-acodec',
        'pcm_s16le',
        '-ac',
        '2',
        '-ar',
        '48000',
        '-',
      ],
    );
  });

  test('STRUCT-only preview remains one exact program-time contributor', () {
    final List<String> args = buildProgramStructuralAudioPreviewArgs(
      structuralAudioPath: '/tmp/program.wav',
      programSampleFrames: 48000,
      bedDelayMs: 0,
    );

    expect(args.where((String value) => value == '-i').length, 1);
    expect(args, isNot(contains('-stream_loop')));
    expect(
      args[args.indexOf('-filter_complex') + 1],
      '[0:a]volume=0.00dB,atrim=end_sample=48000,asetpts=N/SR/TB'
      '[r3previewmix]',
    );
    expect(
      args[args.indexOf('-filter_complex') + 1],
      isNot(contains('amix=')),
    );
  });

  test('authoring start trims the aligned source mix at an exact sample', () {
    final List<String> args = buildProgramStructuralAudioPreviewArgs(
      structuralAudioPath: '/tmp/edit.wav',
      programSampleFrames: 96000,
      startSampleFrame: 32000,
      bedDelayMs: 0,
    );

    expect(
      args[args.indexOf('-filter_complex') + 1],
      '[0:a]volume=0.00dB,'
      'atrim=start_sample=32000:end_sample=96000,asetpts=N/SR/TB'
      '[r3previewmix]',
    );
  });

  test('blank workspace paths are absent rather than phantom inputs', () {
    final List<String> args = buildProgramStructuralAudioPreviewArgs(
      structuralAudioPath: '/tmp/program.wav',
      programSampleFrames: 1600,
      bedDelayMs: 67,
      voicePath: '   ',
      musicPath: '',
    );

    expect(args.where((String value) => value == '-i').length, 1);
    expect(args, isNot(contains('adelay=67:all=1')));
  });

  test('preview backend follows the existing workspace sink backend', () {
    expect(
      programStructuralPreviewBackend('libpulse'),
      ProgramStructuralAudioPreviewBackend.libpulse,
    );
    expect(
      programStructuralPreviewBackend('aplay'),
      ProgramStructuralAudioPreviewBackend.aplay,
    );
    expect(
      () => programStructuralPreviewBackend('other'),
      throwsUnsupportedError,
    );
  });

  test('native startup readiness waits beyond measured sink latency', () {
    const AudioSinkStats exactlyAtLatency = AudioSinkStats(
      submittedSamples: 2400,
      latencySamples: 2400,
      queuedSamples: 0,
      sampleRate: 48000,
      channels: 2,
      healthy: true,
      draining: false,
    );
    const AudioSinkStats beyondLatency = AudioSinkStats(
      submittedSamples: 2880,
      latencySamples: 2400,
      queuedSamples: 0,
      sampleRate: 48000,
      channels: 2,
      healthy: true,
      draining: false,
    );
    const AudioSinkStats firstZeroLatencyPacket = AudioSinkStats(
      submittedSamples: 480,
      latencySamples: 0,
      queuedSamples: 0,
      sampleRate: 48000,
      channels: 2,
      healthy: true,
      draining: false,
    );
    const AudioSinkStats secondZeroLatencyPacket = AudioSinkStats(
      submittedSamples: 960,
      latencySamples: 0,
      queuedSamples: 0,
      sampleRate: 48000,
      channels: 2,
      healthy: true,
      draining: false,
    );
    const AudioSinkStats unhealthy = AudioSinkStats(
      submittedSamples: 9600,
      latencySamples: 2400,
      queuedSamples: 0,
      sampleRate: 48000,
      channels: 2,
      healthy: false,
      draining: false,
    );

    expect(programStructuralAudioNativeReady(exactlyAtLatency), isFalse);
    expect(programStructuralAudioNativeReady(beyondLatency), isTrue);
    expect(programStructuralAudioNativeReady(firstZeroLatencyPacket), isFalse);
    expect(programStructuralAudioNativeReady(secondZeroLatencyPacket), isTrue);
    expect(programStructuralAudioNativeReady(unhealthy), isFalse);
  });

  test('program geometry rejects invalid transport and authoring bounds', () {
    expect(
      () => buildProgramStructuralAudioPreviewArgs(
        structuralAudioPath: '',
        programSampleFrames: 1600,
        bedDelayMs: 0,
      ),
      throwsArgumentError,
    );
    expect(
      () => buildProgramStructuralAudioPreviewArgs(
        structuralAudioPath: '/tmp/program.wav',
        programSampleFrames: 0,
        bedDelayMs: 0,
      ),
      throwsArgumentError,
    );
    expect(
      () => buildProgramStructuralAudioPreviewArgs(
        structuralAudioPath: '/tmp/program.wav',
        programSampleFrames: 1600,
        startSampleFrame: -1,
        bedDelayMs: 0,
      ),
      throwsArgumentError,
    );
    expect(
      () => buildProgramStructuralAudioPreviewArgs(
        structuralAudioPath: '/tmp/program.wav',
        programSampleFrames: 1600,
        startSampleFrame: 1600,
        bedDelayMs: 0,
      ),
      throwsArgumentError,
    );
    expect(
      () => buildProgramStructuralAudioPreviewArgs(
        structuralAudioPath: '/tmp/program.wav',
        programSampleFrames: 1600,
        bedDelayMs: -1,
      ),
      throwsArgumentError,
    );
  });
}
