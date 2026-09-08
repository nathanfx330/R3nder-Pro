// ./test/documentation_contract_manifest_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('documentation contract proof paths exist', () {
    final Directory root = _findRepositoryRoot(Directory.current);
    final File manifest = File(
      '${root.path}${Platform.pathSeparator}docs'
      '${Platform.pathSeparator}CONTRACT_TEST_MANIFEST.md',
    );

    expect(
      manifest.existsSync(),
      isTrue,
      reason: 'docs/CONTRACT_TEST_MANIFEST.md must exist.',
    );

    final String source = manifest.readAsStringSync();
    final List<_ContractSection> contracts = _parseContracts(source);
    expect(
      contracts,
      isNotEmpty,
      reason: 'The manifest must contain numbered contract sections.',
    );

    for (final _ContractSection contract in contracts) {
      final List<String> paths = _proofPaths(contract.body);
      expect(
        paths,
        isNotEmpty,
        reason: '${contract.title} must name at least one proof file.',
      );

      for (final String path in paths) {
        final File file = File(
          '${root.path}${Platform.pathSeparator}'
          '${path.replaceAll('/', Platform.pathSeparator)}',
        );
        expect(
          file.existsSync(),
          isTrue,
          reason: '${contract.title} cites missing proof file: $path',
        );
      }
    }
  });
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
