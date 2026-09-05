// ./test/editor_screen_compile_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/editor_screen.dart';

void main() {
  test('EditorScreen library compiles with structural sequence preview bridge', () {
    final EditorScreen editor = EditorScreen(
      templatePath: '/tmp/test.r3nder',
      initialText: '',
      fontFamily: 'monospace',
      fontColor: Colors.green,
      bgColor: Colors.black,
      engineWidth: 1920,
      engineHeight: 1080,
      engineScale: 1,
      fontSize: 24,
      lineSpacing: 1,
      tracking: 0,
      marginTop: 40,
      marginSide: 40,
      imagesDir: '/tmp/images',
      spritesDir: '/tmp/sprites',
      onClose: (_) {},
    );

    expect(editor.initialText, isEmpty);
    expect(editor.engineWidth, 1920);
  });
}
