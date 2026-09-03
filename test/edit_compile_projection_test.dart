// ./test/edit_compile_projection_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/script_pipeline.dart';

void main() {
  test('EDIT blocks stay authored but never reach engine projection', () {
    const String source = '''BEFORE
[EDIT:main]
  [TRACK:V1]
    [CLIP:intro:video/intro.mp4:0:0:30:1]
    [/CLIP]
  [/TRACK]
[/EDIT]
AFTER
''';

    final CompiledScript compiled = compileScript(source);

    expect(compiled.engineText, contains('BEFORE'));
    expect(compiled.engineText, contains('AFTER'));
    expect(compiled.engineText, isNot(contains('[EDIT:main]')));
    expect(compiled.engineText, isNot(contains('[TRACK:V1]')));
    expect(compiled.engineText, isNot(contains('[CLIP:intro')));
    expect(compiled.engineText, isNot(contains('video/intro.mp4')));
  });

  test('EDIT projection preserves raw document line numbers', () {
    const String source = '''BEFORE
[EDIT:main]
  [TRACK:V1]
    [CLIP:intro:video/intro.mp4:0:0:30:1]
    [/CLIP]
  [/TRACK]
[/EDIT]
AFTER
''';

    final CompiledScript compiled = compileScript(source, lineMarkers: true);

    expect(compiled.engineText, contains('[LINE:0]BEFORE'));
    expect(compiled.engineText, contains('[LINE:7]AFTER'));
    expect(compiled.engineText, isNot(contains('video/intro.mp4')));
  });

  test('CONFIG inside EDIT does not become project configuration', () {
    const String source = '''[CONFIG:WINTITLE:OUTSIDE]
[EDIT:main]
  [TRACK:V1]
    [CLIP:intro:video/intro.mp4:0:0:30:1]
      [CONFIG:WINTITLE:INSIDE]
    [/CLIP]
  [/TRACK]
[/EDIT]
READY
''';

    final CompiledScript compiled = compileScript(source);

    expect(compiled.configs['WINTITLE'], 'OUTSIDE');
    expect(compiled.engineText, isNot(contains('INSIDE')));
    expect(compiled.engineText, contains('READY'));
  });
}
