// ./test/script_node_structural_sequence_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/script_nodes.dart';

void main() {
  test('STRUCT placement is a visible sequence node and round trips exactly', () {
    const String source = '''intro\n[EDIT:cut]\n[TRACK:V1]\n[CLIP:a:video/a.mp4:0:0:24:1]\n[/CLIP]\n[/TRACK]\n[/EDIT]\n[STRUCT:EDIT.cut]\noutro\n''';

    final List<ScriptNode> nodes = parseScriptToNodes(source);
    final ScriptNode placement =
        nodes.singleWhere((ScriptNode node) => node.type == 'STRUCT');

    expect(placement.isVisible, isTrue);
    expect(placement.isStructural, isFalse);
    expect(placement.param('source'), 'EDIT.cut');
    expect(placement.rawText, '[STRUCT:EDIT.cut]');
    expect(nodes.map((ScriptNode node) => node.toMarkup()).join(), source);
  });

  test('STRUCT raw node edit is preserved by the generic properties seam', () {
    const String source = '[STRUCT:MOSAIC.wall]';
    final ScriptNode placement = parseScriptToNodes(source).single;

    placement.rawText = '[STRUCT:MOSAIC.closeup]';
    placement.dirty = true;

    expect(placement.type, 'STRUCT');
    expect(placement.toMarkup(), '[STRUCT:MOSAIC.closeup]');
  });
}
