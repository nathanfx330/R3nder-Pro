// ./tool/audio_clock_probe.dart
//
// Diagnostic probe for the future AUDIO ProjectClock authority.
//
// This intentionally does not change preview behavior. It exercises the same
// transport shape as AudioBedPlayer: ffmpeg produces raw s16le stereo 48 kHz
// PCM, Dart forwards it to paplay/aplay with addStream backpressure, and every
// forwarded byte is counted. The probe reports how far submitted PCM runs
// ahead of wall time and proves that invalidating a generation plus awaiting
// the feeder creates a real quiescence boundary.

import 'dart:async';
import 'dart:io';

const int _sampleRate = 48000;
const int _channels = 2;
const int _bytesPerSample = 2;
const int _bytesPerSampleFrame = _channels * _bytesPerSample;

Future<void> main(List<String> args) async {
  final int seconds = _readSeconds(args);
  final String? requestedDevice = _readOption(args, '--device=');

  if (!await _exists('ffmpeg')) {
    stderr.writeln('ERROR: ffmpeg is not available.');
    exitCode = 2;
    return;
  }

  final _SinkBackend? backend = await _findSinkBackend(requestedDevice);
  if (backend == null) {
    stderr.writeln('ERROR: neither paplay nor aplay is available.');
    exitCode = 2;
    return;
  }

  stdout.writeln('R3NDER AUDIO CLOCK PROBE');
  stdout.writeln('backend: ${backend.name}');
  stdout.writeln('duration: ${seconds}s');
  stdout.writeln('format: s16le stereo ${_sampleRate} Hz');
  stdout.writeln('device: ${requestedDevice ?? 'default'}');
  stdout.writeln('');

  final Process decoder = await Process.start('ffmpeg', <String>[
    '-v', 'error',
    '-f', 'lavfi',
    '-i', 'sine=frequency=440:sample_rate=$_sampleRate',
    '-filter:a', 'volume=0.05',
    '-f', 's16le',
    '-acodec', 'pcm_s16le',
    '-ac', '$_channels',
    '-ar', '$_sampleRate',
    '-',
  ]);

  final Process sink = await Process.start(backend.name, backend.args);

  unawaited(decoder.stderr
      .transform(systemEncoding.decoder)
      .forEach((String line) => stderr.write(line)));
  unawaited(sink.stderr
      .transform(systemEncoding.decoder)
      .forEach((String line) => stderr.write(line)));
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
  final List<double> steadyLeadMs = <double>[];

  final Future<void> feeder = () async {
    try {
      await sink.stdin.addStream(decoder.stdout.transform(counted));
      await sink.stdin.close();
    } catch (_) {
      // Expected after the intentional kill at the end of the probe.
    }
  }();

  final Timer report = Timer.periodic(const Duration(seconds: 1), (_) {
    final double elapsedSec = wall.elapsedMicroseconds / 1000000.0;
    final int submittedFrames = submittedBytes ~/ _bytesPerSampleFrame;
    final double submittedSec = submittedFrames / _sampleRate;
    final double leadMs = (submittedSec - elapsedSec) * 1000.0;

    if (elapsedSec >= 3.0) steadyLeadMs.add(leadMs);

    stdout.writeln(
      't=${elapsedSec.toStringAsFixed(2)}s  '
      'submitted=$submittedFrames  '
      'lead=${leadMs.toStringAsFixed(2)}ms',
    );
  });

  await Future<void>.delayed(Duration(seconds: seconds));

  // The future production contract starts here:
  //   1. invalidate the old generation so it cannot increment the counter,
  //   2. stop both processes,
  //   3. await the feeder,
  //   4. only then is it legal to capture a new origin_sample.
  generation++;
  report.cancel();
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
      'final submitted sample frames: ${submittedBytes ~/ _bytesPerSampleFrame}');

  if (steadyLeadMs.isNotEmpty) {
    final double minLead = steadyLeadMs.reduce((a, b) => a < b ? a : b);
    final double maxLead = steadyLeadMs.reduce((a, b) => a > b ? a : b);
    final double spread = maxLead - minLead;
    final double average =
        steadyLeadMs.reduce((a, b) => a + b) / steadyLeadMs.length;

    stdout.writeln(
        'steady lead average: ${average.toStringAsFixed(2)}ms');
    stdout.writeln(
        'steady lead min/max: ${minLead.toStringAsFixed(2)} / '
        '${maxLead.toStringAsFixed(2)}ms');
    stdout.writeln('steady lead spread: ${spread.toStringAsFixed(2)}ms');
  } else {
    stdout.writeln('steady lead: not enough runtime; use at least 5 seconds.');
  }

  stdout.writeln('');
  stdout.writeln(
      'Interpretation: the absolute lead includes OS pipe, sink, server, and '
      'device buffering. The important first result is whether the lead '
      'settles to a narrow band instead of increasing continuously.');

  if (!counterStopped) exitCode = 4;
}

int _readSeconds(List<String> args) {
  final String? raw = _readOption(args, '--seconds=');
  if (raw == null) return 20;
  final int? parsed = int.tryParse(raw);
  if (parsed == null || parsed < 3 || parsed > 600) {
    throw ArgumentError('--seconds must be between 3 and 600.');
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
    final ProcessResult r = await Process.run('which', <String>[binary]);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<_SinkBackend?> _findSinkBackend(String? device) async {
  if (await _exists('paplay')) {
    return _SinkBackend('paplay', <String>[
      '--raw',
      '--format=s16le',
      '--rate=$_sampleRate',
      '--channels=$_channels',
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
