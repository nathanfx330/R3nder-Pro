// ./test/edit_video_compositor_test.dart

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/edit_surface_model.dart';
import 'package:r3nder/edit_video_compositor.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/project_clock.dart';

class _ColorBackend implements MediaDecoderBackend {
  final Map<String, int> openCounts = <String, int>{};
  final Map<String, List<int>> requests = <String, List<int>>{};

  @override
  MediaDecoder open(String resolvedPath) {
    openCounts[resolvedPath] = (openCounts[resolvedPath] ?? 0) + 1;
    return _ColorDecoder(
      resolvedPath,
      (int frame) => requests
          .putIfAbsent(resolvedPath, () => <int>[])
          .add(frame),
    );
  }
}

class _ColorDecoder implements MediaDecoder {
  final String path;
  final void Function(int frame) onRequest;

  _ColorDecoder(this.path, this.onRequest);

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    onRequest(requestedSourceFrame);
    if (path == 'mask.png') {
      final Uint8List rgba = Uint8List(width * height * 4);
      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          final int value = x == 0 ? 0 : 255;
          final int i = (y * width + x) * 4;
          rgba[i] = value;
          rgba[i + 1] = value;
          rgba[i + 2] = value;
          rgba[i + 3] = 255;
        }
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

    final List<int> color = path == 'top.mp4'
        ? const <int>[0, 0, 255, 255]
        : const <int>[255, 0, 0, 255];
    return _solidFrame(requestedSourceFrame, width, height, color);
  }

  @override
  void dispose() {}
}

class _AsyncColorBackend implements MediaDecoderBackend {
  int openCount = 0;
  final List<int> requests = <int>[];
  final Set<int> readyFrames = <int>{};

  @override
  MediaDecoder open(String resolvedPath) {
    openCount += 1;
    return _AsyncColorDecoder(this);
  }
}

class _AsyncColorDecoder implements NonBlockingMediaDecoder {
  final _AsyncColorBackend owner;

  _AsyncColorDecoder(this.owner);

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
    if (!owner.readyFrames.contains(requestedSourceFrame)) return null;
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

EditVideoCompositor _compositor(
  String source,
  String editId,
  MediaDecoderBackend backend,
) {
  final EditDocumentModel model = EditDocumentModel.parse(source);
  final MediaLayer layer = MediaLayer(
    editDocument: model,
    backend: backend,
    resolveSource: (String value) => value,
  );
  return EditVideoCompositor(
    document: EditSurfaceDocument.parse(source, editId),
    mediaLayer: layer,
    backend: backend,
    resolveSource: (String value) => value,
  );
}

void main() {
  const ui.Size size = ui.Size(2, 1);

  test('higher video track composites over lower video track', () {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:base:base.mp4:0:0:6:1]
[/CLIP]
[/TRACK]
[TRACK:V2]
[CLIP:top:top.mp4:0:0:6:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final _ColorBackend backend = _ColorBackend();
    final EditDocumentModel model = EditDocumentModel.parse(source);
    final MediaLayer layer = MediaLayer(
      editDocument: model,
      backend: backend,
      resolveSource: (String value) => value,
    );
    final EditVideoCompositor compositor = EditVideoCompositor(
      document: EditSurfaceDocument.parse(source, 'main'),
      mediaLayer: layer,
      backend: backend,
      resolveSource: (String value) => value,
    );

    final EditVideoCompositeResult result = compositor.render(
      'main',
      ProjectTime(frame: 0, mode: ProjectClockMode.scrub),
      size,
    );

    expect(result.rgba, isNotNull);
    expect(result.rgba!.sublist(0, 4), <int>[0, 0, 255, 255]);
    expect(result.topFrame!.clipId, 'top');

    compositor.dispose();
    layer.dispose();
  });

  test('crossfade ramps incoming clip from base to top over authored frames', () {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:base:base.mp4:0:0:6:1]
[/CLIP]
[/TRACK]
[TRACK:V2]
[CLIP:top:top.mp4:0:0:6:1]
[#EDIT_TRANSITION:CROSSFADE:3]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final _ColorBackend backend = _ColorBackend();
    final EditDocumentModel model = EditDocumentModel.parse(source);
    final MediaLayer layer = MediaLayer(
      editDocument: model,
      backend: backend,
      resolveSource: (String value) => value,
    );
    final EditVideoCompositor compositor = EditVideoCompositor(
      document: EditSurfaceDocument.parse(source, 'main'),
      mediaLayer: layer,
      backend: backend,
      resolveSource: (String value) => value,
    );

    final EditVideoCompositeResult start = compositor.render(
      'main',
      ProjectTime(frame: 0, mode: ProjectClockMode.scrub),
      size,
    );
    final EditVideoCompositeResult middle = compositor.render(
      'main',
      ProjectTime(frame: 1, mode: ProjectClockMode.scrub),
      size,
    );
    final EditVideoCompositeResult end = compositor.render(
      'main',
      ProjectTime(frame: 2, mode: ProjectClockMode.scrub),
      size,
    );

    expect(start.rgba!.sublist(0, 4), <int>[255, 0, 0, 255]);
    expect(middle.rgba!.sublist(0, 4), <int>[128, 0, 128, 255]);
    expect(end.rgba!.sublist(0, 4), <int>[0, 0, 255, 255]);
    expect(start.topFrame!.clipId, 'base');
    expect(middle.topFrame!.clipId, 'top');

    compositor.dispose();
    layer.dispose();
  });

  test('luma transition reveals incoming clip by mask brightness', () {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:base:base.mp4:0:0:6:1]
[/CLIP]
[/TRACK]
[TRACK:V2]
[CLIP:top:top.mp4:0:0:6:1]
[#EDIT_TRANSITION:LUMA:mask.png:3]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final _ColorBackend backend = _ColorBackend();
    final EditDocumentModel model = EditDocumentModel.parse(source);
    final MediaLayer layer = MediaLayer(
      editDocument: model,
      backend: backend,
      resolveSource: (String value) => value,
    );
    final EditVideoCompositor compositor = EditVideoCompositor(
      document: EditSurfaceDocument.parse(source, 'main'),
      mediaLayer: layer,
      backend: backend,
      resolveSource: (String value) => value,
    );

    final EditVideoCompositeResult start = compositor.render(
      'main',
      ProjectTime(frame: 0, mode: ProjectClockMode.scrub),
      size,
    );
    final EditVideoCompositeResult middle = compositor.render(
      'main',
      ProjectTime(frame: 1, mode: ProjectClockMode.scrub),
      size,
    );
    final EditVideoCompositeResult end = compositor.render(
      'main',
      ProjectTime(frame: 2, mode: ProjectClockMode.scrub),
      size,
    );

    expect(start.rgba!.sublist(0, 8), <int>[
      255, 0, 0, 255,
      255, 0, 0, 255,
    ]);
    expect(middle.rgba!.sublist(0, 8), <int>[
      0, 0, 255, 255,
      255, 0, 0, 255,
    ]);
    expect(end.rgba!.sublist(0, 8), <int>[
      0, 0, 255, 255,
      0, 0, 255, 255,
    ]);
    expect(backend.openCounts['mask.png'], 1);

    compositor.dispose();
    layer.dispose();
  });

  test('EDIT source recursively renders the exact outer source frame', () {
    const String source = '''[EDIT:child]
[TRACK:V1]
[CLIP:inside:base.mp4:0:10:20:1]
[/CLIP]
[/TRACK]
[/EDIT]
[EDIT:main]
[TRACK:V1]
[CLIP:nested:EDIT.child:5:3:10:2]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final _ColorBackend backend = _ColorBackend();
    final EditDocumentModel model = EditDocumentModel.parse(source);
    final MediaLayer layer = MediaLayer(
      editDocument: model,
      backend: backend,
      resolveSource: (String value) => value,
    );
    final EditVideoCompositor compositor = EditVideoCompositor(
      document: EditSurfaceDocument.parse(source, 'main'),
      mediaLayer: layer,
      backend: backend,
      resolveSource: (String value) => value,
    );

    final EditVideoCompositeResult result = compositor.render(
      'main',
      ProjectTime(frame: 7, epoch: 4, mode: ProjectClockMode.scrub),
      size,
    );

    // main frame 7 is offset 2 inside a 2x CLIP beginning at source frame 3,
    // so child frame 7 is requested. Child frame 7 maps to base.mp4 frame 17.
    expect(backend.requests['base.mp4'], <int>[17]);
    expect(result.rgba!.sublist(0, 4), <int>[255, 0, 0, 255]);
    expect(result.topFrame!.clipId, 'nested');
    expect(result.topFrame!.source, 'EDIT.child');
    expect(result.topFrame!.requestedSourceFrame, 7);
    expect(result.topFrame!.actualSourceFrame, 7);
    expect(layer.cachedDecoderCount, 1);

    compositor.dispose();
    layer.dispose();
  });

  test('nested EDIT keeps its own internal transitions before outer composite', () {
    const String source = '''[EDIT:child]
[TRACK:V1]
[CLIP:base:base.mp4:0:0:6:1]
[/CLIP]
[/TRACK]
[TRACK:V2]
[CLIP:top:top.mp4:0:0:6:1]
[#EDIT_TRANSITION:CROSSFADE:3]
[/CLIP]
[/TRACK]
[/EDIT]
[EDIT:main]
[TRACK:V1]
[CLIP:nested:EDIT.child:0:1:3:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final _ColorBackend backend = _ColorBackend();
    final EditDocumentModel model = EditDocumentModel.parse(source);
    final MediaLayer layer = MediaLayer(
      editDocument: model,
      backend: backend,
      resolveSource: (String value) => value,
    );
    final EditVideoCompositor compositor = EditVideoCompositor(
      document: EditSurfaceDocument.parse(source, 'main'),
      mediaLayer: layer,
      backend: backend,
      resolveSource: (String value) => value,
    );

    final EditVideoCompositeResult result = compositor.render(
      'main',
      ProjectTime(frame: 0, mode: ProjectClockMode.scrub),
      size,
    );

    // The outer clip asks for child frame 1, the midpoint of the child's
    // three-frame crossfade. The nested edit is therefore one purple source.
    expect(result.rgba!.sublist(0, 4), <int>[128, 0, 128, 255]);
    expect(result.topFrame!.clipId, 'nested');
    expect(result.topFrame!.requestedSourceFrame, 1);

    compositor.dispose();
    layer.dispose();
  });

  test('live nested EDIT propagates pending without blocking outer render', () {
    const String source = '''[EDIT:child]
[TRACK:V1]
[CLIP:inside:base.mp4:0:0:6:1]
[/CLIP]
[/TRACK]
[/EDIT]
[EDIT:main]
[TRACK:V1]
[CLIP:nested:EDIT.child:0:0:6:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final _AsyncColorBackend backend = _AsyncColorBackend();
    final EditDocumentModel model = EditDocumentModel.parse(source);
    final MediaLayer layer = MediaLayer(
      editDocument: model,
      backend: backend,
      resolveSource: (String value) => value,
    );
    final EditVideoCompositor compositor = EditVideoCompositor(
      document: EditSurfaceDocument.parse(source, 'main'),
      mediaLayer: layer,
      backend: backend,
      resolveSource: (String value) => value,
    );
    final ProjectTime time =
        ProjectTime(frame: 0, mode: ProjectClockMode.monotonic);

    final EditVideoCompositeResult pending =
        compositor.renderAvailable('main', time, size);

    expect(pending.hasPending, isTrue);
    expect(pending.rgba, isNull);
    expect(backend.openCount, 1);
    expect(backend.requests, <int>[0]);

    backend.readyFrames.add(0);
    final EditVideoCompositeResult ready =
        compositor.renderAvailable('main', time, size);

    expect(ready.hasPending, isFalse);
    expect(ready.rgba!.sublist(0, 4), <int>[255, 0, 0, 255]);
    expect(ready.topFrame!.source, 'EDIT.child');
    expect(backend.openCount, 1);
    expect(backend.requests, <int>[0, 0]);

    compositor.dispose();
    layer.dispose();
  });

  test('outer CLIP duration is not inferred from nested EDIT duration', () {
    const String source = '''[EDIT:child]
[TRACK:V1]
[CLIP:inside:base.mp4:0:0:2:1]
[/CLIP]
[/TRACK]
[/EDIT]
[EDIT:main]
[TRACK:V1]
[CLIP:nested:EDIT.child:0:0:5:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final _ColorBackend backend = _ColorBackend();
    final EditDocumentModel model = EditDocumentModel.parse(source);
    final MediaLayer layer = MediaLayer(
      editDocument: model,
      backend: backend,
      resolveSource: (String value) => value,
    );
    final EditVideoCompositor compositor = EditVideoCompositor(
      document: EditSurfaceDocument.parse(source, 'main'),
      mediaLayer: layer,
      backend: backend,
      resolveSource: (String value) => value,
    );

    expect(model.edit('child').projectFrameCount, 2);
    expect(model.edit('main').projectFrameCount, 5);

    final EditVideoCompositeResult result = compositor.render(
      'main',
      ProjectTime(frame: 4, mode: ProjectClockMode.scrub),
      size,
    );

    expect(result.rgba, isNotNull);
    expect(result.rgba, everyElement(0));
    expect(result.topFrame!.source, 'EDIT.child');
    expect(backend.requests['base.mp4'], isNull);

    compositor.dispose();
    layer.dispose();
  });

  test('EDIT source cycles are rejected before any decoder work', () {
    const String source = '''[EDIT:A]
[TRACK:V1]
[CLIP:toB:EDIT.B:0:0:5:1]
[/CLIP]
[/TRACK]
[/EDIT]
[EDIT:B]
[TRACK:V1]
[CLIP:toA:EDIT.A:0:0:5:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final _ColorBackend backend = _ColorBackend();
    final EditDocumentModel model = EditDocumentModel.parse(source);
    final MediaLayer layer = MediaLayer(
      editDocument: model,
      backend: backend,
      resolveSource: (String value) => value,
    );
    final EditVideoCompositor compositor = EditVideoCompositor(
      document: EditSurfaceDocument.parse(source, 'A'),
      mediaLayer: layer,
      backend: backend,
      resolveSource: (String value) => value,
    );

    expect(
      () => compositor.render(
        'A',
        ProjectTime(frame: 0, mode: ProjectClockMode.scrub),
        size,
      ),
      throwsA(
        isA<StateError>().having(
          (StateError error) => '$error',
          'message',
          contains('EDIT source cycle'),
        ),
      ),
    );
    expect(backend.openCounts, isEmpty);

    compositor.dispose();
    layer.dispose();
  });
}
