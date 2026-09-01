// ./lib/config_keys.dart

// =====================================================================
// WHY THIS EXISTS
//
// [CONFIG:KEY:value] is parsed generically. The regex has one CONFIG
// alternation, the node round-trip has one CONFIG case, and the linter
// treats CONFIG as a single known tag. That genericity is real and it is
// why PANELIFE cost no grammar change at all.
//
// It is also why the two places that DO enumerate keys by hand were easy
// to miss. The node workspace listed five in a dropdown and five in a
// defaults map; the tag palette listed five snippets. Adding PANELIFE
// meant editing both, and forgetting either fails silently: a key absent
// from the dropdown falls through to a text field labelled for a
// different setting, and one absent from the palette simply cannot be
// discovered.
//
// So the keys live here once. The dropdown, the defaults, and the palette
// all read from this list, which means a new key is one entry rather than
// three edits in two files with no compiler help.
//
// This is the same scattered-knowledge shape as the tag surface generally
// (knownTags, the palette, the node parse, the node emit, the asset scan,
// the preload scan). This fixes the CONFIG corner of it, not the whole
// problem.
// =====================================================================

/// How a CONFIG value should be edited.
///
/// Kept coarse on purpose. The node workspace maps these onto its own
/// field builders, so this enum names the KIND of value rather than the
/// widget, and the two can move independently.
enum ConfigValueKind {
  /// Whole number with a range, e.g. base font size.
  integer,

  /// `R,G,B` triple.
  rgb,

  /// Path to an image inside the workspace.
  rasterAsset,

  /// Free text.
  text,

  /// Compound value with its own composite form, e.g. `ON:102:INOUT`.
  compound,
}

/// One authorable `[CONFIG:...]` key.
class ConfigKeySpec {
  /// Key as it appears in the script, uppercase.
  final String key;

  /// Value written when the key is first chosen, and the value the node
  /// form treats as "unset" when deciding whether to emit a short form.
  final String defaultValue;

  final ConfigValueKind kind;

  /// One-line description for the tag palette.
  final String blurb;

  /// Snippet inserted by the palette. Held here rather than assembled
  /// from key and default because some keys read better with a realistic
  /// example than with their literal default.
  final String sampleValue;

  const ConfigKeySpec({
    required this.key,
    required this.defaultValue,
    required this.kind,
    required this.blurb,
    required this.sampleValue,
  });

  String get sampleTag => '[CONFIG:$key:$sampleValue]';
}

/// Every CONFIG key R3nder understands, in the order the dropdown shows
/// them: the three that change how text looks, then the two that change
/// what mode the engine runs in, then motion, then caption typography.
const List<ConfigKeySpec> kConfigKeys = [
  ConfigKeySpec(
    key: 'SIZE',
    defaultValue: '48',
    kind: ConfigValueKind.integer,
    blurb: 'Global font size',
    sampleValue: '42',
  ),
  ConfigKeySpec(
    key: 'FG',
    defaultValue: '0,255,0',
    kind: ConfigValueKind.rgb,
    blurb: 'Global text color',
    sampleValue: '0,255,0',
  ),
  ConfigKeySpec(
    key: 'BG',
    defaultValue: '10,15,10',
    kind: ConfigValueKind.rgb,
    blurb: 'Global background color',
    sampleValue: '10,15,10',
  ),
  ConfigKeySpec(
    key: 'DESKTOP',
    defaultValue: '',
    kind: ConfigValueKind.rasterAsset,
    blurb: 'Desktop wallpaper image',
    sampleValue: 'ubuntu_bg.jpg',
  ),
  ConfigKeySpec(
    key: 'WINTITLE',
    defaultValue: 'operator@field-terminal: ~',
    kind: ConfigValueKind.text,
    blurb: 'Terminal window title',
    sampleValue: 'operator@field-terminal: ~',
  ),
  ConfigKeySpec(
    key: 'PANELIFE',
    defaultValue: 'ON',
    kind: ConfigValueKind.compound,
    blurb: 'Selective slow push on MOSAIC panes',
    sampleValue: 'ON',
  ),
  ConfigKeySpec(
    key: 'APPSWITCH',
    defaultValue: 'DESKTOP',
    kind: ConfigValueKind.compound,
    blurb: 'Transition between adjacent APP tags',
    sampleValue: 'SLIDE',
  ),
  ConfigKeySpec(
    key: 'CAPTION',
    defaultValue: 'LEFT',
    kind: ConfigValueKind.compound,
    blurb: 'Typography for MOSAIC caption bands',
    sampleValue: 'CENTER:22',
  ),
];

/// Keys in dropdown order.
List<String> get kConfigKeyNames =>
    kConfigKeys.map((c) => c.key).toList(growable: false);

/// Default value for [key], or empty when the key is unknown.
///
/// Unknown is not an error. A script can carry a CONFIG key this build
/// does not implement, and the node form still has to render it rather
/// than discard it: parsing a document is not permission to rewrite it.
String configDefaultFor(String key) {
  for (final c in kConfigKeys) {
    if (c.key == key.toUpperCase()) return c.defaultValue;
  }
  return '';
}

ConfigKeySpec? configSpecFor(String key) {
  for (final c in kConfigKeys) {
    if (c.key == key.toUpperCase()) return c;
  }
  return null;
}