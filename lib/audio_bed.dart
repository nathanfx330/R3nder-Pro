// ./lib/audio_bed.dart
//
// Background audio bed: playback, device selection, and duration probing.
//
// BOUNDARY CONTRACT
// This library never enters the render path. TerminalEngine and SceneEngine
// do not import it, do not observe it, and do not learn that audio exists.
// The only thing that crosses back into the engine is a single precomputed
// integer (endHoldExtraFrames), derived once from a probed duration before
// frame 0 is drawn. Determinism is untouched: reset() plus N ticks still
// reproduces any frame, with or without a bed attached.
//
// TWO TRACKS, ONE OF THEM AUTHORITATIVE
// A workspace can attach a voice bed and a music bed. They are NOT peers,
// and the asymmetry is the whole design:
//
//   The VOICE bed owns the length. A trailing voiceover line is content,
//   and it should play out over a live blinking cursor rather than be cut
//   off, which is what the end-hold stretch buys. That reasoning is about
//   speech, not about audio.
//
//   The MUSIC bed is trimmed to picture. A four minute track under a forty
//   second piece must not produce a four minute render, and no amount of
//   score is a reason to hold on a settled terminal. Music therefore never
//   reaches endHoldExtraFrames and never enters ScriptWarmKey: attaching,
//   swapping, or re-gaining it cannot move a frame boundary, so it costs no
//   re-simulation at all.
//
// So the single integer above is still a single integer, and it still comes
// from one probe. Which probe is now a stated fact rather than an obvious
// one, and BedTimeline is where it is stated.
//
// Two consumers, deliberately unrelated:
//   1. Preview / editor. Realtime playback, authoring aid only. This file.
//   2. Export. FFmpeg muxes the original file as a second input. Never
//      touches this file. Frame-exactness is automatic because video is
//      engine-locked and audio carries its own timebase.
//
// BACKEND
// ffmpeg decodes, seeks, applies gain, and mixes. On Linux its raw PCM goes
// directly into NativeAudioSink, whose worker thread owns the blocking
// libpulse writes and bounded backpressure. aplay remains the subprocess
// fallback when the native PulseAudio-compatible sink cannot be opened.
// Nothing is held in memory: a 30 minute voiceover costs no RAM and starts
// instantly rather than blocking the UI on a decode. ffmpeg owns the seek via
// -ss, which makes click-to-jump and scrubber drags close to free.
//
// Gain is applied by ffmpeg's volume filter rather than in Dart, so preview
// level matches what the exporter will mux. Audio is deliberately NOT
// peak-normalized: normalizing would make the preview lie about the mix.
//
// The same rule decides how the two tracks are summed. amix defaults to
// normalize=1, which divides by the input count: attaching music would drop
// the voice 6dB on its own, and the balance you heard would not be the
// balance you baked. normalize=0 is therefore mandatory here, and the cost
// is honest rather than hidden. Two hot tracks can sum past full scale and
// the s16le pipe clips hard, which is what the per-track gain sliders are
// for. Riding a fader is the mix; a limiter would be an opinion about it.
//
// ONE PIPELINE, NOT TWO. The mix happens inside the single ffmpeg process
// that already feeds the sink. Two decoder/sink pairs would be two
// independent wall clocks fighting over one device, and the device would
// arbitrate by interleaving them: the tracks would drift against each other
// and against the picture, differently on every scrub.
//
// Devices are enumerated by name so the user picks a real sink instead of a
// guessed index. On multi-sink Linux boxes the system default is frequently
// not the one with speakers attached, which is why testTone() exists.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

// The sum of two beds, spelled once. Preview and export are unrelated code
// paths and stay that way; this is the one fact both have to agree on, so it
// is a registry rather than a copy in each. See audio_mix.dart.
import 'audio_mix.dart';
import 'audio_sink.dart';

/// Wire format shared by the ffmpeg producer and the sink consumer.
/// s16le stereo at 48k: standard voiceover territory, and half the pipe
/// bandwidth of float32 for no audible cost on a preview bed.
const int _kBedRate = 48000;
const int _kBedChannels = 2;
const int _kBedBytesPerFrame = _kBedChannels * 2;
const int _kNativePacketFrames = 480;
const int _kNativePacketBytes = _kNativePacketFrames * _kBedBytesPerFrame;

/// An addressable output sink. [id] null means "let the backend decide".
class PlaybackDevice {
  /// Backend-specific identifier (Pulse sink name or ALSA device string).
  final String? id;
  final String description;

  const PlaybackDevice({required this.id, required this.description});

  @override
  String toString() => description;

  @override
  bool operator ==(Object other) =>
      other is PlaybackDevice && other.id == id;

  @override
  int get hashCode => id?.hashCode ?? 0;
}

class AudioBedException implements Exception {
  final String message;
  const AudioBedException(this.message);

  @override
  String toString() => 'AudioBedException: $message';
}

/// Result of probing a candidate bed file. Always returned, never thrown:
/// a missing or unreadable file is a UI state (amber row in the asset
/// manager), not an exception the menu has to catch.
class AudioBedInfo {
  final String path;

  /// False when the file is absent, unreadable, or holds no audio stream.
  final bool ok;

  /// Source duration in seconds. Zero when [ok] is false.
  final double durationSec;

  /// Source properties, for the readout. Zero when unknown.
  final int sampleRate;
  final int channels;

  /// Human-readable reason [ok] is false. Empty when fine.
  final String error;

  const AudioBedInfo({
    required this.path,
    required this.ok,
    required this.durationSec,
    this.sampleRate = 0,
    this.channels = 0,
    this.error = '',
  });

  const AudioBedInfo.missing(this.path, this.error)
      : ok = false,
        durationSec = 0.0,
        sampleRate = 0,
        channels = 0;

  /// Length in engine frames, rounded up so a partial trailing frame is
  /// never clipped. Caller supplies fps to keep this file free of any
  /// engine import.
  int framesAt(int fps) =>
      ok ? (durationSec * fps).ceil() : 0;

  String get displayName => path.split('/').last;

  /// "1:14.2" style readout for the menu strip.
  String get durationLabel {
    if (!ok) return '--:--';
    final int totalTenths = (durationSec * 10).round();
    final int m = totalTenths ~/ 600;
    final int s = (totalTenths % 600) ~/ 10;
    final int t = totalTenths % 10;
    return '$m:${s.toString().padLeft(2, '0')}.$t';
  }
}

/// Probes bed files. Separate from the player because the menu needs
/// duration whether or not a playback backend exists: the length readout
/// and the end-hold extension must work on a machine with no sound card.
class AudioBedProbe {
  static Future<bool> ffmpegAvailable() async {
    try {
      final ProcessResult r = await Process.run('ffmpeg', ['-version']);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Reads duration, rate, and channel count from [path] via ffprobe.
  ///
  /// Falls back to ffmpeg's own stream dump if ffprobe is missing, since
  /// some distro ffmpeg packages ship without it and R3nder already hard
  /// depends on ffmpeg for export.
  static Future<AudioBedInfo> probe(String path) async {
    if (path.trim().isEmpty) {
      return const AudioBedInfo.missing('', 'No audio bed selected.');
    }
    if (!File(path).existsSync()) {
      return AudioBedInfo.missing(path, 'File not found.');
    }

    final AudioBedInfo? viaProbe = await _probeWithFfprobe(path);
    if (viaProbe != null) return viaProbe;

    final AudioBedInfo? viaFfmpeg = await _probeWithFfmpeg(path);
    if (viaFfmpeg != null) return viaFfmpeg;

    return AudioBedInfo.missing(
        path, 'Could not read an audio stream (ffprobe and ffmpeg both failed).');
  }

  static Future<AudioBedInfo?> _probeWithFfprobe(String path) async {
    try {
      final ProcessResult r = await Process.run('ffprobe', [
        '-v', 'error',
        '-select_streams', 'a:0',
        '-show_entries', 'stream=sample_rate,channels:format=duration',
        '-of', 'default=noprint_wrappers=1',
        path,
      ]);
      if (r.exitCode != 0) return null;

      double dur = 0.0;
      int rate = 0;
      int ch = 0;
      for (final String line in (r.stdout as String).split('\n')) {
        final int eq = line.indexOf('=');
        if (eq <= 0) continue;
        final String key = line.substring(0, eq).trim();
        final String val = line.substring(eq + 1).trim();
        if (key == 'duration') dur = double.tryParse(val) ?? 0.0;
        if (key == 'sample_rate') rate = int.tryParse(val) ?? 0;
        if (key == 'channels') ch = int.tryParse(val) ?? 0;
      }

      if (dur <= 0.0) {
        return AudioBedInfo.missing(path, 'No decodable audio stream.');
      }
      return AudioBedInfo(
        path: path,
        ok: true,
        durationSec: dur,
        sampleRate: rate,
        channels: ch,
      );
    } catch (_) {
      return null;
    }
  }

  /// ffprobe-free fallback. Decodes to null and reads the reported time.
  /// Slower (it walks the file) but only runs when ffprobe is absent.
  static Future<AudioBedInfo?> _probeWithFfmpeg(String path) async {
    try {
      final ProcessResult r = await Process.run('ffmpeg', [
        '-v', 'info',
        '-i', path,
        '-f', 'null',
        '-',
      ]);
      final String err = '${r.stderr}';

      // "time=00:01:14.23" from the final progress line.
      final Iterable<RegExpMatch> times =
          RegExp(r'time=(\d+):(\d\d):(\d\d\.\d+)').allMatches(err);
      if (times.isEmpty) return null;
      final RegExpMatch last = times.last;
      final double dur = int.parse(last.group(1)!) * 3600 +
          int.parse(last.group(2)!) * 60 +
          double.parse(last.group(3)!);
      if (dur <= 0.0) return null;

      final RegExpMatch? stream =
          RegExp(r'Audio:.*?(\d+) Hz, (\w+)').firstMatch(err);
      final int rate =
          stream != null ? (int.tryParse(stream.group(1)!) ?? 0) : 0;
      final int ch = stream != null
          ? (stream.group(2) == 'mono'
              ? 1
              : stream.group(2) == 'stereo'
                  ? 2
                  : 0)
          : 0;

      return AudioBedInfo(
        path: path,
        ok: true,
        durationSec: dur,
        sampleRate: rate,
        channels: ch,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Playback surface. Kept abstract so transport details never leak into the
/// authoring callers.
abstract class AudioBedPlayer {
  /// Backend name for the UI ("libpulse", "aplay").
  String get backendName;

  Future<List<PlaybackDevice>> listDevices();

  /// Starts [path] at [startSec], attenuated by [gainDb], on [device].
  /// Anything already playing is stopped first. Returns once the pipeline
  /// is spawned, not once playback ends.
  ///
  /// [musicPath] adds a second track summed into the same pipeline at
  /// [musicGainDb]. The signature is deliberately asymmetric: the voice bed
  /// is the required first argument and music is an option on it, because
  /// the two are not interchangeable. An ordered list of equal tracks would
  /// suggest they were, and the length contract says otherwise.
  ///
  /// [loop] repeats the FIRST argument indefinitely. In practice this is only
  /// ever set for a music track playing without a voiceover, since the caller
  /// hands whichever track exists to the primary slot. Looping a voiceover is
  /// not a thing anyone wants, and nothing sets it for one.
  ///
  /// [musicLoop] does the same for [musicPath]. Looping fills, it never
  /// extends: playback is still bounded by [durationSec], exactly as the bake
  /// is bounded by its output `-t`, so a repeating score cannot make anything
  /// longer than it already was.
  ///
  /// [musicSeekSec] overrides where the music track starts, for phase. When a
  /// loop is running, scrubbing to frame N should land at N modulo the track
  /// length rather than at N, or the preview would report a musical position
  /// the bake will not have. See [loopedSeek].
  ///
  /// [durationSec] trims playback that many seconds after [startSec]. Pass
  /// the picture's remaining length so the preview stops exactly where the
  /// bake's `-t` will: without it, a music bed longer than the piece keeps
  /// playing over a finished timeline and the editor implies a tail the
  /// export does not contain. Null plays to the end of the longest track,
  /// which is what an audition wants.
  Future<void> play(
    String path, {
    double startSec = 0.0,
    double gainDb = 0.0,
    bool loop = false,
    PlaybackDevice? device,
    String? musicPath,
    double musicGainDb = 0.0,
    bool musicLoop = false,
    double? musicSeekSec,
    double? durationSec,
  });

  Future<void> stop();

  /// Half a second of soft sine, so the user can confirm a sink actually
  /// has speakers on it before authoring against silence.
  Future<void> testTone({PlaybackDevice? device});

  bool get isPlaying;

  void dispose();
}

/// Prefers the in-process Linux libpulse sink. aplay remains a fallback for a
/// Linux environment where the PulseAudio-compatible server cannot be opened.
/// Export remains enabled even when neither preview backend is available.
Future<AudioBedPlayer?> createAudioBedPlayer() async {
  if (Platform.isLinux && NativeAudioSink.isSupported) {
    try {
      final NativeAudioSink probe = NativeAudioSink(
        sampleRate: _kBedRate,
        channels: _kBedChannels,
      );
      probe.dispose();
      return _PipedPlayer._nativePulse();
    } catch (_) {
      // Fall through to aplay. A render-only machine may legitimately have no
      // PulseAudio-compatible server even though the runner has libpulse.
    }
  }
  if (await _binaryExists('aplay')) return _PipedPlayer._aplay();
  return null;
}

Future<bool> _binaryExists(String name) async {
  try {
    final ProcessResult r = await Process.run('which', [name]);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

class _PipedPlayer implements AudioBedPlayer {
  @override
  final String backendName;

  final bool _useNativePulse;
  final List<String> Function(String? deviceId) _sinkArgs;
  final Future<List<PlaybackDevice>> Function() _enumerate;

  Process? _decoder;
  Process? _sink;
  NativeAudioSink? _nativeSink;
  Future<void>? _feeder;
  bool _playing = false;

  /// Invalidates in-flight pipe plumbing when a newer play/stop supersedes
  /// it. Without this, a fast scrub sequence leaves orphaned feeders racing
  /// to write into a sink that belongs to a later request.
  int _generation = 0;

  _PipedPlayer._(
    this.backendName,
    this._sinkArgs,
    this._enumerate, {
    bool useNativePulse = false,
  }) : _useNativePulse = useNativePulse;

  factory _PipedPlayer._nativePulse() {
    return _PipedPlayer._(
      'libpulse',
      (_) => const <String>[],
      _enumeratePulseSinks,
      useNativePulse: true,
    );
  }

  factory _PipedPlayer._aplay() {
    return _PipedPlayer._(
      'aplay',
      (String? dev) => [
        '-t', 'raw',
        '-f', 'S16_LE',
        '-r', '$_kBedRate',
        '-c', '$_kBedChannels',
        '-q',
        if (dev != null) ...['-D', dev],
      ],
      _enumerateAlsaDevices,
    );
  }

  @override
  bool get isPlaying => _playing;

  @override
  Future<List<PlaybackDevice>> listDevices() => _enumerate();

  @override
  Future<void> play(
    String path, {
    double startSec = 0.0,
    double gainDb = 0.0,
    bool loop = false,
    PlaybackDevice? device,
    String? musicPath,
    double musicGainDb = 0.0,
    bool musicLoop = false,
    double? musicSeekSec,
    double? durationSec,
  }) async {
    await stop();
    if (!File(path).existsSync()) return;

    // A music bed that is not on disk is simply absent. It cannot fail a
    // preview any more than it can fail a bake.
    final String? music =
        (musicPath != null && musicPath.trim().isNotEmpty &&
                File(musicPath).existsSync())
            ? musicPath
            : null;

    final int gen = ++_generation;
    final double seek = startSec < 0.0 ? 0.0 : startSec;
    final double musicSeek =
        (musicSeekSec ?? startSec) < 0.0 ? 0.0 : (musicSeekSec ?? startSec);

    // WHY A LOOPED TRACK IS NOT SEEKED WITH -ss.
    //
    // -stream_loop and an input -ss interact badly and not identically across
    // ffmpeg versions: the loop can restart at the seek point rather than at
    // the head of the file, so every repeat after the first would be missing
    // its opening. That is inaudible on the first pass and obvious on the
    // second, which is the worst way for a bug to present.
    //
    // So a looped track is decoded from zero and phase-aligned in the filter
    // chain instead, with atrim discarding the lead-in and asetpts restamping
    // what is left. Deterministic on every build, at the cost of decoding up
    // to one track length of audio that is thrown away. Audio decodes far
    // faster than realtime, so that cost does not show up in a scrub.
    String phaseChain(double sec) {
      if (sec <= 0.0) return '';
      return 'atrim=start=${sec.toStringAsFixed(4)},asetpts=N/SR/TB';
    }

    // -ss ahead of -i is input seeking: ffmpeg jumps rather than decoding
    // from zero, which is what keeps scrub responsive on a long bed.
    // -accurate_seek pulls it back to sample precision afterward.
    //
    // BOTH inputs take the seek, and the same one, unless a loop is running
    // on one of them. The two beds are locked to a single timeline, so
    // seeking one and not the other would put the score somewhere the picture
    // never was.
    final List<String> decodeArgs = <String>[
      '-v', 'error',
      if (loop) ...['-stream_loop', '-1'],
      '-accurate_seek',
      if (seek > 0.0 && !loop) ...['-ss', seek.toStringAsFixed(4)],
      '-i', path,
      if (music != null) ...[
        if (musicLoop) ...['-stream_loop', '-1'],
        '-accurate_seek',
        if (musicSeek > 0.0 && !musicLoop)
          ...['-ss', musicSeek.toStringAsFixed(4)],
        '-i', music,
      ],
      '-f', 's16le',
      '-acodec', 'pcm_s16le',
      '-ac', '$_kBedChannels',
      '-ar', '$_kBedRate',
      // Gain lives here rather than in Dart so preview level matches the
      // level the exporter will mux. No normalization, ever.
      //
      // One track keeps the -af path it always had, byte for byte, so a
      // workspace with no music behaves exactly as it did. Two tracks have
      // to build a graph instead, because a stream summed inside
      // filter_complex is a label rather than an input and -af cannot
      // address it. See _mixGraph for why normalize=0 is load bearing.
      if (music != null) ...[
        '-filter_complex',
        bedMixGraph(
          voiceGainDb: gainDb,
          musicGainDb: musicGainDb,
          voiceChain: loop ? phaseChain(seek) : '',
          musicChain: musicLoop ? phaseChain(musicSeek) : '',
        ),
        '-map', '[$kBedMixOutLabel]',
      ] else if (gainDb != 0.0 || (loop && seek > 0.0)) ...[
        '-af', <String>[
          if (loop && seek > 0.0) phaseChain(seek),
          bedVolumeFilter(gainDb),
        ].where((s) => s.isNotEmpty).join(','),
      ],
      // Output-side trim, so it counts from the seek point rather than from
      // the head of the file. This is what keeps a long music bed from
      // playing over a timeline the export will have already ended, and what
      // keeps an infinite loop finite.
      if (durationSec != null && durationSec > 0.0)
        ...['-t', durationSec.toStringAsFixed(4)],
      '-',
    ];

    Process decoder;
    try {
      decoder = await Process.start('ffmpeg', decodeArgs);
    } catch (e) {
      _playing = false;
      throw AudioBedException('Could not start playback decoder: $e');
    }

    if (_useNativePulse) {
      NativeAudioSink nativeSink;
      try {
        nativeSink = NativeAudioSink(
          device: device?.id,
          sampleRate: _kBedRate,
          channels: _kBedChannels,
        );
      } catch (e) {
        _killQuietly(decoder);
        _playing = false;
        throw AudioBedException('Could not open native playback sink: $e');
      }

      // A newer request landed while either endpoint was opening. The new
      // generation owns playback, so this one must not contribute a sample.
      if (gen != _generation) {
        _killQuietly(decoder);
        nativeSink.dispose();
        return;
      }

      _decoder = decoder;
      _nativeSink = nativeSink;
      _playing = true;

      // A full ffmpeg stderr pipe can still deadlock the decoder even though
      // stdout now feeds native memory rather than another process.
      unawaited(decoder.stderr.drain<void>().catchError((_) {}));

      final Future<void> feeder =
          _feedNative(decoder.stdout, nativeSink, gen);
      _feeder = feeder;
      unawaited(_finishNativePlayback(gen, decoder, nativeSink, feeder));
      return;
    }

    Process sink;
    try {
      sink = await Process.start(
        backendName,
        _sinkArgs(device?.id),
      );
    } catch (e) {
      _killQuietly(decoder);
      _playing = false;
      throw AudioBedException('Could not start playback sink: $e');
    }

    // A newer request landed while we were spawning. Discard this one
    // rather than letting two pipelines fight over the sink.
    if (gen != _generation) {
      _killQuietly(decoder);
      _killQuietly(sink);
      return;
    }

    _decoder = decoder;
    _sink = sink;
    _playing = true;

    // Drain both stderrs or a full pipe buffer deadlocks the children.
    unawaited(decoder.stderr.drain<void>().catchError((_) {}));
    unawaited(sink.stderr.drain<void>().catchError((_) {}));
    unawaited(sink.stdout.drain<void>().catchError((_) {}));

    // Stream pipe carries backpressure, so the decoder is paced by the
    // sink rather than racing ahead and buffering the whole file. Retain the
    // future so stop() can prove the old generation is quiescent.
    final Future<void> feeder = () async {
      try {
        await decoder.stdout.pipe(sink.stdin);
      } catch (_) {
        // Broken pipe after a kill during scrub. Expected, not an error.
      }
    }();
    _feeder = feeder;

    // Natural end of file: the decoder exits, the pipe closes, the sink
    // drains and exits. Only then is playback genuinely over.
    unawaited(sink.exitCode.then((_) {
      if (gen == _generation) {
        _playing = false;
        _decoder = null;
        _sink = null;
        if (identical(_feeder, feeder)) _feeder = null;
      }
    }).catchError((_) {}));
  }

  Future<void> _feedNative(
    Stream<List<int>> source,
    NativeAudioSink sink,
    int gen,
  ) async {
    final BytesBuilder pending = BytesBuilder(copy: false);

    await for (final List<int> chunk in source) {
      if (gen != _generation) return;
      pending.add(chunk);
      if (pending.length < _kNativePacketBytes) continue;

      final Uint8List bytes = pending.takeBytes();
      int offset = 0;
      final int packetEnd =
          bytes.lengthInBytes - (bytes.lengthInBytes % _kNativePacketBytes);
      while (offset < packetEnd) {
        final Uint8List packet = Uint8List.sublistView(
          bytes,
          offset,
          offset + _kNativePacketBytes,
        );
        if (!await _enqueueNativePacket(sink, packet, gen)) return;
        offset += _kNativePacketBytes;
      }
      if (offset < bytes.lengthInBytes) {
        pending.add(Uint8List.sublistView(bytes, offset));
      }
    }

    if (gen != _generation) return;
    final Uint8List tail = pending.takeBytes();
    if (tail.lengthInBytes % _kBedBytesPerFrame != 0) {
      throw const AudioBedException(
        'FFmpeg ended on a partial PCM sample frame.',
      );
    }
    if (tail.isNotEmpty) {
      await _enqueueNativePacket(sink, tail, gen);
    }
  }

  Future<bool> _enqueueNativePacket(
    NativeAudioSink sink,
    Uint8List packet,
    int gen,
  ) async {
    while (gen == _generation) {
      try {
        if (sink.tryEnqueue(packet)) return true;
      } on AudioSinkException catch (e) {
        throw AudioBedException('Native audio sink failed: ${e.message}');
      }
      // NativeAudioSink is deliberately bounded. Yield instead of letting
      // ffmpeg race ahead into a Dart-side buffer when the worker is full.
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    return false;
  }

  Future<void> _finishNativePlayback(
    int gen,
    Process decoder,
    NativeAudioSink sink,
    Future<void> feeder,
  ) async {
    try {
      await decoder.exitCode;
      await feeder;
      if (gen != _generation) return;

      // The feeder being done means every decoder byte was accepted by the
      // native queue, not that the speaker has played it. Drain is the native
      // equivalent of waiting for paplay/aplay to exit naturally.
      sink.drain();
    } catch (_) {
      // Playback already has no asynchronous error channel. A transport error
      // ends this generation, matching the previous subprocess behavior.
    } finally {
      if (gen == _generation) {
        _playing = false;
        if (identical(_decoder, decoder)) _decoder = null;
        if (identical(_nativeSink, sink)) _nativeSink = null;
        if (identical(_feeder, feeder)) _feeder = null;
        sink.dispose();
      }
    }
  }

  @override
  Future<void> stop() async {
    _generation++;
    final Process? d = _decoder;
    final Process? s = _sink;
    final NativeAudioSink? native = _nativeSink;
    final Future<void>? feeder = _feeder;
    _decoder = null;
    _sink = null;
    _nativeSink = null;
    _feeder = null;
    _playing = false;

    // Decoder first: that closes the producer side. The generation was already
    // invalidated, so a native feeder will not enqueue another packet. Only
    // after its future settles is it legal to flush/dispose the old sink.
    _killQuietly(d);
    _killQuietly(s);
    if (feeder != null) {
      try {
        await feeder;
      } catch (_) {}
    }
    if (native != null) {
      try {
        native.flush();
      } catch (_) {}
      native.dispose();
    }
  }

  @override
  Future<void> testTone({PlaybackDevice? device}) async {
    await stop();
    final int gen = ++_generation;

    const double seconds = 0.5;
    const double freq = 440.0;
    final int frames = (_kBedRate * seconds).round();
    final Int16List buf = Int16List(frames * _kBedChannels);

    for (int i = 0; i < frames; i++) {
      // Short raised-cosine ends, otherwise the discontinuity clicks and
      // the click is what you hear instead of the sink.
      final double t = i / _kBedRate;
      final double ramp = math.min(1.0, math.min(i, frames - i) / 480.0);
      final int v =
          (math.sin(2 * math.pi * freq * t) * 0.22 * ramp * 32767).round();
      for (int c = 0; c < _kBedChannels; c++) {
        buf[i * _kBedChannels + c] = v;
      }
    }

    if (_useNativePulse) {
      NativeAudioSink? sink;
      try {
        sink = NativeAudioSink(
          device: device?.id,
          sampleRate: _kBedRate,
          channels: _kBedChannels,
        );
        final Uint8List bytes =
            buf.buffer.asUint8List(0, buf.lengthInBytes);
        int offset = 0;
        while (offset < bytes.lengthInBytes && gen == _generation) {
          final int end = math.min(
            offset + _kNativePacketBytes,
            bytes.lengthInBytes,
          );
          final Uint8List packet = Uint8List.sublistView(bytes, offset, end);
          if (!await _enqueueNativePacket(sink, packet, gen)) return;
          offset = end;
        }
        if (gen == _generation) sink.drain();
      } catch (e) {
        throw AudioBedException('Test tone failed on this device: $e');
      } finally {
        sink?.dispose();
      }
      return;
    }

    try {
      final Process sink =
          await Process.start(backendName, _sinkArgs(device?.id));
      if (gen != _generation) {
        _killQuietly(sink);
        return;
      }
      unawaited(sink.stderr.drain<void>().catchError((_) {}));
      unawaited(sink.stdout.drain<void>().catchError((_) {}));
      sink.stdin.add(buf.buffer.asUint8List(0, buf.lengthInBytes));
      await sink.stdin.close();
      await sink.exitCode;
    } catch (e) {
      throw AudioBedException('Test tone failed on this device: $e');
    }
  }

  @override
  void dispose() {
    _generation++;
    _killQuietly(_decoder);
    _killQuietly(_sink);
    final NativeAudioSink? native = _nativeSink;
    _decoder = null;
    _sink = null;
    _nativeSink = null;
    _feeder = null;
    _playing = false;
    if (native != null) {
      try {
        native.flush();
      } catch (_) {}
      native.dispose();
    }
  }

  static void _killQuietly(Process? p) {
    if (p == null) return;
    try {
      p.kill(ProcessSignal.sigterm);
    } catch (_) {}
  }

  // Device enumeration

  static Future<List<PlaybackDevice>> _enumeratePulseSinks() async {
    final List<PlaybackDevice> devices = <PlaybackDevice>[
      const PlaybackDevice(id: null, description: 'System Default'),
    ];
    try {
      final ProcessResult r =
          await Process.run('pactl', ['list', 'short', 'sinks']);
      if (r.exitCode == 0) {
        for (final String line in (r.stdout as String).split('\n')) {
          final List<String> parts = line.trim().split('\t');
          if (parts.length >= 2 && parts[1].isNotEmpty) {
            devices.add(PlaybackDevice(
              id: parts[1],
              description: _prettifySinkName(parts[1]),
            ));
          }
        }
      }
    } catch (_) {}
    return devices;
  }

  /// alsa_output.pci-0000_00_1f.3.analog-stereo
  ///   becomes "analog-stereo (pci-0000_00_1f.3)"
  static String _prettifySinkName(String sink) {
    final List<String> segs = sink.split('.');
    if (segs.length >= 3 && segs.first.startsWith('alsa_output')) {
      return '${segs.last} (${segs.sublist(1, segs.length - 1).join('.')})';
    }
    return sink;
  }

  static Future<List<PlaybackDevice>> _enumerateAlsaDevices() async {
    final List<PlaybackDevice> devices = <PlaybackDevice>[
      const PlaybackDevice(id: null, description: 'System Default'),
    ];
    try {
      final ProcessResult r = await Process.run('aplay', ['-L']);
      if (r.exitCode == 0) {
        final List<String> lines = (r.stdout as String).split('\n');
        for (int i = 0; i < lines.length; i++) {
          final String line = lines[i];
          if (line.isEmpty || line.startsWith(' ')) continue;
          final String name = line.trim();
          // Keep the useful ones, skip the plugin zoo.
          if (name == 'default' ||
              name.startsWith('hw:') ||
              name.startsWith('plughw:') ||
              name.startsWith('pulse') ||
              name.startsWith('pipewire')) {
            String desc = name;
            if (i + 1 < lines.length && lines[i + 1].startsWith(' ')) {
              desc = '$name (${lines[i + 1].trim()})';
            }
            devices.add(PlaybackDevice(id: name, description: desc));
          }
        }
      }
    } catch (_) {}
    return devices;
  }
}

/// Where a looping track should start so it stays in phase with the picture.
///
/// A loop scrubbed to frame N is not at N seconds into the file, it is at N
/// modulo the file's length. Without this the preview would report a musical
/// position the bake does not have, and the two would agree only at frame 0.
///
/// Preview-only by construction. The bake starts every track at the head and
/// offsets it with real silence, so it has no phase to resolve.
double loopedSeek(double startSec, double durationSec) {
  if (durationSec <= 0.0 || startSec <= 0.0) return 0.0;
  return startSec % durationSec;
}

/// Resolves a stored sink id against what is actually present right now.
///
/// Sink names are machine properties, not project properties: a workspace
/// carried to another box will name a sink that does not exist there. This
/// falls back to System Default rather than throwing or playing nowhere.
PlaybackDevice resolveDevice(List<PlaybackDevice> available, String? storedId) {
  if (storedId == null) {
    return const PlaybackDevice(id: null, description: 'System Default');
  }
  for (final PlaybackDevice d in available) {
    if (d.id == storedId) return d;
  }
  return const PlaybackDevice(id: null, description: 'System Default');
}

/// Timeline arithmetic shared by the menu readout, the preview loop, the
/// editor scrubber, and the exporter, so the four cannot drift apart.
///
/// The bed starts after the preroll wipe, so both video and audio shift by
/// the same amount and the delta is preroll-independent. Any surplus audio
/// becomes extra end-hold frames: the engine keeps ticking a settled
/// terminal with a live blinking cursor rather than freezing a still.
class BedTimeline {
  /// Frames the script produces on its own, from the dry run.
  final int scriptFrames;

  /// Frames the VOICE bed occupies, zero when none is attached.
  ///
  /// This is the one audio value with authority over length. Named for the
  /// bed it came from now that there are two, because "audio" would read as
  /// "all of it" and the whole point is that it is not.
  final int audioFrames;

  /// Frames the MUSIC bed occupies, zero when none is attached.
  ///
  /// DELIBERATELY INERT. It is carried for the readout and the ribbon lane
  /// and touches no arithmetic below: not endHoldExtraFrames, not
  /// totalFrames, not deltaFrames. Music is trimmed to picture rather than
  /// holding for it, so a long score cannot lengthen a piece by a frame.
  ///
  /// If a future change makes this feed the end hold, the exporter's
  /// frame-count guarantee is not what breaks first. Dropping a four minute
  /// track onto a forty second cut and getting a four minute render is,
  /// and it would look like a bug in the engine rather than a decision made
  /// here.
  final int musicFrames;

  const BedTimeline({
    required this.scriptFrames,
    required this.audioFrames,
    this.musicFrames = 0,
  });

  factory BedTimeline.from({
    required int scriptFrames,
    required AudioBedInfo? bed,
    required int fps,
    AudioBedInfo? music,
  }) {
    return BedTimeline(
      scriptFrames: scriptFrames,
      audioFrames: (bed != null && bed.ok) ? bed.framesAt(fps) : 0,
      musicFrames: (music != null && music.ok) ? music.framesAt(fps) : 0,
    );
  }

  /// Frames to add to the engine's end hold. Zero when the script already
  /// outruns the bed, which is the finished-piece case.
  int get endHoldExtraFrames {
    final int delta = audioFrames - scriptFrames;
    return delta > 0 ? delta : 0;
  }

  int get totalFrames => scriptFrames + endHoldExtraFrames;

  /// Signed slack in frames. Negative means the script runs past the bed,
  /// which is normal. Positive means you owe more choreography.
  int get deltaFrames => audioFrames - scriptFrames;

  bool get hasBed => audioFrames > 0;

  bool get hasMusic => musicFrames > 0;

  /// How much music the export will cut off the end.
  ///
  /// Not a warning and not a problem: a score is normally longer than the
  /// shot it plays under, and trimming it is the designed behavior. It is
  /// reported so the ribbon can draw a music lane that stops where the
  /// picture stops instead of one that runs past the end, which now means
  /// something different on the two lanes. On the voice lane an overrun is
  /// dead air you still owe choreography for. On the music lane it is
  /// simply frames that will not be in the file.
  int get musicTrimmedFrames {
    final int over = musicFrames - totalFrames;
    return over > 0 ? over : 0;
  }

  /// Frames of music that actually reach the export, for the ribbon lane.
  int get musicVisibleFrames =>
      musicFrames < totalFrames ? musicFrames : totalFrames;

  /// Under roughly two seconds a tail is an ordinary trailing beat. Past
  /// that it usually means the script is short, so the readout should warn
  /// rather than silently absorb it.
  bool warnAt(int fps) => endHoldExtraFrames > fps * 2;
}
