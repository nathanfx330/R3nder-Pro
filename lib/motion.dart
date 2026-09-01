// ./lib/motion.dart

// =====================================================================
// PANE LIFE
//
// Mosaic panes used to sit dead once they had cascaded in. Pane Life walks
// them serially. Legacy one-image panes keep the original slow push. An
// authored pane can instead contain several ordered source images, nominate
// one hero for the push, and choose a left-to-right or right-to-left read.
//
// SERIAL, NOT STAGGERED. An earlier version overlapped the pushes, offset
// off the cascade, so all three panes drifted at once. It reads as the
// whole page breathing. Visiting panes one at a time reads as attention
// moving across the page, which is the thing worth having: the sequence
// itself does the work a pointer would otherwise have to do.
//
// THE CONSTRAINT THAT SHAPES EVERYTHING HERE: frame counts do not move.
// The motion lives entirely inside cascadeTotalFrames + holdFrames, which
// already governs when a page advances. Nothing new is scheduled, so
// turning this on cannot re-time a finished piece. Bake before, bake
// after, diff the durations: they match or this is wrong.
//
// Everything in this file is a pure function of an integer frame index.
// Nothing accumulates. That is not stylistic: the export path resets and
// replays constantly, and a value that depends on how you arrived at a
// frame makes a scrub from zero and a scrub from frame 900 disagree in
// the last decimal.
//
// EDGE SAFETY, now that a pane can fit its vertical edge instead of
// cropping to fill. The push cannot expose the plate because
// kPaneMinZoomPercent is 100: an image flush to the pane's top and bottom
// only ever scales UP. The walk cannot expose it either, because the
// painter clamps focusX to the crop overflow that actually exists, which
// for a letterboxed source is zero. A tall source in a FIT pane therefore
// pushes without travelling, which is also the correct read: you do not
// pan across a portrait.
// =====================================================================

/// Easing curves, as a closed set.
///
/// A craft note that belongs in the manual too. OUT reads as arriving and
/// settling, which suits a panel that has just landed. INOUT is the
/// conventional camera move, because a real dolly has to accelerate
/// before it can decelerate. INOUT is the default here: a panel drifting
/// for the whole of a long hold is photography, not an arrival.
enum Ease { linear, easeIn, easeOut, easeInOut }

double applyEase(Ease e, double t) {
  final double x = t.clamp(0.0, 1.0);
  switch (e) {
    case Ease.linear:
      return x;
    case Ease.easeIn:
      return x * x;
    case Ease.easeOut:
      final double inv = 1.0 - x;
      return 1.0 - inv * inv;
    case Ease.easeInOut:
      // Smoothstep. Zero derivative at both ends, so a panel starts and
      // stops without a visible kick.
      return x * x * (3.0 - 2.0 * x);
  }
}

Ease? easeFromName(String raw) {
  switch (raw.trim().toUpperCase()) {
    case 'LINEAR':
      return Ease.linear;
    case 'IN':
      return Ease.easeIn;
    case 'OUT':
      return Ease.easeOut;
    case 'INOUT':
      return Ease.easeInOut;
  }
  return null;
}

/// A two-point eased ramp over an integer frame span.
///
/// Deliberately not a keyframe track. R3nder's time is ordinal: events
/// happen in the order they are written and each owns a bounded span. A
/// ramp describes how a value varies ACROSS a span that already exists,
/// which changes no frame count and moves no event. Anything that needs
/// events to move, split, or overlap is a timeline, and a timeline is the
/// thing this tool exists not to be.
class MotionRamp {
  final double from;
  final double to;
  final Ease ease;

  /// Offset from the owning phase's frame zero.
  final int startFrame;

  /// Duration in frames. Zero or negative means the ramp never runs and
  /// [valueAt] returns [from] throughout.
  final int frames;

  const MotionRamp({
    required this.from,
    required this.to,
    required this.startFrame,
    required this.frames,
    this.ease = Ease.easeInOut,
  });

  /// Value at [framesIntoPhase]. Held at [from] before the ramp starts and
  /// at [to] after it ends, so a panel that finishes early simply rests.
  double valueAt(int framesIntoPhase) {
    if (frames <= 0) return from;
    final int local = framesIntoPhase - startFrame;
    if (local <= 0) return from;
    if (local >= frames) return to;
    return from + (to - from) * applyEase(ease, local / frames);
  }
}

// ---------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------

/// Default zoom target, as a percentage of the cover fit.
///
/// 102 is deliberately small. At panel size a two percent push over a
/// second reads as the image being alive rather than as a zoom, and
/// anything a viewer can point at has gone too far.
const double kPaneDefaultZoomPercent = 102.0;

/// Bounds on the zoom target. The floor is exactly still.
const double kPaneMinZoomPercent = 100.0;
const double kPaneMaxZoomPercent = 115.0;

/// Shortest slot that can still read as a push rather than a twitch.
///
/// Sized against the defaults: an [APP] hold defaults to 90 frames, and
/// MOSAIC pages hold up to three panes, so the default script gives each pane
/// exactly 30 frames. A multi-image pane spends that same slot internally;
/// grouping never buys more time.
const int kPaneMinPushFrames = 20;

/// How pane life is configured for a script. Off unless asked for.
class PaneLifeConfig {
  final bool enabled;

  /// Zoom target as a percentage of cover fit. 102 means push to 102%.
  ///
  /// A percentage rather than a fraction because that is how the move is
  /// actually discussed. Nobody has an intuition for 0.02; everyone has
  /// one for 102%.
  final double zoomPercent;

  final Ease ease;

  const PaneLifeConfig({
    this.enabled = false,
    this.zoomPercent = kPaneDefaultZoomPercent,
    this.ease = Ease.easeInOut,
  });

  static const PaneLifeConfig off = PaneLifeConfig();

  /// Scale multiplier the push ends on.
  double get zoomScale => zoomPercent / 100.0;

  /// Parses `[CONFIG:PANELIFE:...]`.
  ///
  /// Accepted: `ON`, `ON:102`, `ON:102:INOUT`. Anything unrecognised falls
  /// back to a default rather than failing, because a config typo should
  /// cost you an effect, not a render.
  ///
  /// Rides on the generic CONFIG parsing, which is why this costs no
  /// grammar change: no regex alternation, no node round-trip case, no
  /// knownTags entry.
  static PaneLifeConfig parse(String? raw) {
    if (raw == null) return off;
    final List<String> parts = raw.split(':').map((s) => s.trim()).toList();
    if (parts.isEmpty) return off;

    final String head = parts[0].toUpperCase();
    if (head != 'ON' && head != 'TRUE' && head != '1') return off;

    double zoom = kPaneDefaultZoomPercent;
    if (parts.length > 1) {
      final double? v = double.tryParse(parts[1]);
      if (v != null) {
        zoom = v.clamp(kPaneMinZoomPercent, kPaneMaxZoomPercent).toDouble();
      }
    }

    Ease ease = Ease.easeInOut;
    if (parts.length > 2) {
      ease = easeFromName(parts[2]) ?? Ease.easeInOut;
    }

    return PaneLifeConfig(enabled: true, zoomPercent: zoom, ease: ease);
  }
}

// ---------------------------------------------------------------------
// Resolved motion for one authored pane
// ---------------------------------------------------------------------

/// What the painter needs for the current image inside a pane.
///
/// [scale] is the familiar Pane Life push. [focusX] is a normalized crop
/// bias from -1 (show the source's left edge) through 0 (centred) to +1
/// (show the right edge). The painter clamps this inside the fitted
/// overscan, so a directional move can never expose an empty edge.
///
/// [fit] is not motion, and it is carried here anyway. It rides along
/// because this class is already defined as everything the painter needs to
/// draw one image inside one pane, and the alternative is a second lookup
/// on the paint path that answers a question the first one could have.
///
/// It is a local enum rather than the authoring one on purpose. This file
/// stays free of any dependency on the script language, exactly as
/// PaneSequenceSpec stays free of ui.Image: PaneFit is what an author
/// writes, [PaneFitMode] is what a painter branches on, and SceneEngine is
/// the one place that converts between them. It was a bool while there
/// were two states; fitWidth made that untenable, which is the usual fate
/// of a bool that stands in for a choice.
///
/// Note that fit is NOT part of [isIdentity]. A pane that fits an edge and
/// never moves is still motionless, and any caller asking whether motion is
/// happening should get the answer yes-or-no about motion.
class PaneMotion {
  final double scale;
  final double focusX;
  final PaneFitMode fit;

  const PaneMotion(this.scale,
      {this.focusX = 0.0, this.fit = PaneFitMode.fill});

  static const PaneMotion none = PaneMotion(1.0);

  bool get isIdentity => scale == 1.0 && focusX == 0.0;

  /// This move, drawn under a different fit rule.
  ///
  /// Exists so fit can be applied ONCE, downstream of every branch that
  /// decides what a pane is doing on a frame. The alternatives were adding
  /// the flag to a dozen construction sites across two files, or teaching
  /// PanePlan about fit so it could stamp its own returns. Both leave a
  /// path where a pane renders with the wrong fit because one branch was
  /// missed, and the branch most likely to be missed is the one taken when
  /// Pane Life is off, which is precisely when fit still has to work.
  PaneMotion withFit(PaneFitMode next) =>
      next == fit ? this : PaneMotion(scale, focusX: focusX, fit: next);
}

/// How the painter scales an image into a pane rect.
///
/// The runtime half of PaneFit. Named for the geometry rather than for the
/// keyword, because the keyword has history the painter should not have to
/// know about: `FIT` in a script means the vertical edge for reasons of
/// release order, not of meaning.
enum PaneFitMode {
  /// `max(rw / iw, rh / ih)`. Crops, never letterboxes.
  fill,

  /// `rh / ih`. Flush top and bottom, letterboxed left and right.
  height,

  /// `rw / iw`. Flush left and right, letterboxed top and bottom.
  width,
}

/// The source image and camera move a pane should show on one exact frame.
class PaneFrame {
  final int imageIndex;
  final PaneMotion motion;

  const PaneFrame({required this.imageIndex, required this.motion});
}

/// Pure authored facts for one pane. This deliberately knows nothing about
/// ui.Image; SceneEngine converts its AppPaneSpec into this small timing DTO.
class PaneSequenceSpec {
  final int imageCount;

  /// Null means this pane is not selected for Pane Life. This is the runtime
  /// reflection of the language: CONFIG enables the feature globally, while
  /// `@hero` on an APP pane token opts that pane into motion.
  final int? heroIndex;
  final bool reverse;

  /// Extra frames per image, indexed within the pane.
  ///
  /// The only value in this file that adds time rather than dividing it.
  /// Everything else here answers "where in the hold are we"; this changes
  /// how long the hold is. It is carried on the sequence because the beat
  /// allocation below has to know WHICH image bought the extra frames, not
  /// merely that the slot got longer.
  final List<int> holds;

  const PaneSequenceSpec({
    required this.imageCount,
    required this.heroIndex,
    this.reverse = false,
    this.holds = const [],
  });

  bool get selected => heroIndex != null;

  int holdAt(int i) =>
      (i < 0 || i >= holds.length) ? 0 : (holds[i] < 0 ? 0 : holds[i]);

  /// Frames this pane adds to its page, whether or not it is selected.
  int get totalHold {
    int t = 0;
    for (final int h in holds) {
      if (h > 0) t += h;
    }
    return t;
  }

  /// Where this pane sits before its slot opens.
  ///
  /// A multi-image walk sweeps focusX from one edge to the other, so its
  /// first animated frame is already at the far edge. Resting at centre
  /// until then meant the crop jumped half the COVER overflow in a single
  /// frame the instant the slot opened, which on a wide plate in a tall
  /// pane is most of the panel width, at exactly the moment that pane
  /// becomes the thing being looked at.
  ///
  /// Derived from the SPEC rather than from a PanePlan, because the caller
  /// that needs it most is drawing a page that is not the held one, and a
  /// plan only ever describes the held page. Asking a plan for a pane on
  /// another page returns some other pane's answer.
  ///
  /// Single-image panes park centred: their push is pure scale from 1.0,
  /// which is already continuous.
  PaneMotion get walkStartMotion {
    if (!selected || imageCount <= 1) return PaneMotion.none;
    return PaneMotion(1.0, focusX: reverse ? 1.0 : -1.0);
  }
}

/// Timing for the panes of one mosaic page.
///
/// The page hold is still divided by PANE count, exactly as the legacy
/// implementation divided it by panel count. An authored pane can then walk
/// several source images inside its own slot without owning any new time.
class PanePlan {
  final PaneLifeConfig config;

  /// Frame each pane begins its authored walk, indexed by pane.
  final List<int> starts;

  /// Frames each pane owns, indexed by pane. Last pane absorbs the remainder.
  final List<int> durations;

  final List<PaneSequenceSpec> sequences;
  final bool active;

  const PanePlan._({
    required this.config,
    required this.starts,
    required this.durations,
    required this.sequences,
    required this.active,
  });

  static const PanePlan disabled = PanePlan._(
    config: PaneLifeConfig.off,
    starts: [],
    durations: [],
    sequences: [],
    active: false,
  );

  bool get isActive => active;
  int get slotFrames => durations.isEmpty ? 0 : durations.first;

  /// Builds the plan for one page. Motion begins after the first-page cascade
  /// and ends inside the hold that page already owned.
  ///
  /// Only panes with an explicit hero consume Pane Life time. This is the
  /// crucial selective-authoring rule: `[CONFIG:PANELIFE:ON]` does not create
  /// motion by itself. If one pane is starred it owns the page hold; if two
  /// are starred they split it; unstarred panes never receive a motion slot.
  factory PanePlan.build({
    required PaneLifeConfig config,
    required List<PaneSequenceSpec> panes,
    required int cascadeFrames,
    required int holdFrames,
  }) {
    if (!config.enabled || panes.isEmpty) return disabled;

    final List<int> selected = <int>[
      for (int i = 0; i < panes.length; i++)
        if (panes[i].selected) i,
    ];
    if (selected.isEmpty) return disabled;

    // [holdFrames] is the BASE hold, before any authored extension. The
    // page's real budget is base + every extension on it, and the two are
    // kept apart here on purpose: dividing the grown hold by pane count
    // would spread one pane's extra frames across all of them, so a +45 on
    // pane one would quietly fatten pane two's slot as well.
    final int extensionTotal = <int>[
      for (final int i in selected) panes[i].totalHold,
    ].fold(0, (a, b) => a + b);

    final int slot = holdFrames ~/ selected.length;

    // Checked against each pane's REAL duration, base plus its own
    // extension, rather than against the bare slot. A page that was too
    // tight to walk can now be rescued by authoring the frames it needs,
    // which is the honest answer to "hold too short": buy more hold.
    // Still all-or-nothing per page, as before, because a page where one
    // hero pushes and another sits still reads as a bug.
    bool anyTooShort = false;
    for (final int i in selected) {
      if (slot + panes[i].totalHold < kPaneMinPushFrames) {
        anyTooShort = true;
        break;
      }
    }
    if (anyTooShort) {
      return PanePlan._(
        config: config,
        starts: const [],
        durations: const [],
        sequences: List<PaneSequenceSpec>.unmodifiable(panes),
        active: false,
      );
    }

    // Arrays stay indexed by visual pane so the painter/engine never need a
    // second mapping. Unselected panes carry -1/0 and frameAt() returns them
    // completely static.
    //
    // Walked cumulatively rather than by multiplying the slot, because
    // panes no longer all have the same length: a pane that bought extra
    // frames pushes every pane after it later by exactly that much.
    final List<int> starts = List<int>.filled(panes.length, -1);
    final List<int> durations = List<int>.filled(panes.length, 0);
    int cursor = cascadeFrames;
    for (int order = 0; order < selected.length; order++) {
      final int paneIndex = selected[order];
      final int base = order == selected.length - 1
          ? holdFrames - order * slot
          : slot;
      starts[paneIndex] = cursor;
      durations[paneIndex] = base + panes[paneIndex].totalHold;
      cursor += durations[paneIndex];
    }

    assert(
        cursor == cascadeFrames + holdFrames + extensionTotal,
        'Pane slots must exactly fill the base hold plus every extension '
        'authored on a selected pane, or the page advance and the motion '
        'plan disagree about when the page ends.');

    return PanePlan._(
      config: config,
      starts: starts,
      durations: durations,
      sequences: List<PaneSequenceSpec>.unmodifiable(panes),
      active: true,
    );
  }

  /// Exact display state for pane [i] at [framesIntoPhase].
  ///
  /// Unselected panes are always static. Selected one-image panes get the
  /// original slow push. Selected multi-image panes use their authored LR/RL
  /// walk and only the explicitly selected hero receives scale emphasis.
  PaneFrame frameAt(int i, int framesIntoPhase) {
    if (i < 0 || i >= sequences.length) {
      return const PaneFrame(imageIndex: 0, motion: PaneMotion.none);
    }

    final PaneSequenceSpec seq = sequences[i];
    final int count = seq.imageCount < 1 ? 1 : seq.imageCount;
    final int? heroIndex = seq.heroIndex;

    // No @hero in the language = no Pane Life for this pane. Grouping is
    // still meaningful for layout, but motion selection is intentionally
    // independent from grouping.
    if (heroIndex == null) {
      return const PaneFrame(imageIndex: 0, motion: PaneMotion.none);
    }

    final int hero = heroIndex.clamp(0, count - 1).toInt();
    final int first = seq.reverse ? count - 1 : 0;
    final int last = seq.reverse ? 0 : count - 1;

    if (!active || i >= starts.length || starts[i] < 0) {
      return PaneFrame(imageIndex: hero, motion: PaneMotion.none);
    }

    final int local = framesIntoPhase - starts[i];
    if (local <= 0) {
      // Parked at the start of the walk, not at centre.
      // See PaneSequenceSpec.walkStartMotion.
      return PaneFrame(imageIndex: first, motion: seq.walkStartMotion);
    }

    final int dur = durations[i];
    if (dur <= 0 || local >= dur) {
      final bool heroAtEnd = last == hero;
      return PaneFrame(
        imageIndex: last,
        motion: PaneMotion(heroAtEnd ? config.zoomScale : 1.0,
            focusX: count > 1 ? (seq.reverse ? -1.0 : 1.0) : 0.0),
      );
    }

    // Selected one-image pane: the original slow push, with no crop drift.
    if (count == 1) {
      final double t = applyEase(config.ease, local / dur);
      return PaneFrame(
        imageIndex: 0,
        motion: PaneMotion(1.0 + (config.zoomScale - 1.0) * t),
      );
    }

    // The hero owns the readable part of this mini-shot. Supporting images
    // are quicker context beats; the selected hero receives the push.
    //
    // Authored extensions are taken OFF the top and handed straight to the
    // image that bought them, then the remainder is split by the original
    // rule. That ordering is the whole point: folding extensions into the
    // slot and re-running the old split would give a +45 on image three to
    // the hero, because the hero takes half of whatever it is given.
    final int heroBeat = seq.reverse ? count - 1 - hero : hero;

    // Indexed by BEAT, not by image, so a reversed walk holds the
    // photograph you extended rather than its mirror position.
    final List<int> beatHold = List<int>.filled(count, 0);
    int extraTotal = 0;
    for (int img = 0; img < count; img++) {
      final int h = seq.holdAt(img);
      if (h <= 0) continue;
      final int b = seq.reverse ? count - 1 - img : img;
      beatHold[b] = h;
      extraTotal += h;
    }

    final int shared = mathMaxInt(count, dur - extraTotal);
    final int maxHero = shared - (count - 1);
    final int heroDur = mathMinInt(
        maxHero, mathMaxInt(kPaneMinPushFrames, shared ~/ 2));
    final int supportTotal = shared - heroDur;
    final int supportCount = count - 1;
    final int supportBase = supportTotal ~/ supportCount;
    int supportRemainder = supportTotal - supportBase * supportCount;

    int beat = 0;
    int beatStart = 0;
    int beatDur = 1;
    int cursor = 0;
    for (int b = 0; b < count; b++) {
      int d;
      if (b == heroBeat) {
        d = heroDur;
      } else {
        d = supportBase;
        if (supportRemainder > 0) {
          d++;
          supportRemainder--;
        }
      }
      d = mathMaxInt(1, d) + beatHold[b];
      final int end = cursor + d;
      if (local < end || b == count - 1) {
        beat = b;
        beatStart = cursor;
        beatDur = d;
        break;
      }
      cursor = end;
    }
    final double beatT = ((local - beatStart) / beatDur).clamp(0.0, 1.0);
    final int image = seq.reverse ? count - 1 - beat : beat;

    final double wholeT = (local / dur).clamp(0.0, 1.0);
    final double focus = seq.reverse
        ? 1.0 - wholeT * 2.0
        : -1.0 + wholeT * 2.0;

    final bool onHero = image == hero;
    final double scale = onHero
        ? 1.0 + (config.zoomScale - 1.0) * applyEase(config.ease, beatT)
        : 1.0;

    return PaneFrame(
      imageIndex: image,
      motion: PaneMotion(scale, focusX: focus),
    );
  }

  PaneMotion motionAt(int i, int framesIntoPhase) =>
      frameAt(i, framesIntoPhase).motion;
}

int mathMaxInt(int a, int b) => a > b ? a : b;
int mathMinInt(int a, int b) => a < b ? a : b;