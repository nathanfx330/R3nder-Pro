// ./test/mosaic_layout_lane_ui_test.dart

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/mosaic_surface.dart';
import 'package:r3nder/ui_theme.dart';

const String _source = '''[EDIT:source]
[TRACK:V1]
[CLIP:media:video/source.mp4:0:0:300:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:pane1]
[CLIP:p1:EDIT.source:0:0:300:1]
[/CLIP]
[/PANE]
[PANE:pane2]
[CLIP:p2:EDIT.source:0:0:300:1]
[/CLIP]
[/PANE]
[PANE:pane3]
[CLIP:p3:EDIT.source:0:0:300:1]
[/CLIP]
[/PANE]
[/MOSAIC]
''';

class _Backend implements MediaDecoderBackend {
  @override
  MediaDecoder open(String resolvedPath) => _Decoder();
}

class _Decoder implements MediaDecoder {
  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    return DecodedMediaFrame(
      requestedSourceFrame: requestedSourceFrame,
      actualSourceFrame: requestedSourceFrame,
      width: width,
      height: height,
      stride: width * 4,
      rgba: Uint8List(width * height * 4),
    );
  }

  @override
  void dispose() {}
}

class _Harness extends StatefulWidget {
  final bool playing;

  const _Harness({
    super.key,
    this.playing = false,
  });

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  String source = _source;
  int frame = 40;
  final List<String> changes = <String>[];

  @override
  Widget build(BuildContext context) {
    final R3Theme theme = R3Theme.of(const Color(0xFF00FF00));
    return MaterialApp(
      theme: theme.materialTheme(),
      home: Scaffold(
        body: MosaicSurface(
          source: source,
          mosaicId: 'wall',
          currentFrame: frame,
          isPlaying: widget.playing,
          theme: theme,
          backend: _Backend(),
          resolveSource: (String value) => value,
          onSourceChanged: (String next) {
            changes.add(next);
            setState(() => source = next);
          },
          onSeek: (int next) => setState(() => frame = next),
        ),
      ),
    );
  }
}

Finder _key(String value) => find.byKey(ValueKey<String>(value));

Future<GlobalKey<_HarnessState>> _mount(
  WidgetTester tester, {
  bool playing = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(1500, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GlobalKey<_HarnessState> key = GlobalKey<_HarnessState>();
  await tester.pumpWidget(_Harness(key: key, playing: playing));
  await tester.pump(const Duration(milliseconds: 200));
  return key;
}

Future<void> _chooseOne(
  WidgetTester tester,
  String paneId,
) async {
  await tester.tap(_key('mosaic-layout-add-one'));
  await tester.pumpAndSettle();
  await tester.tap(_key('mosaic-layout-one:$paneId'));
  await tester.pumpAndSettle();
}

Future<void> _chooseFull(
  WidgetTester tester,
  String paneId,
) async {
  await tester.tap(_key('mosaic-layout-add-full'));
  await tester.pumpAndSettle();
  await tester.tap(_key('mosaic-layout-full:$paneId'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shared LAYOUT lane starts as implicit COMPOSITE',
      (WidgetTester tester) async {
    await _mount(tester);

    expect(_key('mosaic-layout-lane'), findsOneWidget);
    expect(find.text('LAYOUT CUES'), findsOneWidget);
    expect(find.text('IMPLICIT COMPOSITE'), findsOneWidget);
    expect(_key('mosaic-layout-add-composite'), findsOneWidget);
    expect(_key('mosaic-layout-add-twoup'), findsOneWidget);
    expect(_key('mosaic-layout-add-one'), findsOneWidget);
    expect(_key('mosaic-layout-add-full'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('mosaic-layout-cue:40')),
        findsNothing);
  });

  testWidgets('COMPOSITE authors an absolute cue at the playhead',
      (WidgetTester tester) async {
    final GlobalKey<_HarnessState> host = await _mount(tester);

    await tester.tap(_key('mosaic-layout-add-composite'));
    await tester.pumpAndSettle();

    expect(
      host.currentState!.source,
      contains('[LAYOUT:40:COMPOSITE]'),
    );
    expect(_key('mosaic-layout-cue:40'), findsOneWidget);
    expect(find.text('1 CUE'), findsOneWidget);
  });

  testWidgets('ONE and FULL use explicit pane ids and replace same-frame cue',
      (WidgetTester tester) async {
    final GlobalKey<_HarnessState> host = await _mount(tester);

    await _chooseOne(tester, 'pane2');
    expect(
      host.currentState!.source,
      contains('[LAYOUT:40:ONE:PANE=pane2]'),
    );

    await _chooseFull(tester, 'pane3');
    expect(
      host.currentState!.source,
      contains('[LAYOUT:40:FULL:PANE=pane3]'),
    );
    expect(
      host.currentState!.source,
      isNot(contains('[LAYOUT:40:ONE:PANE=pane2]')),
    );
    expect(
      RegExp(r'\[LAYOUT:40:').allMatches(host.currentState!.source),
      hasLength(1),
    );
  });

  testWidgets('TWO UP authors pair, aspect, and MAX in MOSAIC',
      (WidgetTester tester) async {
    final GlobalKey<_HarnessState> host = await _mount(tester);

    await tester.tap(_key('mosaic-layout-add-twoup'));
    await tester.pumpAndSettle();
    expect(find.text('Two Up'), findsOneWidget);

    await tester.tap(_key('mosaic-layout-twoup-b'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('pane3').last);
    await tester.pumpAndSettle();

    await tester.tap(_key('mosaic-layout-twoup-aspect'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('4:3').last);
    await tester.pumpAndSettle();

    await tester.tap(_key('mosaic-layout-twoup-max'));
    await tester.pump();

    await tester.tap(_key('mosaic-layout-twoup-apply'));
    await tester.pumpAndSettle();

    expect(
      host.currentState!.source,
      contains(
        '[LAYOUT:40:TWOUP:A=pane1:B=pane3:MAX:ASPECT=4X3]',
      ),
    );
  });

  testWidgets('marker edits frame and DUR through source-backed API',
      (WidgetTester tester) async {
    final GlobalKey<_HarnessState> host = await _mount(tester);
    await _chooseOne(tester, 'pane1');

    await tester.tap(_key('mosaic-layout-cue:40'));
    await tester.pumpAndSettle();

    await tester.enterText(_key('mosaic-layout-edit-frame'), '55');
    await tester.enterText(_key('mosaic-layout-edit-duration'), '18');
    await tester.tap(_key('mosaic-layout-edit-apply'));
    await tester.pumpAndSettle();

    expect(
      host.currentState!.source,
      contains('[LAYOUT:55:ONE:PANE=pane1:DUR=18]'),
    );
    expect(_key('mosaic-layout-cue:40'), findsNothing);
    expect(_key('mosaic-layout-cue:55'), findsOneWidget);
  });

  testWidgets('marker delete removes the authored cue',
      (WidgetTester tester) async {
    final GlobalKey<_HarnessState> host = await _mount(tester);
    await _chooseFull(tester, 'pane1');

    await tester.tap(_key('mosaic-layout-cue:40'));
    await tester.pumpAndSettle();
    await tester.tap(_key('mosaic-layout-edit-delete'));
    await tester.pumpAndSettle();

    expect(host.currentState!.source, isNot(contains('[LAYOUT:')));
    expect(_key('mosaic-layout-cue:40'), findsNothing);
    expect(find.text('IMPLICIT COMPOSITE'), findsOneWidget);
  });

  testWidgets('layout authoring controls are disabled during playback',
      (WidgetTester tester) async {
    await _mount(tester, playing: true);

    expect(
      tester
          .widget<R3Button>(_key('mosaic-layout-add-composite'))
          .onPressed,
      isNull,
    );
    expect(
      tester.widget<PopupMenuButton<String>>(
        _key('mosaic-layout-add-one'),
      ).enabled,
      isFalse,
    );
    expect(
      tester.widget<PopupMenuButton<String>>(
        _key('mosaic-layout-add-full'),
      ).enabled,
      isFalse,
    );
    expect(
      tester.widget<InkWell>(_key('mosaic-layout-add-twoup')).onTap,
      isNull,
    );
  });
}
