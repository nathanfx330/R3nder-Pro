// ./test/structural_source_export_native_test.dart

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/exporter.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/structural_source_export.dart';

final class _NativeDecodedFrame extends Struct {
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
  Pointer<_NativeDecodedFrame> result,
);
typedef _RenderDart = int Function(
  Pointer<Void> handle,
  int requestedFrame,
  int width,
  int height,
  Pointer<_NativeDecodedFrame> result,
);
typedef _ReleaseNative = Void Function(Pointer<_NativeDecodedFrame> frame);
typedef _ReleaseDart = void Function(Pointer<_NativeDecodedFrame> frame);
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

class _ProbeNativeBackend implements MediaDecoderBackend {
  final DynamicLibrary _library;
  final DynamicLibrary _libc = DynamicLibrary.open('libc.so.6');

  late final _CreateDart _create =
      _library.lookupFunction<_CreateNative, _CreateDart>(
    'r3_media_decoder_create',
  );
  late final _DestroyDart _destroy =
      _library.lookupFunction<_DestroyNative, _DestroyDart>(
    'r3_media_decoder_destroy',
  );
  late final _RenderDart _render =
      _library.lookupFunction<_RenderNative, _RenderDart>(
    'r3_media_decoder_render',
  );
  late final _ReleaseDart _release =
      _library.lookupFunction<_ReleaseNative, _ReleaseDart>(
    'r3_media_decoded_frame_release',
  );
  late final _CopyErrorDart _copyError =
      _library.lookupFunction<_CopyErrorNative, _CopyErrorDart>(
    'r3_media_decoder_copy_last_error',
  );
  late final _CopyCreateErrorDart _copyCreateError =
      _library.lookupFunction<_CopyCreateErrorNative, _CopyCreateErrorDart>(
    'r3_media_decoder_copy_create_error',
  );
  late final _MallocDart _malloc =
      _libc.lookupFunction<_MallocNative, _MallocDart>('malloc');
  late final _FreeDart _free =
      _libc.lookupFunction<_FreeNative, _FreeDart>('free');

  _ProbeNativeBackend(String libraryPath)
      : _library = DynamicLibrary.open(libraryPath);

  @override
  MediaDecoder open(String resolvedPath) {
    final Pointer<Int8> path = _copyUtf8(resolvedPath);
    if (path == nullptr) {
      throw const MediaDecodeException('Probe could not allocate media path.');
    }

    try {
      final Pointer<Void> handle = _create(path);
      if (handle == nullptr) {
        throw MediaDecodeException(_readCreateError());
      }
      return _ProbeNativeDecoder(this, handle);
    } finally {
      _free(path.cast<Void>());
    }
  }

  Pointer<Int8> _copyUtf8(String value) {
    final List<int> bytes = utf8.encode(value);
    final Pointer<Int8> pointer = _malloc(bytes.length + 1).cast<Int8>();
    if (pointer == nullptr) return nullptr;
    final Uint8List target =
        pointer.cast<Uint8>().asTypedList(bytes.length + 1);
    target.setAll(0, bytes);
    target[bytes.length] = 0;
    return pointer;
  }

  String _readCreateError() {
    return _readError((Pointer<Int8> buffer, int capacity) {
      return _copyCreateError(buffer, capacity);
    });
  }

  String _readDecoderError(Pointer<Void> handle) {
    return _readError((Pointer<Int8> buffer, int capacity) {
      return _copyError(handle, buffer, capacity);
    });
  }

  String _readError(int Function(Pointer<Int8>, int) copy) {
    const int capacity = 1024;
    final Pointer<Int8> buffer = _malloc(capacity).cast<Int8>();
    if (buffer == nullptr) return 'Unknown native media decoder error.';
    try {
      final int fullLength = copy(buffer, capacity);
      final int length = fullLength < capacity - 1 ? fullLength : capacity - 1;
      if (length <= 0) return 'Unknown native media decoder error.';
      return utf8.decode(buffer.cast<Uint8>().asTypedList(length));
    } finally {
      _free(buffer.cast<Void>());
    }
  }
}

class _ProbeNativeDecoder implements MediaDecoder {
  final _ProbeNativeBackend backend;
  Pointer<Void> _handle;
  bool _disposed = false;

  _ProbeNativeDecoder(this.backend, this._handle);

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    if (_disposed || _handle == nullptr) {
      throw StateError('Probe native decoder has been disposed.');
    }

    final Pointer<_NativeDecodedFrame> result =
        backend._malloc(sizeOf<_NativeDecodedFrame>()).cast<_NativeDecodedFrame>();
    if (result == nullptr) {
      throw const MediaDecodeException('Probe could not allocate frame result.');
    }

    try {
      final int status = backend._render(
        _handle,
        requestedSourceFrame,
        width,
        height,
        result,
      );
      if (status != 0) {
        throw MediaDecodeException(backend._readDecoderError(_handle));
      }

      final _NativeDecodedFrame raw = result.ref;
      if (raw.rgba == nullptr || raw.byteLength <= 0) {
        throw const MediaDecodeException('Probe decoder returned empty RGBA.');
      }

      return DecodedMediaFrame(
        requestedSourceFrame: raw.requestedFrame,
        actualSourceFrame: raw.actualFrame,
        width: raw.width,
        height: raw.height,
        stride: raw.stride,
        rgba: Uint8List.fromList(raw.rgba.asTypedList(raw.byteLength)),
      );
    } finally {
      backend._release(result);
      backend._free(result.cast<Void>());
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_handle != nullptr) {
      backend._destroy(_handle);
      _handle = nullptr;
    }
  }
}

Future<String?> _findMltPkg() async {
  for (final String candidate in <String>['mlt-framework-7', 'mlt-framework']) {
    final ProcessResult result = await Process.run(
      'pkg-config',
      <String>['--exists', candidate],
    );
    if (result.exitCode == 0) return candidate;
  }
  return null;
}

Future<void> _generateColorClip(String path, String color) async {
  final ProcessResult result = await Process.run(
    'ffmpeg',
    <String>[
      '-hide_banner',
      '-loglevel',
      'error',
      '-y',
      '-f',
      'lavfi',
      '-i',
      'color=c=$color:size=320x180:rate=30',
      '-t',
      '1',
      '-an',
      '-c:v',
      'libx264',
      '-preset',
      'veryfast',
      '-g',
      '30',
      '-keyint_min',
      '30',
      '-sc_threshold',
      '0',
      '-pix_fmt',
      'yuv420p',
      path,
    ],
  );
  expect(
    result.exitCode,
    0,
    reason: 'M13 source generation failed for $color.\n'
        'stdout:\n${result.stdout}\n'
        'stderr:\n${result.stderr}',
  );
}

Future<void> _generateTone(
  String path, {
  required int frequency,
  required double duration,
}) async {
  final ProcessResult result = await Process.run(
    'ffmpeg',
    <String>[
      '-hide_banner',
      '-loglevel',
      'error',
      '-y',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=$frequency:sample_rate=48000:duration=$duration',
      '-c:a',
      'pcm_s16le',
      path,
    ],
  );
  expect(
    result.exitCode,
    0,
    reason: 'M13 tone generation failed for $frequency Hz.\n'
        'stdout:\n${result.stdout}\n'
        'stderr:\n${result.stderr}',
  );
}

Future<List<Map<String, dynamic>>> _probeStreams(String path) async {
  final ProcessResult probe = await Process.run(
    'ffprobe',
    <String>[
      '-v',
      'error',
      '-show_entries',
      'stream=codec_type,codec_name,width,height,avg_frame_rate,nb_frames,duration',
      '-of',
      'json',
      path,
    ],
  );
  expect(probe.exitCode, 0, reason: '${probe.stderr}');
  final Map<String, dynamic> json =
      jsonDecode('${probe.stdout}') as Map<String, dynamic>;
  return (json['streams'] as List<dynamic>)
      .cast<Map<String, dynamic>>();
}

Future<int> _maxAbsAudioSample(
  String path, {
  required double start,
  required double duration,
}) async {
  final ProcessResult decode = await Process.run(
    'ffmpeg',
    <String>[
      '-v',
      'error',
      '-ss',
      start.toStringAsFixed(3),
      '-i',
      path,
      '-t',
      duration.toStringAsFixed(3),
      '-vn',
      '-ac',
      '1',
      '-ar',
      '48000',
      '-f',
      's16le',
      'pipe:1',
    ],
    stdoutEncoding: null,
  );
  expect(decode.exitCode, 0, reason: '${decode.stderr}');

  final Uint8List bytes = Uint8List.fromList(decode.stdout as List<int>);
  final ByteData data = ByteData.sublistView(bytes);
  int max = 0;
  for (int offset = 0; offset + 1 < data.lengthInBytes; offset += 2) {
    final int sample = data.getInt16(offset, Endian.little).abs();
    if (sample > max) max = sample;
  }
  return max;
}

bool _mostlyRed(List<int> pixel) =>
    pixel[0] > 170 && pixel[1] < 90 && pixel[2] < 90;

bool _mostlyBlue(List<int> pixel) =>
    pixel[2] > 170 && pixel[0] < 90 && pixel[1] < 90;

void main() {
  test(
    'M13 exports native MOSAIC with structural audio bounded by picture',
    () async {
      final String? mltPkg = await _findMltPkg();
      if (mltPkg == null) return;

      final ProcessResult ffmpegVersion =
          await Process.run('ffmpeg', const <String>['-version']);
      if (ffmpegVersion.exitCode != 0) return;

      final ProcessResult ffprobeVersion =
          await Process.run('ffprobe', const <String>['-version']);
      if (ffprobeVersion.exitCode != 0) return;

      final ProcessResult pkg = await Process.run(
        'pkg-config',
        <String>['--cflags', '--libs', mltPkg],
      );
      expect(pkg.exitCode, 0, reason: '${pkg.stderr}');

      final Directory temp =
          await Directory.systemTemp.createTemp('r3nder_m13_export_');
      final String library = '${temp.path}/libm13_media_decoder.so';
      final String red = '${temp.path}/red.mp4';
      final String blue = '${temp.path}/blue.mp4';
      final String shortMusic = '${temp.path}/short_music.wav';
      final String longVoice = '${temp.path}/long_voice.wav';
      final String loopOutput = '${temp.path}/mosaic_loop.mp4';
      final String matteOutput = '${temp.path}/mosaic_matte.mp4';

      try {
        final List<String> pkgArgs = '${pkg.stdout}'
            .trim()
            .split(RegExp(r'\s+'))
            .where((String part) => part.isNotEmpty)
            .toList();

        final ProcessResult compile = await Process.run(
          'g++',
          <String>[
            '-std=c++14',
            '-O2',
            '-fPIC',
            '-shared',
            '-pthread',
            '-Wall',
            '-Wextra',
            '-Werror',
            ...pkgArgs.where((String part) => part.startsWith('-I')),
            'linux/runner/media_decoder.cc',
            '-o',
            library,
            ...pkgArgs.where((String part) => !part.startsWith('-I')),
          ],
        );
        expect(
          compile.exitCode,
          0,
          reason: 'M13 native decoder library failed to compile.\n'
              'stdout:\n${compile.stdout}\n'
              'stderr:\n${compile.stderr}',
        );

        await _generateColorClip(red, 'red');
        await _generateColorClip(blue, 'blue');
        await _generateTone(shortMusic, frequency: 880, duration: 0.20);
        await _generateTone(longVoice, frequency: 440, duration: 2.00);

        const String source = '''[MOSAIC:wall]
[PANE:left]
[CLIP:red:red.mp4:0:0:30:1]
[/CLIP]
[/PANE]
[PANE:right]
[CLIP:blue:blue.mp4:0:0:30:1]
[/CLIP]
[/PANE]
[/MOSAIC]
''';

        final _ProbeNativeBackend backend = _ProbeNativeBackend(library);

        // A 0.20 second score loops audibly through a 1.00 second structural
        // root. The infinite input still cannot extend the authored 30 frames.
        final ExportResult loopResult = await StructuralSourceExporter.export(
          source: source,
          structuralSource: 'MOSAIC.wall',
          outputPath: loopOutput,
          format: VideoExportFormat.h264Solid,
          fps: 30,
          width: 320,
          height: 180,
          backend: backend,
          musicPath: shortMusic,
          musicLoop: true,
          resolveSource: (String value) {
            if (value == 'red.mp4') return red;
            if (value == 'blue.mp4') return blue;
            return value;
          },
        );

        expect(loopResult.success, isTrue, reason: loopResult.error);
        expect(loopResult.cancelled, isFalse);
        expect(loopResult.framesWritten, 30);
        expect(File(loopResult.outputPath).existsSync(), isTrue);

        final List<Map<String, dynamic>> loopStreams =
            await _probeStreams(loopResult.outputPath);
        final Map<String, dynamic> loopVideo = loopStreams.singleWhere(
          (Map<String, dynamic> stream) => stream['codec_type'] == 'video',
        );
        final Map<String, dynamic> loopAudio = loopStreams.singleWhere(
          (Map<String, dynamic> stream) => stream['codec_type'] == 'audio',
        );
        expect(loopVideo['width'], 320);
        expect(loopVideo['height'], 180);
        expect(loopVideo['avg_frame_rate'], '30/1');
        expect(loopVideo['nb_frames'], '30');
        expect(loopAudio['codec_name'], 'aac');

        final double loopAudioDuration =
            double.parse('${loopAudio['duration']}');
        expect(loopAudioDuration, inInclusiveRange(0.95, 1.05));

        // Well past the original 0.20 second music file, so a nonzero sample
        // here proves the loop filled rather than merely padding with silence.
        expect(
          await _maxAbsAudioSample(
            loopResult.outputPath,
            start: 0.72,
            duration: 0.12,
          ),
          greaterThan(200),
        );

        final ProcessResult firstFrame = await Process.run(
          'ffmpeg',
          <String>[
            '-v',
            'error',
            '-i',
            loopResult.outputPath,
            '-frames:v',
            '1',
            '-f',
            'rawvideo',
            '-pix_fmt',
            'rgb24',
            'pipe:1',
          ],
          stdoutEncoding: null,
        );
        expect(firstFrame.exitCode, 0, reason: '${firstFrame.stderr}');
        final List<int> rgb = firstFrame.stdout as List<int>;
        expect(rgb.length, 320 * 180 * 3);

        List<int> pixel(int x, int y) {
          final int at = (y * 320 + x) * 3;
          return rgb.sublist(at, at + 3);
        }

        expect(_mostlyRed(pixel(40, 90)), isTrue);
        expect(_mostlyBlue(pixel(280, 90)), isTrue);

        // Voice is intentionally twice as long as picture. Structural source
        // duration stays 30 authored frames. Fill carries the bounded voice;
        // the paired matte is deliberately silent.
        final ExportResult matteResult = await StructuralSourceExporter.export(
          source: source,
          structuralSource: 'MOSAIC.wall',
          outputPath: matteOutput,
          format: VideoExportFormat.lumaMatte,
          fps: 30,
          width: 320,
          height: 180,
          backend: backend,
          audioPath: longVoice,
          resolveSource: (String value) {
            if (value == 'red.mp4') return red;
            if (value == 'blue.mp4') return blue;
            return value;
          },
        );

        expect(matteResult.success, isTrue, reason: matteResult.error);
        expect(matteResult.framesWritten, 30);
        expect(matteResult.mattePath, isNotNull);
        expect(File(matteResult.outputPath).existsSync(), isTrue);
        expect(File(matteResult.mattePath!).existsSync(), isTrue);

        final List<Map<String, dynamic>> fillStreams =
            await _probeStreams(matteResult.outputPath);
        final List<Map<String, dynamic>> matteStreams =
            await _probeStreams(matteResult.mattePath!);

        final List<Map<String, dynamic>> fillAudio = fillStreams
            .where((Map<String, dynamic> stream) => stream['codec_type'] == 'audio')
            .toList();
        final List<Map<String, dynamic>> matteAudio = matteStreams
            .where((Map<String, dynamic> stream) => stream['codec_type'] == 'audio')
            .toList();
        expect(fillAudio, hasLength(1));
        expect(matteAudio, isEmpty);

        final double voiceDuration =
            double.parse('${fillAudio.single['duration']}');
        expect(voiceDuration, inInclusiveRange(0.95, 1.05));
        expect(
          await _maxAbsAudioSample(
            matteResult.outputPath,
            start: 0.72,
            duration: 0.12,
          ),
          greaterThan(200),
        );
      } finally {
        if (temp.existsSync()) {
          temp.deleteSync(recursive: true);
        }
      }
    },
    skip: Platform.isLinux
        ? false
        : 'M13 native structural export is currently Linux-only.',
  );
}
