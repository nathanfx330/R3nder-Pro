// ./test/script_pipeline_blank_line_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/parser.dart';
import 'package:r3nder/script_pipeline.dart';

void main() {
  test('editor line markers preserve authored blank terminal rows', () {
    const String source = 'Alpha\n\nBeta';

    final CompiledScript compiled =
        compileScript(source, lineMarkers: true);

    expect(
      compiled.engineText,
      '[LINE:0]Alpha\n\n[LINE:2]Beta',
    );

    expect(
      ScriptParser.preprocessScript(compiled.engineText),
      '[LINE:0]Alpha\n\n[LINE:2]Beta',
    );
  });

  test('whitespace-only authored row still remains visible spacing', () {
    const String source = 'Alpha\n   \nBeta';

    final CompiledScript compiled =
        compileScript(source, lineMarkers: true);

    expect(
      compiled.engineText,
      '[LINE:0]Alpha\n   \n[LINE:2]Beta',
    );
  });

  test('projection-only structural rows remain zero-time editor metadata', () {
    const String source = '''[EDIT:main]
[/EDIT]
Alpha
''';

    final CompiledScript compiled =
        compileScript(source, lineMarkers: true);
    final String preprocessed =
        ScriptParser.preprocessScript(compiled.engineText);

    expect(preprocessed, contains('[LINE:2]Alpha'));
    expect(preprocessed, isNot(startsWith('\n')));
    expect(
      preprocessed,
      isNot(contains('\n\n[LINE:2]Alpha')),
      reason:
          'Structural source lines preserve raw coordinates but must not '
          'become visible blank terminal rows.',
    );
  });
}
