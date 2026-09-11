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
// still stopped. Preparation and playback are deliberately separate operations:
// Main must reset ProjectClock to project zero AFTER the dry run and BEFORE the
// native sink opens. That ordering lets NativeAudioSink hold exactly frame zero
// through device open and decoder prefill, then release the same authored point
// under AUDIO authority.

import 'dart:io';

import 'program_structural_audio.dart';
import 'program_structural_audio_preview.dart';
import 'scene_engine.dart';
import 'structural_audio_plan.dart';
import 'structural_audio_render.dart';
import 'structural_sequence.dart';

/// One process can own more than one preview session at once: dashboard PREVIEW
/// lives at app level while TEXT authoring owns its own prepared/replay session.
/// A PID-only temp name therefore aliases two independent artifacts. Keep a
/// process-local serial in the filename so one session can never overwrite or
/// delete another session's prepared program WAV.
int _programStructuralPreviewArtifactSerial = 0;

String _nextProgramStructuralPreviewArtifactPath(String tempDirectory) {
  final int serial = _programStructuralPreviewArtifactSerial++;
  return '$tempDirectory${Platform.pathSeparator}'
      '.r3nder_struct_preview_audio_${pid}_$serial.wav';
}

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
/// placement. That check happens before the timing dry run, so ordinary
/// previews that do not opt into clip audio retain the historical startup cost
/// rather than simulating the whole piece just to rediscover that there is
/// nothing to render.
///
/// Dashboard PREVIEW and BAKE-style scenes carry internal STRUCT REGION markers.
/// TEXT authoring instead supplies [editorRawLineAtFrame], the exact frame map
/// already produced by runEditorSimulation and already used by the editor's
/// picture preview. [useEditorLineMap] remains for tests/compatibility when only
/// an editor-marked SceneEngine is available.
///
/// [tempDirectory] is supplied by the caller rather than guessed here. The app
/// can use the operating-system temp directory while tests own an isolated temp
/// tree. Every preparation gets its own filename. Dashboard PREVIEW and TEXT
/// authoring are separate session owners and may overlap in lifetime even when
/// only one of them is actively audible, so a PID-only filename is not safe.
Future<ProgramStructuralAudioPreviewArtifact?>
    prepareProgramStructuralAudioPreviewArtifact({
  required SceneEngine scene,
  required String rawDocument,
  required String Function(String source) resolveSource,
  required String tempDirectory,
  StructuralAudioLeafDecodeBackend? leafDecoder,
  bool useEditorLineMap = false,
  List<int>? editorRawLineAtFrame,
}) async {
  final bool hasAudioPlacement = parseStructuralSequencePlacements(rawDocument)
      .any((StructuralSequencePlacement placement) =>
          placement.resolves && placement.clipAudio);
  if (!hasAudioPlacement) {
    scene.reset();
    return null;
  }

  final ProgramStructuralAudioPreviewTiming timing =
      measureProgramStructuralAudioPreviewTiming(scene);

  final ProgramStructuralAudioTimeline timeline =
      traceProgramStructuralAudioTimeline(
    scene: scene,
    rawDocument: rawDocument,
    totalFrames: timing.totalFrames,
    useEditorLineMap: useEditorLineMap,
    editorRawLineAtFrame: editorRawLineAtFrame,
  );

  if (timeline.occurrences.isEmpty) return null;
  if (timing.totalFrames <= 0 || timing.programSampleFrames <= 0) {
    throw const ProgramStructuralAudioException(
      'A STRUCT audio preview cannot own an empty program timeline.',
    );
  }

  final Directory dir = Directory(tempDirectory);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final String tempPath = _nextProgramStructuralPreviewArtifactPath(dir.path);
  final File tempFile = File(tempPath);

  try {
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
/// [prepare] performs every expensive deterministic step while realtime is
/// stopped. The caller then resets ProjectClock to the intended authored start
/// and calls [playPrepared]. This split is load-bearing: opening NativeAudioSink
/// itself captures and holds the active ProjectClock point.
///
/// A false [prepare] result means there is no STRUCT clip audio, so Main should
/// keep using the historical AudioBedPlayer path. Once [playPrepared] succeeds,
/// this session owns the ENTIRE preview mix, including optional voice and music,
/// and a second workspace player must not start for that run.
class ProgramStructuralAudioPreviewSession {
  final ProgramStructuralAudioPreviewPlayer player;
  ProgramStructuralAudioPreviewArtifact? _artifact;

  ProgramStructuralAudioPreviewSession({required this.player});

  factory ProgramStructuralAudioPreviewSession.forBackendName(
    String backendName,
  ) {
    return ProgramStructuralAudioPreviewSession(
      player: ProgramStructuralAudioPreviewPlayer.forBackendName(backendName),
    );
  }

  ProgramStructuralAudioPreviewArtifact? get artifact => _artifact;
  bool get isPrepared => _artifact != null;
  bool get isPlaying => player.isPlaying;

  Future<bool> prepare({
    required SceneEngine scene,
    required String rawDocument,
    required String Function(String source) resolveSource,
    required String tempDirectory,
    StructuralAudioLeafDecodeBackend? leafDecoder,
    bool useEditorLineMap = false,
    List<int>? editorRawLineAtFrame,
  }) async {
    await stop();

    final ProgramStructuralAudioPreviewArtifact? prepared =
        await prepareProgramStructuralAudioPreviewArtifact(
      scene: scene,
      rawDocument: rawDocument,
      resolveSource: resolveSource,
      tempDirectory: tempDirectory,
      leafDecoder: leafDecoder,
      useEditorLineMap: useEditorLineMap,
      editorRawLineAtFrame: editorRawLineAtFrame,
    );
    _artifact = prepared;
    return prepared != null;
  }

  Future<void> playPrepared({
    int startSampleFrame = 0,
    String? voicePath,
    double voiceGainDb = 0.0,
    String? musicPath,
    double musicGainDb = 0.0,
    bool musicLoop = false,
    String? deviceId,
  }) async {
    final ProgramStructuralAudioPreviewArtifact? prepared = _artifact;
    if (prepared == null) {
      throw const ProgramStructuralAudioPreviewException(
        'Program STRUCT preview playback was requested before preparation.',
      );
    }

    try {
      await player.play(
        structuralAudioPath: prepared.path,
        programSampleFrames: prepared.programSampleFrames,
        bedDelayMs: prepared.bedDelayMs,
        startSampleFrame: startSampleFrame,
        voicePath: voicePath,
        voiceGainDb: voiceGainDb,
        musicPath: musicPath,
        musicGainDb: musicGainDb,
        musicLoop: musicLoop,
        deviceId: deviceId,
      );
    } catch (_) {
      prepared.delete();
      if (identical(_artifact, prepared)) _artifact = null;
      rethrow;
    }
  }

  /// Stop realtime delivery but retain the already rendered program artifact.
  ///
  /// TEXT authoring uses this on PAUSE so repeated PLAY presses can seek into
  /// the same deterministic WAV instead of rebuilding the entire program. Main
  /// PREVIEW continues to use [stop], which also releases the temp artifact.
  Future<void> pausePrepared() async {
    await player.stop();
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
