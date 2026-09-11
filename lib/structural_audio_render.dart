// ./lib/structural_audio_render.dart
//
// M21 Stage 1C: deterministic structural source audio composition.
//
// Stage 1A owns authored geometry. Stage 1B owns leaf media decode. This file
// joins those facts into one source-relative 48 kHz stereo float mix for an
// EDIT or MOSAIC and can serialize that mix as a deterministic IEEE-float WAV.
//
// This is still source audio, not program audio. STRUCT placement timing,
// terminal silence, workspace voice/music beds, preview playback, bake, and
// persistent caches remain outside this module.
//
// Reproducibility rules:
//
//   * output duration is the authored StructuralAudioPlan duration exactly;
//   * every project frame owns exactly 1600 output sample frames;
//   * leaf source lookup stays rational until the one interpolation fraction;
//   * nested EDIT/MOSAIC sources recurse as rendered project-time PCM;
//   * speed is pitch-following resampling, not time stretching;
//   * interpolation is pinned to linear interpolation;
//   * authored CLIP gain is one constant linear scalar per segment;
//   * MUTE is exact digital zero and preserves the authored gain beneath it;
//   * fade gain comes only from Stage 1A's midpoint equal-power contract;
//   * lane and segment accumulation follow the deterministic plan order;
//   * accumulation rounds to float32 after every contributor addition;
//   * no normalization, limiting, or clipping is applied to the float mix;
//   * no-audio leaf media contributes silence without changing duration;
//   * the WAV contains no timestamps or metadata, so identical PCM means
//     identical bytes.

import 'dart:io';
import 'dart:typed_data';

import 'structural_audio_decode.dart';
import 'structural_audio_plan.dart';

const int kStructuralAudioSourceRendererSchemaVersion = 2;
const int _kFloatWavFormatCode = 3;
const int _kFloatWavBitsPerSample = 32;
const int _kFloatWavHeaderBytes = 44;

abstract interface class StructuralAudioLeafDecodeBackend {
  Future<StructuralAudioLeafDecode> decode(
    StructuralAudioSegment segment,
    String resolvedPath,
  );
}

class FfmpegStructuralAudioLeafDecodeBackend
    implements StructuralAudioLeafDecodeBackend {
  final StructuralAudioLeafDecoder decoder;

  FfmpegStructuralAudioLeafDecodeBackend({
    StructuralAudioLeafDecoder? decoder,
  }) : decoder = decoder ?? StructuralAudioLeafDecoder();

  @override
  Future<StructuralAudioLeafDecode> decode(
    StructuralAudioSegment segment,
    String resolvedPath,
  ) {
    return decoder.decodeLeaf(
      segment: segment,
      resolvedPath: resolvedPath,
    );
  }
}

class StructuralAudioRenderException implements Exception {
  final String message;

  const StructuralAudioRenderException(this.message);

  @override
  String toString() => 'StructuralAudioRenderException: $message';
}

class StructuralAudioSourceRender {
  final StructuralAudioPlan plan;
  final Float32List interleavedStereo;

  const StructuralAudioSourceRender({
    required this.plan,
    required this.interleavedStereo,
  });

  int get sampleFrames => interleavedStereo.length ~/ kStructuralAudioChannels;

  Uint8List toWavBytes() => structuralAudioFloatWav(interleavedStereo);
}

class StructuralAudioSourceRenderer {
  final StructuralAudioPlanner planner;
  final StructuralAudioLeafDecodeBackend leafDecoder;
  final String Function(String authoredSource) resolveSource;

  StructuralAudioSourceRenderer({
    required this.planner,
    required this.leafDecoder,
    required this.resolveSource,
  });

  Future<StructuralAudioSourceRender> render(String structuralSource) async {
    final StructuralAudioPlan root = planner.plan(structuralSource);
    final Map<String, Future<StructuralAudioSourceRender>> memo =
        <String, Future<StructuralAudioSourceRender>>{};
    return _renderPlan(root, memo);
  }

  Future<Uint8List> renderWav(String structuralSource) async {
    final StructuralAudioSourceRender rendered = await render(structuralSource);
    return rendered.toWavBytes();
  }

  Future<void> writeWav(
    String structuralSource,
    String outputPath,
  ) async {
    final Uint8List bytes = await renderWav(structuralSource);
    await File(outputPath).writeAsBytes(bytes, flush: true);
  }

  Future<StructuralAudioSourceRender> _renderPlan(
    StructuralAudioPlan plan,
    Map<String, Future<StructuralAudioSourceRender>> memo,
  ) {
    final String key = plan.sourceRef.canonicalSource;
    final Future<StructuralAudioSourceRender>? existing = memo[key];
    if (existing != null) {
      return existing;
    }

    final Future<StructuralAudioSourceRender> created =
        _composePlan(plan, memo);
    memo[key] = created;
    return created;
  }

  Future<StructuralAudioSourceRender> _composePlan(
    StructuralAudioPlan plan,
    Map<String, Future<StructuralAudioSourceRender>> memo,
  ) async {
    final Float32List output = Float32List(
      plan.durationSamples * kStructuralAudioChannels,
    );

    for (final StructuralAudioLanePlan lane in plan.lanes) {
      for (final StructuralAudioSegment segment in lane.segments) {
        await _mixSegment(
          output,
          segment,
          memo,
        );
      }
    }

    return StructuralAudioSourceRender(
      plan: plan,
      interleavedStereo: output,
    );
  }

  Future<void> _mixSegment(
    Float32List destination,
    StructuralAudioSegment segment,
    Map<String, Future<StructuralAudioSourceRender>> memo,
  ) async {
    if (segment.sampleCount <= 0) {
      return;
    }

    if (segment.isStructural) {
      final StructuralAudioPlan nestedPlan = segment.nestedPlan!;
      final StructuralAudioSourceRender nested =
          await _renderPlan(nestedPlan, memo);
      _mixNestedSegment(destination, segment, nested);
      return;
    }

    final String resolvedPath = resolveSource(segment.source);
    final StructuralAudioLeafDecode decoded =
        await leafDecoder.decode(segment, resolvedPath);

    if (decoded.authoredProjectSampleFrames != segment.sampleCount) {
      throw StructuralAudioRenderException(
        'Leaf decode for "${segment.clipId}" represents '
        '${decoded.authoredProjectSampleFrames} project sample frames; '
        'the authored segment owns ${segment.sampleCount}.',
      );
    }

    if (!decoded.hasAudio) {
      return;
    }

    final StructuralAudioDecodeWindow? window = decoded.window;
    if (window == null) {
      throw StructuralAudioRenderException(
        'Decoded leaf "${segment.clipId}" has audio but no decode window.',
      );
    }
    if (decoded.sourceSampleFrames != window.requiredSampleFrames) {
      throw StructuralAudioRenderException(
        'Decoded leaf "${segment.clipId}" has '
        '${decoded.sourceSampleFrames} source sample frames; '
        'the decode window requires ${window.requiredSampleFrames}.',
      );
    }

    _mixLeafSegment(destination, segment, decoded, window);
  }

  void _mixLeafSegment(
    Float32List destination,
    StructuralAudioSegment segment,
    StructuralAudioLeafDecode decoded,
    StructuralAudioDecodeWindow window,
  ) {
    final StructuralAudioSourceInfo source = decoded.sourceInfo;
    final int speedNumerator = segment.speed.numerator;
    final int speedDenominator = segment.speed.denominator;

    // Project sample offset i is i / 1600 project frames.
    // Convert that exact position through CLIP speed and source FPS into a
    // canonical 48 kHz source-time sample coordinate:
    //
    // ((IN * 1600 * speedDen) + i * speedNum)
    //     * sourceFpsDen * 48000
    // ---------------------------------------------------
    //       1600 * speedDen * sourceFpsNum
    //
    // The division remains rational until _sampleLinear().
    final int baseNumerator = segment.sourceInFrame *
        kStructuralAudioSamplesPerProjectFrame *
        speedDenominator *
        source.sourceFpsDenominator *
        kStructuralAudioSampleRate;
    final int stepNumerator = speedNumerator *
        source.sourceFpsDenominator *
        kStructuralAudioSampleRate;
    final int denominator = kStructuralAudioSamplesPerProjectFrame *
        speedDenominator *
        source.sourceFpsNumerator;

    for (int localSample = 0;
        localSample < segment.sampleCount;
        localSample++) {
      final int sourceNumerator =
          baseNumerator + localSample * stepNumerator;
      final double gain = _segmentGain(segment, localSample);
      if (gain == 0.0) {
        continue;
      }

      final double left = _sampleLinear(
        decoded.interleavedStereo,
        sourceNumerator,
        denominator,
        originSampleFrame: window.requiredStartSampleFrame,
        channel: 0,
      );
      final double right = _sampleLinear(
        decoded.interleavedStereo,
        sourceNumerator,
        denominator,
        originSampleFrame: window.requiredStartSampleFrame,
        channel: 1,
      );
      _accumulate(
        destination,
        segment.projectStartSample + localSample,
        left * gain,
        right * gain,
      );
    }
  }

  void _mixNestedSegment(
    Float32List destination,
    StructuralAudioSegment segment,
    StructuralAudioSourceRender nested,
  ) {
    final int speedNumerator = segment.speed.numerator;
    final int speedDenominator = segment.speed.denominator;

    // A nested structural source is itself project-time PCM at 48 kHz. Its
    // source frame rate is therefore exactly the project rate. The source
    // sample coordinate simplifies to:
    //
    // IN * 1600 + i * speedNum / speedDen.
    final int baseNumerator = segment.sourceInFrame *
        kStructuralAudioSamplesPerProjectFrame *
        speedDenominator;

    for (int localSample = 0;
        localSample < segment.sampleCount;
        localSample++) {
      final int sourceNumerator =
          baseNumerator + localSample * speedNumerator;
      final double gain = _segmentGain(segment, localSample);
      if (gain == 0.0) {
        continue;
      }

      final double left = _sampleLinear(
        nested.interleavedStereo,
        sourceNumerator,
        speedDenominator,
        originSampleFrame: 0,
        channel: 0,
      );
      final double right = _sampleLinear(
        nested.interleavedStereo,
        sourceNumerator,
        speedDenominator,
        originSampleFrame: 0,
        channel: 1,
      );
      _accumulate(
        destination,
        segment.projectStartSample + localSample,
        left * gain,
        right * gain,
      );
    }
  }
}

double _segmentGain(
  StructuralAudioSegment segment,
  int localSample,
) {
  if (segment.muted) return 0.0;

  final int absoluteSample = segment.projectStartSample + localSample;
  double gain = segment.audioGain.linearMultiplier;

  final StructuralAudioFade? incoming = segment.incomingFade;
  if (incoming != null &&
      absoluteSample >= incoming.startSample &&
      absoluteSample < incoming.endSampleExclusive) {
    gain *= incoming.gainAtAbsoluteSample(absoluteSample);
  }

  final StructuralAudioFade? outgoing = segment.outgoingFade;
  if (outgoing != null &&
      absoluteSample >= outgoing.startSample &&
      absoluteSample < outgoing.endSampleExclusive) {
    gain *= outgoing.gainAtAbsoluteSample(absoluteSample);
  }

  return gain;
}

void _accumulate(
  Float32List destination,
  int projectSampleFrame,
  double left,
  double right,
) {
  if (projectSampleFrame < 0) {
    return;
  }
  final int base = projectSampleFrame * kStructuralAudioChannels;
  if (base + 1 >= destination.length) {
    return;
  }

  // Float32List assignment deliberately rounds after each contributor. The
  // plan order is deterministic, so the accumulation order and bytes are too.
  destination[base] = destination[base] + left;
  destination[base + 1] = destination[base + 1] + right;
}

double _sampleLinear(
  Float32List interleaved,
  int positionNumerator,
  int positionDenominator, {
  required int originSampleFrame,
  required int channel,
}) {
  if (positionDenominator <= 0) {
    throw ArgumentError('Sample position denominator must be positive.');
  }
  if (channel < 0 || channel >= kStructuralAudioChannels) {
    throw RangeError.range(
      channel,
      0,
      kStructuralAudioChannels - 1,
      'channel',
    );
  }

  final int absoluteFloor =
      _floorDiv(positionNumerator, positionDenominator);
  final int remainder =
      positionNumerator - absoluteFloor * positionDenominator;
  final int localFloor = absoluteFloor - originSampleFrame;
  final double first = _sampleAt(interleaved, localFloor, channel);
  if (remainder == 0) {
    return first;
  }

  final double second = _sampleAt(interleaved, localFloor + 1, channel);
  final double fraction = remainder / positionDenominator;
  return first + (second - first) * fraction;
}

double _sampleAt(
  Float32List interleaved,
  int sampleFrame,
  int channel,
) {
  if (sampleFrame < 0) {
    return 0.0;
  }
  final int index = sampleFrame * kStructuralAudioChannels + channel;
  if (index < 0 || index >= interleaved.length) {
    return 0.0;
  }
  return interleaved[index];
}

Uint8List structuralAudioFloatWav(Float32List interleavedStereo) {
  if (interleavedStereo.length % kStructuralAudioChannels != 0) {
    throw ArgumentError(
      'Structural audio PCM must contain complete stereo sample frames.',
    );
  }

  final int dataBytes =
      interleavedStereo.length * kStructuralAudioBytesPerFloatSample;
  final Uint8List bytes = Uint8List(_kFloatWavHeaderBytes + dataBytes);
  final ByteData data = ByteData.sublistView(bytes);

  _writeAscii(bytes, 0, 'RIFF');
  data.setUint32(4, 36 + dataBytes, Endian.little);
  _writeAscii(bytes, 8, 'WAVE');
  _writeAscii(bytes, 12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, _kFloatWavFormatCode, Endian.little);
  data.setUint16(22, kStructuralAudioChannels, Endian.little);
  data.setUint32(24, kStructuralAudioSampleRate, Endian.little);

  final int blockAlign = kStructuralAudioChannels *
      (_kFloatWavBitsPerSample ~/ 8);
  data.setUint32(
    28,
    kStructuralAudioSampleRate * blockAlign,
    Endian.little,
  );
  data.setUint16(32, blockAlign, Endian.little);
  data.setUint16(34, _kFloatWavBitsPerSample, Endian.little);
  _writeAscii(bytes, 36, 'data');
  data.setUint32(40, dataBytes, Endian.little);

  int offset = _kFloatWavHeaderBytes;
  for (final double sample in interleavedStereo) {
    if (!sample.isFinite) {
      throw const StructuralAudioRenderException(
        'Structural audio mix contains a non-finite sample.',
      );
    }
    data.setFloat32(offset, sample, Endian.little);
    offset += kStructuralAudioBytesPerFloatSample;
  }

  return bytes;
}

void _writeAscii(
  Uint8List destination,
  int offset,
  String value,
) {
  for (int i = 0; i < value.length; i++) {
    destination[offset + i] = value.codeUnitAt(i);
  }
}

int _floorDiv(int numerator, int denominator) {
  if (denominator <= 0) {
    throw ArgumentError('Denominator must be positive.');
  }
  final int quotient = numerator ~/ denominator;
  final int remainder = numerator % denominator;
  if (remainder == 0 || numerator >= 0) {
    return quotient;
  }
  return quotient - 1;
}
