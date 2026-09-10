// ./lib/edit_source_audio_preview.dart
//
// Deterministic source-audio audition for the EDIT/MOSAIC authoring transport.
//
// EDIT playback is source-relative, not program-relative. The selected
// structural source is rendered with the same StructuralAudioSourceRenderer
// used by program Preview and BAKE, written to a temporary IEEE-float WAV,
// then handed to the proven one-process/one-sink preview transport.
//
// This object owns no ProjectClock. EditWorkspace parks the authoritative
// clock on the authored playhead before calling play(). On libpulse the native
// sink performs the AUDIO handoff once audible PCM reaches the device. On the
// aplay fallback EditWorkspace resumes MONOTONIC after play() returns.
//
// Source authoring deliberately ignores the later STRUCT placement AUDIO flag:
// while editing EDIT.main or MOSAIC.wall, its clip audio is always auditioned.
// The AUDIO token only decides whether a placement contributes that source mix
// to TEXT/program Preview and BAKE.

import 'dart:io';

import 'program_structural_audio_preview.dart';
import 'structural_audio_plan.dart';
import 'structural_audio_render.dart';

abstract interface class EditSourceAudioPreviewTransport {
  bool get isPlaying;

  Future<bool> play({
    required String rawDocument,
    required String structuralSource,
    required int startFrame,
    required String Function(String source) resolveSource,
    String? deviceId,
  });

  Future<void> stop();

  void dispose();
}

typedef EditSourceAudioPreviewFactory = EditSourceAudioPreviewTransport Function(
  String backendName,
);

EditSourceAudioPreviewTransport createEditSourceAudioPreview(
  String backendName,
) {
  return DeterministicEditSourceAudioPreview(backendName: backendName);
}

class DeterministicEditSourceAudioPreview
    implements EditSourceAudioPreviewTransport {
  final ProgramStructuralAudioPreviewPlayer _player;
  String? _artifactPath;
  int _generation = 0;
  bool _disposed = false;

  DeterministicEditSourceAudioPreview({required String backendName})
      : _player = ProgramStructuralAudioPreviewPlayer.forBackendName(
          backendName,
        );

  @override
  bool get isPlaying => !_disposed && _player.isPlaying;

  @override
  Future<bool> play({
    required String rawDocument,
    required String structuralSource,
    required int startFrame,
    required String Function(String source) resolveSource,
    String? deviceId,
  }) async {
    if (_disposed) {
      throw StateError('EDIT source audio preview has been disposed.');
    }
    if (startFrame < 0) {
      throw ArgumentError.value(
        startFrame,
        'startFrame',
        'EDIT source audio start frame cannot be negative.',
      );
    }

    final int generation = ++_generation;
    await _player.stop();
    _deleteArtifact();

    final StructuralAudioSourceRenderer renderer = StructuralAudioSourceRenderer(
      planner: StructuralAudioPlanner.parse(rawDocument),
      leafDecoder: FfmpegStructuralAudioLeafDecodeBackend(),
      resolveSource: resolveSource,
    );
    final StructuralAudioSourceRender rendered =
        await renderer.render(structuralSource);
    if (_disposed || generation != _generation) return false;

    final int startSample = structuralAudioSampleAtProjectFrame(startFrame);
    if (rendered.sampleFrames <= 0 || startSample >= rendered.sampleFrames) {
      return false;
    }

    final String path = '${Directory.systemTemp.path}${Platform.pathSeparator}'
        '.r3nder_edit_source_audio_${identityHashCode(this)}_${pid}_$generation.wav';
    final File file = File(path);
    if (file.existsSync()) file.deleteSync();
    await file.writeAsBytes(rendered.toWavBytes(), flush: true);
    if (_disposed || generation != _generation) {
      try {
        if (file.existsSync()) file.deleteSync();
      } catch (_) {}
      return false;
    }
    _artifactPath = path;

    try {
      await _player.play(
        structuralAudioPath: path,
        programSampleFrames: rendered.sampleFrames,
        bedDelayMs: 0,
        startSampleFrame: startSample,
        deviceId: deviceId,
      );
    } catch (_) {
      if (generation == _generation) _deleteArtifact();
      rethrow;
    }

    if (_disposed || generation != _generation) {
      await _player.stop();
      return false;
    }
    return _player.isPlaying;
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    _generation++;
    try {
      await _player.stop();
    } finally {
      _deleteArtifact();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _player.dispose();
    _deleteArtifact();
  }

  void _deleteArtifact() {
    final String? path = _artifactPath;
    _artifactPath = null;
    if (path == null) return;
    try {
      final File file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }
}
