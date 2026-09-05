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

Future<void> _secondaryTap(WidgetTester tester, Finder finder) async {
  await tester.tap(
    finder,
    buttons: kSecondaryMouseButton,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('clip edge context menus own incoming and outgoing crossfades',
      (WidgetTester tester) async {
    String? changed;
    await tester.pumpWidget(_host((String value) => changed = value));
    await tester.pumpAndSettle();

    expect(find.text('XFADE'), findsNothing);

    final Finder inHandle = find.byKey(
      const ValueKey<String>('edit-clip-V1-intro-in-handle'),
    );
    expect(inHandle, findsOneWidget);

    await _secondaryTap(tester, inHandle);
    expect(find.text('XFADE IN'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('edit-xfade-in-12')),
    );
    await tester.pumpAndSettle();

    expect(changed, contains('[#EDIT_TRANSITION:CROSSFADE:12]'));
    expect(changed, isNot(contains('[#EDIT_TRANSITION_OUT:CROSSFADE:')));
    expect(
      find.byKey(
        const ValueKey<String>('edit-clip-V1-intro-in-transition'),
      ),
      findsOneWidget,
    );

    final Finder outHandle = find.byKey(
      const ValueKey<String>('edit-clip-V1-intro-out-handle'),
    );
    expect(outHandle, findsOneWidget);

    await _secondaryTap(tester, outHandle);
    expect(find.text('XFADE OUT'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('edit-xfade-out-24')),
    );
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

  testWidgets('right edge context menu clears only outgoing crossfade',
      (WidgetTester tester) async {
    String? changed;
    await tester.pumpWidget(_host((String value) => changed = value));
    await tester.pumpAndSettle();

    final Finder outHandle = find.byKey(
      const ValueKey<String>('edit-clip-V1-intro-out-handle'),
    );

    await _secondaryTap(tester, outHandle);
    await tester.tap(
      find.byKey(const ValueKey<String>('edit-xfade-out-12')),
    );
    await tester.pumpAndSettle();
    expect(changed, contains('[#EDIT_TRANSITION_OUT:CROSSFADE:12]'));

    await _secondaryTap(tester, outHandle);
    await tester.tap(
      find.byKey(const ValueKey<String>('edit-xfade-out-clear')),
    );
    await tester.pumpAndSettle();

    expect(changed, isNot(contains('[#EDIT_TRANSITION_OUT:CROSSFADE:')));
    expect(
      find.byKey(
        const ValueKey<String>('edit-clip-V1-intro-out-transition'),
      ),
      findsNothing,
    );
  });
}
