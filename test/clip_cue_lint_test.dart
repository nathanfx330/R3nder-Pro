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

  test('valid clip-local DOSSIER cue is not a terminal lint finding', () {
    const String source = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:shot:video/shot.mp4:0:0:300:1]
      [CUE:90]
        [DOSSIER:evidence:person.png:45:60:12:MOSAIC:24,32,40:JOHN SMITH]
          Biography text.
        [/DOSSIER]
      [/CUE]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

    expect(ScriptLinter.lint(source), isEmpty);
  });

  test('valid PANEL inside CARD is lint-clean', () {
    const String source = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:shot:video/shot.mp4:0:0:300:1]
      [CUE:90]
        [CARD:person.png:45:24,32,40:JOHN SMITH]
          [PANEL]
          PRESET: DOCUMENTARY
          FONT: DejaVu Sans
          SUBTITLE: Reporter: Investigations
          META: RANGE | 1990 | 1995
          [/PANEL]
          Biography text.
        [/CARD]
      [/CUE]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

    expect(ScriptLinter.lint(source), isEmpty);
  });

  test('valid PANEL inside SIDECARD is lint-clean', () {
    const String source = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:shot:video/shot.mp4:0:0:300:1]
      [CUE:90]
        [SIDECARD:person.png:45:24,32,40:JOHN SMITH]
          [PANEL]
          PRESET: DOCUMENTARY
          META: ORGANIZATION | Example News
          [/PANEL]
          Biography text.
        [/SIDECARD]
      [/CUE]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

    expect(ScriptLinter.lint(source), isEmpty);
  });

  test('missing PANEL close is reported at the opener', () {
    const String source = '''[CARD:person.png:45:24,32,40:JOHN SMITH]
[PANEL]
PRESET: DOCUMENTARY
Biography text.
[/CARD]''';

    final List<LintFinding> findings = ScriptLinter.lint(source);
    expect(
      findings.any(
        (LintFinding finding) =>
            finding.line == 2 && finding.message.contains('never closed'),
      ),
      isTrue,
    );
  });

  test('unknown PANEL key is reported as preserved and ignored', () {
    const String source = '''[CARD:person.png:45:24,32,40:JOHN SMITH]
[PANEL]
PRESET: DOCUMENTARY
PRESETT: DOCUMENTARY
[/PANEL]
Biography.
[/CARD]''';

    final List<LintFinding> findings = ScriptLinter.lint(source);
    final LintFinding finding = findings.singleWhere(
      (LintFinding finding) => finding.snippet == 'PRESETT: DOCUMENTARY',
    );
    expect(finding.line, 4);
    expect(finding.message, contains('preserved but ignored'));
  });

  test('malformed PANEL META is reported instead of silently dropped', () {
    const String source = '''[CARD:person.png:45:24,32,40:JOHN SMITH]
[PANEL]
PRESET: DOCUMENTARY
META: BROKEN ROW
[/PANEL]
Biography.
[/CARD]''';

    final List<LintFinding> findings = ScriptLinter.lint(source);
    final LintFinding finding = findings.singleWhere(
      (LintFinding finding) => finding.snippet == 'META: BROKEN ROW',
    );
    expect(finding.line, 4);
    expect(finding.message, contains('LABEL | VALUE'));
  });

  test('unknown terminal-shaped tag is still reported', () {
    final List<LintFinding> findings = ScriptLinter.lint('[NOT_A_TAG:1]');
    expect(findings, hasLength(1));
    expect(findings.single.message, contains('Unknown tag'));
  });
}
