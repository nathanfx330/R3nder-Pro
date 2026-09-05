// ./test/structural_sequence_letterbox_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/structural_sequence.dart';
import 'package:r3nder/structural_sequence_preview.dart';
import 'package:r3nder/ui_theme.dart';

const String _source = '''[MOSAIC:wall]
[PANE:pane1]
[CLIP:base:video/base.mp4:0:10:20:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall]
''';

void main() {
  testWidgets('structural terminal returns to fitted 16:9 render frame',
      (WidgetTester tester) async {
    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(_source).single;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            key: const ValueKey<String>('outer-preview'),
            width: 800,
            height: 500,
            child: StructuralSequencePreview(
              rawDocument: _source,
              placement: placement,
              localFrame: placement.durationFrames - 1,
              isPlaying: false,
              theme: R3Theme.of(Colors.green),
              wallpaper: null,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Rect outer = tester.getRect(
      find.byKey(const ValueKey<String>('outer-preview')),
    );
    final Rect terminal = tester.getRect(
      find.byKey(const ValueKey<String>('structural-terminal-window')),
    );
    final Rect desktop = tester.getRect(
      find.byKey(const ValueKey<String>('structural-desktop-positioned')),
    );

    expect(outer.width, closeTo(800.0, 0.01));
    expect(outer.height, closeTo(500.0, 0.01));

    expect(terminal.width, closeTo(800.0, 0.01));
    expect(terminal.height, closeTo(450.0, 0.01));
    expect(terminal.center.dx, closeTo(outer.center.dx, 0.01));
    expect(terminal.center.dy, closeTo(outer.center.dy, 0.01));
    expect(terminal.top - outer.top, closeTo(25.0, 0.01));
    expect(outer.bottom - terminal.bottom, closeTo(25.0, 0.01));

    expect(desktop.left, closeTo(terminal.left, 0.01));
    expect(desktop.top, closeTo(terminal.top, 0.01));
    expect(desktop.width, closeTo(terminal.width, 0.01));
    expect(desktop.height, closeTo(terminal.height, 0.01));

    expect(
      find.byKey(const ValueKey<String>('structural-terminal-title-bar')),
      findsNothing,
    );
  });
}
