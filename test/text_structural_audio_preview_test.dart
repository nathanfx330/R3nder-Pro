// ./test/text_structural_audio_preview_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/text_structural_audio_preview.dart';

const String _audioDocument = '''[EDIT:main]
[TRACK:V1]
[CLIP:base:video/base.mp4:0:0:30:1]
[/CLIP]
[/TRACK]
[/EDIT]
[STRUCT:EDIT.main:AUDIO]
''';

const String _silentDocument = '''[EDIT:main]
[TRACK:V1]
[CLIP:base:video/base.mp4:0:0:30:1]
[/CLIP]
[/TRACK]
[/EDIT]
[STRUCT:EDIT.main]
''';

void main() {
  test('TEXT structural audio obeys the STRUCT AUDIO opt-in', () {
    final TextStructuralAudioPreview preview = TextStructuralAudioPreview();
    addTearDown(preview.dispose);

    expect(preview.documentHasClipAudio(_audioDocument), isTrue);
    expect(preview.documentHasClipAudio(_silentDocument), isFalse);
  });
}
