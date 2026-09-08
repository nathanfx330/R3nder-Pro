// ./lib/structural_sequence.dart
//
// Main-sequence placement for structural EDIT / MOSAIC sources.
//
// EDIT and MOSAIC blocks are reusable source definitions. They do not consume
// TerminalEngine time merely because they exist in the document. A standalone
// [STRUCT:EDIT.foo] or [STRUCT:MOSAIC.bar] line is the sequence-side reference
// that says "play this source here".
//
// STRUCT owns presentation behavior, not source composition. The same EDIT or
// MOSAIC can therefore be presented in a desktop window or fullscreen without
// changing the reusable source definition:
//
//   [STRUCT:MOSAIC.wall]
//   [STRUCT:MOSAIC.wall:FULL]
//
// Window title and informational player overlays are placement-owned for the
// same reason. They are parsed from keyed STRUCT tail segments by
// structural_chrome.dart and travel with this placement into Preview/Bake
// presentation without changing the underlying EDIT/MOSAIC source.
//
// Adjacent STRUCT placements also participate in the desktop application
// choreography. With ordinary APPSWITCH behavior the outgoing structural
// window closes to the desktop and the next one opens without zooming the
// terminal back up between them. With [CONFIG:APPSWITCH:SLIDE], compatible
// adjacent STRUCT placements keep the presentation shell alive and switch
// directly. If the two placements disagree about fullscreen/windowed state,
// the incoming placement owns one deterministic window-animation budget to
// morph between those geometries.

import 'edit_model.dart';
import 'scene_engine.dart';
import 'structural_chrome.dart';

final RegExp _placementLine = RegExp(
  r'^(?<indent>[ \t]*)(?<tag>\[STRUCT:(?:EDIT|MOSAIC)\.[A-Za-z0-9_-]+[^\r\n]*\])(?<trail>[ \t]*)$',
  multiLine: true,
);

final RegExp _runtimeRegionPattern = RegExp(
  r'^STRUCTSEQ_(?<index>\d+)_(?<duration>\d+)$',
);

final RegExp _appSwitchConfig = RegExp(
  r'\[CONFIG:APPSWITCH:(?<mode>[A-Za-z]+)\]',
);

/// A structural source uses the same terminal-to-desktop and window-open
/// timing as the rest of R3nder's desktop presentations.
const int kStructuralZoomFrames = kZoomAnimFrames;
const int kStructuralWindowFrames = kWindowAnimFrames;
const int kStructuralEntryFrames =
    kStructuralZoomFrames + kStructuralWindowFrames;
const int kStructuralExitFrames =
    kStructuralWindowFrames + kStructuralZoomFrames;

/// A standalone `[PAUSE:N]` line occupies two scene ticks beyond N in the
/// editor line-map execution path: entering the pause and advancing past the
/// line. STRUCT owns an exact presentation budget, so its projected PAUSE
/// argument compensates for those framing ticks instead of silently stretching
/// every structural call by two frames.
const int kStructuralProjectionFramingFrames = 2;

/// Prefix reserved for the engine-internal region used by real Preview/Bake.
/// It fits the existing REGION grammar, so no author-visible tag is added.
const String kStructuralRuntimeRegionPrefix = 'STRUCTSEQ_';

enum StructuralPresentationMode {
  windowed,
  fullscreen,
}

enum StructuralSequenceStage {
  zoomOut,
  opening,
  showing,
  closing,
  zoomIn,
}

int structuralSequenceDurationForSource(int sourceFrames) {
  if (sourceFrames <= 0) return 0;
  return kStructuralEntryFrames + sourceFrames + kStructuralExitFrames;
}

int _projectedPauseFramesForEvent(int eventFrames) {
  if (eventFrames <= 0) return 1;
  final int pauseFrames = eventFrames - kStructuralProjectionFramingFrames;
  return pauseFrames > 0 ? pauseFrames : 1;
}

/// Engine-visible identity for one live structural placement.
///
/// Preview/Bake compilation writes this into an internal REGION id before the
/// timing PAUSE. The terminal already exposes currentRegion, so the top-level
/// Preview can discover the active placement without a second line-map clock.
class StructuralRuntimeMarker {
  final int placementIndex;
  final int durationFrames;

  const StructuralRuntimeMarker({
    required this.placementIndex,
    required this.durationFrames,
  });

  String get regionId =>
      '$kStructuralRuntimeRegionPrefix${placementIndex}_$durationFrames';
}

StructuralRuntimeMarker? parseStructuralRuntimeRegion(String? regionId) {
  if (regionId == null) return null;
  final RegExpMatch? match = _runtimeRegionPattern.firstMatch(regionId);
  if (match == null) return null;

  final int? index = int.tryParse(match.namedGroup('index') ?? '');
  final int? duration = int.tryParse(match.namedGroup('duration') ?? '');
  if (index == null || index < 0 || duration == null || duration <= 0) {
    return null;
  }

  return StructuralRuntimeMarker(
    placementIndex: index,
    durationFrames: duration,
  );
}

/// Resolves the authored STRUCT local frame from terminal pause state.
///
/// Runtime projection is deliberately two deterministic parser phases:
///
///   frame 0  REGION marker
///   frame 1  PAUSE entry
///   frame 2+ explicit pause age
///
/// The REGION is kept through the tick that completes the pause, so the final
/// authored structural frame remains visible. On the next free terminal tick
/// engine_tick.dart clears the reserved region before ordinary script content
/// resumes.
int structuralRuntimeLocalFrame({
  required StructuralRuntimeMarker marker,
  required int pauseFramesRemaining,
  required bool awaitingPauseTag,
}) {
  final int duration = marker.durationFrames;
  if (duration <= 1) return 0;

  // Immediately after the REGION marker has been parsed, the internal PAUSE
  // is still the next token. That exact frame is authored local frame zero.
  if (awaitingPauseTag) return 0;

  if (pauseFramesRemaining > 0) {
    final int pauseBudget = _projectedPauseFramesForEvent(duration);
    return (1 + (pauseBudget - pauseFramesRemaining))
        .clamp(0, duration - 1)
        .toInt();
  }

  // The pause-completion tick intentionally keeps the structural REGION alive
  // for one paint. That is the final authored frame, not a stale extra hold.
  return duration - 1;
}

class StructuralSequencePlacement {
  final StructuralSourceRef sourceRef;
  final int lineIndex;
  final int startOffset;
  final int endOffset;

  /// Authored source duration from EDIT/MOSAIC. This is the number of frames
  /// the structural compositor itself advances.
  final int sourceDurationFrames;

  /// Full main-sequence duration after adjacency/application-switch planning.
  final int durationFrames;

  /// Placement presentation, independent of EDIT/MOSAIC composition.
  final StructuralPresentationMode presentationMode;

  /// Placement-owned window/player chrome. Empty title means the canonical
  /// source name. TOP/BOTTOM are dormant unless overlayMode is CUSTOM, but are
  /// preserved so switching to DEFAULT/NONE and back does not destroy copy.
  final StructuralOverlayMode overlayMode;
  final String windowTitle;
  final String topOverlay;
  final String bottomOverlay;

  /// True when the previous/next runnable presentation is this neighbouring
  /// STRUCT placement. Chaining suppresses the terminal zoom between them.
  final bool chainedFromPrevious;
  final bool chainedToNext;

  /// Stronger form of chaining enabled by APPSWITCH:SLIDE. No close/open is
  /// paid when geometry is unchanged. If geometry changes, the incoming
  /// placement owns one window-animation budget for the morph.
  final bool seamlessFromPrevious;
  final bool seamlessToNext;

  /// Needed only for a seamless windowed <-> fullscreen geometry morph.
  final StructuralPresentationMode? previousPresentationMode;

  const StructuralSequencePlacement({
    required this.sourceRef,
    required this.lineIndex,
    required this.startOffset,
    required this.endOffset,
    required this.sourceDurationFrames,
    required this.durationFrames,
    this.presentationMode = StructuralPresentationMode.windowed,
    this.overlayMode = StructuralOverlayMode.defaultOverlay,
    this.windowTitle = '',
    this.topOverlay = '',
    this.bottomOverlay = '',
    this.chainedFromPrevious = false,
    this.chainedToNext = false,
    this.seamlessFromPrevious = false,
    this.seamlessToNext = false,
    this.previousPresentationMode,
  });

  bool get resolves => sourceDurationFrames > 0;
  bool get fullscreen =>
      presentationMode == StructuralPresentationMode.fullscreen;
  String get effectiveWindowTitle =>
      windowTitle.trim().isEmpty ? sourceRef.canonicalSource : windowTitle;
  int get effectiveDurationFrames => durationFrames > 0 ? durationFrames : 1;

  int get entryZoomFrames =>
      chainedFromPrevious ? 0 : kStructuralZoomFrames;

  int get entryWindowFrames {
    if (!chainedFromPrevious) return kStructuralWindowFrames;
    if (!seamlessFromPrevious) return kStructuralWindowFrames;
    if (previousPresentationMode != null &&
        previousPresentationMode != presentationMode) {
      return kStructuralWindowFrames;
    }
    return 0;
  }

  int get exitWindowFrames {
    if (!chainedToNext) return kStructuralWindowFrames;
    return seamlessToNext ? 0 : kStructuralWindowFrames;
  }

  int get exitZoomFrames => chainedToNext ? 0 : kStructuralZoomFrames;

  int get contentStartFrame => entryZoomFrames + entryWindowFrames;
  int get contentEndFrameExclusive => contentStartFrame + sourceDurationFrames;
  int get closingStartFrame => contentEndFrameExclusive;
  int get zoomInStartFrame => closingStartFrame + exitWindowFrames;

  StructuralSequenceStage stageAt(int sequenceFrame) {
    final int f = sequenceFrame
        .clamp(0, durationFrames > 0 ? durationFrames - 1 : 0)
        .toInt();

    if (entryZoomFrames > 0 && f < entryZoomFrames) {
      return StructuralSequenceStage.zoomOut;
    }
    if (entryWindowFrames > 0 && f < contentStartFrame) {
      return StructuralSequenceStage.opening;
    }
    if (f < contentEndFrameExclusive) {
      return StructuralSequenceStage.showing;
    }
    if (exitWindowFrames > 0 && f < zoomInStartFrame) {
      return StructuralSequenceStage.closing;
    }
    return StructuralSequenceStage.zoomIn;
  }

  int stageFrameAt(int sequenceFrame) {
    final int f = sequenceFrame
        .clamp(0, durationFrames > 0 ? durationFrames - 1 : 0)
        .toInt();
    switch (stageAt(f)) {
      case StructuralSequenceStage.zoomOut:
        return f;
      case StructuralSequenceStage.opening:
        return f - entryZoomFrames;
      case StructuralSequenceStage.showing:
        return f - contentStartFrame;
      case StructuralSequenceStage.closing:
        return f - closingStartFrame;
      case StructuralSequenceStage.zoomIn:
        return f - zoomInStartFrame;
    }
  }

  int stageDuration(StructuralSequenceStage stage) {
    return switch (stage) {
      StructuralSequenceStage.zoomOut => entryZoomFrames,
      StructuralSequenceStage.opening => entryWindowFrames,
      StructuralSequenceStage.showing => sourceDurationFrames,
      StructuralSequenceStage.closing => exitWindowFrames,
      StructuralSequenceStage.zoomIn => exitZoomFrames,
    };
  }

  double stageProgressAt(int sequenceFrame) {
    final StructuralSequenceStage stage = stageAt(sequenceFrame);
    final int frames = stageDuration(stage);
    if (frames <= 1) return 1.0;
    return (stageFrameAt(sequenceFrame) / (frames - 1)).clamp(0.0, 1.0);
  }

  int sourceFrameAt(int sequenceFrame) {
    if (sourceDurationFrames <= 0) return 0;
    return (sequenceFrame - contentStartFrame)
        .clamp(0, sourceDurationFrames - 1)
        .toInt();
  }
}

class _StructuralPlacementSeed {
  final RegExpMatch match;
  final StructuralSourceRef sourceRef;
  final int sourceDurationFrames;
  final StructuralPresentationMode presentationMode;
  final StructuralOverlayMode overlayMode;
  final String windowTitle;
  final String topOverlay;
  final String bottomOverlay;

  const _StructuralPlacementSeed({
    required this.match,
    required this.sourceRef,
    required this.sourceDurationFrames,
    required this.presentationMode,
    required this.overlayMode,
    required this.windowTitle,
    required this.topOverlay,
    required this.bottomOverlay,
  });
}

List<int> _lineStarts(String source) {
  final List<int> starts = <int>[0];
  for (int i = 0; i < source.length; i++) {
    if (source.codeUnitAt(i) == 10) starts.add(i + 1);
  }
  return starts;
}

int _lineForOffset(List<int> starts, int offset) {
  int lo = 0;
  int hi = starts.length - 1;
  while (lo < hi) {
    final int mid = (lo + hi + 1) ~/ 2;
    if (starts[mid] <= offset) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo;
}

EditDocumentModel? _tryModel(String rawDocument) {
  try {
    return EditDocumentModel.parse(rawDocument);
  } catch (_) {
    return null;
  }
}

bool _slideAppSwitchEnabled(String rawDocument) {
  final List<RegExpMatch> matches =
      _appSwitchConfig.allMatches(rawDocument).toList(growable: false);
  if (matches.isEmpty) return false;
  return (matches.last.namedGroup('mode') ?? '').toUpperCase() == 'SLIDE';
}

/// Whether two placement tags are consecutive in executable program content.
/// Comments, CONFIG declarations, and reusable EDIT/MOSAIC source definitions
/// consume no terminal time, so they do not break a structural application
/// chain. Real text, PAUSE, or another visible presentation does.
bool _runtimeGapIsEmpty(String gap) {
  String stripped = gap.replaceAll(
    RegExp(
      r'\[EDIT:[^\]\r\n]+\].*?\[/EDIT\]',
      dotAll: true,
    ),
    '',
  );
  stripped = stripped.replaceAll(
    RegExp(
      r'\[MOSAIC:[^\]\r\n]+\].*?\[/MOSAIC\]',
      dotAll: true,
    ),
    '',
  );
  stripped = stripped.replaceAll(RegExp(r'\[#.*?\]', dotAll: true), '');
  stripped = stripped.replaceAll(RegExp(r'\[CONFIG:[^\]\r\n]+\]'), '');
  return stripped.trim().isEmpty;
}

int _plannedDuration({
  required int sourceFrames,
  required bool chainedFromPrevious,
  required bool chainedToNext,
  required bool seamlessFromPrevious,
  required bool seamlessToNext,
  required StructuralPresentationMode presentationMode,
  required StructuralPresentationMode? previousPresentationMode,
}) {
  if (sourceFrames <= 0) return 0;

  final int entryZoom = chainedFromPrevious ? 0 : kStructuralZoomFrames;

  int entryWindow;
  if (!chainedFromPrevious) {
    entryWindow = kStructuralWindowFrames;
  } else if (!seamlessFromPrevious) {
    entryWindow = kStructuralWindowFrames;
  } else if (previousPresentationMode != null &&
      previousPresentationMode != presentationMode) {
    entryWindow = kStructuralWindowFrames;
  } else {
    entryWindow = 0;
  }

  final int exitWindow =
      (!chainedToNext || !seamlessToNext) ? kStructuralWindowFrames : 0;
  final int exitZoom = chainedToNext ? 0 : kStructuralZoomFrames;

  return entryZoom +
      entryWindow +
      sourceFrames +
      exitWindow +
      exitZoom;
}

/// Returns every standalone structural placement in raw document order.
///
/// Invalid or temporarily incomplete structural source definitions do not make
/// the text editor crash while the author is typing. Their placements remain
/// visible with duration 0 so diagnostics can report them and the engine
/// projection can burn a small harmless fallback instead of typing literal
/// markup onto screen.
///
/// This pass also performs structural application planning. It is deliberately
/// based on authored document adjacency rather than widget state, so Preview,
/// Bake, scrub, and runtime projection all get the same duration answer.
List<StructuralSequencePlacement> parseStructuralSequencePlacements(
  String rawDocument,
) {
  final EditDocumentModel? model = _tryModel(rawDocument);
  final List<int> starts = _lineStarts(rawDocument);
  final List<_StructuralPlacementSeed> seeds = <_StructuralPlacementSeed>[];

  for (final RegExpMatch match in _placementLine.allMatches(rawDocument)) {
    final StructuralChromeSpec? chrome =
        parseStructuralChromeTag(match.namedGroup('tag') ?? '');
    if (chrome == null) continue;

    final StructuralSourceRef? ref = StructuralSourceRef.tryParse(chrome.source);
    if (ref == null || ref.id.isEmpty) continue;

    int sourceDuration = 0;
    if (model != null && model.containsStructuralSource(ref)) {
      try {
        sourceDuration = model.structuralSourceFrameCount(ref);
      } catch (_) {
        sourceDuration = 0;
      }
    }

    seeds.add(
      _StructuralPlacementSeed(
        match: match,
        sourceRef: ref,
        sourceDurationFrames: sourceDuration,
        presentationMode: chrome.fullscreen
            ? StructuralPresentationMode.fullscreen
            : StructuralPresentationMode.windowed,
        overlayMode: chrome.overlayMode,
        windowTitle: chrome.windowTitle,
        topOverlay: chrome.topOverlay,
        bottomOverlay: chrome.bottomOverlay,
      ),
    );
  }

  if (seeds.isEmpty) return const <StructuralSequencePlacement>[];

  final bool slide = _slideAppSwitchEnabled(rawDocument);
  final List<bool> chainedFrom = List<bool>.filled(seeds.length, false);
  final List<bool> chainedTo = List<bool>.filled(seeds.length, false);
  final List<bool> seamlessFrom = List<bool>.filled(seeds.length, false);
  final List<bool> seamlessTo = List<bool>.filled(seeds.length, false);

  for (int i = 0; i + 1 < seeds.length; i++) {
    final _StructuralPlacementSeed current = seeds[i];
    final _StructuralPlacementSeed next = seeds[i + 1];
    final String gap = rawDocument.substring(
      current.match.end,
      next.match.start,
    );
    if (!_runtimeGapIsEmpty(gap)) continue;

    chainedTo[i] = true;
    chainedFrom[i + 1] = true;
    if (slide) {
      seamlessTo[i] = true;
      seamlessFrom[i + 1] = true;
    }
  }

  final List<StructuralSequencePlacement> out =
      <StructuralSequencePlacement>[];
  for (int i = 0; i < seeds.length; i++) {
    final _StructuralPlacementSeed seed = seeds[i];
    final StructuralPresentationMode? previousMode =
        chainedFrom[i] && i > 0 ? seeds[i - 1].presentationMode : null;

    final int duration = _plannedDuration(
      sourceFrames: seed.sourceDurationFrames,
      chainedFromPrevious: chainedFrom[i],
      chainedToNext: chainedTo[i],
      seamlessFromPrevious: seamlessFrom[i],
      seamlessToNext: seamlessTo[i],
      presentationMode: seed.presentationMode,
      previousPresentationMode: previousMode,
    );

    out.add(
      StructuralSequencePlacement(
        sourceRef: seed.sourceRef,
        lineIndex: _lineForOffset(starts, seed.match.start),
        startOffset: seed.match.start,
        endOffset: seed.match.end,
        sourceDurationFrames: seed.sourceDurationFrames,
        durationFrames: duration,
        presentationMode: seed.presentationMode,
        overlayMode: seed.overlayMode,
        windowTitle: seed.windowTitle,
        topOverlay: seed.topOverlay,
        bottomOverlay: seed.bottomOverlay,
        chainedFromPrevious: chainedFrom[i],
        chainedToNext: chainedTo[i],
        seamlessFromPrevious: seamlessFrom[i],
        seamlessToNext: seamlessTo[i],
        previousPresentationMode: previousMode,
      ),
    );
  }

  return List<StructuralSequencePlacement>.unmodifiable(out);
}

/// Appends one structural source as the next event in the main TEXT sequence.
///
/// Source definitions remain where they already live. The sequence receives
/// only a lightweight reference and derives its duration from the selected
/// EDIT/MOSAIC definition. Presentation mode and chrome belong to this
/// placement rather than to the reusable source.
String appendStructuralSequencePlacement({
  required String rawDocument,
  required StructuralSourceRef sourceRef,
  StructuralPresentationMode presentationMode =
      StructuralPresentationMode.windowed,
  StructuralOverlayMode overlayMode = StructuralOverlayMode.defaultOverlay,
  String windowTitle = '',
  String topOverlay = '',
  String bottomOverlay = '',
}) {
  final EditDocumentModel model = EditDocumentModel.parse(rawDocument);
  if (!model.containsStructuralSource(sourceRef)) {
    throw StateError('No structural source named ${sourceRef.canonicalSource}.');
  }

  final int duration = model.structuralSourceFrameCount(sourceRef);
  if (duration <= 0) {
    throw StateError('${sourceRef.canonicalSource} has no authored frames.');
  }

  final String newline = rawDocument.contains('\r\n') ? '\r\n' : '\n';
  final StringBuffer out = StringBuffer(rawDocument);
  if (rawDocument.isNotEmpty &&
      !rawDocument.endsWith('\n') &&
      !rawDocument.endsWith('\r')) {
    out.write(newline);
  }
  out.write(
    formatStructuralChromeTag(
      StructuralChromeSpec(
        source: sourceRef.canonicalSource,
        fullscreen:
            presentationMode == StructuralPresentationMode.fullscreen,
        overlayMode: overlayMode,
        windowTitle: windowTitle,
        topOverlay: topOverlay,
        bottomOverlay: bottomOverlay,
      ),
    ),
  );
  out.write(newline);
  return out.toString();
}

/// Replaces sequence placements in an already root-stripped engine projection.
///
/// Editor line-map compilation uses a plain compensated PAUSE so its authored
/// line continues to own exactly the STRUCT event budget. Real Preview/Bake
/// compilation can request [runtimeMarkers], which writes an internal REGION
/// immediately before the same compensated PAUSE.
///
/// Durations come from [parseStructuralSequencePlacements], not from a second
/// local formula. This is load-bearing now that adjacent structural apps can
/// suppress terminal zooms or window close/open frames: Preview, editor scrub,
/// and Bake must project the exact same planned event budget.
///
/// Runtime-only chaining has one additional rule: the control-only gap between
/// two placements that the planner marked as adjacent is removed entirely.
/// Leaving the authored newline there would make TerminalEngine spend a real
/// frame consuming it at normal typing speed, clear the reserved STRUCT region,
/// and briefly expose the base program between A and B. Comments, CONFIG tags,
/// indentation, and line breaks in that gap own no program time, so Preview and
/// Bake collapse them just as the existing desktop presentation hand-off skips
/// them. The editor line-map path keeps the authored line structure unchanged.
String projectStructuralSequencePlacements({
  required String rawDocument,
  required String projectedSource,
  bool runtimeMarkers = false,
}) {
  final List<RegExpMatch> matches =
      _placementLine.allMatches(projectedSource).toList(growable: false);
  if (matches.isEmpty) return projectedSource;

  final List<StructuralSequencePlacement> placements =
      parseStructuralSequencePlacements(rawDocument);

  final StringBuffer out = StringBuffer();
  int cursor = 0;

  for (int index = 0; index < matches.length; index++) {
    final RegExpMatch match = matches[index];
    final StructuralSequencePlacement? placement =
        index < placements.length ? placements[index] : null;

    final bool collapseGap = runtimeMarkers &&
        index > 0 &&
        index - 1 < placements.length &&
        placements[index - 1].chainedToNext;

    if (!collapseGap) {
      out.write(projectedSource.substring(cursor, match.start));
    }

    final int eventDuration = placement?.durationFrames ?? 0;
    final int pauseFrames = _projectedPauseFramesForEvent(eventDuration);

    if (runtimeMarkers && eventDuration > 0) {
      final StructuralRuntimeMarker runtime = StructuralRuntimeMarker(
        placementIndex: index,
        durationFrames: eventDuration,
      );
      // Runtime markers are implementation details. Authored indentation and
      // trailing spaces around a control-only STRUCT line must not become
      // executable terminal characters before or after the marker.
      out.write('[REGION:${runtime.regionId}][PAUSE:$pauseFrames]');
    } else {
      final String indent = match.namedGroup('indent') ?? '';
      final String trail = match.namedGroup('trail') ?? '';
      out.write('$indent[PAUSE:$pauseFrames]$trail');
    }

    cursor = match.end;
  }

  out.write(projectedSource.substring(cursor));
  return out.toString();
}
