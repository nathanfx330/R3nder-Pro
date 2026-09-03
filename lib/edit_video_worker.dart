// ./lib/edit_video_worker.dart
//
// Persistent background worker for EDIT monitor rendering.
//
// The worker owns the same MediaLayer and EditVideoCompositor used by the
// synchronous preview path. MLT producers therefore remain persistent, but
// seek, decode, pixel copy, and compositing no longer block Flutter's UI
// isolate. Render messages are latest-wins: while one frame is decoding,
// newly queued playhead requests collapse to the newest request before the
// next decode begins.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'edit_model.dart';
import 'edit_surface_model.dart';
import 'edit_video_compositor.dart';
import 'media_layer.dart';
import 'project_clock.dart';

class EditVideoWorkerFrameInfo {
  final String trackId;
  final String clipId;
  final String source;
  final int requestedSourceFrame;
  final int? actualSourceFrame;
  final MediaFrameStatus status;
  final String? error;

  const EditVideoWorkerFrameInfo({
    required this.trackId,
    required this.clipId,
    required this.source,
    required this.requestedSourceFrame,
    required this.actualSourceFrame,
    required this.status,
    required this.error,
  });

  factory EditVideoWorkerFrameInfo.fromMessage(Map<Object?, Object?> message) {
    final String statusName = message['status'] as String? ?? 'offline';
    final MediaFrameStatus status = MediaFrameStatus.values.firstWhere(
      (MediaFrameStatus value) => value.name == statusName,
      orElse: () => MediaFrameStatus.offline,
    );
    return EditVideoWorkerFrameInfo(
      trackId: message['trackId'] as String? ?? '',
      clipId: message['clipId'] as String? ?? '',
      source: message['source'] as String? ?? '',
      requestedSourceFrame: message['requestedSourceFrame'] as int? ?? 0,
      actualSourceFrame: message['actualSourceFrame'] as int?,
      status: status,
      error: message['error'] as String?,
    );
  }
}

class EditVideoWorkerResult {
  final int serial;
  final int epoch;
  final int projectFrame;
  final int width;
  final int height;
  final int stride;
  final Uint8List? rgba;
  final EditVideoWorkerFrameInfo? topFrame;
  final EditVideoWorkerFrameInfo? problemFrame;
  final int contributorCount;
  final String? error;

  const EditVideoWorkerResult({
    required this.serial,
    required this.epoch,
    required this.projectFrame,
    required this.width,
    required this.height,
    required this.stride,
    required this.rgba,
    required this.topFrame,
    required this.problemFrame,
    required this.contributorCount,
    required this.error,
  });

  bool get hasImage => rgba != null;

  factory EditVideoWorkerResult.fromMessage(Map<Object?, Object?> message) {
    final TransferableTypedData? transferable =
        message['rgba'] as TransferableTypedData?;
    final ByteBuffer? buffer = transferable?.materialize();
    final Object? topRaw = message['topFrame'];
    final Object? problemRaw = message['problemFrame'];

    return EditVideoWorkerResult(
      serial: message['serial'] as int? ?? 0,
      epoch: message['epoch'] as int? ?? 0,
      projectFrame: message['projectFrame'] as int? ?? 0,
      width: message['width'] as int? ?? 0,
      height: message['height'] as int? ?? 0,
      stride: message['stride'] as int? ?? 0,
      rgba: buffer?.asUint8List(),
      topFrame: topRaw is Map<Object?, Object?>
          ? EditVideoWorkerFrameInfo.fromMessage(topRaw)
          : null,
      problemFrame: problemRaw is Map<Object?, Object?>
          ? EditVideoWorkerFrameInfo.fromMessage(problemRaw)
          : null,
      contributorCount: message['contributorCount'] as int? ?? 0,
      error: message['error'] as String?,
    );
  }
}

class EditVideoWorker {
  final String source;
  final String editId;
  final String workspaceRoot;
  final void Function(EditVideoWorkerResult result) onResult;

  final ReceivePort _receive = ReceivePort();
  StreamSubscription<dynamic>? _subscription;
  Isolate? _isolate;
  SendPort? _commands;
  Map<String, Object?>? _pendingBeforeReady;
  Timer? _killTimer;
  bool _disposed = false;
  String? _fatalError;
  int _latestSerial = 0;
  int _latestEpoch = 0;
  int _latestFrame = 0;

  EditVideoWorker({
    required this.source,
    required this.editId,
    required this.workspaceRoot,
    required this.onResult,
  }) {
    _subscription = _receive.listen(_handleMessage);
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final Isolate isolate = await Isolate.spawn<Map<String, Object?>>(
        _editVideoWorkerEntry,
        <String, Object?>{
          'hostPort': _receive.sendPort,
          'source': source,
          'editId': editId,
          'workspaceRoot': workspaceRoot,
        },
        debugName: 'r3nder-edit-video',
      );
      if (_disposed) {
        isolate.kill(priority: Isolate.immediate);
        return;
      }
      _isolate = isolate;
    } catch (error) {
      if (_disposed) return;
      _fatalError = '$error';
      _emitFatalIfRequested();
    }
  }

  void request({
    required int serial,
    required int epoch,
    required int projectFrame,
    required int width,
    required int height,
  }) {
    if (_disposed) return;
    _latestSerial = serial;
    _latestEpoch = epoch;
    _latestFrame = projectFrame;

    final String? fatal = _fatalError;
    if (fatal != null) {
      onResult(
        EditVideoWorkerResult(
          serial: serial,
          epoch: epoch,
          projectFrame: projectFrame,
          width: 0,
          height: 0,
          stride: 0,
          rgba: null,
          topFrame: null,
          problemFrame: null,
          contributorCount: 0,
          error: fatal,
        ),
      );
      return;
    }

    final Map<String, Object?> message = <String, Object?>{
      'type': 'render',
      'serial': serial,
      'epoch': epoch,
      'projectFrame': projectFrame,
      'width': width,
      'height': height,
    };
    final SendPort? commands = _commands;
    if (commands == null) {
      _pendingBeforeReady = message;
    } else {
      commands.send(message);
    }
  }

  void _handleMessage(dynamic raw) {
    if (_disposed || raw is! Map) return;
    final Map<Object?, Object?> message = raw.cast<Object?, Object?>();
    final String? type = message['type'] as String?;

    switch (type) {
      case 'ready':
        final SendPort? port = message['port'] as SendPort?;
        if (port == null) return;
        _commands = port;
        final Map<String, Object?>? pending = _pendingBeforeReady;
        _pendingBeforeReady = null;
        if (pending != null) port.send(pending);
        break;
      case 'frame':
        onResult(EditVideoWorkerResult.fromMessage(message));
        break;
      case 'fatal':
        _fatalError = message['error'] as String? ?? 'Edit video worker failed.';
        _emitFatalIfRequested();
        break;
      case 'disposed':
        _finish();
        break;
    }
  }

  void _emitFatalIfRequested() {
    final String? fatal = _fatalError;
    if (fatal == null || _latestSerial == 0 || _disposed) return;
    onResult(
      EditVideoWorkerResult(
        serial: _latestSerial,
        epoch: _latestEpoch,
        projectFrame: _latestFrame,
        width: 0,
        height: 0,
        stride: 0,
        rgba: null,
        topFrame: null,
        problemFrame: null,
        contributorCount: 0,
        error: fatal,
      ),
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final SendPort? commands = _commands;
    if (commands == null) {
      _finish();
      return;
    }

    commands.send(const <String, Object?>{'type': 'dispose'});
    _killTimer = Timer(const Duration(seconds: 1), _finish);
  }

  void _finish() {
    _killTimer?.cancel();
    _killTimer = null;
    _commands = null;
    _pendingBeforeReady = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _receive.close();
  }
}

@pragma('vm:entry-point')
void _editVideoWorkerEntry(Map<String, Object?> bootstrap) {
  final SendPort hostPort = bootstrap['hostPort']! as SendPort;
  final String source = bootstrap['source']! as String;
  final String editId = bootstrap['editId']! as String;
  final String workspaceRoot = bootstrap['workspaceRoot']! as String;
  final ReceivePort commands = ReceivePort();

  late final _EditVideoWorkerState state;
  try {
    state = _EditVideoWorkerState(
      source: source,
      editId: editId,
      workspaceRoot: workspaceRoot,
    );
  } catch (error) {
    hostPort.send(<String, Object?>{
      'type': 'fatal',
      'error': '$error',
    });
    commands.close();
    return;
  }

  Map<Object?, Object?>? pendingRender;
  bool renderScheduled = false;
  bool disposed = false;

  void scheduleLatestRender() {
    if (renderScheduled || disposed) return;
    renderScheduled = true;
    Timer.run(() {
      renderScheduled = false;
      if (disposed) return;
      final Map<Object?, Object?>? request = pendingRender;
      pendingRender = null;
      if (request == null) return;

      try {
        hostPort.send(state.render(request));
      } catch (error) {
        hostPort.send(<String, Object?>{
          'type': 'frame',
          'serial': request['serial'] as int? ?? 0,
          'epoch': request['epoch'] as int? ?? 0,
          'projectFrame': request['projectFrame'] as int? ?? 0,
          'width': 0,
          'height': 0,
          'stride': 0,
          'rgba': null,
          'topFrame': null,
          'problemFrame': null,
          'contributorCount': 0,
          'error': '$error',
        });
      }
      // Do not immediately start another render here. Any requests that
      // arrived while MLT was blocked are queued as isolate messages. Their
      // handlers run first, overwrite pendingRender, and schedule one new
      // Timer event. That is what gives this worker latest-wins semantics.
    });
  }

  commands.listen((dynamic raw) {
    if (disposed || raw is! Map) return;
    final Map<Object?, Object?> message = raw.cast<Object?, Object?>();
    switch (message['type']) {
      case 'render':
        pendingRender = message;
        scheduleLatestRender();
        break;
      case 'dispose':
        disposed = true;
        pendingRender = null;
        state.dispose();
        hostPort.send(const <String, Object?>{'type': 'disposed'});
        commands.close();
        break;
    }
  });

  hostPort.send(<String, Object?>{
    'type': 'ready',
    'port': commands.sendPort,
  });
}

class _EditVideoWorkerState {
  final String editId;
  final String workspaceRoot;
  final MediaLayer layer;
  final EditVideoCompositor compositor;
  bool _disposed = false;

  _EditVideoWorkerState({
    required String source,
    required this.editId,
    required this.workspaceRoot,
  })  : layer = MediaLayer(
          editDocument: EditDocumentModel.parse(source),
          backend: NativeMltMediaBackend(),
          resolveSource: (String authored) =>
              _resolveWorkerMediaSource(workspaceRoot, authored),
        ),
        compositor = _createCompositor(source, editId, workspaceRoot);

  static EditVideoCompositor _createCompositor(
    String source,
    String editId,
    String workspaceRoot,
  ) {
    final MediaDecoderBackend backend = NativeMltMediaBackend();
    final MediaLayer mediaLayer = MediaLayer(
      editDocument: EditDocumentModel.parse(source),
      backend: backend,
      resolveSource: (String authored) =>
          _resolveWorkerMediaSource(workspaceRoot, authored),
    );
    return EditVideoCompositor(
      document: EditSurfaceDocument.parse(source, editId),
      mediaLayer: mediaLayer,
      backend: backend,
      resolveSource: (String authored) =>
          _resolveWorkerMediaSource(workspaceRoot, authored),
    );
  }

  Map<String, Object?> render(Map<Object?, Object?> request) {
    if (_disposed) throw StateError('Edit video worker is disposed.');
    final int serial = request['serial'] as int? ?? 0;
    final int epoch = request['epoch'] as int? ?? 0;
    final int projectFrame = request['projectFrame'] as int? ?? 0;
    final int width = request['width'] as int? ?? 0;
    final int height = request['height'] as int? ?? 0;

    final EditVideoCompositeResult result = compositor.render(
      editId,
      ProjectTime(
        frame: projectFrame,
        epoch: epoch,
        mode: ProjectClockMode.scrub,
      ),
      ui.Size(width.toDouble(), height.toDouble()),
    );
    final MediaFrame? problem =
        result.mediaFrames.isEmpty ? null : result.mediaFrames.last;

    return <String, Object?>{
      'type': 'frame',
      'serial': serial,
      'epoch': epoch,
      'projectFrame': projectFrame,
      'width': result.width,
      'height': result.height,
      'stride': result.stride,
      'rgba': result.rgba == null
          ? null
          : TransferableTypedData.fromList(<Uint8List>[result.rgba!]),
      'topFrame': _frameInfoMessage(result.topFrame),
      'problemFrame': _frameInfoMessage(problem),
      'contributorCount': result.contributors.length,
      'error': null,
    };
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    compositor.dispose();
    // compositor owns a distinct MediaLayer internally. The field above is
    // retained only to make ownership explicit if worker construction fails
    // before compositor creation. It has no decoded frames in normal use.
    layer.dispose();
  }
}

Map<String, Object?>? _frameInfoMessage(MediaFrame? frame) {
  if (frame == null) return null;
  return <String, Object?>{
    'trackId': frame.trackId,
    'clipId': frame.clipId,
    'source': frame.source,
    'requestedSourceFrame': frame.requestedSourceFrame,
    'actualSourceFrame': frame.actualSourceFrame,
    'status': frame.status.name,
    'error': frame.error,
  };
}

String _resolveWorkerMediaSource(String workspaceRoot, String source) {
  final String trimmed = source.trim();
  if (trimmed.isEmpty) {
    throw const FileSystemException('Media source path is empty.');
  }
  if (_isAbsolutePath(trimmed)) return trimmed;

  final String portable = trimmed
      .replaceAll('\\', Platform.pathSeparator)
      .replaceAll('/', Platform.pathSeparator);
  return File('$workspaceRoot${Platform.pathSeparator}$portable').path;
}

bool _isAbsolutePath(String path) {
  if (path.startsWith('/') || path.startsWith('\\\\')) return true;
  return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
}
