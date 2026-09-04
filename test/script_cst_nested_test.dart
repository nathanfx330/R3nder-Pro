// ./test/script_cst_nested_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/script_cst.dart';

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

  const String mosaicSource = '''before mosaic
[MOSAIC:wall]
  mosaic-prefix = untouched
  [PANE:left]
    pane-prefix = untouched
    [CLIP:a:EDIT.interview:0:0:300:1]
      clip-body = untouched
    [/CLIP]
    pane-suffix = untouched
  [/PANE]
  mosaic-suffix = untouched
[/MOSAIC]
after mosaic
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

  test('MOSAIC PANE CLIP forms a three-level exact source tree', () {
    final ScriptCstDocument document = ScriptCstDocument.parse(mosaicSource);

    expect(document.roots, hasLength(1));
    final ScriptCstBlock mosaic = document.roots.single;
    final ScriptCstBlock pane = mosaic.children.single;
    final ScriptCstBlock clip = pane.children.single;

    expect(mosaic.type, 'MOSAIC');
    expect(mosaic.header, 'wall');
    expect(pane.type, 'PANE');
    expect(pane.header, 'left');
    expect(clip.type, 'CLIP');
    expect(clip.header, 'a:EDIT.interview:0:0:300:1');

    expect(pane.parent, same(mosaic));
    expect(clip.parent, same(pane));
    expect(clip.ownershipPath, <String>['MOSAIC', 'PANE', 'CLIP']);

    expect(
      mosaic.rawSource,
      mosaicSource.substring(mosaic.startOffset, mosaic.endOffset),
    );
    expect(
      pane.rawSource,
      mosaicSource.substring(pane.startOffset, pane.endOffset),
    );
    expect(
      clip.rawSource,
      mosaicSource.substring(clip.startOffset, clip.endOffset),
    );
    expect(
      clip.innerSource,
      mosaicSource.substring(clip.openEndOffset, clip.closeStartOffset),
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

  test('editing a MOSAIC CLIP opening tag preserves PANE and MOSAIC bytes', () {
    final ScriptCstDocument document = ScriptCstDocument.parse(mosaicSource);
    final ScriptCstBlock mosaic = document.roots.single;
    final ScriptCstBlock pane = mosaic.children.single;
    final ScriptCstBlock clip = pane.children.single;

    const String replacement = '[CLIP:a:EDIT.interview:12:4:240:1/2]';
    final String edited = document.replaceOpeningTag(clip, replacement);

    expect(
      edited.substring(0, clip.startOffset),
      mosaicSource.substring(0, clip.startOffset),
    );
    expect(
      edited.substring(clip.startOffset + replacement.length),
      mosaicSource.substring(clip.openEndOffset),
    );

    final ScriptCstDocument reparsed = ScriptCstDocument.parse(edited);
    final ScriptCstBlock reparsedMosaic = reparsed.roots.single;
    final ScriptCstBlock reparsedPane = reparsedMosaic.children.single;
    final ScriptCstBlock reparsedClip = reparsedPane.children.single;

    expect(reparsedMosaic.openingTag, mosaic.openingTag);
    expect(reparsedMosaic.closingTag, mosaic.closingTag);
    expect(reparsedPane.openingTag, pane.openingTag);
    expect(reparsedPane.closingTag, pane.closingTag);
    expect(reparsedClip.openingTag, replacement);
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

  test('owned insertion before PANE closer preserves every surrounding byte', () {
    final ScriptCstDocument document = ScriptCstDocument.parse(mosaicSource);
    final ScriptCstBlock pane = document.blocksOfType('PANE').single;

    const String insertion = '''    [CLIP:b:EDIT.documents:30:0:120:1]
    [/CLIP]
  ''';
    final String edited = document.insertBeforeClosingTag(pane, insertion);

    expect(
      edited.substring(0, pane.closeStartOffset),
      mosaicSource.substring(0, pane.closeStartOffset),
    );
    expect(
      edited.substring(pane.closeStartOffset + insertion.length),
      mosaicSource.substring(pane.closeStartOffset),
    );

    final ScriptCstDocument reparsed = ScriptCstDocument.parse(edited);
    final ScriptCstBlock reparsedPane = reparsed.blocksOfType('PANE').single;
    expect(reparsedPane.children, hasLength(2));
    expect(
      reparsedPane.children.map((ScriptCstBlock block) => block.header),
      <String>[
        'a:EDIT.interview:0:0:300:1',
        'b:EDIT.documents:30:0:120:1',
      ],
    );
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

  test('EDIT and MOSAIC roots retain independent exact spans', () {
    const String mixed = '''lead bytes
[EDIT:cut]
[TRACK:V1]
[CLIP:a:video/a.mp4:0:0:60:1]
[/CLIP]
[/TRACK]
[/EDIT]
bytes between roots
[MOSAIC:wall]
[PANE:left]
[CLIP:b:EDIT.cut:0:0:60:1]
[/CLIP]
[/PANE]
[/MOSAIC]
trail bytes
''';

    final ScriptCstDocument document = ScriptCstDocument.parse(mixed);
    expect(document.roots, hasLength(2));

    final ScriptCstBlock edit = document.roots[0];
    final ScriptCstBlock mosaic = document.roots[1];
    expect(edit.type, 'EDIT');
    expect(mosaic.type, 'MOSAIC');
    expect(
      mixed.substring(edit.endOffset, mosaic.startOffset),
      '\nbytes between roots\n',
    );
    expect(edit.ownershipPath, <String>['EDIT']);
    expect(mosaic.ownershipPath, <String>['MOSAIC']);
  });

  test('opaque terminal and macro bodies do not manufacture structural nodes', () {
    const String opaque = '''[CARD:portrait.png]
CARD copy may literally mention [EDIT:card_fake]
[/CARD]
[DOSSIER:files:portrait.png]
DOSSIER copy may literally mention [MOSAIC:dossier_fake]
[/DOSSIER]
[TIMELINE]
2026 | literal [TRACK:timeline_fake]
[/TIMELINE]
[DEF_MENU:choice]
[ITEM:A]literal [PANE:menu_fake][/ITEM]
[/DEF_MENU]
[# literal [CLIP:comment_fake]
[EDIT:real]
  [TRACK:V1]
    [CLIP:a:video/a.mp4:0:0:60:1]
    [/CLIP]
  [/TRACK]
[/EDIT]
[MOSAIC:real_wall]
  [PANE:left]
    [CLIP:b:EDIT.real:0:0:60:1]
    [/CLIP]
  [/PANE]
[/MOSAIC]
''';

    final ScriptCstDocument document = ScriptCstDocument.parse(opaque);

    expect(document.roots, hasLength(2));
    expect(
      document.roots.map((ScriptCstBlock block) => block.type),
      <String>['EDIT', 'MOSAIC'],
    );
    expect(document.blocksOfType('EDIT'), hasLength(1));
    expect(document.blocksOfType('TRACK'), hasLength(1));
    expect(document.blocksOfType('MOSAIC'), hasLength(1));
    expect(document.blocksOfType('PANE'), hasLength(1));
    expect(document.blocksOfType('CLIP'), hasLength(2));
  });

  test('opaque spans do not hide illegal real structural source after them', () {
    const String malformed = '''[CARD:portrait.png]
literal [EDIT:fake]
[/CARD]
[TRACK:orphan]
[/TRACK]
''';

    expect(
      () => ScriptCstDocument.parse(malformed),
      throwsA(isA<ScriptCstFormatException>()),
    );
  });

  test('blocks from another parse cannot authorize a mutation', () {
    final ScriptCstDocument first = ScriptCstDocument.parse(source);
    final ScriptCstDocument second = ScriptCstDocument.parse(source);
    final ScriptCstBlock foreignClip = first.blocksOfType('CLIP').single;

    expect(
      () => second.replaceOpeningTag(foreignClip, '[CLIP:foreign]'),
      throwsArgumentError,
    );
    expect(
      () => second.insertBeforeClosingTag(foreignClip, 'x'),
      throwsArgumentError,
    );
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
    expect(
      () => ScriptCstDocument.parse(
        '[MOSAIC:wall][TRACK:V1][/TRACK][/MOSAIC]',
      ),
      throwsA(isA<ScriptCstFormatException>()),
    );
    expect(
      () => ScriptCstDocument.parse(
        '[EDIT:main][PANE:left][/PANE][/EDIT]',
      ),
      throwsA(isA<ScriptCstFormatException>()),
    );
  });
}
