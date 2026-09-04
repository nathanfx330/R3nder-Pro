// ./test/script_cst_nested_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/script_cst.dart';
import 'package:r3nder/script_nodes.dart';

String _composeNodes(List<ScriptNode> nodes) =>
    nodes.map((ScriptNode node) => node.toMarkup()).join();

void main() {
  const String source = '''[# source before edit]
[EDIT:main]
  edit-prefix:  keep   spacing
  [TRACK:V1]
    track-prefix = untouched
    [CLIP:intro]
      source = "video.mp4"
      at = 90
      in = 24
      duration = 180
      speed = 1
    [/CLIP]
    track-suffix = untouched
  [/TRACK]
  edit-suffix: untouched
[/EDIT]
[# source after edit]
''';

  test('EDIT TRACK CLIP forms a three-level exact source tree', () {
    final ScriptCstDocument document = ScriptCstDocument.parse(source);

    expect(document.roots, hasLength(1));
    final ScriptCstBlock edit = document.roots.single;
    final ScriptCstBlock track = edit.children.single;
    final ScriptCstBlock clip = track.children.single;

    expect(edit.type, 'EDIT');
    expect(edit.header, 'main');
    expect(track.type, 'TRACK');
    expect(track.header, 'V1');
    expect(clip.type, 'CLIP');
    expect(clip.header, 'intro');

    expect(track.parent, same(edit));
    expect(clip.parent, same(track));
    expect(clip.ownershipPath, <String>['EDIT', 'TRACK', 'CLIP']);

    expect(edit.rawSource, source.substring(edit.startOffset, edit.endOffset));
    expect(
      track.rawSource,
      source.substring(track.startOffset, track.endOffset),
    );
    expect(clip.rawSource, source.substring(clip.startOffset, clip.endOffset));
    expect(
      clip.innerSource,
      source.substring(clip.openEndOffset, clip.closeStartOffset),
    );
  });

  test('editing the innermost CLIP opening tag preserves all enclosing bytes', () {
    final ScriptCstDocument document = ScriptCstDocument.parse(source);
    final ScriptCstBlock edit = document.roots.single;
    final ScriptCstBlock track = edit.children.single;
    final ScriptCstBlock clip = track.children.single;

    const String replacement = '[CLIP:intro_v2]';
    final String edited = document.replaceOpeningTag(clip, replacement);

    expect(
      edited,
      source.replaceRange(
        clip.startOffset,
        clip.openEndOffset,
        replacement,
      ),
    );

    expect(
      edited.substring(0, clip.startOffset),
      source.substring(0, clip.startOffset),
    );
    expect(
      edited.substring(clip.startOffset + replacement.length),
      source.substring(clip.openEndOffset),
    );

    final ScriptCstDocument reparsed = ScriptCstDocument.parse(edited);
    final ScriptCstBlock reparsedEdit = reparsed.roots.single;
    final ScriptCstBlock reparsedTrack = reparsedEdit.children.single;
    final ScriptCstBlock reparsedClip = reparsedTrack.children.single;

    expect(reparsedEdit.openingTag, edit.openingTag);
    expect(reparsedEdit.closingTag, edit.closingTag);
    expect(reparsedTrack.openingTag, track.openingTag);
    expect(reparsedTrack.closingTag, track.closingTag);
    expect(reparsedClip.header, 'intro_v2');
  });

  test('editing CLIP body preserves TRACK and EDIT source outside that span', () {
    final ScriptCstDocument document = ScriptCstDocument.parse(source);
    final ScriptCstBlock clip = document.blocksOfType('CLIP').single;

    const String newBody = '''
      source = "replacement.mov"
      at = 120
      in = 48
      duration = 180
      speed = 1
    ''';

    final String edited = document.replaceInnerSource(clip, newBody);

    expect(
      edited.substring(0, clip.openEndOffset),
      source.substring(0, clip.openEndOffset),
    );
    expect(
      edited.substring(clip.openEndOffset + newBody.length),
      source.substring(clip.closeStartOffset),
    );

    final ScriptCstDocument reparsed = ScriptCstDocument.parse(edited);
    expect(reparsed.blocksOfType('EDIT'), hasLength(1));
    expect(reparsed.blocksOfType('TRACK'), hasLength(1));
    expect(reparsed.blocksOfType('CLIP'), hasLength(1));
  });

  test('multiple sibling clips retain independent exact spans', () {
    const String siblings = '''[EDIT:main]
[TRACK:V1]
[CLIP:a]
A
[/CLIP]
  untouched between clips
[CLIP:b]
B
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final ScriptCstDocument document = ScriptCstDocument.parse(siblings);
    final List<ScriptCstBlock> clips =
        document.blocksOfType('CLIP').toList(growable: false);

    expect(clips, hasLength(2));
    expect(clips[0].header, 'a');
    expect(clips[1].header, 'b');
    expect(
      siblings.substring(clips[0].endOffset, clips[1].startOffset),
      '\n  untouched between clips\n',
    );
  });

  test('flat node parser keeps EDIT and MOSAIC roots opaque and hidden', () {
    const String mixed = '''BEFORE
[EDIT:main]
  [TRACK:V1]
    [CLIP:a:video/base.mp4:0:0:30:1]
      [PAUSE:99]
    [/CLIP]
  [/TRACK]
[/EDIT]
[PAUSE:12]
[MOSAIC:wall]
  [PANE:left]
    [CLIP:b:EDIT.main:0:0:30:1]
      [SPEED:MAX]
    [/CLIP]
  [/PANE]
[/MOSAIC]
AFTER
''';

    final ScriptCstDocument cst = ScriptCstDocument.parse(mixed);
    final List<ScriptNode> nodes = parseScriptToNodes(mixed);
    final List<ScriptNode> structural = nodes
        .where((ScriptNode node) => node.type == kStructural)
        .toList(growable: false);

    expect(structural, hasLength(2));
    expect(structural.every((ScriptNode node) => !node.isVisible), isTrue);
    expect(structural[0].rawText, cst.roots[0].rawSource);
    expect(structural[1].rawText, cst.roots[1].rawSource);
    expect(_composeNodes(nodes), mixed);

    final List<ScriptNode> pauses = nodes
        .where((ScriptNode node) => node.type == 'PAUSE')
        .toList(growable: false);
    expect(pauses, hasLength(1));
    expect(pauses.single.param('frames'), '12');
    expect(nodes.where((ScriptNode node) => node.type == 'SPEED'), isEmpty);
  });

  test('ordinary node edit cannot rewrite a neighboring structural root', () {
    const String mixed = '''[PAUSE:3]
[EDIT:main]
  [TRACK:V1]
    [CLIP:a:video/base.mp4:0:0:30:1]
    [/CLIP]
  [/TRACK]
[/EDIT]
[PAUSE:7]
''';

    final List<ScriptNode> nodes = parseScriptToNodes(mixed);
    final ScriptNode structural =
        nodes.singleWhere((ScriptNode node) => node.type == kStructural);
    final String owned = structural.rawText;
    final List<ScriptNode> pauses = nodes
        .where((ScriptNode node) => node.type == 'PAUSE')
        .toList(growable: false);

    pauses.last.set('frames', '120');
    final String edited = _composeNodes(nodes);

    expect(structural.rawText, owned);
    expect(edited.contains(owned), isTrue);
    expect(edited, mixed.replaceFirst('[PAUSE:7]', '[PAUSE:120]'));
    expect(
      () => structural.set('anything', 'unsafe'),
      throwsA(isA<StateError>()),
    );
  });

  test('malformed structural text stays available as RAW repair source', () {
    const String malformed = '''[EDIT:main]
  [TRACK:V1]
''';

    final List<ScriptNode> nodes = parseScriptToNodes(malformed);

    expect(nodes.where((ScriptNode node) => node.type == kStructural), isEmpty);
    expect(nodes, hasLength(1));
    expect(nodes.single.type, kRaw);
    expect(nodes.single.isVisible, isTrue);
    expect(_composeNodes(nodes), malformed);
  });

  test('mismatched or illegal structural ownership is rejected', () {
    expect(
      () => ScriptCstDocument.parse(
        '[EDIT:main][TRACK:V1][CLIP:a][/TRACK][/CLIP][/EDIT]',
      ),
      throwsA(isA<ScriptCstFormatException>()),
    );
    expect(
      () => ScriptCstDocument.parse('[TRACK:V1][/TRACK]'),
      throwsA(isA<ScriptCstFormatException>()),
    );
    expect(
      () => ScriptCstDocument.parse(
        '[EDIT:main][CLIP:a][/CLIP][/EDIT]',
      ),
      throwsA(isA<ScriptCstFormatException>()),
    );
    expect(
      () => ScriptCstDocument.parse(
        '[EDIT:main][TRACK:V1][CLIP:a][/CLIP][/EDIT]',
      ),
      throwsA(isA<ScriptCstFormatException>()),
    );
  });
}
