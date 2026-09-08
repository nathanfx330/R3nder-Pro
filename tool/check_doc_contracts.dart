// ./tool/check_doc_contracts.dart
//
// Verifies that the proof files named by docs/CONTRACT_TEST_MANIFEST.md still
// exist. The manifest is documentation, but its references should fail loudly
// when a proving test/probe/visual gate is renamed or removed.

import 'dart:io';

void main() {
  final Directory root = _findRepositoryRoot(Directory.current);
  final File manifest = File(
    '${root.path}${Platform.pathSeparator}docs'
    '${Platform.pathSeparator}CONTRACT_TEST_MANIFEST.md',
  );

  if (!manifest.existsSync()) {
    stderr.writeln('Missing docs/CONTRACT_TEST_MANIFEST.md');
    exitCode = 1;
    return;
  }

  final String source = manifest.readAsStringSync();
  final List<_ContractSection> contracts = _parseContracts(source);
  final List<String> errors = <String>[];
  final Set<String> checkedPaths = <String>{};

  if (contracts.isEmpty) {
    errors.add('Manifest contains no numbered contract sections.');
  }

  for (final _ContractSection contract in contracts) {
    final List<String> proofPaths = _proofPaths(contract.body);
    if (proofPaths.isEmpty) {
      errors.add('${contract.title}: no proof paths declared.');
      continue;
    }

    for (final String path in proofPaths) {
      checkedPaths.add(path);
      final File file = File(
        '${root.path}${Platform.pathSeparator}'
        '${path.replaceAll('/', Platform.pathSeparator)}',
      );
      if (!file.existsSync()) {
        errors.add('${contract.title}: missing $path');
      }
    }
  }

  if (errors.isNotEmpty) {
    stderr.writeln('Documentation contract drift detected:');
    for (final String error in errors) {
      stderr.writeln('  - $error');
    }
    exitCode = 1;
    return;
  }

  stdout.writeln(
    'Documentation contracts OK: '
    '${contracts.length} contracts, ${checkedPaths.length} proof files.',
  );
}

Directory _findRepositoryRoot(Directory start) {
  Directory current = start.absolute;
  while (true) {
    if (File(
      '${current.path}${Platform.pathSeparator}pubspec.yaml',
    ).existsSync()) {
      return current;
    }

    final Directory parent = current.parent;
    if (parent.path == current.path) {
      throw StateError(
        'Could not find repository root containing pubspec.yaml '
        'from ${start.path}.',
      );
    }
    current = parent;
  }
}

List<_ContractSection> _parseContracts(String source) {
  final RegExp heading = RegExp(r'^## (?<title>\d+\. .+)$', multiLine: true);
  final List<RegExpMatch> matches = heading.allMatches(source).toList();
  final List<_ContractSection> sections = <_ContractSection>[];

  for (int i = 0; i < matches.length; i++) {
    final RegExpMatch match = matches[i];
    final int bodyStart = match.end;
    final int bodyEnd = i + 1 < matches.length ? matches[i + 1].start : source.length;
    sections.add(
      _ContractSection(
        title: match.namedGroup('title')!,
        body: source.substring(bodyStart, bodyEnd),
      ),
    );
  }

  return sections;
}

List<String> _proofPaths(String body) {
  final RegExp pathPattern = RegExp(
    r'`((?:test|tool|linux/runner|docs)/[^`\r\n]+)`',
  );
  return pathPattern
      .allMatches(body)
      .map((RegExpMatch match) => match.group(1)!)
      .toSet()
      .toList()
    ..sort();
}

class _ContractSection {
  final String title;
  final String body;

  const _ContractSection({
    required this.title,
    required this.body,
  });
}
