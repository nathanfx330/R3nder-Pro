// ./test/edit_dossier_preview_test.dart

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_video_preview.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/ui_theme.dart';

class _FakeBackend implements MediaDecoderBackend {
  @override
  MediaDecoder open(String resolvedPath) => _FakeDecoder();
}

class _FakeDecoder implements MediaDecoder {
  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    final Uint8List rgba = Uint8List(width * height * 4);
    for (int i = 0; i < rgba.length; i += 4) {
      rgba[i] = 180;
      rgba[i + 1] = 32;
      rgba[i + 2] = 24;
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

const String _source = '''[EDIT:main]
[TRACK:V1]
[CLIP:shot:video/shot.mp4:0:0:180:1]
[CUE:10]
[DOSSIER:evidence:missing.png:10:20:0:GRID:24,32,40:JOHN SMITH]
Biography text.
[/DOSSIER]
[/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
''';

Widget _host({
  required int frame,
  required bool directEdit,
}) {
  return MaterialApp(
    home: SizedBox(
      width: 640,
      height: 360,
      child: EditVideoPreview(
        source: _source,
        editId: directEdit ? 'main' : null,
        structuralSource: directEdit ? null : 'EDIT.main',
        currentFrame: frame,
        theme: R3Theme.of(Colors.green),
        backend: _FakeBackend(),
        resolveSource: (String value) => '/definitely/missing/$value',
        showDiagnosticOverlay: false,
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('standalone EDIT preview self-stages active DOSSIER',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(frame: 10, directEdit: true));
    await tester.pumpAndSettle();

    // Opening frame zero owns the trigger but has zero shell displacement.
    expect(
      find.byKey(const ValueKey<String>('edit-dossier-cue-overlay-paint')),
      findsNothing,
    );

    await tester.pumpWidget(_host(frame: 11, directEdit: true));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('edit-dossier-cue-overlay-paint')),
      findsOneWidget,
    );
  });

  testWidgets('structuralSource preview leaves DOSSIER to outer STRUCT shell',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(frame: 11, directEdit: false));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('edit-dossier-cue-overlay-paint')),
      findsNothing,
    );
  });
}
