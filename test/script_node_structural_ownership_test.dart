// ./test/script_node_structural_ownership_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/script_cst.dart';
import 'package:r3nder/script_nodes.dart';

String _compose(List<ScriptNode> nodes) =>
    nodes.map((ScriptNode node) => node.toMarkup()).join();

void main() {
  test('valid EDIT and MOSAIC roots become visible protected structural nodes', () {
    const String source = '''[PAUSE:4]\n[EDIT:cut]\n  [TRACK:V1]\n    [CLIP:a:video/a.mp4:0:0:60:1]\n    [/CLIP]\n  [/TRACK]\n[/EDIT]\ntext between\n[MOSAIC:wall]\n  [PANE:left]\n    [CLIP:b:EDIT.cut:0:0:60:1]\n    [/CLIP]\n  [/PANE]\n[/MOSAIC]\n[PAUSE:6]\n''';

    final ScriptCstDocument cst = ScriptCstDocument.parse(source);
    final List<ScriptNode> nodes = parseScriptToNodes(source);
    final List<ScriptNode> structural = nodes
        .where((ScriptNode node) => node.isStructural)
        .toList(growable: false);

    expect(structural, hasLength(2));
    expect(structural.map((ScriptNode node) => node.type), <String>['EDIT', 'MOSAIC']);
    expect(structural[0].toMarkup(), cst.roots[0].rawSource);
    expect(structural[1].toMarkup(), cst.roots[1].rawSource);
    expect(structural.every((ScriptNode node) => node.isVisible), isTrue);
    expect(structural[0].rawText, contains('cut · V1 · 1 CUT · a'));
    expect(structural[1].rawText, contains('wall · 1 PANE · 1 ASSIGNED'));
    expect(_compose(nodes), source);

    assignNodeSourceSpans(nodes);
    expect(nodes.first.startOffset, 0);
    expect(nodes.last.endOffset, source.length);
    for (int i = 0; i < nodes.length; i++) {
      final ScriptNode node = nodes[i];
      expect(source.substring(node.startOffset, node.endOffset), node.toMarkup());
      if (i > 0) {
        expect(node.startOffset, nodes[i - 1].endOffset);
      }
    }
  });

  test('structural roots advance document lines but own no runtime line span', () {
    const String source = '''[PAUSE:4][EDIT:cut]\n[TRACK:V1]\n[CLIP:a:video/a.mp4:0:0:60:1]\n[/CLIP]\n[/TRACK]\n[/EDIT]\n[PAUSE:6]\n''';

    final List<ScriptNode> nodes = parseScriptToNodes(source);
    assignNodeLineSpans(nodes);

    final ScriptNode structural =
        nodes.singleWhere((ScriptNode node) => node.isStructural);
    final List<ScriptNode> pauses = nodes
        .where((ScriptNode node) => node.type == 'PAUSE')
        .toList(growable: false);

    expect(pauses, hasLength(2));
    expect(pauses[0].startLine, 0);
    expect(structural.startLine, -1);
    expect(structural.endLine, -1);
    expect(pauses[1].startLine, 6);
  });

  test('opaque terminal bodies do not become structural nodes', () {
    const String source = '''[CARD:portrait.png]\nliteral [EDIT:fake]\n[/CARD]\n[EDIT:real]\n  [TRACK:V1]\n    [CLIP:a:video/a.mp4:0:0:60:1]\n    [/CLIP]\n  [/TRACK]\n[/EDIT]\n''';

    final List<ScriptNode> nodes = parseScriptToNodes(source);
    final List<ScriptNode> structural = nodes
        .where((ScriptNode node) => node.isStructural)
        .toList(growable: false);

    expect(structural, hasLength(1));
    expect(structural.single.type, 'EDIT');
    expect(structural.single.toMarkup(), contains('[EDIT:real]'));
    expect(structural.single.toMarkup(), isNot(contains('[EDIT:fake]')));
    expect(nodes.any((ScriptNode node) => node.type == 'CARD'), isTrue);
    expect(_compose(nodes), source);
  });

  test('generic edits cannot rewrite protected structural source', () {
    const String source = '''[EDIT:cut]\n  [TRACK:V1]\n    [CLIP:a:video/a.mp4:0:0:60:1]\n    [/CLIP]\n  [/TRACK]\n[/EDIT]\n''';

    final ScriptCstDocument cst = ScriptCstDocument.parse(source);
    final List<ScriptNode> nodes = parseScriptToNodes(source);
    final ScriptNode structural =
        nodes.singleWhere((ScriptNode node) => node.isStructural);

    structural.rawText = 'not structural source';
    structural.dirty = true;
    structural.set('id', 'changed');

    // The protected node owns exactly the CST root. The newline after the
    // closer belongs to the following spacer node so whole-document round
    // trip remains lossless without widening structural ownership.
    expect(structural.toMarkup(), cst.roots.single.rawSource);
    expect(_compose(nodes), source);
  });

  test('malformed structural source falls back to lossless repair text', () {
    const String source = '''before\n[EDIT:broken]\n  [TRACK:V1]\nafter\n''';

    final List<ScriptNode> nodes = parseScriptToNodes(source);

    expect(nodes.where((ScriptNode node) => node.isStructural), isEmpty);
    expect(_compose(nodes), source);
  });
}
