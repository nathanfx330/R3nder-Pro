// ./lib/structural_chrome.dart
//
// Placement-owned chrome metadata for [STRUCT:...] video presentations.
//
// EDIT and MOSAIC remain reusable composition sources. Window title,
// informational overlays, fullscreen state, and clip-audio intent belong to the
// STRUCT placement, so the same source can be presented differently in
// different places.
//
// Canonical examples:
//
//   [STRUCT:MOSAIC.wall]
//   [STRUCT:MOSAIC.wall:FULL]
//   [STRUCT:EDIT.main:AUDIO]
//   [STRUCT:MOSAIC.wall:SPLIT]
//   [STRUCT:MOSAIC.wall:SPLIT:ASPECT=4X3]
//   [STRUCT:MOSAIC.wall:TITLE="Archive Viewer"]
//   [STRUCT:MOSAIC.wall:OVERLAY=NONE:TITLE="Archive Viewer"]
//   [STRUCT:MOSAIC.wall:FULL:AUDIO:OVERLAY=CUSTOM:TITLE="Field Monitor":TOP="FEB 1972 · F[frame]":BOTTOM="16MM TRANSFER · REEL 4"]
//
// FULL, SPLIT, and AUDIO are bare placement tokens. SPLIT may carry keyed
// ASPECT=16X9, ASPECT=4X3, or ASPECT=9X16; 16X9 is the omitted default.
// Text values are quoted. Colons
// inside quoted text are data, not segment separators. Backslash, quote,
// newline, carriage return, and tab use the conventional escaped forms.
// Unknown segments make the tag invalid so an author typo cannot silently
// become a different presentation.
//
// `[frame]` inside TITLE, TOP, or BOTTOM is a render-time expression. It is
// preserved verbatim in script state and expands to the current structural
// source frame only when chrome is painted. That keeps authored copy dynamic
// without moving any project-time ownership into the node UI.

import 'mosaic_split_geometry.dart';

enum StructuralOverlayMode {
  defaultOverlay,
  custom,
  none,
}

extension StructuralOverlayModeName on StructuralOverlayMode {
  String get token => switch (this) {
        StructuralOverlayMode.defaultOverlay => 'DEFAULT',
        StructuralOverlayMode.custom => 'CUSTOM',
        StructuralOverlayMode.none => 'NONE',
      };
}

StructuralOverlayMode? structuralOverlayModeFromToken(String raw) {
  return switch (raw.trim().toUpperCase()) {
    'DEFAULT' => StructuralOverlayMode.defaultOverlay,
    'CUSTOM' => StructuralOverlayMode.custom,
    'NONE' => StructuralOverlayMode.none,
    _ => null,
  };
}

extension MosaicSplitClientAspectToken on MosaicSplitClientAspect {
  String get token => switch (this) {
        MosaicSplitClientAspect.aspect16x9 => '16X9',
        MosaicSplitClientAspect.aspect4x3 => '4X3',
        MosaicSplitClientAspect.aspect9x16 => '9X16',
      };
}

MosaicSplitClientAspect? mosaicSplitClientAspectFromToken(String raw) {
  return switch (raw.trim().toUpperCase()) {
    '16X9' => MosaicSplitClientAspect.aspect16x9,
    '4X3' => MosaicSplitClientAspect.aspect4x3,
    '9X16' => MosaicSplitClientAspect.aspect9x16,
    _ => null,
  };
}

/// Expands render-time expressions in authored STRUCT chrome copy.
///
/// Deliberately tiny for now. `[frame]` means the exact structural source frame
/// the preview/export is already rendering. It is therefore deterministic under
/// scrub, playback, seamless handoff, and BAKE. Unknown bracketed text is left
/// untouched so ordinary archival notation cannot be accidentally consumed.
String expandStructuralChromeExpressions(
  String authored, {
  required int frame,
}) {
  if (authored.isEmpty || !authored.contains('[frame]')) return authored;
  return authored.replaceAll('[frame]', '$frame');
}

class StructuralChromeSpec {
  final String source;
  final bool fullscreen;

  /// Placement-owned request for two equal MOSAIC desktop windows. Unsupported
  /// sources remain authored but fall back to ordinary windowed presentation.
  final bool splitWindows;

  /// Windows-style edge-to-edge split presentation. This remains placement
  /// metadata and is meaningful only when [splitWindows] is authored.
  final bool maximizeSplit;

  /// One authored client aspect shared by both normal split windows. It stays
  /// authored while MAX is enabled so turning MAX off restores the prior
  /// aspect rather than silently resetting presentation intent.
  final MosaicSplitClientAspect splitAspect;

  /// Placement-owned intent to play the audio belonging to clips in [source].
  /// This is deliberately independent of workspace voice/music beds.
  final bool clipAudio;

  final StructuralOverlayMode overlayMode;

  /// Empty means the existing default: the canonical structural source name.
  final String windowTitle;

  /// Dormant values are deliberately preserved when overlayMode is DEFAULT or
  /// NONE. A user can switch away from CUSTOM and back without losing copy.
  final String topOverlay;
  final String bottomOverlay;

  const StructuralChromeSpec({
    required this.source,
    this.fullscreen = false,
    this.splitWindows = false,
    this.maximizeSplit = false,
    this.splitAspect = MosaicSplitClientAspect.aspect16x9,
    this.clipAudio = false,
    this.overlayMode = StructuralOverlayMode.defaultOverlay,
    this.windowTitle = '',
    this.topOverlay = '',
    this.bottomOverlay = '',
  });

  String get effectiveWindowTitle =>
      windowTitle.trim().isEmpty ? source : windowTitle;

  StructuralChromeSpec copyWith({
    String? source,
    bool? fullscreen,
    bool? splitWindows,
    bool? maximizeSplit,
    MosaicSplitClientAspect? splitAspect,
    bool? clipAudio,
    StructuralOverlayMode? overlayMode,
    String? windowTitle,
    String? topOverlay,
    String? bottomOverlay,
  }) {
    return StructuralChromeSpec(
      source: source ?? this.source,
      fullscreen: fullscreen ?? this.fullscreen,
      splitWindows: splitWindows ?? this.splitWindows,
      maximizeSplit: maximizeSplit ?? this.maximizeSplit,
      splitAspect: splitAspect ?? this.splitAspect,
      clipAudio: clipAudio ?? this.clipAudio,
      overlayMode: overlayMode ?? this.overlayMode,
      windowTitle: windowTitle ?? this.windowTitle,
      topOverlay: topOverlay ?? this.topOverlay,
      bottomOverlay: bottomOverlay ?? this.bottomOverlay,
    );
  }
}

final RegExp _structuralSource =
    RegExp(r'^(?:EDIT|MOSAIC)\.[A-Za-z0-9_-]+$');

/// Parses one complete [STRUCT:...] tag. Returns null for malformed or unknown
/// syntax rather than guessing. The caller can then leave that source as raw
/// text for repair.
StructuralChromeSpec? parseStructuralChromeTag(String raw) {
  final String text = raw.trim();
  if (!text.startsWith('[STRUCT:') || !text.endsWith(']')) return null;

  final String body = text.substring('[STRUCT:'.length, text.length - 1);
  final List<String>? segments = _splitSegments(body);
  if (segments == null || segments.isEmpty) return null;

  final String source = segments.first.trim();
  if (!_structuralSource.hasMatch(source)) return null;

  bool fullscreen = false;
  bool splitWindows = false;
  bool maximizeSplit = false;
  MosaicSplitClientAspect splitAspect = MosaicSplitClientAspect.aspect16x9;
  bool clipAudio = false;
  StructuralOverlayMode overlay = StructuralOverlayMode.defaultOverlay;
  String title = '';
  String top = '';
  String bottom = '';

  bool sawAspect = false;
  bool sawOverlay = false;
  bool sawTitle = false;
  bool sawTop = false;
  bool sawBottom = false;

  for (final String rawSegment in segments.skip(1)) {
    final String segment = rawSegment.trim();
    if (segment.isEmpty) return null;

    final String bare = segment.toUpperCase();
    if (bare == 'FULL') {
      if (fullscreen) return null;
      fullscreen = true;
      continue;
    }
    if (bare == 'SPLIT') {
      if (splitWindows) return null;
      splitWindows = true;
      continue;
    }
    if (bare == 'MAX') {
      if (maximizeSplit) return null;
      maximizeSplit = true;
      continue;
    }
    if (bare == 'AUDIO') {
      if (clipAudio) return null;
      clipAudio = true;
      continue;
    }

    final int equals = segment.indexOf('=');
    if (equals <= 0) return null;
    final String key = segment.substring(0, equals).trim().toUpperCase();
    final String value = segment.substring(equals + 1).trim();

    switch (key) {
      case 'ASPECT':
        if (sawAspect) return null;
        final MosaicSplitClientAspect? parsed =
            mosaicSplitClientAspectFromToken(value);
        if (parsed == null) return null;
        splitAspect = parsed;
        sawAspect = true;
        break;
      case 'OVERLAY':
        if (sawOverlay) return null;
        final StructuralOverlayMode? parsed =
            structuralOverlayModeFromToken(value);
        if (parsed == null) return null;
        overlay = parsed;
        sawOverlay = true;
        break;
      case 'TITLE':
        if (sawTitle) return null;
        final String? parsed = _parseQuoted(value);
        if (parsed == null) return null;
        title = parsed;
        sawTitle = true;
        break;
      case 'TOP':
        if (sawTop) return null;
        final String? parsed = _parseQuoted(value);
        if (parsed == null) return null;
        top = parsed;
        sawTop = true;
        break;
      case 'BOTTOM':
        if (sawBottom) return null;
        final String? parsed = _parseQuoted(value);
        if (parsed == null) return null;
        bottom = parsed;
        sawBottom = true;
        break;
      default:
        return null;
    }
  }

  if (fullscreen && splitWindows) return null;
  if (sawAspect && !splitWindows) return null;
  if (maximizeSplit && !splitWindows) return null;

  return StructuralChromeSpec(
    source: source,
    fullscreen: fullscreen,
    splitWindows: splitWindows,
    maximizeSplit: maximizeSplit,
    splitAspect: splitAspect,
    clipAudio: clipAudio,
    overlayMode: overlay,
    windowTitle: title,
    topOverlay: top,
    bottomOverlay: bottom,
  );
}

/// Emits the shortest canonical form while preserving dormant custom copy.
String formatStructuralChromeTag(StructuralChromeSpec spec) {
  if (!_structuralSource.hasMatch(spec.source)) {
    throw ArgumentError.value(
      spec.source,
      'spec.source',
      'STRUCT source must be EDIT.<id> or MOSAIC.<id>.',
    );
  }

  if (spec.fullscreen && spec.splitWindows) {
    throw ArgumentError('STRUCT cannot be both FULL and SPLIT.');
  }
  final StringBuffer out = StringBuffer('[STRUCT:${spec.source}');
  if (spec.fullscreen) out.write(':FULL');
  if (spec.maximizeSplit && !spec.splitWindows) {
    throw ArgumentError('STRUCT MAX is valid only with SPLIT.');
  }
  if (spec.splitWindows) {
    out.write(':SPLIT');
    if (spec.maximizeSplit) out.write(':MAX');
    if (spec.splitAspect != MosaicSplitClientAspect.aspect16x9) {
      out.write(':ASPECT=${spec.splitAspect.token}');
    }
  }
  if (spec.clipAudio) out.write(':AUDIO');
  if (spec.overlayMode != StructuralOverlayMode.defaultOverlay) {
    out.write(':OVERLAY=${spec.overlayMode.token}');
  }
  if (spec.windowTitle.isNotEmpty) {
    out.write(':TITLE=${_quote(spec.windowTitle)}');
  }
  if (spec.topOverlay.isNotEmpty) {
    out.write(':TOP=${_quote(spec.topOverlay)}');
  }
  if (spec.bottomOverlay.isNotEmpty) {
    out.write(':BOTTOM=${_quote(spec.bottomOverlay)}');
  }
  out.write(']');
  return out.toString();
}

List<String>? _splitSegments(String body) {
  final List<String> out = <String>[];
  final StringBuffer current = StringBuffer();
  bool quoted = false;
  bool escaped = false;

  for (int i = 0; i < body.length; i++) {
    final String ch = body[i];

    if (escaped) {
      current.write(ch);
      escaped = false;
      continue;
    }

    if (quoted && ch == r'\') {
      current.write(ch);
      escaped = true;
      continue;
    }

    if (ch == '"') {
      quoted = !quoted;
      current.write(ch);
      continue;
    }

    if (ch == ':' && !quoted) {
      out.add(current.toString());
      current.clear();
      continue;
    }

    current.write(ch);
  }

  if (quoted || escaped) return null;
  out.add(current.toString());
  return out;
}

String? _parseQuoted(String raw) {
  if (raw.length < 2 || !raw.startsWith('"') || !raw.endsWith('"')) {
    return null;
  }

  final String inner = raw.substring(1, raw.length - 1);
  final StringBuffer out = StringBuffer();
  bool escaped = false;

  for (int i = 0; i < inner.length; i++) {
    final String ch = inner[i];
    if (!escaped) {
      if (ch == r'\') {
        escaped = true;
      } else {
        out.write(ch);
      }
      continue;
    }

    switch (ch) {
      case 'n':
        out.write('\n');
        break;
      case 'r':
        out.write('\r');
        break;
      case 't':
        out.write('\t');
        break;
      case '"':
        out.write('"');
        break;
      case r'\':
        out.write(r'\');
        break;
      default:
        // Preserve an unfamiliar escape literally rather than corrupting copy.
        out.write(r'\');
        out.write(ch);
        break;
    }
    escaped = false;
  }

  return escaped ? null : out.toString();
}

String _quote(String value) {
  final String escaped = value
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r')
      .replaceAll('\t', r'\t');
  return '"$escaped"';
}
