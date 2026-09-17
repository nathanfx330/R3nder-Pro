// ./lib/project_media_bin.dart
//
// Read-only projection of a project's video/ directory for media-bin UIs.
//
// The bin is derived state. Scanning never creates, renames, copies, probes,
// or otherwise mutates workspace media. Files with names that cannot safely be
// authored into CLIP grammar remain visible and are marked unusableName.

import 'dart:io';

import 'edit_media_import.dart' show resolveActiveWorkspaceRoot;

enum ProjectMediaUsability { usable, unusableName }

class ProjectMediaItem {
  final String fileName;
  final String resolvedPath;
  final String? authoredSource;
  final int sizeBytes;
  final DateTime modifiedAt;
  final ProjectMediaUsability usability;

  const ProjectMediaItem({
    required this.fileName,
    required this.resolvedPath,
    required this.authoredSource,
    required this.sizeBytes,
    required this.modifiedAt,
    required this.usability,
  });

  bool get isUsable => usability == ProjectMediaUsability.usable;
}

ProjectMediaUsability classifyProjectMediaFileName(String fileName) {
  // These characters cannot be copied verbatim into a CLIP source field.
  // Import normalizes the same structural delimiters and control characters
  // at the workspace boundary. Files dropped into video/ manually are not
  // silently renamed; the bin exposes them with unusableName instead.
  final bool unsafe =
      fileName.isEmpty ||
      RegExp(r'[:\[\]\r\n]').hasMatch(fileName) ||
      RegExp(r'[\x00-\x1F]').hasMatch(fileName);
  return unsafe
      ? ProjectMediaUsability.unusableName
      : ProjectMediaUsability.usable;
}

List<ProjectMediaItem> scanProjectMediaBin({String? workspaceRoot}) {
  final Directory workspace = Directory(
    workspaceRoot ?? resolveActiveWorkspaceRoot(),
  ).absolute;
  final Directory videoDir = Directory(
    '${workspace.path}${Platform.pathSeparator}video',
  );

  if (!videoDir.existsSync()) {
    return const <ProjectMediaItem>[];
  }

  final List<ProjectMediaItem> items = <ProjectMediaItem>[];
  for (final FileSystemEntity entity in videoDir.listSync(followLinks: false)) {
    if (entity is! File) continue;

    final File file = entity.absolute;
    final FileStat stat = file.statSync();
    final String fileName = _basename(file.path);
    final ProjectMediaUsability usability = classifyProjectMediaFileName(
      fileName,
    );

    items.add(
      ProjectMediaItem(
        fileName: fileName,
        resolvedPath: file.path,
        authoredSource: usability == ProjectMediaUsability.usable
            ? 'video/$fileName'
            : null,
        sizeBytes: stat.size,
        modifiedAt: stat.modified,
        usability: usability,
      ),
    );
  }

  items.sort(_compareProjectMediaItems);
  return List<ProjectMediaItem>.unmodifiable(items);
}

int _compareProjectMediaItems(ProjectMediaItem a, ProjectMediaItem b) {
  final int folded = a.fileName.toLowerCase().compareTo(
    b.fileName.toLowerCase(),
  );
  if (folded != 0) return folded;
  return a.fileName.compareTo(b.fileName);
}

String _basename(String path) {
  final String normalized = path.replaceAll('\\', '/');
  final int slash = normalized.lastIndexOf('/');
  return slash < 0 ? normalized : normalized.substring(slash + 1);
}
