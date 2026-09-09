// ./lib/structural_audio_decode.dart
//
// M21 Stage 1B: leaf structural-audio decode.
//
// This module owns only the media boundary. It probes one leaf media source,
// derives the exact source interval required by a StructuralAudioSegment, and
// asks ffmpeg for canonical float32 stereo PCM at 48 kHz. It does not compose
// EDIT tracks, MOSAIC panes, STRUCT placements, preview beds, or bake audio.
//
// Reproducibility rules are explicit here because ffmpeg defaults are not a
// contract:
//
//   * source/video frame rate is read as an exact rational;
//   * source interval geometry stays integer/rational until command emission;
//   * input seek follows the existing -accurate_seek then -ss pattern;
//   * resampling is pinned to one swresample configuration;
//   * mono duplicates to L/R without attenuation;
//   * supported multichannel layouts use an explicit downmix and ignore LFE;
//   * unknown multichannel layouts fail instead of accepting ffmpeg defaults;
//   * decode windows include XFADE source handles and a fixed resampler margin;
//   * the resampler margin is removed in Dart after resampling;
//   * no-audio is a valid media state, distinct from a failed decode;
//   * ffmpeg -version is exposed verbatim for the future persistent cache key.
//
// The returned PCM for a decoded source represents the required SOURCE-TIME
// interval, including authored XFADE handles but excluding the fixed resampler
// margin. Stage 1C will map this source-time buffer into exact project-time
// sample geometry and perform composition.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'structural_audio_plan.dart';

const int kStructuralAudioChannels = 2;
const int kStructuralAudioBytesPerFloatSample = 4;

/// Guard samples decoded on each side of the required interval.
///
/// The pinned swresample filter is 32 taps. 256 canonical sample frames is
/// intentionally generous while still being only 5.3 ms at 48 kHz. The guard
/// is discarded after resampling and never enters authored duration.
const int kStructuralAudioResamplerPaddingSampleFrames = 256;

/// Pinned swresample policy. Do not replace this with bare `aresample=48000`.
/// Toolchain changes are additionally invalidated by the ffmpeg version string
/// when Stage 1C introduces persistent source caches.
const String kStructuralAudioResamplerFilter =
    'aresample=48000:resampler=swr:filter_size=32:phase_shift=10:'
    'linear_interp=0:exact_rational=1:cutoff=0.97:dither_method=none';

const String kStructuralAudioOutputFormatFilter =
    'aformat=sample_fmts=flt:sample_rates=48000:channel_layouts=stereo';

const double _kMinus3Db = 0.7071067811865476;
const double _kMinus6Db = 0.5;

enum StructuralAudioSourceKind {
  audio,
  noAudio,
}

class StructuralAudioSourceInfo {
  final String path;
  final StructuralAudioSourceKind kind;

  /// Exact video/source frame rate used by CLIP IN and speed geometry.
  final int sourceFpsNumerator;
  final int sourceFpsDenominator;

  /// Audio-stream metadata. Zero/empty when [kind] is noAudio.
  final int audioSampleRate;
  final int audioChannels;
  final String audioChannelLayout;

  const StructuralAudioSourceInfo._({
    required this.path,
    required this.kind,
    required this.sourceFpsNumerator,
    required this.sourceFpsDenominator,
    required this.audioSampleRate,
    required this.audioChannels,
    required this.audioChannelLayout,
  });

  const StructuralAudioSourceInfo.audio({
    required String path,
    required int sourceFpsNumerator,
    required int sourceFpsDenominator,
    required int audioSampleRate,
    required int audioChannels,
    required String audioChannelLayout,
  }) : this._(
          path: path,
          kind: StructuralAudioSourceKind.audio,
          sourceFpsNumerator: sourceFpsNumerator,
          sourceFpsDenominator: sourceFpsDenominator,
          audioSampleRate: audioSampleRate,
          audioChannels: audioChannels,
          audioChannelLayout: audioChannelLayout,
        );

  const StructuralAudioSourceInfo.noAudio({
    required String path,
    required int sourceFpsNumerator,
    required int sourceFpsDenominator,
  }) : this._(
          path: path,
          kind: StructuralAudioSourceKind.noAudio,
          sourceFpsNumerator: sourceFpsNumerator,
          sourceFpsDenominator: sourceFpsDenominator,
          audioSampleRate: 0,
          audioChannels: 0,
          audioChannelLayout: '',
        );

  bool get hasAudio => kind == StructuralAudioSourceKind.audio;
}

class StructuralAudioDecodeException implements Exception {
  final String message;

  const StructuralAudioDecodeException(this.message);

  @override
  String toString() => 'StructuralAudioDecodeException: $message';
}

/// Exact source-time interval for one leaf decode.
///
/// All fields are temporal sample frames at canonical 48 kHz, not scalar
/// interleaved channel values. [requiredStartSampleFrame] may be negative when
/// an incoming fade asks for source before time zero. That prefix is emitted as
/// silence. [decodeStartSampleFrame] is always clamped to zero.
class StructuralAudioDecodeWindow {
  final int contentStartSampleFrame;
  final int contentEndSampleFrameExclusive;
  final int requiredStartSampleFrame;
  final int requiredEndSampleFrameExclusive;
  final int decodeStartSampleFrame;
  final int decodeEndSampleFrameExclusive;
  final int incomingHandleSampleFrames;
  final int outgoingHandleSampleFrames;

  const StructuralAudioDecodeWindow._({
    required this.contentStartSampleFrame,
    required this.contentEndSampleFrameExclusive,
    required this.requiredStartSampleFrame,
    required this.requiredEndSampleFrameExclusive,
    required this.decodeStartSampleFrame,
    required this.decodeEndSampleFrameExclusive,
    required this.incomingHandleSampleFrames,
    required this.outgoingHandleSampleFrames,
  });

  factory StructuralAudioDecodeWindow.forSegment(
    StructuralAudioSegment segment,
    StructuralAudioSourceInfo source,
  ) {
    if (!segment.isLeafMedia) {
      throw ArgumentError.value(
        segment.source,
        'segment',
        'Structural sources are compositions, not leaf media.',
      );
    }
    if (source.sourceFpsNumerator <= 0 || source.sourceFpsDenominator <= 0) {
      throw ArgumentError('Source frame rate must be a positive rational.');
    }

    final int incomingFrames = _projectFadeFrames(segment.incomingFade);
    final int outgoingFrames = _projectFadeFrames(segment.outgoingFade);

    final _RationalSampleBoundary contentStart = _sourceSampleBoundary(
      segment,
      source,
      projectOffset: 0,
    );
    final _RationalSampleBoundary contentEnd = _sourceSampleBoundary(
      segment,
      source,
      projectOffset: segment.durationFrames,
    );
    final _RationalSampleBoundary requiredStart = _sourceSampleBoundary(
      segment,
      source,
      projectOffset: -incomingFrames,
    );
    final _RationalSampleBoundary requiredEnd = _sourceSampleBoundary(
      segment,
      source,
      projectOffset: segment.durationFrames + outgoingFrames,
    );

    final int contentStartFrame =
        _floorDiv(contentStart.numerator, contentStart.denominator);
    final int contentEndFrame =
        _ceilDiv(contentEnd.numerator, contentEnd.denominator);
    final int requiredStartFrame =
        _floorDiv(requiredStart.numerator, requiredStart.denominator);
    final int requiredEndFrame =
        _ceilDiv(requiredEnd.numerator, requiredEnd.denominator);

    if (requiredEndFrame <= requiredStartFrame) {
      throw const StructuralAudioDecodeException(
        'Derived source audio interval is empty.',
      );
    }

    final int paddedStart =
        requiredStartFrame - kStructuralAudioResamplerPaddingSampleFrames;
    final int decodeStartFrame = paddedStart < 0 ? 0 : paddedStart;
    final int decodeEndFrame =
        requiredEndFrame + kStructuralAudioResamplerPaddingSampleFrames;

    return StructuralAudioDecodeWindow._(
      contentStartSampleFrame: contentStartFrame,
      contentEndSampleFrameExclusive: contentEndFrame,
      requiredStartSampleFrame: requiredStartFrame,
      requiredEndSampleFrameExclusive: requiredEndFrame,
      decodeStartSampleFrame: decodeStartFrame,
      decodeEndSampleFrameExclusive: decodeEndFrame,
      incomingHandleSampleFrames: contentStartFrame - requiredStartFrame,
      outgoingHandleSampleFrames: requiredEndFrame - contentEndFrame,
    );
  }

  int get contentSampleFrames =>
      contentEndSampleFrameExclusive - contentStartSampleFrame;

  int get requiredSampleFrames =>
      requiredEndSampleFrameExclusive - requiredStartSampleFrame;

  int get decodeSampleFrames =>
      decodeEndSampleFrameExclusive - decodeStartSampleFrame;

  int get contentOffsetInRequiredSampleFrames =>
      contentStartSampleFrame - requiredStartSampleFrame;
}

enum StructuralAudioLeafDecodeStatus {
  decoded,
  noAudio,
}

class StructuralAudioLeafDecode {
  final StructuralAudioLeafDecodeStatus status;
  final StructuralAudioSourceInfo sourceInfo;

  /// Exact authored project duration represented by this leaf segment.
  /// A no-audio source contributes this many silent project sample frames.
  final int authoredProjectSampleFrames;

  /// Present only for [StructuralAudioLeafDecodeStatus.decoded].
  final StructuralAudioDecodeWindow? window;

  /// Interleaved float32 stereo source-time PCM for [window.requiredSampleFrames].
  /// Empty for a no-audio source.
  final Float32List interleavedStereo;

  const StructuralAudioLeafDecode._({
    required this.status,
    required this.sourceInfo,
    required this.authoredProjectSampleFrames,
    required this.window,
    required this.interleavedStereo,
  });

  factory StructuralAudioLeafDecode.noAudio({
    required StructuralAudioSourceInfo sourceInfo,
    required int authoredProjectSampleFrames,
  }) {
    return StructuralAudioLeafDecode._(
      status: StructuralAudioLeafDecodeStatus.noAudio,
      sourceInfo: sourceInfo,
      authoredProjectSampleFrames: authoredProjectSampleFrames,
      window: null,
      interleavedStereo: Float32List(0),
    );
  }

  factory StructuralAudioLeafDecode.decoded({
    required StructuralAudioSourceInfo sourceInfo,
    required int authoredProjectSampleFrames,
    required StructuralAudioDecodeWindow window,
    required Float32List interleavedStereo,
  }) {
    return StructuralAudioLeafDecode._(
      status: StructuralAudioLeafDecodeStatus.decoded,
      sourceInfo: sourceInfo,
      authoredProjectSampleFrames: authoredProjectSampleFrames,
      window: window,
      interleavedStereo: interleavedStereo,
    );
  }

  bool get hasAudio => status == StructuralAudioLeafDecodeStatus.decoded;

  int get sourceSampleFrames => interleavedStereo.length ~/ kStructuralAudioChannels;
}

class StructuralAudioProcessResult {
  final int exitCode;
  final String stdoutText;
  final Uint8List stdoutBytes;
  final String stderrText;

  const StructuralAudioProcessResult({
    required this.exitCode,
    this.stdoutText = '',
    this.stdoutBytes = const <int>[],
    this.stderrText = '',
  });
}

abstract interface class StructuralAudioProcessRunner {
  Future<StructuralAudioProcessResult> run(
    String executable,
    List<String> arguments, {
    bool binaryStdout = false,
  });
}

class LocalStructuralAudioProcessRunner implements StructuralAudioProcessRunner {
  const LocalStructuralAudioProcessRunner();

  @override
  Future<StructuralAudioProcessResult> run(
    String executable,
    List<String> arguments, {
    bool binaryStdout = false,
  }) async {
    final ProcessResult result = await Process.run(
      executable,
      arguments,
      stdoutEncoding: binaryStdout ? null : utf8,
      stderrEncoding: utf8,
    );

    return StructuralAudioProcessResult(
      exitCode: result.exitCode,
      stdoutText: binaryStdout ? '' : '${result.stdout}',
      stdoutBytes: binaryStdout
          ? Uint8List.fromList((result.stdout as List<int>))
          : Uint8List(0),
      stderrText: '${result.stderr}',
    );
  }
}

class StructuralAudioLeafDecoder {
  final StructuralAudioProcessRunner runner;
  String? _ffmpegVersion;

  StructuralAudioLeafDecoder({
    StructuralAudioProcessRunner? runner,
  }) : runner = runner ?? const LocalStructuralAudioProcessRunner();

  /// Full ffmpeg version/configuration output for the future SourceAudioKey.
  Future<String> ffmpegVersionString() async {
    final String? cached = _ffmpegVersion;
    if (cached != null) return cached;

    final StructuralAudioProcessResult result =
        await runner.run('ffmpeg', const <String>['-version']);
    if (result.exitCode != 0 || result.stdoutText.trim().isEmpty) {
      throw StructuralAudioDecodeException(
        'Could not read ffmpeg version: ${result.stderrText.trim()}',
      );
    }
    final String version = result.stdoutText.trim();
    _ffmpegVersion = version;
    return version;
  }

  /// Probes the first video stream for exact source fps and the first audio
  /// stream for channel metadata. A missing audio stream is a successful probe.
  Future<StructuralAudioSourceInfo> probe(String resolvedPath) async {
    if (resolvedPath.trim().isEmpty) {
      throw const StructuralAudioDecodeException('Media path is empty.');
    }

    final StructuralAudioProcessResult result = await runner.run(
      'ffprobe',
      <String>[
        '-v', 'error',
        '-show_entries',
        'stream=index,codec_type,avg_frame_rate,r_frame_rate,sample_rate,'
            'channels,channel_layout',
        '-of', 'json',
        resolvedPath,
      ],
    );

    if (result.exitCode != 0) {
      throw StructuralAudioDecodeException(
        'ffprobe failed for "$resolvedPath": ${result.stderrText.trim()}',
      );
    }

    final Object? parsed;
    try {
      parsed = jsonDecode(result.stdoutText);
    } on FormatException catch (error) {
      throw StructuralAudioDecodeException(
        'ffprobe returned invalid JSON for "$resolvedPath": ${error.message}',
      );
    }

    if (parsed is! Map<String, dynamic>) {
      throw StructuralAudioDecodeException(
        'ffprobe returned an unexpected document for "$resolvedPath".',
      );
    }

    final Object? rawStreams = parsed['streams'];
    if (rawStreams is! List) {
      throw StructuralAudioDecodeException(
        'ffprobe returned no stream list for "$resolvedPath".',
      );
    }

    Map<String, dynamic>? video;
    Map<String, dynamic>? audio;
    for (final Object? raw in rawStreams) {
      if (raw is! Map) continue;
      final Map<String, dynamic> stream = <String, dynamic>{
        for (final MapEntry<Object?, Object?> entry in raw.entries)
          '${entry.key}': entry.value,
      };
      final String type = '${stream['codec_type'] ?? ''}'.trim();
      if (type == 'video' && video == null) video = stream;
      if (type == 'audio' && audio == null) audio = stream;
    }

    if (video == null) {
      throw StructuralAudioDecodeException(
        'Leaf media "$resolvedPath" has no video stream for source-frame timing.',
      );
    }

    final (int, int)? fps = _positiveRational('${video['avg_frame_rate'] ?? ''}') ??
        _positiveRational('${video['r_frame_rate'] ?? ''}');
    if (fps == null) {
      throw StructuralAudioDecodeException(
        'Leaf media "$resolvedPath" has no usable video frame rate.',
      );
    }

    if (audio == null) {
      return StructuralAudioSourceInfo.noAudio(
        path: resolvedPath,
        sourceFpsNumerator: fps.$1,
        sourceFpsDenominator: fps.$2,
      );
    }

    final int sampleRate = int.tryParse('${audio['sample_rate'] ?? ''}') ?? 0;
    final int channels = int.tryParse('${audio['channels'] ?? ''}') ?? 0;
    final String layout = '${audio['channel_layout'] ?? ''}'.trim().toLowerCase();
    if (sampleRate <= 0 || channels <= 0) {
      throw StructuralAudioDecodeException(
        'Audio stream in "$resolvedPath" has invalid rate/channel metadata.',
      );
    }

    return StructuralAudioSourceInfo.audio(
      path: resolvedPath,
      sourceFpsNumerator: fps.$1,
      sourceFpsDenominator: fps.$2,
      audioSampleRate: sampleRate,
      audioChannels: channels,
      audioChannelLayout: layout,
    );
  }

  Future<StructuralAudioLeafDecode> decodeLeaf({
    required StructuralAudioSegment segment,
    required String resolvedPath,
    StructuralAudioSourceInfo? sourceInfo,
  }) async {
    if (!segment.isLeafMedia) {
      throw ArgumentError.value(
        segment.source,
        'segment',
        'decodeLeaf accepts leaf media only.',
      );
    }

    final StructuralAudioSourceInfo info = sourceInfo ?? await probe(resolvedPath);
    if (!info.hasAudio) {
      return StructuralAudioLeafDecode.noAudio(
        sourceInfo: info,
        authoredProjectSampleFrames: segment.sampleCount,
      );
    }

    final StructuralAudioDecodeWindow window =
        StructuralAudioDecodeWindow.forSegment(segment, info);
    final String pan = structuralAudioPanFilter(info);
    final String filter = <String>[
      pan,
      kStructuralAudioResamplerFilter,
      kStructuralAudioOutputFormatFilter,
      'atrim=start_sample=0:end_sample=${window.decodeSampleFrames}',
      'asetpts=N/SR/TB',
    ].join(',');

    final List<String> arguments = <String>[
      '-v', 'error',
      '-accurate_seek',
      if (window.decodeStartSampleFrame > 0) ...<String>[
        '-ss',
        _secondsFromCanonicalSampleFrame(window.decodeStartSampleFrame),
      ],
      '-i', resolvedPath,
      '-map', '0:a:0',
      '-vn',
      '-af', filter,
      '-f', 'f32le',
      '-acodec', 'pcm_f32le',
      '-ac', '$kStructuralAudioChannels',
      '-ar', '$kStructuralAudioSampleRate',
      '-',
    ];

    final StructuralAudioProcessResult result = await runner.run(
      'ffmpeg',
      arguments,
      binaryStdout: true,
    );
    if (result.exitCode != 0) {
      throw StructuralAudioDecodeException(
        'ffmpeg audio decode failed for "$resolvedPath": '
        '${result.stderrText.trim()}',
      );
    }

    final Float32List decoded = _decodeFloat32LeStereo(result.stdoutBytes);
    final Float32List required = _trimDecodeMargin(
      decoded,
      window,
    );

    return StructuralAudioLeafDecode.decoded(
      sourceInfo: info,
      authoredProjectSampleFrames: segment.sampleCount,
      window: window,
      interleavedStereo: required,
    );
  }
}

/// Explicit input-channel policy. There is deliberately no default multichannel
/// fallback because accepting ffmpeg's changing coefficients would make source
/// rendering depend on the installed build.
String structuralAudioPanFilter(StructuralAudioSourceInfo info) {
  if (!info.hasAudio) {
    throw ArgumentError('A no-audio source has no channel matrix.');
  }

  if (info.audioChannels == 1) {
    return 'pan=stereo|c0=c0|c1=c0';
  }
  if (info.audioChannels == 2) {
    return 'pan=stereo|c0=c0|c1=c1';
  }

  final String layout = info.audioChannelLayout;
  final String minus3 = _kMinus3Db.toString();
  final String minus6 = _kMinus6Db.toString();

  switch (layout) {
    case '2.1':
      // LFE is intentionally ignored.
      return 'pan=stereo|FL=FL|FR=FR';
    case '3.0':
      return 'pan=stereo|FL=FL+$minus3*FC|FR=FR+$minus3*FC';
    case '3.0(back)':
      return 'pan=stereo|FL=FL+$minus3*BC|FR=FR+$minus3*BC';
    case '4.0':
      return 'pan=stereo|FL=FL+$minus3*FC+$minus3*BC|'
          'FR=FR+$minus3*FC+$minus3*BC';
    case 'quad':
      return 'pan=stereo|FL=FL+$minus3*BL|FR=FR+$minus3*BR';
    case 'quad(side)':
      return 'pan=stereo|FL=FL+$minus3*SL|FR=FR+$minus3*SR';
    case '5.0':
    case '5.1':
      return 'pan=stereo|FL=FL+$minus3*FC+$minus3*BL|'
          'FR=FR+$minus3*FC+$minus3*BR';
    case '5.0(side)':
    case '5.1(side)':
      return 'pan=stereo|FL=FL+$minus3*FC+$minus3*SL|'
          'FR=FR+$minus3*FC+$minus3*SR';
    case '7.1':
      return 'pan=stereo|FL=FL+$minus3*FC+$minus6*BL+$minus6*SL|'
          'FR=FR+$minus3*FC+$minus6*BR+$minus6*SR';
  }

  throw StructuralAudioDecodeException(
    'Unsupported ${info.audioChannels}-channel layout '
    '"${info.audioChannelLayout}" in "${info.path}".',
  );
}

class _RationalSampleBoundary {
  final int numerator;
  final int denominator;

  const _RationalSampleBoundary(this.numerator, this.denominator);
}

_RationalSampleBoundary _sourceSampleBoundary(
  StructuralAudioSegment segment,
  StructuralAudioSourceInfo source, {
  required int projectOffset,
}) {
  // Source-frame position:
  //   IN + projectOffset * speedNum / speedDen
  // Then source-frame position -> seconds via source fps, and seconds ->
  // canonical 48k source-time sample frames. No double enters this mapping.
  final int sourceFrameNumerator =
      segment.sourceInFrame * segment.speed.denominator +
          projectOffset * segment.speed.numerator;
  final int numerator = sourceFrameNumerator *
      source.sourceFpsDenominator *
      kStructuralAudioSampleRate;
  final int denominator =
      segment.speed.denominator * source.sourceFpsNumerator;
  return _RationalSampleBoundary(numerator, denominator);
}

int _projectFadeFrames(StructuralAudioFade? fade) {
  if (fade == null) return 0;
  if (fade.sampleCount % kStructuralAudioSamplesPerProjectFrame != 0) {
    throw const StructuralAudioDecodeException(
      'Audio fade length is not aligned to whole authored project frames.',
    );
  }
  return fade.sampleCount ~/ kStructuralAudioSamplesPerProjectFrame;
}

(int, int)? _positiveRational(String source) {
  final String value = source.trim();
  final int slash = value.indexOf('/');
  if (slash <= 0 || slash == value.length - 1) return null;
  final int? numerator = int.tryParse(value.substring(0, slash));
  final int? denominator = int.tryParse(value.substring(slash + 1));
  if (numerator == null || denominator == null || numerator <= 0 || denominator <= 0) {
    return null;
  }
  final int divisor = _gcd(numerator, denominator);
  return (numerator ~/ divisor, denominator ~/ divisor);
}

String _secondsFromCanonicalSampleFrame(int sampleFrame) {
  if (sampleFrame < 0) {
    throw ArgumentError.value(sampleFrame, 'sampleFrame', 'Must be non-negative.');
  }

  const int scale = 1000000000000;
  final int whole = sampleFrame ~/ kStructuralAudioSampleRate;
  final int remainder = sampleFrame % kStructuralAudioSampleRate;
  int fraction =
      (remainder * scale + kStructuralAudioSampleRate ~/ 2) ~/
          kStructuralAudioSampleRate;
  int seconds = whole;
  if (fraction >= scale) {
    seconds++;
    fraction -= scale;
  }
  return '$seconds.${fraction.toString().padLeft(12, '0')}';
}

Float32List _decodeFloat32LeStereo(Uint8List bytes) {
  const int bytesPerFrame =
      kStructuralAudioChannels * kStructuralAudioBytesPerFloatSample;
  if (bytes.length % bytesPerFrame != 0) {
    throw StructuralAudioDecodeException(
      'ffmpeg returned ${bytes.length} bytes; float32 stereo requires a '
      'multiple of $bytesPerFrame.',
    );
  }

  final ByteData data = ByteData.sublistView(bytes);
  final Float32List out =
      Float32List(bytes.length ~/ kStructuralAudioBytesPerFloatSample);
  for (int i = 0; i < out.length; i++) {
    out[i] = data.getFloat32(
      i * kStructuralAudioBytesPerFloatSample,
      Endian.little,
    );
  }
  return out;
}

Float32List _trimDecodeMargin(
  Float32List decoded,
  StructuralAudioDecodeWindow window,
) {
  final int requiredFrames = window.requiredSampleFrames;
  final Float32List out =
      Float32List(requiredFrames * kStructuralAudioChannels);
  final int decodedFrames = decoded.length ~/ kStructuralAudioChannels;

  // Required source time may begin below zero. That region stays zero in the
  // destination. Likewise an interval extending beyond EOF remains silent when
  // ffmpeg returns fewer frames than requested. Authored duration never shrinks.
  final int copyTimelineStart = window.requiredStartSampleFrame < 0
      ? 0
      : window.requiredStartSampleFrame;
  final int decodedStart = copyTimelineStart - window.decodeStartSampleFrame;
  final int outputStart = copyTimelineStart - window.requiredStartSampleFrame;

  if (decodedStart < 0 || outputStart < 0 || decodedStart >= decodedFrames) {
    return out;
  }

  final int decodedAvailable = decodedFrames - decodedStart;
  final int outputAvailable = requiredFrames - outputStart;
  final int copyFrames =
      decodedAvailable < outputAvailable ? decodedAvailable : outputAvailable;

  for (int frame = 0; frame < copyFrames; frame++) {
    final int src = (decodedStart + frame) * kStructuralAudioChannels;
    final int dst = (outputStart + frame) * kStructuralAudioChannels;
    out[dst] = decoded[src];
    out[dst + 1] = decoded[src + 1];
  }
  return out;
}

int _floorDiv(int numerator, int denominator) {
  if (denominator <= 0) throw ArgumentError('Denominator must be positive.');
  final int quotient = numerator ~/ denominator;
  final int remainder = numerator % denominator;
  if (remainder == 0 || numerator >= 0) return quotient;
  return quotient - 1;
}

int _ceilDiv(int numerator, int denominator) {
  if (denominator <= 0) throw ArgumentError('Denominator must be positive.');
  final int quotient = numerator ~/ denominator;
  final int remainder = numerator % denominator;
  if (remainder == 0 || numerator <= 0) return quotient;
  return quotient + 1;
}

int _gcd(int a, int b) {
  int x = a.abs();
  int y = b.abs();
  while (y != 0) {
    final int next = x % y;
    x = y;
    y = next;
  }
  return x == 0 ? 1 : x;
}
