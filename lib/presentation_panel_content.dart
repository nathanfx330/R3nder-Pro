// ./lib/presentation_panel_content.dart
//
// Structured content carried inside opaque CARD-family presentation bodies.
//
// The CARD/SIDECARD/DOSSIER headers continue to own identity, timing, color,
// and source geometry. Richer typography is authored inside the already-opaque
// body so variable metadata does not turn the colon-delimited header into a
// second layout language.
//
// Canonical form:
//
//   [PANEL]
//   PRESET: DOCUMENTARY
//   KICKER: PROFILE / DOCUMENTARY
//   FONT: IBM Plex Sans
//   SUBTITLE: Investigative Reporter
//   META: ORGANIZATION | Example News
//   META: LOCATION | Washington, DC
//   [/PANEL]
//   Biography copy continues here.
//
// The block owns no time and no coordinates. Unknown directives are preserved
// so a newer script can round trip through an older build. Malformed PANEL
// source is surfaced explicitly through [issues] rather than being silently
// reinterpreted as ordinary biography text.

enum PresentationPanelPreset {
  simple,
  editorial,
  documentary,
  dossier,
}

PresentationPanelPreset? _tryPresentationPanelPresetFromName(String raw) {
  switch (raw.trim().toUpperCase()) {
    case 'SIMPLE':
      return PresentationPanelPreset.simple;
    case 'EDITORIAL':
      return PresentationPanelPreset.editorial;
    case 'DOCUMENTARY':
      return PresentationPanelPreset.documentary;
    case 'DOSSIER':
      return PresentationPanelPreset.dossier;
    default:
      return null;
  }
}

PresentationPanelPreset presentationPanelPresetFromName(String raw) =>
    _tryPresentationPanelPresetFromName(raw) ?? PresentationPanelPreset.simple;

String presentationPanelPresetName(PresentationPanelPreset preset) {
  switch (preset) {
    case PresentationPanelPreset.simple:
      return 'SIMPLE';
    case PresentationPanelPreset.editorial:
      return 'EDITORIAL';
    case PresentationPanelPreset.documentary:
      return 'DOCUMENTARY';
    case PresentationPanelPreset.dossier:
      return 'DOSSIER';
  }
}

/// Semantic label used when a preset defines an implicit KICKER.
///
/// EDITORIAL deliberately has no implicit kicker: its category line is optional
/// authored content below the hero image. DOCUMENTARY/DOSSIER keep their legacy
/// semantic defaults so existing rich cards remain visually unchanged.
String presentationPanelDefaultKicker(PresentationPanelPreset preset) {
  switch (preset) {
    case PresentationPanelPreset.editorial:
      return '';
    case PresentationPanelPreset.dossier:
      return 'DOSSIER / SUBJECT FILE';
    case PresentationPanelPreset.simple:
    case PresentationPanelPreset.documentary:
      return 'PROFILE / DOCUMENTARY';
  }
}

enum PresentationPanelIssueSeverity {
  warning,
  error,
}

enum PresentationPanelIssueCode {
  missingClosingTag,
  unknownDirective,
  malformedDirective,
  malformedMetadata,
  invalidPreset,
  duplicateDirective,
}

class PresentationPanelIssue {
  final PresentationPanelIssueCode code;
  final PresentationPanelIssueSeverity severity;
  final String message;

  /// Zero-based line inside the body supplied to
  /// [parsePresentationPanelContent].
  final int lineIndex;

  /// The line exactly as the PANEL parser received it, apart from newline
  /// normalization performed only while inspecting structured content.
  final String rawLine;

  const PresentationPanelIssue({
    required this.code,
    required this.severity,
    required this.message,
    required this.lineIndex,
    required this.rawLine,
  });
}

class PresentationPanelMetadata {
  final String label;
  final String value;

  const PresentationPanelMetadata({
    required this.label,
    required this.value,
  });

  @override
  bool operator ==(Object other) =>
      other is PresentationPanelMetadata &&
      other.label == label &&
      other.value == value;

  @override
  int get hashCode => Object.hash(label, value);
}

class PresentationPanelContent {
  final String heading;

  /// Optional label painted over the portrait. Empty means use the semantic
  /// default for the selected preset, preserving the look of older rich cards.
  final String kicker;

  /// Optional per-panel family. Empty means inherit the surrounding project
  /// font, which keeps every legacy CARD visually unchanged.
  final String fontFamily;

  final String subtitle;
  final List<PresentationPanelMetadata> metadata;
  final String body;
  final PresentationPanelPreset preset;

  /// True when a [PANEL] opener was present, even if the block was malformed.
  final bool panelOpened;

  /// True only when a complete [PANEL] block was actually present.
  final bool structured;

  /// Unknown or malformed directive lines carried through the GUI writer.
  /// Their text is never interpreted by this build.
  final List<String> preservedDirectives;

  /// Parser diagnostics for malformed or forward-version PANEL source.
  final List<PresentationPanelIssue> issues;

  const PresentationPanelContent({
    required this.heading,
    required this.kicker,
    required this.fontFamily,
    required this.subtitle,
    required this.metadata,
    required this.body,
    required this.preset,
    required this.panelOpened,
    required this.structured,
    required this.preservedDirectives,
    required this.issues,
  });

  bool get hasErrors => issues.any(
        (PresentationPanelIssue issue) =>
            issue.severity == PresentationPanelIssueSeverity.error,
      );

  bool get hasWarnings => issues.any(
        (PresentationPanelIssue issue) =>
            issue.severity == PresentationPanelIssueSeverity.warning,
      );
}

PresentationPanelContent _plainPanelContent({
  required String heading,
  required String body,
  required bool panelOpened,
  List<PresentationPanelIssue> issues = const <PresentationPanelIssue>[],
}) {
  return PresentationPanelContent(
    heading: heading,
    kicker: '',
    fontFamily: '',
    subtitle: '',
    metadata: const <PresentationPanelMetadata>[],
    body: body,
    preset: PresentationPanelPreset.simple,
    panelOpened: panelOpened,
    structured: false,
    preservedDirectives: const <String>[],
    issues: List<PresentationPanelIssue>.unmodifiable(issues),
  );
}

PresentationPanelContent parsePresentationPanelContent({
  required String heading,
  required String body,
}) {
  // Keep the caller's exact body for every unstructured path. In particular,
  // opening and saving a legacy CRLF card must not silently convert it to LF.
  final String rawBody = body;
  final String normalized = body
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');
  final List<String> lines = normalized.split('\n');

  int open = 0;
  while (open < lines.length && lines[open].trim().isEmpty) {
    open++;
  }
  if (open >= lines.length || lines[open].trim() != '[PANEL]') {
    return _plainPanelContent(
      heading: heading,
      body: rawBody,
      panelOpened: false,
    );
  }

  int close = -1;
  for (int i = open + 1; i < lines.length; i++) {
    if (lines[i].trim() == '[/PANEL]') {
      close = i;
      break;
    }
  }
  if (close < 0) {
    return _plainPanelContent(
      heading: heading,
      body: rawBody,
      panelOpened: true,
      issues: <PresentationPanelIssue>[
        PresentationPanelIssue(
          code: PresentationPanelIssueCode.missingClosingTag,
          severity: PresentationPanelIssueSeverity.error,
          message: 'PANEL is never closed; add [/PANEL].',
          lineIndex: open,
          rawLine: lines[open],
        ),
      ],
    );
  }

  PresentationPanelPreset preset = PresentationPanelPreset.simple;
  String kicker = '';
  String fontFamily = '';
  String subtitle = '';
  bool sawPreset = false;
  bool sawKicker = false;
  bool sawFont = false;
  bool sawSubtitle = false;
  final List<PresentationPanelMetadata> metadata =
      <PresentationPanelMetadata>[];
  final List<String> preserved = <String>[];
  final List<PresentationPanelIssue> issues = <PresentationPanelIssue>[];

  void preserveIssue({
    required PresentationPanelIssueCode code,
    required PresentationPanelIssueSeverity severity,
    required String message,
    required int lineIndex,
    required String rawLine,
  }) {
    preserved.add(rawLine);
    issues.add(
      PresentationPanelIssue(
        code: code,
        severity: severity,
        message: message,
        lineIndex: lineIndex,
        rawLine: rawLine,
      ),
    );
  }

  for (int i = open + 1; i < close; i++) {
    final String rawLine = lines[i];
    final String line = rawLine.trim();
    if (line.isEmpty) continue;

    final int colon = line.indexOf(':');
    if (colon <= 0) {
      preserveIssue(
        code: PresentationPanelIssueCode.malformedDirective,
        severity: PresentationPanelIssueSeverity.error,
        message: 'Malformed PANEL directive; expected KEY: value.',
        lineIndex: i,
        rawLine: rawLine,
      );
      continue;
    }

    final String key = line.substring(0, colon).trim().toUpperCase();
    final String value = line.substring(colon + 1).trim();

    switch (key) {
      case 'PRESET':
        if (sawPreset) {
          preserveIssue(
            code: PresentationPanelIssueCode.duplicateDirective,
            severity: PresentationPanelIssueSeverity.warning,
            message: 'Duplicate PRESET is preserved but ignored.',
            lineIndex: i,
            rawLine: rawLine,
          );
          break;
        }
        final PresentationPanelPreset? parsedPreset =
            _tryPresentationPanelPresetFromName(value);
        if (parsedPreset == null) {
          preserveIssue(
            code: PresentationPanelIssueCode.invalidPreset,
            severity: PresentationPanelIssueSeverity.error,
            message: 'Unknown PANEL preset "$value".',
            lineIndex: i,
            rawLine: rawLine,
          );
          break;
        }
        sawPreset = true;
        preset = parsedPreset;
        break;
      case 'KICKER':
        if (sawKicker) {
          preserveIssue(
            code: PresentationPanelIssueCode.duplicateDirective,
            severity: PresentationPanelIssueSeverity.warning,
            message: 'Duplicate KICKER is preserved but ignored.',
            lineIndex: i,
            rawLine: rawLine,
          );
          break;
        }
        if (value.isEmpty) {
          preserveIssue(
            code: PresentationPanelIssueCode.malformedDirective,
            severity: PresentationPanelIssueSeverity.error,
            message: 'KICKER requires text; omit KICKER to use the preset default.',
            lineIndex: i,
            rawLine: rawLine,
          );
          break;
        }
        sawKicker = true;
        kicker = value;
        break;
      case 'FONT':
        if (sawFont) {
          preserveIssue(
            code: PresentationPanelIssueCode.duplicateDirective,
            severity: PresentationPanelIssueSeverity.warning,
            message: 'Duplicate FONT is preserved but ignored.',
            lineIndex: i,
            rawLine: rawLine,
          );
          break;
        }
        if (value.isEmpty) {
          preserveIssue(
            code: PresentationPanelIssueCode.malformedDirective,
            severity: PresentationPanelIssueSeverity.error,
            message: 'FONT requires a family name; omit FONT to inherit.',
            lineIndex: i,
            rawLine: rawLine,
          );
          break;
        }
        sawFont = true;
        fontFamily = value;
        break;
      case 'SUBTITLE':
        if (sawSubtitle) {
          preserveIssue(
            code: PresentationPanelIssueCode.duplicateDirective,
            severity: PresentationPanelIssueSeverity.warning,
            message: 'Duplicate SUBTITLE is preserved but ignored.',
            lineIndex: i,
            rawLine: rawLine,
          );
          break;
        }
        if (value.isEmpty) {
          preserveIssue(
            code: PresentationPanelIssueCode.malformedDirective,
            severity: PresentationPanelIssueSeverity.error,
            message: 'SUBTITLE requires text; omit SUBTITLE when unused.',
            lineIndex: i,
            rawLine: rawLine,
          );
          break;
        }
        sawSubtitle = true;
        subtitle = value;
        break;
      case 'META':
        // The first pipe is the delimiter. Any later pipes belong to the value,
        // so text such as "RANGE | 1990 | 1995" is deterministic.
        final int pipe = value.indexOf('|');
        if (pipe <= 0 || pipe >= value.length - 1) {
          preserveIssue(
            code: PresentationPanelIssueCode.malformedMetadata,
            severity: PresentationPanelIssueSeverity.error,
            message: 'META requires LABEL | VALUE.',
            lineIndex: i,
            rawLine: rawLine,
          );
          break;
        }
        final String label = value.substring(0, pipe).trim();
        final String metaValue = value.substring(pipe + 1).trim();
        if (label.isEmpty || metaValue.isEmpty) {
          preserveIssue(
            code: PresentationPanelIssueCode.malformedMetadata,
            severity: PresentationPanelIssueSeverity.error,
            message: 'META requires non-empty LABEL | VALUE.',
            lineIndex: i,
            rawLine: rawLine,
          );
          break;
        }
        metadata.add(
          PresentationPanelMetadata(label: label, value: metaValue),
        );
        break;
      default:
        preserveIssue(
          code: PresentationPanelIssueCode.unknownDirective,
          severity: PresentationPanelIssueSeverity.warning,
          message: 'Unknown PANEL key "$key" is preserved but ignored.',
          lineIndex: i,
          rawLine: rawLine,
        );
        break;
    }
  }

  final List<String> bodyLines = <String>[
    ...lines.take(open),
    ...lines.skip(close + 1),
  ];
  while (bodyLines.isNotEmpty && bodyLines.first.trim().isEmpty) {
    bodyLines.removeAt(0);
  }
  while (bodyLines.isNotEmpty && bodyLines.last.trim().isEmpty) {
    bodyLines.removeLast();
  }

  return PresentationPanelContent(
    heading: heading,
    kicker: kicker,
    fontFamily: fontFamily,
    subtitle: subtitle,
    metadata: List<PresentationPanelMetadata>.unmodifiable(metadata),
    body: bodyLines.join('\n'),
    preset: preset,
    panelOpened: true,
    structured: true,
    preservedDirectives: List<String>.unmodifiable(preserved),
    issues: List<PresentationPanelIssue>.unmodifiable(issues),
  );
}

/// Canonical writer used by CARD-family GUI controls.
///
/// Legacy SIMPLE cards with no structured fields are emitted unchanged so an
/// existing project never grows metadata syntax simply because it was opened.
/// Unknown or forward-version directives can be supplied through
/// [preservedDirectives]; they are emitted unchanged and remain ignored by this
/// build instead of disappearing during a GUI edit.
String formatPresentationPanelBody({
  required PresentationPanelPreset preset,
  String kicker = '',
  String fontFamily = '',
  required String subtitle,
  required List<PresentationPanelMetadata> metadata,
  List<String> preservedDirectives = const <String>[],
  required String body,
}) {
  final String cleanKicker = kicker.trim();
  final String cleanFont = fontFamily.trim();
  final String cleanSubtitle = subtitle.trim();
  final List<PresentationPanelMetadata> cleanMetadata = metadata
      .map(
        (PresentationPanelMetadata item) => PresentationPanelMetadata(
          label: item.label.trim(),
          value: item.value.trim(),
        ),
      )
      .where(
        (PresentationPanelMetadata item) =>
            item.label.isNotEmpty && item.value.isNotEmpty,
      )
      .toList(growable: false);

  if (preset == PresentationPanelPreset.simple &&
      cleanKicker.isEmpty &&
      cleanFont.isEmpty &&
      cleanSubtitle.isEmpty &&
      cleanMetadata.isEmpty &&
      preservedDirectives.isEmpty) {
    return body;
  }

  final StringBuffer out = StringBuffer()
    ..writeln('[PANEL]')
    ..writeln('PRESET: ${presentationPanelPresetName(preset)}');
  if (cleanKicker.isNotEmpty) {
    out.writeln('KICKER: $cleanKicker');
  }
  if (cleanFont.isNotEmpty) {
    out.writeln('FONT: $cleanFont');
  }
  if (cleanSubtitle.isNotEmpty) {
    out.writeln('SUBTITLE: $cleanSubtitle');
  }
  for (final PresentationPanelMetadata item in cleanMetadata) {
    out.writeln('META: ${item.label} | ${item.value}');
  }
  for (final String rawLine in preservedDirectives) {
    out.writeln(rawLine);
  }
  out.write('[/PANEL]');
  if (body.isNotEmpty) {
    out
      ..writeln()
      ..write(body);
  }
  return out.toString();
}
