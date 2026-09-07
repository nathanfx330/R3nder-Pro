// ./test/editor_structural_fullscreen_palette_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/editor_tag_menu.dart';
import 'package:r3nder/script_nodes.dart';

TagSnippet _snippet(String label) =>
    kAllTags.singleWhere((TagSnippet snippet) => snippet.label == label);

ScriptNode _structFrom(TagSnippet snippet) => parseScriptToNodes(snippet.insertText)
    .singleWhere((ScriptNode node) => node.type == 'STRUCT');

void main() {
  test('tag palette stays internally valid with STRUCT placement choices', () {
    expect(debugValidateTagPalette(), isTrue);
  });

  test('GUI offers windowed and fullscreen video MOSAIC placement choices', () {
    final TagSnippet windowed = _snippet('STRUCT MOSAIC');
    final TagSnippet fullscreen = _snippet('STRUCT MOSAIC FULL SCREEN');

    expect(windowed.insertText, '[STRUCT:MOSAIC.wall]');
    expect(fullscreen.insertText, '[STRUCT:MOSAIC.wall:FULL]');

    final ScriptNode windowedNode = _structFrom(windowed);
    final ScriptNode fullscreenNode = _structFrom(fullscreen);

    expect(windowedNode.param('source'), 'MOSAIC.wall');
    expect(windowedNode.param('mode'), isEmpty);
    expect(fullscreenNode.param('source'), 'MOSAIC.wall');
    expect(fullscreenNode.param('mode'), 'FULL');
  });
}
