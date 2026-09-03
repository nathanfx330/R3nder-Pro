// ./test/media_decoder_native_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Future<String?> _findMltPkg() async {
  for (final String candidate in <String>['mlt-framework-7', 'mlt-framework']) {
    final ProcessResult result = await Process.run(
      'pkg-config',
      <String>['--exists', candidate],
    );
    if (result.exitCode == 0) return candidate;
  }
  return null;
}

void main() {
  test(
    'persistent native MLT bridge returns exact out-of-order RGBA frames',
    () async {
      final String? mltPkg = await _findMltPkg();
      if (mltPkg == null) {
        return;
      }

      final ProcessResult ffmpegVersion =
          await Process.run('ffmpeg', const <String>['-version']);
      if (ffmpegVersion.exitCode != 0) {
        return;
      }

      final ProcessResult pkg = await Process.run(
        'pkg-config',
        <String>['--cflags', '--libs', mltPkg],
      );
      if (pkg.exitCode != 0) {
        return;
      }

      final Directory temp =
          await Directory.systemTemp.createTemp('r3nder_media_decoder_');
      final String clip = '${temp.path}/clip.mp4';
      final String binary = '${temp.path}/media_decoder_test';

      try {
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
            'testsrc2=size=320x180:rate=30',
            '-t',
            '2',
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
        );
        expect(
          generate.exitCode,
          0,
          reason: 'M9 reference media generation failed.\n'
              'stdout:\n${generate.stdout}\n'
              'stderr:\n${generate.stderr}',
        );

        final List<String> pkgArgs = '${pkg.stdout}'
            .trim()
            .split(RegExp(r'\s+'))
            .where((String part) => part.isNotEmpty)
            .toList();

        final ProcessResult compile = await Process.run(
          'g++',
          <String>[
            '-std=c++14',
            '-O2',
            '-pthread',
            '-Wall',
            '-Wextra',
            '-Werror',
            ...pkgArgs.where((String part) => part.startsWith('-I')),
            'linux/runner/media_decoder.cc',
            'linux/runner/media_decoder_test.cc',
            '-o',
            binary,
            ...pkgArgs.where((String part) => !part.startsWith('-I')),
          ],
        );
        expect(
          compile.exitCode,
          0,
          reason: 'Native M9 decoder test failed to compile.\n'
              'stdout:\n${compile.stdout}\n'
              'stderr:\n${compile.stderr}',
        );

        final ProcessResult run = await Process.run(binary, <String>[clip]);
        expect(
          run.exitCode,
          0,
          reason: 'Native M9 decoder regression failed.\n'
              'stdout:\n${run.stdout}\n'
              'stderr:\n${run.stderr}',
        );
        expect('${run.stdout}', contains('media_decoder_test: PASS'));
      } finally {
        if (temp.existsSync()) {
          temp.deleteSync(recursive: true);
        }
      }
    },
    skip: Platform.isLinux
        ? false
        : 'Persistent MLT media decoding is currently Linux-only.',
  );
}
