// ./lib/structural_source_export.dart
//
// Deterministic offline export for canonical EDIT and MOSAIC sources.
//
// Structural source export deliberately does not reuse live preview policy.
// Every output frame is selected by exact integer ProjectTime and rendered
// through the blocking compositor path. A decoder may take as long as it needs
// to produce that frame, but it cannot move project time, shorten the authored
// source, substitute a nearby frame, or turn an offline layer into a hold.
// Recursive EDIT/MOSAIC boundaries preserve leaf decode diagnostics separately
// from their synthetic composition frames, so every actual decoder result is
// validated here even when another nested layer still produced visible pixels.
//
// Structural audio follows the same rule. Workspace voice and music may be
// muxed under a structural root, but neither track may change its authored
// frame count. Voice therefore differs from terminal SceneExporter semantics:
// terminal voice can stretch an already-owned end hold before rendering,
// whereas EDIT/MOSAIC duration is canonical authoring state and is immutable
// here. Music looping fills the authored duration and never extends it.
//
// Terminal SceneExporter remains independent. Its Flutter-canvas readback is
// premultiplied and has preroll semantics that structural sources do not.
// Structural frames come directly from MLT plus R3nder's RGBA compositor, so
// terminal-only readback and preroll filters are not copied into this path.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'audio_mix.dart';
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

    // Validate the recursive leaf channel, not the composition-local synthetic
    // frame list. A nested structural source can produce useful pixels from one
    // layer while another leaf is offline or returned the wrong source frame;
    // exact export must still fail rather than silently bake the partial image.
    for (final MediaFrame frame in result.diagnosticFrames) {
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
    String? audioPath,
    double audioGainDb = 0.0,
    String? musicPath,
    double musicGainDb = 0.0,
    bool musicLoop = false,
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

      // Missing workspace audio is survivable, exactly as terminal BAKE is.
      // A missing bed must not turn a valid structural picture export into a
      // failed render. Callers normally pass already-probed paths, but keeping
      // this check here makes the exporter safe as a standalone boundary too.
      final String? bedFile =
          audioPath != null && File(audioPath).existsSync() ? audioPath : null;
      final String? musicFile =
          musicPath != null && File(musicPath).existsSync() ? musicPath : null;

      final Process currentProcess = await Process.start(
        'ffmpeg',
        _ffmpegArgs(
          outputPath: paths.outputPath,
          mattePath: paths.mattePath,
          format: format,
          fps: fps,
          width: width,
          height: height,
          totalFrames: totalFrames,
          bedFile: bedFile,
          audioGainDb: audioGainDb,
          musicFile: musicFile,
          musicGainDb: musicGainDb,
          musicLoop: musicLoop,
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
    required int totalFrames,
    required String? bedFile,
    required double audioGainDb,
    required String? musicFile,
    required double musicGainDb,
    required bool musicLoop,
  }) {
    final bool hasAudio = bedFile != null || musicFile != null;

    final List<String> args = <String>[
      '-y',
      '-v',
      'error',
      '-nostats',
      '-nostdin',
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
      if (bedFile != null) ...<String>[
        '-i',
        bedFile,
      ],
      if (musicFile != null) ...<String>[
        if (musicLoop) ...<String>['-stream_loop', '-1'],
        '-i',
        musicFile,
      ],
    ];

    const String audioOutLabel = 'structaudio';
    String audioGraph = '';
    if (hasAudio) {
      final String voiceInput = '1:a';
      final String musicInput = bedFile != null ? '2:a' : '1:a';
      if (bedFile != null && musicFile != null) {
        audioGraph = '${bedMixGraph(
          voiceGainDb: audioGainDb,
          musicGainDb: musicGainDb,
          voiceInput: voiceInput,
          musicInput: musicInput,
        )};[$kBedMixOutLabel]apad[$audioOutLabel]';
      } else {
        final String input = bedFile != null ? voiceInput : musicInput;
        final double gain = bedFile != null ? audioGainDb : musicGainDb;
        audioGraph =
            '[$input]${bedVolumeFilter(gain)},apad[$audioOutLabel]';
      }
    }

    // Structural time is authored frame count. The audio may be longer,
    // shorter, or infinitely looped, so every audio-bearing output is cut at
    // exactly the picture duration. The decimal is an ffmpeg boundary value,
    // never canonical project state; frame count and fps remain the source of
    // truth throughout R3nder.
    final String outDuration = (totalFrames / fps).toStringAsFixed(9);

    switch (format) {
      case VideoExportFormat.h264Solid:
        args.addAll(<String>[
          if (hasAudio) ...<String>[
            '-filter_complex',
            audioGraph,
            '-map',
            '0:v:0',
            '-map',
            '[$audioOutLabel]',
            '-c:a',
            'aac',
            '-b:a',
            '192k',
          ],
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
          if (hasAudio) ...<String>['-t', outDuration],
          outputPath,
        ]);
        break;

      case VideoExportFormat.proresAlpha:
        args.addAll(<String>[
          if (hasAudio) ...<String>[
            '-filter_complex',
            audioGraph,
            '-map',
            '0:v:0',
            '-map',
            '[$audioOutLabel]',
            '-c:a',
            'pcm_s24le',
          ],
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
          if (hasAudio) ...<String>['-t', outDuration],
          outputPath,
        ]);
        break;

      case VideoExportFormat.lumaMatte:
        const String videoGraph =
            '[0:v]split=2[fg][fa];'
            '[fg]format=yuv420p[color];'
            '[fa]alphaextract,format=yuv420p[matte]';
        args.addAll(<String>[
          '-filter_complex',
          hasAudio ? '$videoGraph;$audioGraph' : videoGraph,

          // Fill carries the sound. The matte stays silent so dropping both
          // files into an NLE cannot accidentally double the audio level.
          '-map',
          '[color]',
          if (hasAudio) ...<String>[
            '-map',
            '[$audioOutLabel]',
            '-c:a',
            'aac',
            '-b:a',
            '192k',
          ],
          '-c:v',
          'libx264',
          '-preset',
          'veryfast',
          '-crf',
          '18',
          '-threads',
          '0',
          if (hasAudio) ...<String>['-t', outDuration],
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
          if (hasAudio) ...<String>['-t', outDuration],
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
