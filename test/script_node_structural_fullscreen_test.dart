// ./test/script_node_structural_fullscreen_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/script_nodes.dart';

ScriptNode _structNode(String source) {
  return parseScriptToNodes(source)
      .singleWhere((ScriptNode node) => node.type == 'STRUCT');
}

void main() {
  test('STRUCT node parser reconstructs windowed and fullscreen placement', () {
    final ScriptNode windowed = _structNode('[STRUCT:MOSAIC.wall]');
    final ScriptNode fullscreen = _structNode('[STRUCT:MOSAIC.wall:FULL]');

    expect(windowed.param('source'), 'MOSAIC.wall');
    expect(windowed.param('mode'), isEmpty);
    expect(windowed.toMarkup(), '[STRUCT:MOSAIC.wall]');

    expect(fullscreen.param('source'), 'MOSAIC.wall');
    expect(fullscreen.param('mode'), 'FULL');
    expect(fullscreen.toMarkup(), '[STRUCT:MOSAIC.wall:FULL]');
  });

  test('STRUCT fullscreen mode serializes as a reversible placement toggle', () {
    final ScriptNode node = _structNode('[STRUCT:MOSAIC.wall]');

    node.set('mode', 'FULL');
    expect(node.toMarkup(), '[STRUCT:MOSAIC.wall:FULL]');

    final ScriptNode reparsedFull = _structNode(node.toMarkup());
    expect(reparsedFull.param('mode'), 'FULL');

    reparsedFull.set('mode', '');
    expect(reparsedFull.toMarkup(), '[STRUCT:MOSAIC.wall]');

    final ScriptNode reparsedWindow = _structNode(reparsedFull.toMarkup());
    expect(reparsedWindow.param('mode'), isEmpty);
  });

  test('STRUCT EDIT placement uses the same fullscreen presentation flag', () {
    final ScriptNode node = _structNode('[STRUCT:EDIT.cut:FULL]');

    expect(node.param('source'), 'EDIT.cut');
    expect(node.param('mode'), 'FULL');
    expect(node.toMarkup(), '[STRUCT:EDIT.cut:FULL]');
  });
}
