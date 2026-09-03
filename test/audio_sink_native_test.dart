// ./test/audio_sink_native_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'native audio sink drives ProjectClock and preserves cumulative samples',
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
      final String binary = '${temp.path}/audio_sink_test';

      try {
        final List<String> pkgArgs = '${pkg.stdout}'
            .trim()
            .split(RegExp(r'\s+'))
            .where((String part) => part.isNotEmpty)
            .toList();

        final ProcessResult compile = await Process.run('g++', <String>[
          '-std=c++14',
          '-O2',
          '-pthread',
          '-Wall',
          '-Wextra',
          '-Werror',
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
          reason: 'Native audio clock test failed to compile.\n'
              'stdout:\n${compile.stdout}\n'
              'stderr:\n${compile.stderr}',
        );

        final ProcessResult run = await Process.run(binary, const <String>[]);
        expect(
          run.exitCode,
          0,
          reason: 'Native audio clock regression failed.\n'
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
