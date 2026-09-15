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
// Structural CUEs currently accept CARD and SIDECARD. CARD is the fullscreen
// overlay discovered while building the first CUE path. SIDECARD is the
// original side-by-side idea: the same structural video keeps advancing while
// it moves into a desktop-style video window and the card sits beside it.
// Neither form is part of the structural CST. ScriptCstDocument continues to
// own the CLIP span byte-for-byte while this file gives the inner source just
// enough meaning for deterministic presentation.

import 'package:flutter/material.dart';

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

/// CUE-local request for the side-by-side desktop composition.
///
/// It subclasses [CardRequest] on purpose. The inspector, history path, image
/// cache, and CARD content contract can stay shared while runtime type carries
/// the one extra authored fact: this card lives beside a continuously-playing
/// windowed structural source rather than over fullscreen source pixels.
///
/// SIDECARD is deliberately CUE-local. It is not added to the terminal tag
/// grammar and therefore cannot accidentally become another suspending TEXT
/// presentation.
class SideCardRequest extends CardRequest {
  SideCardRequest({
    required super.image,
    required super.holdFrames,
    required super.panelColor,
    required super.heading,
    required super.body,
  });
}

/// One CARD-family presentation triggered from a source-relative frame in a
/// CLIP. [card] is either an ordinary [CardRequest] or [SideCardRequest].
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

  /// The canonical card content. Runtime type selects fullscreen CARD versus
  /// windowed-video SIDECARD without inventing another hidden property model.
  final CardRequest card;

  bool get isSideCard => card is SideCardRequest;

  /// Absolute source span of the complete `[CUE]...[/CUE]` block.
  final int startOffset;
  final int endOffset;

  /// Complete authored CUE source, preserved exactly.
  final String rawSource;
}

/// One CARD-family cue that is actually visible at a specific structural frame.
///
/// The trigger belongs to the source-relative CLIP body, but after it fires the
/// presentation is evaluated from structural time and is allowed to continue
/// across a later cut. The containing EDIT/PANE, not the anchor CLIP, clips its
/// lifetime. This keeps the trigger attached to content without making the
/// owning clip a second presentation-duration authority.
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

  /// Pure CARD visual state for [localFrame]. CARD and SIDECARD intentionally
  /// share this lifetime: opening, authored hold, and closing are identical;
  /// only their pixel choreography differs.
  final CardPresentationFrame presentationFrame;
}

final RegExp _cueOpening = RegExp(r'\[CUE:(\d+)\]');
final RegExp _comment = RegExp(r'\[#.*?\]\n?', dotAll: true);
final RegExp _sideCardTag = RegExp(
  r'\[SIDECARD:([a-zA-Z0-9_\-\./]+)'
  r'(?::(\d+))?'
  r'(?::(\d+,\d+,\d+))?'
  r'(?::([^:\]]+))?\]'
  r'([\s\S]*?)\[/SIDECARD\]',
);
const String _cueClosing = '[/CUE]';

/// Parses every CARD-family cue owned by [clip].
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

      CardRequest? request;
      int? presentationEnd;

      final RegExpMatch? terminalPresentation =
          tagRegex.matchAsPrefix(source, contentAt) as RegExpMatch?;
      if (terminalPresentation != null) {
        final PresentationRequest? parsed =
            presentationRequestFromMatch(terminalPresentation);
        if (parsed is CardRequest) {
          request = parsed;
          presentationEnd = terminalPresentation.end;
        }
      }

      if (request == null && source.startsWith('[SIDECARD:', contentAt)) {
        final RegExpMatch? side =
            _sideCardTag.matchAsPrefix(source, contentAt) as RegExpMatch?;
        if (side == null) {
          throw EditCueFormatException(
            'SIDECARD has invalid CARD-style arguments or is not closed.',
            absoluteBase + contentAt,
          );
        }
        request = _sideCardRequestFromMatch(side);
        presentationEnd = side.end;
      }

      if (request == null || presentationEnd == null) {
        throw EditCueFormatException(
          'CUE must contain exactly one CARD or SIDECARD presentation.',
          absoluteBase + contentAt,
        );
      }

      final CardRequest card = _normalizeNestedCardBody(
        request,
        source: source,
        cardStart: contentAt,
      );

      final int closeAt = _skipWhitespace(source, presentationEnd);
      if (!source.startsWith(_cueClosing, closeAt)) {
        throw EditCueFormatException(
          'CUE must close immediately after its CARD or SIDECARD, apart from whitespace.',
          absoluteBase + closeAt,
        );
      }

      final int end = closeAt + _cueClosing.length;
      cues.add(
        EditCardCue(
          sourceFrame: sourceFrame,
          card: card,
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

SideCardRequest _sideCardRequestFromMatch(RegExpMatch match) {
  final String image = match.group(1)!;
  final int hold = int.parse(match.group(2) ?? '240');
  final Color color = _parsePanelColor(match.group(3));
  final String heading = (match.group(4) ?? '').trim();
  final String body = _cleanPresentationBody(match.group(5) ?? '');
  return SideCardRequest(
    image: image,
    holdFrames: hold,
    panelColor: color,
    heading: heading,
    body: body,
  );
}

Color _parsePanelColor(String? rgb) {
  if (rgb == null) return const Color.fromARGB(255, 30, 30, 38);
  final List<String> parts = rgb.split(',');
  if (parts.length != 3) {
    throw const FormatException('SIDECARD color requires r,g,b.');
  }
  return Color.fromARGB(
    255,
    int.parse(parts[0]),
    int.parse(parts[1]),
    int.parse(parts[2]),
  );
}

String _cleanPresentationBody(String raw) {
  String value = raw.replaceAll(RegExp(r'\[LINE:\d+\]'), '');
  if (value.startsWith('\r\n')) {
    value = value.substring(2);
  } else if (value.startsWith('\n')) {
    value = value.substring(1);
  }
  if (value.endsWith('\r\n')) {
    value = value.substring(0, value.length - 2);
  } else if (value.endsWith('\n')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

CardRequest _normalizeNestedCardBody(
  CardRequest request, {
  required String source,
  required int cardStart,
}) {
  final String cardIndent = _lineIndentAt(source, cardStart);
  final String bodyIndent = '$cardIndent  ';
  final List<String> lines = request.body
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');

  // The generic CARD parser intentionally knows nothing about surrounding
  // source indentation. Inside a CUE, the newline before the closing tag
  // therefore leaves the CARD line's indent as a final whitespace-only body
  // line. Remove only that layout line, not a user-authored blank line before
  // it.
  if (lines.isNotEmpty && lines.last == cardIndent) {
    lines.removeLast();
  }

  // Canonical CUE authoring indents body copy one level inside the presentation
  // tag. Strip exactly that structural prefix from each line. Any additional
  // spaces typed by the author remain intact, including deliberate indentation
  // and blank lines inside the body.
  for (int i = 0; i < lines.length; i++) {
    if (bodyIndent.isNotEmpty && lines[i].startsWith(bodyIndent)) {
      lines[i] = lines[i].substring(bodyIndent.length);
    }
  }

  if (request is SideCardRequest) {
    return SideCardRequest(
      image: request.image,
      holdFrames: request.holdFrames,
      panelColor: request.panelColor,
      heading: request.heading,
      body: lines.join('\n'),
    );
  }

  return CardRequest(
    image: request.image,
    holdFrames: request.holdFrames,
    panelColor: request.panelColor,
    heading: request.heading,
    body: lines.join('\n'),
  );
}

/// Returns every CARD-family cue visible in [edit] at [projectFrame].
///
/// Authored order is the deterministic stacking rule: tracks are visited in
/// source order, clips in source order, cues in body order. A later active cue
/// therefore follows an earlier one in the returned list and may be painted on
/// top without inventing a z-order language.
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

/// Returns every CARD-family cue visible in one MOSAIC pane at [projectFrame].
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

String _lineIndentAt(String source, int offset) {
  final int start = source.lastIndexOf('\n', offset > 0 ? offset - 1 : 0) + 1;
  int cursor = start;
  while (cursor < offset) {
    final int code = source.codeUnitAt(cursor);
    if (code != 32 && code != 9) break;
    cursor++;
  }
  return source.substring(start, cursor);
}
