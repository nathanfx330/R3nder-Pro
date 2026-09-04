// ./test/script_cst_root_nesting_contract_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/script_cst.dart';

void main() {
  test('EDIT cannot be literally nested inside MOSAIC source', () {
    const String source = '''[MOSAIC:wall]
[PANE:left]
[CLIP:base:video/base.mp4:0:0:30:1]
[/CLIP]
[/PANE]
[EDIT:nested]
[/EDIT]
[/MOSAIC]
''';

    expect(
      () => ScriptCstDocument.parse(source),
      throwsA(
        isA<ScriptCstFormatException>().having(
          (ScriptCstFormatException error) => error.message,
          'message',
          contains('EDIT cannot be nested'),
        ),
      ),
    );
  });

  test('MOSAIC cannot be literally nested inside EDIT source', () {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:base:video/base.mp4:0:0:30:1]
[/CLIP]
[/TRACK]
[MOSAIC:nested]
[/MOSAIC]
[/EDIT]
''';

    expect(
      () => ScriptCstDocument.parse(source),
      throwsA(
        isA<ScriptCstFormatException>().having(
          (ScriptCstFormatException error) => error.message,
          'message',
          contains('MOSAIC cannot be nested'),
        ),
      ),
    );
  });
}
