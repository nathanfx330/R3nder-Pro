// ./test/edit_model_validation_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_model.dart';

void main() {
  test('speed accepts exact decimal and rational spellings', () {
    expect(ExactClipSpeed.parse('0.5'), ExactClipSpeed(1, 2));
    expect(ExactClipSpeed.parse('1.25'), ExactClipSpeed(5, 4));
    expect(ExactClipSpeed.parse('30000/1001'), ExactClipSpeed(30000, 1001));
  });

  test('zero or negative duration and speed are rejected', () {
    const String zeroDuration = '''[EDIT:main]
[TRACK:V1]
[CLIP:a:a.mp4:0:0:0:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';
    const String zeroSpeed = '''[EDIT:main]
[TRACK:V1]
[CLIP:a:a.mp4:0:0:30:0]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    expect(
      () => EditDocumentModel.parse(zeroDuration),
      throwsA(isA<EditLanguageFormatException>()),
    );
    expect(
      () => EditDocumentModel.parse(zeroSpeed),
      throwsA(isA<EditLanguageFormatException>()),
    );
  });
}
