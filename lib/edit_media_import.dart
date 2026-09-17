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

import 'edit_model.dart';
import 'engine.dart';
import 'native_media_probe.dart';
import 'session_store.dart';

export 'edit_video_preview.dart' show resolveWorkspaceMediaSource;

class ImportedEditVideo {
  final String authoredSource;
  final String resolvedPath;
  final String clipBaseId;
  final int durationFrames;
  final int sourceLengthFrames;
  final int speedNumerator;
  final int speedDenominator;
  final int sourceFpsNumerator;
  final int sourceFpsDenominator;

  const ImportedEditVideo({
    required this.authoredSource,
    required this.resolvedPath,
    required this.clipBaseId,
    required this.durationFrames,
    required this.sourceLengthFrames,
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

int sourceSpanToProjectFrames({
  required int sourceSpanFrames,
  required ExactClipSpeed speed,
}) {
  if (sourceSpanFrames <= 0) {
    throw ArgumentError.value(
      sourceSpanFrames,
      'sourceSpanFrames',
      'Source span must be positive.',
    );
  }
  return (sourceSpanFrames * speed.denominator + speed.numerator - 1) ~/
      speed.numerator;
}

ImportedEditVideo conformWorkspaceMedia(
  String resolvedPath, {
  int Function(String resolvedPath)? probeFrames,
  NativeMediaProbeResult Function(String resolvedPath)? probeMedia,
}) {
  final File mediaFile = File(resolvedPath).absolute;
  if (!mediaFile.existsSync()) {
    throw FileSystemException('Workspace video does not exist.', mediaFile.path);
  }

  final NativeMediaProbeResult timing;
  if (probeMedia != null) {
    timing = probeMedia(mediaFile.path);
  } else if (probeFrames != null) {
    timing = NativeMediaProbeResult(
      lengthFrames: probeFrames(mediaFile.path),
      fpsNumerator: engineFps,
      fpsDenominator: 1,
    );
  } else {
    timing = NativeMltMediaProbe().probe(mediaFile.path);
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
  // in R3nder's 30 fps project therefore becomes 24/30 = 4/5.
  final ExactClipSpeed speed = ExactClipSpeed(
    timing.fpsNumerator,
    timing.fpsDenominator * engineFps,
  );

  // Use the same exact ceiling conversion for whole media and partial source
  // ranges. The final project frame may clamp at the source edge, matching the
  // existing whole-file import behavior.
  final int durationFrames = sourceSpanToProjectFrames(
    sourceSpanFrames: timing.lengthFrames,
    speed: speed,
  );

  final String fileName = _basename(mediaFile.path);
  return ImportedEditVideo(
    authoredSource: 'video/$fileName',
    resolvedPath: mediaFile.path,
    clipBaseId: _clipIdFromFileName(fileName),
    durationFrames: durationFrames,
    sourceLengthFrames: timing.lengthFrames,
    speedNumerator: speed.numerator,
    speedDenominator: speed.denominator,
    sourceFpsNumerator: timing.fpsNumerator,
    sourceFpsDenominator: timing.fpsDenominator,
  );
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
    return conformWorkspaceMedia(
      destination.path,
      probeFrames: probeFrames,
      probeMedia: probeMedia,
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
