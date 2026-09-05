// ./test/edit_video_compositor_depth_guard_test.dart

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/edit_surface_model.dart';
import 'package:r3nder/edit_video_compositor.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/project_clock.dart';

class _CountingBackend implements MediaDecoderBackend {
  int openCount = 0;
  final List<int> requests = <int>[];

  @override
  MediaDecoder open(String resolvedPath) {
    openCount++;
    return _CountingDecoder(requests);
  }
}

class _CountingDecoder implements MediaDecoder {
  final List<int> requests;

  _CountingDecoder(this.requests);

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    requests.add(requestedSourceFrame);
    final Uint8List rgba = Uint8List(width * height * 4);
    for (int i = 0; i < rgba.length; i += 4) {
      rgba[i] = 255;
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

const String _threeDeepSource = '''[EDIT:leaf]
[TRACK:V1]
[CLIP:media:base.mp4:0:0:5:1]
[/CLIP]
[/TRACK]
[/EDIT]
[EDIT:middle]
[TRACK:V1]
[CLIP:leaf:EDIT.leaf:0:0:5:1]
[/CLIP]
[/TRACK]
[/EDIT]
[EDIT:root]
[TRACK:V1]
[CLIP:middle:EDIT.middle:0:0:5:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';

EditVideoCompositor _buildCompositor(
  _CountingBackend backend, {
  required int maxRenderDepth,
}) {
  final EditDocumentModel model = EditDocumentModel.parse(_threeDeepSource);
  final MediaLayer layer = MediaLayer(
    editDocument: model,
    backend: backend,
    resolveSource: (String value) => value,
  );
  return EditVideoCompositor(
    document: EditSurfaceDocument.parse(_threeDeepSource, 'root'),
    mediaLayer: layer,
    backend: backend,
    resolveSource: (String value) => value,
    maxRenderDepth: maxRenderDepth,
  );
}

void main() {
  const ui.Size size = ui.Size(2, 1);
  final ProjectTime frame0 =
      ProjectTime(frame: 0, mode: ProjectClockMode.scrub);

  test('runtime depth guard stops recursion independently of graph lint', () {
    final _CountingBackend backend = _CountingBackend();
    final EditVideoCompositor compositor = _buildCompositor(
      backend,
      maxRenderDepth: 2,
    );

    expect(
      () => compositor.render('root', frame0, size),
      throwsA(
        isA<StateError>()
            .having(
              (StateError error) => '$error',
              'message',
              contains('hard limit of 2'),
            )
            .having(
              (StateError error) => '$error',
              'source',
              contains('EDIT.leaf'),
            ),
      ),
    );

    // The linter accepts this three-level graph under its normal limit of 8.
    // The runtime guard fires before the over-limit leaf is rendered, so no
    // media decoder can have been opened as a side effect of descending too far.
    expect(backend.openCount, 0);
    expect(backend.requests, isEmpty);

    compositor.dispose();
    compositor.mediaLayer.dispose();
  });

  test('runtime depth guard allows a source exactly at the limit', () {
    final _CountingBackend backend = _CountingBackend();
    final EditVideoCompositor compositor = _buildCompositor(
      backend,
      maxRenderDepth: 3,
    );

    final EditVideoCompositeResult result =
        compositor.render('root', frame0, size);

    expect(result.rgba, isNotNull);
    expect(backend.openCount, 1);
    expect(backend.requests, <int>[0]);

    compositor.dispose();
    compositor.mediaLayer.dispose();
  });
}
