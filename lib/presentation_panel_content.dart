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
//   FONT: IBM Plex Sans
//   SUBTITLE: Investigative Reporter
//   META: ORGANIZATION | Example News
//   META: LOCATION | Washington, DC
//   [/PANEL]
//   Biography copy continues here.
//
// The block owns no time and no coordinates. Unknown keys are ignored so a
// newer writer can remain readable by an older renderer. A missing closing tag
// makes the whole body legacy text instead of silently eating authored copy.

enum PresentationPanelPreset {
  simple,
  documentary,
  dossier,
}

PresentationPanelPreset presentationPanelPresetFromName(String raw) {
  switch (raw.trim().toUpperCase()) {
    case 'DOCUMENTARY':
      return PresentationPanelPreset.documentary;
    case 'DOSSIER':
      return PresentationPanelPreset.dossier;
    default:
      return PresentationPanelPreset.simple;
  }
}

String presentationPanelPresetName(PresentationPanelPreset preset) {
  switch (preset) {
    case PresentationPanelPreset.simple:
      return 'SIMPLE';
    case PresentationPanelPreset.documentary:
      return 'DOCUMENTARY';
    case PresentationPanelPreset.dossier:
      return 'DOSSIER';
  }
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

  /// Optional per-panel family. Empty means inherit the surrounding project
  /// font, which keeps every legacy CARD visually unchanged.
  final String fontFamily;

  final String subtitle;
  final List<PresentationPanelMetadata> metadata;
  final String body;
  final PresentationPanelPreset preset;

  /// True only when a complete [PANEL] block was actually present.
  final bool structured;

  const PresentationPanelContent({
    required this.heading,
    required this.fontFamily,
    required this.subtitle,
    required this.metadata,
    required this.body,
    required this.preset,
    required this.structured,
  });
}

PresentationPanelContent parsePresentationPanelContent({
  required String heading,
  required String body,
}) {
  final String normalized = body
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');
  final List<String> lines = normalized.split('\n');

  int open = 0;
  while (open < lines.length && lines[open].trim().isEmpty) {
    open++;
  }
  if (open >= lines.length || lines[open].trim() != '[PANEL]') {
    return PresentationPanelContent(
      heading: heading,
      fontFamily: '',
      subtitle: '',
      metadata: const <PresentationPanelMetadata>[],
      body: normalized,
      preset: PresentationPanelPreset.simple,
      structured: false,
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
    return PresentationPanelContent(
      heading: heading,
      fontFamily: '',
      subtitle: '',
      metadata: const <PresentationPanelMetadata>[],
      body: normalized,
      preset: PresentationPanelPreset.simple,
      structured: false,
    );
  }

  PresentationPanelPreset preset = PresentationPanelPreset.simple;
  String fontFamily = '';
  String subtitle = '';
  final List<PresentationPanelMetadata> metadata =
      <PresentationPanelMetadata>[];

  for (int i = open + 1; i < close; i++) {
    final String line = lines[i].trim();
    if (line.isEmpty) continue;

    final int colon = line.indexOf(':');
    if (colon <= 0) continue;
    final String key = line.substring(0, colon).trim().toUpperCase();
    final String value = line.substring(colon + 1).trim();

    switch (key) {
      case 'PRESET':
        preset = presentationPanelPresetFromName(value);
        break;
      case 'FONT':
        fontFamily = value;
        break;
      case 'SUBTITLE':
        subtitle = value;
        break;
      case 'META':
        final int pipe = value.indexOf('|');
        if (pipe <= 0) break;
        final String label = value.substring(0, pipe).trim();
        final String metaValue = value.substring(pipe + 1).trim();
        if (label.isEmpty || metaValue.isEmpty) break;
        metadata.add(
          PresentationPanelMetadata(label: label, value: metaValue),
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
    fontFamily: fontFamily,
    subtitle: subtitle,
    metadata: List<PresentationPanelMetadata>.unmodifiable(metadata),
    body: bodyLines.join('\n'),
    preset: preset,
    structured: true,
  );
}

/// Canonical writer used by CARD-family GUI controls.
///
/// Legacy SIMPLE cards with no structured fields are emitted unchanged so an
/// existing project never grows metadata syntax simply because it was opened.
String formatPresentationPanelBody({
  required PresentationPanelPreset preset,
  String fontFamily = '',
  required String subtitle,
  required List<PresentationPanelMetadata> metadata,
  required String body,
}) {
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
      cleanFont.isEmpty &&
      cleanSubtitle.isEmpty &&
      cleanMetadata.isEmpty) {
    return body;
  }

  final StringBuffer out = StringBuffer()
    ..writeln('[PANEL]')
    ..writeln('PRESET: ${presentationPanelPresetName(preset)}');
  if (cleanFont.isNotEmpty) {
    out.writeln('FONT: $cleanFont');
  }
  if (cleanSubtitle.isNotEmpty) {
    out.writeln('SUBTITLE: $cleanSubtitle');
  }
  for (final PresentationPanelMetadata item in cleanMetadata) {
    out.writeln('META: ${item.label} | ${item.value}');
  }
  out.write('[/PANEL]');
  if (body.isNotEmpty) {
    out
      ..writeln()
      ..write(body);
  }
  return out.toString();
}
