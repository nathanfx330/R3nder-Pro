// ./test/terminal_svg_explicit_age_test.dart

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/engine.dart';
import 'package:r3nder/svg_path.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('SVG and SVGFLASH derive exact chained steps from terminal frame age', () {
    final TerminalEngine terminal = TerminalEngine();

    terminal.setup(
      templateText:
          '[SPEED:MAX][SVG:a.svg:2][SVGFLASH:flash:2:2][SVG:b.svg:3]DONE',
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

    SvgDocument doc() => SvgDocument(
          path: ui.Path()..addRect(const Rect.fromLTWH(0, 0, 1, 1)),
          viewLeft: 0,
          viewTop: 0,
          viewWidth: 1,
          viewHeight: 1,
        );

    terminal.setSvgLibrary(
      <String, SvgDocument>{
        'a.svg': doc(),
        'flash/0.svg': doc(),
        'flash/1.svg': doc(),
        'b.svg': doc(),
      },
      <String, List<String>>{
        'flash': <String>['flash/0.svg', 'flash/1.svg'],
      },
    );

    final List<String> keys = <String>[];
    final List<int> framesLeft = <int>[];
    final List<int> stepIndices = <int>[];
    bool started = false;
    int guard = 0;

    while (guard < 40) {
      terminal.tick();
      guard++;

      final ActiveSvgShow? show = terminal.activeSvg;
      if (show != null) {
        started = true;
        keys.add(show.currentKey);
        framesLeft.add(show.framesLeft);
        stepIndices.add(show.stepIdx);
        continue;
      }

      if (started) break;
    }

    expect(guard, lessThan(40), reason: 'SVG chain failed to complete');

    expect(
      keys,
      <String>[
        'a.svg',
        'a.svg',
        'flash/0.svg',
        'flash/0.svg',
        'flash/1.svg',
        'flash/1.svg',
        'flash/0.svg',
        'flash/0.svg',
        'flash/1.svg',
        'flash/1.svg',
        'b.svg',
        'b.svg',
        'b.svg',
      ],
      reason: 'SVG chain gained a gap or an off-by-one step',
    );

    expect(
      framesLeft,
      <int>[2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 3, 2, 1],
      reason: 'derived framesLeft no longer matches legacy visible timing',
    );

    expect(
      stepIndices,
      <int>[0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 0, 0, 0],
    );

    expect(terminal.activeSvg, isNull);
  });
}
