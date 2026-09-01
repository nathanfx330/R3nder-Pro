// ./lib/folder_captions.dart

import 'dart:io';

// =====================================================================
// FOLDER CAPTIONS
//
// A per-folder sidecar saying what the pictures ARE. Sibling to
// .r3nder_order, which says what sequence they are in.
//
// WHY NOT IN THE SCRIPT. Every other authored MOSAIC fact lives in the
// APP tag, and captions deliberately do not. The tag splits on ':' and
// ends on ']', and caption prose contains both: "Chicago, 1919: the
// strike committee" cannot survive the segment split, and no escaping
// scheme invented to rescue it produces a language anyone would want to
// type. That is the practical reason. The real one is that a caption is
// a fact about the PHOTOGRAPH, not about the shot: the same scan used in
// two scripts, or in two cuts of the same film, carries the same date and
// the same subject. Composition belongs to the script. Provenance belongs
// to the asset.
//
// This is a stated amendment to the round-trip rule, not an oversight.
// The rule is that a creative choice must be representable in the script
// and reconstructible from it. Folder order was already the exception,
// for exactly this reason, which makes this a category rather than a
// one-off: the script owns composition, the folder owns provenance.
//
// WHY A SEPARATE FILE FROM THE ORDER MANIFEST. They have different
// shapes and different failure modes. Order is positional and is
// rewritten whole every time a thumbnail is dragged; captions are keyed
// by filename and are edited one at a time. Merging them means every
// keystroke in a caption field rewrites the composition manifest, and one
// bad write loses both. Their degradation rules differ too: a missing
// order file means fall back to name order, which is a SUBSTITUTE, while
// a missing caption entry means draw no band, which is an ABSENCE.
//
// WHY A RECORD AND NOT A STRING. Archival material carries a credit
// line (collection, box, accession) that is not the caption and is
// typeset differently everywhere it is printed: smaller, dimmer, under
// the label. Building that in now costs one column. Retrofitting it onto
// a bare string later means either parsing a delimiter out of captions
// already written by hand, or a second sidecar that has to stay in step
// with the first.
//
// ENABLED IS NOT "TEXT IS NON-EMPTY". A caption you have switched off
// keeps its words. That is the entire point of a checkbox rather than an
// empty field: dropping a caption for one cut must not destroy the
// research that produced it.
//
// THE FILENAME COLUMN IS VERBATIM. This is the first thing this file got
// wrong, and it is worth stating as a rule rather than a fix. Filenames
// are keys, not prose, and archival material arrives with names nobody
// chose: " 1920 in Galicia.jpg" has a leading space, and scans exported
// from other tools carry trailing ones. Trimming the name column stores a
// key that no lookup can ever match, and the failure is invisible: the
// write succeeds, the file is on disk with the caption plainly in it, and
// nothing renders. So the name is cleaned of tabs and newlines only,
// never trimmed, on both write and read. Caption and credit ARE trimmed,
// because there leading whitespace is noise rather than identity.
//
// DETERMINISM IS UNAFFECTED. One more file read during setup, and the
// same folder yields the same captions every run.
// =====================================================================

/// Sidecar filename, inside the folder it describes.
///
/// Dot-prefixed for the same reason as the order manifest: every scanner
/// in R3nder already skips dot-names, so it is invisible to the asset
/// manager's reference walk, the orphan report, the node pickers, and the
/// contact-sheet lister with no special case added anywhere.
const String kFolderCaptionFile = '.r3nder_captions';

// ---------------------------------------------------------------------
// How captions are SET, as opposed to what they SAY
//
// The sidecar above is provenance and lives with the assets. Everything
// below is typography and lives in the script, because it is a decision
// about this piece: the same photograph captioned in two films can be set
// centred in one and ranged left in the other.
//
// Both live in this file for the reason PaneLifeConfig lives in
// motion.dart: the subject is one subject, and splitting it across files
// buys nothing but imports.
// ---------------------------------------------------------------------

/// Where the label sits under the photograph.
///
/// Not a per-image choice. Alignment is the look of the piece, and a
/// contact sheet where some labels are centred and others ranged left
/// reads as a mistake rather than as emphasis.
enum CaptionAlign { left, center, right }

CaptionAlign? captionAlignFromName(String raw) {
  switch (raw.trim().toUpperCase()) {
    case 'LEFT':
      return CaptionAlign.left;
    case 'CENTER':
    case 'CENTRE':
      return CaptionAlign.center;
    case 'RIGHT':
      return CaptionAlign.right;
  }
  return null;
}

/// Default caption size, in the scaled pixels the window chrome uses.
///
/// Started at 16, reasoning that a caption should sit just above the 14px
/// window title. That was measured against a monitor at arm's length and
/// it is too small the moment the delivery is anything else. 22 is the
/// size a label has to be to be read rather than noticed.
const double kCaptionDefaultSizePx = 22.0;

/// Bounds. The floor is where type stops being readable at all; the
/// ceiling is where a label starts competing with the photograph.
const double kCaptionMinSizePx = 10.0;
const double kCaptionMaxSizePx = 48.0;

/// Typography for every caption band in a script.
///
/// Parsed from `[CONFIG:CAPTION:...]`. Absent means the defaults, which
/// are exactly what the first captions shipped with, so adding this key to
/// a script changes nothing until you set something in it.
class CaptionConfig {
  final CaptionAlign align;
  final double sizePx;

  /// Font family, or null for the script's global font.
  ///
  /// A family name, not a path. Every `.ttf` and `.otf` in the workspace
  /// fonts folder is registered at startup under its filename minus the
  /// extension, so naming one here needs no loading of any kind. A name
  /// that did not load falls back to the global font rather than failing:
  /// a font missing from one workspace must not take down a render that
  /// works in another.
  final String? fontFamily;

  const CaptionConfig({
    this.align = CaptionAlign.left,
    this.sizePx = kCaptionDefaultSizePx,
    this.fontFamily,
  });

  static const CaptionConfig defaults = CaptionConfig();

  /// Parses `[CONFIG:CAPTION:...]`.
  ///
  /// Accepted: `CENTER`, `CENTER:22`, `CENTER:22:Inter-Regular`. Each
  /// segment is optional and anything unrecognised falls back to its
  /// default rather than failing, because a config typo should cost you a
  /// look, not a render.
  ///
  /// The font is the LAST segment on purpose. Family names come from
  /// filenames, and a filename is the one value here that could contain a
  /// colon; taking everything after the second one keeps such a name
  /// intact instead of truncating it at the colon.
  static CaptionConfig parse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return defaults;
    final List<String> parts = raw.split(':');

    final CaptionAlign align =
        captionAlignFromName(parts[0]) ?? CaptionAlign.left;

    double size = kCaptionDefaultSizePx;
    if (parts.length > 1) {
      final double? v = double.tryParse(parts[1].trim());
      if (v != null) {
        size = v.clamp(kCaptionMinSizePx, kCaptionMaxSizePx).toDouble();
      }
    }

    String? family;
    if (parts.length > 2) {
      final String rest = parts.sublist(2).join(':').trim();
      if (rest.isNotEmpty) family = rest;
    }

    return CaptionConfig(align: align, sizePx: size, fontFamily: family);
  }

  /// Canonical tag value. Emits only as much as it needs to: a script that
  /// sets alignment alone does not grow a size and a font it never chose.
  String toConfigValue() {
    final String a = align == CaptionAlign.center
        ? 'CENTER'
        : (align == CaptionAlign.right ? 'RIGHT' : 'LEFT');
    final bool sizeIsDefault = (sizePx - kCaptionDefaultSizePx).abs() < 0.001;
    final String? f = (fontFamily != null && fontFamily!.trim().isNotEmpty)
        ? fontFamily!.trim()
        : null;
    if (f != null) {
      return '$a:${_num(sizePx)}:$f';
    }
    if (!sizeIsDefault) return '$a:${_num(sizePx)}';
    return a;
  }

  static String _num(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toString();

  CaptionConfig copyWith({
    CaptionAlign? align,
    double? sizePx,
    String? fontFamily,
    bool clearFont = false,
  }) {
    return CaptionConfig(
      align: align ?? this.align,
      sizePx: sizePx ?? this.sizePx,
      fontFamily: clearFont ? null : (fontFamily ?? this.fontFamily),
    );
  }
}

/// What one image is.
///
/// [enabled] is authored independently of the text. False with a caption
/// present is a real, expected state: written, switched off, kept.
class ImageCaption {
  final bool enabled;
  final String caption;
  final String credit;

  /// Where this image came from, when it came from somewhere addressable:
  /// the URL a [BROWSER] screenshot was captured at.
  ///
  /// NOT governed by [enabled]. That flag decides whether a MOSAIC band
  /// draws, and a browser's address bar is chrome rather than a label:
  /// suppressing the caption on a photograph is a composition choice,
  /// while a browser window with an empty address bar is just a broken
  /// browser. The two are unrelated questions about the same file.
  final String url;

  /// The page's own title, shown on the browser tab. Falls back to the
  /// URL's host when absent, which is what a browser does anyway.
  final String pageTitle;

  const ImageCaption({
    this.enabled = false,
    this.caption = '',
    this.credit = '',
    this.url = '',
    this.pageTitle = '',
  });

  static const ImageCaption none = ImageCaption();

  /// Whether this should actually draw. Enabled with nothing to say is
  /// not an error, it just produces no band.
  bool get hasBand => enabled && caption.trim().isNotEmpty;

  bool get hasCredit => credit.trim().isNotEmpty;

  /// Whether this record says where the image came from.
  bool get hasSource =>
      url.trim().isNotEmpty || pageTitle.trim().isNotEmpty;

  /// True when this record is worth writing at all. An untouched image
  /// stays out of the sidecar entirely rather than filling it with empty
  /// rows for every file in the folder.
  bool get isEmpty =>
      !enabled &&
      caption.isEmpty &&
      credit.isEmpty &&
      url.isEmpty &&
      pageTitle.isEmpty;

  ImageCaption copyWith({
    bool? enabled,
    String? caption,
    String? credit,
    String? url,
    String? pageTitle,
  }) {
    return ImageCaption(
      enabled: enabled ?? this.enabled,
      caption: caption ?? this.caption,
      credit: credit ?? this.credit,
      url: url ?? this.url,
      pageTitle: pageTitle ?? this.pageTitle,
    );
  }

  /// What the address bar shows. Never empty for a record that has a URL,
  /// and never a lie: an unauthored screenshot gets a blank bar rather
  /// than an invented address.
  String get displayUrl => url.trim();

  /// What the tab shows: the page's own title, or failing that the host
  /// out of the URL, or failing that nothing.
  ///
  /// Host extraction is deliberately string surgery rather than Uri.parse.
  /// The value is authored by hand in a text file and may well be a
  /// fragment, a scheme-less host, or an archive path someone typed from
  /// a printout. Uri.parse throws on some of those and silently returns
  /// an empty host on others, and neither is worth a blank tab.
  String get displayTabTitle {
    final String t = pageTitle.trim();
    if (t.isNotEmpty) return t;
    String u = url.trim();
    if (u.isEmpty) return '';
    final int scheme = u.indexOf('://');
    if (scheme >= 0) u = u.substring(scheme + 3);
    final int slash = u.indexOf('/');
    if (slash > 0) u = u.substring(0, slash);
    return u;
  }
}

/// Strips what the line format cannot carry, and nothing else.
///
/// Tabs separate columns and newlines separate records, so neither can
/// appear inside a field. Collapsed to a space rather than removed, so
/// pasting a caption out of a spreadsheet or a PDF does not silently weld
/// two words together.
///
/// Deliberately does NOT trim. Callers trim prose themselves; the
/// filename column must never be trimmed at all.
String _strip(String raw) =>
    raw.replaceAll('\t', ' ').replaceAll(RegExp(r'[\r\n]+'), ' ');

/// Whether a filename can be represented in this format at all.
///
/// A tab or a newline in a name would forge a column boundary or a record
/// boundary and silently corrupt every line after it. Both are legal in
/// POSIX filenames, so this is checked rather than assumed. Reported to
/// the caller as a failed write instead of being skipped quietly: a
/// caption that looked saved and was not is exactly the failure this
/// format exists to avoid.
bool captionableName(String name) =>
    name.isNotEmpty && !name.contains('\t') && !name.contains('\n') &&
    !name.contains('\r');

/// Reads the sidecar, keyed by filename EXACTLY as it appears on disk.
///
/// Unreadable is the same as absent, exactly as with the order manifest:
/// a corrupt sidecar must never take down a render. Malformed lines are
/// skipped individually rather than failing the file, so one bad hand
/// edit costs one caption and not all of them.
///
/// Columns are `filename`, `ON|OFF`, `caption`, `credit`, `url`,
/// `page title`. Trailing columns are optional and unknown extra columns
/// are ignored, so a file written today still reads when a seventh field
/// exists — which is exactly how `url` and `page title` arrived. A
/// four-column sidecar written before [BROWSER] existed reads unchanged.
Map<String, ImageCaption> readFolderCaptions(String dirPath) {
  final Map<String, ImageCaption> out = {};
  try {
    final file = File('$dirPath${Platform.pathSeparator}$kFolderCaptionFile');
    if (!file.existsSync()) return out;

    for (final String raw in file.readAsLinesSync()) {
      if (raw.trim().isEmpty) continue;

      final List<String> cols = raw.split('\t');

      // A comment is a line that starts with '#' AND carries no tab.
      // Records always have tabs, so this cannot swallow one, and a file
      // legitimately named "#3 negative.jpg" still gets a caption. The
      // test is on the raw line, not a trimmed copy, so a name beginning
      // with a space is not first shifted into looking like a comment.
      if (cols.length == 1 && raw.startsWith('#')) continue;

      // NOT trimmed. The name is the key, and on disk it may legally
      // begin or end with a space.
      final String name = cols[0];
      if (name.trim().isEmpty) continue;

      final String flag =
          cols.length > 1 ? cols[1].trim().toUpperCase() : 'OFF';
      out[name] = ImageCaption(
        enabled: flag == 'ON' || flag == 'TRUE' || flag == '1',
        caption: cols.length > 2 ? cols[2].trim() : '',
        credit: cols.length > 3 ? cols[3].trim() : '',
        url: cols.length > 4 ? cols[4].trim() : '',
        pageTitle: cols.length > 5 ? cols[5].trim() : '',
      );
    }
  } catch (_) {
    // Same policy as the order manifest. Absent beats broken.
    return {};
  }
  return out;
}

/// Writes the sidecar. Returns false if it could not be written, which the
/// caller should surface rather than swallow: a caption that looked saved
/// and was not is worse than one that visibly failed.
///
/// Empty records are dropped and an empty map removes the file, so a
/// folder whose captions have all been cleared goes back to having no
/// sidecar at all instead of keeping a husk.
bool writeFolderCaptions(String dirPath, Map<String, ImageCaption> entries) {
  try {
    final file = File('$dirPath${Platform.pathSeparator}$kFolderCaptionFile');

    final List<String> keys = entries.keys
        .where((k) => k.trim().isNotEmpty && !(entries[k]!.isEmpty))
        .toList()
      ..sort();

    // Refuse the whole write rather than dropping the offending row. A
    // partial success here would look identical to a full one.
    for (final String k in keys) {
      if (!captionableName(k)) return false;
    }

    if (keys.isEmpty) {
      if (file.existsSync()) file.deleteSync();
      return true;
    }

    final StringBuffer sb = StringBuffer();
    sb.writeln('# R3nder image records. One line per image, tab separated:');
    sb.writeln('# filename<TAB>ON|OFF<TAB>caption<TAB>credit'
        '<TAB>url<TAB>page title');
    sb.writeln('# url and page title are used by [BROWSER] windows.');
    sb.writeln('# Filenames are verbatim, including any leading spaces.');
    for (final String name in keys) {
      final ImageCaption c = entries[name]!;
      // Trailing empties are dropped rather than written as bare tabs. A
      // folder nobody has pointed a BROWSER at keeps the four-column file
      // it has always had, so growing the format costs existing sidecars
      // no churn in a diff.
      final List<String> cols = [
        _strip(name),
        c.enabled ? 'ON' : 'OFF',
        _strip(c.caption).trim(),
        _strip(c.credit).trim(),
        _strip(c.url).trim(),
        _strip(c.pageTitle).trim(),
      ];
      while (cols.length > 4 && cols.last.isEmpty) {
        cols.removeLast();
      }
      sb.writeln(cols.join('\t'));
    }
    file.writeAsStringSync(sb.toString());
    return true;
  } catch (_) {
    return false;
  }
}

/// Whether this folder has any caption authored at all.
///
/// Used by the contact sheet to decide whether to show caption furniture,
/// so a folder nobody has annotated stays visually clean.
bool folderHasCaptions(String dirPath) {
  final Map<String, ImageCaption> all = readFolderCaptions(dirPath);
  return all.values.any((c) => !c.isEmpty);
}

/// Resolves captions positionally against an ordered name list.
///
/// MUST be built alongside the decode loop rather than looked up later by
/// index. A folder whose third file fails to decode produces an image list
/// shorter than its name list, and every caption after the failure would
/// land on the wrong photograph. Callers pass exactly the names whose
/// images survived.
List<ImageCaption> captionsForNames(
    String dirPath, Iterable<String> orderedNames) {
  final Map<String, ImageCaption> all = readFolderCaptions(dirPath);
  return [
    for (final String n in orderedNames) all[n] ?? ImageCaption.none,
  ];
}