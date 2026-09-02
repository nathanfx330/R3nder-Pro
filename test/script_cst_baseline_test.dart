// ./test/script_cst_baseline_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/script_nodes.dart';

String _compose(List<ScriptNode> nodes) =>
    nodes.map((ScriptNode node) => node.toMarkup()).join();

void main() {
  test('node model round-trips mixed source byte for byte', () {
    const String source = '''[# preserved comment]
[SPEED:MAX]

Alpha text
[PAUSE:30]

[DEF_MENU:choice]
[ITEM:A:Alpha]
[ITEM:B:Beta]
[/DEF_MENU]

[CARD:portrait.png:240:30,30,38:PROFILE]
Body text with [GREEN]inline markup[NORMAL].
[/CARD]

[MACRO_CFG:choice:A:0,255,0:0]
[CALL:choice]
Trailing text
''';

    final List<ScriptNode> nodes = parseScriptToNodes(source);

    expect(_compose(nodes), source);
    expect(nodes.any((ScriptNode n) => n.isSpacer), isTrue);
    expect(nodes.any((ScriptNode n) => n.type == 'DEF_MENU'), isTrue);
    expect(nodes.any((ScriptNode n) => n.type == 'CARD'), isTrue);
  });

  test('editing one node rewrites only that source slice', () {
    const String source = '''[SPEED:2]

BEFORE
[PAUSE:30]
AFTER
''';

    final List<ScriptNode> nodes = parseScriptToNodes(source);
    final ScriptNode pause =
        nodes.singleWhere((ScriptNode n) => n.type == 'PAUSE');

    pause.set('frames', '75');

    expect(
      _compose(nodes),
      '''[SPEED:2]

BEFORE
[PAUSE:75]
AFTER
''',
    );
  });

  test('line spans derive from emitted source without changing it', () {
    const String source = '''FIRST
[PAUSE:12]

SECOND
''';

    final List<ScriptNode> nodes = parseScriptToNodes(source);
    assignNodeLineSpans(nodes);

    expect(_compose(nodes), source);

    for (int i = 1; i < nodes.length; i++) {
      expect(nodes[i].startLine, greaterThanOrEqualTo(nodes[i - 1].startLine));
    }
  });
}
