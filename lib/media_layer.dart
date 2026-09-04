// ./lib/media_layer.dart
//
// Reentrant project-time to media-frame layer.
//
// The structural source model owns clip geometry. ProjectTime owns the
// playhead. MLT owns only persistent leaf-media decoders. Exact parked-frame
// work may wait for decode, while live preview publishes targets to native
// workers and polls completed frames without blocking Dart. EDIT and MOSAIC
// references are never opened as files; they are returned as structural
// placeholders for the compositor to resolve recursively.
// No decoder advances project time or decides project duration.

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
  nestedMosaicPending,
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
      error: 'Nested EDIT source requires compositor resolution.',
    );
  }

  factory MediaFrame.nestedMosaicPending({
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
      status: MediaFrameStatus.nestedMosaicPending,
      error: 'Nested MOSAIC source requires compositor resolution.',
    );
  }

  bool get isDecoded => status == MediaFrameStatus.decoded;
  bool get isPending => status == MediaFrameStatus.pending;
  bool get isStructuralPending =>
      status == MediaFrameStatus.nestedEditPending ||
      status == MediaFrameStatus.nestedMosaicPending;
}

class MediaRenderResult {
  /// Owner id for this clip evaluation. Existing EDIT callers use the edit id;
  /// pane callers use the containing MOSAIC id. Kept as editId for API
  /// compatibility with the M10 surface.
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

/// Optional zero-Dart-pixel presentation capability. The decoder remains the
/// same persistent MLT worker used by request/poll; this only changes where its
/// exact target frame is delivered.
abstract interface class TextureMediaDecoder implements NonBlockingMediaDecoder {
  int get textureId;
  void presentTexture(int requestedSourceFrame, int width, int height);
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

  /// Exact EDIT render path used for parked frames, deterministic tests, and
  /// export-style work.
  MediaRenderResult render(String editId, ProjectTime time, ui.Size size) {
    final EditSequence edit = editDocument.edit(editId);
    return _renderLanes(
      ownerId: editId,
      lanes: <_MediaLane>[
        for (final EditTrack track in edit.tracks)
          _MediaLane(track.id, track.clips),
      ],
      time: time,
      size: size,
      nonBlocking: false,
    );
  }

  /// Nonblocking EDIT preview path.
  MediaRenderResult renderAvailable(
    String editId,
    ProjectTime time,
    ui.Size size,
  ) {
    final EditSequence edit = editDocument.edit(editId);
    return _renderLanes(
      ownerId: editId,
      lanes: <_MediaLane>[
        for (final EditTrack track in edit.tracks)
          _MediaLane(track.id, track.clips),
      ],
      time: time,
      size: size,
      nonBlocking: true,
    );
  }

  /// Exact evaluation of one MOSAIC pane. A pane is a timeline lane whose
  /// visual rectangle is owned by the compositor, so the media layer only
  /// needs its requested pixel size and authored project time.
  MediaRenderResult renderPane(
    String mosaicId,
    String paneId,
    ProjectTime time,
    ui.Size size,
  ) {
    final MosaicPane pane = editDocument.mosaic(mosaicId).pane(paneId);
    return _renderLanes(
      ownerId: mosaicId,
      lanes: <_MediaLane>[_MediaLane(pane.id, pane.clips)],
      time: time,
      size: size,
      nonBlocking: false,
    );
  }

  /// Nonblocking evaluation of one MOSAIC pane.
  MediaRenderResult renderPaneAvailable(
    String mosaicId,
    String paneId,
    ProjectTime time,
    ui.Size size,
  ) {
    final MosaicPane pane = editDocument.mosaic(mosaicId).pane(paneId);
    return _renderLanes(
      ownerId: mosaicId,
      lanes: <_MediaLane>[_MediaLane(pane.id, pane.clips)],
      time: time,
      size: size,
      nonBlocking: true,
    );
  }

  /// Hands one leaf-media source-frame target to the Linux external texture
  /// while reusing the exact same decoder object cached by normal render paths.
  /// Structural sources always return null because they must be composited.
  int? presentNativeTexture({
    required String source,
    required int requestedSourceFrame,
    required int width,
    required int height,
  }) {
    _checkAlive();
    if (StructuralSourceRef.tryParse(source) != null) return null;
    if (requestedSourceFrame < 0 || width <= 0 || height <= 0) {
      throw ArgumentError('Native texture media request is invalid.');
    }

    final String resolved = resolveSource(source);
    final MediaDecoder decoder =
        _decoders.putIfAbsent(resolved, () => backend.open(resolved));
    if (decoder is! TextureMediaDecoder) return null;

    final int id = decoder.textureId;
    if (id <= 0) return null;
    decoder.presentTexture(requestedSourceFrame, width, height);
    return id;
  }

  MediaRenderResult _renderLanes({
    required String ownerId,
    required List<_MediaLane> lanes,
    required ProjectTime time,
    required ui.Size size,
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

    final List<MediaFrame> result = <MediaFrame>[];

    for (final _MediaLane lane in lanes) {
      for (final EditClip clip in lane.clips) {
        if (time.frame < clip.atFrame || time.frame >= clip.endFrameExclusive) {
          continue;
        }

        final int projectOffset = time.frame - clip.atFrame;
        final int requestedSourceFrame =
            clip.sourceFrameAtProjectOffset(projectOffset);
        final StructuralSourceRef? structural =
            StructuralSourceRef.tryParse(clip.source);

        if (structural != null) {
          if (structural.kind == StructuralSourceKind.edit) {
            result.add(
              MediaFrame.nestedEditPending(
                trackId: lane.id,
                clipId: clip.id,
                source: clip.source,
                requestedSourceFrame: requestedSourceFrame,
              ),
            );
          } else {
            result.add(
              MediaFrame.nestedMosaicPending(
                trackId: lane.id,
                clipId: clip.id,
                source: clip.source,
                requestedSourceFrame: requestedSourceFrame,
              ),
            );
          }
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
                  trackId: lane.id,
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
              trackId: lane.id,
              clipId: clip.id,
              source: clip.source,
              decoded: decoded,
            ),
          );
        } on MediaDecodeException catch (error) {
          result.add(
            MediaFrame.offline(
              trackId: lane.id,
              clipId: clip.id,
              source: clip.source,
              requestedSourceFrame: requestedSourceFrame,
              error: error.message,
            ),
          );
        } on FileSystemException catch (error) {
          result.add(
            MediaFrame.offline(
              trackId: lane.id,
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
      editId: ownerId,
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

class _MediaLane {
  final String id;
  final List<EditClip> clips;

  const _MediaLane(this.id, this.clips);
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

class _NativeMltMediaDecoder implements TextureMediaDecoder {
  final _NativeMediaBindings _native;
  Pointer<Void> _handle;
  bool _disposed = false;

  _NativeMltMediaDecoder(this._native, this._handle);

  @override
  int get textureId {
    _checkAlive();
    return _native.textureId();
  }

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

  @override
  void presentTexture(int requestedSourceFrame, int width, int height) {
    _checkRequest(requestedSourceFrame, width, height);
    if (_native.textureId() <= 0) {
      throw const MediaDecodeException(
        'Flutter media texture is not registered yet.',
      );
    }
    final int status =
        _native.textureRequest(_handle, requestedSourceFrame, width, height);
    if (status != 0) {
      throw MediaDecodeException(_native.decoderError(_handle));
    }
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
    _native.textureDetach(_handle);
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

typedef _TextureIdNative = Int64 Function();
typedef _TextureIdDart = int Function();
typedef _TextureDetachNative = Void Function(Pointer<Void> handle);
typedef _TextureDetachDart = void Function(Pointer<Void> handle);

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

  late final _CreateDart create =
      _runner.lookupFunction<_CreateNative, _CreateDart>(
    'r3_media_decoder_create',
  );
  late final _DestroyDart destroy =
      _runner.lookupFunction<_DestroyNative, _DestroyDart>(
    'r3_media_decoder_destroy',
  );
  late final _RenderDart render =
      _runner.lookupFunction<_RenderNative, _RenderDart>(
    'r3_media_decoder_render',
  );
  late final _RequestDart request =
      _runner.lookupFunction<_RequestNative, _RequestDart>(
    'r3_media_decoder_request',
  );
  late final _RenderDart poll =
      _runner.lookupFunction<_RenderNative, _RenderDart>(
    'r3_media_decoder_poll',
  );
  late final _TextureIdDart textureId =
      _runner.lookupFunction<_TextureIdNative, _TextureIdDart>(
    'r3_media_texture_id',
  );
  late final _RequestDart textureRequest =
      _runner.lookupFunction<_RequestNative, _RequestDart>(
    'r3_media_texture_request',
  );
  late final _TextureDetachDart textureDetach =
      _runner.lookupFunction<_TextureDetachNative, _TextureDetachDart>(
    'r3_media_texture_detach_decoder',
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
