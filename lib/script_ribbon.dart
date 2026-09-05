// ./lib/script_ribbon.dart

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'diag.dart';
import 'script_nodes.dart';
import 'ui_theme.dart';

/// Dumps the block list to r3nder_trace.log after every simulation.
///
/// Here because colour tuning cannot fix a typing problem, and from the
/// outside the two look identical: a ribbon whose blocks all carry the
/// same type paints one colour no matter what the palette says. This
/// prints what the strip is actually being told to draw.
const bool kProfileRibbon = true;

// =====================================================================
// WHY THIS EXISTS
//
// The scrubber tells you where you are. It does not tell you what the
// piece is made of. A 4 minute script is a single undifferentiated line,
// and the fact that one DOSSIER eats a third of the runtime while eleven
// text blocks share the rest is invisible until you sit and watch it.
//
// This is a second lane under the scrubber: one block per node, width
// proportional to the frames that node actually consumes. It answers
// "how is this blocked out" at a glance, and it scrubs.
//
// PROPORTIONAL, NOT UNIFORM. Equal-width blocks would show node ORDER,
// which the script view already shows, in a form that reads top to
// bottom instead of left to right. Frame-proportional blocks show
// PACING, which nothing else in the app shows at all. That is the entire
// reason to build it, so the widths have to be honest.
//
// WHICH MEANS ZERO-FRAME NODES GET NO BLOCK. [COLOR:RED], [SPEED:5],
// [ALIGN:LEFT] and their kin consume no frames. Giving them a minimum
// width so they are clickable would make every other block slightly
// wrong, and a time axis is the wrong place for things that take no
// time. They leave no gap, because they occupy no time to leave a gap
// in.
// =====================================================================

/// One node's run on the time axis.
///
/// [endFrame] is exclusive, so `endFrame - startFrame` is the duration and
/// consecutive blocks share a boundary rather than overlapping by one.
class RibbonBlock {
  /// Position of the node in the document, NOT its ScriptNode.id.
  ///
  /// Ids come from a global counter that never resets, so parsing the same
  /// text twice yields two disjoint sets of them: the ribbon's parse and
  /// the node panel's parse can never agree on an id. Document index is the
  /// address both sides compute the same way, because both walk the same
  /// text in the same order.
  ///
  /// Deliberately not used INSIDE the node panel, where ids remain correct:
  /// an index shifts when a node is inserted or deleted, which would break
  /// the controller keys and the pin. Index is a cross-parse address only.
  final int nodeIndex;

  final String type;
  final int startFrame;
  final int endFrame;

  const RibbonBlock({
    required this.nodeIndex,
    required this.type,
    required this.startFrame,
    required this.endFrame,
  });

  int get frames => endFrame - startFrame;
}

/// Broad families, used for colour. Four bands rather than one hue per tag,
/// because at three pixels wide a thirty-colour palette is noise: you would
/// be able to see that the blocks differ without being able to tell how.
enum _Band { text, hold, pause, window, media }

/// Lane height. Skinny by intent: the strip orients you, it is not a place
/// you edit, and every pixel here comes out of the viewer above it.
final double _kLaneH = sc(7);
final double _kLaneGap = sc(3);

/// Invisible padding above and below the lanes, so the strip is comfortable
/// to grab without being thick to look at. Skinny is a visual choice; a
/// 17 pixel drag target would just be a bad one.
final double _kHitPad = sc(6);

_Band _bandFor(String type) {
  switch (type) {
    case 'TEXT':
    case 'RAW':
    case 'REDACT':
    case 'BAR':
      return _Band.text;

    // Separate bands, though both are holds. A WIPE is an event, a moment
    // where something happens; a PAUSE is the script deliberately doing
    // nothing. Scanning a ribbon for dead air is a real authoring task and
    // it wants those two told apart.
    case 'PAUSE':
      return _Band.pause;

    case 'WIPE':
      return _Band.hold;

    case 'GALLERY':
    case 'VIDEO':
    case 'APP':
    case 'BROWSER':
    case 'CARD':
    case 'DOSSIER':
    case 'TIMELINE':
    case 'STRUCT':
      return _Band.window;

    case 'IMG':
    case 'PHOTO':
    case 'SVG':
    case 'SVGFLASH':
    case 'SPRITE':
      return _Band.media;

    default:
      return _Band.text;
  }
}

/// Lifts a band colour to its selected state, preserving hue.
///
/// Scales the channels proportionally so the brightest one reaches
/// [_kSelectedPeak], rather than lerping toward white. Lerping desaturates:
/// [R3Theme.deadAir] at 45% white lands on a grey-pink that is neither
/// clearly red nor clearly distinct from a selected text block. Scaling
/// keeps the ratios exactly, so a selected PAUSE is the same red, louder.
///
/// The same gesture on every band, so nothing's selected form can collide
/// with another band's resting form.
Color _brighten(Color c) {
  final int argb = c.toARGB32();
  final int a = (argb >> 24) & 0xFF;
  final int r = (argb >> 16) & 0xFF;
  final int g = (argb >> 8) & 0xFF;
  final int b = argb & 0xFF;

  final int peak = math.max(r, math.max(g, b));
  // Black has no hue to preserve, and anything already bright is left
  // alone rather than dimmed by a naive scale.
  if (peak == 0 || peak >= _kSelectedPeak) return c;

  final double k = _kSelectedPeak / peak;
  int up(int v) => (v * k).round().clamp(0, 255);
  return Color.fromARGB(a, up(r), up(g), up(b));
}

/// Brightest channel a selected block reaches. Short of 255 so a selected
/// block still reads as a colour rather than as a blown-out highlight.
const int _kSelectedPeak = 205;

/// Brightest channel the text band rests at.
///
/// Deliberately the quietest band except the seam, and that is the whole
/// point of the number. Typed text and progress bars are the SUBSTANCE of
/// a script: on a normal document they are most of the strip. Painting the
/// majority band at full phosphor made the ribbon read as a green bar with
/// occasional flecks, which is the same failure as painting everything
/// grey, just louder.
///
/// Events should stand out against text, not the other way round, so text
/// sits low and every other band is brighter than it.
const int _kTextPeak = 100;

/// Pulls a colour down to [peak] on its brightest channel, hue intact.
///
/// The mirror of [_brighten], and scaling rather than an alpha for the
/// same reason: an alpha-based dim would leave the block translucent, so
/// [_brighten] would then lift a translucent colour and the text band
/// would be the one band whose selected state was see-through.
Color _dim(Color c, int peak) {
  final int argb = c.toARGB32();
  final int a = (argb >> 24) & 0xFF;
  final int r = (argb >> 16) & 0xFF;
  final int g = (argb >> 8) & 0xFF;
  final int b = argb & 0xFF;

  final int high = math.max(r, math.max(g, b));
  if (high == 0 || high <= peak) return c;

  final double k = peak / high;
  int down(int v) => (v * k).round().clamp(0, 255);
  return Color.fromARGB(a, down(r), down(g), down(b));
}

/// Band identity. See the SCRIPT RIBBON PALETTE note in ui_theme.dart for
/// why these are hues rather than brightnesses, and why only one of them
/// follows the phosphor.
Color _colorFor(_Band band, R3Theme theme) {
  switch (band) {
    case _Band.text:
      // Typed characters are the phosphor, so this is the one band that
      // moves with it. Held well down: see _kTextPeak. This is the
      // background substance of a script, not an event in it.
      return _dim(theme.accent, _kTextPeak);
    case _Band.hold:
      return R3Theme.ribbonSeam;
    case _Band.pause:
      return R3Theme.deadAir;
    case _Band.window:
      return R3Theme.ribbonWindow;
    case _Band.media:
      return R3Theme.ribbonMedia;
  }
}

/// Turns the engine's frame-to-line map into blocks on a time axis.
///
/// [rawLineAtFrame] comes out of the simulation: entry i is the document
/// line the engine was reading on frame i. [nodes] must already have their
/// spans stamped by `assignNodeLineSpans`.
///
/// One pass over frames, coalescing runs. Runs rather than per-node lookup
/// because a node holding for 300 frames is 300 identical answers, and
/// because coalescing is what makes a node whose lines the engine revisits
/// come out as separate blocks rather than one wrong long one.
List<RibbonBlock> buildRibbonBlocks(
  List<ScriptNode> nodes,
  List<int> rawLineAtFrame, {
  int endHoldStartFrame = -1,
}) {
  if (nodes.isEmpty || rawLineAtFrame.isEmpty) return const [];

  // Stop where the script does. During the end hold the engine returns from
  // its tick before touching the read head, so every hold frame reports the
  // last line of the script. Walking those would hand the entire tail to
  // whichever node happened to be last, and with a long audio bed that tail
  // can be minutes. The tail is engine-owned time and belongs to no node, so
  // it is simply not walked; the audio lane is what explains it.
  final int limit = (endHoldStartFrame >= 0 &&
          endHoldStartFrame < rawLineAtFrame.length)
      ? endHoldStartFrame
      : rawLineAtFrame.length;
  if (limit <= 0) return const [];

  // Line to node index. Built once so the frame walk is an array read
  // rather than a scan of the node list per frame.
  int maxLine = 0;
  for (final n in nodes) {
    if (n.endLine > maxLine) maxLine = n.endLine;
  }
  //
  // SPACERS ARE SKIPPED, and this is the whole correctness of the strip.
  //
  // Nodes tile the document with no gaps, so the newline after `[APP:...]`
  // is itself a node: a whitespace-only SPACER sharing that same line. The
  // spacer is written second, so a plain last-wins assignment handed the
  // line to it and every tag on the strip was reported as whitespace. A
  // real script measured 610 of 742 frames as SPACER: the entire APP hold,
  // both pauses, and the IMG, all attributed to a newline. SPACER falls to
  // the default band, so the ribbon painted one colour no matter what the
  // palette said, and it looked exactly like a colour bug.
  //
  // A spacer is whitespace. It can never consume a frame, so it can never
  // legitimately own one. Skipping it leaves last-wins to settle the only
  // other case that matters, a zero-frame control tag sharing a line with
  // the text after it (`[SPEED:3]` above a typed paragraph), where the
  // later node is the one actually spending the time.
  final List<int> nodeAtLine = List<int>.filled(maxLine + 1, -1);
  for (int i = 0; i < nodes.length; i++) {
    final ScriptNode n = nodes[i];
    if (n.startLine < 0) continue;
    if (n.type == kSpacer) continue;
    for (int l = n.startLine; l <= n.endLine && l <= maxLine; l++) {
      nodeAtLine[l] = i;
    }
  }

  final List<RibbonBlock> out = [];
  int runNode = -2;
  int runStart = 0;

  void closeRun(int endFrame) {
    if (runNode < 0 || endFrame <= runStart) return;
    final ScriptNode n = nodes[runNode];
    out.add(RibbonBlock(
      nodeIndex: runNode,
      type: n.type,
      startFrame: runStart,
      endFrame: endFrame,
    ));
  }

  for (int f = 0; f < limit; f++) {
    final int line = rawLineAtFrame[f];
    final int idx =
        (line >= 0 && line <= maxLine) ? nodeAtLine[line] : -1;

    // SceneEngine can spend real frames finishing a presentation after its
    // terminal read head has already left the authored line. Those frames are
    // not dead air: they are the outgoing event's close/handoff animation.
    // Keeping the current run open across an unmapped interval makes the
    // ribbon describe visible runtime instead of cutting a black hole between
    // two authored events. Leading unmapped time stays unowned because there
    // is no previous event to inherit it. The end hold is excluded above.
    if (idx < 0) continue;

    if (idx != runNode) {
      closeRun(f);
      runNode = idx;
      runStart = f;
    }
  }
  closeRun(limit);

  if (kProfileRibbon) {
    final Map<String, int> byType = {};
    for (final b in out) {
      byType[b.type] = (byType[b.type] ?? 0) + b.frames;
    }
    diag('ribbon', '${out.length} blocks over $limit frames; '
        'frames by type: $byType');
    for (final b in out) {
      diag('ribbon',
          '  ${b.type.padRight(10)} ${b.startFrame}..${b.endFrame} '
          '(${b.frames}f) node ${b.nodeIndex}');
    }
    // The node list itself, so a block typed TEXT can be traced back to
    // whether the node was mistyped or the line map pointed at the wrong
    // node.
    for (int i = 0; i < nodes.length; i++) {
      diag('ribbon',
          '  node $i ${nodes[i].type.padRight(10)} '
          'lines ${nodes[i].startLine}..${nodes[i].endLine}');
    }
  }

  return out;
}

// ---------------------------------------------------------------------
// Widget
// ---------------------------------------------------------------------

/// Proportional block strip with a playhead. Drag to seek, double-tap a
/// block to open it.
class ScriptRibbon extends StatelessWidget {
  final List<RibbonBlock> blocks;
  final int currentFrame;
  final int totalFrames;
  final R3Theme theme;

  /// Node currently open in the properties panel, drawn in accent, by
  /// document index. Null until something has been opened.
  final int? selectedNodeIndex;

  /// Seek. Fires continuously during a drag.
  final ValueChanged<int> onSeek;

  /// Double-tap on a block, carrying its document index. Null disables the
  /// gesture entirely rather than swallowing taps that do nothing.
  final ValueChanged<int>? onOpenNode;

  /// Length of the audio bed in frames, or 0 when none is attached. In the
  /// editor the bed sits at frame 0, because the preroll wipe is never
  /// previewed here, so the audio lane spans [0, bedFrames).
  final int bedFrames;

  /// Length of the music bed in frames, or 0 when none is attached.
  ///
  /// Drawn as its own lane, and read differently from the bed's. An overhang
  /// on the voice lane is dead air you still owe choreography for, because
  /// the end hold stretched to cover it. An overhang on the music lane is
  /// frames the bake will cut, because nothing stretched for a score. Same
  /// picture, opposite meanings, which is why the lane is clamped at the
  /// piece's end and the surplus is drawn as a trim marker rather than as
  /// more lane.
  final int musicFrames;

  /// Whether the music track repeats to fill the picture.
  ///
  /// Changes what the lane MEANS, so it has to reach the painter. A
  /// non-looping score short of the picture leaves real silence at the end,
  /// and the lane stopping early is that silence. A looping one plays
  /// throughout, so the lane runs the full width and the repeats are marked
  /// instead. Same two numbers, two different readings.
  final bool musicLoops;

  /// Greys out and stops accepting gestures while the sim is rebuilding,
  /// because the blocks on screen describe a document that no longer
  /// exists and seeking into them would land somewhere arbitrary.
  final bool simulating;

  const ScriptRibbon({
    super.key,
    required this.blocks,
    required this.currentFrame,
    required this.totalFrames,
    required this.theme,
    required this.onSeek,
    this.bedFrames = 0,
    this.musicFrames = 0,
    this.musicLoops = false,
    this.selectedNodeIndex,
    this.onOpenNode,
    this.simulating = false,
  });

  int _frameAt(double dx, double width) {
    if (width <= 0 || totalFrames <= 0) return 0;
    final double t = (dx / width).clamp(0.0, 1.0);
    return (t * totalFrames).round().clamp(0, totalFrames);
  }

  RibbonBlock? _blockAt(double dx, double width) {
    final int f = _frameAt(dx, width);
    for (final b in blocks) {
      if (f >= b.startFrame && f < b.endFrame) return b;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // Up to three lanes, deliberately thin. This is an orientation strip,
    // not an NLE: chunky tracks would claim vertical space the viewer and
    // script need, to say something a few pixels already say.
    //
    // Music gets its own lane rather than sharing the audio one. Two beds
    // stacked in one row would read as a single longer track, and the whole
    // reason to look here is which of them runs past the picture.
    final int audioLanes =
        (bedFrames > 0 ? 1 : 0) + (musicFrames > 0 ? 1 : 0);
    final double h = _kLaneH * (1 + audioLanes) + _kLaneGap * audioLanes;

    return LayoutBuilder(
      builder: (context, constraints) {
        final double w = constraints.maxWidth;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,

          // Tap and drag both seek. A double-tap therefore also seeks on
          // its first tap, which is intended: you double-click a block to
          // work on it, and landing on it is part of that. Suppressing it
          // would mean holding every single tap for the double-tap timeout
          // and making the whole strip feel late.
          onTapDown: simulating
              ? null
              : (d) => onSeek(_frameAt(d.localPosition.dx, w)),
          onHorizontalDragUpdate: simulating
              ? null
              : (d) => onSeek(_frameAt(d.localPosition.dx, w)),
          onDoubleTapDown: (simulating || onOpenNode == null)
              ? null
              : (d) {
                  final RibbonBlock? b = _blockAt(d.localPosition.dx, w);
                  if (b != null) onOpenNode!(b.nodeIndex);
                },
          // Present so the double-tap recognizer stays in the arena;
          // onDoubleTapDown carries the position and this carries nothing.
          onDoubleTap: (simulating || onOpenNode == null) ? null : () {},

          child: SizedBox(
            height: h + _kHitPad * 2,
            width: w,
            child: Center(
              child: SizedBox(
                height: h,
                width: w,
                child: CustomPaint(
                  painter: _RibbonPainter(
                    blocks: blocks,
                    currentFrame: currentFrame,
                    totalFrames: totalFrames,
                    theme: theme,
                    selectedNodeIndex: selectedNodeIndex,
                    bedFrames: bedFrames,
                    musicFrames: musicFrames,
                    musicLoops: musicLoops,
                    dimmed: simulating,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RibbonPainter extends CustomPainter {
  final List<RibbonBlock> blocks;
  final int currentFrame;
  final int totalFrames;
  final R3Theme theme;
  final int? selectedNodeIndex;
  final int bedFrames;
  final int musicFrames;
  final bool musicLoops;
  final bool dimmed;

  _RibbonPainter({
    required this.blocks,
    required this.currentFrame,
    required this.totalFrames,
    required this.theme,
    required this.selectedNodeIndex,
    required this.bedFrames,
    required this.musicFrames,
    required this.musicLoops,
    required this.dimmed,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = R3Theme.bg);

    if (size.width <= 0) return;

    final bool hasBed = bedFrames > 0;
    final bool hasMusic = musicFrames > 0;

    // Lane origins, computed once. Music sits under the bed when both are
    // present and takes the bed's row when it is alone, so a score-only
    // workspace gets a two-lane strip rather than a gap where a voiceover
    // would have been.
    final double bedY = _kLaneH + _kLaneGap;
    final double musicY = hasBed ? bedY + _kLaneH + _kLaneGap : bedY;

    // NOT YET SIMULATED. The strip is rendered from the editor's first
    // frame now, so it has to have something to say before there is any
    // timing to show. Empty lane guides say "this is a container that is
    // about to fill" rather than leaving a dark gap that reads as a bug.
    //
    // Both counts are widget properties, known at construction, so the lane
    // COUNT is right immediately: the strip never changes height on the
    // way from empty to full.
    if (totalFrames <= 0) {
      final Paint guide = Paint()..color = R3Theme.hairline;
      canvas.drawRect(Rect.fromLTWH(0, 0, size.width, _kLaneH), guide);
      if (hasBed) {
        canvas.drawRect(
            Rect.fromLTWH(0, bedY, size.width, _kLaneH), guide);
      }
      if (hasMusic) {
        canvas.drawRect(
            Rect.fromLTWH(0, musicY, size.width, _kLaneH), guide);
      }
      return;
    }

    // ONE SHARED AXIS. totalFrames already covers the bed, because the
    // engine stretches its end hold to reach it, so the two lanes are
    // measured against the same width and the audio visibly running past
    // the last block IS the overhang. Scaling the lanes independently
    // would destroy the only thing worth reading here.
    final double perFrame = size.width / totalFrames;

    // --- Script lane -------------------------------------------------
    for (final b in blocks) {
      final double x = b.startFrame * perFrame;
      final double w = b.frames * perFrame;

      // Sub-pixel blocks still paint, at a hairline, rather than vanishing.
      // These are real frames, unlike the zero-frame nodes that are
      // correctly absent, and a gap here would read as missing time.
      final double drawW = w < 1.0 ? 1.0 : w;

      final bool isSelected =
          selectedNodeIndex != null && b.nodeIndex == selectedNodeIndex;

      // SELECTION BRIGHTENS, IT DOES NOT REPLACE.
      //
      // This used to paint every selected block in the phosphor accent,
      // which meant selecting a PAUSE turned it green and it stopped being
      // dead air on screen. The band colour is the block's identity: what
      // KIND of thing it is. Selection is a transient state on top of that
      // identity, so it has to be expressed as a change in intensity
      // rather than as a change in hue, or the two carry the same channel
      // and the louder one wins.
      //
      // Lerping toward the band's own light end keeps a selected pause
      // unmistakably red, a selected window unmistakably phosphor, and the
      // selection unmistakable in both.
      final Color band = _colorFor(_bandFor(b.type), theme);
      final Color base = isSelected ? _brighten(band) : band;

      canvas.drawRect(
        Rect.fromLTWH(x, 0, drawW, _kLaneH),
        Paint()..color = dimmed ? base.withValues(alpha: 0.35) : base,
      );

      // Separator on the right edge, skipped when the block is too narrow
      // to have an interior left over.
      if (drawW > 2.0) {
        canvas.drawRect(
          Rect.fromLTWH(x + drawW - 1, 0, 1, _kLaneH),
          Paint()..color = R3Theme.bg.withValues(alpha: dimmed ? 0.2 : 0.6),
        );
      }
    }

    // --- Audio lanes -------------------------------------------------
    if (hasBed) {
      final double bw = (bedFrames * perFrame).clamp(1.0, size.width);
      canvas.drawRect(
        Rect.fromLTWH(0, bedY, bw, _kLaneH),
        Paint()
          ..color = dimmed
              ? R3Theme.okGreen.withValues(alpha: 0.25)
              : R3Theme.okGreen.withValues(alpha: 0.65),
      );
    }

    // MUSIC IS CLAMPED, THE BED IS NOT, AND THAT ASYMMETRY IS THE POINT.
    //
    // The bed lane is allowed to run to the full width because it cannot
    // exceed it: the engine already stretched its end hold to cover a long
    // voiceover, so totalFrames includes it and the lane ending exactly at
    // the right edge IS the dead-air reading.
    //
    // Nothing stretches for music. A score longer than the piece is cut by
    // the bake, so drawing it past the last block would show frames that
    // will not exist in the file. The lane therefore stops at picture end
    // and the surplus is reported instead: a hatch of ticks over the final
    // stretch, saying "this continues and is discarded" rather than adding
    // width that would lie about the length.
    if (hasMusic) {
      // A LOOP FILLS THE WIDTH. Without one, the lane ends where the track
      // ends and the gap after it is real silence you can see. With one, the
      // score plays under every frame, so the lane runs the full width and
      // the repeat boundaries are marked instead. Same two numbers, two
      // different readings.
      final int visible = musicLoops
          ? totalFrames
          : (musicFrames < totalFrames ? musicFrames : totalFrames);
      final double mw = (visible * perFrame).clamp(1.0, size.width);
      canvas.drawRect(
        Rect.fromLTWH(0, musicY, mw, _kLaneH),
        Paint()
          ..color = dimmed
              ? R3Theme.textDim.withValues(alpha: 0.25)
              : R3Theme.textDim.withValues(alpha: 0.70),
      );

      if (musicLoops && musicFrames > 0) {
        // One hairline per repeat, so the lane says how many times the track
        // comes round rather than just that it continues. Skipped entirely
        // when the marks would be closer together than they are wide: a
        // sting looping two hundred times is a solid block either way, and
        // drawing it as one is honest where drawing two hundred lines is
        // just noise.
        final double period = musicFrames * perFrame;
        if (period >= sc(6)) {
          final Paint edge = Paint()
            ..color = R3Theme.bg.withValues(alpha: dimmed ? 0.3 : 0.75);
          for (double x = period; x < mw; x += period) {
            canvas.drawRect(Rect.fromLTWH(x, musicY, 1, _kLaneH), edge);
          }
        }
      }

      // Surplus is only surplus when the track is longer than the piece. A
      // loop has no tail to discard: it is cut mid-repeat by the same trim,
      // which is the point of looping rather than a loss worth flagging.
      if (!musicLoops && musicFrames > totalFrames) {
        // Ticks over the tail the export discards. Drawn inside the lane's
        // own width, because the thing being reported is that there is no
        // more width to have.
        final double trimW =
            ((musicFrames - totalFrames) * perFrame).clamp(0.0, size.width);
        final double startX = (size.width - trimW).clamp(0.0, size.width);
        final Paint tick = Paint()
          ..color = dimmed
              ? R3Theme.warn.withValues(alpha: 0.25)
              : R3Theme.warn.withValues(alpha: 0.75);
        for (double x = startX; x < size.width; x += sc(4)) {
          canvas.drawRect(Rect.fromLTWH(x, musicY, 1, _kLaneH), tick);
        }
      }
    }

    // --- Playhead ----------------------------------------------------
    // Full height across both lanes and drawn last, so it is never buried
    // and so the two lanes read as one timeline rather than two charts.
    final double px = (currentFrame * perFrame).clamp(0.0, size.width - 1);
    canvas.drawRect(
      Rect.fromLTWH(px, 0, sc(1.5), size.height),
      Paint()..color = dimmed ? R3Theme.textDim : R3Theme.textBright,
    );
  }

  @override
  bool shouldRepaint(_RibbonPainter old) =>
      old.currentFrame != currentFrame ||
      old.totalFrames != totalFrames ||
      old.selectedNodeIndex != selectedNodeIndex ||
      old.bedFrames != bedFrames ||
      old.musicFrames != musicFrames ||
      old.musicLoops != musicLoops ||
      old.dimmed != dimmed ||
      !identical(old.blocks, blocks);
}
