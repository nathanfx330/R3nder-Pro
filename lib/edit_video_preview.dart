// ./lib/edit_video_preview.dart
//
// Live MLT frame preview for the source-backed EDIT surface.
//
// The script remains canonical. Production preview rendering runs in a
// persistent worker isolate so MLT seek/decode and R3nder compositing never
// block Flutter pointer handling. Tests with injected decoder seams retain the
// synchronous path. MLT still decodes source frames only. Project time is
// supplied explicitly and no decoder owns the playhead.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'edit_media_import.dart';
import 'edit_model.dart';
import 'edit_surface_model.dart';
import 'edit_video_compositor.dart';
import 'edit_video_worker.dart';
import 'media_layer.dart';
import 'project_clock.dart';
import 'session_store.dart';
import 'ui_theme.dart';

bool _isAbsolutePath(String path) {
  if (path.startsWith('/') || path.startsWith('\\\\')) return true;
  return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
}

/// Resolves an authored CLIP or luma-mask source against the active workspace.
String resolveWorkspaceMediaSource(String source) {
  final String trimmed = source.trim();
  if (trimmed.isEmpty) {
    throw const FileSystemException('Media source path is empty.');
  }
  if (_isAbsolutePath(trimmed)) return trimmed;

  final String baseDir = resolvePortableBaseDir();
  final SessionStore session = SessionStore(baseDir: baseDir)..load();
  final String? workspace = session.workspace;
  if (workspace == null || workspace.trim().isEmpty) {
    throw FileSystemException(
      'No active workspace is available for this media source.',
      trimmed,
    );
  }

  final String portable = trimmed
      .replaceAll('\\', Platform.pathSeparator)
      .replaceAll('/', Platform.pathSeparator);
  return File('$workspace${Platform.pathSeparator}$portable').path;
}

/// Retained as a small public ordering helper for tests and diagnostics.
/// Runtime presentation now uses EditVideoCompositor instead of discarding
/// every active frame except this one.
MediaFrame? selectVisibleEditFrame(List<MediaFrame> frames) {
  MediaFrame? selected;
  int selectedRank = -1;

  for (int i = 0; i < frames.length; i++) {
    final MediaFrame frame = frames[i];
    if (!frame.isDecoded) continue;

    final RegExpMatch? videoTrack = RegExp(r'^V(\d+)$').firstMatch(frame.trackId);
    final int rank = videoTrack == null ? i : int.parse(videoTrack.group(1)!);
    if (selected == null || rank >= selectedRank) {
      selected = frame;
      selectedRank = rank;
    }
  }

  return selected;
}

class EditVideoPreview extends StatefulWidget {
  final String source;
  final String editId;
  final int currentFrame;
  final R3Theme theme;

  /// True while the playhead is moving continuously. Realtime preview trades
  /// decode resolution for responsiveness, then redraws the parked frame at
  /// full resolution when motion stops. Project frame selection is unchanged.
  final bool fastPreview;

  /// Optional seams for widget tests and non-native experiments. Supplying
  /// either seam keeps rendering on the current isolate so fake decoder state
  /// remains directly observable by tests.
  final MediaDecoderBackend? backend;
  final String Function(String source)? resolveSource;

  const EditVideoPreview({
    super.key,
    required this.source,
    required this.editId,
    required this.currentFrame,
    required this.theme,
    this.fastPreview = false,
    this.backend,
    this.resolveSource,
  });

  @override
  State<EditVideoPreview> createState() => _EditVideoPreviewState();
}

class _EditVideoPreviewState extends State<EditVideoPreview> {
  static const ui.Size _fullDecodeSize = ui.Size(960, 540);
  static const ui.Size _fastDecodeSize = ui.Size(480, 270);

  MediaLayer? _layer;
  EditVideoCompositor? _compositor;
  String? _layerSource;
  String? _layerEditId;

  EditVideoWorker? _worker;
  String? _workerSource;
  String? _workerEditId;
  int _workerGeneration = 0;

  ui.Image? _image;
  EditVideoWorkerFrameInfo? _frame;
  int _contributorCount = 0;
  String _status = 'NO VIDEO AT THIS FRAME';
  int _epoch = 0;
  int _requestSerial = 0;
  bool _scheduled = false;

  bool get _useWorker =>
      widget.backend == null &&
      widget.resolveSource == null &&
      Platform.isLinux;

  @override
  void initState() {
    super.initState();
    _scheduleRender();
  }

  @override
  void didUpdateWidget(covariant EditVideoPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool sourceChanged = oldWidget.source != widget.source ||
        oldWidget.editId != widget.editId ||
        oldWidget.backend != widget.backend ||
        oldWidget.resolveSource != widget.resolveSource;
    if (sourceChanged) {
      _disposePipeline();
      _epoch++;
    } else if (oldWidget.currentFrame != widget.currentFrame ||
        oldWidget.fastPreview != widget.fastPreview) {
      // Presentation changes never discard persistent source decoders. The
      // same MLT producer survives scrub, playback, pause, and quality switch.
      _epoch++;
    }
    _scheduleRender();
  }

  @override
  void dispose() {
    _requestSerial++;
    _disposePipeline();
    _replaceImage(null);
    super.dispose();
  }

  void _disposePipeline() {
    _workerGeneration++;
    _worker?.dispose();
    _worker = null;
    _workerSource = null;
    _workerEditId = null;

    _compositor?.dispose();
    _compositor = null;
    _layer?.dispose();
    _layer = null;
    _layerSource = null;
    _layerEditId = null;
  }

  void _replaceImage(ui.Image? next) {
    final ui.Image? old = _image;
    _image = next;
    if (old != null && !identical(old, next)) old.dispose();
  }

  EditVideoCompositor _ensureSynchronousCompositor() {
    final EditVideoCompositor? existing = _compositor;
    if (existing != null &&
        _layerSource == widget.source &&
        _layerEditId == widget.editId) {
      return existing;
    }

    _compositor?.dispose();
    _compositor = null;
    _layer?.dispose();
    _layer = null;

    final EditDocumentModel model = EditDocumentModel.parse(widget.source);
    final EditSurfaceDocument surface =
        EditSurfaceDocument.parse(widget.source, widget.editId);
    final MediaDecoderBackend backend = widget.backend ?? NativeMltMediaBackend();
    final String Function(String source) resolver =
        widget.resolveSource ?? resolveWorkspaceMediaSource;
    final MediaLayer layer = MediaLayer(
      editDocument: model,
      backend: backend,
      resolveSource: resolver,
    );
    final EditVideoCompositor compositor = EditVideoCompositor(
      document: surface,
      mediaLayer: layer,
      backend: backend,
      resolveSource: resolver,
    );

    _layer = layer;
    _compositor = compositor;
    _layerSource = widget.source;
    _layerEditId = widget.editId;
    return compositor;
  }

  EditVideoWorker _ensureWorker() {
    final EditVideoWorker? existing = _worker;
    if (existing != null &&
        _workerSource == widget.source &&
        _workerEditId == widget.editId) {
      return existing;
    }

    _workerGeneration++;
    _worker?.dispose();
    final int generation = _workerGeneration;
    final String workspaceRoot = resolveActiveWorkspaceRoot();
    final EditVideoWorker worker = EditVideoWorker(
      source: widget.source,
      editId: widget.editId,
      workspaceRoot: workspaceRoot,
      onResult: (EditVideoWorkerResult result) {
        if (!mounted || generation != _workerGeneration) return;
        unawaited(_presentWorkerResult(result));
      },
    );

    _worker = worker;
    _workerSource = widget.source;
    _workerEditId = widget.editId;
    return worker;
  }

  void _scheduleRender() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      if (_useWorker) {
        _requestWorkerRender();
      } else {
        unawaited(_renderCurrentSynchronously());
      }
    });
  }

  ui.Size get _decodeSize =>
      widget.fastPreview ? _fastDecodeSize : _fullDecodeSize;

  void _requestWorkerRender() {
    final int serial = ++_requestSerial;
    final int requestEpoch = _epoch;
    final ui.Size size = _decodeSize;

    try {
      _ensureWorker().request(
        serial: serial,
        epoch: requestEpoch,
        projectFrame: widget.currentFrame,
        width: size.width.round(),
        height: size.height.round(),
      );
    } catch (error) {
      if (!mounted || serial != _requestSerial) return;
      setState(() {
        _replaceImage(null);
        _frame = null;
        _contributorCount = 0;
        _status = 'VIDEO PREVIEW UNAVAILABLE\n$error';
      });
    }
  }

  Future<void> _presentWorkerResult(EditVideoWorkerResult result) async {
    if (!mounted ||
        result.serial != _requestSerial ||
        result.epoch != _epoch ||
        result.projectFrame != widget.currentFrame) {
      return;
    }

    final String? workerError = result.error;
    if (workerError != null) {
      setState(() {
        _replaceImage(null);
        _frame = null;
        _contributorCount = 0;
        _status = 'VIDEO PREVIEW UNAVAILABLE\n$workerError';
      });
      return;
    }

    if (!result.hasImage || result.rgba == null) {
      _presentNoImage(result.problemFrame);
      return;
    }

    setState(() {
      _frame = result.topFrame;
      _contributorCount = result.contributorCount;
      _status = 'COMPOSITING FRAME';
    });

    final ui.Image decoded;
    try {
      decoded = await _decodeRgba(
        result.rgba!,
        result.width,
        result.height,
        result.stride,
      );
    } catch (error) {
      if (!mounted || result.serial != _requestSerial) return;
      setState(() {
        _replaceImage(null);
        _frame = result.topFrame;
        _status = 'FRAME CONVERSION FAILED\n$error';
      });
      return;
    }

    if (!mounted ||
        result.serial != _requestSerial ||
        result.epoch != _epoch ||
        result.projectFrame != widget.currentFrame) {
      decoded.dispose();
      return;
    }

    setState(() {
      _replaceImage(decoded);
      _frame = result.topFrame;
      _contributorCount = result.contributorCount;
      _status = '';
    });
  }

  Future<void> _renderCurrentSynchronously() async {
    final int serial = ++_requestSerial;
    final int requestEpoch = _epoch;
    final ProjectTime time = ProjectTime(
      frame: widget.currentFrame,
      epoch: requestEpoch,
      mode: ProjectClockMode.scrub,
    );

    EditVideoCompositeResult result;
    try {
      result = _ensureSynchronousCompositor().render(
        widget.editId,
        time,
        _decodeSize,
      );
    } catch (error) {
      if (!mounted || serial != _requestSerial) return;
      setState(() {
        _replaceImage(null);
        _frame = null;
        _contributorCount = 0;
        _status = 'VIDEO PREVIEW UNAVAILABLE\n$error';
      });
      return;
    }

    if (!mounted || serial != _requestSerial || requestEpoch != _epoch) return;

    if (!result.hasImage || result.rgba == null) {
      final MediaFrame? problem =
          result.mediaFrames.isEmpty ? null : result.mediaFrames.last;
      _presentNoImage(_frameInfo(problem));
      return;
    }

    final EditVideoWorkerFrameInfo? top = _frameInfo(result.topFrame);
    setState(() {
      _frame = top;
      _contributorCount = result.contributors.length;
      _status = 'COMPOSITING FRAME';
    });

    final ui.Image decoded;
    try {
      decoded = await _decodeRgba(
        result.rgba!,
        result.width,
        result.height,
        result.stride,
      );
    } catch (error) {
      if (!mounted || serial != _requestSerial) return;
      setState(() {
        _replaceImage(null);
        _frame = top;
        _status = 'FRAME CONVERSION FAILED\n$error';
      });
      return;
    }

    if (!mounted || serial != _requestSerial || requestEpoch != _epoch) {
      decoded.dispose();
      return;
    }

    setState(() {
      _replaceImage(decoded);
      _frame = top;
      _contributorCount = result.contributors.length;
      _status = '';
    });
  }

  void _presentNoImage(EditVideoWorkerFrameInfo? problem) {
    if (!mounted) return;
    setState(() {
      _replaceImage(null);
      _frame = problem;
      _contributorCount = 0;
      if (problem == null || problem.status == MediaFrameStatus.decoded) {
        _status = 'NO VIDEO AT FRAME ${widget.currentFrame}';
      } else if (problem.status == MediaFrameStatus.nestedEditPending) {
        _status = 'NESTED EDIT PREVIEW PENDING\n${problem.source}';
      } else {
        _status = 'OFFLINE\n${problem.source}\n${problem.error ?? ''}';
      }
    });
  }

  EditVideoWorkerFrameInfo? _frameInfo(MediaFrame? frame) {
    if (frame == null) return null;
    return EditVideoWorkerFrameInfo(
      trackId: frame.trackId,
      clipId: frame.clipId,
      source: frame.source,
      requestedSourceFrame: frame.requestedSourceFrame,
      actualSourceFrame: frame.actualSourceFrame,
      status: frame.status,
      error: frame.error,
    );
  }

  Future<ui.Image> _decodeRgba(
    Uint8List rgba,
    int width,
    int height,
    int stride,
  ) {
    final Completer<ui.Image> completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
      rowBytes: stride,
    );
    return completer.future;
  }

  @override
  Widget build(BuildContext context) {
    final ui.Image? image = _image;
    final EditVideoWorkerFrameInfo? frame = _frame;

    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (image != null)
            RawImage(
              image: image,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.low,
            )
          else
            Center(
              child: Padding(
                padding: EdgeInsets.all(sc(18)),
                child: Text(
                  _status,
                  textAlign: TextAlign.center,
                  style: widget.theme.micro.copyWith(color: R3Theme.textDim),
                ),
              ),
            ),
          Positioned(
            left: sc(8),
            bottom: sc(7),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: sc(6), vertical: sc(3)),
              color: Colors.black.withValues(alpha: 0.72),
              child: Text(
                frame == null
                    ? 'EDIT ${widget.editId}  F${widget.currentFrame}'
                    : '${frame.trackId} / ${frame.clipId}   '
                        'P${widget.currentFrame}   '
                        'SRC ${frame.requestedSourceFrame}'
                        '${frame.actualSourceFrame == null ? '' : '→${frame.actualSourceFrame}'}   '
                        'LAYERS $_contributorCount'
                        '${widget.fastPreview ? '   FAST' : ''}'
                        '${_useWorker ? '   BG' : ''}',
                style: widget.theme.micro.copyWith(color: R3Theme.textMid),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
