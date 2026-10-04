// ./lib/mosaic_layout_program.dart
//
// Pure frame-dependent MOSAIC layout resolver.
//
// The authored [MosaicLayoutProgram] is reusable across placements. A
// [MosaicLayoutEvaluationContext] supplies placement-specific geometry and any
// legacy SPLIT seed. Resolution walks authored cue boundaries once, preserving
// independent per-actor segments; random frame evaluation is then a binary
// search plus interpolation. Audio presentation intent is resolved here; no
// decoder/readiness fact enters this layer.

import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/animation.dart';

import 'edit_model.dart';
import 'mosaic_layout_cue.dart';
import 'mosaic_overview_geometry.dart';
import 'mosaic_split_geometry.dart';
import 'structural_shell_geometry.dart';

enum MosaicLayoutActorKind {
  composite,
  pane,
}

class MosaicLayoutActorId {
  final MosaicLayoutActorKind kind;
  final String? paneId;
  final int actorOrdinal;

  const MosaicLayoutActorId._({
    required this.kind,
    required this.paneId,
    required this.actorOrdinal,
  });

  const MosaicLayoutActorId.composite()
      : this._(
          kind: MosaicLayoutActorKind.composite,
          paneId: null,
          actorOrdinal: 0,
        );

  const MosaicLayoutActorId.pane(String paneId, int actorOrdinal)
      : this._(
          kind: MosaicLayoutActorKind.pane,
          paneId: paneId,
          actorOrdinal: actorOrdinal,
        );

  String get key => switch (kind) {
        MosaicLayoutActorKind.composite => 'COMPOSITE',
        MosaicLayoutActorKind.pane => 'PANE:$paneId',
      };

  @override
  bool operator ==(Object other) {
    return other is MosaicLayoutActorId &&
        other.kind == kind &&
        other.paneId == paneId &&
        other.actorOrdinal == actorOrdinal;
  }

  @override
  int get hashCode => Object.hash(kind, paneId, actorOrdinal);

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': kind.name,
        'paneId': paneId,
        'actorOrdinal': actorOrdinal,
      };

  @override
  String toString() => key;
}

enum MosaicLayoutPresence {
  absent,
  entering,
  present,
  exiting,
}

enum MosaicLayoutZBand {
  exiting,
  stable,
  entering,
  fullTarget,
}

class MosaicLayoutZ implements Comparable<MosaicLayoutZ> {
  final MosaicLayoutZBand band;
  final int roleRank;
  final int actorOrdinal;

  const MosaicLayoutZ({
    required this.band,
    required this.roleRank,
    required this.actorOrdinal,
  });

  @override
  int compareTo(MosaicLayoutZ other) {
    final int bandOrder = band.index.compareTo(other.band.index);
    if (bandOrder != 0) return bandOrder;
    final int roleOrder = roleRank.compareTo(other.roleRank);
    if (roleOrder != 0) return roleOrder;
    return actorOrdinal.compareTo(other.actorOrdinal);
  }

  @override
  bool operator ==(Object other) {
    return other is MosaicLayoutZ &&
        other.band == band &&
        other.roleRank == roleRank &&
        other.actorOrdinal == actorOrdinal;
  }

  @override
  int get hashCode => Object.hash(band, roleRank, actorOrdinal);

  Map<String, Object?> toJson() => <String, Object?>{
        'band': band.name,
        'roleRank': roleRank,
        'actorOrdinal': actorOrdinal,
      };

  @override
  String toString() => '(${band.name},$roleRank,$actorOrdinal)';
}

enum MosaicLayoutOpacityCurve {
  easedLerp,
  shellEntry,
}

class MosaicLayoutActiveSegment {
  final int startFrame;
  final int durationFrames;

  final Rect startRect;
  final Rect targetRect;
  final Rect anchorRect;

  final double startOpacity;
  final double targetOpacity;

  final Rect startLabelRect;
  final Rect targetLabelRect;
  final double startLabelOpacity;
  final double targetLabelOpacity;

  final double startAudioGain;
  final double targetAudioGain;

  final double startChrome;
  final double targetChrome;

  final MosaicLayoutZ startZ;
  final MosaicLayoutZ targetZ;

  final MosaicLayoutPresence startPresence;
  final MosaicLayoutPresence targetPresence;

  final bool startDominant;
  final bool targetDominant;

  final MosaicLayoutOpacityCurve opacityCurve;

  const MosaicLayoutActiveSegment({
    required this.startFrame,
    required this.durationFrames,
    required this.startRect,
    required this.targetRect,
    required this.anchorRect,
    required this.startOpacity,
    required this.targetOpacity,
    this.startLabelRect = Rect.zero,
    this.targetLabelRect = Rect.zero,
    this.startLabelOpacity = 0.0,
    this.targetLabelOpacity = 0.0,
    required this.startAudioGain,
    required this.targetAudioGain,
    required this.startChrome,
    required this.targetChrome,
    required this.startZ,
    required this.targetZ,
    required this.startPresence,
    required this.targetPresence,
    required this.startDominant,
    required this.targetDominant,
    required this.opacityCurve,
  }) : assert(durationFrames > 1),
       assert(startLabelOpacity >= 0.0 && startLabelOpacity <= 1.0),
       assert(targetLabelOpacity >= 0.0 && targetLabelOpacity <= 1.0),
       assert(startAudioGain >= 0.0 && startAudioGain <= 1.0),
       assert(targetAudioGain >= 0.0 && targetAudioGain <= 1.0),
       assert(
         !targetDominant ||
             targetPresence != MosaicLayoutPresence.absent,
         'targetDominant requires target presence',
       );

  int get endFrame => startFrame + durationFrames - 1;

  int get zSwitchFrame => startFrame + durationFrames ~/ 2;

  MosaicLayoutPresence get transitionalPresence {
    if (targetPresence == MosaicLayoutPresence.absent) {
      return MosaicLayoutPresence.exiting;
    }
    if (startPresence == MosaicLayoutPresence.absent) {
      return MosaicLayoutPresence.entering;
    }
    return MosaicLayoutPresence.present;
  }

  /// Active focal ownership is independent from ordinary z-band ordering.
  ///
  /// Target dominance wins a focal swap. Start dominance is eligible only
  /// while the actor remains target-present; an exiting former owner therefore
  /// falls back to ordinary band ordering immediately.
  int get dominantMorphPriority {
    if (targetPresence == MosaicLayoutPresence.absent) return 0;
    if (targetDominant) return 2;
    if (startDominant) return 1;
    return 0;
  }

  /// roleRank orders a settled peer arrangement. When a target-present actor
  /// stays in the same band, keep its effective source rank for the active
  /// morph and adopt the target rank only at settlement.
  bool get defersSameBandRoleRank =>
      startPresence != MosaicLayoutPresence.absent &&
      targetPresence != MosaicLayoutPresence.absent &&
      startZ.band == targetZ.band;

  MosaicLayoutZ zAt(int frame) {
    if (defersSameBandRoleRank) return startZ;
    return frame < zSwitchFrame ? startZ : targetZ;
  }

  @override
  bool operator ==(Object other) {
    return other is MosaicLayoutActiveSegment &&
        other.startFrame == startFrame &&
        other.durationFrames == durationFrames &&
        other.startRect == startRect &&
        other.targetRect == targetRect &&
        other.anchorRect == anchorRect &&
        other.startOpacity == startOpacity &&
        other.targetOpacity == targetOpacity &&
        other.startLabelRect == startLabelRect &&
        other.targetLabelRect == targetLabelRect &&
        other.startLabelOpacity == startLabelOpacity &&
        other.targetLabelOpacity == targetLabelOpacity &&
        other.startAudioGain == startAudioGain &&
        other.targetAudioGain == targetAudioGain &&
        other.startChrome == startChrome &&
        other.targetChrome == targetChrome &&
        other.startZ == startZ &&
        other.targetZ == targetZ &&
        other.startPresence == startPresence &&
        other.targetPresence == targetPresence &&
        other.startDominant == startDominant &&
        other.targetDominant == targetDominant &&
        other.opacityCurve == opacityCurve;
  }

  @override
  int get hashCode => Object.hashAll(<Object?>[
        startFrame,
        durationFrames,
        startRect,
        targetRect,
        anchorRect,
        startOpacity,
        targetOpacity,
        startLabelRect,
        targetLabelRect,
        startLabelOpacity,
        targetLabelOpacity,
        startAudioGain,
        targetAudioGain,
        startChrome,
        targetChrome,
        startZ,
        targetZ,
        startPresence,
        targetPresence,
        startDominant,
        targetDominant,
        opacityCurve,
      ]);

  Map<String, Object?> toJson() => <String, Object?>{
        'startFrame': startFrame,
        'durationFrames': durationFrames,
        'startRect': _rectJson(startRect),
        'targetRect': _rectJson(targetRect),
        'anchorRect': _rectJson(anchorRect),
        'startOpacity': startOpacity,
        'targetOpacity': targetOpacity,
        'startLabelRect': _rectJson(startLabelRect),
        'targetLabelRect': _rectJson(targetLabelRect),
        'startLabelOpacity': startLabelOpacity,
        'targetLabelOpacity': targetLabelOpacity,
        'startAudioGain': startAudioGain,
        'targetAudioGain': targetAudioGain,
        'startChrome': startChrome,
        'targetChrome': targetChrome,
        'startZ': startZ.toJson(),
        'targetZ': targetZ.toJson(),
        'startPresence': startPresence.name,
        'targetPresence': targetPresence.name,
        'startDominant': startDominant,
        'targetDominant': targetDominant,
        'opacityCurve': opacityCurve.name,
      };
}

class MosaicLayoutActorFrame {
  final MosaicLayoutActorId actorId;
  final MosaicLayoutPresence presence;
  final Rect rect;
  final double opacity;
  final Rect labelRect;
  final double labelOpacity;
  final double chrome;
  final MosaicLayoutZ z;
  final MosaicLayoutActiveSegment? activeSegment;

  const MosaicLayoutActorFrame({
    required this.actorId,
    required this.presence,
    required this.rect,
    required this.opacity,
    this.labelRect = Rect.zero,
    this.labelOpacity = 0.0,
    required this.chrome,
    required this.z,
    required this.activeSegment,
  });

  bool get visible =>
      presence != MosaicLayoutPresence.absent && opacity > 0.0;

  int get dominantMorphPriority =>
      activeSegment?.dominantMorphPriority ?? 0;

  @override
  bool operator ==(Object other) {
    return other is MosaicLayoutActorFrame &&
        other.actorId == actorId &&
        other.presence == presence &&
        other.rect == rect &&
        other.opacity == opacity &&
        other.labelRect == labelRect &&
        other.labelOpacity == labelOpacity &&
        other.chrome == chrome &&
        other.z == z &&
        other.activeSegment == activeSegment;
  }

  @override
  int get hashCode => Object.hash(
        actorId,
        presence,
        rect,
        opacity,
        labelRect,
        labelOpacity,
        chrome,
        z,
        activeSegment,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'actorId': actorId.toJson(),
        'presence': presence.name,
        'rect': _rectJson(rect),
        'opacity': opacity,
        'labelRect': _rectJson(labelRect),
        'labelOpacity': labelOpacity,
        'chrome': chrome,
        'z': z.toJson(),
        'activeSegment': activeSegment?.toJson(),
      };
}

class MosaicLayoutFrame {
  final int sourceFrame;
  final List<MosaicLayoutActorFrame> actors;

  const MosaicLayoutFrame({
    required this.sourceFrame,
    required this.actors,
  });

  MosaicLayoutActorFrame actor(MosaicLayoutActorId id) =>
      actors.singleWhere((MosaicLayoutActorFrame actor) => actor.actorId == id);

  MosaicLayoutActorFrame pane(String paneId) => actors.singleWhere(
        (MosaicLayoutActorFrame actor) =>
            actor.actorId.kind == MosaicLayoutActorKind.pane &&
            actor.actorId.paneId == paneId,
      );

  MosaicLayoutActorFrame get composite => actors.singleWhere(
        (MosaicLayoutActorFrame actor) =>
            actor.actorId.kind == MosaicLayoutActorKind.composite,
      );

  List<MosaicLayoutActorFrame> get paintActors {
    final List<MosaicLayoutActorFrame> visible = actors
        .where(
          (MosaicLayoutActorFrame actor) =>
              actor.presence != MosaicLayoutPresence.absent,
        )
        .toList(growable: false);
    final List<MosaicLayoutActorFrame> sorted =
        List<MosaicLayoutActorFrame>.from(visible)
          ..sort(
            (MosaicLayoutActorFrame a, MosaicLayoutActorFrame b) {
              final int dominantOrder = a.dominantMorphPriority
                  .compareTo(b.dominantMorphPriority);
              if (dominantOrder != 0) return dominantOrder;
              return a.z.compareTo(b.z);
            },
          );
    return List<MosaicLayoutActorFrame>.unmodifiable(sorted);
  }

  @override
  bool operator ==(Object other) {
    if (other is! MosaicLayoutFrame ||
        other.sourceFrame != sourceFrame ||
        other.actors.length != actors.length) {
      return false;
    }
    for (int i = 0; i < actors.length; i++) {
      if (other.actors[i] != actors[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        sourceFrame,
        Object.hashAll(actors),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'sourceFrame': sourceFrame,
        'actors': actors
            .map((MosaicLayoutActorFrame actor) => actor.toJson())
            .toList(growable: false),
      };
}

class MosaicPaneAudioFrame {
  final double gain;
  final bool interpolateToNextFrame;

  const MosaicPaneAudioFrame({
    required this.gain,
    required this.interpolateToNextFrame,
  });

  @override
  bool operator ==(Object other) =>
      other is MosaicPaneAudioFrame &&
      other.gain == gain &&
      other.interpolateToNextFrame == interpolateToNextFrame;

  @override
  int get hashCode => Object.hash(gain, interpolateToNextFrame);
}

class MosaicLayoutEvaluationContext {
  final Rect programRect;
  final Rect ordinaryWindowRect;
  final Rect compositeRect;
  final double compositeChrome;
  final double titleHeight;

  /// Legacy placement-owned seed. Null means implicit COMPOSITE.
  ///
  /// If an authored cue exists at frame zero, the legacy seed is not visible
  /// in source time: the frame-zero cue establishes the canonical initial
  /// layout immediately.
  final MosaicLayoutState? legacySeed;

  const MosaicLayoutEvaluationContext({
    required this.programRect,
    required this.ordinaryWindowRect,
    required this.compositeRect,
    required this.compositeChrome,
    required this.titleHeight,
    this.legacySeed,
  });

  @override
  bool operator ==(Object other) {
    return other is MosaicLayoutEvaluationContext &&
        other.programRect == programRect &&
        other.ordinaryWindowRect == ordinaryWindowRect &&
        other.compositeRect == compositeRect &&
        other.compositeChrome == compositeChrome &&
        other.titleHeight == titleHeight &&
        other.legacySeed == legacySeed;
  }

  @override
  int get hashCode => Object.hash(
        programRect,
        ordinaryWindowRect,
        compositeRect,
        compositeChrome,
        titleHeight,
        legacySeed,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'programRect': _rectJson(programRect),
        'ordinaryWindowRect': _rectJson(ordinaryWindowRect),
        'compositeRect': _rectJson(compositeRect),
        'compositeChrome': compositeChrome,
        'titleHeight': titleHeight,
        'legacySeed': legacySeed?.formatTokens(),
      };
}

class MosaicLayoutProgram {
  final String mosaicId;
  final List<String> paneIds;
  final int projectFrameCount;
  final MosaicLayoutState? initialState;
  final List<MosaicLayoutCue> cues;
  final List<MosaicLayoutIssue> sourceIssues;

  const MosaicLayoutProgram._({
    required this.mosaicId,
    required this.paneIds,
    required this.projectFrameCount,
    required this.initialState,
    required this.cues,
    required this.sourceIssues,
  });

  factory MosaicLayoutProgram.fromMosaic({
    required String source,
    required MosaicSequence mosaic,
  }) {
    final MosaicLayoutStart? parsedStart = parseMosaicLayoutStart(
      source: source,
      mosaic: mosaic,
    );
    final List<MosaicLayoutCue> parsed = parseMosaicLayoutCues(
      source: source,
      mosaic: mosaic,
    );
    final MosaicLayoutValidationResult validation = validateMosaicLayoutCues(
      mosaic: mosaic,
      cues: parsed,
    );
    final MosaicLayoutValidationResult? startValidation =
        parsedStart == null
            ? null
            : validateMosaicLayoutCues(
                mosaic: mosaic,
                cues: <MosaicLayoutCue>[
                  MosaicLayoutCue(frame: 0, state: parsedStart.state),
                ],
              );
    final List<MosaicLayoutIssue> errors = <MosaicLayoutIssue>[
      ...validation.errors,
      if (startValidation != null) ...startValidation.errors,
    ];
    if (errors.isNotEmpty) {
      throw StateError(errors.first.message);
    }

    final List<String> paneIds =
        mosaic.panes.map((MosaicPane pane) => pane.id).toList(growable: false);
    final MosaicLayoutState? resolvedStart = parsedStart?.state.resolveBareTwoUp(
      paneIds,
    );
    final List<MosaicLayoutCue> resolved = <MosaicLayoutCue>[
      for (final MosaicLayoutCue cue in parsed)
        cue.copyWith(
          state: cue.state.resolveBareTwoUp(paneIds),
          clearSourceSpan: true,
        ),
    ]..sort(
        (MosaicLayoutCue a, MosaicLayoutCue b) => a.frame.compareTo(b.frame),
      );

    return MosaicLayoutProgram._(
      mosaicId: mosaic.id,
      paneIds: List<String>.unmodifiable(paneIds),
      projectFrameCount: mosaic.projectFrameCount,
      initialState: resolvedStart,
      cues: List<MosaicLayoutCue>.unmodifiable(resolved),
      sourceIssues: List<MosaicLayoutIssue>.unmodifiable(<MosaicLayoutIssue>[
        ...validation.issues,
        if (startValidation != null) ...startValidation.issues,
      ]),
    );
  }

  MosaicResolvedLayoutProgram resolveForStructuralAudio({
    MosaicLayoutState? legacySeed,
  }) {
    // Audio needs the exact actor inclusion/segment semantics, not output
    // geometry. Use one stable non-degenerate geometry context so the same
    // resolver owns CREATE / CONTINUE / REDIRECT / interruption timing while
    // placement-specific legacy SPLIT still enters through [legacySeed].
    return resolve(
      MosaicLayoutEvaluationContext(
        programRect: const Rect.fromLTWH(0, 0, 1920, 1080),
        ordinaryWindowRect: const Rect.fromLTWH(160, 90, 1600, 900),
        compositeRect: const Rect.fromLTWH(160, 90, 1600, 900),
        compositeChrome: 1.0,
        titleHeight: 38.0,
        legacySeed: legacySeed,
      ),
    );
  }

  MosaicResolvedLayoutProgram resolve(MosaicLayoutEvaluationContext context) {
    final List<MosaicLayoutActorId> actors = <MosaicLayoutActorId>[
      const MosaicLayoutActorId.composite(),
      for (int i = 0; i < paneIds.length; i++)
        MosaicLayoutActorId.pane(paneIds[i], i + 1),
    ];

    final bool cueAtZero = cues.isNotEmpty && cues.first.frame == 0;
    final MosaicLayoutState seedState = initialState ??
        (cueAtZero
            ? const MosaicLayoutState.composite()
            : (context.legacySeed ?? const MosaicLayoutState.composite())
                .resolveBareTwoUp(paneIds));

    Map<MosaicLayoutActorId, _ResolvedActorState> states =
        _canonicalStatesForTarget(
      state: seedState,
      context: context,
      actorIds: actors,
    );

    final List<_ResolvedBoundary> boundaries = <_ResolvedBoundary>[
      _ResolvedBoundary(
        frame: -1,
        states: Map<MosaicLayoutActorId, _ResolvedActorState>.unmodifiable(
          states,
        ),
      ),
    ];
    final List<MosaicLayoutIssue> issues = <MosaicLayoutIssue>[
      ...sourceIssues,
    ];

    if (initialState != null && cueAtZero) {
      issues.add(
        const MosaicLayoutIssue(
          severity: MosaicLayoutIssueSeverity.warning,
          code: MosaicLayoutIssueCode.initialWithFrameZeroCue,
          message:
              'LAYOUT_START owns the initial MOSAIC state; legacy LAYOUT at frame 0 is ignored until removed or migrated.',
          frame: 0,
        ),
      );
    }

    if (context.legacySeed != null && (initialState != null || cues.isNotEmpty)) {
      issues.add(
        const MosaicLayoutIssue(
          severity: MosaicLayoutIssueSeverity.warning,
          code: MosaicLayoutIssueCode.legacyWithCues,
          message:
              'Legacy STRUCT SPLIT seed is mixed with MOSAIC layout-program metadata.',
        ),
      );
    }

    for (final MosaicLayoutCue cue in cues) {
      if (cue.frame == 0 && initialState != null) {
        continue;
      }
      if (cue.frame == 0) {
        // A frame-zero cue is the authored initial layout, not an internal
        // transition out of the placement seed. STRUCT entry owns the visible
        // application-opening motion. This also makes a frame-zero cue win
        // outright over dormant legacy SPLIT intent.
        states = _canonicalStatesForTarget(
          state: cue.state,
          context: context,
          actorIds: actors,
        );
        boundaries.add(
          _ResolvedBoundary(
            frame: 0,
            states: Map<MosaicLayoutActorId, _ResolvedActorState>.unmodifiable(
              states,
            ),
          ),
        );
        continue;
      }

      states = <MosaicLayoutActorId, _ResolvedActorState>{
        for (final MapEntry<MosaicLayoutActorId, _ResolvedActorState> entry
            in states.entries)
          entry.key: entry.value.evaluateAt(cue.frame),
      };

      final Map<MosaicLayoutActorId, _TerminalCondition> desired =
          _terminalConditionsForTarget(
        state: cue.state,
        context: context,
        actorIds: actors,
      );
      final Map<MosaicLayoutActorId, bool> snapshotDominance =
          _snapshotDominanceForStates(states);

      bool changed = false;
      final Map<MosaicLayoutActorId, _ResolvedActorState> reconciled =
          <MosaicLayoutActorId, _ResolvedActorState>{};

      for (final MosaicLayoutActorId actorId in actors) {
        final _ResolvedActorState old = states[actorId]!;
        final _TerminalCondition target = desired[actorId]!;

        if (old.terminal == target) {
          // CONTINUE: preserve the actor's current segment exactly, including
          // its original start frame and duration.
          reconciled[actorId] = old;
          continue;
        }

        changed = true;
        if (old.presence != MosaicLayoutPresence.absent) {
          reconciled[actorId] = _redirectActor(
            old: old,
            desired: target,
            startDominant: snapshotDominance[actorId]!,
            frame: cue.frame,
            durationFrames: cue.durationFrames,
          );
        } else if (target.included) {
          reconciled[actorId] = _createActor(
            actorId: actorId,
            desired: target,
            frame: cue.frame,
            durationFrames: cue.durationFrames,
          );
        } else {
          reconciled[actorId] = _ResolvedActorState.canonical(
            actorId: actorId,
            terminal: target,
          );
        }
      }

      if (!changed) {
        issues.add(
          MosaicLayoutIssue(
            severity: MosaicLayoutIssueSeverity.info,
            code: MosaicLayoutIssueCode.noEffect,
            message:
                'LAYOUT cue at frame ${cue.frame} matches the effective current layout and has no effect.',
            frame: cue.frame,
          ),
        );
      }

      states = reconciled;
      boundaries.add(
        _ResolvedBoundary(
          frame: cue.frame,
          states: Map<MosaicLayoutActorId, _ResolvedActorState>.unmodifiable(
            states,
          ),
        ),
      );
    }

    final List<_ResolvedBoundary> frozenBoundaries =
        List<_ResolvedBoundary>.unmodifiable(boundaries);
    return MosaicResolvedLayoutProgram._(
      context: context,
      actorIds: List<MosaicLayoutActorId>.unmodifiable(actors),
      boundaries: frozenBoundaries,
      appearanceFramesByPane: _appearanceFramesByPane(
        actorIds: actors,
        boundaries: frozenBoundaries,
      ),
      paintabilityChangeFramesByActor: _paintabilityChangeFramesByActor(
        actorIds: actors,
        boundaries: frozenBoundaries,
      ),
      issues: List<MosaicLayoutIssue>.unmodifiable(issues),
    );
  }
}

class MosaicResolvedLayoutProgram {
  final MosaicLayoutEvaluationContext context;
  final List<MosaicLayoutActorId> actorIds;
  final List<_ResolvedBoundary> _boundaries;
  final Map<String, List<int>> _appearanceFramesByPane;
  final Map<MosaicLayoutActorId, List<int>> _paintabilityChangeFramesByActor;
  final List<MosaicLayoutIssue> issues;

  const MosaicResolvedLayoutProgram._({
    required this.context,
    required this.actorIds,
    required List<_ResolvedBoundary> boundaries,
    required Map<String, List<int>> appearanceFramesByPane,
    required Map<MosaicLayoutActorId, List<int>> paintabilityChangeFramesByActor,
    required this.issues,
  })  : _boundaries = boundaries,
        _appearanceFramesByPane = appearanceFramesByPane,
        _paintabilityChangeFramesByActor = paintabilityChangeFramesByActor;

  MosaicLayoutFrame evaluate(int sourceFrame) {
    if (sourceFrame < 0) {
      throw ArgumentError.value(
        sourceFrame,
        'sourceFrame',
        'MOSAIC layout source frame must be non-negative.',
      );
    }

    final _ResolvedBoundary boundary = _boundaryFor(sourceFrame);
    final List<MosaicLayoutActorFrame> frames = <MosaicLayoutActorFrame>[
      for (final MosaicLayoutActorId actorId in actorIds)
        boundary.states[actorId]!.evaluateAt(sourceFrame).toFrame(),
    ];

    return MosaicLayoutFrame(
      sourceFrame: sourceFrame,
      actors: List<MosaicLayoutActorFrame>.unmodifiable(frames),
    );
  }

  MosaicPaneAudioFrame paneAudioFrame(
    String paneId, {
    required int sourceFrame,
  }) {
    if (sourceFrame < 0) {
      throw ArgumentError.value(
        sourceFrame,
        'sourceFrame',
        'MOSAIC layout source frame must be non-negative.',
      );
    }

    final MosaicLayoutActorId compositeId = actorIds.first;
    final MosaicLayoutActorId paneActorId = actorIds.singleWhere(
      (MosaicLayoutActorId actorId) =>
          actorId.kind == MosaicLayoutActorKind.pane &&
          actorId.paneId == paneId,
      orElse: () => throw StateError('Unknown MOSAIC PANE "$paneId".'),
    );
    final _ResolvedBoundary boundary = _boundaryFor(sourceFrame);
    final _ResolvedActorState composite =
        boundary.states[compositeId]!.evaluateAt(sourceFrame);
    final _ResolvedActorState pane =
        boundary.states[paneActorId]!.evaluateAt(sourceFrame);

    // COMPOSITE represents the whole MOSAIC, including every pane. Direct pane
    // actors represent that pane when the desktop is decomposed. During
    // COMPOSITE <-> pane transitions both representations overlap; summing and
    // clamping preserves unity while audio intent remains independent from
    // visual opacity.
    final double gain =
        (composite.audioGain + pane.audioGain).clamp(0.0, 1.0).toDouble();

    bool transitioning(_ResolvedActorState actor) {
      final MosaicLayoutActiveSegment? segment = actor.activeSegment;
      return segment != null && segment.endFrame > sourceFrame;
    }

    return MosaicPaneAudioFrame(
      gain: gain,
      interpolateToNextFrame:
          transitioning(composite) || transitioning(pane),
    );
  }

  int? nextAppearanceFrame(String paneId, {required int afterFrame}) {
    final List<int>? appearances = _appearanceFramesByPane[paneId];
    if (appearances == null) {
      throw StateError('Unknown MOSAIC PANE "$paneId".');
    }

    int low = 0;
    int high = appearances.length;
    while (low < high) {
      final int mid = low + ((high - low) >> 1);
      if (appearances[mid] <= afterFrame) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low < appearances.length ? appearances[low] : null;
  }

  bool actorStayedPaintableAcross(
    MosaicLayoutActorId actorId, {
    required int frameA,
    required int frameB,
  }) {
    final List<int>? changes = _paintabilityChangeFramesByActor[actorId];
    if (changes == null) {
      throw StateError('Unknown MOSAIC actor "$actorId".');
    }
    if (frameA == frameB) return true;

    final int lower = math.min(frameA, frameB);
    final int upper = math.max(frameA, frameB);

    int low = 0;
    int high = changes.length;
    while (low < high) {
      final int mid = low + ((high - low) >> 1);
      if (changes[mid] <= lower) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }

    return low >= changes.length || changes[low] > upper;
  }

  Set<String> paneIdsEnteringBetween({
    required int afterFrame,
    required int throughFrame,
  }) {
    if (throughFrame < afterFrame) return <String>{};
    final Set<String> out = <String>{};
    for (final MosaicLayoutActorId actorId in actorIds) {
      final String? paneId = actorId.paneId;
      if (paneId == null) continue;
      final int? next =
          nextAppearanceFrame(paneId, afterFrame: afterFrame);
      if (next != null && next <= throughFrame) out.add(paneId);
    }
    return Set<String>.unmodifiable(out);
  }

  /// Stable serialization used to prove separately rebuilt Preview/BAKE
  /// resolver tables are bit-identical for the same program/context inputs.
  String canonicalSerialization() {
    return jsonEncode(<String, Object?>{
      'context': context.toJson(),
      'actorIds':
          actorIds.map((MosaicLayoutActorId id) => id.toJson()).toList(),
      'boundaries': _boundaries
          .map((_ResolvedBoundary boundary) => boundary.toJson(actorIds))
          .toList(),
    });
  }

  _ResolvedBoundary _boundaryFor(int frame) {
    int low = 0;
    int high = _boundaries.length - 1;
    while (low <= high) {
      final int mid = low + ((high - low) >> 1);
      if (_boundaries[mid].frame <= frame) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return _boundaries[high < 0 ? 0 : high];
  }
}

Map<String, List<int>> _appearanceFramesByPane({
  required List<MosaicLayoutActorId> actorIds,
  required List<_ResolvedBoundary> boundaries,
}) {
  final Map<String, List<int>> out = <String, List<int>>{
    for (final MosaicLayoutActorId actorId in actorIds)
      if (actorId.paneId != null) actorId.paneId!: <int>[],
  };
  final Map<MosaicLayoutActorId, bool> included =
      <MosaicLayoutActorId, bool>{
    for (final MosaicLayoutActorId actorId in actorIds) actorId: false,
  };

  for (final _ResolvedBoundary boundary in boundaries) {
    for (final MosaicLayoutActorId actorId in actorIds) {
      final String? paneId = actorId.paneId;
      if (paneId == null) continue;
      final bool nextIncluded =
          boundary.states[actorId]!.terminal.included;
      if (!(included[actorId] ?? false) && nextIncluded) {
        out[paneId]!.add(boundary.frame);
      }
      included[actorId] = nextIncluded;
    }
  }

  return Map<String, List<int>>.unmodifiable(
    <String, List<int>>{
      for (final MapEntry<String, List<int>> entry in out.entries)
        entry.key: List<int>.unmodifiable(entry.value),
    },
  );
}

Map<MosaicLayoutActorId, List<int>> _paintabilityChangeFramesByActor({
  required List<MosaicLayoutActorId> actorIds,
  required List<_ResolvedBoundary> boundaries,
}) {
  final Map<MosaicLayoutActorId, List<int>> out =
      <MosaicLayoutActorId, List<int>>{
    for (final MosaicLayoutActorId actorId in actorIds) actorId: <int>[],
  };
  final Map<MosaicLayoutActorId, bool> paintable =
      <MosaicLayoutActorId, bool>{
    for (final MosaicLayoutActorId actorId in actorIds) actorId: false,
  };

  for (int boundaryIndex = 0;
      boundaryIndex < boundaries.length;
      boundaryIndex++) {
    final _ResolvedBoundary boundary = boundaries[boundaryIndex];
    final int? nextBoundaryFrame = boundaryIndex + 1 < boundaries.length
        ? boundaries[boundaryIndex + 1].frame
        : null;

    for (final MosaicLayoutActorId actorId in actorIds) {
      final _ResolvedActorState state = boundary.states[actorId]!;
      final bool boundaryPaintable =
          state.presence != MosaicLayoutPresence.absent;
      if ((paintable[actorId] ?? false) != boundaryPaintable &&
          boundary.frame >= 0) {
        out[actorId]!.add(boundary.frame);
      }
      paintable[actorId] = boundaryPaintable;

      final MosaicLayoutActiveSegment? segment = state.activeSegment;
      if (segment == null) continue;

      // Settlement is a real paintability boundary only when the segment is
      // allowed to finish before the next cue. If another cue lands at or
      // before endFrame, reconciliation interrupts/redirects the actor without
      // an authored absent frame in between.
      if (nextBoundaryFrame != null &&
          segment.endFrame >= nextBoundaryFrame) {
        continue;
      }

      final bool settledPaintable = state.terminal.included;
      if ((paintable[actorId] ?? false) != settledPaintable) {
        out[actorId]!.add(segment.endFrame);
        paintable[actorId] = settledPaintable;
      }
    }
  }

  return Map<MosaicLayoutActorId, List<int>>.unmodifiable(
    <MosaicLayoutActorId, List<int>>{
      for (final MapEntry<MosaicLayoutActorId, List<int>> entry
          in out.entries)
        entry.key: List<int>.unmodifiable(entry.value),
    },
  );
}

class _TerminalCondition {
  final bool included;
  final Rect? anchorRect;
  final double restingChrome;
  final double restingAudioGain;
  final Rect restingLabelRect;
  final double restingLabelOpacity;
  final MosaicLayoutZ restingZ;
  final bool dominant;

  const _TerminalCondition({
    required this.included,
    required this.anchorRect,
    required this.restingChrome,
    required this.restingAudioGain,
    required this.restingLabelRect,
    required this.restingLabelOpacity,
    required this.restingZ,
    required this.dominant,
  }) : assert(!dominant || included, 'dominant requires inclusion'),
       assert(restingAudioGain >= 0.0 && restingAudioGain <= 1.0),
       assert(restingLabelOpacity >= 0.0 && restingLabelOpacity <= 1.0);

  @override
  bool operator ==(Object other) {
    return other is _TerminalCondition &&
        other.included == included &&
        other.anchorRect == anchorRect &&
        other.restingChrome == restingChrome &&
        other.restingAudioGain == restingAudioGain &&
        other.restingLabelRect == restingLabelRect &&
        other.restingLabelOpacity == restingLabelOpacity &&
        other.restingZ == restingZ &&
        other.dominant == dominant;
  }

  @override
  int get hashCode => Object.hash(
        included,
        anchorRect,
        restingChrome,
        restingAudioGain,
        restingLabelRect,
        restingLabelOpacity,
        restingZ,
        dominant,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'included': included,
        'anchorRect': anchorRect == null ? null : _rectJson(anchorRect!),
        'restingChrome': restingChrome,
        'restingAudioGain': restingAudioGain,
        'restingLabelRect': _rectJson(restingLabelRect),
        'restingLabelOpacity': restingLabelOpacity,
        'restingZ': restingZ.toJson(),
        'dominant': dominant,
      };
}

class _ResolvedActorState {
  final MosaicLayoutActorId actorId;
  final _TerminalCondition terminal;
  final MosaicLayoutPresence presence;
  final Rect rect;
  final double opacity;
  final Rect labelRect;
  final double labelOpacity;
  final double audioGain;
  final double chrome;
  final MosaicLayoutZ z;
  final MosaicLayoutActiveSegment? activeSegment;

  const _ResolvedActorState({
    required this.actorId,
    required this.terminal,
    required this.presence,
    required this.rect,
    required this.opacity,
    required this.labelRect,
    required this.labelOpacity,
    required this.audioGain,
    required this.chrome,
    required this.z,
    required this.activeSegment,
  });

  factory _ResolvedActorState.canonical({
    required MosaicLayoutActorId actorId,
    required _TerminalCondition terminal,
  }) {
    if (!terminal.included) {
      return _ResolvedActorState(
        actorId: actorId,
        terminal: terminal,
        presence: MosaicLayoutPresence.absent,
        rect: Rect.zero,
        opacity: 0.0,
        labelRect: terminal.restingLabelRect,
        labelOpacity: terminal.restingLabelOpacity,
        audioGain: terminal.restingAudioGain,
        chrome: 0.0,
        z: terminal.restingZ,
        activeSegment: null,
      );
    }

    return _ResolvedActorState(
      actorId: actorId,
      terminal: terminal,
      presence: MosaicLayoutPresence.present,
      rect: terminal.anchorRect!,
      opacity: 1.0,
      labelRect: terminal.restingLabelRect,
      labelOpacity: terminal.restingLabelOpacity,
      audioGain: terminal.restingAudioGain,
      chrome: terminal.restingChrome,
      z: terminal.restingZ,
      activeSegment: null,
    );
  }

  _ResolvedActorState evaluateAt(int frame) {
    final MosaicLayoutActiveSegment? segment = activeSegment;
    if (segment == null) return this;

    // Settlement always precedes reconciliation. <= is deliberate: a segment
    // may have ended anywhere in the gap since the preceding cue.
    if (segment.endFrame <= frame) {
      return _ResolvedActorState.canonical(
        actorId: actorId,
        terminal: terminal,
      );
    }

    final double linear = ((frame - segment.startFrame) /
            (segment.durationFrames - 1))
        .clamp(0.0, 1.0)
        .toDouble();
    final double eased = Curves.easeInOutCubic.transform(linear);

    Rect rect = Rect.lerp(
      segment.startRect,
      segment.targetRect,
      eased,
    )!;
    final double opacityProgress;
    final double opacity;
    if (segment.opacityCurve == MosaicLayoutOpacityCurve.shellEntry) {
      final StructuralShapeEntryFrame shell = structuralShapeEntryFrameAt(
        targetRect: segment.anchorRect,
        linearProgress: linear,
        contentReady: true,
      );
      rect = shell.rect;
      opacityProgress = shell.opacity;
      opacity = shell.opacity;
    } else {
      opacityProgress = eased;
      opacity = _lerp(
        segment.startOpacity,
        segment.targetOpacity,
        opacityProgress,
      );
    }
    final Rect labelRect = Rect.lerp(
      segment.startLabelRect,
      segment.targetLabelRect,
      eased,
    )!;
    final double labelOpacity = _lerp(
      segment.startLabelOpacity,
      segment.targetLabelOpacity,
      opacityProgress,
    );
    final double audioGain = _lerp(
      segment.startAudioGain,
      segment.targetAudioGain,
      opacityProgress,
    );

    return _ResolvedActorState(
      actorId: actorId,
      terminal: terminal,
      presence: segment.transitionalPresence,
      rect: rect,
      opacity: opacity,
      labelRect: labelRect,
      labelOpacity: labelOpacity,
      audioGain: audioGain,
      chrome: _lerp(
        segment.startChrome,
        segment.targetChrome,
        eased,
      ),
      z: segment.zAt(frame),
      activeSegment: segment,
    );
  }

  MosaicLayoutActorFrame toFrame() => MosaicLayoutActorFrame(
        actorId: actorId,
        presence: presence,
        rect: rect,
        opacity: opacity,
        labelRect: labelRect,
        labelOpacity: labelOpacity,
        chrome: chrome,
        z: z,
        activeSegment: activeSegment,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'terminal': terminal.toJson(),
        'labelRect': _rectJson(labelRect),
        'labelOpacity': labelOpacity,
        'audioGain': audioGain,
        'frame': toFrame().toJson(),
      };
}

class _ResolvedBoundary {
  final int frame;
  final Map<MosaicLayoutActorId, _ResolvedActorState> states;

  const _ResolvedBoundary({
    required this.frame,
    required this.states,
  });

  Map<String, Object?> toJson(List<MosaicLayoutActorId> actorIds) =>
      <String, Object?>{
        'frame': frame,
        'actors': <Object?>[
          for (final MosaicLayoutActorId actorId in actorIds)
            <String, Object?>{
              'id': actorId.toJson(),
              'state': states[actorId]!.toJson(),
            },
        ],
      };
}

Map<MosaicLayoutActorId, _ResolvedActorState> _canonicalStatesForTarget({
  required MosaicLayoutState state,
  required MosaicLayoutEvaluationContext context,
  required List<MosaicLayoutActorId> actorIds,
}) {
  final Map<MosaicLayoutActorId, _TerminalCondition> terminals =
      _terminalConditionsForTarget(
    state: state,
    context: context,
    actorIds: actorIds,
  );
  return <MosaicLayoutActorId, _ResolvedActorState>{
    for (final MosaicLayoutActorId actorId in actorIds)
      actorId: _ResolvedActorState.canonical(
        actorId: actorId,
        terminal: terminals[actorId]!,
      ),
  };
}

Map<MosaicLayoutActorId, _TerminalCondition> _terminalConditionsForTarget({
  required MosaicLayoutState state,
  required MosaicLayoutEvaluationContext context,
  required List<MosaicLayoutActorId> actorIds,
}) {
  final Map<MosaicLayoutActorId, _TerminalCondition> out =
      <MosaicLayoutActorId, _TerminalCondition>{
    for (final MosaicLayoutActorId actorId in actorIds)
      actorId: _absentTerminal(actorId),
  };

  MosaicLayoutActorId paneActor(String paneId) => actorIds.singleWhere(
        (MosaicLayoutActorId actorId) =>
            actorId.kind == MosaicLayoutActorKind.pane &&
            actorId.paneId == paneId,
        orElse: () =>
            throw StateError('LAYOUT references unknown PANE "$paneId".'),
      );

  switch (state.kind) {
    case MosaicLayoutStateKind.composite:
      final MosaicLayoutActorId composite = actorIds.first;
      out[composite] = _TerminalCondition(
        included: true,
        anchorRect: context.compositeRect,
        restingChrome: context.compositeChrome,
        restingAudioGain: 1.0,
        restingLabelRect: _hiddenLabelRect(
          context.compositeRect,
          context.titleHeight,
        ),
        restingLabelOpacity: 0.0,
        restingZ: MosaicLayoutZ(
          band: MosaicLayoutZBand.stable,
          roleRank: 0,
          actorOrdinal: composite.actorOrdinal,
        ),
        dominant: false,
      );
      break;

    case MosaicLayoutStateKind.twoUp:
      final String paneA = state.paneA!;
      final String paneB = state.paneB!;
      final MosaicSplitWindowGeometry geometry = mosaicSplitWindowGeometry(
        frame: context.programRect,
        aspect: state.splitAspect,
        titleHeight: context.titleHeight,
        maximized: state.maximizeSplit,
      );
      final MosaicLayoutActorId actorA = paneActor(paneA);
      final MosaicLayoutActorId actorB = paneActor(paneB);
      out[actorA] = _TerminalCondition(
        included: true,
        anchorRect: geometry.leftWindowRect,
        restingChrome: 1.0,
        restingAudioGain: 1.0,
        restingLabelRect: _hiddenLabelRect(
          geometry.leftWindowRect,
          context.titleHeight,
        ),
        restingLabelOpacity: 0.0,
        restingZ: MosaicLayoutZ(
          band: MosaicLayoutZBand.stable,
          roleRank: 0,
          actorOrdinal: actorA.actorOrdinal,
        ),
        dominant: false,
      );
      out[actorB] = _TerminalCondition(
        included: true,
        anchorRect: geometry.rightWindowRect,
        restingChrome: 1.0,
        restingAudioGain: 1.0,
        restingLabelRect: _hiddenLabelRect(
          geometry.rightWindowRect,
          context.titleHeight,
        ),
        restingLabelOpacity: 0.0,
        restingZ: MosaicLayoutZ(
          band: MosaicLayoutZBand.stable,
          roleRank: 1,
          actorOrdinal: actorB.actorOrdinal,
        ),
        dominant: false,
      );
      break;

    case MosaicLayoutStateKind.overview:
      final MosaicOverviewGeometry geometry = mosaicOverviewGeometry(
        frame: context.programRect,
        aspect: state.splitAspect,
        titleHeight: context.titleHeight,
        thumbnailCount: state.overviewOthers.length,
      );
      final MosaicLayoutActorId mainActor = paneActor(state.overviewMain!);
      out[mainActor] = _TerminalCondition(
        included: true,
        anchorRect: geometry.mainWindowRect,
        restingChrome: 1.0,
        restingAudioGain: 1.0,
        restingLabelRect: _hiddenLabelRect(
          geometry.mainWindowRect,
          context.titleHeight,
        ),
        restingLabelOpacity: 0.0,
        restingZ: MosaicLayoutZ(
          band: MosaicLayoutZBand.stable,
          // MAIN must remain terminal-equal when +2 becomes +3. Its rank is
          // therefore a stable focal tier, not a function of shelf count.
          roleRank: 100,
          actorOrdinal: mainActor.actorOrdinal,
        ),
        dominant: true,
      );
      for (int index = 0; index < state.overviewOthers.length; index++) {
        final MosaicLayoutActorId actor =
            paneActor(state.overviewOthers[index]);
        out[actor] = _TerminalCondition(
          included: true,
          anchorRect: geometry.thumbnailRects[index],
          restingChrome: 0.0,
          restingAudioGain: 0.0,
          restingLabelRect: geometry.labelRects[index],
          restingLabelOpacity: 1.0,
          restingZ: MosaicLayoutZ(
            band: MosaicLayoutZBand.stable,
            roleRank: index,
            actorOrdinal: actor.actorOrdinal,
          ),
          dominant: false,
        );
      }
      break;

    case MosaicLayoutStateKind.one:
      final MosaicLayoutActorId actor = paneActor(state.paneId!);
      out[actor] = _TerminalCondition(
        included: true,
        anchorRect: context.ordinaryWindowRect,
        restingChrome: 1.0,
        restingAudioGain: 1.0,
        restingLabelRect: _hiddenLabelRect(
          context.ordinaryWindowRect,
          context.titleHeight,
        ),
        restingLabelOpacity: 0.0,
        restingZ: MosaicLayoutZ(
          band: MosaicLayoutZBand.stable,
          roleRank: 0,
          actorOrdinal: actor.actorOrdinal,
        ),
        dominant: true,
      );
      break;

    case MosaicLayoutStateKind.full:
      final MosaicLayoutActorId actor = paneActor(state.paneId!);
      out[actor] = _TerminalCondition(
        included: true,
        anchorRect: context.programRect,
        restingChrome: 0.0,
        restingAudioGain: 1.0,
        restingLabelRect: _hiddenLabelRect(
          context.programRect,
          context.titleHeight,
        ),
        restingLabelOpacity: 0.0,
        restingZ: MosaicLayoutZ(
          band: MosaicLayoutZBand.fullTarget,
          roleRank: 0,
          actorOrdinal: actor.actorOrdinal,
        ),
        dominant: true,
      );
      break;
  }

  return out;
}

_TerminalCondition _absentTerminal(MosaicLayoutActorId actorId) {
  return _TerminalCondition(
    included: false,
    anchorRect: null,
    restingChrome: 0.0,
    restingAudioGain: 0.0,
    restingLabelRect: Rect.zero,
    restingLabelOpacity: 0.0,
    restingZ: MosaicLayoutZ(
      band: MosaicLayoutZBand.exiting,
      roleRank: 0,
      actorOrdinal: actorId.actorOrdinal,
    ),
    dominant: false,
  );
}

Map<MosaicLayoutActorId, bool> _snapshotDominanceForStates(
  Map<MosaicLayoutActorId, _ResolvedActorState> states,
) {
  MosaicLayoutActorId? activeOwner;
  int highestPriority = 0;

  for (final MapEntry<MosaicLayoutActorId, _ResolvedActorState> entry
      in states.entries) {
    final MosaicLayoutActiveSegment? segment = entry.value.activeSegment;
    if (segment == null) continue;
    final int priority = segment.dominantMorphPriority;
    if (priority == 0) continue;
    if (priority > highestPriority) {
      highestPriority = priority;
      activeOwner = entry.key;
      continue;
    }
    if (priority == highestPriority) {
      throw StateError(
        'Multiple MOSAIC actors resolve the same dominant morph priority '
        '$priority at one cue boundary.',
      );
    }
  }

  final Map<MosaicLayoutActorId, bool> out =
      <MosaicLayoutActorId, bool>{
    for (final MapEntry<MosaicLayoutActorId, _ResolvedActorState> entry
        in states.entries)
      entry.key: entry.value.activeSegment == null
          ? entry.value.terminal.dominant
          : entry.key == activeOwner,
  };

  final int ownerCount = out.values.where((bool value) => value).length;
  if (ownerCount > 1) {
    throw StateError(
      'MOSAIC snapshot dominance resolved more than one current owner.',
    );
  }

  return Map<MosaicLayoutActorId, bool>.unmodifiable(out);
}

/// Raw startDominant endpoint facts can persist on a target-absent CONTINUE
/// segment from an older cue. Those facts are intentionally inert because
/// target-presence gating gives them priority zero. The globally resolved
/// current owner above is therefore the authority used when a new redirect
/// snapshots dominance.
_ResolvedActorState _createActor({
  required MosaicLayoutActorId actorId,
  required _TerminalCondition desired,
  required int frame,
  required int durationFrames,
}) {
  assert(desired.included);
  if (durationFrames <= 1) {
    return _ResolvedActorState.canonical(
      actorId: actorId,
      terminal: desired,
    );
  }

  final Rect anchor = desired.anchorRect!;
  final MosaicLayoutActiveSegment segment = MosaicLayoutActiveSegment(
    startFrame: frame,
    durationFrames: durationFrames,
    startRect: structuralShellEmergenceRect(anchor),
    targetRect: anchor,
    anchorRect: anchor,
    startOpacity: 0.0,
    targetOpacity: 1.0,
    startLabelRect: structuralShellEmergenceRect(desired.restingLabelRect),
    targetLabelRect: desired.restingLabelRect,
    startLabelOpacity: 0.0,
    targetLabelOpacity: desired.restingLabelOpacity,
    startAudioGain: 0.0,
    targetAudioGain: desired.restingAudioGain,
    startChrome: desired.restingChrome,
    targetChrome: desired.restingChrome,
    startZ: MosaicLayoutZ(
      band: MosaicLayoutZBand.entering,
      roleRank: desired.restingZ.roleRank,
      actorOrdinal: actorId.actorOrdinal,
    ),
    targetZ: desired.restingZ,
    startPresence: MosaicLayoutPresence.absent,
    targetPresence: MosaicLayoutPresence.present,
    startDominant: false,
    targetDominant: desired.dominant,
    opacityCurve: MosaicLayoutOpacityCurve.shellEntry,
  );

  return _ResolvedActorState(
    actorId: actorId,
    terminal: desired,
    presence: MosaicLayoutPresence.entering,
    rect: segment.startRect,
    opacity: 0.0,
    labelRect: segment.startLabelRect,
    labelOpacity: 0.0,
    audioGain: 0.0,
    chrome: desired.restingChrome,
    z: segment.startZ,
    activeSegment: segment,
  );
}

_ResolvedActorState _redirectActor({
  required _ResolvedActorState old,
  required _TerminalCondition desired,
  required bool startDominant,
  required int frame,
  required int durationFrames,
}) {
  if (durationFrames <= 1) {
    return _ResolvedActorState.canonical(
      actorId: old.actorId,
      terminal: desired,
    );
  }

  final Rect anchor;
  final Rect targetRect;
  final double targetOpacity;
  final double targetChrome;
  final MosaicLayoutZ targetZ;
  final MosaicLayoutPresence targetPresence;

  if (desired.included) {
    anchor = desired.anchorRect!;
    targetRect = anchor;
    targetOpacity = 1.0;
    targetChrome = desired.restingChrome;
    targetZ = desired.restingZ;
    targetPresence = MosaicLayoutPresence.present;
  } else {
    // Excluding an actor preserves the resting rectangle it is leaving.
    // Never derive an emergence rect from the current motion endpoint; doing
    // so would allow E(E(anchor)) after repeated dismissal.
    final Rect? oldAnchor = old.activeSegment?.anchorRect ??
        (old.terminal.included ? old.terminal.anchorRect : null);
    if (oldAnchor == null) {
      throw StateError(
        'Cannot redirect ${old.actorId} to absent without an anchor rect.',
      );
    }
    anchor = oldAnchor;
    targetRect = structuralShellEmergenceRect(oldAnchor);
    targetOpacity = 0.0;
    targetChrome = old.chrome;
    final int roleRank = old.terminal.included
        ? old.terminal.restingZ.roleRank
        : old.z.roleRank;
    targetZ = MosaicLayoutZ(
      band: MosaicLayoutZBand.exiting,
      roleRank: roleRank,
      actorOrdinal: old.actorId.actorOrdinal,
    );
    targetPresence = MosaicLayoutPresence.absent;
  }

  final MosaicLayoutActiveSegment segment = MosaicLayoutActiveSegment(
    startFrame: frame,
    durationFrames: durationFrames,
    startRect: old.rect,
    targetRect: targetRect,
    anchorRect: anchor,
    startOpacity: old.opacity,
    targetOpacity: targetOpacity,
    startLabelRect: old.labelRect,
    targetLabelRect: desired.restingLabelRect,
    startLabelOpacity: old.labelOpacity,
    targetLabelOpacity: desired.restingLabelOpacity,
    startAudioGain: old.audioGain,
    targetAudioGain: desired.restingAudioGain,
    startChrome: old.chrome,
    targetChrome: targetChrome,
    startZ: old.z,
    targetZ: targetZ,
    startPresence: old.presence,
    targetPresence: targetPresence,
    startDominant: startDominant,
    targetDominant: desired.dominant,
    opacityCurve: MosaicLayoutOpacityCurve.easedLerp,
  );

  return _ResolvedActorState(
    actorId: old.actorId,
    terminal: desired,
    presence: segment.transitionalPresence,
    rect: old.rect,
    opacity: old.opacity,
    labelRect: old.labelRect,
    labelOpacity: old.labelOpacity,
    audioGain: old.audioGain,
    chrome: old.chrome,
    z: old.z,
    activeSegment: segment,
  );
}

Rect _hiddenLabelRect(Rect anchor, double titleHeight) {
  final double scale = titleHeight > 0.0 ? titleHeight / 38.0 : 1.0;
  return Rect.fromLTWH(
    anchor.left,
    anchor.bottom + 8.0 * scale,
    anchor.width,
    24.0 * scale,
  );
}

double _lerp(double a, double b, double t) => a + (b - a) * t;

List<double> _rectJson(Rect rect) => <double>[
      rect.left,
      rect.top,
      rect.right,
      rect.bottom,
    ];
