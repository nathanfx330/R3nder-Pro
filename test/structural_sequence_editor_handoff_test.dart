// ./test/structural_sequence_editor_handoff_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/structural_sequence.dart';
import 'package:r3nder/structural_sequence_preview.dart';
import 'package:r3nder/ui_theme.dart';

class _EditorHandoffBackend implements MediaDecoderBackend {
  bool releaseB = false;
  final Map<String, int> opens = <String, int>{};
  final Map<String, int> disposes = <String, int>{};

  @override
  MediaDecoder open(String resolvedPath) {
    opens[resolvedPath] = (opens[resolvedPath] ?? 0) + 1;
    if (resolvedPath.endsWith('/video/b.mp4')) {
      return _PendingBDecoder(
        released: () => releaseB,
        onDispose: () {
          disposes[resolvedPath] = (disposes[resolvedPath] ?? 0) + 1;
        },
      );
    }
    return _ResolvedOfflineDecoder(
      path: resolvedPath,
      onDispose: () {
        disposes[resolvedPath] = (disposes[resolvedPath] ?? 0) + 1;
      },
    );
  }
}

class _ResolvedOfflineDecoder implements MediaDecoder {
  final String path;
  final VoidCallback onDispose;
  bool _disposed = false;

  _ResolvedOfflineDecoder({required this.path, required this.onDispose});

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    throw MediaDecodeException('intentional resolved A: $path');
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    onDispose();
  }
}

class _PendingBDecoder implements NonBlockingMediaDecoder {
  final bool Function() released;
  final VoidCallback onDispose;
  bool _disposed = false;

  _PendingBDecoder({required this.released, required this.onDispose});

  @override
  void request(int requestedSourceFrame, int width, int height) {}

  @override
  DecodedMediaFrame? poll(
    int requestedSourceFrame,
    int width,
    int height,
  ) {
    if (!released()) return null;
    throw const MediaDecodeException('intentional resolved B');
  }

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    throw const MediaDecodeException('intentional blocking B');
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    onDispose();
  }
}

const String _source = '''[CONFIG:APPSWITCH:SLIDE]
[EDIT:a]
[TRACK:V1]
[CLIP:a:video/a.mp4:0:0:3:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:first]
[PANE:pane1]
[CLIP:a_edit:EDIT.a:0:0:3:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.first]

[EDIT:b]
[TRACK:V1]
[CLIP:b:video/b.mp4:0:0:3:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:second]
[PANE:pane1]
[CLIP:b_edit:EDIT.b:0:0:3:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.second]
''';

String _resolveSource(String source) => '/workspace/$source';

Finder _client(String source) =>
    find.byKey(ValueKey<String>('sequence-preview:$source'));

Future<void> _pumpPlacement(
  WidgetTester tester, {
  required StructuralSequencePlacement placement,
  required int localFrame,
  required _EditorHandoffBackend backend,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: SizedBox(
        width: 640,
        height: 360,
        child: StructuralSequencePreview(
          rawDocument: _source,
          placement: placement,
          localFrame: localFrame,
          isPlaying: true,
          theme: R3Theme.of(Colors.green),
          wallpaper: null,
          terminalCursorFraction: const Size(0.01, 0.02),
          backend: backend,
          resolveSource: _resolveSource,
        ),
      ),
    ),
  );
}

double _structuralOpacity(WidgetTester tester) {
  return tester
      .widget<Opacity>(
        find.byKey(const ValueKey<String>('structural-window-opacity')),
      )
      .opacity;
}

void main() {
  testWidgets(
    'editor-style seamless STRUCT source update never drops the live shell',
    (WidgetTester tester) async {
      final List<StructuralSequencePlacement> placements =
          parseStructuralSequencePlacements(_source);
      expect(placements, hasLength(2));

      final StructuralSequencePlacement first = placements[0];
      final StructuralSequencePlacement second = placements[1];
      expect(first.seamlessToNext, isTrue);
      expect(second.seamlessFromPrevious, isTrue);
      expect(first.presentationMode, second.presentationMode);

      final _EditorHandoffBackend backend = _EditorHandoffBackend();

      await _pumpPlacement(
        tester,
        placement: first,
        localFrame: first.contentStartFrame,
        backend: backend,
      );

      for (int attempt = 0;
          attempt < 20 &&
              find
                  .byKey(
                    const ValueKey<String>('structural-first-frame-ready'),
                  )
                  .evaluate()
                  .isEmpty;
          attempt++) {
        await tester.pump();
      }

      expect(
        find.byKey(const ValueKey<String>('structural-first-frame-ready')),
        findsOneWidget,
      );
      expect(_structuralOpacity(tester), 1.0);
      expect(_client('MOSAIC.first'), findsOneWidget);
      expect(backend.opens['/workspace/video/a.mp4'], 1);

      // This is the editor's real handoff shape: same widget slot / same State,
      // but placement changes from A to B. B is deliberately still pending.
      await _pumpPlacement(
        tester,
        placement: second,
        localFrame: 0,
        backend: backend,
      );
      await tester.pump();

      // The old bug reset _firstFrameReady here, making this opacity 0 and
      // exposing only the desktop. A seamless handoff must keep the shell up.
      expect(
        find.byKey(const ValueKey<String>('structural-window-positioned')),
        findsOneWidget,
      );
      expect(_structuralOpacity(tester), 1.0);

      // B evaluates underneath at current time while A's already-painted keyed
      // client remains on top. The outgoing decoder must not be reopened.
      expect(_client('MOSAIC.second'), findsOneWidget);
      expect(_client('MOSAIC.first'), findsOneWidget);
      expect(backend.opens['/workspace/video/a.mp4'], 1);
      expect(backend.disposes['/workspace/video/a.mp4'] ?? 0, 0);
      expect(backend.opens['/workspace/video/b.mp4'], 1);

      // Advancing the editor project frame gives the pending B decoder another
      // evaluation. Once it resolves, only the client changes; the shell stays.
      backend.releaseB = true;
      await _pumpPlacement(
        tester,
        placement: second,
        localFrame: 1,
        backend: backend,
      );

      for (int attempt = 0;
          attempt < 20 && _client('MOSAIC.first').evaluate().isNotEmpty;
          attempt++) {
        await tester.pump();
      }

      expect(_structuralOpacity(tester), 1.0);
      expect(_client('MOSAIC.first'), findsNothing);
      expect(_client('MOSAIC.second'), findsOneWidget);
      expect(backend.opens['/workspace/video/a.mp4'], 1);
      expect(backend.opens['/workspace/video/b.mp4'], 1);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
