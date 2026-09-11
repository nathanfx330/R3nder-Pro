// ./test/structural_audio_gain_cache_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/structural_audio_cache.dart';
import 'package:r3nder/structural_audio_plan.dart';

String _script(String suffix) => '''[EDIT:main]
[TRACK:V1]
[CLIP:a:video/a.mp4:0:0:1:1$suffix]
[/CLIP]
[/TRACK]
[/EDIT]
''';

void main() {
  test('GAIN and MUTE each change StructuralSourceAudioKey', () async {
    final Directory workspace =
        await Directory.systemTemp.createTemp('r3nder_gain_cache_');
    addTearDown(() async {
      if (workspace.existsSync()) await workspace.delete(recursive: true);
    });

    final Directory video = Directory(
      '${workspace.path}${Platform.pathSeparator}video',
    )..createSync(recursive: true);
    File('${video.path}${Platform.pathSeparator}a.mp4')
        .writeAsBytesSync(<int>[1, 2, 3, 4]);

    String resolve(String source) =>
        '${workspace.path}${Platform.pathSeparator}'
        '${source.replaceAll('/', Platform.pathSeparator)}';

    StructuralSourceAudioKey keyFor(String suffix) {
      final StructuralAudioPlan plan =
          StructuralAudioPlanner.parse(_script(suffix)).plan('EDIT.main');
      return StructuralSourceAudioKey.fromPlan(
        plan: plan,
        resolveSource: resolve,
        ffmpegVersion: 'ffmpeg test build',
      );
    }

    final StructuralSourceAudioKey unity = keyFor('');
    final StructuralSourceAudioKey gained = keyFor(':GAIN=-6.0');
    final StructuralSourceAudioKey muted = keyFor(':GAIN=-6.0:MUTE');

    expect(gained.digest, isNot(unity.digest));
    expect(muted.digest, isNot(gained.digest));
    expect(gained.manifest, contains('segment_gain_tenths_db=-60'));
    expect(gained.manifest, contains('segment_muted=0'));
    expect(muted.manifest, contains('segment_gain_tenths_db=-60'));
    expect(muted.manifest, contains('segment_muted=1'));
  });
}
