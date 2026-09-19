// ./lib/template_authoring.dart
//
// Dashboard-side document creation for the shared templates/ library.
//
// Templates remain app-level recipes rather than workspace assets. This helper
// owns the filesystem policy so the dashboard dialog does not duplicate naming
// rules or accidentally create paths outside templates/.

import 'dart:io';

class TemplateDocumentException implements Exception {
  final String message;

  const TemplateDocumentException(this.message);

  @override
  String toString() => message;
}

String normalizeTemplateDocumentName(String rawName) {
  final String name = rawName.trim();
  if (name.isEmpty) {
    throw const TemplateDocumentException('Document name cannot be empty.');
  }
  if (name == '.' || name == '..') {
    throw const TemplateDocumentException('Document name is not valid.');
  }

  // Keep names portable between Linux and Windows builds. The dashboard is
  // creating one filename, never a path, so separators and Windows-reserved
  // filename characters have no useful meaning here.
  final RegExp invalid = RegExp(r'[<>:"/\\|?*\x00-\x1F]');
  if (invalid.hasMatch(name)) {
    throw const TemplateDocumentException(
      'Document name contains characters that cannot be used in a filename.',
    );
  }
  if (name.endsWith('.') || name.endsWith(' ')) {
    throw const TemplateDocumentException(
      'Document name cannot end with a dot or space.',
    );
  }

  return name.toLowerCase().endsWith('.txt') ? name : '$name.txt';
}

/// Creates one empty template document and returns its normalized filename.
///
/// Collision checks are case-insensitive so a document library created on
/// Linux behaves the same after moving to a case-insensitive filesystem.
String createTemplateDocument({
  required String templatesDir,
  required String rawName,
}) {
  final String fileName = normalizeTemplateDocumentName(rawName);
  final Directory dir = Directory(templatesDir);
  try {
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    final String wanted = fileName.toLowerCase();
    for (final FileSystemEntity entity in dir.listSync()) {
      final String existing =
          entity.path.split(Platform.pathSeparator).last.toLowerCase();
      if (existing == wanted) {
        throw TemplateDocumentException(
          'A document named $fileName already exists.',
        );
      }
    }

    final String path =
        '${dir.path}${Platform.pathSeparator}$fileName';
    File(path).writeAsStringSync('', flush: true);
  } on TemplateDocumentException {
    rethrow;
  } on FileSystemException catch (error) {
    throw TemplateDocumentException(
      'Could not create $fileName: ${error.message}',
    );
  }

  return fileName;
}
