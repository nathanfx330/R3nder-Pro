// ./test/script_node_structural_chrome_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/script_nodes.dart';

void main() {
  test('extended STRUCT chrome parses as first-class node state', () {
    const String source =
        '[STRUCT:MOSAIC.wall:FULL:OVERLAY=CUSTOM:'
        'TITLE="Archive: Viewer":TOP="FEB 1972":BOTTOM="REEL 4"]';

    final List<ScriptNode> nodes = parseScriptToNodes(source);
    final ScriptNode node =
        nodes.firstWhere((ScriptNode value) => value.type == 'STRUCT');

    expect(node.param('source'), 'MOSAIC.wall');
    expect(node.param('mode'), 'FULL');
    expect(node.param('overlay'), 'CUSTOM');
    expect(node.param('title'), 'Archive: Viewer');
    expect(node.param('top'), 'FEB 1972');
    expect(node.param('bottom'), 'REEL 4');
    expect(node.toMarkup(), source);
  });

  test('node edits serialize canonical keyed chrome syntax', () {
    final ScriptNode node = parseScriptToNodes('[STRUCT:EDIT.main]').firstWhere(
      (ScriptNode value) => value.type == 'STRUCT',
    );

    node.set('mode', 'FULL');
    node.set('overlay', 'CUSTOM');
    node.set('title', 'Field Monitor');
    node.set('top', 'FEB 1972');
    node.set('bottom', '16MM TRANSFER · REEL 4');

    expect(
      node.toMarkup(),
      '[STRUCT:EDIT.main:FULL:OVERLAY=CUSTOM:'
      'TITLE="Field Monitor":TOP="FEB 1972":'
      'BOTTOM="16MM TRANSFER · REEL 4"]',
    );
  });

  test('switching overlay mode does not destroy dormant custom copy', () {
    final ScriptNode node = parseScriptToNodes(
      '[STRUCT:EDIT.main:OVERLAY=CUSTOM:TOP="TOP COPY":BOTTOM="BOTTOM COPY"]',
    ).firstWhere((ScriptNode value) => value.type == 'STRUCT');

    node.set('overlay', 'NONE');
    expect(
      node.toMarkup(),
      '[STRUCT:EDIT.main:OVERLAY=NONE:TOP="TOP COPY":BOTTOM="BOTTOM COPY"]',
    );

    node.set('overlay', 'CUSTOM');
    expect(
      node.toMarkup(),
      '[STRUCT:EDIT.main:OVERLAY=CUSTOM:TOP="TOP COPY":BOTTOM="BOTTOM COPY"]',
    );
  });

  test('malformed extended STRUCT stays raw instead of guessing', () {
    final List<ScriptNode> nodes = parseScriptToNodes(
      '[STRUCT:MOSAIC.wall:OVERLAY=LOUD]',
    );

    expect(nodes.any((ScriptNode node) => node.type == 'STRUCT'), isFalse);
    expect(nodes.any((ScriptNode node) => node.type == kRaw), isTrue);
  });
}
