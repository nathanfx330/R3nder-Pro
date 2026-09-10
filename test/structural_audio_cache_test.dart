// ./test/structural_audio_cache_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/structural_audio_cache.dart';
import 'package:r3nder/structural_audio_decode.dart';
import 'package:r3nder/structural_audio_plan.dart';

class _CountingNoAudioDecoder implements StructuralAudioLeafDecodeBackend {
  int calls = 0;

  @override
  Future<StructuralAudioLeafDecode> decode(
    StructuralAudioSegment segment,
    String resolvedPath,
  ) async {
    calls++;
    return StructuralAudioLeafDecode.noAudio(
      sourceInfo: StructuralAudioSourceInfo.noAudio(
        path: resolvedPath,
        sourceFpsNumerator: 30,
        sourceFpsDenominator: 1,
      ),
      authoredProjectSampleFrames: segment.sampleCount,
    );
  }
}

String _script({int sourceIn = 0}) => '''[EDIT:main]
[TRACK:V1]
[CLIP:base:video/base.mp4:0:$sourceIn:2:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';

void main() {
  test('dependency-free SHA-256 matches the standard abc vector', () {
    expect(
      structuralAudioSha256Hex('abc'),
      'ba7816bf8f01cfea414140de5dae2223'
      'b00361a396177a9cb410ff61f20015ad',
    );
  });

  test('identical source audio inputs reuse the persistent WAV', () async {
    final Directory workspace =
        await Directory.systemTemp.createTemp('r3nder_source_audio_cache_');
    addTearDown(() async {
      if (workspace.existsSync()) {
        await workspace.delete(recursive: true);
      }
    });

    final Directory video = Directory(
      '${workspace.path}${Platform.pathSeparator}video',
    )..createSync(recursive: true);
    final File media = File(
      '${video.path}${Platform.pathSeparator}base.mp4',
    )..writeAsBytesSync(<int>[1, 2, 3, 4]);

    final _CountingNoAudioDecoder decoder = _CountingNoAudioDecoder();
    int versionCalls = 0;
    final StructuralSourceAudioCache cache = StructuralSourceAudioCache(
      workspaceRoot: workspace.path,
      resolveSource: (String source) =>
          '${workspace.path}${Platform.pathSeparator}'
          '${source.replaceAll('/', Platform.pathSeparator)}',
      leafDecoder: decoder,
      ffmpegVersionResolver: () async {
        versionCalls++;
        return 'ffmpeg test build';
      },
    );

    final StructuralSourceAudioArtifact first = await cache.prepare(
      rawDocument: _script(),
      structuralSource: 'EDIT.main',
    );
    final StructuralSourceAudioArtifact second = await cache.prepare(
      rawDocument: _script(),
      structuralSource: 'EDIT.main',
    );

    expect(media.existsSync(), isTrue);
    expect(first.cacheHit, isFalse);
    expect(second.cacheHit, isTrue);
    expect(first.key.digest, second.key.digest);
    expect(first.path, second.path);
    expect(first.sampleFrames, 3200);
    expect(File(first.path).existsSync(), isTrue);
    expect(decoder.calls, 1);
    expect(versionCalls, 1);
  });

  test('clip trim and leaf mtime each invalidate SourceAudioKey', () async {
    final Directory workspace =
        await Directory.systemTemp.createTemp('r3nder_source_audio_key_');
    addTearDown(() async {
      if (workspace.existsSync()) {
        await workspace.delete(recursive: true);
      }
    });

    final Directory video = Directory(
      '${workspace.path}${Platform.pathSeparator}video',
    )..createSync(recursive: true);
    final File media = File(
      '${video.path}${Platform.pathSeparator}base.mp4',
    )..writeAsBytesSync(<int>[9, 8, 7, 6]);

    final _CountingNoAudioDecoder decoder = _CountingNoAudioDecoder();
    final StructuralSourceAudioCache cache = StructuralSourceAudioCache(
      workspaceRoot: workspace.path,
      resolveSource: (String source) =>
          '${workspace.path}${Platform.pathSeparator}'
          '${source.replaceAll('/', Platform.pathSeparator)}',
      leafDecoder: decoder,
      ffmpegVersionResolver: () async => 'ffmpeg test build',
    );

    final StructuralSourceAudioArtifact original = await cache.prepare(
      rawDocument: _script(),
      structuralSource: 'EDIT.main',
    );
    final StructuralSourceAudioArtifact trimmed = await cache.prepare(
      rawDocument: _script(sourceIn: 1),
      structuralSource: 'EDIT.main',
    );

    expect(trimmed.cacheHit, isFalse);
    expect(trimmed.key.digest, isNot(original.key.digest));
    expect(decoder.calls, 2);

    final DateTime changedMtime =
        media.lastModifiedSync().add(const Duration(seconds: 2));
    media.setLastModifiedSync(changedMtime);

    final StructuralSourceAudioArtifact touched = await cache.prepare(
      rawDocument: _script(),
      structuralSource: 'EDIT.main',
    );

    expect(touched.cacheHit, isFalse);
    expect(touched.key.digest, isNot(original.key.digest));
    expect(decoder.calls, 3);
  });
}
