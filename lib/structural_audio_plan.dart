// ./lib/structural_audio_plan.dart
//
// M21 Stage 1A: pure structural-audio geometry.
//
// This file deliberately knows nothing about ffmpeg, MLT, files, Flutter,
// playback, or export. It converts canonical EDIT/MOSAIC authored state into
// exact project/sample geometry that later stages may render.
//
// The contract is intentionally narrow:
//
//   * project time is integer frames at 30 fps;
//   * structural audio is canonical 48 kHz stereo later in the pipeline;
//   * therefore one authored project frame is exactly 1600 samples;
//   * clip AT, duration, fade boundaries, and source placement are derived
//     from frame integers, never accumulated from seconds;
//   * speed stays exact rational state;
//   * leaf media is not probed here, so every authored video clip remains in
//     the plan even when a later probe discovers that it has no audio stream;
//   * structural sources recurse as structural plans and are never treated as
//     filesystem media;
//   * only authored CROSSFADE edge directives become audio fades. Luma is a
//     picture transition and does not silently acquire audio semantics here.
//
// Equal-power fade samples use the midpoint convention:
//
//   t = (i + 0.5) / N
//   fade out = cos(t * pi / 2)
//   fade in  = sin(t * pi / 2)
//
// Midpoints avoid a fully silent endpoint, make N=1 well-defined without a
// special case, and pin one byte-reproducible curve for later renderers.

import 'dart:math' as math;

import 'edit_linter.dart';
import 'edit_model.dart';

const int kStructuralAudioSampleRate = 48000;
const int kStructuralAudioProjectFps = 30;
const int kStructuralAudioSamplesPerProjectFrame =
    kStructuralAudioSampleRate ~/ kStructuralAudioProjectFps;

int structuralAudioSampleAtProjectFrame(int frame) {
  if (frame < 0) {
    throw ArgumentError.value(
      frame,
      'frame',
      'Project frame must be non-negative.',
    );
  }
  return frame * kStructuralAudioSamplesPerProjectFrame;
}

int structuralAudioSamplesForProjectFrames(int frames) {
  if (frames < 0) {
    throw ArgumentError.value(
      frames,
      'frames',
      'Project frame count must be non-negative.',
    );
  }
  return frames * kStructuralAudioSamplesPerProjectFrame;
}

enum StructuralAudioFadeDirection {
  fadeIn,
  fadeOut,
}

class StructuralAudioFade {
  final StructuralAudioFadeDirection direction;
  final int startSample;
  final int sampleCount;

  StructuralAudioFade({
    required this.direction,
    required this.startSample,
    required this.sampleCount,
  }) {
    if (startSample < 0) {
      throw ArgumentError.value(
        startSample,
        'startSample',
        'Fade start must be non-negative.',
      );
    }
    if (sampleCount <= 0) {
      throw ArgumentError.value(
        sampleCount,
        'sampleCount',
        'Fade must contain at least one sample.',
      );
    }
  }

  int get endSampleExclusive => startSample + sampleCount;

  /// Equal-power midpoint gain for one sample inside this fade.
  ///
  /// [sampleOffset] is local to the fade and therefore must be in
  /// `0 .. sampleCount - 1`. No endpoint special case exists: N=1 evaluates
  /// at t=0.5, so fade-in and fade-out are both sqrt(1/2).
  double gainAtOffset(int sampleOffset) {
    if (sampleOffset < 0 || sampleOffset >= sampleCount) {
      throw RangeError.range(
        sampleOffset,
        0,
        sampleCount - 1,
        'sampleOffset',
      );
    }

    final double t = (sampleOffset + 0.5) / sampleCount;
    final double phase = t * math.pi / 2.0;
    return switch (direction) {
      StructuralAudioFadeDirection.fadeIn => math.sin(phase),
      StructuralAudioFadeDirection.fadeOut => math.cos(phase),
    };
  }

  double gainAtAbsoluteSample(int sample) {
    if (sample < startSample || sample >= endSampleExclusive) {
      throw RangeError(
        'Sample $sample is outside fade '
        '$startSample..$endSampleExclusive.',
      );
    }
    return gainAtOffset(sample - startSample);
  }
}

enum StructuralAudioLaneKind {
  editTrack,
  mosaicPane,
}

class StructuralAudioSegment {
  final String laneId;
  final int authoredIndex;
  final String clipId;
  final String source;
  final int projectStartFrame;
  final int durationFrames;
  final int sourceInFrame;
  final ExactClipSpeed speed;
  final StructuralAudioFade? incomingFade;
  final StructuralAudioFade? outgoingFade;

  /// Non-null only when [source] is EDIT.id or MOSAIC.id.
  ///
  /// Keeping this as a plan rather than a path is the audio equivalent of the
  /// video compositor's structural recursion rule: nested structural sources
  /// are compositions, not files.
  final StructuralAudioPlan? nestedPlan;

  const StructuralAudioSegment({
    required this.laneId,
    required this.authoredIndex,
    required this.clipId,
    required this.source,
    required this.projectStartFrame,
    required this.durationFrames,
    required this.sourceInFrame,
    required this.speed,
    required this.incomingFade,
    required this.outgoingFade,
    required this.nestedPlan,
  });

  int get projectEndFrameExclusive => projectStartFrame + durationFrames;
  int get projectStartSample =>
      structuralAudioSampleAtProjectFrame(projectStartFrame);
  int get sampleCount => structuralAudioSamplesForProjectFrames(durationFrames);
  int get projectEndSampleExclusive => projectStartSample + sampleCount;

  bool get isLeafMedia => nestedPlan == null;
  bool get isStructural => nestedPlan != null;

  StructuralSourceRef? get structuralSourceRef =>
      nestedPlan?.sourceRef;

  /// Exact integer source-frame sample used by the existing picture model.
  int sourceFrameAtProjectOffset(int projectOffset) {
    if (projectOffset < 0 || projectOffset >= durationFrames) {
      throw RangeError.range(
        projectOffset,
        0,
        durationFrames - 1,
        'projectOffset',
      );
    }
    return sourceInFrame +
        (projectOffset * speed.numerator) ~/ speed.denominator;
  }

  /// Exact rational source position at a project-frame boundary.
  ///
  /// This accepts the trailing boundary at [durationFrames], unlike
  /// [sourceFrameAtProjectOffset]. Stage 1B can therefore derive a source
  /// interval without converting speed to a double. Divide the returned
  /// numerator by [sourceBoundaryDenominator] only at the decoder boundary.
  int sourceBoundaryNumeratorAtProjectOffset(int projectOffset) {
    if (projectOffset < 0 || projectOffset > durationFrames) {
      throw RangeError.range(
        projectOffset,
        0,
        durationFrames,
        'projectOffset',
      );
    }
    return sourceInFrame * speed.denominator +
        projectOffset * speed.numerator;
  }

  int get sourceBoundaryDenominator => speed.denominator;
}

class StructuralAudioLanePlan {
  final StructuralAudioLaneKind kind;
  final String id;
  final int authoredIndex;
  final List<StructuralAudioSegment> segments;

  const StructuralAudioLanePlan({
    required this.kind,
    required this.id,
    required this.authoredIndex,
    required this.segments,
  });

  StructuralAudioSegment segment(String clipId) => segments.singleWhere(
        (StructuralAudioSegment segment) => segment.clipId == clipId,
        orElse: () => throw StateError(
          'No audio segment named "$clipId" in lane "$id".',
        ),
      );
}

class StructuralAudioPlan {
  final StructuralSourceRef sourceRef;
  final int durationFrames;
  final List<StructuralAudioLanePlan> lanes;

  const StructuralAudioPlan({
    required this.sourceRef,
    required this.durationFrames,
    required this.lanes,
  });

  int get durationSamples =>
      structuralAudioSamplesForProjectFrames(durationFrames);

  Iterable<StructuralAudioSegment> get segments sync* {
    for (final StructuralAudioLanePlan lane in lanes) {
      yield* lane.segments;
    }
  }

  StructuralAudioLanePlan lane(String id) => lanes.singleWhere(
        (StructuralAudioLanePlan lane) => lane.id == id,
        orElse: () => throw StateError(
          'No audio lane named "$id" in ${sourceRef.canonicalSource}.',
        ),
      );
}

class StructuralAudioPlanException implements Exception {
  final String message;

  const StructuralAudioPlanException(this.message);

  @override
  String toString() => 'StructuralAudioPlanException: $message';
}

class StructuralAudioPlanner {
  final EditDocumentModel document;
  final int maxNesting;

  final Map<StructuralSourceRef, StructuralAudioPlan> _memo =
      <StructuralSourceRef, StructuralAudioPlan>{};
  bool _validated = false;

  StructuralAudioPlanner(
    this.document, {
    this.maxNesting = EditGraphLinter.defaultMaxNesting,
  });

  factory StructuralAudioPlanner.parse(
    String authoredDocument, {
    int maxNesting = EditGraphLinter.defaultMaxNesting,
  }) {
    return StructuralAudioPlanner(
      EditDocumentModel.parse(authoredDocument),
      maxNesting: maxNesting,
    );
  }

  StructuralAudioPlan plan(String source) {
    _validateGraph();

    final StructuralSourceRef? ref = StructuralSourceRef.tryParse(source);
    if (ref == null || ref.id.isEmpty) {
      throw ArgumentError.value(
        source,
        'source',
        'Expected EDIT.<id> or MOSAIC.<id>.',
      );
    }
    if (!document.containsStructuralSource(ref)) {
      throw StateError('No structural source named "${ref.canonicalSource}".');
    }

    return _build(ref);
  }

  void _validateGraph() {
    if (_validated) return;
    final EditLintResult lint = EditGraphLinter.lint(
      document,
      maxNesting: maxNesting,
    );
    if (!lint.isValid) {
      final EditLintIssue issue = lint.issues.first;
      throw StructuralAudioPlanException(
        '${issue.message} Path: ${issue.editPath.join(' -> ')}',
      );
    }
    _validated = true;
  }

  StructuralAudioPlan _build(StructuralSourceRef ref) {
    final StructuralAudioPlan? cached = _memo[ref];
    if (cached != null) return cached;

    final StructuralAudioPlan plan = switch (ref.kind) {
      StructuralSourceKind.edit => _buildEdit(ref),
      StructuralSourceKind.mosaic => _buildMosaic(ref),
    };
    _memo[ref] = plan;
    return plan;
  }

  StructuralAudioPlan _buildEdit(StructuralSourceRef ref) {
    final EditSequence edit = document.edit(ref.id);
    final List<(int, int, EditTrack)> videoTracks = <(int, int, EditTrack)>[];

    for (int i = 0; i < edit.tracks.length; i++) {
      final EditTrack track = edit.tracks[i];
      final int? rank = _videoTrackRank(track.id);
      if (rank != null) videoTracks.add((rank, i, track));
    }

    // Match picture's V-track ordering rather than depending on declaration
    // order. Summation is conceptually commutative, but later float32 mixing
    // must still receive one deterministic contributor order.
    videoTracks.sort((a, b) {
      final int rank = a.$1.compareTo(b.$1);
      return rank != 0 ? rank : a.$2.compareTo(b.$2);
    });

    final List<StructuralAudioLanePlan> lanes = <StructuralAudioLanePlan>[
      for (final (int _, int authoredIndex, EditTrack track) in videoTracks)
        _buildLane(
          kind: StructuralAudioLaneKind.editTrack,
          laneId: track.id,
          authoredIndex: authoredIndex,
          clips: track.clips,
        ),
    ];

    return StructuralAudioPlan(
      sourceRef: ref,
      durationFrames: edit.projectFrameCount,
      lanes: List<StructuralAudioLanePlan>.unmodifiable(lanes),
    );
  }

  StructuralAudioPlan _buildMosaic(StructuralSourceRef ref) {
    final MosaicSequence mosaic = document.mosaic(ref.id);
    final List<StructuralAudioLanePlan> lanes = <StructuralAudioLanePlan>[
      for (int i = 0; i < mosaic.panes.length; i++)
        _buildLane(
          kind: StructuralAudioLaneKind.mosaicPane,
          laneId: mosaic.panes[i].id,
          authoredIndex: i,
          clips: mosaic.panes[i].clips,
        ),
    ];

    return StructuralAudioPlan(
      sourceRef: ref,
      durationFrames: mosaic.projectFrameCount,
      lanes: List<StructuralAudioLanePlan>.unmodifiable(lanes),
    );
  }

  StructuralAudioLanePlan _buildLane({
    required StructuralAudioLaneKind kind,
    required String laneId,
    required int authoredIndex,
    required List<EditClip> clips,
  }) {
    final List<StructuralAudioSegment> segments = <StructuralAudioSegment>[];
    for (int i = 0; i < clips.length; i++) {
      segments.add(_buildSegment(laneId, i, clips[i]));
    }

    return StructuralAudioLanePlan(
      kind: kind,
      id: laneId,
      authoredIndex: authoredIndex,
      segments: List<StructuralAudioSegment>.unmodifiable(segments),
    );
  }

  StructuralAudioSegment _buildSegment(
    String laneId,
    int authoredIndex,
    EditClip clip,
  ) {
    final StructuralSourceRef? nestedRef =
        StructuralSourceRef.tryParse(clip.source);
    final StructuralAudioPlan? nestedPlan =
        nestedRef == null ? null : _build(nestedRef);

    final int incomingFrames = _crossfadeFrames(
      clip.block.innerSource,
      outgoing: false,
    );
    final int outgoingFrames = _crossfadeFrames(
      clip.block.innerSource,
      outgoing: true,
    );

    _validateFadeLength(clip, incomingFrames, 'incoming');
    _validateFadeLength(clip, outgoingFrames, 'outgoing');

    return StructuralAudioSegment(
      laneId: laneId,
      authoredIndex: authoredIndex,
      clipId: clip.id,
      source: clip.source,
      projectStartFrame: clip.atFrame,
      durationFrames: clip.durationFrames,
      sourceInFrame: clip.inFrame,
      speed: clip.speed,
      incomingFade: incomingFrames == 0
          ? null
          : StructuralAudioFade(
              direction: StructuralAudioFadeDirection.fadeIn,
              startSample:
                  structuralAudioSampleAtProjectFrame(clip.atFrame),
              sampleCount:
                  structuralAudioSamplesForProjectFrames(incomingFrames),
            ),
      outgoingFade: outgoingFrames == 0
          ? null
          : StructuralAudioFade(
              direction: StructuralAudioFadeDirection.fadeOut,
              startSample: structuralAudioSampleAtProjectFrame(
                clip.endFrameExclusive - outgoingFrames,
              ),
              sampleCount:
                  structuralAudioSamplesForProjectFrames(outgoingFrames),
            ),
      nestedPlan: nestedPlan,
    );
  }

  static void _validateFadeLength(
    EditClip clip,
    int frames,
    String edge,
  ) {
    if (frames <= clip.durationFrames) return;
    throw StructuralAudioPlanException(
      '$edge CROSSFADE on CLIP "${clip.id}" is $frames frames but the '
      'clip duration is ${clip.durationFrames}.',
    );
  }
}

final RegExp _incomingCrossfadeDirective = RegExp(
  r'\[#EDIT_TRANSITION:CROSSFADE:(\d+)\]',
);
final RegExp _outgoingCrossfadeDirective = RegExp(
  r'\[#EDIT_TRANSITION_OUT:CROSSFADE:(\d+)\]',
);

int _crossfadeFrames(String body, {required bool outgoing}) {
  final RegExp pattern =
      outgoing ? _outgoingCrossfadeDirective : _incomingCrossfadeDirective;
  final RegExpMatch? match = pattern.firstMatch(body);
  if (match == null) return 0;
  final int frames = int.parse(match.group(1)!);
  return frames > 0 ? frames : 0;
}

int? _videoTrackRank(String trackId) {
  final RegExpMatch? match = RegExp(r'^V(\d+)$').firstMatch(trackId);
  if (match == null) return null;
  return int.parse(match.group(1)!);
}
