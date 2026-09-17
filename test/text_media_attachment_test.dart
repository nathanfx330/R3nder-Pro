// ./test/text_media_attachment_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_media_import.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/script_nodes.dart';
import 'package:r3nder/structural_sequence.dart';
import 'package:r3nder/text_media_attachment.dart';

const ImportedEditVideo _media = ImportedEditVideo(
  authoredSource: 'video/interview.mp4',
  resolvedPath: '/workspace/video/interview.mp4',
  clipBaseId: 'interview',
  durationFrames: 100,
  sourceLengthFrames: 80,
  speedNumerator: 4,
  speedDenominator: 5,
  sourceFpsNumerator: 24,
  sourceFpsDenominator: 1,
);

ScriptNode _firstText(String source) {
  final List<ScriptNode> nodes = parseScriptToNodes(source);
  assignNodeSourceSpans(nodes);
  return nodes.firstWhere((ScriptNode node) => node.type == 'TEXT');
}

void main() {
  test(
    'attaches media after the selected TEXT through STRUCT and one-clip EDIT',
    () {
      const String source =
          '''Narration text\n[PAUSE:12]\n[EDIT:existing]\n  [TRACK:V1]\n    [CLIP:a:video/a.mp4:0:0:30:1]\n    [/CLIP]\n  [/TRACK]\n[/EDIT]\n''';
      final ScriptNode text = _firstText(source);

      final TextMediaAttachmentResult result = attachProjectMediaToText(
        source: source,
        textStartOffset: text.startOffset,
        textEndOffset: text.endOffset,
        media: _media,
      );

      expect(
        result.document,
        startsWith('Narration text\n[STRUCT:EDIT.interview]\n[PAUSE:12]\n'),
      );
      expect(result.editId, 'interview');
      expect(result.clipId, 'interview');
      expect(result.structuralSource, 'EDIT.interview');
      expect(
        result.document,
        contains('[CLIP:interview:video/interview.mp4:0:0:100:4/5]'),
      );

      final EditDocumentModel model = EditDocumentModel.parse(result.document);
      expect(model.edit('existing').track('V1').clip('a').durationFrames, 30);
      expect(
        model.edit('interview').track('V1').clip('interview').speed.toString(),
        '4/5',
      );

      final List<StructuralSequencePlacement> placements =
          parseStructuralSequencePlacements(result.document);
      expect(placements, hasLength(1));
      expect(placements.single.sourceRef.canonicalSource, 'EDIT.interview');
      expect(placements.single.sourceDurationFrames, 100);
    },
  );

  test('EDIT id collision is resolved without changing existing source', () {
    const String source =
        '''Words\n[EDIT:interview]\n  [TRACK:V1]\n    [CLIP:old:video/old.mp4:0:0:10:1]\n    [/CLIP]\n  [/TRACK]\n[/EDIT]\n''';
    final ScriptNode text = _firstText(source);

    final TextMediaAttachmentResult result = attachProjectMediaToText(
      source: source,
      textStartOffset: text.startOffset,
      textEndOffset: text.endOffset,
      media: _media,
    );

    expect(result.editId, 'interview_2');
    expect(result.structuralSource, 'EDIT.interview_2');
    expect(result.document, contains('[EDIT:interview]\n'));
    expect(result.document, contains('[CLIP:old:video/old.mp4:0:0:10:1]'));
    expect(result.document, contains('[EDIT:interview_2]\n'));
  });

  test('attachment preserves CRLF and makes STRUCT a standalone line', () {
    const String source = 'Words\r\n[PAUSE:3]\r\n';
    final ScriptNode text = _firstText(source);

    final TextMediaAttachmentResult result = attachProjectMediaToText(
      source: source,
      textStartOffset: text.startOffset,
      textEndOffset: text.endOffset,
      media: _media,
    );

    expect(
      result.document,
      startsWith('Words\r\n[STRUCT:EDIT.interview]\r\n[PAUSE:3]\r\n'),
    );
    expect(RegExp(r'(?<!\r)\n').hasMatch(result.document), isFalse);
  });

  test(
    'TEXT without a trailing newline gains only the line breaks required by STRUCT',
    () {
      const String source = 'Words';
      final ScriptNode text = _firstText(source);

      final TextMediaAttachmentResult result = attachProjectMediaToText(
        source: source,
        textStartOffset: text.startOffset,
        textEndOffset: text.endOffset,
        media: _media,
      );

      expect(
        result.document,
        startsWith('Words\n[STRUCT:EDIT.interview]\n[EDIT:interview]\n'),
      );
    },
  );

  test('non-TEXT source span is rejected', () {
    const String source = '[PAUSE:5]\nWords\n';
    final List<ScriptNode> nodes = parseScriptToNodes(source);
    assignNodeSourceSpans(nodes);
    final ScriptNode pause = nodes.firstWhere(
      (ScriptNode node) => node.type == 'PAUSE',
    );

    expect(
      () => attachProjectMediaToText(
        source: source,
        textStartOffset: pause.startOffset,
        textEndOffset: pause.endOffset,
        media: _media,
      ),
      throwsStateError,
    );
  });
}
