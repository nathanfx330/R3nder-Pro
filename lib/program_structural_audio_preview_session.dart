// ./lib/program_structural_audio_preview_session.dart
//
// M21 Stage 5B: prepare and own the full-program STRUCT audio artifact that
// PREVIEW transports.
//
// Stage 5A proved the one-process, one-sink transport. This module closes the
// other half of that boundary: dry-run the already-set-up SceneEngine before
// realtime starts, resolve AUDIO-enabled STRUCT placements in absolute project
// time, render the same source PCM rules BAKE uses, write one temporary float
// WAV, and own its cleanup for the lifetime of a preview run.
//
// Nothing here owns project time. SceneEngine is sampled only while preview is
// still stopped. ProgramStructuralAudioPreviewPlayer opens the native sink only
// after this artifact is complete, so the existing sink remains the sole AUDIO
// ProjectClock authority once realtime begins.

import 'dart:io';

import 'program_structural_audio.dart';
import 'program_structural_audio_preview.dart';
import 'scene_engine.dart';
import 'structural_audio_plan.dart';
import 'structural_audio_render.dart';

/// Exact program facts PREVIEW needs before it may start its audio transport.
///
/// [audioStartFrame] is the same historical workspace-bed anchor BAKE derives:
/// the project frame on which the terminal engine first advances. STRUCT audio
/// itself does not use that anchor because its WAV is already in absolute
/// program time. [bedDelayMs] exists only for voice/music parity with BAKE.
class ProgramStructuralAudioPreviewTiming {
  final int totalFrames;
  final int audioStartFrame;

  const ProgramStructuralAudioPreviewTiming({
    required this.totalFrames,
    required this.audioStartFrame,
  });

  int get programSampleFrames =>
      structuralAudioSamplesForProjectFrames(totalFrames);

  int get bedDelayMs =>
      (audioStartFrame * 1000 / kStructuralAudioProjectFps).round();
}

/// Runs the same frame-count/audio-anchor dry run BAKE performs.
///
/// The caller must invoke this before realtime ProjectClock polling begins.
/// Images remain decoded across [SceneEngine.reset], so this costs scene ticks,
/// not another media load. The scene is reset on both entry and exit, including
/// failure, so preparation cannot leak a hidden playback position into PREVIEW.
ProgramStructuralAudioPreviewTiming measureProgramStructuralAudioPreviewTiming(
  SceneEngine scene,
) {
  scene.reset();
  int totalFrames = 0;
  int audioStartFrame = 0;
  bool terminalHasStarted = false;

  try {
    while (!scene.isFinished) {
      scene.tick();
      totalFrames++;
      if (!terminalHasStarted && scene.terminal.frameCount > 0) {
        terminalHasStarted = true;
        audioStartFrame = scene.frameCount;
      }
    }
  } finally {
    scene.reset();
  }

  return ProgramStructuralAudioPreviewTiming(
    totalFrames: totalFrames,
    audioStartFrame: audioStartFrame,
  );
}

/// Temporary whole-program WAV plus the exact timeline facts that produced it.
class ProgramStructuralAudioPreviewArtifact {
  final String path;
  final ProgramStructuralAudioPreviewTiming timing;
  final ProgramStructuralAudioTimeline timeline;

  const ProgramStructuralAudioPreviewArtifact({
    required this.path,
    required this.timing,
    required this.timeline,
  });

  int get programSampleFrames => timing.programSampleFrames;
  int get bedDelayMs => timing.bedDelayMs;

  void delete() {
    try {
      final File file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // A preview temp is never worth turning shutdown into an exception.
    }
  }
}

/// Builds PREVIEW's ephemeral full-program STRUCT WAV.
///
/// Returns null when the document has no resolved AUDIO-enabled STRUCT
/// placement. That is the fast path which preserves the historical workspace
/// bed player unchanged.
///
/// [tempDirectory] is supplied by the caller rather than guessed here. The app
/// can keep the file beside its workspace while tests can own an isolated temp
/// tree. The fixed per-process filename is safe because R3nder runs one PREVIEW
/// at a time; a stale file from an interrupted run is removed before writing.
Future<ProgramStructuralAudioPreviewArtifact?>
    prepareProgramStructuralAudioPreviewArtifact({
  required SceneEngine scene,
  required String rawDocument,
  required String Function(String source) resolveSource,
  required String tempDirectory,
  StructuralAudioLeafDecodeBackend? leafDecoder,
}) async {
  final ProgramStructuralAudioPreviewTiming timing =
      measureProgramStructuralAudioPreviewTiming(scene);

  final ProgramStructuralAudioTimeline timeline =
      traceProgramStructuralAudioTimeline(
    scene: scene,
    rawDocument: rawDocument,
    totalFrames: timing.totalFrames,
  );

  if (timeline.occurrences.isEmpty) return null;
  if (timing.totalFrames <= 0 || timing.programSampleFrames <= 0) {
    throw const ProgramStructuralAudioException(
      'A STRUCT audio preview cannot own an empty program timeline.',
    );
  }

  final Directory dir = Directory(tempDirectory);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final String tempPath =
      '${dir.path}${Platform.pathSeparator}.r3nder_struct_preview_audio_$pid.wav';
  final File tempFile = File(tempPath);

  try {
    if (tempFile.existsSync()) tempFile.deleteSync();

    final StructuralAudioSourceRenderer sourceRenderer =
        StructuralAudioSourceRenderer(
      planner: StructuralAudioPlanner.parse(rawDocument),
      leafDecoder:
          leafDecoder ?? FfmpegStructuralAudioLeafDecodeBackend(),
      resolveSource: resolveSource,
    );
    final ProgramStructuralAudioRender rendered =
        await ProgramStructuralAudioRenderer(
      timeline: timeline,
      renderSource: sourceRenderer.render,
    ).render();

    if (rendered.sampleFrames != timing.programSampleFrames) {
      throw ProgramStructuralAudioException(
        'Program STRUCT preview rendered ${rendered.sampleFrames} sample '
        'frames; dry-run timing requires ${timing.programSampleFrames}.',
      );
    }

    await rendered.writeWav(tempPath);
    return ProgramStructuralAudioPreviewArtifact(
      path: tempPath,
      timing: timing,
      timeline: timeline,
    );
  } catch (_) {
    try {
      if (tempFile.existsSync()) tempFile.deleteSync();
    } catch (_) {}
    rethrow;
  } finally {
    // Both dry-run helpers reset independently, but keep the ownership rule
    // explicit at this boundary too: callers always receive a frame-zero scene.
    scene.reset();
  }
}

/// Owns PREVIEW's program-audio player and temporary artifact as one lifetime.
///
/// Main can create one of these only when it already has a playback backend.
/// [prepareAndPlay] returns false for documents with no STRUCT audio, allowing
/// the existing AudioBedPlayer path to run untouched. A true result means this
/// session owns the ENTIRE preview mix, including optional voice and music, so a
/// second workspace player must not be started for the same run.
class ProgramStructuralAudioPreviewSession {
  final ProgramStructuralAudioPreviewPlayer player;
  ProgramStructuralAudioPreviewArtifact? _artifact;

  ProgramStructuralAudioPreviewSession({required this.player});

  ProgramStructuralAudioPreviewArtifact? get artifact => _artifact;
  bool get isPlaying => player.isPlaying;

  Future<bool> prepareAndPlay({
    required SceneEngine scene,
    required String rawDocument,
    required String Function(String source) resolveSource,
    required String tempDirectory,
    String? voicePath,
    double voiceGainDb = 0.0,
    String? musicPath,
    double musicGainDb = 0.0,
    bool musicLoop = false,
    String? deviceId,
    StructuralAudioLeafDecodeBackend? leafDecoder,
  }) async {
    await stop();

    final ProgramStructuralAudioPreviewArtifact? prepared =
        await prepareProgramStructuralAudioPreviewArtifact(
      scene: scene,
      rawDocument: rawDocument,
      resolveSource: resolveSource,
      tempDirectory: tempDirectory,
      leafDecoder: leafDecoder,
    );
    if (prepared == null) return false;

    _artifact = prepared;
    try {
      await player.play(
        structuralAudioPath: prepared.path,
        programSampleFrames: prepared.programSampleFrames,
        bedDelayMs: prepared.bedDelayMs,
        voicePath: voicePath,
        voiceGainDb: voiceGainDb,
        musicPath: musicPath,
        musicGainDb: musicGainDb,
        musicLoop: musicLoop,
        deviceId: deviceId,
      );
      return true;
    } catch (_) {
      prepared.delete();
      if (identical(_artifact, prepared)) _artifact = null;
      rethrow;
    }
  }

  Future<void> stop() async {
    final ProgramStructuralAudioPreviewArtifact? old = _artifact;
    _artifact = null;
    try {
      await player.stop();
    } finally {
      old?.delete();
    }
  }

  void dispose() {
    final ProgramStructuralAudioPreviewArtifact? old = _artifact;
    _artifact = null;
    player.dispose();
    old?.delete();
  }
}
