// ./test/media_layer_test.dart

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/project_clock.dart';

class _FakeBackend implements MediaDecoderBackend {
  final Set<String> failingPaths;
  final int actualFrameDelta;
  int openCount = 0;
  final Map<String, _FakeDecoder> opened = <String, _FakeDecoder>{};

  _FakeBackend({
    this.failingPaths = const <String>{},
    this.actualFrameDelta = 0,
  });

  @override
  MediaDecoder open(String resolvedPath) {
    openCount += 1;
    if (failingPaths.contains(resolvedPath)) {
      throw MediaDecodeException('offline: $resolvedPath');
    }
    final _FakeDecoder decoder = _FakeDecoder(actualFrameDelta);
    opened[resolvedPath] = decoder;
    return decoder;
  }
}

class _FakeDecoder implements MediaDecoder {
  final int actualFrameDelta;
  final List<int> requests = <int>[];
  bool disposed = false;

  _FakeDecoder(this.actualFrameDelta);

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    if (disposed) throw StateError('decoder disposed');
    requests.add(requestedSourceFrame);
    return _frame(requestedSourceFrame, width, height, actualFrameDelta);
  }

  @override
  void dispose() {
    disposed = true;
  }
}

class _AsyncFakeBackend implements MediaDecoderBackend {
  int openCount = 0;
  _AsyncFakeDecoder? decoder;

  @override
  MediaDecoder open(String resolvedPath) {
    openCount += 1;
    return decoder = _AsyncFakeDecoder();
  }
}

class _AsyncFakeDecoder implements NonBlockingMediaDecoder {
  final List<int> requested = <int>[];
  int? readyFrame;
  bool disposed = false;

  @override
  void request(int requestedSourceFrame, int width, int height) {
    if (disposed) throw StateError('decoder disposed');
    requested.add(requestedSourceFrame);
  }

  @override
  DecodedMediaFrame? poll(
    int requestedSourceFrame,
    int width,
    int height,
  ) {
    if (disposed) throw StateError('decoder disposed');
    if (readyFrame != requestedSourceFrame) return null;
    return _frame(requestedSourceFrame, width, height, 0);
  }

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    if (disposed) throw StateError('decoder disposed');
    return _frame(requestedSourceFrame, width, height, 0);
  }

  @override
  void dispose() {
    disposed = true;
  }
}

DecodedMediaFrame _frame(
  int requestedSourceFrame,
  int width,
  int height,
  int actualFrameDelta,
) {
  return DecodedMediaFrame(
    requestedSourceFrame: requestedSourceFrame,
    actualSourceFrame: requestedSourceFrame + actualFrameDelta,
    width: width,
    height: height,
    stride: width * 4,
    rgba: Uint8List(width * height * 4),
  );
}

EditDocumentModel _model() {
  return EditDocumentModel.parse('''[EDIT:main]
  [TRACK:V1]
    [CLIP:a:video/a.mp4:10:5:20:2]
    [/CLIP]
    [CLIP:b:video/b.mp4:40:100:10:1/2]
    [/CLIP]
  [/TRACK]
  [TRACK:V2]
    [CLIP:overlay:video/overlay.mp4:10:30:50:1]
    [/CLIP]
  [/TRACK]
[/EDIT]
''');
}

EditDocumentModel _singleModel() {
  return EditDocumentModel.parse('''[EDIT:main]
  [TRACK:V1]
    [CLIP:a:video/a.mp4:0:0:20:1]
    [/CLIP]
  [/TRACK]
[/EDIT]
''');
}

ProjectTime _time(int frame, {int epoch = 0}) {
  return ProjectTime(
    frame: frame,
    epoch: epoch,
    mode: ProjectClockMode.scrub,
  );
}

void main() {
  test('render maps project time to exact source frames in track order', () {
    final _FakeBackend backend = _FakeBackend(actualFrameDelta: 1);
    final MediaLayer layer = MediaLayer(
      editDocument: _model(),
      backend: backend,
      resolveSource: (String source) => '/workspace/$source',
    );

    final MediaRenderResult result =
        layer.render('main', _time(12, epoch: 7), const ui.Size(4, 3));

    expect(result.frames, hasLength(2));
    expect(result.frames[0].trackId, 'V1');
    expect(result.frames[0].clipId, 'a');
    expect(result.frames[0].requestedSourceFrame, 9);
    expect(result.frames[0].actualSourceFrame, 10);
    expect(result.frames[0].rgba, hasLength(4 * 3 * 4));

    expect(result.frames[1].trackId, 'V2');
    expect(result.frames[1].clipId, 'overlay');
    expect(result.frames[1].requestedSourceFrame, 32);
    expect(result.frames[1].actualSourceFrame, 33);

    layer.dispose();
  });

  test('live render returns pending instead of blocking async decoder', () {
    final _AsyncFakeBackend backend = _AsyncFakeBackend();
    final MediaLayer layer = MediaLayer(
      editDocument: _singleModel(),
      backend: backend,
      resolveSource: (String source) => '/workspace/$source',
    );

    final MediaRenderResult pending =
        layer.renderAvailable('main', _time(3), const ui.Size(2, 2));

    expect(backend.openCount, 1);
    expect(pending.frames, hasLength(1));
    expect(pending.frames.single.status, MediaFrameStatus.pending);
    expect(pending.frames.single.requestedSourceFrame, 3);
    expect(pending.hasPending, isTrue);
    expect(backend.decoder!.requested, <int>[3]);

    backend.decoder!.readyFrame = 3;
    final MediaRenderResult ready =
        layer.renderAvailable('main', _time(3), const ui.Size(2, 2));

    expect(backend.openCount, 1);
    expect(ready.frames.single.status, MediaFrameStatus.decoded);
    expect(ready.frames.single.actualSourceFrame, 3);
    expect(ready.hasPending, isFalse);

    final MediaRenderResult next =
        layer.renderAvailable('main', _time(4), const ui.Size(2, 2));
    expect(next.frames.single.status, MediaFrameStatus.pending);
    expect(backend.openCount, 1);
    expect(backend.decoder!.requested, <int>[3, 3, 4]);

    layer.dispose();
  });

  test('persistent decoders survive epoch changes while stale results do not', () {
    final _FakeBackend backend = _FakeBackend();
    final MediaLayer layer = MediaLayer(
      editDocument: _model(),
      backend: backend,
      resolveSource: (String source) => '/workspace/$source',
    );

    final ProjectTime beforeSeek = _time(15, epoch: 2);
    final ProjectTime afterSeek = _time(15, epoch: 3);

    final MediaRenderResult first =
        layer.render('main', beforeSeek, const ui.Size(2, 2));
    final int cachedBeforeSeek = layer.cachedDecoderCount;
    final MediaRenderResult second =
        layer.render('main', afterSeek, const ui.Size(2, 2));

    expect(cachedBeforeSeek, 2);
    expect(layer.cachedDecoderCount, 2);
    expect(backend.openCount, 2);
    expect(first.canPresentAgainst(afterSeek), isFalse);
    expect(second.canPresentAgainst(afterSeek), isTrue);

    layer.dispose();
  });

  test('backwards requests reuse one source decoder without owning playhead', () {
    final _FakeBackend backend = _FakeBackend();
    final MediaLayer layer = MediaLayer(
      editDocument: _model(),
      backend: backend,
      resolveSource: (String source) => '/workspace/$source',
    );

    layer.render('main', _time(18), const ui.Size(2, 2));
    layer.render('main', _time(14), const ui.Size(2, 2));
    layer.render('main', _time(11), const ui.Size(2, 2));

    final _FakeDecoder decoder = backend.opened['/workspace/video/a.mp4']!;
    expect(decoder.requests, <int>[21, 13, 7]);
    expect(backend.openCount, 2);

    layer.dispose();
  });

  test('offline media returns an offline frame without changing edit duration', () {
    final _FakeBackend backend = _FakeBackend(
      failingPaths: <String>{'/workspace/video/a.mp4'},
    );
    final EditDocumentModel model = _model();
    final MediaLayer layer = MediaLayer(
      editDocument: model,
      backend: backend,
      resolveSource: (String source) => '/workspace/$source',
    );

    final int durationBefore = model.edit('main').projectFrameCount;
    final MediaRenderResult result =
        layer.render('main', _time(12), const ui.Size(2, 2));
    final int durationAfter = model.edit('main').projectFrameCount;

    expect(durationBefore, 60);
    expect(durationAfter, 60);
    expect(result.frames, hasLength(2));
    expect(result.frames[0].status, MediaFrameStatus.offline);
    expect(result.frames[0].requestedSourceFrame, 9);
    expect(result.frames[1].status, MediaFrameStatus.decoded);

    layer.dispose();
  });

  test('inactive project frames request no media', () {
    final _FakeBackend backend = _FakeBackend();
    final MediaLayer layer = MediaLayer(
      editDocument: _model(),
      backend: backend,
      resolveSource: (String source) => '/workspace/$source',
    );

    final MediaRenderResult result =
        layer.render('main', _time(5), const ui.Size(2, 2));

    expect(result.frames, isEmpty);
    expect(backend.openCount, 0);

    layer.dispose();
  });
}
