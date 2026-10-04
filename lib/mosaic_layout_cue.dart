// ./lib/mosaic_layout_cue.dart
//
// Canonical MOSAIC-owned presentation layout grammar.
//
// LAYOUT directives are non-structural metadata that live directly inside a
// MOSAIC body. They therefore do not participate in ScriptCst nesting. Parsing
// is deliberately split from semantic validation: malformed syntax cannot be
// evaluated, while a syntactically valid cue that references a missing pane can
// still be opened and repaired by the editor.

import 'edit_model.dart';
import 'mosaic_split_geometry.dart';
import 'script_cst.dart';

const int kDefaultMosaicLayoutTransitionFrames = 12;

enum MosaicLayoutStateKind {
  composite,
  twoUp,
  overview,
  one,
  full,
}

extension MosaicLayoutStateKindToken on MosaicLayoutStateKind {
  String get token => switch (this) {
        MosaicLayoutStateKind.composite => 'COMPOSITE',
        MosaicLayoutStateKind.twoUp => 'TWOUP',
        MosaicLayoutStateKind.overview => 'OVERVIEW',
        MosaicLayoutStateKind.one => 'ONE',
        MosaicLayoutStateKind.full => 'FULL',
      };
}

class MosaicLayoutState {
  final MosaicLayoutStateKind kind;
  final String? paneA;
  final String? paneB;
  final String? paneId;
  final String? overviewMain;
  final List<String> overviewOthers;
  final MosaicSplitClientAspect splitAspect;
  final bool maximizeSplit;

  const MosaicLayoutState._({
    required this.kind,
    this.paneA,
    this.paneB,
    this.paneId,
    this.overviewMain,
    this.overviewOthers = const <String>[],
    this.splitAspect = MosaicSplitClientAspect.aspect16x9,
    this.maximizeSplit = false,
  });

  const MosaicLayoutState.composite()
      : this._(kind: MosaicLayoutStateKind.composite);

  const MosaicLayoutState.twoUp({
    String? paneA,
    String? paneB,
    MosaicSplitClientAspect aspect = MosaicSplitClientAspect.aspect16x9,
    bool maximized = false,
  }) : this._(
          kind: MosaicLayoutStateKind.twoUp,
          paneA: paneA,
          paneB: paneB,
          splitAspect: aspect,
          maximizeSplit: maximized,
        );

  factory MosaicLayoutState.overview({
    required String mainPane,
    required List<String> others,
    MosaicSplitClientAspect aspect = MosaicSplitClientAspect.aspect16x9,
  }) {
    if (mainPane.isEmpty) {
      throw ArgumentError.value(
        mainPane,
        'mainPane',
        'OVERVIEW MAIN is required.',
      );
    }
    if (others.length < 2 || others.length > 3) {
      throw ArgumentError.value(
        others,
        'others',
        'OVERVIEW requires two or three OTHERS panes.',
      );
    }
    final Set<String> unique = <String>{mainPane, ...others};
    if (unique.length != others.length + 1 ||
        others.any((String id) => id.isEmpty)) {
      throw ArgumentError(
        'OVERVIEW MAIN and OTHERS must be distinct non-empty pane ids.',
      );
    }
    return MosaicLayoutState._(
      kind: MosaicLayoutStateKind.overview,
      overviewMain: mainPane,
      overviewOthers: List<String>.unmodifiable(others),
      splitAspect: aspect,
    );
  }

  const MosaicLayoutState.one(String paneId)
      : this._(
          kind: MosaicLayoutStateKind.one,
          paneId: paneId,
        );

  const MosaicLayoutState.full(String paneId)
      : this._(
          kind: MosaicLayoutStateKind.full,
          paneId: paneId,
        );

  bool get isBareTwoUp =>
      kind == MosaicLayoutStateKind.twoUp && paneA == null && paneB == null;

  Iterable<String> get referencedPaneIds sync* {
    switch (kind) {
      case MosaicLayoutStateKind.composite:
        return;
      case MosaicLayoutStateKind.twoUp:
        if (paneA != null) yield paneA!;
        if (paneB != null) yield paneB!;
        return;
      case MosaicLayoutStateKind.overview:
        if (overviewMain != null) yield overviewMain!;
        yield* overviewOthers;
        return;
      case MosaicLayoutStateKind.one:
      case MosaicLayoutStateKind.full:
        if (paneId != null) yield paneId!;
        return;
    }
  }

  bool referencesPane(String id) => referencedPaneIds.contains(id);

  MosaicLayoutState renamePane(String oldId, String newId) {
    switch (kind) {
      case MosaicLayoutStateKind.composite:
        return this;
      case MosaicLayoutStateKind.twoUp:
        return MosaicLayoutState.twoUp(
          paneA: paneA == oldId ? newId : paneA,
          paneB: paneB == oldId ? newId : paneB,
          aspect: splitAspect,
          maximized: maximizeSplit,
        );
      case MosaicLayoutStateKind.overview:
        return MosaicLayoutState.overview(
          mainPane: overviewMain == oldId ? newId : overviewMain!,
          others: <String>[
            for (final String id in overviewOthers)
              id == oldId ? newId : id,
          ],
          aspect: splitAspect,
        );
      case MosaicLayoutStateKind.one:
        return MosaicLayoutState.one(paneId == oldId ? newId : paneId!);
      case MosaicLayoutStateKind.full:
        return MosaicLayoutState.full(paneId == oldId ? newId : paneId!);
    }
  }

  MosaicLayoutState resolveBareTwoUp(List<String> authoredPaneIds) {
    if (!isBareTwoUp) return this;
    if (authoredPaneIds.length < 2) {
      throw StateError(
        'Bare TWOUP requires at least two panes in authored MOSAIC order.',
      );
    }
    return MosaicLayoutState.twoUp(
      paneA: authoredPaneIds[0],
      paneB: authoredPaneIds[1],
      aspect: splitAspect,
      maximized: maximizeSplit,
    );
  }

  String formatTokens() {
    final List<String> out = <String>[kind.token];
    switch (kind) {
      case MosaicLayoutStateKind.composite:
        break;
      case MosaicLayoutStateKind.twoUp:
        if (paneA != null || paneB != null) {
          if (paneA == null || paneB == null) {
            throw StateError('TWOUP requires both A and B or neither.');
          }
          out
            ..add('A=$paneA')
            ..add('B=$paneB');
        }
        if (maximizeSplit) out.add('MAX');
        if (splitAspect != MosaicSplitClientAspect.aspect16x9) {
          out.add('ASPECT=${_aspectToken(splitAspect)}');
        }
        break;
      case MosaicLayoutStateKind.overview:
        if (overviewMain == null || overviewMain!.isEmpty) {
          throw StateError('OVERVIEW requires MAIN=<id>.');
        }
        if (overviewOthers.length < 2 || overviewOthers.length > 3) {
          throw StateError('OVERVIEW requires two or three OTHERS panes.');
        }
        out
          ..add('MAIN=$overviewMain')
          ..add('OTHERS=${overviewOthers.join(',')}');
        if (splitAspect != MosaicSplitClientAspect.aspect16x9) {
          out.add('ASPECT=${_aspectToken(splitAspect)}');
        }
        break;
      case MosaicLayoutStateKind.one:
      case MosaicLayoutStateKind.full:
        if (paneId == null || paneId!.isEmpty) {
          throw StateError('${kind.token} requires PANE=<id>.');
        }
        out.add('PANE=$paneId');
        break;
    }
    return out.join(':');
  }

  @override
  bool operator ==(Object other) {
    return other is MosaicLayoutState &&
        other.kind == kind &&
        other.paneA == paneA &&
        other.paneB == paneB &&
        other.paneId == paneId &&
        other.overviewMain == overviewMain &&
        _stringListsEqual(other.overviewOthers, overviewOthers) &&
        other.splitAspect == splitAspect &&
        other.maximizeSplit == maximizeSplit;
  }

  @override
  int get hashCode => Object.hash(
        kind,
        paneA,
        paneB,
        paneId,
        overviewMain,
        Object.hashAll(overviewOthers),
        splitAspect,
        maximizeSplit,
      );

  @override
  String toString() => formatTokens();
}

bool _stringListsEqual(List<String> a, List<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class MosaicLayoutSourceSpan {
  final int startOffset;
  final int endOffset;
  final String indent;
  final String lineEnding;

  const MosaicLayoutSourceSpan({
    required this.startOffset,
    required this.endOffset,
    required this.indent,
    required this.lineEnding,
  });
}

class MosaicLayoutStart {
  final MosaicLayoutState state;
  final MosaicLayoutSourceSpan? sourceSpan;

  const MosaicLayoutStart({
    required this.state,
    this.sourceSpan,
  });

  String formatTag() => '[LAYOUT_START:${state.formatTokens()}]';

  @override
  bool operator ==(Object other) =>
      other is MosaicLayoutStart && other.state == state;

  @override
  int get hashCode => state.hashCode;

  @override
  String toString() => formatTag();
}

class MosaicLayoutCue {
  final int frame;
  final MosaicLayoutState state;
  final int durationFrames;
  final MosaicLayoutSourceSpan? sourceSpan;

  const MosaicLayoutCue({
    required this.frame,
    required this.state,
    this.durationFrames = kDefaultMosaicLayoutTransitionFrames,
    this.sourceSpan,
  });

  MosaicLayoutCue copyWith({
    int? frame,
    MosaicLayoutState? state,
    int? durationFrames,
    MosaicLayoutSourceSpan? sourceSpan,
    bool clearSourceSpan = false,
  }) {
    return MosaicLayoutCue(
      frame: frame ?? this.frame,
      state: state ?? this.state,
      durationFrames: durationFrames ?? this.durationFrames,
      sourceSpan: clearSourceSpan ? null : (sourceSpan ?? this.sourceSpan),
    );
  }

  String formatTag() {
    if (frame < 0) {
      throw ArgumentError.value(frame, 'frame', 'LAYOUT frame must be >= 0.');
    }
    if (durationFrames < 0) {
      throw ArgumentError.value(
        durationFrames,
        'durationFrames',
        'LAYOUT DUR must be >= 0.',
      );
    }
    final StringBuffer out = StringBuffer(
      '[LAYOUT:$frame:${state.formatTokens()}',
    );
    if (durationFrames != kDefaultMosaicLayoutTransitionFrames) {
      out.write(':DUR=$durationFrames');
    }
    out.write(']');
    return out.toString();
  }

  @override
  bool operator ==(Object other) {
    return other is MosaicLayoutCue &&
        other.frame == frame &&
        other.state == state &&
        other.durationFrames == durationFrames;
  }

  @override
  int get hashCode => Object.hash(frame, state, durationFrames);

  @override
  String toString() => formatTag();
}

class MosaicLayoutFormatException implements FormatException {
  @override
  final String message;

  @override
  final dynamic source;

  @override
  final int? offset;

  const MosaicLayoutFormatException(
    this.message,
    int sourceOffset,
  )   : source = null,
        offset = sourceOffset;

  @override
  String toString() => 'MosaicLayoutFormatException: $message at $offset';
}

enum MosaicLayoutIssueSeverity {
  info,
  warning,
  error,
}

enum MosaicLayoutIssueCode {
  duplicateFrame,
  unknownPane,
  duplicateTwoUpPane,
  bareTwoUpNeedsTwoPanes,
  overviewNeedsThreePanes,
  deadCue,
  legacyWithCues,
  initialWithFrameZeroCue,
  noEffect,
}

class MosaicLayoutIssue {
  final MosaicLayoutIssueSeverity severity;
  final MosaicLayoutIssueCode code;
  final String message;
  final int? frame;

  const MosaicLayoutIssue({
    required this.severity,
    required this.code,
    required this.message,
    this.frame,
  });

  bool get isError => severity == MosaicLayoutIssueSeverity.error;
}

class MosaicLayoutValidationResult {
  final List<MosaicLayoutIssue> issues;

  const MosaicLayoutValidationResult._(this.issues);

  bool get isValid => !issues.any((MosaicLayoutIssue issue) => issue.isError);

  Iterable<MosaicLayoutIssue> get errors =>
      issues.where((MosaicLayoutIssue issue) => issue.isError);
}

MosaicLayoutStart? parseMosaicLayoutStart({
  required String source,
  required MosaicSequence mosaic,
}) {
  final String inner = source.substring(
    mosaic.block.openEndOffset,
    mosaic.block.closeStartOffset,
  );
  final RegExp canonicalLine = RegExp(
    r'^(?<indent>[ \t]*)\[LAYOUT_START:(?<body>[^\]\r\n]+)\][ \t]*(?<eol>\r?\n|$)$',
  );

  MosaicLayoutStart? found;
  int cursor = 0;
  while (cursor < inner.length) {
    final int newline = inner.indexOf('\n', cursor);
    final int lineEnd = newline < 0 ? inner.length : newline + 1;
    final String rawLine = inner.substring(cursor, lineEnd);
    final int globalStart = mosaic.block.openEndOffset + cursor;
    cursor = lineEnd;

    if (_insideChildBlock(globalStart, mosaic.block.children)) continue;

    final String leftTrimmed = rawLine.trimLeft();
    if (!leftTrimmed.startsWith('[LAYOUT_START')) continue;

    final RegExpMatch? match = canonicalLine.firstMatch(rawLine);
    if (match == null) {
      throw MosaicLayoutFormatException(
        'Malformed direct MOSAIC LAYOUT_START directive.',
        globalStart,
      );
    }
    if (found != null) {
      throw MosaicLayoutFormatException(
        'Only one LAYOUT_START directive is allowed per MOSAIC.',
        globalStart,
      );
    }

    final List<String> segments = match
        .namedGroup('body')!
        .split(':')
        .map((String token) => token.trim())
        .toList();
    if (segments.isEmpty || segments.any((String token) => token.isEmpty)) {
      throw MosaicLayoutFormatException(
        'LAYOUT_START requires a state before optional tokens.',
        globalStart,
      );
    }
    if (segments.skip(1).any(
          (String token) => token.toUpperCase().startsWith('DUR='),
        )) {
      throw MosaicLayoutFormatException(
        'LAYOUT_START does not accept DUR= because it is an initial condition, not a transition.',
        globalStart,
      );
    }

    final MosaicLayoutStateKind? kind = _stateKindFromToken(segments[0]);
    if (kind == null) {
      throw MosaicLayoutFormatException(
        'Unknown LAYOUT_START state "${segments[0]}".',
        globalStart,
      );
    }

    final _ParsedLayoutOptions options = _parseOptions(
      kind,
      segments.skip(1),
      globalStart,
    );
    final MosaicLayoutState state = switch (kind) {
      MosaicLayoutStateKind.composite => const MosaicLayoutState.composite(),
      MosaicLayoutStateKind.twoUp => MosaicLayoutState.twoUp(
          paneA: options.paneA,
          paneB: options.paneB,
          aspect: options.aspect,
          maximized: options.maximized,
        ),
      MosaicLayoutStateKind.overview => MosaicLayoutState.overview(
          mainPane: options.overviewMain!,
          others: options.overviewOthers,
          aspect: options.aspect,
        ),
      MosaicLayoutStateKind.one => MosaicLayoutState.one(options.paneId!),
      MosaicLayoutStateKind.full => MosaicLayoutState.full(options.paneId!),
    };

    found = MosaicLayoutStart(
      state: state,
      sourceSpan: MosaicLayoutSourceSpan(
        startOffset: globalStart,
        endOffset: globalStart + rawLine.length,
        indent: match.namedGroup('indent') ?? '',
        lineEnding: match.namedGroup('eol') ?? '',
      ),
    );
  }

  return found;
}

List<MosaicLayoutCue> parseMosaicLayoutCues({
  required String source,
  required MosaicSequence mosaic,
}) {
  final String inner = source.substring(
    mosaic.block.openEndOffset,
    mosaic.block.closeStartOffset,
  );
  final List<MosaicLayoutCue> out = <MosaicLayoutCue>[];
  final RegExp canonicalLine = RegExp(
    r'^(?<indent>[ \t]*)\[LAYOUT:(?<body>[^\]\r\n]+)\][ \t]*(?<eol>\r?\n|$)$',
  );

  int cursor = 0;
  while (cursor < inner.length) {
    final int newline = inner.indexOf('\n', cursor);
    final int lineEnd = newline < 0 ? inner.length : newline + 1;
    final String rawLine = inner.substring(cursor, lineEnd);
    final int globalStart = mosaic.block.openEndOffset + cursor;
    cursor = lineEnd;

    if (_insideChildBlock(globalStart, mosaic.block.children)) continue;

    final String leftTrimmed = rawLine.trimLeft();
    if (!leftTrimmed.startsWith('[LAYOUT:')) continue;

    final RegExpMatch? match = canonicalLine.firstMatch(rawLine);
    if (match == null) {
      throw MosaicLayoutFormatException(
        'Malformed direct MOSAIC LAYOUT directive.',
        globalStart,
      );
    }

    final String body = match.namedGroup('body')!;
    final List<String> segments =
        body.split(':').map((String token) => token.trim()).toList();
    if (segments.length < 2 || segments.any((String token) => token.isEmpty)) {
      throw MosaicLayoutFormatException(
        'LAYOUT requires frame and state before optional tokens.',
        globalStart,
      );
    }

    final int? frame = int.tryParse(segments[0]);
    if (frame == null || frame < 0) {
      throw MosaicLayoutFormatException(
        'LAYOUT frame must be a non-negative integer.',
        globalStart,
      );
    }

    final MosaicLayoutStateKind? kind = _stateKindFromToken(segments[1]);
    if (kind == null) {
      throw MosaicLayoutFormatException(
        'Unknown LAYOUT state "${segments[1]}".',
        globalStart,
      );
    }

    final _ParsedLayoutOptions options = _parseOptions(
      kind,
      segments.skip(2),
      globalStart,
    );

    final MosaicLayoutState state = switch (kind) {
      MosaicLayoutStateKind.composite => const MosaicLayoutState.composite(),
      MosaicLayoutStateKind.twoUp => MosaicLayoutState.twoUp(
          paneA: options.paneA,
          paneB: options.paneB,
          aspect: options.aspect,
          maximized: options.maximized,
        ),
      MosaicLayoutStateKind.overview => MosaicLayoutState.overview(
          mainPane: options.overviewMain!,
          others: options.overviewOthers,
          aspect: options.aspect,
        ),
      MosaicLayoutStateKind.one => MosaicLayoutState.one(options.paneId!),
      MosaicLayoutStateKind.full => MosaicLayoutState.full(options.paneId!),
    };

    out.add(
      MosaicLayoutCue(
        frame: frame,
        state: state,
        durationFrames: options.durationFrames,
        sourceSpan: MosaicLayoutSourceSpan(
          startOffset: globalStart,
          endOffset: globalStart + rawLine.length,
          indent: match.namedGroup('indent') ?? '',
          lineEnding: match.namedGroup('eol') ?? '',
        ),
      ),
    );
  }

  return List<MosaicLayoutCue>.unmodifiable(out);
}

MosaicLayoutValidationResult validateMosaicLayoutCues({
  required MosaicSequence mosaic,
  required List<MosaicLayoutCue> cues,
}) {
  final List<MosaicLayoutIssue> issues = <MosaicLayoutIssue>[];
  final Set<int> frames = <int>{};
  final Set<String> paneIds =
      mosaic.panes.map((MosaicPane pane) => pane.id).toSet();

  for (final MosaicLayoutCue cue in cues) {
    if (!frames.add(cue.frame)) {
      issues.add(
        MosaicLayoutIssue(
          severity: MosaicLayoutIssueSeverity.error,
          code: MosaicLayoutIssueCode.duplicateFrame,
          message: 'Two LAYOUT cues occupy frame ${cue.frame}.',
          frame: cue.frame,
        ),
      );
    }

    if (cue.state.isBareTwoUp && mosaic.panes.length < 2) {
      issues.add(
        MosaicLayoutIssue(
          severity: MosaicLayoutIssueSeverity.error,
          code: MosaicLayoutIssueCode.bareTwoUpNeedsTwoPanes,
          message: 'Bare TWOUP at frame ${cue.frame} requires at least two panes.',
          frame: cue.frame,
        ),
      );
    }

    if (cue.state.kind == MosaicLayoutStateKind.overview &&
        mosaic.panes.length < 3) {
      issues.add(
        MosaicLayoutIssue(
          severity: MosaicLayoutIssueSeverity.error,
          code: MosaicLayoutIssueCode.overviewNeedsThreePanes,
          message:
              'OVERVIEW at frame ${cue.frame} requires at least three panes.',
          frame: cue.frame,
        ),
      );
    }

    if (cue.state.kind == MosaicLayoutStateKind.twoUp &&
        cue.state.paneA != null &&
        cue.state.paneA == cue.state.paneB) {
      issues.add(
        MosaicLayoutIssue(
          severity: MosaicLayoutIssueSeverity.error,
          code: MosaicLayoutIssueCode.duplicateTwoUpPane,
          message: 'TWOUP at frame ${cue.frame} names the same pane twice.',
          frame: cue.frame,
        ),
      );
    }

    for (final String id in cue.state.referencedPaneIds) {
      if (!paneIds.contains(id)) {
        issues.add(
          MosaicLayoutIssue(
            severity: MosaicLayoutIssueSeverity.error,
            code: MosaicLayoutIssueCode.unknownPane,
            message: 'LAYOUT at frame ${cue.frame} references unknown PANE "$id".',
            frame: cue.frame,
          ),
        );
      }
    }

    if (cue.frame >= mosaic.projectFrameCount) {
      issues.add(
        MosaicLayoutIssue(
          severity: MosaicLayoutIssueSeverity.warning,
          code: MosaicLayoutIssueCode.deadCue,
          message: 'LAYOUT at frame ${cue.frame} is outside the MOSAIC duration.',
          frame: cue.frame,
        ),
      );
    }
  }

  return MosaicLayoutValidationResult._(
    List<MosaicLayoutIssue>.unmodifiable(issues),
  );
}

_ParsedLayoutOptions _parseOptions(
  MosaicLayoutStateKind kind,
  Iterable<String> rawTokens,
  int offset,
) {
  String? paneA;
  String? paneB;
  String? paneId;
  String? overviewMain;
  List<String>? overviewOthers;
  bool maximized = false;
  bool sawMax = false;
  MosaicSplitClientAspect aspect = MosaicSplitClientAspect.aspect16x9;
  bool sawAspect = false;
  int duration = kDefaultMosaicLayoutTransitionFrames;
  bool sawDuration = false;

  for (final String raw in rawTokens) {
    final String token = raw.trim();
    if (token.isEmpty) {
      throw MosaicLayoutFormatException(
        'LAYOUT optional tokens cannot be empty.',
        offset,
      );
    }

    if (token.toUpperCase() == 'MAX') {
      if (kind != MosaicLayoutStateKind.twoUp || sawMax) {
        throw MosaicLayoutFormatException(
          'LAYOUT MAX is valid once and only on TWOUP.',
          offset,
        );
      }
      sawMax = true;
      maximized = true;
      continue;
    }

    final int equals = token.indexOf('=');
    if (equals <= 0 || equals == token.length - 1) {
      throw MosaicLayoutFormatException(
        'Unknown LAYOUT token "$token".',
        offset,
      );
    }
    final String key = token.substring(0, equals).trim().toUpperCase();
    final String value = token.substring(equals + 1).trim();

    switch (key) {
      case 'A':
        if (kind != MosaicLayoutStateKind.twoUp || paneA != null) {
          throw MosaicLayoutFormatException(
            'LAYOUT A= is valid once and only on TWOUP.',
            offset,
          );
        }
        _validatePaneToken(value, offset);
        paneA = value;
        break;
      case 'B':
        if (kind != MosaicLayoutStateKind.twoUp || paneB != null) {
          throw MosaicLayoutFormatException(
            'LAYOUT B= is valid once and only on TWOUP.',
            offset,
          );
        }
        _validatePaneToken(value, offset);
        paneB = value;
        break;
      case 'MAIN':
        if (kind != MosaicLayoutStateKind.overview || overviewMain != null) {
          throw MosaicLayoutFormatException(
            'LAYOUT MAIN= is valid once and only on OVERVIEW.',
            offset,
          );
        }
        _validatePaneToken(value, offset);
        overviewMain = value;
        break;
      case 'OTHERS':
        if (kind != MosaicLayoutStateKind.overview || overviewOthers != null) {
          throw MosaicLayoutFormatException(
            'LAYOUT OTHERS= is valid once and only on OVERVIEW.',
            offset,
          );
        }
        final List<String> ids =
            value.split(',').map((String id) => id.trim()).toList();
        if (ids.length < 2 || ids.length > 3) {
          throw MosaicLayoutFormatException(
            'OVERVIEW OTHERS must name two or three panes.',
            offset,
          );
        }
        for (final String id in ids) {
          _validatePaneToken(id, offset);
        }
        if (ids.toSet().length != ids.length) {
          throw MosaicLayoutFormatException(
            'OVERVIEW OTHERS cannot contain duplicate panes.',
            offset,
          );
        }
        overviewOthers = List<String>.unmodifiable(ids);
        break;
      case 'PANE':
        if ((kind != MosaicLayoutStateKind.one &&
                kind != MosaicLayoutStateKind.full) ||
            paneId != null) {
          throw MosaicLayoutFormatException(
            'LAYOUT PANE= is valid once and only on ONE/FULL.',
            offset,
          );
        }
        _validatePaneToken(value, offset);
        paneId = value;
        break;
      case 'ASPECT':
        if ((kind != MosaicLayoutStateKind.twoUp &&
                kind != MosaicLayoutStateKind.overview) ||
            sawAspect) {
          throw MosaicLayoutFormatException(
            'LAYOUT ASPECT= is valid once and only on TWOUP/OVERVIEW.',
            offset,
          );
        }
        final MosaicSplitClientAspect? parsed = _aspectFromToken(value);
        if (parsed == null) {
          throw MosaicLayoutFormatException(
            'LAYOUT ASPECT must be 16X9, 4X3, or 9X16.',
            offset,
          );
        }
        aspect = parsed;
        sawAspect = true;
        break;
      case 'DUR':
        if (sawDuration) {
          throw MosaicLayoutFormatException(
            'LAYOUT DUR= may appear at most once.',
            offset,
          );
        }
        final int? parsed = int.tryParse(value);
        if (parsed == null || parsed < 0) {
          throw MosaicLayoutFormatException(
            'LAYOUT DUR must be a non-negative integer.',
            offset,
          );
        }
        duration = parsed;
        sawDuration = true;
        break;
      default:
        throw MosaicLayoutFormatException(
          'Unknown LAYOUT option "$key".',
          offset,
        );
    }
  }

  if (kind == MosaicLayoutStateKind.twoUp && (paneA == null) != (paneB == null)) {
    throw MosaicLayoutFormatException(
      'TWOUP requires both A=<pane> and B=<pane>, or neither.',
      offset,
    );
  }
  if (kind == MosaicLayoutStateKind.overview) {
    if (overviewMain == null || overviewOthers == null) {
      throw MosaicLayoutFormatException(
        'OVERVIEW requires MAIN=<pane> and OTHERS=<pane>,<pane>[,<pane>].',
        offset,
      );
    }
    if (overviewOthers.contains(overviewMain)) {
      throw MosaicLayoutFormatException(
        'OVERVIEW MAIN cannot also appear in OTHERS.',
        offset,
      );
    }
  }
  if ((kind == MosaicLayoutStateKind.one ||
          kind == MosaicLayoutStateKind.full) &&
      paneId == null) {
    throw MosaicLayoutFormatException(
      '${kind.token} requires PANE=<id>.',
      offset,
    );
  }

  return _ParsedLayoutOptions(
    paneA: paneA,
    paneB: paneB,
    paneId: paneId,
    overviewMain: overviewMain,
    overviewOthers: overviewOthers ?? const <String>[],
    maximized: maximized,
    aspect: aspect,
    durationFrames: duration,
  );
}

bool _insideChildBlock(int offset, List<ScriptCstBlock> children) {
  for (final ScriptCstBlock child in children) {
    if (offset >= child.startOffset && offset < child.endOffset) return true;
  }
  return false;
}

void _validatePaneToken(String value, int offset) {
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
    throw MosaicLayoutFormatException(
      'LAYOUT pane ids must use letters, numbers, underscore, or hyphen.',
      offset,
    );
  }
}

MosaicLayoutStateKind? _stateKindFromToken(String raw) {
  return switch (raw.trim().toUpperCase()) {
    'COMPOSITE' => MosaicLayoutStateKind.composite,
    'TWOUP' => MosaicLayoutStateKind.twoUp,
    'OVERVIEW' => MosaicLayoutStateKind.overview,
    'ONE' => MosaicLayoutStateKind.one,
    'FULL' => MosaicLayoutStateKind.full,
    _ => null,
  };
}

String _aspectToken(MosaicSplitClientAspect aspect) {
  return switch (aspect) {
    MosaicSplitClientAspect.aspect16x9 => '16X9',
    MosaicSplitClientAspect.aspect4x3 => '4X3',
    MosaicSplitClientAspect.aspect9x16 => '9X16',
  };
}

MosaicSplitClientAspect? _aspectFromToken(String raw) {
  return switch (raw.trim().toUpperCase()) {
    '16X9' => MosaicSplitClientAspect.aspect16x9,
    '4X3' => MosaicSplitClientAspect.aspect4x3,
    '9X16' => MosaicSplitClientAspect.aspect9x16,
    _ => null,
  };
}

class _ParsedLayoutOptions {
  final String? paneA;
  final String? paneB;
  final String? paneId;
  final String? overviewMain;
  final List<String> overviewOthers;
  final bool maximized;
  final MosaicSplitClientAspect aspect;
  final int durationFrames;

  const _ParsedLayoutOptions({
    required this.paneA,
    required this.paneB,
    required this.paneId,
    required this.overviewMain,
    required this.overviewOthers,
    required this.maximized,
    required this.aspect,
    required this.durationFrames,
  });
}
