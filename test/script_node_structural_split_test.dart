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
    expect(node.param('showPaneNames'), isEmpty);
    expect(node.param('pane1Name'), isEmpty);
    expect(node.param('pane2Name'), isEmpty);
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
    expect(node.toMarkup(), isNot(contains(':MAX')));
    expect(node.toMarkup(), isNot(contains('PANENAMES')));
    expect(node.toMarkup(), isNot(contains('NAME1=')));
    expect(node.toMarkup(), isNot(contains('NAME2=')));
  });

  test('pane names survive hide/show and remain dormant outside SPLIT', () {
    final ScriptNode node = _structNode(
      '[STRUCT:MOSAIC.wall:SPLIT:NAME1="Camera A":NAME2="Witness"]',
    );

    expect(node.param('showPaneNames'), isEmpty);
    expect(node.param('pane1Name'), 'Camera A');
    expect(node.param('pane2Name'), 'Witness');

    node.set('showPaneNames', 'PANENAMES');
    expect(
      node.toMarkup(),
      '[STRUCT:MOSAIC.wall:SPLIT:PANENAMES:NAME1="Camera A":NAME2="Witness"]',
    );

    node.set('showPaneNames', '');
    expect(
      node.toMarkup(),
      '[STRUCT:MOSAIC.wall:SPLIT:NAME1="Camera A":NAME2="Witness"]',
    );

    node.set('split', '');
    expect(
      node.toMarkup(),
      '[STRUCT:MOSAIC.wall:NAME1="Camera A":NAME2="Witness"]',
    );

    node.set('split', 'SPLIT');
    node.set('showPaneNames', 'PANENAMES');
    expect(
      node.toMarkup(),
      '[STRUCT:MOSAIC.wall:SPLIT:PANENAMES:NAME1="Camera A":NAME2="Witness"]',
    );
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

  test('node round-trips MAX split and preserves dormant aspect', () {
    final ScriptNode node = _structNode(
      '[STRUCT:MOSAIC.wall:SPLIT:MAX:ASPECT=4X3]',
    );

    expect(node.param('split'), 'SPLIT');
    expect(node.param('maxSplit'), 'MAX');
    expect(node.param('aspect'), '4X3');
    expect(
      node.toMarkup(),
      '[STRUCT:MOSAIC.wall:SPLIT:MAX:ASPECT=4X3]',
    );

    node.set('maxSplit', '');
    expect(
      node.toMarkup(),
      '[STRUCT:MOSAIC.wall:SPLIT:ASPECT=4X3]',
    );

    node.set('maxSplit', 'MAX');
    expect(
      node.toMarkup(),
      '[STRUCT:MOSAIC.wall:SPLIT:MAX:ASPECT=4X3]',
    );
  });

  test('turning split off removes presentation syntax without leaking aspect',
      () {
    final ScriptNode node = _structNode(
      '[STRUCT:MOSAIC.wall:SPLIT:MAX:ASPECT=9X16]',
    );

    node.set('split', '');
    node.set('maxSplit', '');
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
