// ./test/mosaic_trim_ui_test.dart

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/mosaic_surface.dart';
import 'package:r3nder/mosaic_trim.dart';
import 'package:r3nder/ui_theme.dart';

const String _source = '''[EDIT:source]
[TRACK:V1]
[CLIP:media:video/source.mp4:0:0:300:1][/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:short]
[CLIP:short:EDIT.source:0:0:100:1][/CLIP]
[/PANE]
[PANE:long]
[CLIP:long:EDIT.source:0:0:200:1][/CLIP]
[CLIP:late:EDIT.source:220:0:20:1][/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall]
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
  final String initialSource;
  final bool playing;

  const _Harness({
    super.key,
    this.initialSource = _source,
    this.playing = false,
  });

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late String source = widget.initialSource;
  final List<String> changes = <String>[];
  final MediaDecoderBackend backend = _Backend();

  void replaceSource(String next) => setState(() => source = next);

  @override
  Widget build(BuildContext context) {
    final R3Theme theme = R3Theme.of(const Color(0xFF00FF00));
    return MaterialApp(
      theme: theme.materialTheme(),
      home: Scaffold(
        body: MosaicSurface(
          source: source,
          mosaicId: 'wall',
          currentFrame: 0,
          isPlaying: widget.playing,
          theme: theme,
          backend: backend,
          resolveSource: (String value) => value,
          onSourceChanged: (String next) {
            changes.add(next);
            setState(() => source = next);
          },
          onSeek: (_) {},
        ),
      ),
    );
  }
}

Finder _key(String key) => find.byKey(ValueKey<String>(key));

Future<GlobalKey<_HarnessState>> _mount(
  WidgetTester tester, {
  String source = _source,
  bool playing = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(1500, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final GlobalKey<_HarnessState> key = GlobalKey<_HarnessState>();
  await tester.pumpWidget(_Harness(
    key: key,
    initialSource: source,
    playing: playing,
  ));
  await tester.pump(const Duration(milliseconds: 200));
  return key;
}

Future<void> _openTrim(WidgetTester tester) async {
  await tester.tap(_key('mosaic-trim-shortest'));
  await tester.pumpAndSettle();
}

Future<void> _confirmTrim(WidgetTester tester) async {
  await _openTrim(tester);
  await tester.tap(_key('mosaic-trim-confirm'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('summary and cancel leave source and undo history untouched',
      (WidgetTester tester) async {
    final GlobalKey<_HarnessState> host = await _mount(tester);
    expect(find.byTooltip('End all panes when the first populated pane ends. '
        'Existing gaps remain.'), findsOneWidget);
    await _openTrim(tester);

    expect(find.textContaining('240 to 100 frames (140 removed)'), findsOneWidget);
    expect(find.textContaining('Clips trimmed: 1. Clips removed: 1.'),
        findsOneWidget);
    expect(find.textContaining('STRUCT placements affected: 1.'), findsOneWidget);
    expect(host.currentState!.changes, isEmpty);
    await tester.tap(_key('mosaic-trim-cancel'));
    await tester.pumpAndSettle();

    expect(host.currentState!.source, _source);
    expect(host.currentState!.changes, isEmpty);
    expect(tester.widget<R3Button>(_key('mosaic-undo')).onPressed, isNull);
  });

  testWidgets('confirmation emits once and one undo restores all trimmed bytes',
      (WidgetTester tester) async {
    final GlobalKey<_HarnessState> host = await _mount(tester);
    await _confirmTrim(tester);
    final String trimmed = trimMosaicToShortest(_source, 'wall');

    expect(host.currentState!.changes, <String>[trimmed]);
    expect(tester.widget<R3Button>(_key('mosaic-trim-shortest')).onPressed, isNull);
    await tester.tap(_key('mosaic-undo'));
    await tester.pumpAndSettle();
    expect(host.currentState!.source, _source);
    expect(host.currentState!.changes, <String>[trimmed, _source]);
    expect(tester.widget<R3Button>(_key('mosaic-undo')).onPressed, isNull);

    await tester.tap(_key('mosaic-redo'));
    await tester.pumpAndSettle();
    expect(host.currentState!.source, trimmed);
    expect(host.currentState!.changes, <String>[trimmed, _source, trimmed]);
    expect(tester.widget<R3Button>(_key('mosaic-redo')).onPressed, isNull);
  });

  final Map<String, String> disabledSources = <String, String>{
    'empty panes': '[MOSAIC:wall][PANE:a][/PANE][PANE:b][/PANE][/MOSAIC]',
    'one populated pane': '''[EDIT:source]
[TRACK:V1]
[CLIP:media:video/source.mp4:0:0:300:1][/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:a][CLIP:a:EDIT.source:0:0:100:1][/CLIP][/PANE]
[PANE:b][/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall]
''',
    'equal pane endings': trimMosaicToShortest(_source, 'wall'),
  };
  for (final MapEntry<String, String> entry in disabledSources.entries) {
    testWidgets('button is disabled for ${entry.key}',
        (WidgetTester tester) async {
      await _mount(tester, source: entry.value);
      expect(tester.widget<R3Button>(_key('mosaic-trim-shortest')).onPressed,
          isNull);
    });
  }

  testWidgets('button is disabled during playback', (WidgetTester tester) async {
    await _mount(tester, playing: true);
    expect(tester.widget<R3Button>(_key('mosaic-trim-shortest')).onPressed, isNull);
    expect(tester.widget<R3Button>(_key('mosaic-undo')).onPressed, isNull);
  });

  testWidgets('all conflicts are readable and no partial edit is committed',
      (WidgetTester tester) async {
    final String conflicts = _source
        .replaceFirst(
          '[CLIP:long:EDIT.source:0:0:200:1][/CLIP]',
          '[CLIP:long:EDIT.source:80:0:120:1]\n'
          '[#EDIT_TRANSITION:CROSSFADE:30]\n[/CLIP]',
        )
        .replaceFirst('[/MOSAIC]', '[PANE:blocked]\n'
            '[CLIP:blocked:EDIT.source:150:0:100:1][/CLIP]\n'
            '[/PANE]\n[/MOSAIC]');
    final GlobalKey<_HarnessState> host =
        await _mount(tester, source: conflicts);
    await _openTrim(tester);

    expect(find.text('Cannot trim MOSAIC'), findsOneWidget);
    expect(find.textContaining('PANE "long", CLIP "long"'), findsOneWidget);
    expect(find.textContaining('PANE "blocked"'), findsOneWidget);
    expect(_key('mosaic-trim-confirm'), findsNothing);
    expect(host.currentState!.changes, isEmpty);
    await tester.tap(find.text('CLOSE'));
    await tester.pumpAndSettle();
    expect(host.currentState!.source, conflicts);
    expect(tester.widget<R3Button>(_key('mosaic-undo')).onPressed, isNull);
  });

  testWidgets('confirmation cannot overwrite a source changed during the dialog',
      (WidgetTester tester) async {
    final GlobalKey<_HarnessState> host = await _mount(tester);
    await _openTrim(tester);
    const String external = '$_source\n[#] External change\n';
    host.currentState!.replaceSource(external);
    await tester.pump();
    await tester.tap(_key('mosaic-trim-confirm'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Review the trim again.'), findsOneWidget);
    expect(host.currentState!.source, external);
    expect(host.currentState!.changes, isEmpty);
    await tester.tap(find.text('CLOSE'));
    await tester.pumpAndSettle();
  });

  testWidgets('external source replacement clears the local undo history',
      (WidgetTester tester) async {
    final GlobalKey<_HarnessState> host = await _mount(tester);
    await _confirmTrim(tester);
    host.currentState!.replaceSource('${host.currentState!.source}\nExternal');
    await tester.pumpAndSettle();

    expect(tester.widget<R3Button>(_key('mosaic-undo')).onPressed, isNull);
    expect(tester.widget<R3Button>(_key('mosaic-redo')).onPressed, isNull);
  });

  testWidgets('a new MOSAIC edit after undo clears the redo branch',
      (WidgetTester tester) async {
    await _mount(tester);
    await _confirmTrim(tester);
    await tester.tap(_key('mosaic-undo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1 PANE'));
    await tester.pumpAndSettle();

    expect(tester.widget<R3Button>(_key('mosaic-redo')).onPressed, isNull);
    expect(tester.widget<R3Button>(_key('mosaic-undo')).onPressed, isNotNull);
  });
}
