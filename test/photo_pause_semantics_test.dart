// ./test/photo_pause_semantics_test.dart

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PHOTO pause begins only after every visible scan is complete', () {
    const int authoredPause = 6;
    final TerminalEngine terminal = TerminalEngine();

    terminal.setup(
      templateText: '''
[SPEED:MAX]
[PHOTO:photo_a.png:30:R:0,255,0:50]
[PHOTO:photo_b.png:30:R:0,255,0:50]
[PAUSE:$authoredPause]
[WIPE]
DONE.
''',
      fontColor: const Color(0xFF00FF00),
      bgColor: const Color(0xFF0A0F0A),
      width: 1920,
      height: 1080,
      scale: 1,
      fontPath: 'monospace',
      fontSize: 32,
      lineSpacing: 40,
      tracking: 0,
      marginTop: 60,
      marginSide: 60,
    );

    final ui.Path oneBitPath = ui.Path()
      ..addRect(const Rect.fromLTWH(0, 0, 1, 1));
    terminal.setImgLibrary(<String, ImgStencil>{
      'R:photo_a.png': ImgStencil(
        pxWidth: 1,
        pxHeight: 1,
        path: oneBitPath,
      ),
      'R:photo_b.png': ImgStencil(
        pxWidth: 1,
        pxHeight: 1,
        path: oneBitPath,
      ),
    });

    int guard = 0;
    while (terminal.pauseFrames == 0 && guard < 200) {
      terminal.tick();
      guard++;

      if (terminal.pauseFrames == 0 && terminal.hasPhotos) {
        // The completed stack may exist before PAUSE is reached, but PAUSE
        // must never start while any visible layer is still scanning.
        final bool anyIncomplete = terminal.photoStack.any(
          (photo) =>
              photo.revealProgressAt(terminal.frameCount) < 1.0,
        );
        if (anyIncomplete) {
          expect(terminal.pauseFrames, 0);
        }
      }
    }

    expect(guard, lessThan(200), reason: 'PHOTO pause was never reached');
    expect(terminal.pauseFrames, authoredPause);
    expect(terminal.hasPhotos, isTrue);
    expect(
      terminal.photoStack.every(
        (photo) => photo.revealProgressAt(terminal.frameCount) >= 1.0,
      ),
      isTrue,
      reason: 'PAUSE began before the PHOTO stack finished drawing',
    );

    // The authored pause holds the fully drawn composite for its entire
    // duration. PHOTO remains visible even on the tick that reaches zero;
    // the following tick consumes WIPE.
    for (int expected = authoredPause - 1; expected >= 0; expected--) {
      terminal.tick();
      expect(terminal.pauseFrames, expected);
      expect(terminal.hasPhotos, isTrue);
      expect(
        terminal.photoStack.every(
          (photo) => photo.revealProgressAt(terminal.frameCount) >= 1.0,
        ),
        isTrue,
      );
    }

    terminal.tick();
    expect(terminal.hasPhotos, isFalse);
  });
}
