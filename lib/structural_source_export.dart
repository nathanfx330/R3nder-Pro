// ./lib/structural_source_export.dart
//
// Deterministic offline export for canonical EDIT and MOSAIC sources.
//
// Structural source export deliberately does not reuse live preview policy.
// Every output frame is selected by exact integer ProjectTime and rendered
// through the blocking compositor path. A decoder may take as long as it needs
// to produce that frame, but it cannot move project time, shorten the authored
// source, substitute a nearby frame, or turn an offline layer into a hold.
//
// Terminal SceneExporter remains independent. Its Flutter-canvas readback is
// premultiplied and has preroll/audio semantics that structural sources do not.
// Structural frames come directly from MLT plus R3nder's RGBA compositor, so
// terminal-only readback filters are not copied into this path.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'edit_linter.dart';
import 'edit_model.dart';
import 'edit_video_compositor.dart';
import 'exporter.dart';
import 'media_layer.dart';
import 'project_clock.dart';

class StructuralSourceFrameRenderer {
  final EditDocumentModel model;
  final StructuralSourceRef root;
  final int width;
  final int height;
  final MediaLayer _mediaLayer;
  final EditVideoCompositor _compositor;

  bool _disposed = false;

  StructuralSourceFrameRenderer._({
    required this.model,
    required this.root,
    required this.width,
    required this.height,
    required MediaLayer mediaLayer,
    required EditVideoCompositor compositor,
  })  : _mediaLayer = mediaLayer,
        _compositor = compositor;

  factory StructuralSourceFrameRenderer.create({
    required String source,
    required String structuralSource,
    required int width,
    required int height,
    required MediaDecoderBackend backend,
    required String Function(String source) resolveSource,
  }) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('Structural export size must be positive.');
    }

    final EditDocumentModel model = EditDocumentModel.parse(source);
    final StructuralSourceRef root = _parseRoot(structuralSource);
    if (!model.containsStructuralSource(root)) {
      throw StateError(
        'No structural source named "${root.canonicalSource}".',
      );
    }

    final EditLintResult lint = EditGraphLinter.lint(model);
    if (!lint.isValid) {
      final EditLintIssue issue = lint.issues.first;
      throw StateError(
        'Structural source graph is not exportable: ${issue.message} '
        'Path: ${issue.editPath.join(' -> ')}',
      );
    }

    final MediaLayer mediaLayer = MediaLayer(
      editDocument: model,
      backend: backend,
      resolveSource: resolveSource,
    );
    final EditVideoCompositor compositor = EditVideoCompositor.forModel(
      model: model,
      mediaLayer: mediaLayer,
      backend: backend,
      resolveSource: resolveSource,
    );

    return StructuralSourceFrameRenderer._(
      model: model,
      root: root,
      width: width,
      height: height,
      mediaLayer: mediaLayer,
      compositor: compositor,
    );
  }

  static StructuralSourceRef _parseRoot(String source) {
    final StructuralSourceRef? root = StructuralSourceRef.tryParse(source);
    if (root == null || root.id.isEmpty) {
      throw ArgumentError.value(
        source,
        'structuralSource',
        'Expected EDIT.<id> or MOSAIC.<id>.',
      );
    }
    return root;
  }

  int get totalFrames => model.structuralSourceFrameCount(root);

  Uint8List renderFrame(int projectFrame) {
    _checkAlive();
    if (projectFrame < 0 || projectFrame >= totalFrames) {
      throw RangeError.range(
        projectFrame,
        0,
        totalFrames <= 0 ? 0 : totalFrames - 1,
        'projectFrame',
      );
    }

    final EditVideoCompositeResult result = _compositor.renderSource(
      root.canonicalSource,
      ProjectTime(frame: projectFrame, mode: ProjectClockMode.scrub),
      ui.Size(width.toDouble(), height.toDouble()),
    );

    if (result.hasPending) {
      throw StateError(
        'Exact structural export returned a pending frame at '
        '${root.canonicalSource} frame $projectFrame.',
      );
    }

    for (final MediaFrame frame in result.mediaFrames) {
      if (frame.status == MediaFrameStatus.offline) {
        throw MediaDecodeException(
          'Offline source "${frame.source}" while exporting '
          '${root.canonicalSource} frame $projectFrame: '
          '${frame.error ?? 'unknown decode error'}',
        );
      }
      if (frame.status == MediaFrameStatus.decoded &&
          frame.actualSourceFrame != null &&
          frame.actualSourceFrame != frame.requestedSourceFrame) {
        throw MediaDecodeException(
          'Source "${frame.source}" returned frame '
          '${frame.actualSourceFrame} when exact frame '
          '${frame.requestedSourceFrame} was requested.',
        );
      }
    }

    // An authored gap is a legitimate transparent frame. It is different from
    // an offline source, which was rejected above.
    final Uint8List? rgba = result.rgba;
    if (rgba == null) {
      return Uint8List(width * height * 4);
    }

    if (result.width != width || result.height != height) {
      throw StateError(
        'Structural compositor returned ${result.width}x${result.height} '
        'for requested ${width}x$height export frame $projectFrame.',
      );
    }

    final int packedStride = width * 4;
    final int requiredBytes = result.stride * height;
    if (result.stride < packedStride || rgba.length < requiredBytes) {
      throw StateError(
        'Structural compositor returned an invalid RGBA buffer at frame '
        '$projectFrame.',
      );
    }

    if (result.stride == packedStride && rgba.length == packedStride * height) {
      return Uint8List.fromList(rgba);
    }

    final Uint8List packed = Uint8List(packedStride * height);
    for (int y = 0; y < height; y++) {
      final int src = y * result.stride;
      final int dst = y * packedStride;
      packed.setRange(dst, dst + packedStride, rgba, src);
    }
    return packed;
  }

  void _checkAlive() {
    if (_disposed) {
      throw StateError('StructuralSourceFrameRenderer has been disposed.');
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _compositor.dispose();
    _mediaLayer.dispose();
  }
}

class StructuralSourceExporter {
  static Future<bool> _isFfmpegAvailable() async {
    try {
      final ProcessResult result =
          await Process.run('ffmpeg', <String>['-version']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<ExportResult> export({
    required String source,
    required String structuralSource,
    required String outputPath,
    required VideoExportFormat format,
    required int fps,
    required int width,
    required int height,
    required String Function(String source) resolveSource,
    MediaDecoderBackend? backend,
    void Function(int done, int total)? onProgress,
    void Function(String status)? onStatus,
    ExportCancelToken? cancelToken,
  }) async {
    final _StructuralExportPaths paths =
        _StructuralExportPaths.forFormat(outputPath, format);

    if (fps <= 0 || width <= 0 || height <= 0) {
      return ExportResult(
        success: false,
        cancelled: false,
        framesWritten: 0,
        outputPath: paths.outputPath,
        mattePath: paths.mattePath,
        error: 'Structural export fps and dimensions must be positive.',
      );
    }

    if (!await _isFfmpegAvailable()) {
      return ExportResult(
        success: false,
        cancelled: false,
        framesWritten: 0,
        outputPath: paths.outputPath,
        mattePath: paths.mattePath,
        error: 'ffmpeg not found on system PATH.',
      );
    }

    StructuralSourceFrameRenderer? renderer;
    Process? process;
    int framesWritten = 0;

    Future<void> deletePartialOutputs() async {
      for (final String path in <String>[
        paths.outputPath,
        if (paths.mattePath != null) paths.mattePath!,
      ]) {
        try {
          final File file = File(path);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    }

    Future<void> terminateProcess() async {
      final Process? current = process;
      if (current == null) return;
      try {
        await current.stdin.close();
      } catch (_) {}
      try {
        current.kill(ProcessSignal.sigterm);
      } catch (_) {}
      try {
        await current.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {
        try {
          current.kill(ProcessSignal.sigkill);
        } catch (_) {}
      }
    }

    try {
      onStatus?.call('Preparing Structural Source...');
      renderer = StructuralSourceFrameRenderer.create(
        source: source,
        structuralSource: structuralSource,
        width: width,
        height: height,
        backend: backend ?? NativeMltMediaBackend(),
        resolveSource: resolveSource,
      );

      final int totalFrames = renderer.totalFrames;
      if (totalFrames <= 0) {
        return ExportResult(
          success: false,
          cancelled: false,
          framesWritten: 0,
          outputPath: paths.outputPath,
          mattePath: paths.mattePath,
          error: 'Structural source "$structuralSource" has no authored frames.',
        );
      }

      final Directory outputDirectory = File(paths.outputPath).parent;
      if (!await outputDirectory.exists()) {
        await outputDirectory.create(recursive: true);
      }

      final Process currentProcess = await Process.start(
        'ffmpeg',
        _ffmpegArgs(
          outputPath: paths.outputPath,
          mattePath: paths.mattePath,
          format: format,
          fps: fps,
          width: width,
          height: height,
        ),
      );
      process = currentProcess;

      final StringBuffer stderr = StringBuffer();
      final Future<void> stderrDone =
          currentProcess.stderr.transform(utf8.decoder).forEach(stderr.write);
      final Future<void> stdoutDone = currentProcess.stdout.drain<void>();

      onStatus?.call('Rendering Structural Source...');

      for (int frame = 0; frame < totalFrames; frame++) {
        if (cancelToken?.isCancelled ?? false) {
          await terminateProcess();
          await deletePartialOutputs();
          return ExportResult(
            success: false,
            cancelled: true,
            framesWritten: framesWritten,
            outputPath: paths.outputPath,
            mattePath: paths.mattePath,
          );
        }

        final Uint8List rgba = renderer.renderFrame(frame);
        currentProcess.stdin.add(rgba);
        await currentProcess.stdin.flush();
        framesWritten++;
        onProgress?.call(framesWritten, totalFrames);
      }

      await currentProcess.stdin.close();
      final int exitCode = await currentProcess.exitCode;
      await stderrDone;
      await stdoutDone;

      if (exitCode != 0) {
        await deletePartialOutputs();
        return ExportResult(
          success: false,
          cancelled: false,
          framesWritten: framesWritten,
          outputPath: paths.outputPath,
          mattePath: paths.mattePath,
          error: 'ffmpeg structural export failed ($exitCode): '
              '${stderr.toString().trim()}',
        );
      }

      onStatus?.call('Structural Export Complete');
      return ExportResult(
        success: true,
        cancelled: false,
        framesWritten: framesWritten,
        outputPath: paths.outputPath,
        mattePath: paths.mattePath,
      );
    } catch (error) {
      await terminateProcess();
      await deletePartialOutputs();
      return ExportResult(
        success: false,
        cancelled: false,
        framesWritten: framesWritten,
        outputPath: paths.outputPath,
        mattePath: paths.mattePath,
        error: '$error',
      );
    } finally {
      renderer?.dispose();
    }
  }

  static List<String> _ffmpegArgs({
    required String outputPath,
    required String? mattePath,
    required VideoExportFormat format,
    required int fps,
    required int width,
    required int height,
  }) {
    final List<String> args = <String>[
      '-y',
      '-v',
      'error',
      '-nostats',
      '-f',
      'rawvideo',
      '-pix_fmt',
      'rgba',
      '-s',
      '${width}x$height',
      '-framerate',
      '$fps',
      '-i',
      'pipe:0',
    ];

    switch (format) {
      case VideoExportFormat.h264Solid:
        args.addAll(<String>[
          '-c:v',
          'libx264',
          '-preset',
          'veryfast',
          '-crf',
          '18',
          '-pix_fmt',
          'yuv420p',
          '-threads',
          '0',
          outputPath,
        ]);
        break;
      case VideoExportFormat.proresAlpha:
        args.addAll(<String>[
          '-c:v',
          'prores_ks',
          '-profile:v',
          '4444',
          '-qscale:v',
          '11',
          '-pix_fmt',
          'yuva444p10le',
          '-threads',
          '0',
          outputPath,
        ]);
        break;
      case VideoExportFormat.lumaMatte:
        args.addAll(<String>[
          '-filter_complex',
          '[0:v]split=2[fg][fa];'
              '[fg]format=yuv420p[color];'
              '[fa]alphaextract,format=yuv420p[matte]',
          '-map',
          '[color]',
          '-c:v',
          'libx264',
          '-preset',
          'veryfast',
          '-crf',
          '18',
          '-threads',
          '0',
          outputPath,
          '-map',
          '[matte]',
          '-c:v',
          'libx264',
          '-preset',
          'veryfast',
          '-crf',
          '18',
          '-threads',
          '0',
          '-an',
          mattePath!,
        ]);
        break;
    }

    return args;
  }
}

class _StructuralExportPaths {
  final String outputPath;
  final String? mattePath;

  const _StructuralExportPaths({
    required this.outputPath,
    required this.mattePath,
  });

  factory _StructuralExportPaths.forFormat(
    String requested,
    VideoExportFormat format,
  ) {
    switch (format) {
      case VideoExportFormat.proresAlpha:
        return _StructuralExportPaths(
          outputPath: requested.replaceAll(RegExp(r'\.mp4$'), '.mov'),
          mattePath: null,
        );
      case VideoExportFormat.h264Solid:
        return _StructuralExportPaths(
          outputPath: requested.replaceAll(RegExp(r'\.mov$'), '.mp4'),
          mattePath: null,
        );
      case VideoExportFormat.lumaMatte:
        final String output = requested.replaceAll(RegExp(r'\.mov$'), '.mp4');
        return _StructuralExportPaths(
          outputPath: output,
          mattePath: output.replaceAll(RegExp(r'\.mp4$'), '_matte.mp4'),
        );
    }
  }
}
