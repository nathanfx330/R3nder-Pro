// ./test/edit_v2_and_long_xfade_ui_test.dart

import 'dart:typed_data';

import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_surface.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/ui_theme.dart';

const String _source = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:intro:video/intro.mp4:0:0:120:1]
    [/CLIP]
  [/TRACK]
[/EDIT]
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
      rgba[i] = 80;
      rgba[i + 1] = 120;
      rgba[i + 2] = 160;
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
        child: EditSurface(
          source: _source,
          editId: 'main',
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

Future<void> _secondaryTap(WidgetTester tester, Finder finder) async {
  await tester.tap(
    finder,
    buttons: kSecondaryMouseButton,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('selected clip can move from V1 to V2 and back',
      (WidgetTester tester) async {
    String? changed;
    await tester.pumpWidget(_host((String value) => changed = value));
    await tester.pumpAndSettle();

    await tester.tap(find.text('intro').first);
    await tester.pump();
    expect(find.text('TO V2'), findsOneWidget);

    await tester.tap(find.text('TO V2'));
    await tester.pumpAndSettle();

    expect(changed, contains('[TRACK:V2]'));
    expect(changed, contains('[CLIP:intro:video/intro.mp4:0:0:120:1]'));
    expect(find.text('V2'), findsWidgets);
    expect(find.text('TO V1'), findsOneWidget);

    await tester.tap(find.text('TO V1'));
    await tester.pumpAndSettle();
    expect(changed, contains('[TRACK:V1]'));
    expect(find.text('TO V2'), findsOneWidget);
  });

  testWidgets('edge menu exposes a visibly long 72-frame crossfade',
      (WidgetTester tester) async {
    String? changed;
    await tester.pumpWidget(_host((String value) => changed = value));
    await tester.pumpAndSettle();

    final Finder handle = find.byKey(
      const ValueKey<String>('edit-clip-V1-intro-in-handle'),
    );
    await _secondaryTap(tester, handle);
    expect(
      find.byKey(const ValueKey<String>('edit-xfade-in-72')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('edit-xfade-in-72')),
    );
    await tester.pumpAndSettle();
    expect(changed, contains('[#EDIT_TRANSITION:CROSSFADE:72]'));
  });

  testWidgets('edge menu accepts a custom crossfade duration',
      (WidgetTester tester) async {
    String? changed;
    await tester.pumpWidget(_host((String value) => changed = value));
    await tester.pumpAndSettle();

    final Finder handle = find.byKey(
      const ValueKey<String>('edit-clip-V1-intro-in-handle'),
    );
    await _secondaryTap(tester, handle);
    await tester.tap(
      find.byKey(const ValueKey<String>('edit-xfade-in-custom')),
    );
    await tester.pumpAndSettle();

    final Finder field = find.byKey(
      const ValueKey<String>('edit-xfade-custom-field'),
    );
    expect(field, findsOneWidget);
    await tester.enterText(field, '90');
    await tester.tap(find.text('APPLY'));
    await tester.pumpAndSettle();

    expect(changed, contains('[#EDIT_TRANSITION:CROSSFADE:90]'));
  });
}
