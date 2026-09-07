// ./test/structural_sequence_readiness_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/structural_sequence.dart';
import 'package:r3nder/structural_sequence_preview.dart';
import 'package:r3nder/ui_theme.dart';

class _OfflineBackend implements MediaDecoderBackend {
  int opens = 0;

  @override
  MediaDecoder open(String resolvedPath) {
    opens++;
    return _OfflineDecoder(resolvedPath);
  }
}

class _OfflineDecoder implements MediaDecoder {
  final String path;

  _OfflineDecoder(this.path);

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    throw MediaDecodeException('intentional readiness-test offline: $path');
  }

  @override
  void dispose() {}
}

const String _source = '''[MOSAIC:wall]
[PANE:pane1]
[CLIP:leaf:video/missing.mp4:0:0:3:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall]
''';

String _resolveSource(String source) => '/workspace/$source';

Widget _buildPreview({
  required StructuralSequencePlacement placement,
  required _OfflineBackend backend,
}) {
  return MaterialApp(
    home: SizedBox(
      width: 320,
      height: 180,
      child: StructuralSequencePreview(
        rawDocument: _source,
        placement: placement,
        localFrame: 0,
        isPlaying: true,
        theme: R3Theme.of(Colors.green),
        wallpaper: null,
        backend: backend,
        resolveSource: _resolveSource,
      ),
    ),
  );
}

void main() {
  testWidgets(
    'offline structural source resolves first-frame readiness without pixels',
    (WidgetTester tester) async {
      final StructuralSequencePlacement placement =
          parseStructuralSequencePlacements(_source).single;
      final _OfflineBackend backend = _OfflineBackend();

      expect(placement.stageAt(0), StructuralSequenceStage.zoomOut);

      await tester.pumpWidget(
        _buildPreview(
          placement: placement,
          backend: backend,
        ),
      );

      final Finder ready = find.byKey(
        const ValueKey<String>('structural-first-frame-ready'),
      );

      for (int attempt = 0; attempt < 8 && ready.evaluate().isEmpty; attempt++) {
        await tester.pump();
      }

      expect(backend.opens, 1);
      expect(ready, findsOneWidget);
      expect(find.textContaining('OFFLINE'), findsOneWidget);
    },
  );
}
