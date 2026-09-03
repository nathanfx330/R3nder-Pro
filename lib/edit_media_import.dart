// ./lib/edit_media_import.dart
//
// Workspace media import for the source-backed EDIT surface.
//
// External files are copied into <workspace>/video and represented in script
// as portable video/<name> paths. MLT is consulted once for source length so
// the initial CLIP can be authored at the source's real frame count. After the
// CLIP exists, authored duration remains canonical project state.

import 'dart:io';

import 'native_media_probe.dart';
import 'session_store.dart';

class ImportedEditVideo {
  final String authoredSource;
  final String resolvedPath;
  final String clipBaseId;
  final int durationFrames;

  const ImportedEditVideo({
    required this.authoredSource,
    required this.resolvedPath,
    required this.clipBaseId,
    required this.durationFrames,
  });
}

String resolveActiveWorkspaceRoot() {
  final String baseDir = resolvePortableBaseDir();
  final SessionStore session = SessionStore(baseDir: baseDir)..load();
  final String? workspace = session.workspace;
  if (workspace == null || workspace.trim().isEmpty) {
    throw const FileSystemException('No active workspace is available.');
  }
  return Directory(workspace).absolute.path;
}

ImportedEditVideo importVideoToWorkspace(
  String pickedPath, {
  String? workspaceRoot,
  int Function(String resolvedPath)? probeFrames,
}) {
  final File sourceFile = File(pickedPath).absolute;
  if (!sourceFile.existsSync()) {
    throw FileSystemException('Selected video does not exist.', sourceFile.path);
  }

  final String workspace =
      Directory(workspaceRoot ?? resolveActiveWorkspaceRoot()).absolute.path;
  final Directory videoDir =
      Directory('$workspace${Platform.pathSeparator}video');
  videoDir.createSync(recursive: true);

  final String originalName = _basename(sourceFile.path);
  final String safeName = _safeFileName(originalName);
  String destinationPath = '${videoDir.path}${Platform.pathSeparator}$safeName';

  bool sameFile = false;
  final File initialDestination = File(destinationPath);
  if (initialDestination.existsSync()) {
    try {
      sameFile = FileSystemEntity.identicalSync(
        sourceFile.path,
        initialDestination.path,
      );
    } catch (_) {
      sameFile = sourceFile.path == initialDestination.absolute.path;
    }
  }

  if (!sameFile && initialDestination.existsSync()) {
    destinationPath = _nextAvailablePath(videoDir.path, safeName);
  }

  bool copied = false;
  final File destination = File(destinationPath);
  if (!sameFile) {
    sourceFile.copySync(destination.path);
    copied = true;
  }

  try {
    final int length = (probeFrames ?? NativeMltMediaProbe().sourceLengthFrames)(
      destination.path,
    );
    if (length <= 0) {
      throw StateError('Media probe returned an invalid source length: $length');
    }

    final String fileName = _basename(destination.path);
    return ImportedEditVideo(
      authoredSource: 'video/$fileName',
      resolvedPath: destination.path,
      clipBaseId: _clipIdFromFileName(fileName),
      durationFrames: length,
    );
  } catch (_) {
    if (copied && destination.existsSync()) {
      destination.deleteSync();
    }
    rethrow;
  }
}

String _basename(String path) {
  final String normalized = path.replaceAll('\\', '/');
  final int slash = normalized.lastIndexOf('/');
  return slash < 0 ? normalized : normalized.substring(slash + 1);
}

String _safeFileName(String value) {
  String safe = value
      .replaceAll(RegExp(r'[:\r\n]'), '_')
      .replaceAll(RegExp(r'[\x00-\x1F]'), '_')
      .trim();
  if (safe.isEmpty || safe == '.' || safe == '..') {
    safe = 'video.mp4';
  }
  return safe;
}

String _nextAvailablePath(String directory, String fileName) {
  final int dot = fileName.lastIndexOf('.');
  final String stem = dot > 0 ? fileName.substring(0, dot) : fileName;
  final String extension = dot > 0 ? fileName.substring(dot) : '';

  int suffix = 2;
  while (true) {
    final String candidate =
        '$directory${Platform.pathSeparator}${stem}_$suffix$extension';
    if (!File(candidate).existsSync()) return candidate;
    suffix++;
  }
}

String _clipIdFromFileName(String fileName) {
  final int dot = fileName.lastIndexOf('.');
  final String stem = dot > 0 ? fileName.substring(0, dot) : fileName;
  String id = stem
      .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
      .replaceAll(RegExp(r'_+'), '_');
  id = id.replaceAll(RegExp(r'^_+|_+$'), '');
  return id.isEmpty ? 'clip' : id;
}
