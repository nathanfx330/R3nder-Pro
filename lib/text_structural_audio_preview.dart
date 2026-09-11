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
//
// SEEK / REPLAY ORDERING IS LOAD-BEARING. Cursor jumps stop the old transport
// asynchronously, but the editor can move the picture and request another PLAY
// before that teardown finishes. A stale pause completion must never seek the
// shared ProjectClock back to the old frame after the new run has anchored it.
// New starts therefore invalidate stale stop callbacks and wait for any old sink
// teardown to complete before opening the replacement sink.

import 'dart:io';

import 'audio_bed.dart';
import 'program_structural_audio_preview_session.dart';
import 'project_clock.dart';
import 'scene_engine.dart';
import 'structural_audio_plan.dart';
import 'structural_sequence.dart';

class TextStructuralAudioPreview {
  ProgramStructuralAudioPreviewSession? _session;
  String? _backendName;
  String? _preparedDocument;
  bool _disposed = false;

  /// Monotonic ownership token for transport operations.
  ///
  /// PAUSE/INVALIDATE capture the generation they started under. If a later
  /// PLAY begins before their async sink teardown completes, that later PLAY
  /// increments this value and the stale completion is forbidden from writing
  /// its old hold frame back into the shared ProjectClock.
  int _transportGeneration = 0;

  /// Native sink teardown currently in flight.
  ///
  /// PLAY waits for this before opening its replacement sink. That keeps two
  /// generations from overlapping at the device boundary and, just as
  /// importantly, guarantees the new sink captures the new authored playhead
  /// rather than a clock point still being released by the old sink.
  Future<void>? _pendingTransportStop;

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

  bool _operationIsCurrent(int generation) =>
      !_disposed && generation == _transportGeneration;

  Future<bool> prepareAndPlay({
    required SceneEngine scene,
    required String rawDocument,
    required List<int> editorRawLineAtFrame,
    required int startFrame,
    required AudioBedPlayer backend,
    required String Function(String source) resolveSource,
    required String? voicePath,
    required double voiceGainDb,
    required String? musicPath,
    required double musicGainDb,
    required bool musicLoop,
    void Function()? onPrepared,
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

    // Claim the newest transport generation BEFORE waiting for an old pause.
    // That immediately makes the old pause's eventual clock write stale.
    final int generation = ++_transportGeneration;
    final Future<void>? pendingStop = _pendingTransportStop;
    if (pendingStop != null) {
      await pendingStop;
      if (!_operationIsCurrent(generation)) return false;
    }

    final ProgramStructuralAudioPreviewSession session =
        _ensureSession(backend.backendName);

    if (_preparedDocument != rawDocument || !session.isPrepared) {
      final bool prepared = await session.prepare(
        scene: scene,
        rawDocument: rawDocument,
        resolveSource: resolveSource,
        tempDirectory: Directory.systemTemp.path,
        editorRawLineAtFrame: editorRawLineAtFrame,
      );
      if (!_operationIsCurrent(generation)) return false;
      if (!prepared) {
        _preparedDocument = null;
        return false;
      }
      _preparedDocument = rawDocument;

      // Preparation deliberately resets SceneEngine to frame zero. Give the
      // TEXT owner one synchronous seam to restore its authored picture state
      // before the realtime sink is allowed to start. Otherwise a resume from
      // a later playhead can spend deterministic replay time while audio is
      // already advancing.
      onPrepared?.call();
    }

    if (!_operationIsCurrent(generation)) return false;

    final ProgramStructuralAudioPreviewArtifact? artifact = session.artifact;
    if (artifact == null) return false;

    final int startSample = structuralAudioSampleAtProjectFrame(startFrame);
    if (startSample >= artifact.programSampleFrames) return false;

    // TEXT borrows the application's one realtime ProjectClock. Anchor that
    // clock at the authored editor playhead only AFTER the previous transport
    // has fully torn down. The libpulse sink captures this exact point, holds
    // it through prefill, then releases the same point under AUDIO authority
    // when PCM is audible.
    final NativeRealtimeProjectClock? clock = sharedRealtimeProjectClock;
    clock?.seekScrub(
      ProjectTime(
        frame: startFrame,
        mode: ProjectClockMode.scrub,
      ),
    );

    try {
      await session.playPrepared(
        startSampleFrame: startSample,
        voicePath: voicePath,
        voiceGainDb: voiceGainDb,
        musicPath: musicPath,
        musicGainDb: musicGainDb,
        musicLoop: musicLoop,
        deviceId: deviceId,
      );
    } catch (_) {
      // A failed transport must not strand the shared application clock in
      // SCRUB. Keep the historical no-STRUCT fallback able to run immediately.
      if (_operationIsCurrent(generation)) {
        clock?.seekMonotonic(ProjectTime(frame: startFrame));
      }
      rethrow;
    }

    if (!_operationIsCurrent(generation)) return false;

    // aplay has no native ProjectClock handoff. Start its picture authority
    // from the same authored point immediately after the process is live.
    if (backend.backendName != 'libpulse') {
      clock?.seekMonotonic(ProjectTime(frame: startFrame));
    }

    return session.isPlaying;
  }

  Future<void> pause({int? holdFrame}) async {
    if (_disposed) return;

    final int generation = ++_transportGeneration;
    final ProgramStructuralAudioPreviewSession? session = _session;
    final Future<void> stopping = session?.pausePrepared() ?? Future<void>.value();
    _pendingTransportStop = stopping;

    try {
      await stopping;

      // Native sink teardown releases AUDIO to MONOTONIC. TEXT pause is an
      // authored hold, so reassert the visible frame after teardown completes.
      // But only the newest operation may touch the clock: a cursor jump can
      // already have started another PLAY while this stop was in flight.
      if (holdFrame != null && _operationIsCurrent(generation)) {
        sharedRealtimeProjectClock?.seekScrub(
          ProjectTime(
            frame: holdFrame,
            mode: ProjectClockMode.scrub,
          ),
        );
      }
    } finally {
      if (identical(_pendingTransportStop, stopping)) {
        _pendingTransportStop = null;
      }
    }
  }

  Future<void> invalidate({int? holdFrame}) async {
    if (_disposed) return;

    _preparedDocument = null;
    final int generation = ++_transportGeneration;
    final ProgramStructuralAudioPreviewSession? session = _session;
    final Future<void> stopping = session?.stop() ?? Future<void>.value();
    _pendingTransportStop = stopping;

    try {
      await stopping;
      if (holdFrame != null && _operationIsCurrent(generation)) {
        sharedRealtimeProjectClock?.seekScrub(
          ProjectTime(
            frame: holdFrame,
            mode: ProjectClockMode.scrub,
          ),
        );
      }
    } finally {
      if (identical(_pendingTransportStop, stopping)) {
        _pendingTransportStop = null;
      }
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _transportGeneration++;
    _pendingTransportStop = null;
    _preparedDocument = null;
    _session?.dispose();
    _session = null;
    _backendName = null;
  }
}
