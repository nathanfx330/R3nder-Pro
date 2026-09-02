// ./tool/audio_clock_probe.dart
//
// Diagnostic probe for the future AUDIO ProjectClock authority.
//
// This intentionally does not change preview behavior. It exercises the same
// transport shape as AudioBedPlayer: ffmpeg produces raw s16le stereo 48 kHz
// PCM, Dart forwards it to paplay/aplay with addStream backpressure, and every
// forwarded byte is counted. On PulseAudio it also gives the stream a unique
// name, requests a bounded latency, and samples sink-input timing so we can
// compare submitted PCM with the server's own buffering numbers.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

const int _sampleRate = 48000;
const int _channels = 2;
const int _bytesPerSample = 2;
const int _bytesPerSampleFrame = _channels * _bytesPerSample;
const String _pulseName = 'R3nderAudioClockProbe';

Future<void> main(List<String> args) async {
  final int seconds = _readIntOption(
    args,
    '--seconds=',
    fallback: 20,
    min: 3,
    max: 600,
  );
  final int latencyMs = _readIntOption(
    args,
    '--latency-ms=',
    fallback: 50,
    min: 1,
    max: 5000,
  );
  final String? requestedDevice = _readOption(args, '--device=');

  if (!await _exists('ffmpeg')) {
    stderr.writeln('ERROR: ffmpeg is not available.');
    exitCode = 2;
    return;
  }

  final _SinkBackend? backend =
      await _findSinkBackend(requestedDevice, latencyMs);
  if (backend == null) {
    stderr.writeln('ERROR: neither paplay nor aplay is available.');
    exitCode = 2;
    return;
  }

  final bool pactlAvailable =
      backend.name == 'paplay' && await _exists('pactl');

  stdout.writeln('R3NDER AUDIO CLOCK PROBE');
  stdout.writeln('backend: ${backend.name}');
  stdout.writeln('duration: ${seconds}s');
  stdout.writeln('format: s16le stereo $_sampleRate Hz');
  stdout.writeln('device: ${requestedDevice ?? 'default'}');
  if (backend.name == 'paplay') {
    stdout.writeln('requested PulseAudio latency: ${latencyMs}ms');
    stdout.writeln('pactl timing probe: ${pactlAvailable ? 'yes' : 'no'}');
  } else {
    stdout.writeln('requested latency: unavailable on aplay fallback');
  }
  stdout.writeln('');

  final Process decoder = await Process.start('ffmpeg', <String>[
    '-v', 'error',
    '-f', 'lavfi',
    '-i', 'sine=frequency=440:sample_rate=$_sampleRate',
    '-af', 'volume=0.01',
    '-f', 's16le',
    '-acodec', 'pcm_s16le',
    '-ac', '$_channels',
    '-ar', '$_sampleRate',
    '-',
  ]);

  final Process sink = await Process.start(backend.name, backend.args);

  // Expected broken-pipe diagnostics after the intentional shutdown are not
  // useful probe output, so drain rather than mirror child stderr.
  unawaited(decoder.stderr.drain<void>().catchError((_) {}));
  unawaited(sink.stderr.drain<void>().catchError((_) {}));
  unawaited(sink.stdout.drain<void>().catchError((_) {}));

  int generation = 1;
  int submittedBytes = 0;
  final int feederGeneration = generation;

  final StreamTransformer<List<int>, List<int>> counted =
      StreamTransformer<List<int>, List<int>>.fromHandlers(
    handleData: (List<int> chunk, EventSink<List<int>> out) {
      if (generation == feederGeneration) {
        submittedBytes += chunk.length;
      }
      out.add(chunk);
    },
  );

  final Stopwatch wall = Stopwatch()..start();
  final List<double> submittedLeadSamples = <double>[];
  final List<double> pulseLatencySamples = <double>[];

  final Future<void> feeder = () async {
    try {
      await sink.stdin.addStream(decoder.stdout.transform(counted));
      await sink.stdin.close();
    } catch (_) {
      // Expected after the intentional kill at the end of the probe.
    }
  }();

  for (int i = 0; i < seconds; i++) {
    await Future<void>.delayed(const Duration(seconds: 1));

    final double elapsedSec = wall.elapsedMicroseconds / 1000000.0;
    final int submittedFrames = submittedBytes ~/ _bytesPerSampleFrame;
    final double submittedSec = submittedFrames / _sampleRate;
    final double submittedLeadMs = (submittedSec - elapsedSec) * 1000.0;

    final _PulseLatency? pulse =
        pactlAvailable ? await _readPulseLatency() : null;

    if (elapsedSec >= 3.0) {
      submittedLeadSamples.add(submittedLeadMs);
      if (pulse != null) pulseLatencySamples.add(pulse.totalMs);
    }

    final StringBuffer line = StringBuffer(
      't=${elapsedSec.toStringAsFixed(2)}s  '
      'submitted=$submittedFrames  '
      'lead=${submittedLeadMs.toStringAsFixed(2)}ms',
    );
    if (pulse != null) {
      line.write(
        '  pulse=${pulse.totalMs.toStringAsFixed(2)}ms'
        ' (buffer=${pulse.bufferMs.toStringAsFixed(2)},'
        ' sink=${pulse.sinkMs.toStringAsFixed(2)})',
      );
    }
    stdout.writeln(line);
  }

  // Future production ordering contract:
  //   1. invalidate the old generation so it cannot increment the counter,
  //   2. stop both processes,
  //   3. await the feeder,
  //   4. only then is it legal to capture a new origin_sample.
  generation++;
  _killQuietly(decoder);
  _killQuietly(sink);

  try {
    await feeder.timeout(const Duration(seconds: 3));
  } on TimeoutException {
    stderr.writeln('ERROR: feeder did not quiesce within 3 seconds.');
    exitCode = 3;
    return;
  }

  final int atQuiescence = submittedBytes;
  await Future<void>.delayed(const Duration(milliseconds: 250));
  final bool counterStopped = submittedBytes == atQuiescence;

  wall.stop();

  stdout.writeln('');
  stdout.writeln('quiescence: ${counterStopped ? 'PASS' : 'FAIL'}');
  stdout.writeln(
    'final submitted sample frames: '
    '${submittedBytes ~/ _bytesPerSampleFrame}',
  );
  _printStats('submitted lead', submittedLeadSamples);
  _printStats('PulseAudio reported latency', pulseLatencySamples);

  stdout.writeln('');
  stdout.writeln(
    'Interpretation: submitted lead includes bytes accepted upstream of the '
    'speaker. PulseAudio latency is its reported stream-buffer plus sink '
    'latency. We are looking for a bounded, narrow-band relationship rather '
    'than a continuously growing or sawtooth submitted lead.',
  );

  if (!counterStopped) exitCode = 4;
}

void _printStats(String label, List<double> values) {
  if (values.isEmpty) {
    stdout.writeln('$label: unavailable');
    return;
  }

  final double minValue = values.reduce((a, b) => a < b ? a : b);
  final double maxValue = values.reduce((a, b) => a > b ? a : b);
  final double average = values.reduce((a, b) => a + b) / values.length;

  stdout.writeln('$label average: ${average.toStringAsFixed(2)}ms');
  stdout.writeln(
    '$label min/max: ${minValue.toStringAsFixed(2)} / '
    '${maxValue.toStringAsFixed(2)}ms',
  );
  stdout.writeln(
    '$label spread: ${(maxValue - minValue).toStringAsFixed(2)}ms',
  );
}

Future<_PulseLatency?> _readPulseLatency() async {
  try {
    final ProcessResult result = await Process.run(
      'pactl',
      <String>['-f', 'json', 'list', 'sink-inputs'],
    );
    if (result.exitCode != 0) return null;

    final Object? decoded = jsonDecode(result.stdout as String);
    if (decoded is! List) return null;

    for (final Object? item in decoded) {
      if (item is! Map) continue;
      final Map<Object?, Object?> map = item;
      final Object? propertiesRaw = map['properties'];
      final Map<Object?, Object?> properties =
          propertiesRaw is Map ? propertiesRaw : const <Object?, Object?>{};

      final String applicationName =
          '${properties['application.name'] ?? ''}';
      final String mediaName = '${properties['media.name'] ?? ''}';
      final String streamName = '${map['name'] ?? ''}';

      if (applicationName != _pulseName &&
          mediaName != _pulseName &&
          streamName != _pulseName) {
        continue;
      }

      final double bufferUsec = _asDouble(map['buffer_usec']);
      final double sinkUsec = _asDouble(map['sink_usec']);
      return _PulseLatency(
        bufferMs: bufferUsec / 1000.0,
        sinkMs: sinkUsec / 1000.0,
      );
    }
  } catch (_) {}

  return null;
}

double _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse('$value') ?? 0.0;
}

int _readIntOption(
  List<String> args,
  String prefix, {
  required int fallback,
  required int min,
  required int max,
}) {
  final String? raw = _readOption(args, prefix);
  if (raw == null) return fallback;

  final int? parsed = int.tryParse(raw);
  if (parsed == null || parsed < min || parsed > max) {
    throw ArgumentError('$prefix must be between $min and $max.');
  }
  return parsed;
}

String? _readOption(List<String> args, String prefix) {
  for (final String arg in args) {
    if (arg.startsWith(prefix)) return arg.substring(prefix.length);
  }
  return null;
}

Future<bool> _exists(String binary) async {
  try {
    final ProcessResult result = await Process.run('which', <String>[binary]);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<_SinkBackend?> _findSinkBackend(
  String? device,
  int latencyMs,
) async {
  if (await _exists('paplay')) {
    return _SinkBackend('paplay', <String>[
      '--raw',
      '--format=s16le',
      '--rate=$_sampleRate',
      '--channels=$_channels',
      '--client-name=$_pulseName',
      '--stream-name=$_pulseName',
      '--latency-msec=$latencyMs',
      if (device != null && device.isNotEmpty) '--device=$device',
    ]);
  }

  if (await _exists('aplay')) {
    return _SinkBackend('aplay', <String>[
      '-t', 'raw',
      '-f', 'S16_LE',
      '-r', '$_sampleRate',
      '-c', '$_channels',
      '-q',
      if (device != null && device.isNotEmpty) ...<String>['-D', device],
    ]);
  }

  return null;
}

void _killQuietly(Process process) {
  try {
    process.kill(ProcessSignal.sigterm);
  } catch (_) {}
}

class _SinkBackend {
  final String name;
  final List<String> args;

  const _SinkBackend(this.name, this.args);
}

class _PulseLatency {
  final double bufferMs;
  final double sinkMs;

  const _PulseLatency({required this.bufferMs, required this.sinkMs});

  double get totalMs => bufferMs + sinkMs;
}
