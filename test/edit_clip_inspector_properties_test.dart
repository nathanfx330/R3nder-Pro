// ./test/edit_clip_inspector_properties_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_surface.dart';
import 'package:r3nder/ui_theme.dart';

const String _source = '''[EDIT:main]\n  [TRACK:V1]\n    [CLIP:intro:video/intro.mp4:10:20:40:1]\n    [/CLIP]\n  [/TRACK]\n[/EDIT]\n''';

class _InspectorHarness extends StatefulWidget {
  const _InspectorHarness({super.key});

  @override
  State<_InspectorHarness> createState() => _InspectorHarnessState();
}

class _InspectorHarnessState extends State<_InspectorHarness> {
  String source = _source;

  @override
  Widget build(BuildContext context) {
    final R3Theme theme = R3Theme.of(const Color(0xFF00FF00));
    return MaterialApp(
      theme: theme.materialTheme(),
      home: Scaffold(
        body: SizedBox(
          width: 1280,
          height: 720,
          child: EditSurface(
            source: source,
            editId: 'main',
            currentFrame: 0,
            theme: theme,
            onSourceChanged: (String next) {
              setState(() => source = next);
            },
            onSeek: (_) {},
          ),
        ),
      ),
    );
  }
}

Future<void> _selectIntro(WidgetTester tester) async {
  await tester.tap(find.text('intro').first);
  await tester.pumpAndSettle();
}

Future<void> _show(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('slip and speed author through inspector and remain undoable',
      (WidgetTester tester) async {
    final GlobalKey<_InspectorHarnessState> key =
        GlobalKey<_InspectorHarnessState>();
    await tester.pumpWidget(_InspectorHarness(key: key));
    await tester.pumpAndSettle();
    await _selectIntro(tester);

    final Finder slipPlus =
        find.byKey(const ValueKey<String>('edit-inspector-slip-plus'));
    await _show(tester, slipPlus);
    await tester.tap(slipPlus);
    await tester.pumpAndSettle();

    expect(
      key.currentState!.source,
      contains('[CLIP:intro:video/intro.mp4:10:21:40:1]'),
    );

    final Finder speedMenu =
        find.byKey(const ValueKey<String>('edit-inspector-speed-menu'));
    await _show(tester, speedMenu);
    await tester.tap(speedMenu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('2 X'));
    await tester.pumpAndSettle();

    expect(
      key.currentState!.source,
      contains('[CLIP:intro:video/intro.mp4:10:21:40:2]'),
    );

    await tester.tap(find.byKey(const ValueKey<String>('edit-undo')));
    await tester.pumpAndSettle();
    expect(
      key.currentState!.source,
      contains('[CLIP:intro:video/intro.mp4:10:21:40:1]'),
    );
  });

  testWidgets('incoming and outgoing crossfades author through inspector',
      (WidgetTester tester) async {
    final GlobalKey<_InspectorHarnessState> key =
        GlobalKey<_InspectorHarnessState>();
    await tester.pumpWidget(_InspectorHarness(key: key));
    await tester.pumpAndSettle();
    await _selectIntro(tester);

    final Finder incoming =
        find.byKey(const ValueKey<String>('edit-inspector-transition-in-menu'));
    await _show(tester, incoming);
    await tester.tap(incoming);
    await tester.pumpAndSettle();
    await tester.tap(find.text('CROSSFADE 12 FRAMES'));
    await tester.pumpAndSettle();

    expect(
      key.currentState!.source,
      contains('[#EDIT_TRANSITION:CROSSFADE:12]'),
    );

    final Finder outgoing =
        find.byKey(const ValueKey<String>('edit-inspector-transition-out-menu'));
    await _show(tester, outgoing);
    await tester.tap(outgoing);
    await tester.pumpAndSettle();
    await tester.tap(find.text('CROSSFADE 24 FRAMES'));
    await tester.pumpAndSettle();

    expect(
      key.currentState!.source,
      contains('[#EDIT_TRANSITION_OUT:CROSSFADE:24]'),
    );
    expect(
      find.byKey(
        const ValueKey<String>('edit-clip-V1-intro-in-transition'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey<String>('edit-clip-V1-intro-out-transition'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('incoming transition can switch from crossfade to luma',
      (WidgetTester tester) async {
    final GlobalKey<_InspectorHarnessState> key =
        GlobalKey<_InspectorHarnessState>();
    await tester.pumpWidget(_InspectorHarness(key: key));
    await tester.pumpAndSettle();
    await _selectIntro(tester);

    final Finder incoming =
        find.byKey(const ValueKey<String>('edit-inspector-transition-in-menu'));
    await _show(tester, incoming);
    await tester.tap(incoming);
    await tester.pumpAndSettle();
    await tester.tap(find.text('CROSSFADE 12 FRAMES'));
    await tester.pumpAndSettle();

    await _show(tester, incoming);
    await tester.tap(incoming);
    await tester.pumpAndSettle();
    await tester.tap(find.text('LUMA…'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('edit-inspector-luma-source')),
      'wipes/soft.png',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('edit-inspector-luma-frames')),
      '10',
    );
    await tester.tap(find.text('APPLY'));
    await tester.pumpAndSettle();

    expect(
      key.currentState!.source,
      contains('[#EDIT_TRANSITION:LUMA:wipes/soft.png:10]'),
    );
    expect(
      key.currentState!.source,
      isNot(contains('[#EDIT_TRANSITION:CROSSFADE:12]')),
    );
    expect(find.text('LUMA 10F'), findsOneWidget);
    expect(find.text('wipes/soft.png'), findsOneWidget);
  });
}
