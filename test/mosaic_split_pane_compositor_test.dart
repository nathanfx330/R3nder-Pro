// ./test/mosaic_split_pane_compositor_test.dart

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/edit_video_compositor.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/project_clock.dart';

class _ColorBackend implements MediaDecoderBackend {
  final Map<String, List<int>> requests = <String, List<int>>{};

  @override
  MediaDecoder open(String resolvedPath) => _ColorDecoder(
        resolvedPath,
        (int frame) =>
            requests.putIfAbsent(resolvedPath, () => <int>[]).add(frame),
      );
}

class _ColorDecoder implements MediaDecoder {
  _ColorDecoder(this.path, this.onRequest);

  final String path;
  final void Function(int frame) onRequest;

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    onRequest(requestedSourceFrame);
    final List<int> color = path == 'blue.mp4'
        ? const <int>[0, 0, 255, 255]
        : const <int>[255, 0, 0, 255];
    return _solidFrame(requestedSourceFrame, width, height, color);
  }

  @override
  void dispose() {}
}

class _AsyncBackend implements MediaDecoderBackend {
  bool ready = false;
  final List<int> requests = <int>[];

  @override
  MediaDecoder open(String resolvedPath) => _AsyncDecoder(this);
}

class _AsyncDecoder implements NonBlockingMediaDecoder {
  _AsyncDecoder(this.owner);

  final _AsyncBackend owner;

  @override
  void request(int requestedSourceFrame, int width, int height) {
    owner.requests.add(requestedSourceFrame);
  }

  @override
  DecodedMediaFrame? poll(
    int requestedSourceFrame,
    int width,
    int height,
  ) {
    if (!owner.ready) return null;
    return _solidFrame(
      requestedSourceFrame,
      width,
      height,
      const <int>[255, 0, 0, 255],
    );
  }

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    return _solidFrame(
      requestedSourceFrame,
      width,
      height,
      const <int>[255, 0, 0, 255],
    );
  }

  @override
  void dispose() {}
}

DecodedMediaFrame _solidFrame(
  int requestedSourceFrame,
  int width,
  int height,
  List<int> color,
) {
  final Uint8List rgba = Uint8List(width * height * 4);
  for (int i = 0; i < rgba.length; i += 4) {
    rgba.setRange(i, i + 4, color);
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

EditVideoCompositor _build(
  String source,
  MediaDecoderBackend backend,
  MediaLayer layer,
) {
  return EditVideoCompositor.forModel(
    model: EditDocumentModel.parse(source),
    mediaLayer: layer,
    backend: backend,
    resolveSource: (String value) => value,
  );
}

void main() {
  const ui.Size paneSize = ui.Size(6, 4);

  test('exact MOSAIC pane render recursively resolves nested EDIT', () {
    const String source = '''[EDIT:child]
[TRACK:V1]
[CLIP:red:red.mp4:0:10:4:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:left]
[CLIP:nested:EDIT.child:0:1:3:1]
[/CLIP]
[/PANE]
[PANE:right]
[CLIP:blue:blue.mp4:0:0:3:1]
[/CLIP]
[/PANE]
[/MOSAIC]
''';

    final _ColorBackend backend = _ColorBackend();
    final EditDocumentModel model = EditDocumentModel.parse(source);
    final MediaLayer layer = MediaLayer(
      editDocument: model,
      backend: backend,
      resolveSource: (String value) => value,
    );
    final EditVideoCompositor compositor = _build(source, backend, layer);

    final EditVideoCompositeResult result = compositor.renderMosaicPane(
      'MOSAIC.wall',
      0,
      ProjectTime(frame: 1, mode: ProjectClockMode.scrub),
      paneSize,
    );

    // Pane frame 1 asks for child frame 2, which maps to red.mp4 frame 12.
    expect(backend.requests['red.mp4'], <int>[12]);
    expect(backend.requests['blue.mp4'], isNull);
    expect(result.hasPending, isFalse);
    expect(result.rgba, isNotNull);
    expect(result.rgba!.sublist(0, 4), <int>[255, 0, 0, 255]);
    expect(result.topFrame!.source, 'EDIT.child');
    expect(
      result.diagnosticFrames.any(
        (MediaFrame frame) =>
            frame.source == 'red.mp4' &&
            frame.requestedSourceFrame == 12 &&
            frame.actualSourceFrame == 12,
      ),
      isTrue,
    );

    compositor.dispose();
    layer.dispose();
  });

  test('available MOSAIC pane render preserves nested pending readiness', () {
    const String source = '''[EDIT:child]
[TRACK:V1]
[CLIP:red:red.mp4:0:0:3:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:left]
[CLIP:nested:EDIT.child:0:0:3:1]
[/CLIP]
[/PANE]
[PANE:right]
[CLIP:other:blue.mp4:0:0:3:1]
[/CLIP]
[/PANE]
[/MOSAIC]
''';

    final _AsyncBackend backend = _AsyncBackend();
    final EditDocumentModel model = EditDocumentModel.parse(source);
    final MediaLayer layer = MediaLayer(
      editDocument: model,
      backend: backend,
      resolveSource: (String value) => value,
    );
    final EditVideoCompositor compositor = _build(source, backend, layer);
    final ProjectTime time =
        ProjectTime(frame: 0, mode: ProjectClockMode.monotonic);

    final EditVideoCompositeResult pending =
        compositor.renderMosaicPaneAvailable(
      'MOSAIC.wall',
      0,
      time,
      paneSize,
    );
    expect(pending.hasPending, isTrue);
    expect(pending.rgba, isNull);
    expect(backend.requests, <int>[0]);

    backend.ready = true;
    final EditVideoCompositeResult ready =
        compositor.renderMosaicPaneAvailable(
      'MOSAIC.wall',
      0,
      time,
      paneSize,
    );
    expect(ready.hasPending, isFalse);
    expect(ready.rgba, isNotNull);
    expect(ready.rgba!.sublist(0, 4), <int>[255, 0, 0, 255]);
    expect(backend.requests, <int>[0, 0]);

    compositor.dispose();
    layer.dispose();
  });
}
