// ./lib/edit_native_preview.dart
//
// Dart control surface for the native MLT EDIT preview texture.
//
// The Linux runner owns the external Flutter texture and MLT consumer. Dart
// only sends explicit transport commands. R3nder ProjectClock and canonical
// EDIT geometry remain authoritative; the native player is a display follower.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'edit_model.dart';
import 'project_clock.dart';

typedef _TextureIdNative = Int64 Function();
typedef _TextureIdDart = int Function();

typedef _OpenNative = Int32 Function(Pointer<Int8>, Int32, Int32);
typedef _OpenDart = int Function(Pointer<Int8>, int, int);

typedef _VoidNative = Void Function();
typedef _VoidDart = void Function();

typedef _FrameNative = Int32 Function(Int64);
typedef _FrameDart = int Function(int);

typedef _PlayNative = Int32 Function(
  Int64,
  Int64,
  Int64,
  Int64,
  Int64,
);
typedef _PlayDart = int Function(int, int, int, int, int);

typedef _PositionNative = Int64 Function();
typedef _PositionDart = int Function();

typedef _DoubleNative = Double Function();
typedef _DoubleDart = double Function();

typedef _IntNative = Int32 Function();
typedef _IntDart = int Function();

typedef _CopyErrorNative = Int32 Function(Pointer<Int8>, Int32);
typedef _CopyErrorDart = int Function(Pointer<Int8>, int);

typedef _MallocNative = Pointer<Void> Function(IntPtr);
typedef _MallocDart = Pointer<Void> Function(int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);

class NativeEditPreview {
  final DynamicLibrary _runner;
  final DynamicLibrary _libc;

  late final _TextureIdDart _textureId;
  late final _OpenDart _open;
  late final _VoidDart _close;
  late final _FrameDart _seekFrame;
  late final _PlayDart _playFrom;
  late final _FrameDart _pauseAt;
  late final _PositionDart _positionFrame;
  late final _DoubleDart _sourceFps;
  late final _IntDart _isPlaying;
  late final _CopyErrorDart _copyLastError;
  late final _MallocDart _malloc;
  late final _FreeDart _free;

  NativeEditPreview()
      : _runner = DynamicLibrary.process(),
        _libc = DynamicLibrary.open('libc.so.6') {
    if (!Platform.isLinux) {
      throw UnsupportedError('Native EDIT preview is currently Linux only.');
    }

    _textureId = _runner.lookupFunction<_TextureIdNative, _TextureIdDart>(
      'r3_edit_preview_texture_id',
    );
    _open = _runner.lookupFunction<_OpenNative, _OpenDart>(
      'r3_edit_preview_open',
    );
    _close = _runner.lookupFunction<_VoidNative, _VoidDart>(
      'r3_edit_preview_close',
    );
    _seekFrame = _runner.lookupFunction<_FrameNative, _FrameDart>(
      'r3_edit_preview_seek_frame',
    );
    _playFrom = _runner.lookupFunction<_PlayNative, _PlayDart>(
      'r3_edit_preview_play_from',
    );
    _pauseAt = _runner.lookupFunction<_FrameNative, _FrameDart>(
      'r3_edit_preview_pause_at',
    );
    _positionFrame = _runner.lookupFunction<_PositionNative, _PositionDart>(
      'r3_edit_preview_position_frame',
    );
    _sourceFps = _runner.lookupFunction<_DoubleNative, _DoubleDart>(
      'r3_edit_preview_source_fps',
    );
    _isPlaying = _runner.lookupFunction<_IntNative, _IntDart>(
      'r3_edit_preview_is_playing',
    );
    _copyLastError = _runner.lookupFunction<_CopyErrorNative, _CopyErrorDart>(
      'r3_edit_preview_copy_last_error',
    );
    _malloc = _libc.lookupFunction<_MallocNative, _MallocDart>('malloc');
    _free = _libc.lookupFunction<_FreeNative, _FreeDart>('free');
  }

  static bool get isSupported => Platform.isLinux;

  int get textureId => _textureId();
  int get positionFrame => _positionFrame();
  double get sourceFps => _sourceFps();
  bool get isPlaying => _isPlaying() != 0;

  bool open(String resolvedPath) {
    final Pointer<Int8> path = _copyUtf8(resolvedPath);
    if (path == nullptr) return false;
    try {
      // Zero dimensions tell the bridge to use the source-derived MLT profile,
      // matching the proven MLT Player preview path.
      return _open(path, 0, 0) != 0;
    } finally {
      _free(path.cast<Void>());
    }
  }

  void close() => _close();

  bool seekFrame(int sourceFrame) => _seekFrame(sourceFrame) != 0;

  bool playFrom({
    required int sourceFrame,
    required RationalFrameRate projectRate,
    required ExactClipSpeed clipSpeed,
  }) {
    return _playFrom(
          sourceFrame,
          projectRate.numerator,
          projectRate.denominator,
          clipSpeed.numerator,
          clipSpeed.denominator,
        ) !=
        0;
  }

  bool pauseAt(int sourceFrame) => _pauseAt(sourceFrame) != 0;

  String get lastError {
    final int required = _copyLastError(nullptr, 0);
    if (required <= 1) return '';
    final Pointer<Int8> buffer = _malloc(required).cast<Int8>();
    if (buffer == nullptr) return 'Could not allocate native error buffer.';
    try {
      _copyLastError(buffer, required);
      final Uint8List bytes = buffer.cast<Uint8>().asTypedList(required);
      int length = 0;
      while (length < bytes.length && bytes[length] != 0) {
        length++;
      }
      return utf8.decode(bytes.sublist(0, length), allowMalformed: true);
    } finally {
      _free(buffer.cast<Void>());
    }
  }

  Pointer<Int8> _copyUtf8(String value) {
    final List<int> bytes = utf8.encode(value);
    final Pointer<Uint8> out = _malloc(bytes.length + 1).cast<Uint8>();
    if (out == nullptr) return nullptr.cast<Int8>();
    final Uint8List target = out.asTypedList(bytes.length + 1);
    target.setAll(0, bytes);
    target[bytes.length] = 0;
    return out.cast<Int8>();
  }
}
