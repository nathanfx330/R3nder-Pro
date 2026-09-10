// ./lib/program_structural_audio_preview.dart
//
// Realtime transport for a pre-rendered program STRUCT audio bed.
//
// structural_audio_* owns source decode/composition. program_structural_audio
// owns absolute program placement. This module owns only the final PREVIEW
// transport once that program WAV already exists.
//
// One ffmpeg process feeds one sink. With the native Linux sink, that sink is
// the sole AUDIO ProjectClock authority. Voice and music receive the same
// preroll delay BAKE gives them. The program STRUCT WAV receives no delay
// because it is already expressed in absolute project time.
//
// The same transport is also useful to authoring surfaces once they have a
// deterministic structural WAV. [startSampleFrame] trims the already-aligned
// program/source mix after composition, so a playhead start never changes the
// relationship between contributors merely because preview began mid-piece.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'audio_mix.dart';
import 'audio_sink.dart';
import 'structural_audio_plan.dart';

const int _kPreviewChannels = 2;
const int _kPreviewBytesPerFrame = _kPreviewChannels * 2;
const int _kPreviewPacketFrames = 480;
const int _kPreviewPacketBytes =
    _kPreviewPacketFrames * _kPreviewBytesPerFrame;
const Duration _kNativeStartTimeout = Duration(seconds: 2);
const Duration _kNativeStartPoll = Duration(milliseconds: 5);
const String kProgramStructuralPreviewMixLabel = 'r3previewmix';

enum ProgramStructuralAudioPreviewBackend {
  libpulse,
  aplay,
}

class ProgramStructuralAudioPreviewException implements Exception {
  final String message;

  const ProgramStructuralAudioPreviewException(this.message);

  @override
  String toString() => 'ProgramStructuralAudioPreviewException: $message';
}

ProgramStructuralAudioPreviewBackend programStructuralPreviewBackend(
  String backendName,
) {
  return switch (backendName) {
    'libpulse' => ProgramStructuralAudioPreviewBackend.libpulse,
    'aplay' => ProgramStructuralAudioPreviewBackend.aplay,
    _ => throw UnsupportedError(
        'Unsupported program audio preview backend "$backendName".',
      ),
  };
}

String? _presentPath(String? value) {
  final String? trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// True once the native sink has accepted more PCM than its measured device
/// latency. At that point the sink worker has had enough data to release the
/// caller's SCRUB hold into AUDIO authority.
///
/// A reported zero latency is treated conservatively: require two complete
/// producer packets. That avoids racing the first write between the submitted
/// counter increment and the worker's immediately following latency refresh.
bool programStructuralAudioNativeReady(AudioSinkStats stats) {
  if (!stats.healthy || stats.submittedSamples <= 0) return false;
  if (stats.latencySamples <= 0) {
    return stats.submittedSamples >= _kPreviewPacketFrames * 2;
  }
  return stats.submittedSamples > stats.latencySamples;
}

/// Builds the ffmpeg side of PREVIEW's one-process, one-sink audio pipeline.
///
/// [startSampleFrame] is in the same canonical 48 kHz timeline as
/// [programSampleFrames]. Trimming happens after every contributor has been
/// placed in that timeline. Main PREVIEW leaves it at zero; authoring views can
/// start from their playhead without inventing separate seek arithmetic for
/// structural audio, voice, and music.
List<String> buildProgramStructuralAudioPreviewArgs({
  required String structuralAudioPath,
  required int programSampleFrames,
  required int bedDelayMs,
  int startSampleFrame = 0,
  String? voicePath,
  double voiceGainDb = 0.0,
  String? musicPath,
  double musicGainDb = 0.0,
  bool musicLoop = false,
}) {
  final String structural = structuralAudioPath.trim();
  if (structural.isEmpty) {
    throw ArgumentError.value(
      structuralAudioPath,
      'structuralAudioPath',
      'Program STRUCT audio path cannot be empty.',
    );
  }
  if (programSampleFrames <= 0) {
    throw ArgumentError.value(
      programSampleFrames,
      'programSampleFrames',
      'Program audio must own at least one sample frame.',
    );
  }
  if (startSampleFrame < 0 || startSampleFrame >= programSampleFrames) {
    throw ArgumentError.value(
      startSampleFrame,
      'startSampleFrame',
      'Preview start must fall inside the rendered audio timeline.',
    );
  }
  if (bedDelayMs < 0) {
    throw ArgumentError.value(
      bedDelayMs,
      'bedDelayMs',
      'Workspace bed delay cannot be negative.',
    );
  }

  final String? voice = _presentPath(voicePath);
  final String? music = _presentPath(musicPath);
  final List<String> args = <String>['-v', 'error'];
  final List<AudioMixTrack> tracks = <AudioMixTrack>[];
  int inputIndex = 0;

  final String delayChain =
      bedDelayMs > 0 ? 'adelay=$bedDelayMs:all=1' : '';

  if (voice != null) {
    args.addAll(<String>['-i', voice]);
    tracks.add(
      AudioMixTrack(
        input: '$inputIndex:a',
        label: 'r3prevvoice',
        gainDb: voiceGainDb,
        chain: delayChain,
      ),
    );
    inputIndex++;
  }

  if (music != null) {
    if (musicLoop) {
      args.addAll(<String>['-stream_loop', '-1']);
    }
    args.addAll(<String>['-i', music]);
    tracks.add(
      AudioMixTrack(
        input: '$inputIndex:a',
        label: 'r3prevmusic',
        gainDb: musicGainDb,
        chain: delayChain,
      ),
    );
    inputIndex++;
  }

  args.addAll(<String>['-i', structural]);
  tracks.add(
    AudioMixTrack(
      input: '$inputIndex:a',
      label: 'r3prevstruct',
      gainDb: 0.0,
    ),
  );

  final String trimChain = startSampleFrame == 0
      ? 'atrim=end_sample=$programSampleFrames,asetpts=N/SR/TB'
      : 'atrim=start_sample=$startSampleFrame:'
          'end_sample=$programSampleFrames,asetpts=N/SR/TB';
  final String graph = audioMixGraph(
    tracks: tracks,
    outputLabel: kProgramStructuralPreviewMixLabel,
    postMixChain: trimChain,
  );

  args.addAll(<String>[
    '-filter_complex',
    graph,
    '-map',
    '[$kProgramStructuralPreviewMixLabel]',
    '-f',
    's16le',
    '-acodec',
    'pcm_s16le',
    '-ac',
    '$_kPreviewChannels',
    '-ar',
    '$kStructuralAudioSampleRate',
    '-',
  ]);
  return args;
}

/// PREVIEW transport used once a deterministic structural WAV exists.
///
/// For libpulse, [play] does not report success merely because ffmpeg spawned.
/// The native sink holds ProjectClock in SCRUB while opening. We therefore wait
/// until enough PCM has actually crossed the sink to cover measured latency.
/// A decoder/device path that never becomes live fails within a bounded two
/// seconds instead of leaving the picture frozen at its authored start.
class ProgramStructuralAudioPreviewPlayer {
  final ProgramStructuralAudioPreviewBackend backend;

  Process? _decoder;
  Process? _sink;
  NativeAudioSink? _nativeSink;
  Future<void>? _feeder;
  bool _playing = false;
  int _generation = 0;

  ProgramStructuralAudioPreviewPlayer({required this.backend});

  factory ProgramStructuralAudioPreviewPlayer.forBackendName(
    String backendName,
  ) {
    return ProgramStructuralAudioPreviewPlayer(
      backend: programStructuralPreviewBackend(backendName),
    );
  }

  bool get isPlaying => _playing;

  Future<void> play({
    required String structuralAudioPath,
    required int programSampleFrames,
    required int bedDelayMs,
    int startSampleFrame = 0,
    String? voicePath,
    double voiceGainDb = 0.0,
    String? musicPath,
    double musicGainDb = 0.0,
    bool musicLoop = false,
    String? deviceId,
  }) async {
    await stop();
    if (!File(structuralAudioPath).existsSync()) {
      throw ProgramStructuralAudioPreviewException(
        'Program STRUCT audio file does not exist: $structuralAudioPath',
      );
    }

    final int gen = ++_generation;
    final List<String> decodeArgs = buildProgramStructuralAudioPreviewArgs(
      structuralAudioPath: structuralAudioPath,
      programSampleFrames: programSampleFrames,
      bedDelayMs: bedDelayMs,
      startSampleFrame: startSampleFrame,
      voicePath: voicePath,
      voiceGainDb: voiceGainDb,
      musicPath: musicPath,
      musicGainDb: musicGainDb,
      musicLoop: musicLoop,
    );

    if (backend == ProgramStructuralAudioPreviewBackend.libpulse) {
      NativeAudioSink nativeSink;
      try {
        nativeSink = NativeAudioSink(
          device: deviceId,
          sampleRate: kStructuralAudioSampleRate,
          channels: _kPreviewChannels,
        );
      } catch (e) {
        _playing = false;
        throw ProgramStructuralAudioPreviewException(
          'Could not open native program-audio sink: $e',
        );
      }

      Process decoder;
      try {
        decoder = await Process.start('ffmpeg', decodeArgs);
      } catch (e) {
        nativeSink.dispose();
        _playing = false;
        throw ProgramStructuralAudioPreviewException(
          'Could not start program-audio decoder: $e',
        );
      }

      if (gen != _generation) {
        _killQuietly(decoder);
        nativeSink.dispose();
        return;
      }

      _decoder = decoder;
      _nativeSink = nativeSink;
      _playing = true;
      unawaited(decoder.stderr.drain<void>().catchError((_) {}));

      final Future<void> feeder =
          _feedNative(decoder.stdout, nativeSink, gen);
      _feeder = feeder;
      unawaited(_finishNative(gen, decoder, nativeSink, feeder));

      await _waitForNativeStart(nativeSink, gen);
      return;
    }

    Process decoder;
    try {
      decoder = await Process.start('ffmpeg', decodeArgs);
    } catch (e) {
      _playing = false;
      throw ProgramStructuralAudioPreviewException(
        'Could not start program-audio decoder: $e',
      );
    }

    Process sink;
    try {
      sink = await Process.start('aplay', <String>[
        '-t',
        'raw',
        '-f',
        'S16_LE',
        '-r',
        '$kStructuralAudioSampleRate',
        '-c',
        '$_kPreviewChannels',
        '-q',
        if (deviceId != null && deviceId.isNotEmpty) ...<String>['-D', deviceId],
      ]);
    } catch (e) {
      _killQuietly(decoder);
      _playing = false;
      throw ProgramStructuralAudioPreviewException(
        'Could not start aplay program-audio sink: $e',
      );
    }

    if (gen != _generation) {
      _killQuietly(decoder);
      _killQuietly(sink);
      return;
    }

    _decoder = decoder;
    _sink = sink;
    _playing = true;
    unawaited(decoder.stderr.drain<void>().catchError((_) {}));
    unawaited(sink.stderr.drain<void>().catchError((_) {}));
    unawaited(sink.stdout.drain<void>().catchError((_) {}));

    final Future<void> feeder = () async {
      try {
        await decoder.stdout.pipe(sink.stdin);
      } catch (_) {}
    }();
    _feeder = feeder;

    unawaited(sink.exitCode.then((_) {
      if (gen == _generation) {
        _playing = false;
        _decoder = null;
        _sink = null;
        if (identical(_feeder, feeder)) _feeder = null;
      }
    }).catchError((_) {}));
  }

  Future<void> _waitForNativeStart(
    NativeAudioSink sink,
    int gen,
  ) async {
    final DateTime deadline = DateTime.now().add(_kNativeStartTimeout);
    AudioSinkStats? last;

    while (gen == _generation) {
      try {
        final AudioSinkStats stats = sink.stats;
        last = stats;
        if (!stats.healthy) {
          throw ProgramStructuralAudioPreviewException(
            'Native program-audio sink failed before playback: '
            '${sink.lastError}',
          );
        }
        if (programStructuralAudioNativeReady(stats)) return;
      } on ProgramStructuralAudioPreviewException {
        rethrow;
      } catch (e) {
        throw ProgramStructuralAudioPreviewException(
          'Native program-audio sink disappeared before playback: $e',
        );
      }

      if (DateTime.now().isAfter(deadline)) {
        final AudioSinkStats? stats = last;
        throw ProgramStructuralAudioPreviewException(
          'Program audio did not reach the native sink within '
          '${_kNativeStartTimeout.inMilliseconds} ms '
          '(submitted=${stats?.submittedSamples ?? 0}, '
          'latency=${stats?.latencySamples ?? 0}, '
          'queued=${stats?.queuedSamples ?? 0}, '
          'healthy=${stats?.healthy ?? false}).',
        );
      }
      await Future<void>.delayed(_kNativeStartPoll);
    }

    throw const ProgramStructuralAudioPreviewException(
      'Program audio startup was superseded by a newer playback request.',
    );
  }

  Future<void> _feedNative(
    Stream<List<int>> source,
    NativeAudioSink sink,
    int gen,
  ) async {
    final BytesBuilder pending = BytesBuilder(copy: false);

    await for (final List<int> chunk in source) {
      if (gen != _generation) return;
      pending.add(chunk);
      if (pending.length < _kPreviewPacketBytes) continue;

      final Uint8List bytes = pending.takeBytes();
      int offset = 0;
      final int packetEnd = bytes.lengthInBytes -
          (bytes.lengthInBytes % _kPreviewPacketBytes);
      while (offset < packetEnd) {
        final Uint8List packet = Uint8List.sublistView(
          bytes,
          offset,
          offset + _kPreviewPacketBytes,
        );
        if (!await _enqueueNative(sink, packet, gen)) return;
        offset += _kPreviewPacketBytes;
      }
      if (offset < bytes.lengthInBytes) {
        pending.add(Uint8List.sublistView(bytes, offset));
      }
    }

    if (gen != _generation) return;
    final Uint8List tail = pending.takeBytes();
    if (tail.lengthInBytes % _kPreviewBytesPerFrame != 0) {
      throw const ProgramStructuralAudioPreviewException(
        'FFmpeg ended on a partial PCM sample frame.',
      );
    }
    if (tail.isNotEmpty) {
      await _enqueueNative(sink, tail, gen);
    }
  }

  Future<bool> _enqueueNative(
    NativeAudioSink sink,
    Uint8List packet,
    int gen,
  ) async {
    while (gen == _generation) {
      try {
        if (sink.tryEnqueue(packet)) return true;
      } on AudioSinkException catch (e) {
        throw ProgramStructuralAudioPreviewException(
          'Native program-audio sink failed: ${e.message}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    return false;
  }

  Future<bool> _waitForNativeDrain(
    NativeAudioSink sink,
    int gen,
  ) async {
    while (gen == _generation) {
      final AudioSinkStats stats = sink.stats;
      if (!stats.healthy) {
        throw ProgramStructuralAudioPreviewException(
          'Native program-audio sink failed: ${sink.lastError}',
        );
      }
      if (!stats.draining) return true;
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    return false;
  }

  Future<void> _finishNative(
    int gen,
    Process decoder,
    NativeAudioSink sink,
    Future<void> feeder,
  ) async {
    try {
      await decoder.exitCode;
      await feeder;
      if (gen != _generation) return;
      sink.requestDrain();
      await _waitForNativeDrain(sink, gen);
    } catch (_) {
      // Startup failures are surfaced synchronously by _waitForNativeStart.
      // Failures after a successful start end the current preview transport;
      // native teardown releases ProjectClock to MONOTONIC.
    } finally {
      if (gen == _generation) {
        _playing = false;
        if (identical(_decoder, decoder)) _decoder = null;
        if (identical(_nativeSink, sink)) _nativeSink = null;
        if (identical(_feeder, feeder)) _feeder = null;
        sink.dispose();
      }
    }
  }

  Future<void> stop() async {
    _generation++;
    final Process? decoder = _decoder;
    final Process? sink = _sink;
    final NativeAudioSink? native = _nativeSink;
    final Future<void>? feeder = _feeder;

    _decoder = null;
    _sink = null;
    _nativeSink = null;
    _feeder = null;
    _playing = false;

    _killQuietly(decoder);
    _killQuietly(sink);
    if (feeder != null) {
      try {
        await feeder;
      } catch (_) {}
    }
    if (native != null) {
      try {
        native.flush();
      } catch (_) {}
      native.dispose();
    }
  }

  void dispose() {
    _generation++;
    _killQuietly(_decoder);
    _killQuietly(_sink);
    final NativeAudioSink? native = _nativeSink;
    _decoder = null;
    _sink = null;
    _nativeSink = null;
    _feeder = null;
    _playing = false;
    if (native != null) {
      try {
        native.flush();
      } catch (_) {}
      native.dispose();
    }
  }
}

void _killQuietly(Process? process) {
  if (process == null) return;
  try {
    process.kill(ProcessSignal.sigterm);
  } catch (_) {}
}
