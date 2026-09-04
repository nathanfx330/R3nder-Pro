// ./test/structural_source_export_test.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/structural_source_export.dart';

class _RecordingBackend implements MediaDecoderBackend {
  final Map<String, List<int>> requests = <String, List<int>>{};
  final int actualFrameOffset;
  int openCount = 0;

  _RecordingBackend({this.actualFrameOffset = 0});

  @override
  MediaDecoder open(String resolvedPath) {
    openCount++;
    return _RecordingDecoder(
      resolvedPath,
      actualFrameOffset,
      (int frame) => requests
          .putIfAbsent(resolvedPath, () => <int>[])
          .add(frame),
    );
  }
}

class _RecordingDecoder implements MediaDecoder {
  final String path;
  final int actualFrameOffset;
  final void Function(int frame) onRequest;

  _RecordingDecoder(this.path, this.actualFrameOffset, this.onRequest);

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    onRequest(requestedSourceFrame);

    final List<int> color;
    if (path.contains('red')) {
      color = const <int>[255, 0, 0, 255];
    } else if (path.contains('blue')) {
      color = const <int>[0, 0, 255, 255];
    } else {
      color = <int>[requestedSourceFrame & 0xff, 64, 128, 255];
    }

    final Uint8List rgba = Uint8List(width * height * 4);
    for (int i = 0; i < rgba.length; i += 4) {
      rgba.setRange(i, i + 4, color);
    }

    return DecodedMediaFrame(
      requestedSourceFrame: requestedSourceFrame,
      actualSourceFrame: requestedSourceFrame + actualFrameOffset,
      width: width,
      height: height,
      stride: width * 4,
      rgba: rgba,
    );
  }

  @override
  void dispose() {}
}

void main() {
  test('EDIT export duration and nested frame mapping come only from authored graph',
      () {
    const String source = '''[EDIT:child]
[TRACK:V1]
[CLIP:leaf:leaf.mp4:0:10:20:1]
[/CLIP]
[/TRACK]
[/EDIT]
[EDIT:main]
[TRACK:V1]
[CLIP:nested:EDIT.child:0:3:5:2]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final _RecordingBackend backend = _RecordingBackend();
    final StructuralSourceFrameRenderer renderer =
        StructuralSourceFrameRenderer.create(
      source: source,
      structuralSource: 'EDIT.main',
      width: 4,
      height: 2,
      backend: backend,
      resolveSource: (String value) => value,
    );

    expect(renderer.totalFrames, 5);

    final Uint8List frame = renderer.renderFrame(2);

    // main frame 2 maps through its 2x nested CLIP to child frame 7. The child
    // then maps frame 7 to leaf.mp4 frame 17.
    expect(backend.requests['leaf.mp4'], <int>[17]);
    expect(frame.length, 4 * 2 * 4);
    expect(frame.sublist(0, 4), <int>[17, 64, 128, 255]);

    renderer.dispose();
  });

  test('MOSAIC can be exported as the root without any EDIT anchor', () {
    const String source = '''[MOSAIC:wall]
[PANE:left]
[CLIP:red:red.mp4:0:0:2:1]
[/CLIP]
[/PANE]
[PANE:right]
[CLIP:blue:blue.mp4:0:0:2:1]
[/CLIP]
[/PANE]
[/MOSAIC]
''';

    final _RecordingBackend backend = _RecordingBackend();
    final StructuralSourceFrameRenderer renderer =
        StructuralSourceFrameRenderer.create(
      source: source,
      structuralSource: 'MOSAIC.wall',
      width: 10,
      height: 4,
      backend: backend,
      resolveSource: (String value) => value,
    );

    expect(renderer.totalFrames, 2);
    final Uint8List frame = renderer.renderFrame(0);

    List<int> pixel(int x, int y) {
      final int at = (y * 10 + x) * 4;
      return frame.sublist(at, at + 4);
    }

    expect(pixel(0, 0), <int>[255, 0, 0, 255]);
    expect(pixel(7, 0), <int>[0, 0, 255, 255]);
    expect(backend.openCount, 2);

    renderer.dispose();
  });

  test('authored empty timeline space exports transparent rather than holding', () {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:late:leaf.mp4:2:0:2:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final _RecordingBackend backend = _RecordingBackend();
    final StructuralSourceFrameRenderer renderer =
        StructuralSourceFrameRenderer.create(
      source: source,
      structuralSource: 'EDIT.main',
      width: 3,
      height: 2,
      backend: backend,
      resolveSource: (String value) => value,
    );

    expect(renderer.totalFrames, 4);
    final Uint8List gap = renderer.renderFrame(0);
    expect(gap, everyElement(0));
    expect(backend.openCount, 0);

    renderer.renderFrame(2);
    expect(backend.requests['leaf.mp4'], <int>[0]);

    renderer.dispose();
  });

  test('offline leaf is a hard export error rather than a transparent omission', () {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:missing:missing.mp4:0:0:2:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final StructuralSourceFrameRenderer renderer =
        StructuralSourceFrameRenderer.create(
      source: source,
      structuralSource: 'EDIT.main',
      width: 2,
      height: 2,
      backend: _RecordingBackend(),
      resolveSource: (String value) {
        throw FileSystemException('not found', value);
      },
    );

    expect(
      () => renderer.renderFrame(0),
      throwsA(
        isA<MediaDecodeException>().having(
          (MediaDecodeException error) => error.message,
          'message',
          contains('Offline source "missing.mp4"'),
        ),
      ),
    );

    renderer.dispose();
  });

  test('nested offline leaf remains a hard error even when sibling pixels render',
      () {
    const String source = '''[EDIT:child]
[TRACK:V1]
[CLIP:good:good.mp4:0:0:2:1]
[/CLIP]
[/TRACK]
[TRACK:V2]
[CLIP:missing:missing.mp4:0:0:2:1]
[/CLIP]
[/TRACK]
[/EDIT]
[EDIT:main]
[TRACK:V1]
[CLIP:nested:EDIT.child:0:0:2:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final StructuralSourceFrameRenderer renderer =
        StructuralSourceFrameRenderer.create(
      source: source,
      structuralSource: 'EDIT.main',
      width: 2,
      height: 2,
      backend: _RecordingBackend(),
      resolveSource: (String value) {
        if (value == 'missing.mp4') {
          throw FileSystemException('not found', value);
        }
        return value;
      },
    );

    expect(
      () => renderer.renderFrame(0),
      throwsA(
        isA<MediaDecodeException>().having(
          (MediaDecodeException error) => error.message,
          'message',
          contains('Offline source "missing.mp4"'),
        ),
      ),
    );

    renderer.dispose();
  });

  test('decoder returning adjacent source frame is rejected during export', () {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:leaf:leaf.mp4:0:5:2:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final StructuralSourceFrameRenderer renderer =
        StructuralSourceFrameRenderer.create(
      source: source,
      structuralSource: 'EDIT.main',
      width: 2,
      height: 2,
      backend: _RecordingBackend(actualFrameOffset: 1),
      resolveSource: (String value) => value,
    );

    expect(
      () => renderer.renderFrame(0),
      throwsA(
        isA<MediaDecodeException>().having(
          (MediaDecodeException error) => error.message,
          'message',
          contains('returned frame 6 when exact frame 5 was requested'),
        ),
      ),
    );

    renderer.dispose();
  });

  test('nested adjacent source frame mismatch is preserved through structural frame',
      () {
    const String source = '''[EDIT:child]
[TRACK:V1]
[CLIP:leaf:leaf.mp4:0:5:2:1]
[/CLIP]
[/TRACK]
[/EDIT]
[EDIT:main]
[TRACK:V1]
[CLIP:nested:EDIT.child:0:0:2:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final StructuralSourceFrameRenderer renderer =
        StructuralSourceFrameRenderer.create(
      source: source,
      structuralSource: 'EDIT.main',
      width: 2,
      height: 2,
      backend: _RecordingBackend(actualFrameOffset: 1),
      resolveSource: (String value) => value,
    );

    expect(
      () => renderer.renderFrame(0),
      throwsA(
        isA<MediaDecodeException>().having(
          (MediaDecodeException error) => error.message,
          'message',
          contains('returned frame 6 when exact frame 5 was requested'),
        ),
      ),
    );

    renderer.dispose();
  });

  test('mixed structural cycle is rejected before a decoder opens', () {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:wall:MOSAIC.wall:0:0:2:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:pane]
[CLIP:main:EDIT.main:0:0:2:1]
[/CLIP]
[/PANE]
[/MOSAIC]
''';

    final _RecordingBackend backend = _RecordingBackend();

    expect(
      () => StructuralSourceFrameRenderer.create(
        source: source,
        structuralSource: 'EDIT.main',
        width: 2,
        height: 2,
        backend: backend,
        resolveSource: (String value) => value,
      ),
      throwsA(
        isA<StateError>().having(
          (StateError error) => '$error',
          'message',
          contains('Structural source graph is not exportable'),
        ),
      ),
    );
    expect(backend.openCount, 0);
  });
}
