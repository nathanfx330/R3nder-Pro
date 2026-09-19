// ./test/template_authoring_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/template_authoring.dart';

void main() {
  test('normalizes document names to txt filenames', () {
    expect(normalizeTemplateDocumentName('notes'), 'notes.txt');
    expect(normalizeTemplateDocumentName('  notes.txt  '), 'notes.txt');
    expect(normalizeTemplateDocumentName('NOTES.TXT'), 'NOTES.TXT');
  });

  test('rejects empty, path-like, and non-portable names', () {
    for (final String name in <String>[
      '',
      '   ',
      '.',
      '..',
      'folder/name',
      r'folder\\name',
      'bad:name',
      'bad*name',
      'bad?',
      'trailing.',
    ]) {
      expect(
        () => normalizeTemplateDocumentName(name),
        throwsA(isA<TemplateDocumentException>()),
        reason: 'Expected "$name" to be rejected.',
      );
    }
  });

  test('creates one empty document and rejects case-insensitive collision', () {
    final Directory root =
        Directory.systemTemp.createTempSync('r3nder_template_authoring_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    final String fileName = createTemplateDocument(
      templatesDir: root.path,
      rawName: 'Interview Notes',
    );

    expect(fileName, 'Interview Notes.txt');

    final File created = File(
      '${root.path}${Platform.pathSeparator}Interview Notes.txt',
    );
    expect(created.existsSync(), isTrue);
    expect(created.readAsStringSync(), isEmpty);

    expect(
      () => createTemplateDocument(
        templatesDir: root.path,
        rawName: 'interview notes.TXT',
      ),
      throwsA(isA<TemplateDocumentException>()),
    );
  });

  test('creates templates directory when it does not exist yet', () {
    final Directory root =
        Directory.systemTemp.createTempSync('r3nder_template_parent_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    final String templates =
        '${root.path}${Platform.pathSeparator}templates';

    expect(Directory(templates).existsSync(), isFalse);

    final String fileName = createTemplateDocument(
      templatesDir: templates,
      rawName: 'first',
    );

    expect(fileName, 'first.txt');
    expect(Directory(templates).existsSync(), isTrue);
    expect(
      File('$templates${Platform.pathSeparator}first.txt').existsSync(),
      isTrue,
    );
  });
}
