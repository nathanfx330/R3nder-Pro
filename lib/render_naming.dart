// ./lib/render_naming.dart
//
// Collision-safe naming for finished BAKE outputs.
//
// Render names are authored as human labels, then normalized into portable
// filename stems. Versions are monotonic across every container format in one
// render family: if `cut_1080p_v003.mp4` exists and v002 was deleted, the next
// bake is v004 rather than reusing a hole. Fill/matte pairs reserve one version
// together so their filenames can never drift apart.

import 'dart:io';

class RenderOutputPlan {
  final String outputPath;
  final String? mattePath;
  final String safeName;
  final String resolutionLabel;
  final int version;
  final String fileName;
  final String? matteFileName;

  const RenderOutputPlan({
    required this.outputPath,
    required this.safeName,
    required this.resolutionLabel,
    required this.version,
    required this.fileName,
    this.mattePath,
    this.matteFileName,
  });

  String get versionLabel => 'v${version.toString().padLeft(3, '0')}';
}

String sanitizeRenderName(String raw, {String fallback = 'output'}) {
  String value = raw.trim();
  value = value.replaceFirst(
    RegExp(r'\.(?:mp4|mov)$', caseSensitive: false),
    '',
  );
  value = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
  value = value.replaceAll(RegExp(r'_+'), '_');
  value = value.replaceAll(RegExp(r'^[._-]+'), '');
  value = value.replaceAll(RegExp(r'[._-]+$'), '');

  if (value.isNotEmpty) return value;

  String safeFallback = fallback.trim();
  safeFallback = safeFallback.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
  safeFallback = safeFallback.replaceAll(RegExp(r'_+'), '_');
  safeFallback = safeFallback.replaceAll(RegExp(r'^[._-]+'), '');
  safeFallback = safeFallback.replaceAll(RegExp(r'[._-]+$'), '');
  return safeFallback.isEmpty ? 'output' : safeFallback;
}

String _joinPath(String directoryPath, String fileName) {
  if (directoryPath.endsWith('/') || directoryPath.endsWith('\\')) {
    return '$directoryPath$fileName';
  }
  return '$directoryPath${Platform.pathSeparator}$fileName';
}

String _fileName(String path) =>
    path.split(RegExp(r'[\\/]+')).where((String part) => part.isNotEmpty).last;

int _maxExistingVersion({
  required Directory directory,
  required String familyStem,
}) {
  if (!directory.existsSync()) return 0;

  final RegExp versioned = RegExp(
    '^${RegExp.escape(familyStem)}_v(?<version>\\d{3,})(?:_matte)?\\.[^.]+\$',
    caseSensitive: false,
  );

  int maxVersion = 0;
  for (final FileSystemEntity entity in directory.listSync()) {
    if (entity is! File) continue;
    final RegExpMatch? match = versioned.firstMatch(_fileName(entity.path));
    if (match == null) continue;
    final int? version = int.tryParse(match.namedGroup('version') ?? '');
    if (version != null && version > maxVersion) maxVersion = version;
  }
  return maxVersion;
}

RenderOutputPlan planNextRenderOutput({
  required String directoryPath,
  required String renderName,
  required String resolutionLabel,
  required String extension,
  bool preroll = false,
  bool includeMatteCompanion = false,
}) {
  final String safeName = sanitizeRenderName(renderName);
  final String safeResolution = sanitizeRenderName(
    resolutionLabel,
    fallback: 'render',
  );
  final String safeExtension = extension
      .trim()
      .replaceFirst(RegExp(r'^\.+'), '')
      .toLowerCase();
  if (safeExtension.isEmpty) {
    throw ArgumentError.value(extension, 'extension', 'Cannot be empty.');
  }

  final String familyStem =
      '${preroll ? 'preroll_' : ''}${safeName}_$safeResolution';
  final Directory directory = Directory(directoryPath);
  int version = _maxExistingVersion(
        directory: directory,
        familyStem: familyStem,
      ) +
      1;

  while (true) {
    final String versionLabel = 'v${version.toString().padLeft(3, '0')}';
    final String stem = '${familyStem}_$versionLabel';
    final String fileName = '$stem.$safeExtension';
    final String outputPath = _joinPath(directoryPath, fileName);
    final String? matteFileName =
        includeMatteCompanion ? '${stem}_matte.$safeExtension' : null;
    final String? mattePath = matteFileName == null
        ? null
        : _joinPath(directoryPath, matteFileName);

    final bool occupied = File(outputPath).existsSync() ||
        (mattePath != null && File(mattePath).existsSync());
    if (!occupied) {
      return RenderOutputPlan(
        outputPath: outputPath,
        mattePath: mattePath,
        safeName: safeName,
        resolutionLabel: safeResolution,
        version: version,
        fileName: fileName,
        matteFileName: matteFileName,
      );
    }
    version++;
  }
}
