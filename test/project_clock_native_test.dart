// ./test/project_clock_native_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'native ProjectClock control block stays coherent under raced writers',
    () async {
      final Directory temp =
          await Directory.systemTemp.createTemp('r3nder_project_clock_');
      final String binary = '${temp.path}/project_clock_test';

      try {
        final ProcessResult compile = await Process.run('g++', <String>[
          '-std=c++17',
          '-O2',
          '-pthread',
          '-Wall',
          '-Wextra',
          '-Werror',
          'linux/runner/project_clock.cc',
          'linux/runner/project_clock_test.cc',
          '-o',
          binary,
        ]);

        expect(
          compile.exitCode,
          0,
          reason: 'Native clock test failed to compile.\n'
              'stdout:\n${compile.stdout}\n'
              'stderr:\n${compile.stderr}',
        );

        final ProcessResult run = await Process.run(binary, const <String>[]);
        expect(
          run.exitCode,
          0,
          reason: 'Native clock regression failed.\n'
              'stdout:\n${run.stdout}\n'
              'stderr:\n${run.stderr}',
        );
        expect('${run.stdout}', contains('project_clock_test: PASS'));
      } finally {
        if (temp.existsSync()) {
          temp.deleteSync(recursive: true);
        }
      }
    },
    skip: Platform.isLinux
        ? false
        : 'Native realtime ProjectClock is currently Linux-only.',
  );
}
