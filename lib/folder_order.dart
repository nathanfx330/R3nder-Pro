// ./lib/folder_order.dart

import 'dart:io';

// =====================================================================
// FOLDER ORDER
//
// Folder-backed tags (GALLERY, VIDEO, APP, DOSSIER, TIMELINE stage) load
// their images through one loader that sorted by filename and offered no
// way to say otherwise. Filename order is deterministic, which is why it
// was chosen, but it is not authored: drop a new scan into a MOSAIC APP
// folder and it lands wherever its name falls, silently reshuffling a
// composition that was already right.
//
// This is a per-folder manifest that says what the order actually is.
//
// WHY A DOTFILE. Every scanner in R3nder already skips names beginning
// with a dot: the asset manager's reference walk and orphan report, the
// node panel's pickers, and the contact-sheet lister. So the manifest is
// invisible to all of them with no special case added anywhere, and it
// travels inside the folder it describes, which means moving or copying
// a workspace carries the order with it.
//
// WHY NOT RENAME. Numeric prefixes (010_, 020_) would need no code at
// all and would be visible in any file manager. They also destroy the
// filenames, and in archival material a filename carries provenance:
// dates, box numbers, subject names. Rewriting those to encode a
// composition decision trades something irreplaceable for something
// cosmetic.
//
// DETERMINISM IS UNAFFECTED. This is one more file read during setup.
// The same folder yields the same sequence on every run, which is all
// the render path requires.
// =====================================================================

/// Manifest filename, inside the folder it orders.
const String kFolderOrderFile = '.r3nder_order';

/// Reads the raw manifest: filenames in authored order, exactly as written.
///
/// May name files that are no longer present. Callers should go through
/// [orderedFolderNames] rather than using this directly, unless they are
/// specifically inspecting the manifest itself.
List<String> readFolderOrder(String dirPath) {
  try {
    final File f = File('$dirPath${Platform.pathSeparator}$kFolderOrderFile');
    if (!f.existsSync()) return const [];
    return f
        .readAsLinesSync()
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('#'))
        .toList();
  } catch (_) {
    // An unreadable manifest is the same as no manifest. It must never be
    // able to fail a bake: the folder still has images and filename order
    // is a defensible answer.
    return const [];
  }
}

/// Applies the manifest to what is actually on disk.
///
/// [onDisk] is the filenames the caller found, in any order. The result is
/// every one of them exactly once, ordered.
///
/// THREE DRIFT RULES, and the second one is the point:
///
///  * Listed and present: in manifest order.
///  * Present but NOT listed: appended after everything listed, in name
///    order. A newly added image therefore lands at the END rather than
///    inserting itself wherever its name happens to sort. That is the
///    behaviour that stops a finished composition from reshuffling when
///    you drop in another scan, and it holds even for a folder nobody has
///    ever reordered by hand.
///  * Listed but absent: skipped. Recycling an image cannot corrupt the
///    order of the ones that remain, and the stale entry is harmless until
///    the next write cleans it out.
///
/// With no manifest this degrades to plain name order, which is exactly
/// what the loader did before.
List<String> orderedFolderNames(String dirPath, Iterable<String> onDisk) {
  final List<String> present = onDisk.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

  final List<String> manifest = readFolderOrder(dirPath);
  if (manifest.isEmpty) return present;

  final Set<String> remaining = present.toSet();
  final List<String> out = [];

  for (final name in manifest) {
    if (remaining.remove(name)) out.add(name);
  }

  // Whatever the manifest did not account for, in name order.
  for (final name in present) {
    if (remaining.contains(name)) out.add(name);
  }

  return out;
}

/// True when this folder has an authored order, as opposed to falling back
/// to filename order. The editor uses it to say which of the two you are
/// looking at.
bool folderHasOrder(String dirPath) {
  try {
    return File('$dirPath${Platform.pathSeparator}$kFolderOrderFile')
        .existsSync();
  } catch (_) {
    return false;
  }
}

/// Writes the manifest. Returns false if it could not be written, which the
/// caller should surface: silently failing to save an order the user just
/// arranged is worse than saying so.
///
/// Writes the full list including a header comment, so the file explains
/// itself to anyone who opens it outside R3nder.
bool writeFolderOrder(String dirPath, List<String> names) {
  try {
    final File f = File('$dirPath${Platform.pathSeparator}$kFolderOrderFile');
    final StringBuffer b = StringBuffer()
      ..writeln('# R3nder folder order. One filename per line.')
      ..writeln('# Files not listed here load after these, in name order.')
      ..writeln('# Lines starting with # are ignored. Safe to edit by hand.');
    for (final n in names) {
      b.writeln(n);
    }
    f.writeAsStringSync(b.toString());
    return true;
  } catch (_) {
    return false;
  }
}

/// Removes the manifest, returning the folder to filename order.
bool clearFolderOrder(String dirPath) {
  try {
    final File f = File('$dirPath${Platform.pathSeparator}$kFolderOrderFile');
    if (f.existsSync()) f.deleteSync();
    return true;
  } catch (_) {
    return false;
  }
}