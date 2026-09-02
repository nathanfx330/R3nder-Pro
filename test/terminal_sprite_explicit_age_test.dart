// ./test/terminal_sprite_explicit_age_test.dart

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TerminalEngine terminalFor(String script) {
    final TerminalEngine terminal = TerminalEngine();
    terminal.setup(
      templateText: script,
      fontColor: const Color(0xFF00FF00),
      bgColor: const Color(0xFF0A0F0A),
      width: 1280,
      height: 720,
      scale: 1,
      fontPath: 'monospace',
      fontSize: 32,
      lineSpacing: 40,
      tracking: 0,
      marginTop: 60,
      marginSide: 60,
    );
    terminal.setSpriteLibrary(<String, List<List<String>>>{
      'spin': <List<String>>[
        <String>['0'],
        <String>['1'],
        <String>['2'],
      ],
    });
    return terminal;
  }

  String spriteGlyph(TerminalEngine terminal) {
    expect(terminal.renderedLines, isNotEmpty);
    expect(terminal.renderedLines.first.chars, isNotEmpty);
    return terminal.renderedLines.first.chars.first.char;
  }

  test('SPRITE derives frame cadence through PAUSE and freezes on SPRITE_OFF',
      () {
    final TerminalEngine terminal = terminalFor(
      '[SPEED:MAX]'
      '[SPRITE:spin:2]'
      '[PAUSE:7]'
      '[SPRITE_OFF:spin]'
      '[PAUSE:3]',
    );

    terminal.tick(); // Sprite frame 0 commits immediately at terminal frame 1.
    expect(terminal.frameCount, 1);
    expect(spriteGlyph(terminal), '0');

    final List<String> visible = <String>['0'];
    for (int i = 0; i < 8; i++) {
      terminal.tick();
      visible.add(spriteGlyph(terminal));
    }

    expect(
      visible,
      <String>['0', '0', '1', '1', '2', '2', '0', '0', '1'],
    );

    // The next tick materializes the frame for that output, then SPRITE_OFF
    // removes live animation state. The rendered line must freeze there.
    terminal.tick();
    expect(spriteGlyph(terminal), '1');

    for (int i = 0; i < 4; i++) {
      terminal.tick();
      expect(spriteGlyph(terminal), '1');
    }
  });

  test('later persistent PHOTO gate freezes sprite active age exactly', () {
    final TerminalEngine terminal = terminalFor(
      '[SPEED:MAX]'
      '[PHOTO:base.png:1:R:0,255,0:1]'
      '[SPRITE:spin:2]'
      '[PAUSE:3]'
      '[PHOTO:overlay.png:1:R:0,255,0:50]'
      '[PAUSE:4]'
      '[SPRITE_OFF:spin]',
    );

    final ui.Path path = ui.Path()
      ..addRect(const ui.Rect.fromLTWH(0, 0, 1, 1));
    final ImgStencil stencil = ImgStencil(
      pxWidth: 1,
      pxHeight: 1,
      path: path,
    );
    terminal.setImgLibrary(<String, ImgStencil>{
      'R:base.png': stencil,
      'R:overlay.png': stencil,
    });

    // First PHOTO persists and clears the canvas, then releases after one
    // frame so the sprite can be created over the surviving onion layer.
    terminal.tick();
    terminal.tick();
    terminal.tick();
    expect(terminal.frameCount, 3);
    expect(spriteGlyph(terminal), '0');

    // PAUSE keeps sprite animation live. At frame 7 it has reached frame 2.
    for (int i = 0; i < 4; i++) {
      terminal.tick();
    }
    expect(terminal.frameCount, 7);
    expect(spriteGlyph(terminal), '2');

    // This tick advances the sprite once for frame 8, then starts a second
    // persistent PHOTO over the existing onion stack. Its 50% gate is 15
    // frames, during which legacy sprite updates were skipped entirely.
    terminal.tick();
    expect(terminal.frameCount, 8);
    expect(spriteGlyph(terminal), '2');

    for (int i = 0; i < 15; i++) {
      terminal.tick();
      expect(
        spriteGlyph(terminal),
        '2',
        reason: 'sprite advanced inside persistent PHOTO gate at frame '
            '${terminal.frameCount}',
      );
    }
    expect(terminal.frameCount, 23);

    // First eligible terminal tick after the gate resumes from the exact
    // pre-gate phase: frame 2 had one hold tick accumulated, so it wraps to 0.
    terminal.tick();
    expect(terminal.frameCount, 24);
    expect(spriteGlyph(terminal), '0');
  });

  test('SPRITE explicit-age sequence replays exactly after reset', () {
    final TerminalEngine terminal = terminalFor(
      '[SPEED:MAX][SPRITE:spin:3][PAUSE:10][SPRITE_OFF:spin]',
    );

    List<String> collect() {
      terminal.reset();
      final List<String> out = <String>[];
      for (int i = 0; i < 12; i++) {
        terminal.tick();
        if (terminal.renderedLines.isNotEmpty) {
          out.add(spriteGlyph(terminal));
        }
      }
      return out;
    }

    final List<String> first = collect();
    final List<String> replay = collect();

    expect(first, replay);
    expect(first, containsAllInOrder(<String>['0', '1', '2', '0']));
  });
}
