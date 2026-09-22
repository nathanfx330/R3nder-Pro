// ./test/script_node_structural_split_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/script_nodes.dart';

ScriptNode _structNode(String source) {
  return parseScriptToNodes(source).firstWhere(
    (ScriptNode node) => node.type == 'STRUCT',
  );
}

void main() {
  test('legacy STRUCT keeps split defaults absent on untouched round trip', () {
    const String source = '[STRUCT:MOSAIC.wall]';
    final ScriptNode node = _structNode(source);

    expect(node.param('split'), isEmpty);
    expect(node.param('aspect'), '16X9');
    expect(node.toMarkup(), source);
  });

  test('editing unrelated chrome does not materialize split defaults', () {
    final ScriptNode node = _structNode('[STRUCT:MOSAIC.wall]');

    node.set('title', 'Archive');
    expect(
      node.toMarkup(),
      '[STRUCT:MOSAIC.wall:TITLE="Archive"]',
    );
    expect(node.toMarkup(), isNot(contains('SPLIT')));
    expect(node.toMarkup(), isNot(contains('ASPECT=')));
  });

  test('node serializes canonical SPLIT and authored non-default aspect', () {
    final ScriptNode node = _structNode('[STRUCT:MOSAIC.wall]');

    node.set('split', 'SPLIT');
    expect(node.toMarkup(), '[STRUCT:MOSAIC.wall:SPLIT]');

    node.set('aspect', '4X3');
    expect(
      node.toMarkup(),
      '[STRUCT:MOSAIC.wall:SPLIT:ASPECT=4X3]',
    );
  });

  test('turning split off removes presentation syntax without leaking aspect',
      () {
    final ScriptNode node = _structNode(
      '[STRUCT:MOSAIC.wall:SPLIT:ASPECT=9X16]',
    );

    node.set('split', '');
    expect(node.toMarkup(), '[STRUCT:MOSAIC.wall]');
    expect(node.toMarkup(), isNot(contains('ASPECT=')));
  });

  test('FULL and SPLIT node state serialize exclusively when controls clear peer',
      () {
    final ScriptNode node = _structNode('[STRUCT:MOSAIC.wall:SPLIT]');

    node.set('split', '');
    node.set('mode', 'FULL');
    expect(node.toMarkup(), '[STRUCT:MOSAIC.wall:FULL]');

    node.set('mode', '');
    node.set('split', 'SPLIT');
    expect(node.toMarkup(), '[STRUCT:MOSAIC.wall:SPLIT]');
  });
}
