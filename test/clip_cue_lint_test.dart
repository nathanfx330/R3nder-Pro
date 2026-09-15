// ./test/clip_cue_lint_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/script_lint.dart';

void main() {
  test('valid clip-local CARD cue is not a terminal lint finding', () {
    const String source = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:shot:video/shot.mp4:0:0:300:1]
      [CUE:90]
        [CARD:person.png:45:24,32,40:JOHN SMITH]
          Biography text.
        [/CARD]
      [/CUE]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

    expect(ScriptLinter.lint(source), isEmpty);
  });

  test('valid clip-local SIDECARD cue is not a terminal lint finding', () {
    const String source = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:shot:video/shot.mp4:0:0:300:1]
      [CUE:90]
        [SIDECARD:person.png:45:24,32,40:JOHN SMITH]
          Biography text.
        [/SIDECARD]
      [/CUE]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

    expect(ScriptLinter.lint(source), isEmpty);
  });

  test('unknown terminal-shaped tag is still reported', () {
    final List<LintFinding> findings = ScriptLinter.lint('[NOT_A_TAG:1]');
    expect(findings, hasLength(1));
    expect(findings.single.message, contains('Unknown tag'));
  });
}
