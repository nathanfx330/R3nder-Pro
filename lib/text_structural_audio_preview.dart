// ./lib/text_structural_audio_preview.dart
//
// TEXT-mode owner for AUDIO-enabled structural program playback.
//
// TEXT previews the authored program, not an isolated EDIT/MOSAIC source.
// Therefore clip audio is present only when the STRUCT placement carries the
// AUDIO token. The deterministic whole-program artifact and realtime transport
// are the same ones used by dashboard PREVIEW. This coordinator only adds the
// editor-specific lifetime rule: PAUSE stops the realtime transport but keeps a
// prepared artifact alive so replaying the unchanged document does not render
// the whole program again.

import 'dart:io';

import 'audio_bed.dart';
import 'program_structural_audio_preview_session.dart';
import 'scene_engine.dart';
import 'structural_audio_plan.dart';
import 'structural_sequence.dart';

export 'edit_video_preview.dart' show resolveWorkspaceMediaSource;

class TextStructuralAudioPreview {
  ProgramStructuralAudioPreviewSession? _session;
  String? _backendName;
  String? _preparedDocument;
  bool _disposed = false;

  bool get isPrepared => !_disposed && (_session?.isPrepared ?? false);
  bool get isPlaying => !_disposed && (_session?.isPlaying ?? false);

  bool documentHasClipAudio(String rawDocument) {
    return parseStructuralSequencePlacements(rawDocument).any(
      (StructuralSequencePlacement placement) =>
          placement.resolves && placement.clipAudio,
    );
  }

  ProgramStructuralAudioPreviewSession _ensureSession(String backendName) {
    final ProgramStructuralAudioPreviewSession? existing = _session;
    if (existing != null && _backendName == backendName) return existing;

    existing?.dispose();
    final ProgramStructuralAudioPreviewSession created =
        ProgramStructuralAudioPreviewSession.forBackendName(backendName);
    _session = created;
    _backendName = backendName;
    _preparedDocument = null;
    return created;
  }

  Future<bool> prepareAndPlay({
    required SceneEngine scene,
    required String rawDocument,
    required int startFrame,
    required AudioBedPlayer backend,
    required String Function(String source) resolveSource,
    required String? voicePath,
    required double voiceGainDb,
    required String? musicPath,
    required double musicGainDb,
    required bool musicLoop,
    String? deviceId,
  }) async {
    if (_disposed) {
      throw StateError('TEXT structural audio preview has been disposed.');
    }
    if (startFrame < 0) {
      throw ArgumentError.value(
        startFrame,
        'startFrame',
        'TEXT audio start frame cannot be negative.',
      );
    }
    if (!documentHasClipAudio(rawDocument)) return false;

    final ProgramStructuralAudioPreviewSession session =
        _ensureSession(backend.backendName);

    if (_preparedDocument != rawDocument || !session.isPrepared) {
      final bool prepared = await session.prepare(
        scene: scene,
        rawDocument: rawDocument,
        resolveSource: resolveSource,
        tempDirectory: Directory.systemTemp.path,
      );
      if (!prepared) {
        _preparedDocument = null;
        return false;
      }
      _preparedDocument = rawDocument;
    }

    final ProgramStructuralAudioPreviewArtifact? artifact = session.artifact;
    if (artifact == null) return false;

    final int startSample = structuralAudioSampleAtProjectFrame(startFrame);
    if (startSample >= artifact.programSampleFrames) return false;

    await session.playPrepared(
      startSampleFrame: startSample,
      voicePath: voicePath,
      voiceGainDb: voiceGainDb,
      musicPath: musicPath,
      musicGainDb: musicGainDb,
      musicLoop: musicLoop,
      deviceId: deviceId,
    );
    return session.isPlaying;
  }

  Future<void> pause() async {
    if (_disposed) return;
    await _session?.pausePrepared();
  }

  Future<void> invalidate() async {
    if (_disposed) return;
    _preparedDocument = null;
    await _session?.stop();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _preparedDocument = null;
    _session?.dispose();
    _session = null;
    _backendName = null;
  }
}
