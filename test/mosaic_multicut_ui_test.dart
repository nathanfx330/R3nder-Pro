// ./test/mosaic_multicut_ui_test.dart

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/mosaic_surface.dart';
import 'package:r3nder/ui_theme.dart';

const String _source = '''[EDIT:cuts]
[TRACK:V1]
[CLIP:a:video/a.mp4:0:0:80:1]
[/CLIP]
[CLIP:b:video/b.mp4:80:0:80:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:pane1]
[CLIP:a:video/a.mp4:0:0:80:1]
[/CLIP]
[CLIP:b:video/b.mp4:80:0:80:1]
[/CLIP]
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
    for (int i = 0; i < rgba.length; i += 4) {
      rgba[i] = 60;
      rgba[i + 1] = 90;
      rgba[i + 2] = 120;
      rgba[i + 3] = 255;
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
        width: 1280,
        height: 720,
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
  testWidgets('pane shows multiple sequence items with crossfade control between them',
      (WidgetTester tester) async {
    String? changed;
    await tester.pumpWidget(_host((String value) => changed = value));
    await tester.pumpAndSettle();

    expect(find.text('2 SEQUENCES'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('mosaic-cut-assignment:a')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('mosaic-cut-assignment:b')),
      findsOneWidget,
    );

    final Finder transition = find.byKey(
      const ValueKey<String>('mosaic-xfade:pane1:a:b'),
    );
    expect(transition, findsOneWidget);
    await tester.tap(transition);
    await tester.pumpAndSettle();
    await tester.tap(find.text('24 FRAMES'));
    await tester.pumpAndSettle();

    expect(changed, contains('[CLIP:b:video/b.mp4:56:0:80:1]'));
    expect(changed, contains('[#EDIT_TRANSITION:CROSSFADE:24]'));
    expect(find.text('XFADE\n24F'), findsOneWidget);
  });

  testWidgets('pane uses ADD SEQUENCE instead of cut assignment controls',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host((_) {}));
    await tester.pumpAndSettle();

    expect(find.text('ADD SEQUENCE'), findsOneWidget);
    expect(find.text('ADD CUT'), findsNothing);
    expect(find.text('CHANGE CUT'), findsNothing);
    expect(find.text('ASSIGN CUT'), findsNothing);
  });
}
