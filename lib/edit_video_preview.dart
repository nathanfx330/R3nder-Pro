// ./lib/edit_video_preview.dart
//
// Live MLT frame preview for the source-backed EDIT surface.
//
// R3nder owns project time, edit geometry, layer order, and final pixels. MLT
// owns persistent source decoders only. Parked frames use the exact render path.
// While the playhead is moving, native decoders run ahead on worker threads and
// this widget only polls completed frames. A pending decode holds the previous
// complete image instead of blocking the UI isolate or audio feeder.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'edit_model.dart';
import 'edit_surface_model.dart';
import 'edit_video_compositor.dart';
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
  final bool isPlaying;

  /// Moving preview uses a fixed smaller decode size. It changes only pixel
  /// cost, never project-time selection or source-frame mapping.
  final bool fastPreview;

  /// Optional seams for widget tests and alternate decoder experiments.
  final MediaDecoderBackend? backend;
  final String Function(String source)? resolveSource;

  const EditVideoPreview({
    super.key,
    required this.source,
    required this.editId,
    required this.currentFrame,
    required this.theme,
    this.isPlaying = false,
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
  static const Duration _pendingRetryDelay = Duration(milliseconds: 6);

  MediaLayer? _layer;
  EditVideoCompositor? _compositor;
  String? _layerSource;
  String? _layerEditId;
  ui.Image? _image;
  MediaFrame? _frame;
  int _contributorCount = 0;
  String _status = 'NO VIDEO AT THIS FRAME';
  int _epoch = 0;
  int _requestSerial = 0;
  bool _scheduled = false;
  Timer? _pendingRetry;

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
      _pendingRetry?.cancel();
      _disposeLayer();
      _epoch++;
    } else if (oldWidget.currentFrame != widget.currentFrame ||
        oldWidget.fastPreview != widget.fastPreview ||
        oldWidget.isPlaying != widget.isPlaying) {
      // Epoch invalidates late presentation, not the decoder or its read-ahead.
      _epoch++;
    }
    _scheduleRender();
  }

  @override
  void dispose() {
    _requestSerial++;
    _pendingRetry?.cancel();
    _pendingRetry = null;
    _disposeLayer();
    _replaceImage(null);
    super.dispose();
  }

  void _disposeLayer() {
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

  EditVideoCompositor _ensureCompositor() {
    final EditVideoCompositor? existing = _compositor;
    if (existing != null &&
        _layerSource == widget.source &&
        _layerEditId == widget.editId) {
      return existing;
    }

    _disposeLayer();
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

  bool get _moving => widget.isPlaying || widget.fastPreview;

  void _scheduleRender() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      unawaited(_renderCurrent());
    });
  }

  void _schedulePendingRetry() {
    if (_pendingRetry != null || !mounted) return;
    _pendingRetry = Timer(_pendingRetryDelay, () {
      _pendingRetry = null;
      if (mounted) _scheduleRender();
    });
  }

  Future<void> _renderCurrent() async {
    final int serial = ++_requestSerial;
    final int requestEpoch = _epoch;
    final ProjectTime time = ProjectTime(
      frame: widget.currentFrame,
      epoch: requestEpoch,
      mode: widget.isPlaying
          ? ProjectClockMode.monotonic
          : ProjectClockMode.scrub,
    );
    final ui.Size decodeSize =
        _moving ? _fastDecodeSize : _fullDecodeSize;

    EditVideoCompositeResult result;
    try {
      final EditVideoCompositor compositor = _ensureCompositor();
      result = _moving
          ? compositor.renderAvailable(widget.editId, time, decodeSize)
          : compositor.render(widget.editId, time, decodeSize);
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

    if (result.hasPending) {
      // Keep the last complete composite on screen. This is frame dropping, not
      // clock slowing: ProjectClock continues and the worker receives the next
      // target even if this exact picture misses its presentation deadline.
      if (_image == null && _status != 'DECODE AHEAD') {
        setState(() => _status = 'DECODE AHEAD');
      }
      _schedulePendingRetry();
      return;
    }

    if (!result.hasImage || result.rgba == null) {
      final MediaFrame? problem =
          result.mediaFrames.isEmpty ? null : result.mediaFrames.last;
      setState(() {
        _replaceImage(null);
        _frame = problem;
        _contributorCount = 0;
        if (problem == null) {
          _status = 'NO VIDEO AT FRAME ${widget.currentFrame}';
        } else if (problem.status == MediaFrameStatus.nestedEditPending) {
          _status = 'NESTED EDIT PREVIEW PENDING\n${problem.source}';
        } else {
          _status = 'OFFLINE\n${problem.source}\n${problem.error ?? ''}';
        }
      });
      return;
    }

    final MediaFrame? top = result.topFrame;

    // Frame identity and layer metadata are already authoritative at this
    // point. Publish them before the asynchronous Flutter image upload. The
    // pixel upload may complete on a later event-loop turn, but diagnostic
    // state must not pretend that no frame exists while those pixels are being
    // converted. This also keeps widget tests independent of engine image
    // callback timing.
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
    final MediaFrame? frame = _frame;

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
                        '${_moving ? '   ASYNC' : ''}',
                style: widget.theme.micro.copyWith(color: R3Theme.textMid),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
