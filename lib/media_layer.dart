// ./lib/media_layer.dart
//
// Reentrant project-time to media-frame layer.
//
// The edit model owns clip geometry. ProjectTime owns the playhead. MLT owns
// only persistent source decoders. Exact parked-frame work may wait for decode,
// while live preview publishes targets to native workers and polls completed
// frames without blocking Dart. No decoder advances project time or decides
// project duration.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'edit_model.dart';
import 'project_clock.dart';

enum MediaFrameStatus {
  decoded,
  pending,
  offline,
  nestedEditPending,
}

class MediaFrame {
  final String trackId;
  final String clipId;
  final String source;
  final int requestedSourceFrame;
  final int? actualSourceFrame;
  final int width;
  final int height;
  final int stride;
  final Uint8List? rgba;
  final MediaFrameStatus status;
  final String? error;

  const MediaFrame._({
    required this.trackId,
    required this.clipId,
    required this.source,
    required this.requestedSourceFrame,
    required this.actualSourceFrame,
    required this.width,
    required this.height,
    required this.stride,
    required this.rgba,
    required this.status,
    required this.error,
  });

  factory MediaFrame.decoded({
    required String trackId,
    required String clipId,
    required String source,
    required DecodedMediaFrame decoded,
  }) {
    return MediaFrame._(
      trackId: trackId,
      clipId: clipId,
      source: source,
      requestedSourceFrame: decoded.requestedSourceFrame,
      actualSourceFrame: decoded.actualSourceFrame,
      width: decoded.width,
      height: decoded.height,
      stride: decoded.stride,
      rgba: decoded.rgba,
      status: MediaFrameStatus.decoded,
      error: null,
    );
  }

  factory MediaFrame.pending({
    required String trackId,
    required String clipId,
    required String source,
    required int requestedSourceFrame,
  }) {
    return MediaFrame._(
      trackId: trackId,
      clipId: clipId,
      source: source,
      requestedSourceFrame: requestedSourceFrame,
      actualSourceFrame: null,
      width: 0,
      height: 0,
      stride: 0,
      rgba: null,
      status: MediaFrameStatus.pending,
      error: null,
    );
  }

  factory MediaFrame.offline({
    required String trackId,
    required String clipId,
    required String source,
    required int requestedSourceFrame,
    required String error,
  }) {
    return MediaFrame._(
      trackId: trackId,
      clipId: clipId,
      source: source,
      requestedSourceFrame: requestedSourceFrame,
      actualSourceFrame: null,
      width: 0,
      height: 0,
      stride: 0,
      rgba: null,
      status: MediaFrameStatus.offline,
      error: error,
    );
  }

  factory MediaFrame.nestedEditPending({
    required String trackId,
    required String clipId,
    required String source,
    required int requestedSourceFrame,
  }) {
    return MediaFrame._(
      trackId: trackId,
      clipId: clipId,
      source: source,
      requestedSourceFrame: requestedSourceFrame,
      actualSourceFrame: null,
      width: 0,
      height: 0,
      stride: 0,
      rgba: null,
      status: MediaFrameStatus.nestedEditPending,
      error: 'Nested EDIT sources are reserved for M11.',
    );
  }

  bool get isDecoded => status == MediaFrameStatus.decoded;
  bool get isPending => status == MediaFrameStatus.pending;
}

class MediaRenderResult {
  final String editId;
  final ProjectTime projectTime;
  final ui.Size outputSize;
  final List<MediaFrame> frames;

  const MediaRenderResult({
    required this.editId,
    required this.projectTime,
    required this.outputSize,
    required this.frames,
  });

  bool get hasPending => frames.any((MediaFrame frame) => frame.isPending);

  /// A decoded result may become the current composite only while the seek
  /// epoch and exact requested project position still match. Decoder objects
  /// and their read-ahead caches are deliberately not discarded when this
  /// returns false.
  bool canPresentAgainst(ProjectTime current) {
    return projectTime.epoch == current.epoch &&
        projectTime.frame == current.frame &&
        projectTime.phaseNumerator == current.phaseNumerator &&
        projectTime.phaseDenominator == current.phaseDenominator;
  }
}

class DecodedMediaFrame {
  final int requestedSourceFrame;
  final int actualSourceFrame;
  final int width;
  final int height;
  final int stride;
  final Uint8List rgba;

  const DecodedMediaFrame({
    required this.requestedSourceFrame,
    required this.actualSourceFrame,
    required this.width,
    required this.height,
    required this.stride,
    required this.rgba,
  });
}

class MediaDecodeException implements Exception {
  final String message;

  const MediaDecodeException(this.message);

  @override
  String toString() => 'MediaDecodeException: $message';
}

abstract interface class MediaDecoder {
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height);
  void dispose();
}

/// Optional live-preview capability. Native MLT decoders implement this; test
/// fakes and alternate backends can remain synchronous and need only implement
/// [MediaDecoder].
abstract interface class NonBlockingMediaDecoder implements MediaDecoder {
  void request(int requestedSourceFrame, int width, int height);
  DecodedMediaFrame? poll(int requestedSourceFrame, int width, int height);
}

abstract interface class MediaDecoderBackend {
  MediaDecoder open(String resolvedPath);
}

class MediaLayer {
  final EditDocumentModel editDocument;
  final MediaDecoderBackend backend;
  final String Function(String source) resolveSource;

  final Map<String, MediaDecoder> _decoders = <String, MediaDecoder>{};
  bool _disposed = false;

  MediaLayer({
    required this.editDocument,
    required this.backend,
    required this.resolveSource,
  });

  factory MediaLayer.native({
    required EditDocumentModel editDocument,
    required String Function(String source) resolveSource,
  }) {
    return MediaLayer(
      editDocument: editDocument,
      backend: NativeMltMediaBackend(),
      resolveSource: resolveSource,
    );
  }

  /// Exact render path used for parked frames, deterministic tests, and export
  /// style work. A native decoder may wait for its worker here, but the source
  /// frame returned is exact.
  MediaRenderResult render(String editId, ProjectTime time, ui.Size size) {
    return _render(editId, time, size, nonBlocking: false);
  }

  /// Live preview path. Native decoders only publish the newest source target
  /// and poll their read-ahead ring. When an exact requested frame is not ready
  /// yet, the result carries [MediaFrameStatus.pending] instead of blocking the
  /// caller. Synchronous test/alternate decoders keep their existing behavior.
  MediaRenderResult renderAvailable(
    String editId,
    ProjectTime time,
    ui.Size size,
  ) {
    return _render(editId, time, size, nonBlocking: true);
  }

  MediaRenderResult _render(
    String editId,
    ProjectTime time,
    ui.Size size, {
    required bool nonBlocking,
  }) {
    _checkAlive();
    final int width = size.width.round();
    final int height = size.height.round();
    if (!size.width.isFinite ||
        !size.height.isFinite ||
        width <= 0 ||
        height <= 0) {
      throw ArgumentError.value(
        size,
        'size',
        'Media render size must be positive.',
      );
    }

    final EditSequence edit = editDocument.edit(editId);
    final List<MediaFrame> result = <MediaFrame>[];

    for (final EditTrack track in edit.tracks) {
      for (final EditClip clip in track.clips) {
        if (time.frame < clip.atFrame || time.frame >= clip.endFrameExclusive) {
          continue;
        }

        final int projectOffset = time.frame - clip.atFrame;
        final int requestedSourceFrame =
            clip.sourceFrameAtProjectOffset(projectOffset);

        if (clip.source.startsWith('EDIT.')) {
          result.add(
            MediaFrame.nestedEditPending(
              trackId: track.id,
              clipId: clip.id,
              source: clip.source,
              requestedSourceFrame: requestedSourceFrame,
            ),
          );
          continue;
        }

        try {
          final String resolved = resolveSource(clip.source);
          final MediaDecoder decoder =
              _decoders.putIfAbsent(resolved, () => backend.open(resolved));

          DecodedMediaFrame? decoded;
          if (nonBlocking && decoder is NonBlockingMediaDecoder) {
            decoder.request(requestedSourceFrame, width, height);
            decoded = decoder.poll(requestedSourceFrame, width, height);
            if (decoded == null) {
              result.add(
                MediaFrame.pending(
                  trackId: track.id,
                  clipId: clip.id,
                  source: clip.source,
                  requestedSourceFrame: requestedSourceFrame,
                ),
              );
              continue;
            }
          } else {
            decoded = decoder.render(requestedSourceFrame, width, height);
          }

          result.add(
            MediaFrame.decoded(
              trackId: track.id,
              clipId: clip.id,
              source: clip.source,
              decoded: decoded,
            ),
          );
        } on MediaDecodeException catch (error) {
          result.add(
            MediaFrame.offline(
              trackId: track.id,
              clipId: clip.id,
              source: clip.source,
              requestedSourceFrame: requestedSourceFrame,
              error: error.message,
            ),
          );
        } on FileSystemException catch (error) {
          result.add(
            MediaFrame.offline(
              trackId: track.id,
              clipId: clip.id,
              source: clip.source,
              requestedSourceFrame: requestedSourceFrame,
              error: error.message,
            ),
          );
        }
      }
    }

    return MediaRenderResult(
      editId: editId,
      projectTime: time,
      outputSize: size,
      frames: List<MediaFrame>.unmodifiable(result),
    );
  }

  int get cachedDecoderCount => _decoders.length;

  void _checkAlive() {
    if (_disposed) throw StateError('MediaLayer has been disposed.');
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final MediaDecoder decoder in _decoders.values) {
      decoder.dispose();
    }
    _decoders.clear();
  }
}

class NativeMltMediaBackend implements MediaDecoderBackend {
  final _NativeMediaBindings _native;

  NativeMltMediaBackend() : _native = _NativeMediaBindings.open();

  static bool get isSupported => Platform.isLinux;

  @override
  MediaDecoder open(String resolvedPath) {
    final Pointer<Int8> path = _native.copyUtf8(resolvedPath);
    if (path == nullptr) {
      throw const MediaDecodeException('Could not allocate native media path.');
    }

    try {
      final Pointer<Void> handle = _native.create(path);
      if (handle == nullptr) {
        throw MediaDecodeException(_native.createError());
      }
      return _NativeMltMediaDecoder(_native, handle);
    } finally {
      _native.free(path.cast<Void>());
    }
  }
}

class _NativeMltMediaDecoder implements NonBlockingMediaDecoder {
  final _NativeMediaBindings _native;
  Pointer<Void> _handle;
  bool _disposed = false;

  _NativeMltMediaDecoder(this._native, this._handle);

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    _checkRequest(requestedSourceFrame, width, height);
    return _readNativeFrame(
      requestedSourceFrame,
      width,
      height,
      (Pointer<_NativeMediaDecodedFrame> result) {
        final int status =
            _native.render(_handle, requestedSourceFrame, width, height, result);
        if (status != 0) {
          throw MediaDecodeException(_native.decoderError(_handle));
        }
        return true;
      },
    )!;
  }

  @override
  void request(int requestedSourceFrame, int width, int height) {
    _checkRequest(requestedSourceFrame, width, height);
    final int status =
        _native.request(_handle, requestedSourceFrame, width, height);
    if (status != 0) {
      throw MediaDecodeException(_native.decoderError(_handle));
    }
  }

  @override
  DecodedMediaFrame? poll(
    int requestedSourceFrame,
    int width,
    int height,
  ) {
    _checkRequest(requestedSourceFrame, width, height);
    return _readNativeFrame(
      requestedSourceFrame,
      width,
      height,
      (Pointer<_NativeMediaDecodedFrame> result) {
        final int status =
            _native.poll(_handle, requestedSourceFrame, width, height, result);
        if (status < 0) {
          throw MediaDecodeException(_native.decoderError(_handle));
        }
        return status == 1;
      },
    );
  }

  DecodedMediaFrame? _readNativeFrame(
    int requestedSourceFrame,
    int width,
    int height,
    bool Function(Pointer<_NativeMediaDecodedFrame> result) invoke,
  ) {
    final Pointer<_NativeMediaDecodedFrame> result = _native
        .malloc(sizeOf<_NativeMediaDecodedFrame>())
        .cast<_NativeMediaDecodedFrame>();
    if (result == nullptr) {
      throw const MediaDecodeException('Could not allocate native frame result.');
    }

    try {
      if (!invoke(result)) return null;

      final _NativeMediaDecodedFrame raw = result.ref;
      if (raw.rgba == nullptr || raw.byteLength <= 0) {
        throw const MediaDecodeException('Native decoder returned an empty frame.');
      }

      final Uint8List pixels = Uint8List.fromList(
        raw.rgba.asTypedList(raw.byteLength),
      );
      return DecodedMediaFrame(
        requestedSourceFrame: raw.requestedFrame,
        actualSourceFrame: raw.actualFrame,
        width: raw.width,
        height: raw.height,
        stride: raw.stride,
        rgba: pixels,
      );
    } finally {
      _native.releaseFrame(result);
      _native.free(result.cast<Void>());
    }
  }

  void _checkRequest(int requestedSourceFrame, int width, int height) {
    _checkAlive();
    if (requestedSourceFrame < 0) {
      throw RangeError.value(requestedSourceFrame, 'requestedSourceFrame');
    }
    if (width <= 0 || height <= 0) {
      throw ArgumentError('Native media output size must be positive.');
    }
  }

  void _checkAlive() {
    if (_disposed || _handle == nullptr) {
      throw StateError('Native MLT media decoder has been disposed.');
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _native.destroy(_handle);
    _handle = nullptr;
  }
}

final class _NativeMediaDecodedFrame extends Struct {
  @Int64()
  external int requestedFrame;

  @Int64()
  external int actualFrame;

  @Int32()
  external int width;

  @Int32()
  external int height;

  @Int32()
  external int stride;

  @Int32()
  external int reserved;

  @Int64()
  external int byteLength;

  external Pointer<Uint8> rgba;
}

typedef _CreateNative = Pointer<Void> Function(Pointer<Int8> path);
typedef _CreateDart = Pointer<Void> Function(Pointer<Int8> path);
typedef _DestroyNative = Void Function(Pointer<Void> handle);
typedef _DestroyDart = void Function(Pointer<Void> handle);

typedef _RenderNative = Int32 Function(
  Pointer<Void> handle,
  Int64 requestedFrame,
  Int32 width,
  Int32 height,
  Pointer<_NativeMediaDecodedFrame> result,
);
typedef _RenderDart = int Function(
  Pointer<Void> handle,
  int requestedFrame,
  int width,
  int height,
  Pointer<_NativeMediaDecodedFrame> result,
);

typedef _RequestNative = Int32 Function(
  Pointer<Void> handle,
  Int64 requestedFrame,
  Int32 width,
  Int32 height,
);
typedef _RequestDart = int Function(
  Pointer<Void> handle,
  int requestedFrame,
  int width,
  int height,
);

typedef _ReleaseFrameNative = Void Function(
  Pointer<_NativeMediaDecodedFrame> frame,
);
typedef _ReleaseFrameDart = void Function(
  Pointer<_NativeMediaDecodedFrame> frame,
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
typedef _CopyCreateErrorDart = int Function(Pointer<Int8> buffer, int capacity);
typedef _MallocNative = Pointer<Void> Function(IntPtr size);
typedef _MallocDart = Pointer<Void> Function(int size);
typedef _FreeNative = Void Function(Pointer<Void> pointer);
typedef _FreeDart = void Function(Pointer<Void> pointer);

class _NativeMediaBindings {
  final DynamicLibrary _runner;
  final DynamicLibrary _libc;

  late final _CreateDart create = _runner.lookupFunction<_CreateNative, _CreateDart>(
    'r3_media_decoder_create',
  );
  late final _DestroyDart destroy =
      _runner.lookupFunction<_DestroyNative, _DestroyDart>(
    'r3_media_decoder_destroy',
  );
  late final _RenderDart render = _runner.lookupFunction<_RenderNative, _RenderDart>(
    'r3_media_decoder_render',
  );
  late final _RequestDart request =
      _runner.lookupFunction<_RequestNative, _RequestDart>(
    'r3_media_decoder_request',
  );
  late final _RenderDart poll = _runner.lookupFunction<_RenderNative, _RenderDart>(
    'r3_media_decoder_poll',
  );
  late final _ReleaseFrameDart releaseFrame = _runner.lookupFunction<
      _ReleaseFrameNative,
      _ReleaseFrameDart>('r3_media_decoded_frame_release');
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

  _NativeMediaBindings._(this._runner, this._libc);

  factory _NativeMediaBindings.open() {
    if (!Platform.isLinux) {
      throw UnsupportedError('Native MLT media decoding is currently Linux-only.');
    }
    return _NativeMediaBindings._(
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
    if (buffer == nullptr) return 'Unknown native media decoder error.';
    try {
      final int fullLength = copy(buffer, capacity);
      final int length = fullLength < capacity - 1 ? fullLength : capacity - 1;
      if (length <= 0) return 'Unknown native media decoder error.';
      return utf8.decode(buffer.cast<Uint8>().asTypedList(length));
    } finally {
      free(buffer.cast<Void>());
    }
  }
}
