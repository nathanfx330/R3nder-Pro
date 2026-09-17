// ./test/maximize_lint_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/script_lint.dart';

void main() {
  test('valid clip-local MAXIMIZE is not treated as terminal text', () {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:shot:video/shot.mp4:0:0:100:1]
[CUE:10]
  [MAXIMIZE:30]
[/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
[STRUCT:EDIT.main]
''';

    final List<LintFinding> findings = ScriptLinter.lint(source);
    expect(
      findings.where((LintFinding finding) =>
          finding.snippet.contains('MAXIMIZE') ||
          finding.message.contains('MAXIMIZE')),
      isEmpty,
    );
  });
}
