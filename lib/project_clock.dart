// ./lib/project_clock.dart
//
// Project time is a value, not a side effect of painting.
//
// The realtime implementation is backed by a tiny native clock so the
// authoritative timebase does not depend on Flutter's vsync cadence. Flutter
// may sample it at 60/120/144 Hz, but sampling never advances time. The same
// control block is shaped for the eventual audio clock: coherent control
// fields live behind a seqlock, while played_samples is an independent atomic
// written by the audio sink.
//
// Export deliberately does not use the native shared clock. Export time is an
// explicit value selected by the render loop, which keeps deterministic bake
// state independent from preview state and eventually permits both at once.

import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Exact project frame rate. Never store canonical project time as a double.
@immutable
class RationalFrameRate {
  final int numerator;
  final int denominator;

  const RationalFrameRate._(this.numerator, this.denominator);

  factory RationalFrameRate(int numerator, [int denominator = 1]) {
    if (numerator <= 0 || denominator <= 0) {
      throw ArgumentError('Frame rate numerator and denominator must be > 0.');
    }
    final int g = _gcd(numerator, denominator);
    return RationalFrameRate._(numerator ~/ g, denominator ~/ g);
  }

  double get framesPerSecond => numerator / denominator;

  @override
  bool operator ==(Object other) =>
      other is RationalFrameRate &&
      other.numerator == numerator &&
      other.denominator == denominator;

  @override
  int get hashCode => Object.hash(numerator, denominator);

  @override
  String toString() => '$numerator/$denominator';
}

enum ProjectClockMode { monotonic, scrub, audio }

/// Exact point on the project timeline.
///
/// [frame] is the whole project frame. [phaseNumerator]/[phaseDenominator]
/// describes the sub-frame position in [0, 1). The phase is kept rational so
/// 24000/1001, audio sample clocks, and arbitrary scrub positions never pass
/// through floating point merely to become canonical state.
@immutable
class ProjectTime {
  final int frame;
  final int phaseNumerator;
  final int phaseDenominator;
  final int epoch;
  final ProjectClockMode mode;

  const ProjectTime._({
    required this.frame,
    required this.phaseNumerator,
    required this.phaseDenominator,
    required this.epoch,
    required this.mode,
  });

  factory ProjectTime({
    required int frame,
    int phaseNumerator = 0,
    int phaseDenominator = 1,
    int epoch = 0,
    ProjectClockMode mode = ProjectClockMode.monotonic,
  }) {
    if (phaseDenominator <= 0) {
      throw ArgumentError('phaseDenominator must be > 0.');
    }

    int whole = frame;
    final int quotient = phaseNumerator ~/ phaseDenominator;
    int remainder = phaseNumerator - quotient * phaseDenominator;
    whole += quotient;
    if (remainder < 0) {
      remainder += phaseDenominator;
      whole -= 1;
    }

    final int g = _gcd(remainder.abs(), phaseDenominator);
    return ProjectTime._(
      frame: whole,
      phaseNumerator: remainder ~/ g,
      phaseDenominator: phaseDenominator ~/ g,
      epoch: epoch,
      mode: mode,
    );
  }

  factory ProjectTime.zero({
    int epoch = 0,
    ProjectClockMode mode = ProjectClockMode.monotonic,
  }) =>
      ProjectTime(frame: 0, epoch: epoch, mode: mode);

  bool get isOnFrame => phaseNumerator == 0;

  /// UI/debug convenience only. Never feed this back into canonical time.
  double get phase => phaseNumerator / phaseDenominator;

  ProjectTime withEpoch(int value) => ProjectTime(
        frame: frame,
        phaseNumerator: phaseNumerator,
        phaseDenominator: phaseDenominator,
        epoch: value,
        mode: mode,
      );

  ProjectTime withMode(ProjectClockMode value) => ProjectTime(
        frame: frame,
        phaseNumerator: phaseNumerator,
        phaseDenominator: phaseDenominator,
        epoch: epoch,
        mode: value,
      );

  @override
  String toString() =>
      'ProjectTime(frame=$frame, phase=$phaseNumerator/$phaseDenominator, '
      'epoch=$epoch, mode=${mode.name})';
}

/// Common project-clock surface.
///
/// Realtime clocks derive [current] from an external authority. Export clocks
/// expose an explicitly selected deterministic frame. The caller never needs
/// to pretend those are the same physical mechanism merely because they share
/// a time value.
abstract interface class ProjectClock {
  RationalFrameRate get rate;
  ProjectTime get current;
  ProjectTime sample();
  void seek(ProjectTime time);
  void dispose();
}

/// Pure deterministic clock used by export and deterministic tests.
///
/// No native state, no wall clock, no audio device, no global mutable clock.
/// [selectFrame] is an explicit value assignment and does not increment the
/// epoch; [seek] does, because a seek invalidates asynchronous work.
class ExportProjectClock implements ProjectClock {
  @override
  final RationalFrameRate rate;

  int _epoch = 0;
  ProjectTime _current;

  ExportProjectClock(this.rate)
      : _current = ProjectTime.zero(mode: ProjectClockMode.scrub);

  @override
  ProjectTime get current => _current;

  int get epoch => _epoch;

  void selectFrame(int frame) {
    _current = ProjectTime(
      frame: frame,
      epoch: _epoch,
      mode: ProjectClockMode.scrub,
    );
  }

  void select(ProjectTime time) {
    _current = ProjectTime(
      frame: time.frame,
      phaseNumerator: time.phaseNumerator,
      phaseDenominator: time.phaseDenominator,
      epoch: _epoch,
      mode: ProjectClockMode.scrub,
    );
  }

  @override
  void seek(ProjectTime time) {
    _epoch += 1;
    _current = ProjectTime(
      frame: time.frame,
      phaseNumerator: time.phaseNumerator,
      phaseDenominator: time.phaseDenominator,
      epoch: _epoch,
      mode: ProjectClockMode.scrub,
    );
  }

  @override
  ProjectTime sample() => _current;

  @override
  void dispose() {}
}

/// Realtime clock whose authority lives in the native control block.
///
/// This is also a [Listenable]. A Flutter Ticker may call [sample] at display
/// cadence, then mutate legacy frame-counted scene state up to [current], and
/// finally call [signalRepaint]. The Ticker is therefore only a poll/repaint
/// cadence. It is never the time source.
class NativeRealtimeProjectClock extends ChangeNotifier
    implements ProjectClock {
  RationalFrameRate _rate;

  @override
  RationalFrameRate get rate => _rate;

  final _NativeClockBindings _native;
  late final Pointer<Void> _handle;
  ProjectTime _current = ProjectTime.zero();
  bool _disposed = false;

  NativeRealtimeProjectClock(RationalFrameRate rate)
      : _rate = rate,
        _native = _NativeClockBindings.open() {
    _handle = _native.create(rate.numerator, rate.denominator);
    if (_handle == nullptr) {
      throw StateError('Native ProjectClock allocation failed.');
    }
    _current = sample();
  }

  static bool get isSupported => Platform.isLinux;

  @override
  ProjectTime get current => _current;

  @override
  ProjectTime sample() {
    _checkAlive();
    final _NativeClockSnapshot raw = _native.read(_handle).ref;
    _current = ProjectTime(
      frame: raw.frame,
      phaseNumerator: raw.phaseNumerator,
      phaseDenominator: raw.phaseDenominator,
      epoch: raw.epoch,
      mode: _modeFromNative(raw.mode),
    );
    return _current;
  }

  /// Seek and immediately run from that exact point on CLOCK_MONOTONIC.
  @override
  void seek(ProjectTime time) => seekMonotonic(time);

  void seekMonotonic(ProjectTime time) {
    _checkAlive();
    _native.seekMonotonic(
      _handle,
      time.frame,
      time.phaseNumerator,
      time.phaseDenominator,
    );
    sample();
  }

  /// Hold on an exact authored scrub position. Every call is a seek and
  /// therefore advances the native epoch.
  void seekScrub(ProjectTime time) {
    _checkAlive();
    _native.seekScrub(
      _handle,
      time.frame,
      time.phaseNumerator,
      time.phaseDenominator,
    );
    sample();
  }

  /// Changes the native frame rate without changing the sampled project
  /// position. Re-anchoring through the active non-audio mode also advances
  /// epoch, because a rate change invalidates asynchronous work just like a
  /// seek. AUDIO is refused until its handoff owns enough sample-origin state
  /// to preserve the same audible position under a new project rate.
  void setRate(RationalFrameRate value) {
    _checkAlive();
    final ProjectTime anchor = sample();
    if (anchor.mode == ProjectClockMode.audio) {
      throw StateError('Cannot change ProjectClock rate while AUDIO is active.');
    }

    _native.setRate(_handle, value.numerator, value.denominator);
    _rate = value;

    if (anchor.mode == ProjectClockMode.scrub) {
      _native.seekScrub(
        _handle,
        anchor.frame,
        anchor.phaseNumerator,
        anchor.phaseDenominator,
      );
    } else {
      _native.seekMonotonic(
        _handle,
        anchor.frame,
        anchor.phaseNumerator,
        anchor.phaseDenominator,
      );
    }
    sample();
  }

  /// Reserved for the future PCM-backed audio clock. The audio backend sets
  /// the sample origin once, then updates only the standalone played_samples
  /// atomic. Latency is subtracted before samples are converted to project
  /// time, so the clock represents audible playout rather than queued audio.
  void seekAudio(
    ProjectTime time, {
    required int originSample,
    required int sampleRate,
    required int latencySamples,
  }) {
    _checkAlive();
    _native.seekAudio(
      _handle,
      time.frame,
      time.phaseNumerator,
      time.phaseDenominator,
      originSample,
      sampleRate,
      latencySamples,
    );
    sample();
  }

  void setLatencySamples(int samples) {
    _checkAlive();
    _native.setLatencySamples(_handle, samples);
  }

  void setPlayedSamples(int samples) {
    _checkAlive();
    _native.setPlayedSamples(_handle, samples);
  }

  void addPlayedSamples(int samples) {
    _checkAlive();
    _native.addPlayedSamples(_handle, samples);
  }

  /// Notify paint listeners only after the caller has brought mutable legacy
  /// scene state up to [current]. This ordering prevents a paint of the new
  /// clock time against the previous scene state during the purity migration.
  void signalRepaint() {
    _checkAlive();
    notifyListeners();
  }

  void _checkAlive() {
    if (_disposed) throw StateError('ProjectClock has been disposed.');
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _native.destroy(_handle);
    super.dispose();
  }
}

ProjectClockMode _modeFromNative(int value) {
  switch (value) {
    case 1:
      return ProjectClockMode.scrub;
    case 2:
      return ProjectClockMode.audio;
    default:
      return ProjectClockMode.monotonic;
  }
}

int _gcd(int a, int b) {
  a = a.abs();
  b = b.abs();
  while (b != 0) {
    final int t = a % b;
    a = b;
    b = t;
  }
  return a == 0 ? 1 : a;
}

final class _NativeClockSnapshot extends Struct {
  @Int64()
  external int frame;

  @Int64()
  external int phaseNumerator;

  @Int64()
  external int phaseDenominator;

  @Uint64()
  external int epoch;

  @Int32()
  external int mode;

  @Int32()
  external int padding;
}

typedef _CreateNative = Pointer<Void> Function(Int64 fpsNum, Int64 fpsDen);
typedef _CreateDart = Pointer<Void> Function(int fpsNum, int fpsDen);
typedef _DestroyNative = Void Function(Pointer<Void> handle);
typedef _DestroyDart = void Function(Pointer<Void> handle);
typedef _SetRateNative = Void Function(
  Pointer<Void> handle,
  Int64 fpsNum,
  Int64 fpsDen,
);
typedef _SetRateDart = void Function(
  Pointer<Void> handle,
  int fpsNum,
  int fpsDen,
);
typedef _SeekNative = Void Function(
  Pointer<Void> handle,
  Int64 frame,
  Int64 phaseNum,
  Int64 phaseDen,
);
typedef _SeekDart = void Function(
  Pointer<Void> handle,
  int frame,
  int phaseNum,
  int phaseDen,
);
typedef _SeekAudioNative = Void Function(
  Pointer<Void> handle,
  Int64 frame,
  Int64 phaseNum,
  Int64 phaseDen,
  Int64 originSample,
  Int64 sampleRate,
  Int64 latencySamples,
);
typedef _SeekAudioDart = void Function(
  Pointer<Void> handle,
  int frame,
  int phaseNum,
  int phaseDen,
  int originSample,
  int sampleRate,
  int latencySamples,
);
typedef _SetIntNative = Void Function(Pointer<Void> handle, Int64 value);
typedef _SetIntDart = void Function(Pointer<Void> handle, int value);
typedef _ReadNative = Pointer<_NativeClockSnapshot> Function(Pointer<Void> handle);
typedef _ReadDart = Pointer<_NativeClockSnapshot> Function(Pointer<Void> handle);

class _NativeClockBindings {
  final DynamicLibrary _library;

  late final _CreateDart create =
      _library.lookupFunction<_CreateNative, _CreateDart>('r3_clock_create');
  late final _DestroyDart destroy =
      _library.lookupFunction<_DestroyNative, _DestroyDart>('r3_clock_destroy');
  late final _SetRateDart setRate =
      _library.lookupFunction<_SetRateNative, _SetRateDart>('r3_clock_set_rate');
  late final _SeekDart seekMonotonic =
      _library.lookupFunction<_SeekNative, _SeekDart>('r3_clock_seek_monotonic');
  late final _SeekDart seekScrub =
      _library.lookupFunction<_SeekNative, _SeekDart>('r3_clock_seek_scrub');
  late final _SeekAudioDart seekAudio = _library
      .lookupFunction<_SeekAudioNative, _SeekAudioDart>('r3_clock_seek_audio');
  late final _SetIntDart setLatencySamples = _library.lookupFunction<
      _SetIntNative, _SetIntDart>('r3_clock_set_latency_samples');
  late final _SetIntDart setPlayedSamples = _library.lookupFunction<
      _SetIntNative, _SetIntDart>('r3_clock_set_played_samples');
  late final _SetIntDart addPlayedSamples = _library.lookupFunction<
      _SetIntNative, _SetIntDart>('r3_clock_add_played_samples');
  late final _ReadDart read =
      _library.lookupFunction<_ReadNative, _ReadDart>('r3_clock_read');

  _NativeClockBindings._(this._library);

  factory _NativeClockBindings.open() {
    if (!Platform.isLinux) {
      throw UnsupportedError(
          'The native realtime ProjectClock is currently implemented on Linux.');
    }

    // project_clock.cc is linked into the Linux runner itself and the runner
    // exports its symbols. No extra shared library has to be found beside a
    // portable build, and debug/release use the same lookup path.
    return _NativeClockBindings._(DynamicLibrary.process());
  }
}
