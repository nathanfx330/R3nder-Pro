// ./lib/session_store.dart

import 'dart:convert';
import 'dart:io';

// =====================================================================
// WHY THIS EXISTS
//
// Two separate failures made R3nder forget what you were working on.
//
// 1. THE APP FOLDER MOVED. Session state was written to $baseDir, and
//    $baseDir was resolved by walking UP FROM THE CURRENT WORKING
//    DIRECTORY looking for a templates/ or fonts/ folder. The cwd is not
//    a property of the install: it is the project root under
//    `flutter run` and whatever directory you happened to be in when you
//    launched a built binary. So the workspace path was written to one
//    place and looked for in another, the read came back empty, and the
//    app silently fell back to default_workspace/ as though nothing had
//    ever been saved.
//
//    The executable's own directory does not move. That IS the portable
//    app folder: the binary, templates/, and default_workspace/ sit in
//    it together and travel together.
//
// 2. THE TEMPLATE WAS NEVER SAVED AT ALL. There was no read and no
//    write. The index started at 0 and whatever Directory.listSync()
//    happened to return first got loaded, which is filesystem order and
//    therefore not even stable between two boots of the same install.
//
// WHY BY NAME, NOT BY INDEX. An index is an address into a list whose
// contents change. Add a template, rename one, or let the filesystem
// reorder itself, and a saved index quietly points at a different file.
// A filename either resolves or it does not, and when it does not the
// fallback is visible rather than wrong.
//
// WHY PER WORKSPACE. A template is a recipe and a workspace is the
// ingredients; the piece you are actually working on is the PAIRING of
// the two. Remembering one last-used template globally would mean
// switching workspaces hands you a script written against assets that
// are no longer there. Fonts are scoped the same way for the same
// reason: they live inside the workspace, so the selection cannot
// meaningfully survive a switch.
//
// The audio device stays global. A sink name is a property of this
// machine, not of a project, which is the same argument the original
// code made for keeping it out of workspace.json.
// =====================================================================

/// Session file, inside the portable app folder so it travels with the
/// binary and the workspaces it names.
const String kSessionFileName = '.r3nder_session.json';

/// Superseded single-line state files, read once for migration.
const String kLegacyWorkspaceFile = '.r3nder_workspace';
const String kLegacyAudioDeviceFile = '.r3nder_audio_device';

/// Schema version. Nothing reads it yet; it is here so a future change
/// can tell an old file from a corrupt one.
const int kSessionSchemaVersion = 1;

/// Locates the portable app folder: the directory holding the executable,
/// templates/, and default_workspace/.
///
/// Resolution order, and the order matters:
///
///  1. The executable's own directory, if it already looks like an app
///     folder. This is the installed and portable case, and it is stable
///     across launches no matter where you were standing when you ran it.
///  2. Walking UP from the executable, for the development case: a
///     `flutter run` binary lives in build/linux/<arch>/<mode>/bundle/,
///     several levels below the project root that actually holds
///     templates/.
///  3. The executable's directory anyway. A fresh portable copy has no
///     markers yet, so this is first launch and the caller will scaffold
///     templates/ and default_workspace/ right here.
///
/// The current working directory is deliberately never consulted.
String resolvePortableBaseDir() {
  Directory exeDir;
  try {
    exeDir = File(Platform.resolvedExecutable).parent;
  } catch (_) {
    return Directory.current.path;
  }

  if (_isAppRoot(exeDir.path)) return exeDir.path;

  // Development layout. Six levels clears bundle -> mode -> arch ->
  // linux -> build -> project root with one to spare.
  Directory d = exeDir;
  for (int i = 0; i < 6; i++) {
    if (d.path == d.parent.path) break; // filesystem root
    d = d.parent;
    if (_isAppRoot(d.path) || _isSourceRoot(d.path)) return d.path;
  }

  return exeDir.path;
}

/// An app folder that has been used at least once.
bool _isAppRoot(String p) {
  try {
    return Directory('$p${Platform.pathSeparator}templates').existsSync() ||
        Directory('$p${Platform.pathSeparator}default_workspace').existsSync();
  } catch (_) {
    return false;
  }
}

/// A checked-out source tree that has not been run yet, so it carries no
/// app-folder markers. Without this a first `flutter run` on a fresh
/// clone would scaffold templates/ down inside build/, where the next
/// `flutter clean` would delete it.
bool _isSourceRoot(String p) {
  try {
    return File('$p${Platform.pathSeparator}pubspec.yaml').existsSync();
  } catch (_) {
    return false;
  }
}

/// Everything the app should remember between launches.
///
/// Nothing here ever throws. A missing, unreadable, or malformed session
/// file is a first launch, which is a completely ordinary state: losing
/// the last selection is an annoyance, and refusing to open is not an
/// acceptable trade for it. Failures are reported through [onError] so
/// the caller can log them and carry on.
class SessionStore {
  /// Portable app folder. The session file sits directly inside it.
  final String baseDir;

  /// Routed to the caller's error log. Never used for control flow.
  final void Function(String message)? onError;

  SessionStore({required this.baseDir, this.onError});

  String get path => '$baseDir${Platform.pathSeparator}$kSessionFileName';

  /// Absolute path of the workspace that was active on last exit, or null
  /// if there is nothing remembered (or it has since been deleted, which
  /// the caller checks).
  String? workspace;

  /// Output sink id. Machine-scoped, so global rather than per workspace.
  String? audioDeviceId;

  /// Workspace path -> template FILENAME (not a path, and not an index).
  final Map<String, String> _templateByWorkspace = {};

  /// Workspace path -> font FAMILY NAME, which is what FontLoader
  /// registers and what the engine is handed, so it survives the font
  /// list being re-scanned in a different order.
  final Map<String, String> _fontByWorkspace = {};

  String? templateFor(String workspacePath) =>
      _templateByWorkspace[workspacePath];

  String? fontFor(String workspacePath) => _fontByWorkspace[workspacePath];

  void setTemplateFor(String workspacePath, String? fileName) {
    if (fileName == null || fileName.isEmpty) {
      _templateByWorkspace.remove(workspacePath);
    } else {
      _templateByWorkspace[workspacePath] = fileName;
    }
  }

  void setFontFor(String workspacePath, String? family) {
    if (family == null || family.isEmpty) {
      _fontByWorkspace.remove(workspacePath);
    } else {
      _fontByWorkspace[workspacePath] = family;
    }
  }

  /// Reads the session file, falling back to the two legacy single-line
  /// files when it is absent.
  ///
  /// Migration is read-only and one-way. The legacy files are left on
  /// disk rather than deleted: they cost nothing, and deleting state
  /// during a load path is the kind of thing that turns a bad parse into
  /// a lost workspace.
  void load() {
    final File f = File(path);

    bool exists = false;
    try {
      exists = f.existsSync();
    } catch (_) {
      exists = false;
    }

    if (!exists) {
      _loadLegacy();
      return;
    }

    try {
      final dynamic raw = jsonDecode(f.readAsStringSync());
      if (raw is! Map) {
        onError?.call('Session file is not an object, ignoring: $path');
        _loadLegacy();
        return;
      }

      workspace = _readString(raw['workspace']);
      audioDeviceId = _readString(raw['audioDevice']);
      _readStringMap(raw['templates'], _templateByWorkspace);
      _readStringMap(raw['fonts'], _fontByWorkspace);
    } catch (e) {
      onError?.call('Failed to read session file, starting fresh: $e');
      _loadLegacy();
    }
  }

  /// Picks up state written by the pre-session build so an existing
  /// install does not lose its workspace the first time it runs this
  /// code. Only fills fields that are still unset.
  void _loadLegacy() {
    workspace ??= _readLine(kLegacyWorkspaceFile);
    audioDeviceId ??= _readLine(kLegacyAudioDeviceFile);
  }

  String? _readLine(String fileName) {
    try {
      final File f = File('$baseDir${Platform.pathSeparator}$fileName');
      if (!f.existsSync()) return null;
      final String s = f.readAsStringSync().trim();
      return s.isEmpty ? null : s;
    } catch (_) {
      return null;
    }
  }

  static String? _readString(dynamic v) {
    if (v is! String) return null;
    final String s = v.trim();
    return s.isEmpty ? null : s;
  }

  static void _readStringMap(dynamic v, Map<String, String> into) {
    if (v is! Map) return;
    v.forEach((k, val) {
      if (k is String && val is String && k.isNotEmpty && val.isNotEmpty) {
        into[k] = val;
      }
    });
  }

  /// Writes the session file.
  ///
  /// Prunes per-workspace entries whose directory no longer exists, so
  /// the file does not accumulate a permanent record of every folder the
  /// app has ever seen. The active workspace is never pruned, even if it
  /// has somehow gone missing mid-session: it is what the caller is
  /// currently working in, and dropping it here would make the next
  /// launch forget a workspace that a moment ago was fine.
  void save() {
    _prune();

    final Map<String, dynamic> data = {
      'version': kSessionSchemaVersion,
      if (workspace != null) 'workspace': workspace,
      if (audioDeviceId != null) 'audioDevice': audioDeviceId,
      'templates': _templateByWorkspace,
      'fonts': _fontByWorkspace,
    };

    try {
      File(path)
          .writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(data)}\n');
    } catch (e) {
      onError?.call('Failed to write session file: $e');
    }
  }

  void _prune() {
    bool gone(String workspacePath) {
      if (workspacePath == workspace) return false;
      try {
        return !Directory(workspacePath).existsSync();
      } catch (_) {
        return false;
      }
    }

    _templateByWorkspace.removeWhere((ws, _) => gone(ws));
    _fontByWorkspace.removeWhere((ws, _) => gone(ws));
  }
}