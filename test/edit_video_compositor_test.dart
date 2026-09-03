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

  @override
  MediaDecoder open(String resolvedPath) {
    openCounts[resolvedPath] = (openCounts[resolvedPath] ?? 0) + 1;
    return _ColorDecoder(resolvedPath);
  }
}

class _ColorDecoder implements MediaDecoder {
  final String path;

  _ColorDecoder(this.path);

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
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

  @override
  void dispose() {}
}

EditVideoCompositor _compositor(
  String source,
  _ColorBackend backend,
  MediaLayer Function(EditDocumentModel model) rememberLayer,
) {
  final EditDocumentModel model = EditDocumentModel.parse(source);
  final MediaLayer layer = MediaLayer(
    editDocument: model,
    backend: backend,
    resolveSource: (String value) => value,
  );
  rememberLayer(model);
  return EditVideoCompositor(
    document: EditSurfaceDocument.parse(source, 'main'),
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
}
