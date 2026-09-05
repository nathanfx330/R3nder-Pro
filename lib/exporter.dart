// ./lib/exporter.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'scene_engine.dart';
import 'project_clock.dart';
import 'scene_evaluator.dart';
import 'compositor.dart';
import 'motion.dart';
import 'diag.dart';
import 'media_layer.dart';
import 'program_structural_export.dart';

// The sum of two beds, and the gain spelling, shared with the preview
// player. NOT an import of audio_bed.dart: export and preview remain
// unrelated code paths, and this registry holds no state, spawns nothing,
// and imports nothing. It exists so the balance you rode a fader to find in
// the editor is arithmetically the same balance that lands in the file.
import 'audio_mix.dart';

enum VideoExportFormat {
  h264Solid,
  proresAlpha,

  /// Fill plus matte pair: two H.264 files where the second carries the
  /// alpha channel as luminance. Multiply fill by matte in the comp and the
  /// plate reconstructs exactly.
  ///
  /// Exists because ProRes 4444 is intra-only and near-lossless, so it barely
  /// compresses terminal output at all. For a working cut you drop into a
  /// timeline repeatedly, the pair is a fraction of the size and carries the
  /// same information. ProRes stays for the mastering file.
  lumaMatte,
}

class ExportCancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class ExportResult {
  final bool success;
  final bool cancelled;
  final String? error;
  final int framesWritten;

  /// The path actually written, which may differ from the one requested:
  /// the container is a property of the format, so the exporter coerces the
  /// extension rather than trusting the caller to agree with it.
  final String outputPath;

  /// Second file for lumaMatte exports, null for every other format.
  final String? mattePath;

  const ExportResult({
    required this.success,
    required this.cancelled,
    required this.framesWritten,
    required this.outputPath,
    this.mattePath,
    this.error,
  });
}

// ---------------------------------------------------------------------------
// Writer isolate (GPU Path)
// ---------------------------------------------------------------------------

void _fifoWriterMain((String, SendPort) setup) {
  final String fifoPath = setup.$1;
  final SendPort reply = setup.$2;

  final ReceivePort inbox = ReceivePort();
  reply.send(inbox.sendPort);

  RandomAccessFile? raf;

  try {
    raf = File(fifoPath).openSync(mode: FileMode.writeOnly);
  } catch (e) {
    reply.send('error:FIFO open failed: $e');
    inbox.close();
    return;
  }
  reply.send('ready');

  inbox.listen((dynamic msg) {
    if (msg == null) {
      try {
        raf!.closeSync();
        reply.send('done');
      } catch (e) {
        reply.send('error:FIFO close failed: $e');
      }
      inbox.close();
      return;
    }
    try {
      final Uint8List bytes =
          (msg as TransferableTypedData).materialize().asUint8List();
      raf!.writeFromSync(bytes);
      reply.send('ack');
    } catch (e) {
      try {
        raf!.closeSync();
      } catch (_) {}
      reply.send('error:FIFO write failed: $e');
      inbox.close();
    }
  });
}

// ---------------------------------------------------------------------------
// Exporter
// ---------------------------------------------------------------------------

class _InFlightReadback {
  final ui.Image frame;
  final Future<ByteData?> bytes;
  final int index;
  _InFlightReadback(this.frame, this.bytes, this.index);
}

class SceneExporter {
  static const int _maxFramesInFlight = 2;
  static const int _progressIntervalMs = 125;

  static Future<bool> _isFfmpegAvailable() async {
    try {
      final ProcessResult r = await Process.run('ffmpeg', ['-version']);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<ExportResult> export({
    required SceneEngine scene,
    required String fontFamily,
    required String outputPath,
    required VideoExportFormat format,
    required int fps,
    required int width,
    required int height,
    /// Raw authored document containing EDIT/MOSAIC definitions and STRUCT
    /// placements. When null, bake is the historical terminal-only path.
    String? structuralDocument,
    /// Resolves relative CLIP/luma paths for [structuralDocument]. Both this
    /// and the document must be present before whole-program STRUCT is enabled.
    String Function(String source)? resolveStructuralSource,
    /// Decoder seam for deterministic exporter tests. Production uses native
    /// persistent MLT when omitted.
    MediaDecoderBackend? structuralBackend,
    /// Background audio bed, muxed as a second ffmpeg input. Null means a
    /// silent bake. Export never touches the preview player: ffmpeg reads the
    /// original file, so the bake gets full source rate and channel count
    /// regardless of what the preview pipeline resampled to.
    String? audioPath,
    /// Applied by ffmpeg's volume filter, the same filter the preview player
    /// uses, so the level you hear scrubbing is the level that lands here.
    double audioGainDb = 0.0,
    /// Music bed, summed with [audioPath] rather than replacing it. Null
    /// means no score.
    ///
    /// It has no say in length. The dry run below has already settled the
    /// frame count, and the voice bed is the only track that could have
    /// stretched it; music is bounded by the same output `-t` that trims the
    /// sub-frame rounding remainder. A score is normally longer than the cut
    /// it plays under, and cutting it off is the designed behavior rather
    /// than a compromise.
    String? musicPath,
    /// Attenuates the music track before the sum. See audio_mix.dart for why
    /// the sum itself does not renormalize.
    double musicGainDb = 0.0,
    /// Repeats the music track until the picture ends.
    ///
    /// LOOPING FILLS, IT DOES NOT EXTEND. The repeat is `-stream_loop -1` on
    /// the input, which is infinite, and the same output `-t` that trims a
    /// long score is what makes it finite again. So this changes what plays
    /// under the last third of a piece and changes no frame count at all,
    /// which is what keeps music outside ScriptWarmKey with the loop on.
    ///
    /// Simpler here than in the preview player because a bake always starts
    /// every track at the head: there is no scrub position, so there is no
    /// phase to resolve and no interaction with an input seek.
    bool musicLoop = false,
    void Function(int done, int total)? onProgress,
    void Function(String status)? onStatus,
    ExportCancelToken? cancelToken,
  }) async {
    // Container is a property of the format, so coerce the extension here
    // rather than trusting the caller. Computed before the ffmpeg check
    // because every early return below reports these.
    String actualOutputPath = outputPath;
    String? mattePath;
    switch (format) {
      case VideoExportFormat.proresAlpha:
        actualOutputPath =
            outputPath.replaceAll(RegExp(r'\.mp4$'), '.mov');
        break;
      case VideoExportFormat.h264Solid:
        actualOutputPath =
            outputPath.replaceAll(RegExp(r'\.mov$'), '.mp4');
        break;
      case VideoExportFormat.lumaMatte:
        actualOutputPath =
            outputPath.replaceAll(RegExp(r'\.mov$'), '.mp4');
        mattePath =
            actualOutputPath.replaceAll(RegExp(r'\.mp4$'), '_matte.mp4');
        break;
    }

    if (!await _isFfmpegAvailable()) {
      return ExportResult(
        success: false, cancelled: false, framesWritten: 0, outputPath: actualOutputPath, mattePath: mattePath,
        error: 'ffmpeg not found on system PATH.',
      );
    }

    onStatus?.call('Calculating Timeline...');

    // 1. Dry run the scene to get the exact frame count.
    // The SceneEngine is fully deterministic (seeded RNG, frame-counted
    // window/gallery phases), so this count is exact. The engine owns the
    // 2-second end hold now (kEndHoldFrames in engine.dart), so it's already
    // included here — the exporter no longer bolts extra frames on, and the
    // hold frames animate (cursor blink, flash effects) instead of freezing.
    // When an audio bed outlasts the script, that same hold is what stretches
    // to cover it, so the extended total falls out of this loop for free.
    //
    // The dry run also reports where the bed starts. Rather than hardcoding a
    // preroll length (which would silently desync the day preroll timing
    // changes), watch for the project frame on which the terminal engine first
    // ticks. Preview uses the identical condition after evaluating ProjectTime,
    // so export must keep that project-frame number instead of subtracting one
    // for the old tick-before-paint render loop.
    scene.reset();
    int totalFrames = 0;
    int audioStartFrame = 0;
    bool terminalHasStarted = false;
    while (!scene.isFinished) {
      scene.tick();
      totalFrames++;
      if (!terminalHasStarted && scene.terminal.frameCount > 0) {
        terminalHasStarted = true;
        audioStartFrame = scene.frameCount;
      }
    }

    // 1b. PANE LIFE NEUTRALITY AUDIT.
    //
    // The whole Pane Life design rests on one claim: turning it on cannot
    // change the length of a piece. Motion divides a hold the page already
    // owned rather than scheduling anything new. That is asserted in
    // _ActiveApp.rebuildPanePlan, but an assert is debug-only and it checks
    // the PLAN, not the render.
    //
    // So the claim gets checked against the thing it is actually about: the
    // frame count a bake produces. The dry run above is exactly "bake with
    // it on"; this is "bake with it off", from the same engine and the same
    // decoded assets, costing one extra tick loop and no decode.
    //
    // A mismatch is reported rather than thrown. The export is not wrong,
    // it is just longer or shorter than the design promised, and failing a
    // render someone is waiting on would be a worse answer than telling
    // them. If this ever fires, the motion has found a way to schedule
    // time and that is the bug to chase before any other.
    //
    // Structural pane GROUPING is excluded by construction: it changes how
    // many visual panes exist and therefore how many pages, which the
    // manual documents as a legitimate duration change. Only the ON/OFF
    // toggle is audited, with grouping held constant.
    if (scene.paneLife.enabled) {
      final PaneLifeConfig authored = scene.paneLife;
      scene.paneLife = PaneLifeConfig.off;
      scene.reset();
      int stillFrames = 0;
      while (!scene.isFinished) {
        scene.tick();
        stillFrames++;
      }
      scene.paneLife = authored;

      if (stillFrames != totalFrames) {
        diag(
            'panelife',
            'FRAME COUNT NOT NEUTRAL: $totalFrames with motion, '
            '$stillFrames without (delta ${totalFrames - stillFrames}). '
            'Pane Life must divide an existing hold, never extend it.');
      } else {
        diag('panelife',
            'neutrality OK: $totalFrames frames with motion and without');
      }
    }

    // Reset for the actual render (images stay decoded across resets)
    scene.reset();

    final String exportDir = File(actualOutputPath).parent.path;
    final Directory dir = Directory(exportDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);

    final String fifoPath = '$exportDir/.r3nder_fifo_$pid';
    try {
      final File f = File(fifoPath);
      if (f.existsSync()) f.deleteSync();
      final ProcessResult mk = await Process.run('mkfifo', [fifoPath]);
      if (mk.exitCode != 0) {
        return ExportResult(
          success: false, cancelled: false, framesWritten: 0, outputPath: actualOutputPath, mattePath: mattePath,
          error: 'mkfifo failed: ${mk.stderr}',
        );
      }
    } catch (e) {
      return ExportResult(
        success: false, cancelled: false, framesWritten: 0, outputPath: actualOutputPath, mattePath: mattePath,
        error: 'mkfifo unavailable: $e',
      );
    }

    // Captured as nullable locals rather than bool flags: Dart promotes
    // `bedFile != null` inside the collection-ifs below, but cannot tie a
    // separate boolean back to the variable it was derived from.
    final String? bedFile =
        (audioPath != null && File(audioPath).existsSync()) ? audioPath : null;
    final String? musicFile =
        (musicPath != null && File(musicPath).existsSync()) ? musicPath : null;

    // Either track alone is enough to make this a bake with sound, so every
    // audio decision below keys on this rather than on the voice bed.
    final bool hasAudio = bedFile != null || musicFile != null;

    final List<String> args = [
      '-y',
      '-v', 'error',
      '-nostats',
      '-nostdin',
      '-f', 'rawvideo',
      '-pix_fmt', 'rgba',
      '-s', '${width}x$height',
      '-framerate', '$fps',
      '-i', fifoPath, // Input 0: FIFO (Video)
      if (bedFile != null) ...['-i', bedFile], // Input 1: voice bed
      if (musicFile != null) ...[
        // Infinite here, finite at the output -t below. A loop that had to
        // be counted would need the picture length before the input list is
        // built, and would be wrong by a frame whenever the score did not
        // divide evenly into it.
        if (musicLoop) ...['-stream_loop', '-1'],
        '-i', musicFile, // Input 1 or 2: music bed
      ],
    ];

    // Music takes the slot after the voice bed, or the voice bed's slot when
    // there is no voice bed. Derived rather than hardcoded: a bake with music
    // and no voiceover is an ordinary case, not an edge one.
    final String voiceInput = '1:a';
    final String musicInput = bedFile != null ? '2:a' : '1:a';

    // Audio filter chain, in order:
    //
    //   adelay  parks the beds behind the preroll wipe. This used to be
    //           -itsoffset, which is wrong in a way that only shows up in
    //           someone else's software: -itsoffset records the shift as a
    //           container start_time rather than as actual samples, so any
    //           tool that ignores start_time slams the voiceover to zero and
    //           plays it underneath the green. adelay writes real silence,
    //           leaving nothing to interpret. Verified: with adelay the audio
    //           stream starts at 0.000 and runs the full video duration, with
    //           the content offset exactly where it belongs.
    //           BOTH tracks take the same delay. They are locked to one
    //           timeline, and a score that started under the green while the
    //           voiceover waited would be two different timelines.
    //   volume  matches the preview player's filter, so the level you hear
    //           scrubbing is the level that lands here. Spelled by
    //           audio_mix.dart so the two cannot drift.
    //   amix    sums the two, without renormalizing. See audio_mix.dart:
    //           normalize=1 would drop the voice 6dB the moment a score was
    //           attached, with no fader moved and nothing said.
    //   apad    backfills silence to the end so the track runs the full
    //           length of the picture instead of stopping early. AFTER the
    //           sum rather than on each branch: padding both inputs would
    //           make both infinite, which turns amix's duration=longest into
    //           a statement about nothing. Bounded by the output -t below.
    //
    // WHY THIS IS A GRAPH AND NOT -af. A stream summed inside filter_complex
    // is a label, and -af cannot address a label. Once two tracks can be
    // attached, every format has to build the chain here, including the plain
    // H.264 path that previously needed no filter_complex at all. That in
    // turn is why -map 0:v appears on that path: filter_complex suppresses
    // automatic stream selection, so an unmapped video stream is silently
    // dropped rather than diagnosed.
    final int bedDelayMs = (audioStartFrame * 1000 / fps).round();
    final String delayChain =
        bedDelayMs > 0 ? 'adelay=$bedDelayMs:all=1' : '';

    /// Label the mixed, padded audio lands on. Mapped by name below.
    const String audioOutLabel = 'bedout';

    String audioGraph = '';
    if (bedFile != null && musicFile != null) {
      audioGraph = '${bedMixGraph(
        voiceGainDb: audioGainDb,
        musicGainDb: musicGainDb,
        voiceChain: delayChain,
        musicChain: delayChain,
        voiceInput: voiceInput,
        musicInput: musicInput,
      )};[$kBedMixOutLabel]apad[$audioOutLabel]';
    } else if (hasAudio) {
      // One track. Same chain minus the sum, so a workspace with no score
      // produces the identical filtergraph it always did.
      final String src = bedFile != null ? voiceInput : musicInput;
      final double gain = bedFile != null ? audioGainDb : musicGainDb;
      audioGraph = '[$src]${<String>[
        if (delayChain.isNotEmpty) delayChain,
        bedVolumeFilter(gain),
        'apad',
      ].join(',')}[$audioOutLabel]';
    }

    // Video length stays authoritative. The engine already stretched its end
    // hold to cover a longer VOICE bed, so for that track this only trims the
    // sub-frame remainder left by rounding a duration up to whole frames.
    //
    // For music it does real work. Nothing stretched to accommodate a score,
    // so this is the cut that keeps a four minute track under a forty second
    // piece from producing a four minute file. It is the designed behavior
    // and not a safety net: see the musicPath parameter above.
    final String outDuration = (totalFrames / fps).toStringAsFixed(6);

    if (format == VideoExportFormat.proresAlpha) {
      // Flutter produces Premultiplied Alpha. Unpremultiply it so glows
      // composite correctly in NLEs.
      const String videoGraph =
          '[0:v]unpremultiply=inplace=1,format=rgba[straight]';
      args.addAll([
        '-filter_complex',
        hasAudio ? '$videoGraph;$audioGraph' : videoGraph,
        '-map', '[straight]',
        if (hasAudio) ...[
          // filter_complex suppresses automatic stream selection, so the
          // audio has to be mapped by hand or it is silently dropped.
          '-map', '[$audioOutLabel]',
          // .mov wants uncompressed audio next to a 4444 video track: this
          // is a mastering file headed for an NLE, not a delivery file.
          '-c:a', 'pcm_s24le',
        ],
        '-c:v', 'prores_ks', '-profile:v', '4444',
        '-qscale:v', '11', '-pix_fmt', 'yuva444p10le',
        '-threads', '0',
        if (hasAudio) ...['-t', outDuration],
        actualOutputPath,
      ]);
    } else if (format == VideoExportFormat.lumaMatte) {
      // One invocation, two outputs. split=2 after the unpremultiply feeds
      // both branches from a single decode: the fill drops alpha via
      // yuv420p, the matte pulls the alpha plane out as luminance.
      //
      // The format=rgba pin between unpremultiply and alphaextract is load
      // bearing. Without it the two filters fail to negotiate a common
      // format and the whole graph dies at runtime with "The following
      // filters could not choose their formats". The ProRes branch above
      // carries the same pin.
      //
      // Fill must be STRAIGHT, not premultiplied: the comp reconstructs as
      // fill multiplied by matte, so a premultiplied fill would apply alpha
      // a second time and every soft edge would darken.
      const String videoGraph =
          '[0:v]unpremultiply=inplace=1,format=rgba,split=2[fg][fa]; '
          '[fg]format=yuv420p[color]; '
          '[fa]alphaextract,format=yuv420p[matte]';
      args.addAll([
        '-filter_complex',
        hasAudio ? '$videoGraph; $audioGraph' : videoGraph,

        // Output 1: the color fill, carrying the audio.
        '-map', '[color]',
        if (hasAudio) ...[
          '-map', '[$audioOutLabel]',
          '-c:a', 'aac', '-b:a', '192k',
        ],
        '-c:v', 'libx264', '-preset', 'veryfast',
        '-crf', '18', '-threads', '0',
        if (hasAudio) ...['-t', outDuration],
        actualOutputPath,

        // Output 2: the matte. Silent by design. Audio on both files would
        // double up the moment someone drops the pair into a timeline
        // without muting one.
        '-map', '[matte]',
        '-c:v', 'libx264', '-preset', 'veryfast',
        '-crf', '18', '-threads', '0',
        '-an',
        if (hasAudio) ...['-t', outDuration],
        mattePath!,
      ]);
    } else {
      args.addAll([
        if (hasAudio) ...[
          // This path had no filter_complex before two tracks existed. It
          // needs one now, and adding it means video must be mapped by hand:
          // filter_complex turns off automatic stream selection for the whole
          // command, not just for the streams it touches.
          '-filter_complex', audioGraph,
          '-map', '0:v',
          '-map', '[$audioOutLabel]',
          // pcm is not legal in an .mp4 container; aac is.
          '-c:a', 'aac', '-b:a', '192k',
        ],
        '-c:v', 'libx264', '-preset', 'veryfast',
        '-crf', '18', '-pix_fmt', 'yuv420p',
        '-threads', '0',
        if (hasAudio) ...['-t', outDuration],
        actualOutputPath,
      ]);
    }

    final ReceivePort fromWriter = ReceivePort();
    final Completer<SendPort> portC = Completer<SendPort>();
    final Completer<void> readyC = Completer<void>();
    final Completer<void> doneC = Completer<void>();
    String? writerError;
    int pendingAcks = 0;
    Completer<void>? ackSlot;

    fromWriter.listen((dynamic msg) {
      if (msg is SendPort) {
        if (!portC.isCompleted) portC.complete(msg);
      } else if (msg == 'ready') {
        if (!readyC.isCompleted) readyC.complete();
      } else if (msg == 'ack') {
        pendingAcks--;
        ackSlot?.complete();
        ackSlot = null;
      } else if (msg == 'done') {
        if (!doneC.isCompleted) doneC.complete();
      } else if (msg is String && msg.startsWith('error:')) {
        writerError = msg.substring(6);
        if (!readyC.isCompleted) readyC.complete();
        if (!doneC.isCompleted) doneC.complete();
        ackSlot?.complete();
        ackSlot = null;
      }
    });

    ProgramStructuralFrameRenderer? structuralRenderer;
    if (structuralDocument != null && resolveStructuralSource != null) {
      final ProgramStructuralFrameRenderer candidate =
          ProgramStructuralFrameRenderer(
        rawDocument: structuralDocument,
        width: width,
        height: height,
        backend: structuralBackend ?? NativeMltMediaBackend(),
        resolveSource: resolveStructuralSource,
      );
      if (candidate.hasPlacements) {
        structuralRenderer = candidate;
      } else {
        candidate.dispose();
      }
    }

    final Isolate writerIsolate = await Isolate.spawn(_fifoWriterMain, (fifoPath, fromWriter.sendPort));
    final Process proc = await Process.start('ffmpeg', args);

    bool procDead = false;
    final Completer<int> exitC = Completer<int>();
    unawaited(proc.exitCode.then((int code) {
      procDead = true;
      exitC.complete(code);
    }));

    final StringBuffer errBuf = StringBuffer();
    proc.stderr.transform(utf8.decoder).listen(errBuf.write);

    Future<void> teardown() async {
      structuralRenderer?.dispose();
      try { proc.kill(ProcessSignal.sigterm); } catch (_) {}
      if (!readyC.isCompleted) {
        try {
          final RandomAccessFile r = File(fifoPath).openSync(mode: FileMode.read);
          r.closeSync();
        } catch (_) {}
      }
      writerIsolate.kill(priority: Isolate.immediate);
      fromWriter.close();
      try {
        final File f = File(fifoPath);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }

    final SendPort toWriter = await portC.future;
    final SceneCompositor compositor = SceneCompositor(width: width, height: height);

    onStatus?.call('Rendering Frames...');

    int renderedFrames = 0;
    _InFlightReadback? inFlight;
    final Stopwatch wall = Stopwatch()..start();
    int lastProgressMs = -_progressIntervalMs;

    Future<void> resolveInFlight() async {
      final _InFlightReadback f = inFlight!;
      inFlight = null;

      final ByteData? rawBytes = await f.bytes;
      f.frame.dispose();

      if (rawBytes == null) {
        throw Exception('Failed to extract raw pixels at frame ${f.index}.');
      }
      final Uint8List bytes = rawBytes.buffer.asUint8List(rawBytes.offsetInBytes, rawBytes.lengthInBytes);

      while (pendingAcks >= _maxFramesInFlight && writerError == null) {
        ackSlot = Completer<void>();
        await ackSlot!.future;
      }
      if (writerError != null) {
        throw Exception('Frame writer failed: $writerError\n${errBuf.toString().trim()}');
      }

      toWriter.send(TransferableTypedData.fromList([bytes]));
      pendingAcks++;
      renderedFrames++;

      final int nowMs = wall.elapsedMilliseconds;
      if (nowMs - lastProgressMs >= _progressIntervalMs || renderedFrames == totalFrames) {
        lastProgressMs = nowMs;
        onProgress?.call(renderedFrames, totalFrames);
        await Future<void>(() {}); // Yield event loop
      }
    }

    try {
      await readyC.future;
      if (writerError != null) throw Exception('Writer failed to attach: $writerError');

      for (int i = 0; i < totalFrames; i++) {
        if (cancelToken?.isCancelled ?? false) {
          inFlight?.frame.dispose();
          await teardown();
          return ExportResult(success: false, cancelled: true, framesWritten: renderedFrames, outputPath: actualOutputPath, mattePath: mattePath);
        }
        if (procDead) throw Exception('FFmpeg died during encode (at frame $i)\n${errBuf.toString().trim()}');
        if (writerError != null) throw Exception('Frame writer failed: $writerError\n${errBuf.toString().trim()}');

        // Frame i means ProjectTime(frame: i), exactly as it does in preview.
        // The dry run counted a duration of totalFrames ticks, so the file
        // contains project frames 0 through totalFrames - 1: same duration as
        // before, with no hidden one-frame offset at either end.
        final SceneEvaluationResult evaluation = scene.evaluate(
          ProjectTime(frame: i, mode: ProjectClockMode.scrub),
        );
        if (!evaluation.exact) {
          throw Exception(
              'Scene could not evaluate export frame $i '
              '(reached ${evaluation.reachedFrame}).');
        }

        // STRUCT observes the same already-evaluated SceneEngine frame Preview
        // does. Exact media decode may block here, but it cannot advance the
        // engine or select any project frame other than i.
        final ui.Image? structuralFrame = structuralRenderer == null
            ? null
            : await structuralRenderer.renderIfActive(
                scene: scene,
                fontFamily: fontFamily,
              );

        // Non-STRUCT frames stay on the original terminal SceneCompositor.
        final ui.Image frame = structuralFrame ??
            await compositor.advanceExportAsync(scene, fontFamily);
        final Future<ByteData?> bytesF = frame.toByteData(format: ui.ImageByteFormat.rawRgba);

        if (inFlight != null) await resolveInFlight();
        inFlight = _InFlightReadback(frame, bytesF, i);
      }

      if (inFlight != null) await resolveInFlight();

      toWriter.send(null);
      await doneC.future;
      if (writerError != null) throw Exception('Frame writer failed during close: $writerError');

      onStatus?.call('Finalizing File...');

      while (!exitC.isCompleted) {
        if (cancelToken?.isCancelled ?? false) {
          await teardown();
          return ExportResult(success: false, cancelled: true, framesWritten: renderedFrames, outputPath: actualOutputPath, mattePath: mattePath);
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }

      final int exitCode = await exitC.future;
      if (exitCode != 0) {
        throw Exception('FFmpeg failed with code $exitCode\n${errBuf.toString().trim()}');
      }

      onProgress?.call(totalFrames, totalFrames);

    } catch (e) {
      inFlight?.frame.dispose();
      await teardown();
      return ExportResult(
        success: false, cancelled: false, framesWritten: renderedFrames, outputPath: actualOutputPath, mattePath: mattePath,
        error: e.toString(),
      );
    }

    structuralRenderer?.dispose();
    fromWriter.close();
    try {
      final File f = File(fifoPath);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}

    return ExportResult(success: true, cancelled: false, framesWritten: renderedFrames, outputPath: actualOutputPath, mattePath: mattePath);
  }
}
