// ./lib/native_media_probe.dart
//
// Read-only source metadata probe backed by the same persistent MLT bridge
// used for EDIT preview decoding.
//
// The returned value is source length in source-native frames. Import code may
// use it to author an initial CLIP duration, but once that duration is written
// the script remains canonical and media replacement cannot silently change it.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

class NativeMediaProbeException implements Exception {
  final String message;

  const NativeMediaProbeException(this.message);

  @override
  String toString() => 'NativeMediaProbeException: $message';
}

class NativeMltMediaProbe {
  final _NativeProbeBindings _native;

  NativeMltMediaProbe() : _native = _NativeProbeBindings.open();

  int sourceLengthFrames(String resolvedPath) {
    if (resolvedPath.trim().isEmpty) {
      throw const NativeMediaProbeException('Media path is empty.');
    }

    final Pointer<Int8> path = _native.copyUtf8(resolvedPath);
    if (path == nullptr) {
      throw const NativeMediaProbeException('Could not allocate media path.');
    }

    Pointer<Void> handle = nullptr;
    try {
      handle = _native.create(path);
      if (handle == nullptr) {
        throw NativeMediaProbeException(_native.createError());
      }

      final int length = _native.length(handle);
      if (length <= 0) {
        throw NativeMediaProbeException(_native.decoderError(handle));
      }
      return length;
    } finally {
      if (handle != nullptr) _native.destroy(handle);
      _native.free(path.cast<Void>());
    }
  }
}

typedef _CreateNative = Pointer<Void> Function(Pointer<Int8> path);
typedef _CreateDart = Pointer<Void> Function(Pointer<Int8> path);
typedef _DestroyNative = Void Function(Pointer<Void> handle);
typedef _DestroyDart = void Function(Pointer<Void> handle);
typedef _LengthNative = Int64 Function(Pointer<Void> handle);
typedef _LengthDart = int Function(Pointer<Void> handle);
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
typedef _CopyCreateErrorDart = int Function(Pointer<Int8> buffer, int capacity);
typedef _MallocNative = Pointer<Void> Function(IntPtr size);
typedef _MallocDart = Pointer<Void> Function(int size);
typedef _FreeNative = Void Function(Pointer<Void> pointer);
typedef _FreeDart = void Function(Pointer<Void> pointer);

class _NativeProbeBindings {
  final DynamicLibrary _runner;
  final DynamicLibrary _libc;

  late final _CreateDart create = _runner.lookupFunction<_CreateNative, _CreateDart>(
    'r3_media_decoder_create',
  );
  late final _DestroyDart destroy =
      _runner.lookupFunction<_DestroyNative, _DestroyDart>(
    'r3_media_decoder_destroy',
  );
  late final _LengthDart length =
      _runner.lookupFunction<_LengthNative, _LengthDart>(
    'r3_media_decoder_length',
  );
  late final _CopyErrorDart copyLastError = _runner.lookupFunction<
      _CopyErrorNative,
      _CopyErrorDart>('r3_media_decoder_copy_last_error');
  late final _CopyCreateErrorDart copyCreateError = _runner.lookupFunction<
      _CopyCreateErrorNative,
      _CopyCreateErrorDart>('r3_media_decoder_copy_create_error');
  late final _MallocDart malloc =
      _libc.lookupFunction<_MallocNative, _MallocDart>('malloc');
  late final _FreeDart free =
      _libc.lookupFunction<_FreeNative, _FreeDart>('free');

  _NativeProbeBindings._(this._runner, this._libc);

  factory _NativeProbeBindings.open() {
    if (!Platform.isLinux) {
      throw UnsupportedError('Native MLT media probing is currently Linux-only.');
    }
    return _NativeProbeBindings._(
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

  String decoderError(Pointer<Void> handle) =>
      _readError((Pointer<Int8> buffer, int capacity) {
        return copyLastError(handle, buffer, capacity);
      });

  String _readError(int Function(Pointer<Int8>, int) copy) {
    const int capacity = 1024;
    final Pointer<Int8> buffer = malloc(capacity).cast<Int8>();
    if (buffer == nullptr) return 'Unknown native media probe error.';
    try {
      final int fullLength = copy(buffer, capacity);
      final int length = fullLength < capacity - 1 ? fullLength : capacity - 1;
      if (length <= 0) return 'Unknown native media probe error.';
      return utf8.decode(buffer.cast<Uint8>().asTypedList(length));
    } finally {
      free(buffer.cast<Void>());
    }
  }
}
