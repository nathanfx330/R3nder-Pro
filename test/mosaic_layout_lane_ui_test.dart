// ./test/mosaic_layout_lane_ui_test.dart

import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_video_preview.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/mosaic_split_geometry.dart';
import 'package:r3nder/mosaic_surface.dart';
import 'package:r3nder/structural_mosaic_layout_preview.dart';
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

final String _source4 = _source.replaceFirst(
  '[/MOSAIC]\n',
  '''[PANE:pane4]
[CLIP:p4:EDIT.source:0:0:300:1]
[/CLIP]
[/PANE]
[/MOSAIC]
''',
);

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
  final String initialSource;

  const _Harness({
    super.key,
    this.playing = false,
    this.initialSource = _source,
  });

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late String source;
  int frame = 40;
  final List<String> changes = <String>[];

  @override
  void initState() {
    super.initState();
    source = widget.initialSource;
  }

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
  String source = _source,
}) async {
  await tester.binding.setSurfaceSize(const Size(1500, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GlobalKey<_HarnessState> key = GlobalKey<_HarnessState>();
  await tester.pumpWidget(
    _Harness(
      key: key,
      playing: playing,
      initialSource: source,
    ),
  );
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
  testWidgets('COME IN ON defaults to implicit COMPOSITE',
      (WidgetTester tester) async {
    await _mount(tester);

    expect(_key('mosaic-layout-lane'), findsOneWidget);
    expect(find.text('COME IN ON'), findsOneWidget);
    expect(_key('mosaic-layout-come-in-on'), findsOneWidget);
    expect(_key('mosaic-layout-start-bar'), findsOneWidget);
    expect(find.text('LAYOUT CUES'), findsOneWidget);
    expect(find.text('NO TRANSITIONS'), findsOneWidget);
    expect(
      tester.widget<Text>(_key('mosaic-layout-start-status')).data,
      'DEFAULT',
    );
    expect(_key('mosaic-layout-add-composite'), findsOneWidget);
    expect(_key('mosaic-layout-add-twoup'), findsOneWidget);
    expect(_key('mosaic-layout-add-overview'), findsOneWidget);
    expect(_key('mosaic-layout-add-one'), findsOneWidget);
    expect(_key('mosaic-layout-add-full'), findsOneWidget);
  });

  testWidgets('COME IN ON authors initial state outside cue timeline',
      (WidgetTester tester) async {
    final GlobalKey<_HarnessState> host = await _mount(tester);
    expect(host.currentState!.frame, 40);

    await tester.tap(_key('mosaic-layout-come-in-on'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ONE · pane2').last);
    await tester.pumpAndSettle();

    expect(
      host.currentState!.source,
      contains('[LAYOUT_START:ONE:PANE=pane2]'),
    );
    expect(host.currentState!.source, isNot(contains('[LAYOUT:0:')));
    expect(_key('mosaic-layout-cue:0'), findsNothing);
    expect(find.text('NO TRANSITIONS'), findsOneWidget);
    expect(
      tester.widget<Text>(_key('mosaic-layout-start-status')).data,
      'INITIAL STATE',
    );
    expect(host.currentState!.frame, 40);
    expect(find.byType(StructuralMosaicLayoutPreview), findsOneWidget);
  });

  testWidgets('COME IN ON TWO UP reuses pair aspect and MAX authoring',
      (WidgetTester tester) async {
    final GlobalKey<_HarnessState> host = await _mount(tester);

    await tester.tap(_key('mosaic-layout-come-in-on'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('TWO UP…').last);
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
        '[LAYOUT_START:TWOUP:A=pane1:B=pane3:MAX:ASPECT=4X3]',
      ),
    );
    expect(host.currentState!.source, isNot(contains('[LAYOUT:0:')));
    expect(host.currentState!.frame, 40);
  });

  testWidgets('legacy F0 cue stays visible until COME IN ON migrates it',
      (WidgetTester tester) async {
    final String source = _source.replaceFirst(
      '[MOSAIC:wall]\n',
      '[MOSAIC:wall]\n[LAYOUT:0:ONE:PANE=pane1]\n',
    );
    final GlobalKey<_HarnessState> host =
        await _mount(tester, source: source);

    expect(_key('mosaic-layout-cue:0'), findsOneWidget);
    expect(
      tester.widget<Text>(_key('mosaic-layout-start-status')).data,
      'LEGACY F0 CUE',
    );

    await tester.tap(_key('mosaic-layout-come-in-on'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ONE · pane2').last);
    await tester.pumpAndSettle();

    expect(
      host.currentState!.source,
      contains('[LAYOUT_START:ONE:PANE=pane2]'),
    );
    expect(host.currentState!.source, isNot(contains('[LAYOUT:0:')));
    expect(_key('mosaic-layout-cue:0'), findsNothing);
    expect(find.text('NO TRANSITIONS'), findsOneWidget);
  });

  testWidgets('MOSAIC viewer switches to layout-aware actor Preview after cue',
      (WidgetTester tester) async {
    final GlobalKey<_HarnessState> host = await _mount(tester);

    expect(find.byType(EditVideoPreview), findsWidgets);
    expect(find.byType(StructuralMosaicLayoutPreview), findsNothing);

    await _chooseOne(tester, 'pane1');

    expect(
      host.currentState!.source,
      contains('[LAYOUT:40:ONE:PANE=pane1]'),
    );
    expect(find.byType(StructuralMosaicLayoutPreview), findsOneWidget);
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

  testWidgets('OVERVIEW authors MAIN +2 and cue-local aspect',
      (WidgetTester tester) async {
    final GlobalKey<_HarnessState> host = await _mount(tester);

    await tester.tap(_key('mosaic-layout-add-overview'));
    await tester.pumpAndSettle();
    expect(find.text('Overview'), findsOneWidget);

    await tester.tap(_key('mosaic-layout-overview-main'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('pane2').last);
    await tester.pumpAndSettle();

    await tester.tap(_key('mosaic-layout-overview-other-1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('pane1').last);
    await tester.pumpAndSettle();

    await tester.tap(_key('mosaic-layout-overview-aspect'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('4:3').last);
    await tester.pumpAndSettle();

    await tester.tap(_key('mosaic-layout-overview-apply'));
    await tester.pumpAndSettle();

    expect(
      host.currentState!.source,
      contains(
        '[LAYOUT:40:OVERVIEW:MAIN=pane2:'
        'OTHERS=pane1,pane3:ASPECT=4X3]',
      ),
    );
    expect(_key('mosaic-layout-cue:40'), findsOneWidget);
  });

  testWidgets('OVERVIEW +3 authors ordered third thumbnail on four-pane MOSAIC',
      (WidgetTester tester) async {
    final GlobalKey<_HarnessState> host =
        await _mount(tester, source: _source4);

    await tester.tap(_key('mosaic-layout-add-overview'));
    await tester.pumpAndSettle();
    await tester.tap(_key('mosaic-layout-overview-third'));
    await tester.pump();
    expect(_key('mosaic-layout-overview-other-3'), findsOneWidget);

    await tester.tap(_key('mosaic-layout-overview-apply'));
    await tester.pumpAndSettle();

    expect(
      host.currentState!.source,
      contains(
        '[LAYOUT:40:OVERVIEW:MAIN=pane1:'
        'OTHERS=pane2,pane3,pane4]',
      ),
    );
  });

  testWidgets('OVERVIEW rejects duplicate MAIN/thumbnail selection in dialog',
      (WidgetTester tester) async {
    final GlobalKey<_HarnessState> host = await _mount(tester);

    await tester.tap(_key('mosaic-layout-add-overview'));
    await tester.pumpAndSettle();

    await tester.tap(_key('mosaic-layout-overview-other-1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('pane1').last);
    await tester.pumpAndSettle();

    final TextButton apply = tester.widget<TextButton>(
      _key('mosaic-layout-overview-apply'),
    );
    expect(apply.onPressed, isNull);
    expect(
      find.text('MAIN and thumbnail panes must all be different.'),
      findsOneWidget,
    );
    expect(host.currentState!.changes, isEmpty);
  });

  testWidgets('COME IN ON OVERVIEW authors LAYOUT_START through same dialog',
      (WidgetTester tester) async {
    final GlobalKey<_HarnessState> host = await _mount(tester);

    await tester.tap(_key('mosaic-layout-come-in-on'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OVERVIEW…').last);
    await tester.pumpAndSettle();

    await tester.tap(_key('mosaic-layout-overview-apply'));
    await tester.pumpAndSettle();

    expect(
      host.currentState!.source,
      contains(
        '[LAYOUT_START:OVERVIEW:MAIN=pane1:OTHERS=pane2,pane3]',
      ),
    );
    expect(host.currentState!.source, isNot(contains('[LAYOUT:0:')));
  });

  testWidgets('existing OVERVIEW at playhead reopens prefilled and updates',
      (WidgetTester tester) async {
    final String source = _source.replaceFirst(
      '[MOSAIC:wall]\n',
      '[MOSAIC:wall]\n'
          '[LAYOUT:40:OVERVIEW:MAIN=pane2:OTHERS=pane1,pane3:ASPECT=4X3]\n',
    );
    final GlobalKey<_HarnessState> host =
        await _mount(tester, source: source);

    await tester.tap(_key('mosaic-layout-add-overview'));
    await tester.pumpAndSettle();

    final DropdownButtonFormField<String> main =
        tester.widget<DropdownButtonFormField<String>>(
      _key('mosaic-layout-overview-main'),
    );
    expect(main.initialValue, 'pane2');

    final DropdownButtonFormField<MosaicSplitClientAspect> aspect =
        tester.widget<DropdownButtonFormField<MosaicSplitClientAspect>>(
      _key('mosaic-layout-overview-aspect'),
    );
    expect(aspect.initialValue, MosaicSplitClientAspect.aspect4x3);

    await tester.tap(_key('mosaic-layout-overview-main'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('pane1').last);
    await tester.pumpAndSettle();

    await tester.tap(_key('mosaic-layout-overview-other-1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('pane2').last);
    await tester.pumpAndSettle();

    await tester.tap(_key('mosaic-layout-overview-apply'));
    await tester.pumpAndSettle();

    expect(
      host.currentState!.source,
      contains(
        '[LAYOUT:40:OVERVIEW:MAIN=pane1:'
        'OTHERS=pane2,pane3:ASPECT=4X3]',
      ),
    );
    expect(
      RegExp(r'\[LAYOUT:40:').allMatches(host.currentState!.source),
      hasLength(1),
    );
  });

  testWidgets('long layout lane exposes horizontal scrolling',
      (WidgetTester tester) async {
    final String longSource = _source
        .replaceAll(':300:1]', ':1000:1]')
        .replaceFirst(
          '[MOSAIC:wall]\n',
          '[MOSAIC:wall]\n[LAYOUT:900:FULL:PANE=pane1]\n',
        );

    await _mount(tester, source: longSource);

    final Scrollbar scrollbar = tester.widget<Scrollbar>(
      _key('mosaic-layout-lane-scrollbar'),
    );
    expect(scrollbar.thumbVisibility, isTrue);
    expect(scrollbar.controller, isNotNull);
    expect(_key('mosaic-layout-cue:900'), findsOneWidget);
  });

  testWidgets('drag retimes cue only once on pointer up',
      (WidgetTester tester) async {
    final GlobalKey<_HarnessState> host = await _mount(tester);
    await _chooseOne(tester, 'pane1');

    final int changesBeforeDrag = host.currentState!.changes.length;
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(_key('mosaic-layout-cue:40')),
      kind: PointerDeviceKind.mouse,
    );

    // The first move crosses Flutter's horizontal-drag slop and starts the
    // recognizer. A subsequent pointer move supplies the first drag update.
    await gesture.moveBy(const Offset(24, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();

    expect(host.currentState!.changes, hasLength(changesBeforeDrag));
    expect(host.currentState!.source, contains('[LAYOUT:40:ONE:PANE=pane1]'));

    final Text frameBadge = tester.widget<Text>(
      _key('mosaic-layout-cue-drag-frame:40'),
    );
    final int previewFrame = int.parse(frameBadge.data!.substring(1));
    expect(previewFrame, greaterThan(40));

    await gesture.up();
    await tester.pumpAndSettle();

    expect(host.currentState!.changes, hasLength(changesBeforeDrag + 1));
    expect(
      host.currentState!.source,
      contains('[LAYOUT:$previewFrame:ONE:PANE=pane1]'),
    );
    expect(host.currentState!.source, isNot(contains('[LAYOUT:40:')));
    expect(_key('mosaic-layout-cue:$previewFrame'), findsOneWidget);
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
    expect(
      tester.widget<Text>(_key('mosaic-layout-start-status')).data,
      'DEFAULT',
    );
    expect(find.text('NO TRANSITIONS'), findsOneWidget);
  });


  testWidgets('dead cue remains visible for repair beyond composition end',
      (WidgetTester tester) async {
    final String source = _source.replaceFirst(
      '[MOSAIC:wall]\n',
      '[MOSAIC:wall]\n[LAYOUT:350:FULL:PANE=pane1]\n',
    );
    await _mount(tester, source: source);

    expect(_key('mosaic-layout-cue:350'), findsOneWidget);
  });

  testWidgets('duplicate-frame source renders distinct repair markers',
      (WidgetTester tester) async {
    final String source = _source.replaceFirst(
      '[MOSAIC:wall]\n',
      '[MOSAIC:wall]\n'
          '[LAYOUT:40:ONE:PANE=pane1]\n'
          '[LAYOUT:40:FULL:PANE=pane2]\n',
    );
    await _mount(tester, source: source);

    expect(_key('mosaic-layout-cue:40:0'), findsOneWidget);
    expect(_key('mosaic-layout-cue:40:1'), findsOneWidget);
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
