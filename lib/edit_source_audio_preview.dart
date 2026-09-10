// ./lib/edit_source_audio_preview.dart
//
// Deterministic source-audio audition for the EDIT/MOSAIC authoring transport.
//
// EDIT playback is source-relative, not program-relative. The selected
// structural source is rendered with the same StructuralAudioSourceRenderer
// used by program Preview and BAKE, written to a temporary IEEE-float WAV,
// then handed to the proven one-process/one-sink preview transport.
//
// Rendering source PCM is intentionally separate from transport restart. The
// prepared WAV stays alive across PLAY/PAUSE while the authored document and
// selected structural source are unchanged. Scrubbing therefore restarts from
// an exact sample inside the already-rendered source instead of decoding and
// composing the entire EDIT/MOSAIC again on every press of PLAY. Any document
// or source change invalidates the artifact; dispose always removes it.
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
  String? _artifactDocument;
  String? _artifactSource;
  int _artifactSampleFrames = 0;
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

    final _PreparedEditSourceAudio? prepared = await _ensureArtifact(
      generation: generation,
      rawDocument: rawDocument,
      structuralSource: structuralSource,
      resolveSource: resolveSource,
    );
    if (prepared == null || _disposed || generation != _generation) {
      return false;
    }

    final int startSample = structuralAudioSampleAtProjectFrame(startFrame);
    if (startSample >= prepared.sampleFrames) return false;

    await _player.play(
      structuralAudioPath: prepared.path,
      programSampleFrames: prepared.sampleFrames,
      bedDelayMs: 0,
      startSampleFrame: startSample,
      deviceId: deviceId,
    );

    if (_disposed || generation != _generation) {
      await _player.stop();
      return false;
    }
    return _player.isPlaying;
  }

  Future<_PreparedEditSourceAudio?> _ensureArtifact({
    required int generation,
    required String rawDocument,
    required String structuralSource,
    required String Function(String source) resolveSource,
  }) async {
    final String? cachedPath = _artifactPath;
    if (_artifactDocument == rawDocument &&
        _artifactSource == structuralSource &&
        _artifactSampleFrames > 0 &&
        cachedPath != null &&
        File(cachedPath).existsSync()) {
      return _PreparedEditSourceAudio(
        path: cachedPath,
        sampleFrames: _artifactSampleFrames,
      );
    }

    _deleteArtifact();

    final StructuralAudioSourceRenderer renderer = StructuralAudioSourceRenderer(
      planner: StructuralAudioPlanner.parse(rawDocument),
      leafDecoder: FfmpegStructuralAudioLeafDecodeBackend(),
      resolveSource: resolveSource,
    );
    final StructuralAudioSourceRender rendered =
        await renderer.render(structuralSource);
    if (_disposed || generation != _generation) return null;
    if (rendered.sampleFrames <= 0) return null;

    final String path = '${Directory.systemTemp.path}${Platform.pathSeparator}'
        '.r3nder_edit_source_audio_${identityHashCode(this)}_$pid.wav';
    final File file = File(path);
    if (file.existsSync()) file.deleteSync();
    await file.writeAsBytes(rendered.toWavBytes(), flush: true);
    if (_disposed || generation != _generation) {
      try {
        if (file.existsSync()) file.deleteSync();
      } catch (_) {}
      return null;
    }

    _artifactPath = path;
    _artifactDocument = rawDocument;
    _artifactSource = structuralSource;
    _artifactSampleFrames = rendered.sampleFrames;
    return _PreparedEditSourceAudio(
      path: path,
      sampleFrames: rendered.sampleFrames,
    );
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    _generation++;
    // Stop only the realtime transport. The deterministic source WAV is the
    // expensive part and remains valid until the authored source changes.
    await _player.stop();
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
    _artifactDocument = null;
    _artifactSource = null;
    _artifactSampleFrames = 0;
    if (path == null) return;
    try {
      final File file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }
}

class _PreparedEditSourceAudio {
  final String path;
  final int sampleFrames;

  const _PreparedEditSourceAudio({
    required this.path,
    required this.sampleFrames,
  });
}
