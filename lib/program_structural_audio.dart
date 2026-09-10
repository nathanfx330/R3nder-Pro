// ./lib/program_structural_audio.dart
//
// M21: program-aligned STRUCT clip audio.
//
// structural_audio_render.dart owns one EDIT/MOSAIC source in source-relative
// project time. This file owns the next coordinate system: where AUDIO-enabled
// STRUCT placements land in the whole authored program.
//
// There is deliberately no realtime audio state here. The existing SceneEngine
// is evaluated at explicit ProjectTime values to discover the exact frames on
// which a STRUCT placement is in its showing stage. Source PCM is then copied
// into one full-program 48 kHz stereo float buffer. Terminal typing, desktop
// zooms, window opening/closing, and AUDIO-disabled placements therefore remain
// silence by construction.
//
// Preview and BAKE can later consume the same program WAV. Neither needs to
// infer placement timing again, and ProjectClock remains the only realtime
// authority.

import 'dart:io';
import 'dart:typed_data';

import 'edit_model.dart';
import 'project_clock.dart';
import 'scene_engine.dart';
import 'scene_evaluator.dart';
import 'structural_audio_decode.dart';
import 'structural_audio_plan.dart';
import 'structural_audio_render.dart';
import 'structural_sequence.dart';

const int kProgramStructuralAudioSchemaVersion = 1;

typedef StructuralAudioSourceRenderCallback =
    Future<StructuralAudioSourceRender> Function(String structuralSource);

class ProgramStructuralAudioException implements Exception {
  final String message;

  const ProgramStructuralAudioException(this.message);

  @override
  String toString() => 'ProgramStructuralAudioException: $message';
}

/// One AUDIO-enabled STRUCT placement expressed in absolute project time.
///
/// [programStartFrame] is the first frame of the placement's SHOWING stage,
/// not the beginning of its desktop/window presentation. The source PCM starts
/// at source frame zero there and runs for [sourceDurationFrames].
class ProgramStructuralAudioOccurrence {
  final int placementIndex;
  final StructuralSourceRef sourceRef;
  final int programStartFrame;
  final int sourceDurationFrames;

  const ProgramStructuralAudioOccurrence({
    required this.placementIndex,
    required this.sourceRef,
    required this.programStartFrame,
    required this.sourceDurationFrames,
  });

  int get programStartSample =>
      structuralAudioSampleAtProjectFrame(programStartFrame);

  int get sampleCount =>
      structuralAudioSamplesForProjectFrames(sourceDurationFrames);

  int get programEndFrameExclusive =>
      programStartFrame + sourceDurationFrames;
}

class ProgramStructuralAudioTimeline {
  final int durationFrames;
  final List<ProgramStructuralAudioOccurrence> occurrences;

  ProgramStructuralAudioTimeline({
    required this.durationFrames,
    required List<ProgramStructuralAudioOccurrence> occurrences,
  }) : occurrences =
            List<ProgramStructuralAudioOccurrence>.unmodifiable(occurrences) {
    if (durationFrames < 0) {
      throw ArgumentError.value(
        durationFrames,
        'durationFrames',
        'Program duration must be non-negative.',
      );
    }

    for (final ProgramStructuralAudioOccurrence occurrence in occurrences) {
      if (occurrence.programStartFrame < 0) {
        throw ArgumentError.value(
          occurrence.programStartFrame,
          'programStartFrame',
          'Program audio occurrence must start at or after frame zero.',
        );
      }
      if (occurrence.sourceDurationFrames <= 0) {
        throw ArgumentError.value(
          occurrence.sourceDurationFrames,
          'sourceDurationFrames',
          'Program audio occurrence must own at least one source frame.',
        );
      }
      if (occurrence.programEndFrameExclusive > durationFrames) {
        throw ArgumentError(
          'STRUCT placement ${occurrence.placementIndex} ends at project frame '
          '${occurrence.programEndFrameExclusive}, beyond program duration '
          '$durationFrames.',
        );
      }
    }
  }

  int get durationSamples =>
      structuralAudioSamplesForProjectFrames(durationFrames);
}

class _RuntimeOccurrenceTrace {
  final int programStartFrame;
  int lastProgramFrame;
  int lastSourceFrame;
  int framesSeen;

  _RuntimeOccurrenceTrace({
    required this.programStartFrame,
    required this.lastProgramFrame,
    required this.lastSourceFrame,
    required this.framesSeen,
  });
}

int _runtimeLocalFrame(
  SceneEngine scene,
  StructuralRuntimeMarker marker,
) {
  final terminal = scene.terminal;
  final bool awaitingPauseTag = terminal.activePause == null &&
      terminal.charIndex >= 0 &&
      terminal.charIndex < terminal.text.length &&
      terminal.text.startsWith('[PAUSE:', terminal.charIndex);

  return structuralRuntimeLocalFrame(
    marker: marker,
    pauseFramesRemaining: terminal.pauseFrames,
    awaitingPauseTag: awaitingPauseTag,
  );
}

/// Resolves AUDIO-enabled STRUCT placements into absolute project-frame spans.
///
/// [totalFrames] is the exact program duration already owned by the caller's
/// SceneEngine dry run. The trace samples frames 0 through totalFrames - 1 with
/// the same explicit ProjectTime seam used by Preview and BAKE video.
///
/// Preview and BAKE scenes carry internal STRUCT REGION markers. Editor TEXT
/// scenes deliberately do not, because their compiled projection preserves raw
/// document line ownership for the ribbon. Set [useEditorLineMap] for that
/// second representation. A STRUCT line is already contract-tested to own its
/// complete event duration contiguously, so its first owned project frame is
/// local frame zero and the normal placement geometry remains authoritative.
///
/// The supplied scene is reset before tracing and again before returning, even
/// on failure. No hidden playback position leaks out of audio preparation.
ProgramStructuralAudioTimeline traceProgramStructuralAudioTimeline({
  required SceneEngine scene,
  required String rawDocument,
  required int totalFrames,
  bool useEditorLineMap = false,
}) {
  if (totalFrames < 0) {
    throw ArgumentError.value(
      totalFrames,
      'totalFrames',
      'Program duration must be non-negative.',
    );
  }

  final List<StructuralSequencePlacement> placements =
      parseStructuralSequencePlacements(rawDocument);
  final Set<int> expected = <int>{
    for (int i = 0; i < placements.length; i++)
      if (placements[i].resolves && placements[i].clipAudio) i,
  };
  final Map<int, _RuntimeOccurrenceTrace> traces =
      <int, _RuntimeOccurrenceTrace>{};
  final Map<int, int> placementIndexByLine = useEditorLineMap
      ? <int, int>{
          for (int i = 0; i < placements.length; i++)
            placements[i].lineIndex: i,
        }
      : const <int, int>{};
  final Map<int, int> editorEventStarts = <int, int>{};

  scene.reset();
  try {
    for (int projectFrame = 0; projectFrame < totalFrames; projectFrame++) {
      final SceneEvaluationResult evaluation = scene.evaluate(
        ProjectTime(
          frame: projectFrame,
          mode: ProjectClockMode.scrub,
        ),
      );
      if (!evaluation.exact) {
        throw ProgramStructuralAudioException(
          'Scene could not evaluate project frame $projectFrame while '
          'planning STRUCT audio; reached ${evaluation.reachedFrame}.',
        );
      }

      final StructuralRuntimeMarker? marker =
          parseStructuralRuntimeRegion(scene.terminal.currentRegion);

      int? placementIndex;
      int? localFrame;

      if (marker != null) {
        placementIndex = marker.placementIndex;
        if (placementIndex < 0 || placementIndex >= placements.length) {
          throw ProgramStructuralAudioException(
            'Runtime STRUCT marker references placement $placementIndex, but '
            'the document has ${placements.length} placements.',
          );
        }

        final StructuralSequencePlacement placement =
            placements[placementIndex];
        if (marker.durationFrames != placement.durationFrames) {
          throw ProgramStructuralAudioException(
            'Runtime STRUCT marker $placementIndex owns '
            '${marker.durationFrames} frames, while placement planning owns '
            '${placement.durationFrames}.',
          );
        }
        localFrame = _runtimeLocalFrame(scene, marker);
      } else if (useEditorLineMap) {
        placementIndex =
            placementIndexByLine[scene.terminal.currentRawLine];
        if (placementIndex == null) continue;

        final StructuralSequencePlacement placement =
            placements[placementIndex];
        final int eventStart = editorEventStarts.putIfAbsent(
          placementIndex,
          () => projectFrame,
        );
        localFrame = projectFrame - eventStart;
        if (localFrame < 0 || localFrame >= placement.durationFrames) {
          throw ProgramStructuralAudioException(
            'Editor STRUCT line ${placement.lineIndex} exposed local frame '
            '$localFrame outside placement $placementIndex duration '
            '${placement.durationFrames}.',
          );
        }
      } else {
        continue;
      }

      final StructuralSequencePlacement placement = placements[placementIndex];
      if (!placement.resolves || !placement.clipAudio) continue;

      if (placement.stageAt(localFrame) != StructuralSequenceStage.showing) {
        continue;
      }

      final int sourceFrame = placement.sourceFrameAt(localFrame);
      final _RuntimeOccurrenceTrace? existing = traces[placementIndex];
      if (existing == null) {
        if (sourceFrame != 0) {
          throw ProgramStructuralAudioException(
            'STRUCT placement $placementIndex entered audio at source frame '
            '$sourceFrame instead of source frame zero.',
          );
        }
        traces[placementIndex] = _RuntimeOccurrenceTrace(
          programStartFrame: projectFrame,
          lastProgramFrame: projectFrame,
          lastSourceFrame: sourceFrame,
          framesSeen: 1,
        );
        continue;
      }

      if (projectFrame != existing.lastProgramFrame + 1 ||
          sourceFrame != existing.lastSourceFrame + 1) {
        throw ProgramStructuralAudioException(
          'STRUCT placement $placementIndex audio is not contiguous: '
          'project $projectFrame/source $sourceFrame followed '
          'project ${existing.lastProgramFrame}/source '
          '${existing.lastSourceFrame}.',
        );
      }

      existing.lastProgramFrame = projectFrame;
      existing.lastSourceFrame = sourceFrame;
      existing.framesSeen++;
    }
  } finally {
    scene.reset();
  }

  final List<ProgramStructuralAudioOccurrence> occurrences =
      <ProgramStructuralAudioOccurrence>[];
  for (final int placementIndex in expected) {
    final StructuralSequencePlacement placement = placements[placementIndex];
    final _RuntimeOccurrenceTrace? trace = traces[placementIndex];
    if (trace == null) {
      throw ProgramStructuralAudioException(
        'AUDIO-enabled STRUCT placement $placementIndex never reached its '
        'showing stage inside the $totalFrames-frame program.',
      );
    }
    if (trace.framesSeen != placement.sourceDurationFrames ||
        trace.lastSourceFrame != placement.sourceDurationFrames - 1) {
      throw ProgramStructuralAudioException(
        'STRUCT placement $placementIndex exposed ${trace.framesSeen} source '
        'frames through runtime, but the source owns '
        '${placement.sourceDurationFrames}.',
      );
    }

    occurrences.add(
      ProgramStructuralAudioOccurrence(
        placementIndex: placementIndex,
        sourceRef: placement.sourceRef,
        programStartFrame: trace.programStartFrame,
        sourceDurationFrames: placement.sourceDurationFrames,
      ),
    );
  }

  occurrences.sort((a, b) {
    final int byFrame = a.programStartFrame.compareTo(b.programStartFrame);
    return byFrame != 0
        ? byFrame
        : a.placementIndex.compareTo(b.placementIndex);
  });

  return ProgramStructuralAudioTimeline(
    durationFrames: totalFrames,
    occurrences: occurrences,
  );
}

class ProgramStructuralAudioRender {
  final ProgramStructuralAudioTimeline timeline;
  final Float32List interleavedStereo;

  const ProgramStructuralAudioRender({
    required this.timeline,
    required this.interleavedStereo,
  });

  int get sampleFrames =>
      interleavedStereo.length ~/ kStructuralAudioChannels;

  Uint8List toWavBytes() => structuralAudioFloatWav(interleavedStereo);

  Future<void> writeWav(String outputPath) async {
    await File(outputPath).writeAsBytes(toWavBytes(), flush: true);
  }
}

/// Assembles source-relative EDIT/MOSAIC renders into one program-time bed.
///
/// The same source is rendered at most once per call even when several STRUCT
/// placements reference it. Persistent reuse belongs to the later cache stage;
/// this memo is intentionally process-local and cannot become stale on disk.
class ProgramStructuralAudioRenderer {
  final ProgramStructuralAudioTimeline timeline;
  final StructuralAudioSourceRenderCallback renderSource;

  const ProgramStructuralAudioRenderer({
    required this.timeline,
    required this.renderSource,
  });

  Future<ProgramStructuralAudioRender> render() async {
    final Float32List output = Float32List(
      timeline.durationSamples * kStructuralAudioChannels,
    );
    final Map<String, Future<StructuralAudioSourceRender>> memo =
        <String, Future<StructuralAudioSourceRender>>{};

    for (final ProgramStructuralAudioOccurrence occurrence
        in timeline.occurrences) {
      final String source = occurrence.sourceRef.canonicalSource;
      final Future<StructuralAudioSourceRender> pending = memo.putIfAbsent(
        source,
        () => renderSource(source),
      );
      final StructuralAudioSourceRender rendered = await pending;

      if (rendered.plan.sourceRef != occurrence.sourceRef) {
        throw ProgramStructuralAudioException(
          'Requested $source but source renderer returned '
          '${rendered.plan.sourceRef.canonicalSource}.',
        );
      }
      if (rendered.plan.durationFrames != occurrence.sourceDurationFrames ||
          rendered.sampleFrames != occurrence.sampleCount) {
        throw ProgramStructuralAudioException(
          'Source render $source owns ${rendered.plan.durationFrames} frames '
          'and ${rendered.sampleFrames} samples; placement '
          '${occurrence.placementIndex} requires '
          '${occurrence.sourceDurationFrames} frames and '
          '${occurrence.sampleCount} samples.',
        );
      }

      _mixOccurrence(output, occurrence, rendered.interleavedStereo);
    }

    return ProgramStructuralAudioRender(
      timeline: timeline,
      interleavedStereo: output,
    );
  }
}

void _mixOccurrence(
  Float32List destination,
  ProgramStructuralAudioOccurrence occurrence,
  Float32List source,
) {
  final int destinationStart =
      occurrence.programStartSample * kStructuralAudioChannels;
  if (destinationStart < 0 ||
      destinationStart + source.length > destination.length) {
    throw ProgramStructuralAudioException(
      'STRUCT placement ${occurrence.placementIndex} does not fit inside the '
      'program audio buffer.',
    );
  }

  for (int i = 0; i < source.length; i++) {
    // Float32List assignment deliberately rounds after every addition. If two
    // placements ever overlap in a future main-sequence model, their sum is
    // still deterministic and follows occurrence order.
    destination[destinationStart + i] =
        destination[destinationStart + i] + source[i];
  }
}
