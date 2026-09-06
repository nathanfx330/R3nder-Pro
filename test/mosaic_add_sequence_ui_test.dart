// ./test/mosaic_add_sequence_ui_test.dart

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/mosaic_surface.dart';
import 'package:r3nder/ui_theme.dart';

const String _source = '''[EDIT:main]
[TRACK:V1]
[CLIP:a:video/a.mp4:0:0:120:1]
[/CLIP]
[/TRACK]
[/EDIT]
[EDIT:broll]
[TRACK:V1]
[CLIP:b:video/b.mp4:0:0:80:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:pane1]
[/PANE]
[/MOSAIC]
''';

class _SolidBackend implements MediaDecoderBackend {
  @override
  MediaDecoder open(String resolvedPath) => _SolidDecoder();
}

class _SolidDecoder implements MediaDecoder {
  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    final Uint8List rgba = Uint8List(width * height * 4);
    for (int i = 3; i < rgba.length; i += 4) {
      rgba[i] = 255;
    }
    return DecodedMediaFrame(
      requestedSourceFrame: requestedSourceFrame,
      actualSourceFrame: requestedSourceFrame,
      width: width,
      height: height,
      stride: width * 4,
      rgba: rgba,
    );
  }

  @override
  void dispose() {}
}

Widget _host(ValueChanged<String> onSourceChanged) {
  final R3Theme theme = R3Theme.of(const Color(0xFF00FF00));
  return MaterialApp(
    theme: theme.materialTheme(),
    home: Scaffold(
      body: SizedBox(
        width: 1000,
        height: 700,
        child: MosaicSurface(
          source: _source,
          mosaicId: 'wall',
          currentFrame: 0,
          theme: theme,
          backend: _SolidBackend(),
          resolveSource: (String value) => value,
          onSourceChanged: onSourceChanged,
          onSeek: (_) {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('empty MOSAIC pane lists whole EDIT sequences',
      (WidgetTester tester) async {
    String? changed;
    await tester.pumpWidget(_host((String value) => changed = value));
    await tester.pumpAndSettle();

    expect(find.text('ADD SEQUENCE'), findsOneWidget);
    expect(find.text('ADD CUT'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('mosaic-empty-pane:pane1')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('mosaic-empty-pane:pane1')),
    );
    await tester.pumpAndSettle();

    expect(find.text('EDIT.main'), findsOneWidget);
    expect(find.text('EDIT.broll'), findsOneWidget);
    expect(find.text('120 FRAMES'), findsOneWidget);
    expect(find.text('80 FRAMES'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('mosaic-edit-sequence:main')),
    );
    await tester.pumpAndSettle();

    expect(changed, isNotNull);
    expect(changed, contains('[CLIP:edit_main:EDIT.main:0:0:120:1]'));
    expect(find.text('EDIT.main'), findsOneWidget);
  });

  testWidgets('ADD SEQUENCE appends another whole EDIT after the first',
      (WidgetTester tester) async {
    String latest = _source;
    await tester.pumpWidget(_host((String value) => latest = value));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('mosaic-empty-pane:pane1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('mosaic-edit-sequence:main')),
    );
    await tester.pumpAndSettle();

    final Finder addSequence = find.byKey(
      const ValueKey<String>('mosaic-pane-add-sequence:pane1'),
    );
    expect(addSequence, findsOneWidget);
    await tester.tap(addSequence);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('mosaic-edit-sequence:broll')),
    );
    await tester.pumpAndSettle();

    expect(latest, contains('[CLIP:edit_main:EDIT.main:0:0:120:1]'));
    expect(latest, contains('[CLIP:edit_broll:EDIT.broll:120:0:80:1]'));
  });
}
