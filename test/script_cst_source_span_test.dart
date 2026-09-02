// ./test/script_cst_source_span_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/script_nodes.dart';

String _compose(List<ScriptNode> nodes) =>
    nodes.map((ScriptNode node) => node.toMarkup()).join();

void main() {
  test('source spans tile the emitted document exactly', () {
    const String source = '''[SPEED:MAX]\n\nAlpha\n[PAUSE:30]\nOmega\n''';

    final List<ScriptNode> nodes = parseScriptToNodes(source);
    assignNodeSourceSpans(nodes);

    expect(_compose(nodes), source);
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

  test('source spans recompute after one node changes length', () {
    const String source = '''BEFORE\n[PAUSE:3]\nAFTER\n''';

    final List<ScriptNode> nodes = parseScriptToNodes(source);
    final ScriptNode pause =
        nodes.singleWhere((ScriptNode node) => node.type == 'PAUSE');

    pause.set('frames', '120');
    assignNodeSourceSpans(nodes);

    const String expected = '''BEFORE\n[PAUSE:120]\nAFTER\n''';
    expect(_compose(nodes), expected);

    for (final ScriptNode node in nodes) {
      expect(
        expected.substring(node.startOffset, node.endOffset),
        node.toMarkup(),
      );
    }
  });
}
