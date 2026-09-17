// ./lib/project_media_thumbnails.dart
//
// Disk-backed thumbnail cache for project media-bin items.
//
// Thumbnail generation is derived work, never authored project state. Cached
// images live under <workspace>/.cache/thumbs and are invalidated by a stable
// key over media path, size, and modification time. The caller owns transport
// state and must report whether ProjectClock is running; this service will not
// launch ffmpeg while that flag is true.

import 'dart:convert';
import 'dart:io';

import 'edit_media_import.dart' show resolveActiveWorkspaceRoot;
import 'project_media_bin.dart';

typedef ThumbnailProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

class ProjectMediaThumbnailService {
  final String workspaceRoot;
  final String ffmpegExecutable;
  final ThumbnailProcessRunner _runProcess;

  ProjectMediaThumbnailService({
    String? workspaceRoot,
    this.ffmpegExecutable = 'ffmpeg',
    ThumbnailProcessRunner? runProcess,
  }) : workspaceRoot = Directory(
         workspaceRoot ?? resolveActiveWorkspaceRoot(),
       ).absolute.path,
       _runProcess = runProcess ?? _defaultRunProcess;

  String thumbnailPathFor(ProjectMediaItem item) {
    final String key = projectMediaThumbnailCacheKey(item);
    return '$workspaceRoot${Platform.pathSeparator}.cache'
        '${Platform.pathSeparator}thumbs${Platform.pathSeparator}$key.jpg';
  }

  Future<String?> thumbnailFor(
    ProjectMediaItem item, {
    required bool projectClockRunning,
  }) async {
    final File thumbnail = File(thumbnailPathFor(item));
    if (_isNonEmptyFile(thumbnail)) return thumbnail.path;

    // Cached thumbnails remain available during playback, but no new ffmpeg
    // subprocess is allowed to launch while ProjectClock is running.
    if (projectClockRunning) return null;

    final File media = File(item.resolvedPath);
    if (!media.existsSync()) return null;

    final Directory cacheDir = thumbnail.parent;
    cacheDir.createSync(recursive: true);

    final File temporary = File('${thumbnail.path}.tmp.jpg');
    _deleteIfPresent(temporary);

    final ProcessResult result;
    try {
      result = await _runProcess(ffmpegExecutable, <String>[
        '-hide_banner',
        '-loglevel',
        'error',
        '-nostdin',
        '-y',
        '-i',
        media.path,
        '-frames:v',
        '1',
        '-vf',
        'scale=320:-2:force_original_aspect_ratio=decrease',
        '-q:v',
        '3',
        temporary.path,
      ]);
    } catch (_) {
      _deleteIfPresent(temporary);
      return null;
    }

    if (result.exitCode != 0 || !_isNonEmptyFile(temporary)) {
      _deleteIfPresent(temporary);
      return null;
    }

    _deleteIfPresent(thumbnail);
    temporary.renameSync(thumbnail.path);
    return thumbnail.path;
  }
}

String projectMediaThumbnailCacheKey(ProjectMediaItem item) {
  final String identity =
      '${item.resolvedPath}\u0000${item.sizeBytes}\u0000'
      '${item.modifiedAt.microsecondsSinceEpoch}';
  return _fnv1a64(identity);
}

Future<ProcessResult> _defaultRunProcess(
  String executable,
  List<String> arguments,
) {
  return Process.run(executable, arguments);
}

bool _isNonEmptyFile(File file) {
  if (!file.existsSync()) return false;
  try {
    return file.lengthSync() > 0;
  } catch (_) {
    return false;
  }
}

void _deleteIfPresent(File file) {
  try {
    if (file.existsSync()) file.deleteSync();
  } catch (_) {}
}

String _fnv1a64(String value) {
  const int offsetBasis = 0xcbf29ce484222325;
  const int prime = 0x100000001b3;
  const int mask = 0xffffffffffffffff;

  int hash = offsetBasis;
  for (final int byte in utf8.encode(value)) {
    hash ^= byte;
    hash = (hash * prime) & mask;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
