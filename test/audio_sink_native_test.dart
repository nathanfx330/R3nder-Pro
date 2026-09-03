// ./test/audio_sink_native_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Future<void> _compileAndRunAudioSinkTest({
  required Directory temp,
  required List<String> pkgArgs,
  required String suffix,
  List<String> defines = const <String>[],
}) async {
  final String binary = '${temp.path}/audio_sink_test_$suffix';

  final ProcessResult compile = await Process.run('g++', <String>[
    '-std=c++14',
    '-O2',
    '-pthread',
    '-Wall',
    '-Wextra',
    '-Werror',
    ...defines,
    'linux/runner/project_clock.cc',
    'linux/runner/audio_sink.cc',
    'linux/runner/audio_sink_test.cc',
    ...pkgArgs,
    '-o',
    binary,
  ]);

  expect(
    compile.exitCode,
    0,
    reason: 'Native audio clock test ($suffix) failed to compile.\n'
        'stdout:\n${compile.stdout}\n'
        'stderr:\n${compile.stderr}',
  );

  final ProcessResult run = await Process.run(binary, const <String>[]);
  expect(
    run.exitCode,
    0,
    reason: 'Native audio clock regression ($suffix) failed.\n'
        'stdout:\n${run.stdout}\n'
        'stderr:\n${run.stderr}',
  );
  expect(
    '${run.stdout}',
    anyOf(
      contains('audio_sink_test: PASS'),
      contains('audio_sink_test: SKIP'),
    ),
  );
}

void main() {
  test(
    'native audio sink drives ProjectClock and bounds flush/destroy waits',
    () async {
      final ProcessResult pkg = await Process.run(
        'pkg-config',
        const <String>['--cflags', '--libs', 'libpulse-simple'],
      );
      if (pkg.exitCode != 0) {
        // A source-only/test environment may not have the Linux development
        // package even though portable runtime builds are produced elsewhere.
        return;
      }

      final Directory temp =
          await Directory.systemTemp.createTemp('r3nder_audio_sink_');

      try {
        final List<String> pkgArgs = '${pkg.stdout}'
            .trim()
            .split(RegExp(r'\s+'))
            .where((String part) => part.isNotEmpty)
            .toList();

        await _compileAndRunAudioSinkTest(
          temp: temp,
          pkgArgs: pkgArgs,
          suffix: 'normal',
        );

        // Deterministic fault injection for the caller-side flush timeout only.
        // The production default remains 2000 ms. Here the worker deliberately
        // stalls for 100 ms while the caller is allowed to wait only 25 ms.
        await _compileAndRunAudioSinkTest(
          temp: temp,
          pkgArgs: pkgArgs,
          suffix: 'flush_timeout',
          defines: const <String>[
            '-DR3_AUDIO_SINK_FLUSH_TIMEOUT_MS=25',
            '-DR3_AUDIO_SINK_TEST_FLUSH_STALL_MS=100',
            '-DR3_AUDIO_SINK_EXPECT_FLUSH_TIMEOUT=1',
          ],
        );

        // The shutdown regression uses the same pattern. The worker remains
        // alive for 100 ms after close, but destroy is allowed to wait only 25
        // ms. It must return, release ProjectClock safely, and let the detached
        // worker own its eventual native cleanup.
        await _compileAndRunAudioSinkTest(
          temp: temp,
          pkgArgs: pkgArgs,
          suffix: 'destroy_timeout',
          defines: const <String>[
            '-DR3_AUDIO_SINK_DESTROY_TIMEOUT_MS=25',
            '-DR3_AUDIO_SINK_TEST_DESTROY_STALL_MS=100',
            '-DR3_AUDIO_SINK_EXPECT_DESTROY_TIMEOUT=1',
          ],
        );
      } finally {
        if (temp.existsSync()) {
          temp.deleteSync(recursive: true);
        }
      }
    },
    skip: Platform.isLinux
        ? false
        : 'Native audio sink is currently Linux-only.',
  );
}
