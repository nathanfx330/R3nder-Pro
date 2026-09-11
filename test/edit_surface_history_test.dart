// ./test/edit_surface_history_test.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_surface.dart';
import 'package:r3nder/ui_theme.dart';

const String _source = '''[EDIT:main]\n  [TRACK:V1]\n    [CLIP:intro:video/intro.mp4:10:20:40:1]\n      [#UNKNOWN:KEEP:ME]\n    [/CLIP]\n    [CLIP:later:video/later.mp4:90:0:20:1]\n    [/CLIP]\n  [/TRACK]\n  [TRACK:V2]\n    [CLIP:overlay:video/overlay.mp4:25:5:30:2]\n    [/CLIP]\n  [/TRACK]\n[/EDIT]\n''';

const String _externalSource = '''[EDIT:main]\n  [TRACK:V1]\n    [CLIP:intro:video/intro.mp4:12:20:40:1]\n      [#UNKNOWN:EXTERNAL:BRANCH]\n    [/CLIP]\n    [CLIP:later:video/later.mp4:90:0:20:1]\n    [/CLIP]\n  [/TRACK]\n  [TRACK:V2]\n    [CLIP:overlay:video/overlay.mp4:25:5:30:2]\n    [/CLIP]\n  [/TRACK]\n[/EDIT]\n''';

class _HistoryHarness extends StatefulWidget {
  final bool withTextField;

  const _HistoryHarness({this.withTextField = false});

  @override
  State<_HistoryHarness> createState() => _HistoryHarnessState();
}

class _HistoryHarnessState extends State<_HistoryHarness> {
  String source = _source;

  void replaceExternally(String next) {
    setState(() => source = next);
  }

  @override
  Widget build(BuildContext context) {
    final R3Theme theme = R3Theme.of(const Color(0xFF00FF00));
    return MaterialApp(
      theme: theme.materialTheme(),
      home: Scaffold(
        body: SizedBox(
          width: 1280,
          height: 720,
          child: Column(
            children: [
              if (widget.withTextField)
                const SizedBox(
                  height: 42,
                  child: TextField(
                    key: ValueKey<String>('outside-history-text-field'),
                  ),
                ),
              Expanded(
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
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _deleteIntro(WidgetTester tester) async {
  await tester.tap(find.text('intro').first);
  await tester.pump();
  await tester.tap(
    find.byKey(const ValueKey<String>('edit-inspector-delete')),
  );
  await tester.pumpAndSettle();
}

Future<void> _sendControlZ(
  WidgetTester tester, {
  bool shift = false,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  }
  await tester.sendKeyDownEvent(LogicalKeyboardKey.keyZ);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.keyZ);
  if (shift) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  }
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('delete undo restores exact authored bytes and clip selection',
      (WidgetTester tester) async {
    final GlobalKey<_HistoryHarnessState> key =
        GlobalKey<_HistoryHarnessState>();
    await tester.pumpWidget(_HistoryHarness(key: key));
    await tester.pumpAndSettle();

    await _deleteIntro(tester);
    expect(key.currentState!.source, isNot(contains('[CLIP:intro:')));

    await tester.tap(find.byKey(const ValueKey<String>('edit-undo')));
    await tester.pumpAndSettle();

    expect(key.currentState!.source, _source);
    expect(key.currentState!.source, contains('[#UNKNOWN:KEEP:ME]'));
    final Text selected = tester.widget<Text>(
      find.byKey(const ValueKey<String>('edit-inspector-clip-id')),
    );
    expect(selected.data, 'intro');

    await tester.tap(find.byKey(const ValueKey<String>('edit-redo')));
    await tester.pumpAndSettle();

    expect(key.currentState!.source, isNot(contains('[CLIP:intro:')));
    expect(
      find.byKey(const ValueKey<String>('edit-inspector-empty')),
      findsOneWidget,
    );
  });

  testWidgets('Ctrl Z and Ctrl Shift Z navigate EDIT source history',
      (WidgetTester tester) async {
    final GlobalKey<_HistoryHarnessState> key =
        GlobalKey<_HistoryHarnessState>();
    await tester.pumpWidget(_HistoryHarness(key: key));
    await tester.pumpAndSettle();

    await _deleteIntro(tester);
    expect(key.currentState!.source, isNot(_source));

    await _sendControlZ(tester);
    expect(key.currentState!.source, _source);

    await _sendControlZ(tester, shift: true);
    expect(key.currentState!.source, isNot(contains('[CLIP:intro:')));
  });

  testWidgets('new EDIT mutation after undo clears redo branch',
      (WidgetTester tester) async {
    final GlobalKey<_HistoryHarnessState> key =
        GlobalKey<_HistoryHarnessState>();
    await tester.pumpWidget(_HistoryHarness(key: key));
    await tester.pumpAndSettle();

    await _deleteIntro(tester);
    await tester.tap(find.byKey(const ValueKey<String>('edit-undo')));
    await tester.pumpAndSettle();
    expect(key.currentState!.source, _source);

    await tester.tap(find.text('overlay').first);
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('edit-inspector-delete')),
    );
    await tester.pumpAndSettle();
    final String branched = key.currentState!.source;
    expect(branched, contains('[CLIP:intro:'));
    expect(branched, isNot(contains('[CLIP:overlay:')));

    final InkWell redo = tester.widget<InkWell>(
      find.byKey(const ValueKey<String>('edit-redo')),
    );
    expect(redo.onTap, isNull);
  });

  testWidgets('Ctrl Z is ignored while an outside text field owns focus',
      (WidgetTester tester) async {
    final GlobalKey<_HistoryHarnessState> key =
        GlobalKey<_HistoryHarnessState>();
    await tester.pumpWidget(_HistoryHarness(key: key, withTextField: true));
    await tester.pumpAndSettle();

    await _deleteIntro(tester);
    final String deleted = key.currentState!.source;

    await tester.tap(
      find.byKey(const ValueKey<String>('outside-history-text-field')),
    );
    await tester.pump();
    await _sendControlZ(tester);

    expect(key.currentState!.source, deleted);
  });

  testWidgets('external source replacement clears stale EDIT history',
      (WidgetTester tester) async {
    final GlobalKey<_HistoryHarnessState> key =
        GlobalKey<_HistoryHarnessState>();
    await tester.pumpWidget(_HistoryHarness(key: key));
    await tester.pumpAndSettle();

    await _deleteIntro(tester);
    key.currentState!.replaceExternally(_externalSource);
    await tester.pumpAndSettle();

    expect(key.currentState!.source, _externalSource);
    final InkWell undo = tester.widget<InkWell>(
      find.byKey(const ValueKey<String>('edit-undo')),
    );
    expect(undo.onTap, isNull);
  });
}
