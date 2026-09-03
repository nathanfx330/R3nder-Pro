// ./lib/edit_media_import.dart
//
// Workspace media import for the source-backed EDIT surface.
//
// External files are copied into <workspace>/video and represented in script
// as portable video/<name> paths. MLT is consulted once for source length and
// exact source frame rate. Import then conforms that source timing to R3nder's
// fixed project rate. After the CLIP exists, authored duration and speed remain
// canonical project state.

import 'dart:io';

import 'engine.dart';
import 'native_media_probe.dart';
import 'session_store.dart';

class ImportedEditVideo {
  final String authoredSource;
  final String resolvedPath;
  final String clipBaseId;
  final int durationFrames;
  final int speedNumerator;
  final int speedDenominator;
  final int sourceFpsNumerator;
  final int sourceFpsDenominator;

  const ImportedEditVideo({
    required this.authoredSource,
    required this.resolvedPath,
    required this.clipBaseId,
    required this.durationFrames,
    this.speedNumerator = 1,
    this.speedDenominator = 1,
    this.sourceFpsNumerator = engineFps,
    this.sourceFpsDenominator = 1,
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
  NativeMediaProbeResult Function(String resolvedPath)? probeMedia,
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
    final NativeMediaProbeResult timing;
    if (probeMedia != null) {
      timing = probeMedia(destination.path);
    } else if (probeFrames != null) {
      // Backward-compatible deterministic test seam. Existing tests that only
      // care about filesystem import implicitly describe project-rate media.
      timing = NativeMediaProbeResult(
        lengthFrames: probeFrames(destination.path),
        fpsNumerator: engineFps,
        fpsDenominator: 1,
      );
    } else {
      timing = NativeMltMediaProbe().probe(destination.path);
    }

    if (timing.lengthFrames <= 0 ||
        timing.fpsNumerator <= 0 ||
        timing.fpsDenominator <= 0) {
      throw StateError(
        'Media probe returned invalid timing: '
        '${timing.lengthFrames} frames at '
        '${timing.fpsNumerator}/${timing.fpsDenominator} fps',
      );
    }

    // CLIP speed is source frames consumed per project frame. A 24 fps source
    // in R3nder's 30 fps project therefore becomes 24/30 = 4/5. Native MLT
    // playback then runs that source at its natural 1.0 transport speed while
    // ProjectClock still advances at 30 project frames per second.
    final int rawSpeedNumerator = timing.fpsNumerator;
    final int rawSpeedDenominator = timing.fpsDenominator * engineFps;
    final int speedDivisor = _gcd(rawSpeedNumerator, rawSpeedDenominator);
    final int speedNumerator = rawSpeedNumerator ~/ speedDivisor;
    final int speedDenominator = rawSpeedDenominator ~/ speedDivisor;

    // Preserve source duration in wall-clock time while expressing duration in
    // project frames. ceil(sourceFrames / sourceFramesPerProjectFrame) ensures
    // the final authored project frame can still address the final source frame.
    final int durationNumerator =
        timing.lengthFrames * engineFps * timing.fpsDenominator;
    final int durationFrames =
        (durationNumerator + timing.fpsNumerator - 1) ~/ timing.fpsNumerator;

    final String fileName = _basename(destination.path);
    return ImportedEditVideo(
      authoredSource: 'video/$fileName',
      resolvedPath: destination.path,
      clipBaseId: _clipIdFromFileName(fileName),
      durationFrames: durationFrames,
      speedNumerator: speedNumerator,
      speedDenominator: speedDenominator,
      sourceFpsNumerator: timing.fpsNumerator,
      sourceFpsDenominator: timing.fpsDenominator,
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
  // CLIP fields live inside square-bracket structural markup and use colon
  // as their field separator. Linux filenames may legally contain all three
  // characters, so a media filename cannot be copied verbatim into authored
  // source. In particular, a closing bracket would terminate [CLIP:...] early
  // and make the parser report a phantom extra/missing field. Normalize those
  // grammar delimiters at the workspace boundary before the path ever becomes
  // script text.
  String safe = value
      .replaceAll(RegExp(r'[:\[\]\r\n]'), '_')
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

int _gcd(int a, int b) {
  int x = a.abs();
  int y = b.abs();
  while (y != 0) {
    final int next = x % y;
    x = y;
    y = next;
  }
  return x == 0 ? 1 : x;
}
