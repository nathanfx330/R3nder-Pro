// ./test/edit_linter_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_linter.dart';
import 'package:r3nder/edit_model.dart';

EditDocumentModel _parse(String source) => EditDocumentModel.parse(source);

void main() {
  test('acyclic nested edit graph within ceiling is valid', () {
    final EditDocumentModel model = _parse('''[EDIT:a]
[TRACK:V1]
[CLIP:ab:EDIT.b:0:0:10:1][/CLIP]
[/TRACK]
[/EDIT]
[EDIT:b]
[TRACK:V1]
[CLIP:bc:EDIT.c:0:0:10:1][/CLIP]
[/TRACK]
[/EDIT]
[EDIT:c]
[/EDIT]
''');

    final EditLintResult result = EditGraphLinter.lint(model, maxNesting: 3);
    expect(result.isValid, isTrue);
    expect(result.issues, isEmpty);
  });

  test('cycle detection belongs to the edit graph linter', () {
    final EditDocumentModel model = _parse('''[EDIT:a]
[TRACK:V1]
[CLIP:ab:EDIT.b:0:0:10:1][/CLIP]
[/TRACK]
[/EDIT]
[EDIT:b]
[TRACK:V1]
[CLIP:ba:EDIT.a:0:0:10:1][/CLIP]
[/TRACK]
[/EDIT]
''');

    final EditLintResult result = EditGraphLinter.lint(model);
    expect(result.isValid, isFalse);
    expect(
      result.issues.any((EditLintIssue issue) => issue.code == EditLintCode.cycle),
      isTrue,
    );
  });

  test('nesting ceiling is enforced before rendering', () {
    final EditDocumentModel model = _parse('''[EDIT:a]
[TRACK:V1]
[CLIP:ab:EDIT.b:0:0:10:1][/CLIP]
[/TRACK]
[/EDIT]
[EDIT:b]
[TRACK:V1]
[CLIP:bc:EDIT.c:0:0:10:1][/CLIP]
[/TRACK]
[/EDIT]
[EDIT:c]
[/EDIT]
''');

    final EditLintResult result = EditGraphLinter.lint(model, maxNesting: 2);
    expect(result.isValid, isFalse);
    expect(
      result.issues.any(
        (EditLintIssue issue) => issue.code == EditLintCode.nestingLimit,
      ),
      isTrue,
    );
  });

  test('missing nested edit reference is reported by the linter', () {
    final EditDocumentModel model = _parse('''[EDIT:a]
[TRACK:V1]
[CLIP:missing:EDIT.nowhere:0:0:10:1][/CLIP]
[/TRACK]
[/EDIT]
''');

    final EditLintResult result = EditGraphLinter.lint(model);
    expect(result.isValid, isFalse);
    expect(
      result.issues.single.code,
      EditLintCode.missingEditSource,
    );
    expect(result.issues.single.editPath, <String>['a', 'nowhere']);
  });
}
