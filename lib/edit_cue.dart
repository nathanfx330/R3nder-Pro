// ./lib/edit_cue.dart
//
// Clip-local source-relative triggers for structural EDIT time.
//
// A CUE owns only the source frame at which one authored event begins. Content
// presentations (CARD, SIDECARD, DOSSIER) own their own deterministic lifetime
// and pixels. MAXIMIZE is deliberately different: it paints no content and is
// represented as a shell cue whose geometry is owned later by STRUCT.
//
// Keeping every trigger in source coordinates makes it follow the clip's
// content through moves, trims, slips, and exact rational speed changes without
// introducing a second project clock.

import 'package:flutter/material.dart';

import 'card_presentation.dart';
import 'edit_model.dart';
import 'maximize_presentation.dart';
import 'parser.dart' show tagRegex;
import 'presentation_requests.dart';

class EditCueFormatException implements Exception {
  final String message;
  final int offset;

  const EditCueFormatException(this.message, this.offset);

  @override
  String toString() => 'EditCueFormatException at $offset: $message';
}

/// One unbounded occupied interval on the EDIT project timeline.
///
/// CUE timing is intentionally hybrid. The trigger is authored in source frames
/// and projected through the current CLIP geometry, while presentation lifetime
/// is already a project-frame quantity. The range is therefore not clamped to a
/// CLIP, EDIT, or parent container boundary.
class CueOccupiedRange {
  const CueOccupiedRange({
    required this.startFrame,
    required this.endFrameExclusive,
  })  : assert(startFrame >= 0),
        assert(endFrameExclusive > startFrame);

  final int startFrame;
  final int endFrameExclusive;

  bool overlaps(CueOccupiedRange other) =>
      startFrame < other.endFrameExclusive &&
      other.startFrame < endFrameExclusive;

  @override
  String toString() => '[$startFrame, $endFrameExclusive)';
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

  final int sourceFrame;
  final CardRequest card;

  bool get isSideCard => card is SideCardRequest;

  final int startOffset;
  final int endOffset;
  final String rawSource;
}

/// One DOSSIER presentation triggered from a source-relative frame in a CLIP.
///
/// Unlike CARD, DOSSIER lifetime depends on its evidence branch and, for a
/// mosaic, on the number of resolved evidence pages. This object therefore
/// stores authored facts and trigger position only.
class EditDossierCue {
  const EditDossierCue({
    required this.sourceFrame,
    required this.dossier,
    required this.startOffset,
    required this.endOffset,
    required this.rawSource,
  });

  final int sourceFrame;
  final DossierRequest dossier;
  final int startOffset;
  final int endOffset;
  final String rawSource;
}

/// One shell-only MAXIMIZE event.
///
/// MAXIMIZE intentionally does not extend PresentationRequest. It contributes no
/// pixels and owns no layout; its authored fact is only the fullscreen hold.
class EditMaximizeCue {
  const EditMaximizeCue({
    required this.sourceFrame,
    required this.holdFrames,
    required this.startOffset,
    required this.endOffset,
    required this.rawSource,
  });

  final int sourceFrame;
  final int holdFrames;
  final int startOffset;
  final int endOffset;
  final String rawSource;
}

/// One CARD-family cue that is actually visible at a specific structural frame.
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
  final int localFrame;
  final CardPresentationFrame presentationFrame;
}

/// One triggered DOSSIER cue at a specific structural frame.
///
/// Triggered does not necessarily mean still visible. The caller that knows the
/// resolved evidence page count evaluates [localFrame] through its DOSSIER
/// timing and drops it once that explicit lifetime ends.
class ActiveEditDossierCue {
  const ActiveEditDossierCue({
    required this.clip,
    required this.cue,
    required this.triggerProjectFrame,
    required this.localFrame,
  });

  final EditClip clip;
  final EditDossierCue cue;
  final int triggerProjectFrame;
  final int localFrame;
}

/// One active shell-only MAXIMIZE cue at an EDIT project frame.
class ActiveEditMaximizeCue {
  const ActiveEditMaximizeCue({
    required this.clip,
    required this.cue,
    required this.triggerProjectFrame,
    required this.localFrame,
    required this.presentationFrame,
  });

  final EditClip clip;
  final EditMaximizeCue cue;
  final int triggerProjectFrame;
  final int localFrame;
  final MaximizePresentationFrame presentationFrame;
}

class _ParsedEditCue {
  const _ParsedEditCue({
    required this.sourceFrame,
    required this.presentation,
    required this.maximizeHoldFrames,
    required this.startOffset,
    required this.endOffset,
    required this.rawSource,
  });

  final int sourceFrame;

  /// Content-producing payload. Null for shell-only MAXIMIZE.
  final PresentationRequest? presentation;

  /// Shell-only payload. Null for content presentations.
  final int? maximizeHoldFrames;

  final int startOffset;
  final int endOffset;
  final String rawSource;
}

final RegExp _cueOpening = RegExp(r'\[CUE:(\d+)\]');
final RegExp _comment = RegExp(r'\[#.*?\]\n?', dotAll: true);
final RegExp _maximizeTag = RegExp(r'\[MAXIMIZE:(\d+)\]');
final RegExp _sideCardTag = RegExp(
  r'\[SIDECARD:([a-zA-Z0-9_\-\./]+)'
  r'(?::(\d+))?'
  r'(?::(\d+,\d+,\d+))?'
  r'(?::([^:\]]+))?\]'
  r'([\s\S]*?)\[/SIDECARD\]',
);
const String _cueClosing = '[/CUE]';

/// Parses every CARD-family cue owned by [clip]. Other valid CUE payloads are
/// skipped rather than misreported as malformed CARD source.
List<EditCardCue> parseClipCardCues(EditClip clip) {
  final List<EditCardCue> out = <EditCardCue>[];
  for (final _ParsedEditCue cue in _parseClipCues(clip)) {
    final PresentationRequest? presentation = cue.presentation;
    if (presentation is! CardRequest) continue;
    out.add(
      EditCardCue(
        sourceFrame: cue.sourceFrame,
        card: presentation,
        startOffset: cue.startOffset,
        endOffset: cue.endOffset,
        rawSource: cue.rawSource,
      ),
    );
  }
  return List<EditCardCue>.unmodifiable(out);
}

/// Parses every DOSSIER cue owned by [clip].
List<EditDossierCue> parseClipDossierCues(EditClip clip) {
  final List<EditDossierCue> out = <EditDossierCue>[];
  for (final _ParsedEditCue cue in _parseClipCues(clip)) {
    final PresentationRequest? presentation = cue.presentation;
    if (presentation is! DossierRequest) continue;
    out.add(
      EditDossierCue(
        sourceFrame: cue.sourceFrame,
        dossier: presentation,
        startOffset: cue.startOffset,
        endOffset: cue.endOffset,
        rawSource: cue.rawSource,
      ),
    );
  }
  return List<EditDossierCue>.unmodifiable(out);
}

/// Parses every shell-only MAXIMIZE cue owned by [clip].
List<EditMaximizeCue> parseClipMaximizeCues(EditClip clip) {
  final List<EditMaximizeCue> out = <EditMaximizeCue>[];
  for (final _ParsedEditCue cue in _parseClipCues(clip)) {
    final int? holdFrames = cue.maximizeHoldFrames;
    if (holdFrames == null) continue;
    out.add(
      EditMaximizeCue(
        sourceFrame: cue.sourceFrame,
        holdFrames: holdFrames,
        startOffset: cue.startOffset,
        endOffset: cue.endOffset,
        rawSource: cue.rawSource,
      ),
    );
  }
  return List<EditMaximizeCue>.unmodifiable(out);
}

List<_ParsedEditCue> _parseClipCues(EditClip clip) {
  final String source = clip.block.innerSource;
  final int absoluteBase = clip.block.openEndOffset;
  final List<_ParsedEditCue> cues = <_ParsedEditCue>[];

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

      PresentationRequest? request;
      int? maximizeHoldFrames;
      int? payloadEnd;

      final RegExpMatch? terminalPresentation =
          tagRegex.matchAsPrefix(source, contentAt) as RegExpMatch?;
      if (terminalPresentation != null) {
        final PresentationRequest? parsed =
            presentationRequestFromMatch(terminalPresentation);
        if (parsed is CardRequest || parsed is DossierRequest) {
          request = parsed;
          payloadEnd = terminalPresentation.end;
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
        payloadEnd = side.end;
      }

      if (request == null && source.startsWith('[MAXIMIZE:', contentAt)) {
        final RegExpMatch? maximize =
            _maximizeTag.matchAsPrefix(source, contentAt) as RegExpMatch?;
        if (maximize == null) {
          throw EditCueFormatException(
            'MAXIMIZE requires one non-negative integer hold frame count.',
            absoluteBase + contentAt,
          );
        }
        maximizeHoldFrames = int.parse(maximize.group(1)!);
        payloadEnd = maximize.end;
      }

      if (payloadEnd == null ||
          (request == null && maximizeHoldFrames == null)) {
        throw EditCueFormatException(
          'CUE must contain exactly one CARD, SIDECARD, DOSSIER, or MAXIMIZE payload.',
          absoluteBase + contentAt,
        );
      }

      final PresentationRequest? normalized = request == null
          ? null
          : _normalizeNestedPresentationBody(
              request,
              source: source,
              presentationStart: contentAt,
            );

      final int closeAt = _skipWhitespace(source, payloadEnd);
      if (!source.startsWith(_cueClosing, closeAt)) {
        throw EditCueFormatException(
          'CUE must close immediately after its payload, apart from whitespace.',
          absoluteBase + closeAt,
        );
      }

      final int end = closeAt + _cueClosing.length;
      cues.add(
        _ParsedEditCue(
          sourceFrame: sourceFrame,
          presentation: normalized,
          maximizeHoldFrames: maximizeHoldFrames,
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

  return List<_ParsedEditCue>.unmodifiable(cues);
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

PresentationRequest _normalizeNestedPresentationBody(
  PresentationRequest request, {
  required String source,
  required int presentationStart,
}) {
  if (request is CardRequest) {
    final String body = _normalizeNestedBody(
      request.body,
      source: source,
      presentationStart: presentationStart,
    );
    if (request is SideCardRequest) {
      return SideCardRequest(
        image: request.image,
        holdFrames: request.holdFrames,
        panelColor: request.panelColor,
        heading: request.heading,
        body: body,
      );
    }
    return CardRequest(
      image: request.image,
      holdFrames: request.holdFrames,
      panelColor: request.panelColor,
      heading: request.heading,
      body: body,
    );
  }

  if (request is DossierRequest) {
    return DossierRequest(
      folder: request.folder,
      image: request.image,
      holdSplit: request.holdSplit,
      holdFull: request.holdFull,
      centerMode: request.centerMode,
      cardLead: request.cardLead,
      panelColor: request.panelColor,
      heading: request.heading,
      body: _normalizeNestedBody(
        request.body,
        source: source,
        presentationStart: presentationStart,
      ),
    );
  }

  return request;
}

String _normalizeNestedBody(
  String body, {
  required String source,
  required int presentationStart,
}) {
  final String presentationIndent = _lineIndentAt(source, presentationStart);
  final String bodyIndent = '$presentationIndent  ';
  final List<String> lines = body
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');

  if (lines.isNotEmpty && lines.last == presentationIndent) {
    lines.removeLast();
  }

  for (int i = 0; i < lines.length; i++) {
    if (bodyIndent.isNotEmpty && lines[i].startsWith(bodyIndent)) {
      lines[i] = lines[i].substring(bodyIndent.length);
    }
  }
  return lines.join('\n');
}

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

/// Returns every DOSSIER cue whose source-relative trigger has fired by
/// [projectFrame]. Exact visible lifetime is resolved later with the evidence
/// page count, because that count belongs to the asset-backed presentation.
List<ActiveEditDossierCue> activeDossierCuesForEdit(
  EditSequence edit,
  int projectFrame,
) {
  if (projectFrame < 0 || projectFrame >= edit.projectFrameCount) {
    return const <ActiveEditDossierCue>[];
  }
  return _activeDossierCues(
    edit.tracks.expand((EditTrack track) => track.clips),
    projectFrame,
  );
}

List<ActiveEditDossierCue> activeDossierCuesForPane(
  MosaicPane pane,
  int projectFrame,
) {
  if (projectFrame < 0 || projectFrame >= pane.projectFrameCount) {
    return const <ActiveEditDossierCue>[];
  }
  return _activeDossierCues(pane.clips, projectFrame);
}

List<ActiveEditDossierCue> _activeDossierCues(
  Iterable<EditClip> clips,
  int projectFrame,
) {
  final List<ActiveEditDossierCue> active = <ActiveEditDossierCue>[];
  for (final EditClip clip in clips) {
    for (final EditDossierCue cue in parseClipDossierCues(clip)) {
      final int? trigger = cueProjectFrame(clip, cue.sourceFrame);
      if (trigger == null || projectFrame < trigger) continue;
      active.add(
        ActiveEditDossierCue(
          clip: clip,
          cue: cue,
          triggerProjectFrame: trigger,
          localFrame: projectFrame - trigger,
        ),
      );
    }
  }
  return List<ActiveEditDossierCue>.unmodifiable(active);
}

/// Shell-only MAXIMIZE cues are meaningful for an EDIT root. They deliberately
/// have no MosaicPane variant in v1 because a pane-local cue must not seize the
/// geometry of the whole outer MOSAIC window.
List<ActiveEditMaximizeCue> activeMaximizeCuesForEdit(
  EditSequence edit,
  int projectFrame,
) {
  if (projectFrame < 0 || projectFrame >= edit.projectFrameCount) {
    return const <ActiveEditMaximizeCue>[];
  }

  final List<ActiveEditMaximizeCue> active = <ActiveEditMaximizeCue>[];
  for (final EditClip clip
      in edit.tracks.expand((EditTrack track) => track.clips)) {
    for (final EditMaximizeCue cue in parseClipMaximizeCues(clip)) {
      final int? trigger = cueProjectFrame(clip, cue.sourceFrame);
      if (trigger == null || projectFrame < trigger) continue;

      final int localFrame = projectFrame - trigger;
      final MaximizePresentationFrame? presentationFrame =
          MaximizePresentationTiming(
        holdFrames: cue.holdFrames,
      ).frameAt(localFrame);
      if (presentationFrame == null) continue;

      active.add(
        ActiveEditMaximizeCue(
          clip: clip,
          cue: cue,
          triggerProjectFrame: trigger,
          localFrame: localFrame,
          presentationFrame: presentationFrame,
        ),
      );
    }
  }
  return List<ActiveEditMaximizeCue>.unmodifiable(active);
}

/// Returns the project-frame offset inside [clip] where [cueSourceFrame]
/// becomes active, or null when that source point is outside the clip's
/// current visible source window.
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

int? cueProjectFrame(EditClip clip, int cueSourceFrame) {
  final int? offset = cueProjectOffset(clip, cueSourceFrame);
  return offset == null ? null : clip.atFrame + offset;
}

/// Projects a source-relative CUE trigger plus an already-resolved project
/// lifetime onto the EDIT timeline.
///
/// A null result means the trigger is outside the CLIP's current visible source
/// window and is therefore inert. The returned range is deliberately unbounded:
/// presentation lifetime can continue past the source CLIP, and reusable EDITs
/// can be truncated differently by different parent containers.
CueOccupiedRange? cueOccupiedRange(
  EditClip clip,
  int cueSourceFrame,
  int durationFrames,
) {
  if (durationFrames <= 0) {
    throw ArgumentError.value(
      durationFrames,
      'durationFrames',
      'CUE occupied duration must be positive.',
    );
  }

  final int? startFrame = cueProjectFrame(clip, cueSourceFrame);
  if (startFrame == null) return null;
  return CueOccupiedRange(
    startFrame: startFrame,
    endFrameExclusive: startFrame + durationFrames,
  );
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
