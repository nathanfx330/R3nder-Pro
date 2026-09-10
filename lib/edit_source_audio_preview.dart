// ./lib/edit_source_audio_preview.dart
//
// Deterministic source-audio audition for the EDIT/MOSAIC authoring transport.
//
// EDIT playback is source-relative, not program-relative. The selected
// structural source is rendered with the same StructuralAudioSourceRenderer
// used by program Preview and BAKE, then handed to the proven one-process / one-
// sink preview transport.
//
// The expensive source render is content-addressed and persisted inside the
// active workspace. Repeated PLAY presses and later application runs therefore
// reuse the same whole-source WAV as long as authored source geometry, resolved
// leaf metadata, renderer policy, and ffmpeg identity are unchanged.
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

import 'edit_media_import.dart';
import 'program_structural_audio_preview.dart';
import 'structural_audio_cache.dart';
import 'structural_audio_plan.dart';

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
  StructuralSourceAudioCache? _cache;
  String? _cacheWorkspaceRoot;
  String Function(String source)? _cacheResolver;
  int _generation = 0;
  bool _disposed = false;

  DeterministicEditSourceAudioPreview({required String backendName})
      : _player = ProgramStructuralAudioPreviewPlayer.forBackendName(
          backendName,
        );

  @override
  bool get isPlaying => !_disposed && _player.isPlaying;

  StructuralSourceAudioCache _ensureCache(
    String workspaceRoot,
    String Function(String source) resolveSource,
  ) {
    final StructuralSourceAudioCache? existing = _cache;
    if (existing != null &&
        _cacheWorkspaceRoot == workspaceRoot &&
        identical(_cacheResolver, resolveSource)) {
      return existing;
    }

    final StructuralSourceAudioCache created = StructuralSourceAudioCache.ffmpeg(
      workspaceRoot: workspaceRoot,
      resolveSource: resolveSource,
    );
    _cache = created;
    _cacheWorkspaceRoot = workspaceRoot;
    _cacheResolver = resolveSource;
    return created;
  }

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

    final String workspaceRoot = resolveActiveWorkspaceRoot();
    final StructuralSourceAudioCache cache =
        _ensureCache(workspaceRoot, resolveSource);
    final StructuralSourceAudioArtifact artifact = await cache.prepare(
      rawDocument: rawDocument,
      structuralSource: structuralSource,
    );
    if (_disposed || generation != _generation) return false;

    final int startSample = structuralAudioSampleAtProjectFrame(startFrame);
    if (artifact.sampleFrames <= 0 || startSample >= artifact.sampleFrames) {
      return false;
    }

    await _player.play(
      structuralAudioPath: artifact.path,
      programSampleFrames: artifact.sampleFrames,
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

  @override
  Future<void> stop() async {
    if (_disposed) return;
    _generation++;
    await _player.stop();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _player.dispose();
    _cache = null;
    _cacheWorkspaceRoot = null;
    _cacheResolver = null;
  }
}
