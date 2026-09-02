// ./lib/engine_state.dart

part of 'engine.dart';

// Terminal render/state models. These live in the engine library so private
// implementation types remain private while engine.dart can focus on the
// deterministic state machine itself.

/// One step of an in-terminal SVG show: which stencil, for how many frames.
/// One entry in an [ActiveSvgShow]: which stencil to draw and for how long.
///
/// Public because [ActiveSvgShow.steps] is, and a public field typed on a
/// private class is a type callers can hold but cannot name.
class SvgStep {
  final String key; // Library key (file path relative to images/)
  final int frames;

  SvgStep({required this.key, required this.frames});
}

/// An in-terminal SVG show in flight. Unlike the desktop presentations this
/// NEVER suspends the engine to the SceneEngine — the terminal screen itself
/// is the canvas. The engine wiped on entry, holds here (frameCount keeps
/// advancing, deterministic), and wipes again on exit before resuming.
///
/// A single [SVG] tag is one step; an [SVGFLASH] is the folder's files
/// repeated `cycles` times at `framesPer` each. Chained SVG/SVGFLASH tags
/// CUT between shows: the exit wipe only plays when no chain is ahead.
class ActiveSvgShow {
  final List<SvgStep> steps;

  /// Fill color override from the tag's r,g,b segment, or null = the pen
  /// color snapshotted when the tag fired (so [RED][SVG:logo.svg] works).
  final Color color;

  int stepIdx = 0;
  int framesLeft;

  ActiveSvgShow({required this.steps, required this.color})
      : framesLeft = steps.isNotEmpty ? steps[0].frames : 0;

  String get currentKey => steps[stepIdx.clamp(0, steps.length - 1)].key;
}

/// An in-terminal slow-scan photo LAYER in flight. Reuses the ImgStencil
/// path logic but fits it to the screen and reveals it top-to-bottom.
///
/// STACKING (onion layers): PHOTO layers live together in
/// TerminalEngine._photoStack, painted bottom-to-top. A [PHOTO] carrying a
/// release segment is a "stack" layer: it opens the typing gate EARLY (at
/// [releaseAt], a % of the scan) and PERSISTS until an explicit wipe, so the
/// next PHOTO scans in directly OVER it. Off-pixels draw nothing, so lower
/// layers show through the gaps of upper ones — a solid mesh, then its
/// wireframe/edge pass over it in the SAME tint, building up structure like
/// passes on a single-color tube.
///
/// A [PHOTO] with NO release segment is a "classic" fullscreen layer:
/// [persist] is false and [releaseAt] equals the full hold — it blocks the
/// engine for its whole hold, then tears down / chain-cuts to the next show,
/// byte-identical to the pre-stack behavior.
class ActivePhotoShow {
  final String key; // "<channel>:<file>"
  final int holdFrames;
  final Color color;

  /// First terminal frame on which this layer is visible at scan age zero.
  /// Normal parser entry uses the next terminal frame; a classic chained
  /// PHOTO can CUT into another PHOTO after the frame has already advanced,
  /// so that path intentionally uses the current terminal frame instead.
  final int startFrame;

  /// Stack layer (true): persists until wipe, releases the gate early.
  /// Classic layer (false): blocks its whole hold, then tears down.
  final bool persist;

  /// Elapsed frame at which the typing gate opens. Stack: a % of the
  /// 30-frame scan. Classic: the full holdFrames (block until hold ends).
  final int releaseAt;

  /// Number of frames the scanline takes to reach the bottom.
  static const int scanDuration = 30; // 1 second at 30fps

  ActivePhotoShow({
    required this.key,
    required this.holdFrames,
    required this.color,
    required this.startFrame,
    this.persist = false,
    int releasePercent = 100,
  }) : releaseAt =
            persist ? scanGate(releasePercent) : math.max(holdFrames, 1);

  /// Frame within the scan at which a stack layer opens the gate. 100 (or
  /// more) = release only when the scan completes; otherwise that % of the
  /// scan, min 1 frame.
  static int scanGate(int percent) {
    if (percent >= 100) return scanDuration;
    final int r = (scanDuration * percent.clamp(0, 100) / 100).round();
    return r.clamp(1, scanDuration);
  }

  /// The frame past which nothing about this layer changes: the scan is
  /// done AND the gate has opened. Persisting layers remain on the onion
  /// stack after this point, but their derived age clamps here.
  int get settleFrame => math.max(releaseAt, scanDuration);

  /// Frames since this layer became visible, clamped once both reveal and
  /// gate timing have settled. No per-tick PHOTO counter is carried.
  int elapsedAt(int terminalFrame) {
    final int elapsed = terminalFrame - startFrame;
    if (elapsed <= 0) return 0;
    return elapsed >= settleFrame ? settleFrame : elapsed;
  }

  /// 0..1 progress of the scanline reveal at an explicit terminal frame.
  double revealProgressAt(int terminalFrame) =>
      (elapsedAt(terminalFrame) / scanDuration).clamp(0.0, 1.0);

  bool gateReleasedAt(int terminalFrame) =>
      elapsedAt(terminalFrame) >= releaseAt;
}

/// A preloaded [IMG] raster stencil: IBM 3279 Programmed Symbols emulation.
///
/// Built once by the SceneEngine at setup(): the scripted channel is read
/// from the source raster, hard-thresholded (>= 128 = on), and every
/// horizontal RUN of on-pixels is merged into one rect inside a single
/// ui.Path in PIXEL coordinates. The painter stamps the whole tile with one
/// drawPath per copy — no per-frame pixel reads, no image sampling, no
/// filtering. Hard pixel edges are guaranteed by construction: scaled-up
/// pixels are literally scaled rects.
///
/// Off pixels simply don't exist in the path — NOTHING is drawn there, the
/// terminal background shows through. No black is ever painted. Light on
/// the monitor, exactly like phosphor.
class ImgStencil {
  /// Native pixel dimensions of the source raster.
  final int pxWidth;
  final int pxHeight;

  /// On-pixels as merged rects, in pixel coordinates (0,0 = top-left).
  final Path path;

  ImgStencil({
    required this.pxWidth,
    required this.pxHeight,
    required this.path,
  });
}

/// Reveal state for an [IMG] band evaluated from explicit terminal-frame age.
///
/// The rendered line owns this object for as long as the band remains on
/// screen. Early gate release therefore needs no separate live timing list:
/// the painter can keep deriving reveal progress from [startFrame] while
/// later terminal content runs.
class ImgBandState {
  /// Frames between each copy revealing.
  final int framesPer;

  /// Total copies in the band (already clamped to the margins).
  final int copies;

  /// First terminal frame on which the band is visible at reveal age zero.
  final int startFrame;

  /// Elapsed frame at which the TYPING GATE releases, letting the content
  /// after this tag begin while the band keeps revealing behind it. Equal
  /// to [totalFrames] for a full block (the classic behavior); smaller when
  /// the tag scripts an early-release percentage. Always >= 1.
  final int releaseAt;

  ImgBandState({
    required this.framesPer,
    required this.copies,
    required this.startFrame,
    int releasePercent = 100,
  }) : releaseAt = gateFrames(copies, framesPer, releasePercent);

  /// The band reveals fully over this many frames.
  int get totalFrames => copies * math.max(framesPer, 1);

  int elapsedAt(int terminalFrame) {
    final int elapsed = terminalFrame - startFrame;
    if (elapsed <= 0) return 0;
    return elapsed >= totalFrames ? totalFrames : elapsed;
  }

  /// Copy 0 is visible the frame the band commits; copy k appears at
  /// elapsed >= k * framesPer. Sequential, left to right.
  int revealedCopiesAt(int terminalFrame) => math.min(
      copies,
      (elapsedAt(terminalFrame) ~/ math.max(framesPer, 1)) + 1);

  /// True when this band is a single tile rather than a repeating pattern.
  ///
  /// The two cases reveal differently, and [framesPer] means the same thing
  /// in both: how fast the band draws on. With copies to stagger it is the
  /// gap between them. With one tile there is nothing to stagger, so it is
  /// the time the scanline takes to cross it.
  bool get isSingle => copies <= 1;

  /// 0..1 scanline progress for a single-tile band, top to bottom.
  ///
  /// Always 1 for a repeating band: those reveal by copy and clipping them
  /// as well would be two competing animations on one element.
  ///
  /// COSTS NOTHING IN TIMING. A single-copy band already burned
  /// `1 * framesPer` frames on its gate while showing the finished tile the
  /// whole time, so the frames were being spent either way. This spends them
  /// drawing. Every existing script keeps its exact frame count and the tag
  /// after it lands on the same frame as before.
  double scanProgressAt(int terminalFrame) {
    if (!isSingle) return 1.0;
    final int span = math.max(framesPer, 1);
    return (elapsedAt(terminalFrame) / span).clamp(0.0, 1.0);
  }

  bool isDoneAt(int terminalFrame) =>
      elapsedAt(terminalFrame) >= totalFrames;

  bool gateReleasedAt(int terminalFrame) =>
      elapsedAt(terminalFrame) >= releaseAt;

  /// Frames the typing gate should hold for a band of [copies] x [framesPer]
  /// at the given release [percent] (0..100 = fraction of the full reveal).
  /// 100 or more = block the whole reveal (the classic behavior). Shared by
  /// the live band and the dud path so a MISSING asset costs the timeline
  /// exactly what a present one would — following text lands on the same
  /// frame either way.
  static int gateFrames(int copies, int framesPer, int percent) {
    final int total = copies * math.max(framesPer, 1);
    if (percent >= 100) return total;
    final int r = (total * percent.clamp(0, 100) / 100).round();
    return r.clamp(1, total);
  }
}

/// Everything the painter needs to draw an [IMG] band, attached to the
/// LineData that owns it. Styling is snapshotted at tag-fire time, same
/// rule as sprites: tint = pen color the moment the tag fired.
class ImgBandData {
  final ImgStencil stencil;

  /// Tint color (pen color at tag-fire — on-theme in green/amber/white
  /// modes automatically, same rule as SVG stencils).
  final Color color;

  /// Engine scale at commit (native px * this = drawn px).
  final double drawScale;

  /// Reveal state anchored to an explicit terminal start frame.
  final ImgBandState state;

  ImgBandData({
    required this.stencil,
    required this.color,
    required this.drawScale,
    required this.state,
  });

  double get tileDrawW => stencil.pxWidth * drawScale;
  double get tileDrawH => stencil.pxHeight * drawScale;
}

class _ActiveSprite {
  final String path;
  final List<List<String>> frames;
  final int holdFrames;

  int currentFrame = 0;
  int framesSinceLast = 0;

  final int startLineIdx;
  final int lineCount;
  final int startGlobalCharIndex;

  // Snapshotted styling
  final String align;
  final double fontSize;
  final double lineSpacing;
  final double tracking;
  final Color fgColor;
  final Color? bgColor;
  final String? flashStyle;

  _ActiveSprite({
    required this.path,
    required this.frames,
    required this.holdFrames,
    required this.startLineIdx,
    required this.lineCount,
    required this.startGlobalCharIndex,
    required this.align,
    required this.fontSize,
    required this.lineSpacing,
    required this.tracking,
    required this.fgColor,
    this.bgColor,
    this.flashStyle,
  });
}

/// A terminal BAR animation evaluated from explicit terminal-frame age.
///
/// [startFrame] is the first visible terminal frame after the BAR tag commits.
/// At that frame the bar is empty, exactly as the legacy counter was at
/// elapsed == 0. Later frames derive progress from frame distance rather than
/// mutating an elapsed counter. Terminal time already freezes while desktop
/// presentations own the scene, so this preserves the existing suspension
/// behavior without giving BAR a second clock.
class BarState {
  final int frames;
  final int startFrame;
  final int width;

  BarState({
    required this.frames,
    required this.startFrame,
    required this.width,
  });

  int elapsedAt(int terminalFrame) {
    final int elapsed = terminalFrame - startFrame;
    if (elapsed <= 0) return 0;
    final int stop = math.max(frames, 1);
    return elapsed >= stop ? stop : elapsed;
  }

  double progressAt(int terminalFrame) {
    final int denominator = frames > 0 ? frames : 1;
    return elapsedAt(terminalFrame) / denominator;
  }

  bool completesAt(int terminalFrame) => elapsedAt(terminalFrame) >= frames;
}

class BarInfo {
  final int index;
  final String fill;
  final String empty;
  final BarState state;

  BarInfo({
    required this.index,
    required this.fill,
    required this.empty,
    required this.state,
  });
}

class CharData {
  final String char;
  final Color fgColor;
  final Color? bgColor;
  final String? flashStyle;
  final BarInfo? barInfo;
  final int spatialIndex;
  final double fontSize;
  final String? regionId;

  CharData({
    required this.char,
    required this.fgColor,
    this.bgColor,
    this.flashStyle,
    this.barInfo,
    required this.spatialIndex,
    required this.fontSize,
    this.regionId,
  });

  CharData copyWith({
    String? char,
    Color? fgColor,
    Color? bgColor,
    String? flashStyle,
    BarInfo? barInfo,
    int? spatialIndex,
    double? fontSize,
    String? regionId,
    bool clearBg = false,
  }) {
    return CharData(
      char: char ?? this.char,
      fgColor: fgColor ?? this.fgColor,
      bgColor: clearBg ? null : (bgColor ?? this.bgColor),
      flashStyle: flashStyle ?? this.flashStyle,
      barInfo: barInfo ?? this.barInfo,
      spatialIndex: spatialIndex ?? this.spatialIndex,
      fontSize: fontSize ?? this.fontSize,
      regionId: regionId ?? this.regionId,
    );
  }
}

class LineData {
  final List<CharData> chars;
  final String align;
  final double spacing;
  final double width; // Passed directly from the engine to prevent rendering divergence

  /// Non-null when this line IS an [IMG] band: the painter draws the
  /// stamped tiles instead of chars (which will be empty). Alignment and
  /// width behave exactly like a text line, so [ALIGN:CENTER] centers the
  /// band for free.
  final ImgBandData? imgBand;

  LineData({
    required this.chars,
    required this.align,
    required this.spacing,
    required this.width,
    this.imgBand,
  });
}
