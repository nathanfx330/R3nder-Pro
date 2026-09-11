// ./test/edit_edge_transition_ui_test.dart

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
    [CLIP:intro:video/intro.mp4:10:20:40:1]
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
          currentFrame: 10,
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

Future<void> _show(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('inspector owns incoming and outgoing crossfade authoring',
      (WidgetTester tester) async {
    String? changed;
    await tester.pumpWidget(_host((String value) => changed = value));
    await tester.pumpAndSettle();

    await tester.tap(find.text('intro'));
    await tester.pumpAndSettle();

    final Finder incoming =
        find.byKey(const ValueKey<String>('edit-inspector-transition-in-menu'));
    await _show(tester, incoming);
    await tester.tap(incoming);
    await tester.pumpAndSettle();
    await tester.tap(find.text('CROSSFADE 12 FRAMES'));
    await tester.pumpAndSettle();

    expect(changed, contains('[#EDIT_TRANSITION:CROSSFADE:12]'));
    expect(changed, isNot(contains('[#EDIT_TRANSITION_OUT:CROSSFADE:')));
    expect(
      find.byKey(
        const ValueKey<String>('edit-clip-V1-intro-in-transition'),
      ),
      findsOneWidget,
    );

    final Finder outgoing =
        find.byKey(const ValueKey<String>('edit-inspector-transition-out-menu'));
    await _show(tester, outgoing);
    await tester.tap(outgoing);
    await tester.pumpAndSettle();
    await tester.tap(find.text('CROSSFADE 24 FRAMES'));
    await tester.pumpAndSettle();

    expect(changed, contains('[#EDIT_TRANSITION:CROSSFADE:12]'));
    expect(changed, contains('[#EDIT_TRANSITION_OUT:CROSSFADE:24]'));
    expect(
      find.byKey(
        const ValueKey<String>('edit-clip-V1-intro-out-transition'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('secondary click on trim edge no longer opens transition authoring',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host((_) {}));
    await tester.pumpAndSettle();

    final Finder inHandle = find.byKey(
      const ValueKey<String>('edit-clip-V1-intro-in-handle'),
    );
    expect(inHandle, findsOneWidget);

    await tester.tap(
      inHandle,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(find.text('XFADE IN'), findsNothing);
    expect(find.text('XFADE OUT'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('edit-inspector-transition-in-menu')),
      findsOneWidget,
    );
  });
}
