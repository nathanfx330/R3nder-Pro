// ./lib/edit_cue.dart
//
// Clip-local presentation triggers for structural EDIT time.
//
// A CUE is deliberately smaller than a presentation. It owns only the source
// frame at which an already-authored presentation event begins. The contained
// presentation owns its own deterministic lifetime and appearance. Keeping the
// trigger in source coordinates makes it follow the clip's content through
// moves, trims, slips, and exact rational speed changes without introducing a
// second project clock.
//
// V1 accepts CARD only. The parser is intentionally separate from the
// structural CST: CUE is content inside a CLIP body, not another track/layer
// owner. ScriptCstDocument continues to own the CLIP span byte-for-byte while
// this file gives the inner source just enough meaning for deterministic
// structural presentation.

import 'card_presentation.dart';
import 'edit_model.dart';
import 'parser.dart' show tagRegex;
import 'presentation_requests.dart';

class EditCueFormatException implements Exception {
  final String message;
  final int offset;

  const EditCueFormatException(this.message, this.offset);

  @override
  String toString() => 'EditCueFormatException at $offset: $message';
}

/// One CARD presentation triggered from a source-relative frame in a CLIP.
class EditCardCue {
  const EditCardCue({
    required this.sourceFrame,
    required this.card,
    required this.startOffset,
    required this.endOffset,
    required this.rawSource,
  });

  /// Authored source frame, in the same coordinate space as CLIP `in`.
  final int sourceFrame;

  /// The existing canonical CARD request. Defaults and body cleanup therefore
  /// come from the same parser used by TEXT rather than being copied here.
  final CardRequest card;

  /// Absolute source span of the complete `[CUE]...[/CUE]` block.
  final int startOffset;
  final int endOffset;

  /// Complete authored CUE source, preserved exactly.
  final String rawSource;
}

/// One CARD cue that is actually visible at a specific structural frame.
///
/// The trigger belongs to the source-relative CLIP body, but after it fires the
/// CARD presentation is evaluated from structural time and is allowed to
/// continue across a later cut. The containing EDIT/PANE, not the anchor CLIP,
/// clips its lifetime. This keeps the trigger attached to content without
/// making the owning clip a second presentation-duration authority.
class ActiveEditCardCue {
  const ActiveEditCardCue({
    required this.clip,
    required this.cue,
    required this.triggerProjectFrame,
    required this.localFrame,
    required this.presentationFrame,
  });

  final EditClip clip;
  final EditCardCue cue;
  final int triggerProjectFrame;

  /// Frame age inside the CARD presentation, zero on the trigger frame.
  final int localFrame;

  /// Pure CARD visual state for [localFrame].
  final CardPresentationFrame presentationFrame;
}

final RegExp _cueOpening = RegExp(r'\[CUE:(\d+)\]');
final RegExp _comment = RegExp(r'\[#.*?\]\n?', dotAll: true);
const String _cueClosing = '[/CUE]';

/// Parses every CARD cue owned by [clip].
///
/// Other CLIP body source is left uninterpreted. In particular, transition
/// directives and future body constructs remain somebody else's grammar. The
/// scan skips complete terminal tags before looking inside them, so text such
/// as `[CUE:900]` appearing inside an ordinary CARD body cannot accidentally
/// become structural timing.
List<EditCardCue> parseClipCardCues(EditClip clip) {
  final String source = clip.block.innerSource;
  final int absoluteBase = clip.block.openEndOffset;
  final List<EditCardCue> cues = <EditCardCue>[];

  int cursor = 0;
  while (cursor < source.length) {
    if (source.startsWith('[CUE:', cursor)) {
      final RegExpMatch? opening =
          _cueOpening.matchAsPrefix(source, cursor) as RegExpMatch?;
      if (opening == null) {
        throw EditCueFormatException(
          'CUE requires one non-negative integer source frame.',
          absoluteBase + cursor,
        );
      }

      final int sourceFrame = int.parse(opening.group(1)!);
      final int contentAt = _skipWhitespace(source, opening.end);

      final RegExpMatch? presentation =
          tagRegex.matchAsPrefix(source, contentAt) as RegExpMatch?;
      if (presentation == null) {
        throw EditCueFormatException(
          'CUE must contain exactly one CARD presentation.',
          absoluteBase + contentAt,
        );
      }

      final PresentationRequest? request =
          presentationRequestFromMatch(presentation);
      if (request is! CardRequest) {
        throw EditCueFormatException(
          'CUE v1 supports CARD only.',
          absoluteBase + contentAt,
        );
      }

      final int closeAt = _skipWhitespace(source, presentation.end);
      if (!source.startsWith(_cueClosing, closeAt)) {
        throw EditCueFormatException(
          'CUE must close immediately after its CARD, apart from whitespace.',
          absoluteBase + closeAt,
        );
      }

      final int end = closeAt + _cueClosing.length;
      cues.add(
        EditCardCue(
          sourceFrame: sourceFrame,
          card: request,
          startOffset: absoluteBase + cursor,
          endOffset: absoluteBase + end,
          rawSource: source.substring(cursor, end),
        ),
      );
      cursor = end;
      continue;
    }

    // CARD/DOSSIER/TIMELINE are complete matches in tagRegex. Skip the whole
    // match so bracket-shaped prose inside their opaque bodies is never
    // mistaken for a CUE owned by this CLIP.
    if (source.codeUnitAt(cursor) == 0x5B) {
      final RegExpMatch? terminalTag =
          tagRegex.matchAsPrefix(source, cursor) as RegExpMatch?;
      if (terminalTag != null) {
        cursor = terminalTag.end;
        continue;
      }

      final RegExpMatch? comment =
          _comment.matchAsPrefix(source, cursor) as RegExpMatch?;
      if (comment != null) {
        cursor = comment.end;
        continue;
      }
    }

    cursor++;
  }

  return List<EditCardCue>.unmodifiable(cues);
}

/// Returns every CARD cue visible in [edit] at [projectFrame].
///
/// Authored order is the deterministic stacking rule for v1: tracks are
/// visited in source order, clips in source order, cues in body order. A later
/// active cue therefore follows an earlier one in the returned list and may be
/// painted on top without inventing a z-order language.
List<ActiveEditCardCue> activeCardCuesForEdit(
  EditSequence edit,
  int projectFrame,
) {
  if (projectFrame < 0 || projectFrame >= edit.projectFrameCount) {
    return const <ActiveEditCardCue>[];
  }

  return _activeCardCues(
    edit.tracks.expand((EditTrack track) => track.clips),
    projectFrame,
  );
}

/// Returns every CARD cue visible in one MOSAIC pane at [projectFrame].
///
/// The pane is the presentation lifetime boundary. A cue may survive the cut
/// from its anchor clip into the next clip in the same pane, but it cannot leak
/// beyond the pane's authored frame count or into another pane.
List<ActiveEditCardCue> activeCardCuesForPane(
  MosaicPane pane,
  int projectFrame,
) {
  if (projectFrame < 0 || projectFrame >= pane.projectFrameCount) {
    return const <ActiveEditCardCue>[];
  }

  return _activeCardCues(pane.clips, projectFrame);
}

List<ActiveEditCardCue> _activeCardCues(
  Iterable<EditClip> clips,
  int projectFrame,
) {
  final List<ActiveEditCardCue> active = <ActiveEditCardCue>[];

  for (final EditClip clip in clips) {
    for (final EditCardCue cue in parseClipCardCues(clip)) {
      final int? trigger = cueProjectFrame(clip, cue.sourceFrame);
      if (trigger == null || projectFrame < trigger) continue;

      final int localFrame = projectFrame - trigger;
      final CardPresentationFrame? presentationFrame = CardPresentationTiming(
        holdFrames: cue.card.holdFrames,
      ).frameAt(localFrame);
      if (presentationFrame == null) continue;

      active.add(
        ActiveEditCardCue(
          clip: clip,
          cue: cue,
          triggerProjectFrame: trigger,
          localFrame: localFrame,
          presentationFrame: presentationFrame,
        ),
      );
    }
  }

  return List<ActiveEditCardCue>.unmodifiable(active);
}

/// Returns the project-frame offset inside [clip] where [cueSourceFrame]
/// becomes active, or null when that source point is outside the clip's
/// current visible source window.
///
/// This is the exact inverse of the CLIP's rational source walk in the sense
/// a trigger needs: the earliest project frame whose continuous source
/// position has reached or passed the authored source frame. Integer ceil is
/// used directly; no double enters the mapping.
///
/// At speeds above 1 some integer source frames are skipped by sampling. A cue
/// on one of those frames fires on the first project frame after the crossing,
/// rather than disappearing merely because no decoded frame has that exact
/// integer index.
int? cueProjectOffset(EditClip clip, int cueSourceFrame) {
  final int sourceDelta = cueSourceFrame - clip.inFrame;
  if (sourceDelta < 0) return null;

  final int numerator = clip.speed.numerator;
  final int denominator = clip.speed.denominator;
  final int projectOffset =
      (sourceDelta * denominator + numerator - 1) ~/ numerator;

  if (projectOffset < 0 || projectOffset >= clip.durationFrames) return null;
  return projectOffset;
}

/// Absolute EDIT/MOSAIC-local project frame for a source-relative cue.
int? cueProjectFrame(EditClip clip, int cueSourceFrame) {
  final int? offset = cueProjectOffset(clip, cueSourceFrame);
  return offset == null ? null : clip.atFrame + offset;
}

int _skipWhitespace(String source, int from) {
  int i = from;
  while (i < source.length) {
    final int c = source.codeUnitAt(i);
    if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) {
      i++;
      continue;
    }
    break;
  }
  return i;
}
