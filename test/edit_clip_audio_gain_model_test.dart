// ./test/edit_clip_audio_gain_model_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_linter.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/edit_surface_model.dart';

const String _source = '''PREFIX
[EDIT:main]
  [TRACK:V1]
    [CLIP:intro:video/intro.mp4:10:20:40:1:GAIM=-9.0:GAIN=-8.0:MUTE]
      [#UNKNOWN:KEEP:BODY]
    [/CLIP]
    [CLIP:plain:video/plain.mp4:60:0:20:1]
    [/CLIP]
  [/TRACK]
  [TRACK:V2]
  [/TRACK]
[/EDIT]
SUFFIX
''';

void main() {
  test('absent audio suffix means exact unity gain and audible', () {
    final EditClip clip = EditDocumentModel.parse(_source)
        .edit('main')
        .track('V1')
        .clip('plain');

    expect(clip.audioGain, ClipAudioGain.unity);
    expect(clip.audioGain.tenthsDb, 0);
    expect(clip.muted, isFalse);
    expect(clip.optionTokens, isEmpty);
  });

  test('GAIN and MUTE parse after the six canonical CLIP fields', () {
    final EditClip clip = EditDocumentModel.parse(_source)
        .edit('main')
        .track('V1')
        .clip('intro');

    expect(clip.id, 'intro');
    expect(clip.source, 'video/intro.mp4');
    expect(clip.atFrame, 10);
    expect(clip.inFrame, 20);
    expect(clip.durationFrames, 40);
    expect(clip.speed, ExactClipSpeed(1));
    expect(clip.audioGain, ClipAudioGain.parse('-8.0'));
    expect(clip.muted, isTrue);
    expect(
      clip.optionTokens,
      <String>['GAIM=-9.0', 'GAIN=-8.0', 'MUTE'],
    );
  });

  test('unknown suffix is preserved and linted as a nonblocking warning', () {
    final EditDocumentModel model = EditDocumentModel.parse(_source);
    final EditLintResult lint = EditGraphLinter.lint(model);

    expect(lint.isValid, isTrue);
    final List<EditLintIssue> warnings = lint.warnings.toList();
    expect(warnings, hasLength(1));
    expect(warnings.single.code, EditLintCode.unknownClipOption);
    expect(warnings.single.severity, EditLintSeverity.warning);
    expect(warnings.single.message, contains('GAIM'));
  });

  test('gain edit rewrites only GAIN token and preserves unknown suffix and body', () {
    final EditSurfaceDocument document =
        EditSurfaceDocument.parse(_source, 'main');
    final String next = document.setAudioGain(
      'V1',
      'intro',
      ClipAudioGain.parse('-6.0'),
    );

    expect(
      next,
      contains(
        '[CLIP:intro:video/intro.mp4:10:20:40:1:'
        'GAIM=-9.0:GAIN=-6.0:MUTE]',
      ),
    );
    expect(next, contains('[#UNKNOWN:KEEP:BODY]'));
    expect(next.startsWith('PREFIX\n'), isTrue);
    expect(next.endsWith('SUFFIX\n'), isTrue);
  });

  test('unity removes GAIN while MUTE and unknown options remain authored', () {
    final EditSurfaceDocument document =
        EditSurfaceDocument.parse(_source, 'main');
    final String next =
        document.setAudioGain('V1', 'intro', ClipAudioGain.unity);
    final EditSurfaceClip clip =
        EditSurfaceDocument.parse(next, 'main').clip('V1', 'intro');

    expect(clip.audioGain, ClipAudioGain.unity);
    expect(clip.muted, isTrue);
    expect(clip.clip.optionTokens, <String>['GAIM=-9.0', 'MUTE']);
  });

  test('mute toggles without destroying the authored gain', () {
    final EditSurfaceDocument document =
        EditSurfaceDocument.parse(_source, 'main');
    final String unmuted = document.setMuted('V1', 'intro', false);
    final EditSurfaceClip afterUnmute =
        EditSurfaceDocument.parse(unmuted, 'main').clip('V1', 'intro');

    expect(afterUnmute.muted, isFalse);
    expect(afterUnmute.audioGain, ClipAudioGain.parse('-8.0'));
    expect(unmuted, contains('GAIM=-9.0:GAIN=-8.0]'));

    final String remuted =
        EditSurfaceDocument.parse(unmuted, 'main').setMuted('V1', 'intro', true);
    final EditSurfaceClip afterRemute =
        EditSurfaceDocument.parse(remuted, 'main').clip('V1', 'intro');
    expect(afterRemute.muted, isTrue);
    expect(afterRemute.audioGain, ClipAudioGain.parse('-8.0'));
  });

  test('geometry edit preserves every suffix token byte for byte', () {
    final EditSurfaceDocument document =
        EditSurfaceDocument.parse(_source, 'main');
    final String next = document.moveClip('V1', 'intro', 25);

    expect(
      next,
      contains(
        '[CLIP:intro:video/intro.mp4:25:20:40:1:'
        'GAIM=-9.0:GAIN=-8.0:MUTE]',
      ),
    );
  });

  test('move to another track and split preserve clip-local audio options', () {
    final EditSurfaceDocument document =
        EditSurfaceDocument.parse(_source, 'main');
    final String moved = document.moveClipToTrack('V1', 'intro', 'V2', 10);
    final EditSurfaceDocument movedDoc =
        EditSurfaceDocument.parse(moved, 'main');
    final EditSurfaceClip movedClip = movedDoc.clip('V2', 'intro');

    expect(movedClip.audioGain, ClipAudioGain.parse('-8.0'));
    expect(movedClip.muted, isTrue);
    expect(
      movedClip.clip.optionTokens,
      <String>['GAIM=-9.0', 'GAIN=-8.0', 'MUTE'],
    );

    final String split = movedDoc.splitClip('V2', 'intro', 30);
    final EditSurfaceDocument splitDoc =
        EditSurfaceDocument.parse(split, 'main');
    for (final String id in <String>['intro', 'intro_2']) {
      final EditSurfaceClip piece = splitDoc.clip('V2', id);
      expect(piece.audioGain, ClipAudioGain.parse('-8.0'));
      expect(piece.muted, isTrue);
      expect(
        piece.clip.optionTokens,
        <String>['GAIM=-9.0', 'GAIN=-8.0', 'MUTE'],
      );
    }
  });

  test('gain bounds, duplicate options, and malformed known keys fail', () {
    expect(() => ClipAudioGain.parse('-60.0'), returnsNormally);
    expect(() => ClipAudioGain.parse('12.0'), returnsNormally);
    expect(() => ClipAudioGain.parse('-60.1'), throwsFormatException);
    expect(() => ClipAudioGain.parse('12.1'), throwsFormatException);

    const List<String> invalid = <String>[
      'GAIN=-6.0:GAIN=-3.0',
      'MUTE:MUTE',
      'GAIN',
      'GAIN=',
      'MUTE=true',
    ];
    for (final String suffix in invalid) {
      final String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:a:video/a.mp4:0:0:1:1:$suffix]
[/CLIP]
[/TRACK]
[/EDIT]
''';
      expect(
        () => EditDocumentModel.parse(source),
        throwsA(isA<EditLanguageFormatException>()),
        reason: 'Known malformed suffix should fail: $suffix',
      );
    }
  });
}
