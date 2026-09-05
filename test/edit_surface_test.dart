// ./test/edit_surface_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_surface.dart';
import 'package:r3nder/ui_theme.dart';

const String _source = '''[EDIT:main]\n  [TRACK:V1]\n    [CLIP:intro:video/intro.mp4:10:20:40:1]\n    [/CLIP]\n  [/TRACK]\n  [TRACK:V2]\n    [CLIP:overlay:video/overlay.mp4:25:5:30:1]\n    [/CLIP]\n  [/TRACK]\n[/EDIT]\n''';

Widget _host({
  required ValueChanged<String> onSourceChanged,
  ValueChanged<int>? onSeek,
  int currentFrame = 0,
}) {
  final R3Theme theme = R3Theme.of(const Color(0xFF00FF00));
  return MaterialApp(
    theme: theme.materialTheme(),
    home: Scaffold(
      body: SizedBox(
        width: 1280,
        height: 720,
        child: EditSurface(
          source: _source,
          editId: 'main',
          currentFrame: currentFrame,
          // Workspace audio can still be present upstream. The cut surface
          // deliberately does not draw it as if it were clip-local material.
          voiceFrames: 70,
          musicFrames: 120,
          musicLoops: false,
          theme: theme,
          onSourceChanged: onSourceChanged,
          onSeek: onSeek ?? (_) {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('surface renders only video cut tracks, not composition audio beds',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(onSourceChanged: (_) {}));
    await tester.pumpAndSettle();

    expect(find.text('V2'), findsOneWidget);
    expect(find.text('V1'), findsOneWidget);
    expect(find.text('intro'), findsOneWidget);
    expect(find.text('overlay'), findsOneWidget);
    expect(find.text('A1'), findsNothing);
    expect(find.text('A2'), findsNothing);
    expect(find.text('VOICE'), findsNothing);
    expect(find.text('MUSIC'), findsNothing);
  });

  testWidgets('dragging clip body serializes new at frame into script',
      (WidgetTester tester) async {
    String? changed;
    await tester.pumpWidget(_host(onSourceChanged: (String value) {
      changed = value;
    }));
    await tester.pumpAndSettle();

    await tester.drag(find.text('intro'), const Offset(20, 0));
    await tester.pumpAndSettle();

    expect(changed, isNotNull);
    expect(
      changed,
      contains('[CLIP:intro:video/intro.mp4:20:20:40:1]'),
    );
  });

  testWidgets('split button writes two real CLIP blocks at playhead',
      (WidgetTester tester) async {
    String? changed;
    await tester.pumpWidget(
      _host(
        currentFrame: 30,
        onSourceChanged: (String value) {
          changed = value;
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('intro'));
    await tester.pump();
    expect(find.text('SPLIT'), findsOneWidget);

    await tester.tap(find.text('SPLIT'));
    await tester.pumpAndSettle();

    expect(changed, isNotNull);
    expect(
      changed,
      contains('[CLIP:intro:video/intro.mp4:10:20:20:1]'),
    );
    expect(
      changed,
      contains('[CLIP:intro_2:video/intro.mp4:30:40:20:1]'),
    );
  });

  testWidgets('crossfade controls are owned by clip edges, not the toolbar',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(onSourceChanged: (_) {}));
    await tester.pumpAndSettle();

    expect(find.text('XFADE'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('edit-clip-V1-intro-in-handle')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('edit-clip-V1-intro-out-handle')),
      findsOneWidget,
    );
  });

  testWidgets('ruler drag coalesces a burst of scrub positions',
      (WidgetTester tester) async {
    final List<int> seeks = <int>[];
    await tester.pumpWidget(
      _host(
        onSourceChanged: (_) {},
        onSeek: seeks.add,
      ),
    );
    await tester.pumpAndSettle();

    final Finder ruler =
        find.byKey(const ValueKey<String>('edit-timeline-scrub'));
    expect(ruler, findsOneWidget);
    final Rect rect = tester.getRect(ruler);
    final TestGesture gesture = await tester.startGesture(
      Offset(rect.left + 40, rect.center.dy),
    );

    for (int i = 0; i < 20; i++) {
      await gesture.moveBy(const Offset(4, 0));
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 40));

    expect(seeks, isNotEmpty);
    expect(seeks.length, lessThan(10));
    expect(seeks.last, greaterThan(seeks.first));
  });
}
