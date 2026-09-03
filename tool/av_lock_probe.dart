// ./tool/av_lock_probe.dart
//
// One-command runner for the M4 sustained A/V lock probe.
//
// Usage from the repository root:
//
//   dart run tool/av_lock_probe.dart
//   dart run tool/av_lock_probe.dart --seconds=30
//
// The runner generates temporary 1080p H.264 reference media, compiles the
// native probe against the same ProjectClock, PulseAudio sink, and MLT decoder
// used by R3nder, then records two sessions:
//
//   baseline  real audio sink + AUDIO ProjectClock, no video decoder
//   video     same clock while persistent MLT decoding is driven at 60 Hz
//
// The combined log is written beside pubspec.yaml as
// r3nder_av_lock_session_NNN.log. Temporary media and binaries are removed.

import 'dart:io';

const int _defaultSeconds = 15;
const int _minimumSeconds = 5;
const int _maximumSeconds = 300;

Future<String?> _findMltPackage() async {
  for (final String candidate in <String>[
    'mlt-framework-7',
    'mlt-framework',
  ]) {
    final ProcessResult result = await Process.run(
      'pkg-config',
      <String>['--exists', candidate],
    );
    if (result.exitCode == 0) return candidate;
  }
  return null;
}

Future<List<String>?> _pkgConfig(String package) async {
  final ProcessResult result = await Process.run(
    'pkg-config',
    <String>['--cflags', '--libs', package],
  );
  if (result.exitCode != 0) return null;
  return '${result.stdout}'
      .trim()
      .split(RegExp(r'\s+'))
      .where((String value) => value.isNotEmpty)
      .toList();
}

bool _isCompileFlag(String value) {
  return value.startsWith('-I') ||
      value.startsWith('-D') ||
      value.startsWith('-U') ||
      value.startsWith('-f');
}

int _parseSeconds(List<String> args) {
  for (final String arg in args) {
    if (!arg.startsWith('--seconds=')) continue;
    final int? parsed = int.tryParse(arg.substring('--seconds='.length));
    if (parsed == null || parsed < _minimumSeconds || parsed > _maximumSeconds) {
      stderr.writeln(
        '--seconds must be an integer from $_minimumSeconds to $_maximumSeconds.',
      );
      exitCode = 64;
      return -1;
    }
    return parsed;
  }
  return _defaultSeconds;
}

int _nextSessionNumber(Directory root) {
  final RegExp pattern = RegExp(r'^r3nder_av_lock_session_(\d+)\.log$');
  int highest = 0;
  for (final FileSystemEntity entry in root.listSync()) {
    if (entry is! File) continue;
    final String name = entry.uri.pathSegments.isNotEmpty
        ? entry.uri.pathSegments.last
        : '';
    final RegExpMatch? match = pattern.firstMatch(name);
    if (match == null) continue;
    final int value = int.tryParse(match.group(1) ?? '') ?? 0;
    if (value > highest) highest = value;
  }
  return highest + 1;
}

String _shortGitHead(Directory root) {
  try {
    final ProcessResult result = Process.runSync(
      'git',
      const <String>['rev-parse', '--short', 'HEAD'],
      workingDirectory: root.path,
    );
    if (result.exitCode == 0) return '${result.stdout}'.trim();
  } catch (_) {}
  return 'unknown';
}

String _gitBranch(Directory root) {
  try {
    final ProcessResult result = Process.runSync(
      'git',
      const <String>['branch', '--show-current'],
      workingDirectory: root.path,
    );
    if (result.exitCode == 0) return '${result.stdout}'.trim();
  } catch (_) {}
  return 'unknown';
}

Iterable<String> _summaryLines(Object output) sync* {
  for (final String line in '$output'.split('\n')) {
    if (line.startsWith('SUMMARY ') ||
        line.startsWith('AV_LOCK_PASS ') ||
        line.startsWith('AV_LOCK_SKIP ') ||
        line.startsWith('AV_LOCK_FAIL ')) {
      yield line;
    }
  }
}

Future<void> main(List<String> args) async {
  final int seconds = _parseSeconds(args);
  if (seconds < 0) return;

  final Directory root = Directory.current.absolute;
  if (!File('${root.path}/pubspec.yaml').existsSync()) {
    stderr.writeln(
      'Run this command from the R3nder Pro repository root beside pubspec.yaml.',
    );
    exitCode = 64;
    return;
  }

  final String? mltPackage = await _findMltPackage();
  if (mltPackage == null) {
    stderr.writeln(
      'M4 probe skipped: pkg-config could not find mlt-framework-7 or mlt-framework.',
    );
    exitCode = 2;
    return;
  }

  final List<String>? mltFlags = await _pkgConfig(mltPackage);
  final List<String>? pulseFlags = await _pkgConfig('libpulse-simple');
  if (mltFlags == null || pulseFlags == null) {
    stderr.writeln(
      'M4 probe skipped: development flags for MLT or libpulse-simple are missing.',
    );
    exitCode = 2;
    return;
  }

  final ProcessResult ffmpegVersion =
      await Process.run('ffmpeg', const <String>['-version']);
  if (ffmpegVersion.exitCode != 0) {
    stderr.writeln('M4 probe requires ffmpeg to generate reference media.');
    exitCode = 2;
    return;
  }

  final Directory temp =
      await Directory.systemTemp.createTemp('r3nder_av_lock_');
  final String clip = '${temp.path}/av_lock_reference.mp4';
  final String binary = '${temp.path}/av_lock_probe';
  final int durationMs = seconds * 1000;
  final int clipSeconds = seconds + 5;

  final int session = _nextSessionNumber(root);
  final String sessionLabel = session.toString().padLeft(3, '0');
  final File log = File(
    '${root.path}/r3nder_av_lock_session_$sessionLabel.log',
  );
  final StringBuffer report = StringBuffer()
    ..writeln('# R3nder M4 sustained A/V lock trace v1')
    ..writeln('# started=${DateTime.now().toIso8601String()}')
    ..writeln('# branch=${_gitBranch(root)}')
    ..writeln('# head=${_shortGitHead(root)}')
    ..writeln('# seconds_per_mode=$seconds')
    ..writeln('# mlt_pkg=$mltPackage')
    ..writeln('# video_source=1920x1080@30 H.264')
    ..writeln('# video_decode_request=960x540')
    ..writeln('# audio=48000Hz stereo s16le silence')
    ..writeln('# presentation_sample_period_us=16667')
    ..writeln();

  try {
    stdout.writeln('M4: generating ${clipSeconds}s 1080p reference clip...');
    final ProcessResult generate = await Process.run(
      'ffmpeg',
      <String>[
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-f',
        'lavfi',
        '-i',
        'testsrc2=size=1920x1080:rate=30',
        '-t',
        '$clipSeconds',
        '-an',
        '-c:v',
        'libx264',
        '-preset',
        'veryfast',
        '-g',
        '30',
        '-keyint_min',
        '30',
        '-sc_threshold',
        '0',
        '-pix_fmt',
        'yuv420p',
        clip,
      ],
      workingDirectory: root.path,
    );
    report
      ..writeln('## GENERATE')
      ..writeln('exit=${generate.exitCode}')
      ..writeln('${generate.stdout}')
      ..writeln('${generate.stderr}');
    if (generate.exitCode != 0) {
      stderr.writeln('M4 reference media generation failed.');
      log.writeAsStringSync(report.toString());
      exitCode = 1;
      return;
    }

    final List<String> allFlags = <String>[
      ...pulseFlags,
      ...mltFlags,
    ];
    final List<String> compileFlags =
        allFlags.where(_isCompileFlag).toSet().toList();
    final List<String> linkFlags = allFlags
        .where((String value) => !_isCompileFlag(value) && value != '-pthread')
        .toSet()
        .toList();

    stdout.writeln('M4: compiling native A/V probe...');
    final ProcessResult compile = await Process.run(
      'g++',
      <String>[
        '-std=c++14',
        '-O2',
        '-pthread',
        '-Wall',
        '-Wextra',
        '-Werror',
        ...compileFlags,
        'linux/runner/project_clock.cc',
        'linux/runner/audio_sink.cc',
        'linux/runner/media_decoder.cc',
        'linux/runner/av_lock_probe.cc',
        '-o',
        binary,
        ...linkFlags,
      ],
      workingDirectory: root.path,
    );
    report
      ..writeln('## COMPILE')
      ..writeln('exit=${compile.exitCode}')
      ..writeln('${compile.stdout}')
      ..writeln('${compile.stderr}');
    if (compile.exitCode != 0) {
      stderr.writeln('M4 native probe failed to compile.');
      stderr.writeln('${compile.stderr}');
      log.writeAsStringSync(report.toString());
      exitCode = 1;
      return;
    }

    stdout.writeln('M4: baseline audio clock run for ${seconds}s...');
    final ProcessResult baseline = await Process.run(
      binary,
      <String>['baseline', '$durationMs'],
      workingDirectory: root.path,
    );
    report
      ..writeln('## BASELINE')
      ..writeln('exit=${baseline.exitCode}')
      ..writeln('${baseline.stdout}')
      ..writeln('${baseline.stderr}');
    for (final String line in _summaryLines(baseline.stdout)) {
      stdout.writeln(line);
    }

    if (baseline.exitCode != 0) {
      stderr.writeln('M4 baseline run failed.');
      log.writeAsStringSync(report.toString());
      exitCode = 1;
      return;
    }

    if ('${baseline.stdout}'.contains('AV_LOCK_SKIP ')) {
      stdout.writeln('M4 probe skipped by the native audio backend.');
      log.writeAsStringSync(report.toString());
      stdout.writeln('Trace written: ${log.path}');
      return;
    }

    stdout.writeln('M4: audio clock + sustained MLT run for ${seconds}s...');
    final ProcessResult video = await Process.run(
      binary,
      <String>['video', '$durationMs', clip],
      workingDirectory: root.path,
    );
    report
      ..writeln('## VIDEO')
      ..writeln('exit=${video.exitCode}')
      ..writeln('${video.stdout}')
      ..writeln('${video.stderr}');
    for (final String line in _summaryLines(video.stdout)) {
      stdout.writeln(line);
    }

    log.writeAsStringSync(report.toString());
    stdout.writeln('Trace written: ${log.path}');

    if (video.exitCode != 0) {
      stderr.writeln('M4 video-load run failed.');
      exitCode = 1;
      return;
    }

    stdout.writeln(
      'M4 measurement complete. Send ${log.path.split(Platform.pathSeparator).last} for analysis.',
    );
  } finally {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  }
}
