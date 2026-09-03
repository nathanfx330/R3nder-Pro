// ./lib/audio_sink.dart
//
// Linux native PCM sink for preview playback and AUDIO ProjectClock authority.
//
// FFmpeg remains the decoder/mixer. This sink owns blocking PulseAudio writes
// on its own worker thread and exposes bounded enqueue plus drain/flush state
// to Dart. The native worker also advances ProjectClock's cumulative submitted
// sample counter, supplies measured device latency, and performs the
// SCRUB -> AUDIO -> MONOTONIC handoffs without making Flutter's ticker the
// time source.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

/// Packet contract for the preview PCM stream.
///
/// Full producer packets represent exactly 10 ms of audio. A single shorter
/// frame-aligned packet is allowed only as the final EOF tail. This makes packet
/// duration explicit without forcing the native C sink itself to care about
/// decoder packetization.
class PreviewPcmPacketContract {
  static const int packetDurationMicroseconds = 10000;
  static const int bytesPerSample = 2;

  final int sampleRate;
  final int channels;

  const PreviewPcmPacketContract({
    required this.sampleRate,
    required this.channels,
  });

  int get bytesPerFrame {
    if (channels <= 0) {
      throw ArgumentError.value(channels, 'channels', 'Must be positive.');
    }
    return channels * bytesPerSample;
  }

  int get framesPerPacket {
    if (sampleRate <= 0) {
      throw ArgumentError.value(
        sampleRate,
        'sampleRate',
        'Must be positive.',
      );
    }

    final int scaled = sampleRate * packetDurationMicroseconds;
    if (scaled % Duration.microsecondsPerSecond != 0) {
      throw StateError(
        'A 10 ms preview packet is not an exact PCM frame count at '
        '$sampleRate Hz.',
      );
    }
    return scaled ~/ Duration.microsecondsPerSecond;
  }

  int get bytesPerPacket => framesPerPacket * bytesPerFrame;

  /// Validates one non-empty packet and returns true when it is the short EOF
  /// tail rather than a full 10 ms packet.
  bool validatePacketByteCount(
    int byteCount, {
    required bool shortTailAlreadyAccepted,
  }) {
    final int frameBytes = bytesPerFrame;
    if (byteCount <= 0 || byteCount % frameBytes != 0) {
      throw ArgumentError(
        'PCM byte count must be aligned to $frameBytes-byte sample frames.',
      );
    }

    final int fullPacketBytes = bytesPerPacket;
    if (byteCount > fullPacketBytes) {
      throw ArgumentError(
        'Preview PCM packets must not exceed 10 ms '
        '($fullPacketBytes bytes at $sampleRate Hz, $channels channels).',
      );
    }

    if (shortTailAlreadyAccepted) {
      throw StateError(
        'A short preview PCM tail must be followed by drain or flush before '
        'more audio is enqueued.',
      );
    }

    return byteCount < fullPacketBytes;
  }
}

class AudioSinkException implements Exception {
  final String message;
  const AudioSinkException(this.message);

  @override
  String toString() => 'AudioSinkException: $message';
}

class AudioSinkStats {
  final int submittedSamples;
  final int latencySamples;
  final int queuedSamples;
  final int sampleRate;
  final int channels;
  final bool healthy;
  final bool draining;

  const AudioSinkStats({
    required this.submittedSamples,
    required this.latencySamples,
    required this.queuedSamples,
    required this.sampleRate,
    required this.channels,
    required this.healthy,
    required this.draining,
  });
}

class NativeAudioSink {
  static const int defaultSampleRate = 48000;
  static const int defaultChannels = 2;
  static const int defaultLatencyMs = 50;
  static const int defaultQueueMs = 100;

  static bool get isSupported => Platform.isLinux;

  final _NativeAudioSinkBindings _native;
  late final Pointer<Void> _handle;
  late final PreviewPcmPacketContract _packetContract;
  late final int _packetBytes;
  bool _shortTailAccepted = false;
  bool _disposed = false;

  NativeAudioSink({
    String? device,
    int sampleRate = defaultSampleRate,
    int channels = defaultChannels,
    int latencyMs = defaultLatencyMs,
    int maxQueueMs = defaultQueueMs,
  }) : _native = _NativeAudioSinkBindings.open() {
    _packetContract = PreviewPcmPacketContract(
      sampleRate: sampleRate,
      channels: channels,
    );

    // Resolve the exact 10 ms packet size before native stream creation. This
    // throws if the duration cannot be represented by an integer PCM frame
    // count, so packet timing never depends on rounding or producer chunking.
    _packetBytes = _packetContract.bytesPerPacket;

    Pointer<Int8> devicePtr = nullptr;
    try {
      if (device != null && device.isNotEmpty) {
        devicePtr = _native.copyUtf8(device);
        if (devicePtr == nullptr) {
          throw const AudioSinkException(
            'Could not allocate the selected audio device name.',
          );
        }
      }
      _handle = _native.create(
        devicePtr,
        sampleRate,
        channels,
        latencyMs,
        maxQueueMs,
      );
    } finally {
      if (devicePtr != nullptr) _native.free(devicePtr.cast<Void>());
    }

    if (_handle == nullptr) {
      throw AudioSinkException(_native.createError());
    }
  }

  AudioSinkStats get stats {
    _checkAlive();
    final _NativeAudioSinkStats raw = _native.read(_handle).ref;
    return AudioSinkStats(
      submittedSamples: raw.submittedSamples,
      latencySamples: raw.latencySamples,
      queuedSamples: raw.queuedSamples,
      sampleRate: raw.sampleRate,
      channels: raw.channels,
      healthy: raw.healthy != 0,
      draining: raw.draining != 0,
    );
  }

  /// Attempts to copy one interleaved s16le PCM packet into the native queue.
  /// Full packets are exactly 10 ms. One shorter frame-aligned packet is
  /// allowed as the final EOF tail and must be followed by drain or flush.
  /// Returns false when the bounded queue is full. A false result is
  /// backpressure, not an error: the caller should pause the source stream and
  /// retry later instead of buffering an unbounded amount in Dart.
  bool tryEnqueue(Uint8List pcm) {
    _checkAlive();
    if (pcm.isEmpty) return true;

    final bool isShortTail = _packetContract.validatePacketByteCount(
      pcm.lengthInBytes,
      shortTailAlreadyAccepted: _shortTailAccepted,
    );
    assert(_packetBytes == _packetContract.bytesPerPacket);

    final Pointer<Uint8> buffer =
        _native.malloc(pcm.lengthInBytes).cast<Uint8>();
    if (buffer == nullptr) {
      throw const AudioSinkException('Native PCM allocation failed.');
    }

    try {
      buffer.asTypedList(pcm.lengthInBytes).setAll(0, pcm);
      final int result = _native.enqueue(_handle, buffer, pcm.lengthInBytes);
      if (result > 0) {
        if (isShortTail) _shortTailAccepted = true;
        return true;
      }
      if (result == 0) return false;
      throw AudioSinkException(lastError);
    } finally {
      _native.free(buffer.cast<Void>());
    }
  }

  /// Requests natural audible completion after all already accepted PCM. The
  /// worker performs the blocking drain and ProjectClock tail handoff; callers
  /// poll [stats].draining rather than blocking Flutter inside an FFI call.
  void requestDrain() {
    _checkAlive();
    if (_native.requestDrain(_handle) < 0) {
      throw AudioSinkException(lastError);
    }
    _shortTailAccepted = false;
  }

  /// Drops queued and server-buffered audio. The native ProjectClock sample
  /// counter remains cumulative, and active AUDIO authority is first reanchored
  /// onto the current audible ProjectTime.
  void flush() {
    _checkAlive();
    if (_native.flush(_handle) < 0) {
      throw AudioSinkException(lastError);
    }
    _shortTailAccepted = false;
  }

  String get lastError {
    _checkAlive();
    return _native.sinkError(_handle);
  }

  void _checkAlive() {
    if (_disposed) throw StateError('NativeAudioSink has been disposed.');
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _native.destroy(_handle);
  }
}

final class _NativeAudioSinkStats extends Struct {
  @Int64()
  external int submittedSamples;

  @Int64()
  external int latencySamples;

  @Int64()
  external int queuedSamples;

  @Int32()
  external int sampleRate;

  @Int32()
  external int channels;

  @Int32()
  external int healthy;

  @Int32()
  external int draining;

  @Int32()
  external int padding;
}

typedef _CreateNative = Pointer<Void> Function(
  Pointer<Int8> device,
  Int32 sampleRate,
  Int32 channels,
  Int32 latencyMs,
  Int32 maxQueueMs,
);
typedef _CreateDart = Pointer<Void> Function(
  Pointer<Int8> device,
  int sampleRate,
  int channels,
  int latencyMs,
  int maxQueueMs,
);
typedef _DestroyNative = Void Function(Pointer<Void> handle);
typedef _DestroyDart = void Function(Pointer<Void> handle);
typedef _EnqueueNative = Int32 Function(
  Pointer<Void> handle,
  Pointer<Uint8> data,
  Int64 byteCount,
);
typedef _EnqueueDart = int Function(
  Pointer<Void> handle,
  Pointer<Uint8> data,
  int byteCount,
);
typedef _SinkActionNative = Int32 Function(Pointer<Void> handle);
typedef _SinkActionDart = int Function(Pointer<Void> handle);
typedef _ReadNative = Pointer<_NativeAudioSinkStats> Function(
  Pointer<Void> handle,
);
typedef _ReadDart = Pointer<_NativeAudioSinkStats> Function(
  Pointer<Void> handle,
);
typedef _CopyErrorNative = Int32 Function(
  Pointer<Void> handle,
  Pointer<Int8> buffer,
  Int32 capacity,
);
typedef _CopyErrorDart = int Function(
  Pointer<Void> handle,
  Pointer<Int8> buffer,
  int capacity,
);
typedef _CopyCreateErrorNative = Int32 Function(
  Pointer<Int8> buffer,
  Int32 capacity,
);
typedef _CopyCreateErrorDart = int Function(
  Pointer<Int8> buffer,
  int capacity,
);
typedef _MallocNative = Pointer<Void> Function(IntPtr size);
typedef _MallocDart = Pointer<Void> Function(int size);
typedef _FreeNative = Void Function(Pointer<Void> pointer);
typedef _FreeDart = void Function(Pointer<Void> pointer);

class _NativeAudioSinkBindings {
  final DynamicLibrary _runner;
  final DynamicLibrary _libc;

  late final _CreateDart create = _runner.lookupFunction<_CreateNative,
      _CreateDart>('r3_audio_sink_create');
  late final _DestroyDart destroy = _runner.lookupFunction<_DestroyNative,
      _DestroyDart>('r3_audio_sink_destroy');
  late final _EnqueueDart enqueue = _runner.lookupFunction<_EnqueueNative,
      _EnqueueDart>('r3_audio_sink_enqueue');
  late final _SinkActionDart requestDrain = _runner.lookupFunction<
      _SinkActionNative,
      _SinkActionDart>('r3_audio_sink_request_drain');
  late final _SinkActionDart flush = _runner.lookupFunction<_SinkActionNative,
      _SinkActionDart>('r3_audio_sink_flush');
  late final _ReadDart read = _runner.lookupFunction<_ReadNative,
      _ReadDart>('r3_audio_sink_read');
  late final _CopyErrorDart copyLastError = _runner.lookupFunction<
      _CopyErrorNative, _CopyErrorDart>('r3_audio_sink_copy_last_error');
  late final _CopyCreateErrorDart copyCreateError = _runner.lookupFunction<
      _CopyCreateErrorNative,
      _CopyCreateErrorDart>('r3_audio_sink_copy_create_error');

  late final _MallocDart malloc =
      _libc.lookupFunction<_MallocNative, _MallocDart>('malloc');
  late final _FreeDart free =
      _libc.lookupFunction<_FreeNative, _FreeDart>('free');

  _NativeAudioSinkBindings._(this._runner, this._libc);

  factory _NativeAudioSinkBindings.open() {
    if (!Platform.isLinux) {
      throw UnsupportedError('NativeAudioSink is currently Linux-only.');
    }
    return _NativeAudioSinkBindings._(
      DynamicLibrary.process(),
      DynamicLibrary.open('libc.so.6'),
    );
  }

  Pointer<Int8> copyUtf8(String value) {
    final List<int> bytes = utf8.encode(value);
    final Pointer<Int8> out = malloc(bytes.length + 1).cast<Int8>();
    if (out == nullptr) return nullptr;
    final Uint8List target = out.cast<Uint8>().asTypedList(bytes.length + 1);
    target.setAll(0, bytes);
    target[bytes.length] = 0;
    return out;
  }

  String createError() => _readError((Pointer<Int8> buffer, int capacity) {
        return copyCreateError(buffer, capacity);
      });

  String sinkError(Pointer<Void> handle) =>
      _readError((Pointer<Int8> buffer, int capacity) {
        return copyLastError(handle, buffer, capacity);
      });

  String _readError(int Function(Pointer<Int8>, int) copy) {
    const int capacity = 1024;
    final Pointer<Int8> buffer = malloc(capacity).cast<Int8>();
    if (buffer == nullptr) return 'Unknown native audio sink error.';
    try {
      final int fullLength = copy(buffer, capacity);
      final int length = fullLength < capacity - 1 ? fullLength : capacity - 1;
      if (length <= 0) return 'Unknown native audio sink error.';
      return utf8.decode(buffer.cast<Uint8>().asTypedList(length));
    } finally {
      free(buffer.cast<Void>());
    }
  }
}
