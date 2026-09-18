// ./test/edit_cue_span_integration_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_cue.dart';
import 'package:r3nder/edit_surface.dart';
import 'package:r3nder/edit_surface_model.dart';
import 'package:r3nder/ui_theme.dart';

const String _source = '''[EDIT:main]
[TRACK:V1]
[CLIP:shot:video/shot.mp4:0:0:300:1]
[CUE:20][CARD:a.png:0]A[/CARD][/CUE]
[CUE:80][CARD:b.png:0]B[/CARD][/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
''';

class _Harness extends StatefulWidget {
  const _Harness({
    super.key,
    this.playing = false,
  });

  final bool playing;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
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
            currentFrame: 20,
            isPlaying: widget.playing,
            theme: theme,
            onSourceChanged: (String next) {
              setState(() => source = next);
            },
            onSeek: (_) {},
            resolveSource: (String source) => '/definitely/missing/$source',
          ),
        ),
      ),
    );
  }
}

int _firstCueOffset(String source) {
  final EditSurfaceDocument document =
      EditSurfaceDocument.parse(source, 'main');
  return parseClipCardCues(document.clip('V1', 'shot').clip).first.startOffset;
}

void main() {
  testWidgets('cue drag is transient until release and undo is one source edit',
      (WidgetTester tester) async {
    final GlobalKey<_HarnessState> key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key));
    await tester.pumpAndSettle();

    final int offset = _firstCueOffset(key.currentState!.source);
    final Finder handle = find.byKey(
      ValueKey<String>('cue-span-handle-$offset'),
    );
    expect(handle, findsOneWidget);

    final TestGesture gesture =
        await tester.startGesture(tester.getCenter(handle));
    // First cross Flutter's horizontal drag slop. The event that wins the
    // gesture arena is not guaranteed to be delivered as an update delta.
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();

    // The measured update is 30 px = 15 frames at the default 2 px/frame, so
    // the preview is F35. Pointer movement still must not touch source.
    expect(key.currentState!.source, _source);

    await gesture.up();
    await tester.pumpAndSettle();

    expect(key.currentState!.source, contains('[CUE:35]'));
    expect(key.currentState!.source, isNot(contains('[CUE:20]')));

    final Finder undo = find.byKey(const ValueKey<String>('edit-undo'));
    await tester.ensureVisible(undo);
    await tester.tap(undo);
    await tester.pumpAndSettle();

    expect(key.currentState!.source, _source);
  });

  testWidgets('legal cue hard-clamps at next same-lane neighbor',
      (WidgetTester tester) async {
    final GlobalKey<_HarnessState> key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key));
    await tester.pumpAndSettle();

    final int offset = _firstCueOffset(key.currentState!.source);
    final Finder handle = find.byKey(
      ValueKey<String>('cue-span-handle-$offset'),
    );

    // CARD hold 0 occupies 33 frames. With the next cue at F80, the latest
    // legal start is F47. Dragging much farther right must stop there.
    await tester.drag(handle, const Offset(300, 0));
    await tester.pumpAndSettle();

    expect(key.currentState!.source, contains('[CUE:47]'));
    expect(key.currentState!.source, contains('[CUE:80]'));
  });

  testWidgets('cue handles do not author while playback is running',
      (WidgetTester tester) async {
    final GlobalKey<_HarnessState> key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key, playing: true));
    await tester.pumpAndSettle();

    final int offset = _firstCueOffset(key.currentState!.source);
    final Finder handle = find.byKey(
      ValueKey<String>('cue-span-handle-$offset'),
    );
    expect(handle, findsOneWidget);

    await tester.drag(handle, const Offset(60, 0));
    await tester.pumpAndSettle();

    expect(key.currentState!.source, _source);
  });
}
