// ./lib/desktop_open.dart

import 'dart:io';

import 'diag.dart';

// =====================================================================
// WHY THIS EXISTS
//
// Node mode names assets rather than linking them: a field holds
// `evidence`, and the folder it means is `<workspace>/images/evidence/`.
// That indirection is the right one and it is why a workspace moves
// without breaking, but it also means the author is looking at a name
// while the thing they want to rename, cull, or re-scan is a directory
// they now have to go find by hand.
//
// So this hands a path to the desktop. It is a HANDOFF, not a launcher:
// R3nder does not manage, wait on, or own the process it starts, and the
// file manager that answers is whichever one the session registered.
//
// It lives in its own file because the node panel is not the only place
// that will want it. The workspace menu, the asset manager, and the bake
// output folder are all the same question asked from different screens,
// and two implementations of "open this path" is the shape that produces
// one screen selecting the file and another only opening its parent,
// with nothing to say which was intended.
//
// Nothing here imports Flutter. Callers get a message string back and
// decide how to show it.
// =====================================================================

// =====================================================================
// WHY DETACHED, AND WHY ONLY SOMETIMES
//
// `xdg-open` does not hand off and return. It resolves the handler and
// execs it, so when the file manager is NOT already running it does not
// exit until the file manager does. Awaiting it would leave the control
// disabled for the length of the author's file-browsing session, and
// then any timeout worth having would report a failure on a launch that
// worked perfectly. Detached is not an optimisation here, it is the only
// reading of the exit code that is not a lie.
//
// The cost is real and is accepted: a detached start reports only that
// the binary was found and spawned. A handler that launches and then
// fails is invisible from here. That is the correct trade for a folder,
// because the desktop is a better place to notice a missing file manager
// than a status line inside a motion graphics tool.
//
// The D-Bus reveal is the exception and is awaited, because it is a
// method call with an answer rather than a program to run: no owner on
// the bus is a real, immediate, catchable failure, and it is the only
// signal that tells us to fall back to opening the parent directory
// instead.
// =====================================================================

/// True when a path handoff is meaningful on this platform.
///
/// R3nder targets Linux, and the two mechanisms below are freedesktop
/// ones. Rather than pretend otherwise on a machine that has neither,
/// callers can disable the control instead of offering an action that
/// always fails.
bool get canRevealPaths => Platform.isLinux;

/// Opens [absolutePath] in the session's file manager.
///
/// A directory opens directly. A file opens its containing directory
/// with the file SELECTED, which is a different and better answer: the
/// author clicked a specific asset, and a folder of ninety scans with
/// nothing highlighted has not answered the question they asked.
///
/// Returns null on success, or a short uppercase message suitable for a
/// status line. Never throws: this is a convenience attached to an
/// editing form, and it must not be able to take down the form.
Future<String?> revealInFileManager(String absolutePath) async {
  if (!canRevealPaths) {
    return 'FILE MANAGER HANDOFF IS LINUX ONLY';
  }

  final String path = absolutePath.trim();
  if (path.isEmpty) return 'NO PATH TO OPEN';

  // Resolved once, here, rather than trusted from the caller. The node
  // panel knows a slot is a folder slot, but the slot describes what the
  // FIELD expects, not what is on disk, and a folder name that currently
  // resolves to a stray file is exactly when this is worth being right
  // about.
  final bool isDir = Directory(path).existsSync();
  final bool isFile = !isDir && File(path).existsSync();

  if (!isDir && !isFile) {
    diag('open', 'path absent: $path');
    return 'NOT ON DISK';
  }

  if (isDir) {
    return _openDetached('xdg-open', [path], path);
  }

  // A file: try to reveal it selected before settling for its parent.
  if (await _showItemInFileManager(path)) return null;

  final String parent = File(path).parent.path;
  diag('open', 'reveal unavailable, falling back to parent: $parent');
  return _openDetached('xdg-open', [parent], parent);
}

/// Starts [exe] detached and reports only whether it spawned.
///
/// See the header: an exit code from `xdg-open` describes the lifetime of
/// the file manager, not the success of the request, so the only honest
/// question left is whether the binary exists at all. A missing one
/// throws [ProcessException] immediately and is worth saying out loud,
/// because on a headless or minimal box it is the actual explanation.
Future<String?> _openDetached(
    String exe, List<String> args, String what) async {
  try {
    await Process.start(exe, args, mode: ProcessStartMode.detached);
    diag('open', '$exe $what');
    return null;
  } on ProcessException catch (e) {
    diag('open', '$exe missing: ${e.message}');
    return 'NO $exe ON PATH';
  } catch (e) {
    diag('open', '$exe failed: $e');
    return 'COULD NOT OPEN $what';
  }
}

// =====================================================================
// WHY gdbus AND NOT `nautilus --select`
//
// Selecting a file inside its folder has no command-line spelling that
// generalises: nautilus and dolphin spell it `--select`, nemo and thunar
// do not take it at all, and probing for one by name is a list of
// desktops that goes stale the moment somebody runs this on a machine
// nobody tested.
//
// The freedesktop answer is a bus interface, org.freedesktop.FileManager1,
// which every one of those file managers implements and which is
// D-Bus-activatable, so the call starts the file manager if it is not
// already up. It asks the session what its file manager is instead of
// guessing, which is the same reason `xdg-open` is used above rather
// than the name of a browser.
//
// `gdbus` carries the call. It is part of glib2, and a Flutter Linux
// build already requires GTK, so this adds nothing to the prerequisites
// in the README.
// =====================================================================

/// Asks the session's file manager to show [path] with it selected.
///
/// Returns true when the call was accepted. False means no file manager
/// answered the bus, or gdbus is not installed, and the caller should
/// fall back to opening the parent directory.
Future<bool> _showItemInFileManager(String path) async {
  final String uri = _gvariantSafeFileUri(path);

  try {
    final ProcessResult r = await Process.run('gdbus', [
      'call',
      '--session',
      '--dest',
      'org.freedesktop.FileManager1',
      '--object-path',
      '/org/freedesktop/FileManager1',
      '--method',
      'org.freedesktop.FileManager1.ShowItems',
      "['$uri']",
      // Startup notification id. Empty is legal and means "no token".
      '',
    ]).timeout(const Duration(seconds: 6));

    if (r.exitCode == 0) {
      diag('open', 'ShowItems $uri');
      return true;
    }
    diag('open', 'ShowItems exit ${r.exitCode}: ${r.stderr}');
    return false;
  } catch (e) {
    // Missing gdbus, no bus, no owner, or an activation slower than the
    // timeout. All four mean the same thing to the caller.
    diag('open', 'ShowItems unavailable: $e');
    return false;
  }
}

/// A `file://` URI for [path], safe to embed in a GVariant literal.
///
/// The argument crosses as ONE argv element and no shell is involved, so
/// spaces need nothing beyond the URI encoding [Uri.file] already does.
/// The apostrophe is the exception and the reason this function exists:
/// it is a legal path character that [Uri] leaves alone because it is
/// legal in a URI too, and it is also what closes the GVariant string
/// literal. An unescaped one turns a filename into a parse error.
///
/// Percent-encoding it is correct rather than a workaround: %27 is a
/// valid encoding of that byte, and the file manager decodes the URI
/// before it touches the filesystem.
String _gvariantSafeFileUri(String path) =>
    Uri.file(path).toString().replaceAll("'", '%27');