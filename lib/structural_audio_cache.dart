// ./lib/structural_audio_cache.dart
//
// Persistent content-addressed cache for deterministic EDIT/MOSAIC source audio.
//
// StructuralAudioSourceRenderer deliberately owns composition only. This module
// owns artifact reuse across PLAY presses and application runs. A cache key is
// derived only from the selected structural source graph, resolved leaf file
// identity, deterministic renderer policy, and ffmpeg toolchain identity.
// Unrelated terminal text, STRUCT placement chrome, or titles therefore cannot
// invalidate a source-audio artifact.

import 'dart:convert';
import 'dart:io';

import 'structural_audio_decode.dart';
import 'structural_audio_plan.dart';
import 'structural_audio_render.dart';

const int kStructuralSourceAudioCacheSchemaVersion = 2;
const int _kFloatWavHeaderBytes = 44;
const int _kUint32Mask = 0xffffffff;

typedef StructuralAudioFfmpegVersionResolver = Future<String> Function();

class StructuralSourceAudioKey {
  final String digest;
  final String manifest;

  const StructuralSourceAudioKey({
    required this.digest,
    required this.manifest,
  });

  static StructuralSourceAudioKey fromPlan({
    required StructuralAudioPlan plan,
    required String Function(String source) resolveSource,
    required String ffmpegVersion,
  }) {
    final String manifest = _sourceAudioManifest(
      plan: plan,
      resolveSource: resolveSource,
      ffmpegVersion: ffmpegVersion,
    );
    return StructuralSourceAudioKey(
      digest: structuralAudioSha256Hex(manifest),
      manifest: manifest,
    );
  }
}

class StructuralSourceAudioArtifact {
  final StructuralSourceAudioKey key;
  final String path;
  final int sampleFrames;
  final bool cacheHit;

  const StructuralSourceAudioArtifact({
    required this.key,
    required this.path,
    required this.sampleFrames,
    required this.cacheHit,
  });
}

class StructuralSourceAudioCache {
  final String workspaceRoot;
  final String Function(String source) resolveSource;
  final StructuralAudioLeafDecodeBackend leafDecoder;
  final StructuralAudioFfmpegVersionResolver ffmpegVersionResolver;

  final Map<String, Future<StructuralSourceAudioArtifact>> _inFlight =
      <String, Future<StructuralSourceAudioArtifact>>{};
  String? _ffmpegVersion;

  StructuralSourceAudioCache({
    required this.workspaceRoot,
    required this.resolveSource,
    required this.leafDecoder,
    required this.ffmpegVersionResolver,
  });

  factory StructuralSourceAudioCache.ffmpeg({
    required String workspaceRoot,
    required String Function(String source) resolveSource,
  }) {
    final StructuralAudioLeafDecoder decoder = StructuralAudioLeafDecoder();
    return StructuralSourceAudioCache(
      workspaceRoot: workspaceRoot,
      resolveSource: resolveSource,
      leafDecoder: FfmpegStructuralAudioLeafDecodeBackend(decoder: decoder),
      ffmpegVersionResolver: decoder.ffmpegVersionString,
    );
  }

  Directory get cacheDirectory => Directory(
        '${Directory(workspaceRoot).absolute.path}${Platform.pathSeparator}'
        '.r3nder${Platform.pathSeparator}cache${Platform.pathSeparator}'
        'audio${Platform.pathSeparator}source${Platform.pathSeparator}'
        'v$kStructuralSourceAudioCacheSchemaVersion',
      );

  Future<StructuralSourceAudioArtifact> prepare({
    required String rawDocument,
    required String structuralSource,
  }) async {
    final StructuralAudioPlanner planner =
        StructuralAudioPlanner.parse(rawDocument);
    final StructuralAudioPlan plan = planner.plan(structuralSource);
    final String ffmpegVersion = await _resolveFfmpegVersion();
    final StructuralSourceAudioKey key = StructuralSourceAudioKey.fromPlan(
      plan: plan,
      resolveSource: resolveSource,
      ffmpegVersion: ffmpegVersion,
    );

    final Directory directory = cacheDirectory;
    final String path = '${directory.path}${Platform.pathSeparator}'
        '${key.digest}.wav';
    final File cached = File(path);
    final int expectedBytes = _kFloatWavHeaderBytes +
        plan.durationSamples *
            kStructuralAudioChannels *
            kStructuralAudioBytesPerFloatSample;

    if (_isValidArtifact(cached, expectedBytes)) {
      return StructuralSourceAudioArtifact(
        key: key,
        path: path,
        sampleFrames: plan.durationSamples,
        cacheHit: true,
      );
    }

    final Future<StructuralSourceAudioArtifact>? existing =
        _inFlight[key.digest];
    if (existing != null) return existing;

    final Future<StructuralSourceAudioArtifact> created = _renderAndStore(
      planner: planner,
      plan: plan,
      key: key,
      outputPath: path,
      expectedBytes: expectedBytes,
    );
    _inFlight[key.digest] = created;
    try {
      return await created;
    } finally {
      if (identical(_inFlight[key.digest], created)) {
        _inFlight.remove(key.digest);
      }
    }
  }

  Future<String> _resolveFfmpegVersion() async {
    final String? existing = _ffmpegVersion;
    if (existing != null) return existing;
    final String resolved = (await ffmpegVersionResolver()).trim();
    if (resolved.isEmpty) {
      throw const StructuralAudioDecodeException(
        'ffmpeg version string is empty.',
      );
    }
    _ffmpegVersion = resolved;
    return resolved;
  }

  Future<StructuralSourceAudioArtifact> _renderAndStore({
    required StructuralAudioPlanner planner,
    required StructuralAudioPlan plan,
    required StructuralSourceAudioKey key,
    required String outputPath,
    required int expectedBytes,
  }) async {
    final Directory directory = cacheDirectory;
    directory.createSync(recursive: true);

    final File output = File(outputPath);
    if (output.existsSync() && !_isValidArtifact(output, expectedBytes)) {
      output.deleteSync();
    }

    final StructuralAudioSourceRenderer renderer = StructuralAudioSourceRenderer(
      planner: planner,
      leafDecoder: leafDecoder,
      resolveSource: resolveSource,
    );
    final StructuralAudioSourceRender rendered =
        await renderer.render(plan.sourceRef.canonicalSource);
    if (rendered.sampleFrames != plan.durationSamples) {
      throw StructuralAudioRenderException(
        'Rendered source audio length ${rendered.sampleFrames} does not match '
        'planned length ${plan.durationSamples}.',
      );
    }

    final File temporary = File(
      '$outputPath.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await temporary.writeAsBytes(rendered.toWavBytes(), flush: true);
      if (temporary.lengthSync() != expectedBytes) {
        throw StructuralAudioRenderException(
          'Cached source WAV length ${temporary.lengthSync()} does not match '
          'expected length $expectedBytes.',
        );
      }

      if (_isValidArtifact(output, expectedBytes)) {
        temporary.deleteSync();
      } else {
        if (output.existsSync()) output.deleteSync();
        await temporary.rename(output.path);
      }
    } catch (_) {
      try {
        if (temporary.existsSync()) temporary.deleteSync();
      } catch (_) {}
      rethrow;
    }

    return StructuralSourceAudioArtifact(
      key: key,
      path: output.path,
      sampleFrames: plan.durationSamples,
      cacheHit: false,
    );
  }

  static bool _isValidArtifact(File file, int expectedBytes) {
    try {
      return file.existsSync() && file.lengthSync() == expectedBytes;
    } catch (_) {
      return false;
    }
  }
}

String _sourceAudioManifest({
  required StructuralAudioPlan plan,
  required String Function(String source) resolveSource,
  required String ffmpegVersion,
}) {
  final StringBuffer out = StringBuffer()
    ..writeln('source_audio_cache_schema=$kStructuralSourceAudioCacheSchemaVersion')
    ..writeln('source_renderer_schema=$kStructuralAudioSourceRendererSchemaVersion')
    ..writeln('sample_rate=$kStructuralAudioSampleRate')
    ..writeln('channels=$kStructuralAudioChannels')
    ..writeln('ffmpeg=${jsonEncode(ffmpegVersion)}');

  _writePlanManifest(out, plan, resolveSource);
  return out.toString();
}

void _writePlanManifest(
  StringBuffer out,
  StructuralAudioPlan plan,
  String Function(String source) resolveSource,
) {
  out
    ..writeln('plan_begin=${jsonEncode(plan.sourceRef.canonicalSource)}')
    ..writeln('plan_duration_frames=${plan.durationFrames}')
    ..writeln('plan_lane_count=${plan.lanes.length}');

  for (final StructuralAudioLanePlan lane in plan.lanes) {
    out
      ..writeln('lane_begin=${jsonEncode(lane.id)}')
      ..writeln('lane_kind=${lane.kind.name}')
      ..writeln('lane_authored_index=${lane.authoredIndex}')
      ..writeln('lane_segment_count=${lane.segments.length}');

    for (final StructuralAudioSegment segment in lane.segments) {
      out
        ..writeln('segment_begin=${jsonEncode(segment.clipId)}')
        ..writeln('segment_lane=${jsonEncode(segment.laneId)}')
        ..writeln('segment_authored_index=${segment.authoredIndex}')
        ..writeln('segment_source=${jsonEncode(segment.source)}')
        ..writeln('segment_project_start=${segment.projectStartFrame}')
        ..writeln('segment_duration=${segment.durationFrames}')
        ..writeln('segment_source_in=${segment.sourceInFrame}')
        ..writeln('segment_speed_num=${segment.speed.numerator}')
        ..writeln('segment_speed_den=${segment.speed.denominator}')
        ..writeln('segment_gain_tenths_db=${segment.audioGain.tenthsDb}')
        ..writeln('segment_muted=${segment.muted ? 1 : 0}');
      _writeFadeManifest(out, 'incoming', segment.incomingFade);
      _writeFadeManifest(out, 'outgoing', segment.outgoingFade);

      final StructuralAudioPlan? nested = segment.nestedPlan;
      if (nested != null) {
        out.writeln('segment_kind=structural');
        _writePlanManifest(out, nested, resolveSource);
      } else {
        out.writeln('segment_kind=leaf');
        final String resolved = File(resolveSource(segment.source)).absolute.path;
        final FileStat stat = FileStat.statSync(resolved);
        if (stat.type != FileSystemEntityType.file) {
          throw FileSystemException(
            'Structural audio source is not a file.',
            resolved,
          );
        }
        out
          ..writeln('leaf_path=${jsonEncode(resolved)}')
          ..writeln('leaf_size=${stat.size}')
          ..writeln('leaf_mtime_us=${stat.modified.microsecondsSinceEpoch}');
      }
      out.writeln('segment_end');
    }
    out.writeln('lane_end');
  }
  out.writeln('plan_end');
}

void _writeFadeManifest(
  StringBuffer out,
  String label,
  StructuralAudioFade? fade,
) {
  if (fade == null) {
    out.writeln('${label}_fade=none');
    return;
  }
  out
    ..writeln('${label}_fade_direction=${fade.direction.name}')
    ..writeln('${label}_fade_start=${fade.startSample}')
    ..writeln('${label}_fade_count=${fade.sampleCount}');
}

/// Small dependency-free SHA-256 implementation used only for cache filenames.
/// Keeping it here avoids making the application dependency graph larger for a
/// single deterministic digest operation.
String structuralAudioSha256Hex(String value) {
  final List<int> bytes = <int>[...utf8.encode(value), 0x80];
  final int originalByteLength = bytes.length - 1;
  while (bytes.length % 64 != 56) {
    bytes.add(0);
  }

  final int bitLength = originalByteLength * 8;
  for (int shift = 56; shift >= 0; shift -= 8) {
    bytes.add((bitLength >> shift) & 0xff);
  }

  int h0 = 0x6a09e667;
  int h1 = 0xbb67ae85;
  int h2 = 0x3c6ef372;
  int h3 = 0xa54ff53a;
  int h4 = 0x510e527f;
  int h5 = 0x9b05688c;
  int h6 = 0x1f83d9ab;
  int h7 = 0x5be0cd19;

  for (int chunk = 0; chunk < bytes.length; chunk += 64) {
    final List<int> w = List<int>.filled(64, 0);
    for (int i = 0; i < 16; i++) {
      final int offset = chunk + i * 4;
      w[i] = ((bytes[offset] << 24) |
              (bytes[offset + 1] << 16) |
              (bytes[offset + 2] << 8) |
              bytes[offset + 3]) &
          _kUint32Mask;
    }
    for (int i = 16; i < 64; i++) {
      final int s0 = _rotateRight(w[i - 15], 7) ^
          _rotateRight(w[i - 15], 18) ^
          (w[i - 15] >> 3);
      final int s1 = _rotateRight(w[i - 2], 17) ^
          _rotateRight(w[i - 2], 19) ^
          (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & _kUint32Mask;
    }

    int a = h0;
    int b = h1;
    int c = h2;
    int d = h3;
    int e = h4;
    int f = h5;
    int g = h6;
    int h = h7;

    for (int i = 0; i < 64; i++) {
      final int sigma1 =
          _rotateRight(e, 6) ^ _rotateRight(e, 11) ^ _rotateRight(e, 25);
      final int choose = (e & f) ^ ((~e) & g);
      final int temp1 =
          (h + sigma1 + choose + _sha256K[i] + w[i]) & _kUint32Mask;
      final int sigma0 =
          _rotateRight(a, 2) ^ _rotateRight(a, 13) ^ _rotateRight(a, 22);
      final int majority = (a & b) ^ (a & c) ^ (b & c);
      final int temp2 = (sigma0 + majority) & _kUint32Mask;

      h = g;
      g = f;
      f = e;
      e = (d + temp1) & _kUint32Mask;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & _kUint32Mask;
    }

    h0 = (h0 + a) & _kUint32Mask;
    h1 = (h1 + b) & _kUint32Mask;
    h2 = (h2 + c) & _kUint32Mask;
    h3 = (h3 + d) & _kUint32Mask;
    h4 = (h4 + e) & _kUint32Mask;
    h5 = (h5 + f) & _kUint32Mask;
    h6 = (h6 + g) & _kUint32Mask;
    h7 = (h7 + h) & _kUint32Mask;
  }

  return <int>[h0, h1, h2, h3, h4, h5, h6, h7]
      .map((int word) => word.toRadixString(16).padLeft(8, '0'))
      .join();
}

int _rotateRight(int value, int bits) {
  return ((value >> bits) | (value << (32 - bits))) & _kUint32Mask;
}

const List<int> _sha256K = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];
