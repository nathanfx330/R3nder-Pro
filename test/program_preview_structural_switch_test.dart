// ./test/program_preview_structural_switch_test.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/program_preview_surface.dart';
import 'package:r3nder/scene_engine.dart';
import 'package:r3nder/script_pipeline.dart';
import 'package:r3nder/structural_sequence.dart';
import 'package:r3nder/ui_theme.dart';

class _RecordingBackend implements MediaDecoderBackend {
  final Map<String, int> opens = <String, int>{};
  final Map<String, int> disposes = <String, int>{};

  @override
  MediaDecoder open(String resolvedPath) {
    opens[resolvedPath] = (opens[resolvedPath] ?? 0) + 1;
    return _RecordingDecoder(
      path: resolvedPath,
      onDispose: () {
        disposes[resolvedPath] = (disposes[resolvedPath] ?? 0) + 1;
      },
    );
  }
}

class _RecordingDecoder implements MediaDecoder {
  final String path;
  final VoidCallback onDispose;
  bool _disposed = false;

  _RecordingDecoder({required this.path, required this.onDispose});

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    final Uint8List rgba = Uint8List(width * height * 4);
    final bool second = path.endsWith('b.mp4');
    for (int i = 0; i < rgba.length; i += 4) {
      rgba[i] = second ? 20 : 220;
      rgba[i + 1] = second ? 160 : 40;
      rgba[i + 2] = second ? 220 : 40;
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
[EDIT:b]
[TRACK:V1]
[CLIP:b:video/b.mp4:0:0:3:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:first]
[PANE:pane1]
[CLIP:edit_a:EDIT.a:0:0:3:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[MOSAIC:second]
[PANE:pane1]
[CLIP:edit_b:EDIT.b:0:0:3:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.first]
[STRUCT:MOSAIC.second]
''';

String _resolveSource(String source) => '/workspace/$source';

Future<void> _waitForOpen(
  WidgetTester tester,
  _RecordingBackend backend,
  String path,
) async {
  for (int attempt = 0;
      attempt < 50 && (backend.opens[path] ?? 0) == 0;
      attempt++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump();
  }
  expect(backend.opens[path], 1, reason: '$path should be predecoded once.');
}

void main() {
  testWidgets(
    'seamless STRUCT preloads next MOSAIC and keeps its decoder at handoff',
    (WidgetTester tester) async {
      final Directory root =
          await Directory.systemTemp.createTemp('r3nder_struct_switch_preview_');
      final Directory images = Directory('${root.path}/images')
        ..createSync(recursive: true);
      final Directory sprites = Directory('${root.path}/sprites')
        ..createSync(recursive: true);

      final CompiledScript compiled = compileScript(_source);
      final List<StructuralSequencePlacement> placements =
          parseStructuralSequencePlacements(_source);
      expect(placements, hasLength(2));
      expect(placements.first.seamlessToNext, isTrue);
      expect(placements.last.seamlessFromPrevious, isTrue);

      final SceneEngine scene = SceneEngine();
      await scene.setup(
        templateText: compiled.engineText,
        fontColor: Colors.green,
        bgColor: Colors.black,
        width: 320,
        height: 180,
        scale: 1,
        fontPath: 'monospace',
        fontSize: 12,
        lineSpacing: 16,
        tracking: 0,
        marginTop: 10,
        marginSide: 10,
        imagesDir: images.path,
        spritesDir: sprites.path,
        paneLifeConfig: compiled.paneLife,
        captionConfig: compiled.caption,
        appSwitchConfig: compiled.appSwitch,
      );

      final _RecordingBackend backend = _RecordingBackend();
      final ChangeNotifier repaint = ChangeNotifier();

      addTearDown(() {
        repaint.dispose();
        scene.disposeImages();
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 320,
            height: 180,
            child: ProgramPreviewSurface(
              repaint: repaint,
              scene: scene,
              rawDocument: _source,
              fontFamily: 'monospace',
              theme: R3Theme.of(Colors.green),
              structuralBackend: backend,
              structuralResolveSource: _resolveSource,
            ),
          ),
        ),
      );

      StructuralRuntimeMarker? marker;
      int guard = 0;
      while (guard < 500) {
        scene.tick();
        repaint.notifyListeners();
        await tester.pump();
        marker = parseStructuralRuntimeRegion(scene.terminal.currentRegion);
        if (marker?.placementIndex == 0) break;
        guard++;
      }
      expect(marker?.placementIndex, 0);

      // The visible first source and the hidden incoming second source are both
      // mounted as soon as placement 0 becomes active.
      expect(
        find.byKey(const ValueKey<String>('program-struct-layer-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('program-struct-layer-1')),
        findsOneWidget,
      );

      await _waitForOpen(tester, backend, '/workspace/video/a.mp4');
      await _waitForOpen(tester, backend, '/workspace/video/b.mp4');

      final Finder incomingLayer =
          find.byKey(const ValueKey<String>('program-struct-layer-1'));
      final Opacity hiddenOpacity = tester.widget<Opacity>(
        find.descendant(of: incomingLayer, matching: find.byType(Opacity)).first,
      );
      expect(hiddenOpacity.opacity, 0.0);
      expect(backend.opens['/workspace/video/b.mp4'], 1);
      expect(backend.disposes['/workspace/video/b.mp4'] ?? 0, 0);

      // Advance frame-by-frame through the real terminal marker transition.
      // The incoming layer must become visible without disappearing/reopening.
      guard = 0;
      while (guard < 500) {
        scene.tick();
        repaint.notifyListeners();
        await tester.pump();
        marker = parseStructuralRuntimeRegion(scene.terminal.currentRegion);
        if (marker?.placementIndex == 1) break;
        guard++;
      }
      expect(marker?.placementIndex, 1);

      expect(
        find.byKey(const ValueKey<String>('program-struct-layer-0')),
        findsNothing,
      );
      expect(incomingLayer, findsOneWidget);

      final Opacity visibleOpacity = tester.widget<Opacity>(
        find.descendant(of: incomingLayer, matching: find.byType(Opacity)).first,
      );
      expect(visibleOpacity.opacity, 1.0);
      expect(backend.opens['/workspace/video/b.mp4'], 1);
      expect(backend.disposes['/workspace/video/b.mp4'] ?? 0, 0);
    },
  );
}
