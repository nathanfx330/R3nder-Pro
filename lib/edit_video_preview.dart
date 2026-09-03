// ./lib/edit_video_preview.dart
//
// Live MLT frame preview for the source-backed EDIT surface.
//
// The script remains canonical. This widget reparses authored EDIT geometry
// when source changes, then keeps one MediaLayer alive while the playhead
// scrubs so persistent MLT producers survive forwards and backwards seeks.
// Project time is supplied explicitly. The decoder never owns the playhead.

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'edit_model.dart';
import 'media_layer.dart';
import 'project_clock.dart';
import 'session_store.dart';
import 'ui_theme.dart';

bool _isAbsolutePath(String path) {
  if (path.startsWith('/') || path.startsWith('\\\\')) return true;
  return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
}

/// Resolves an authored CLIP source against the active R3nder workspace.
///
/// Relative paths are portable project paths. `video/intro.mp4` means
/// `<workspace>/video/intro.mp4`. Absolute paths are accepted for diagnostic
/// and development use, but portable scripts should stay workspace-relative.
String resolveWorkspaceMediaSource(String source) {
  final String trimmed = source.trim();
  if (trimmed.isEmpty) {
    throw const FileSystemException('CLIP source path is empty.');
  }
  if (_isAbsolutePath(trimmed)) return trimmed;

  final String baseDir = resolvePortableBaseDir();
  final SessionStore session = SessionStore(baseDir: baseDir)..load();
  final String? workspace = session.workspace;
  if (workspace == null || workspace.trim().isEmpty) {
    throw FileSystemException(
      'No active workspace is available for this CLIP source.',
      trimmed,
    );
  }

  final String portable = trimmed
      .replaceAll('\\', Platform.pathSeparator)
      .replaceAll('/', Platform.pathSeparator);
  return File('$workspace${Platform.pathSeparator}$portable').path;
}

/// Chooses the opaque picture shown by the first live edit preview.
///
/// V tracks follow familiar compositor order: V2 is above V1, V3 above V2,
/// and so on. Unknown track names fall back to authored result order. This is
/// deliberately not transition compositing. Crossfades and luma are authored
/// already, but combining two decoded pictures belongs to the compositor
/// slice, not to decoder plumbing.
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

  /// Optional seams for widget tests and non-native experiments.
  final MediaDecoderBackend? backend;
  final String Function(String source)? resolveSource;

  const EditVideoPreview({
    super.key,
    required this.source,
    required this.editId,
    required this.currentFrame,
    required this.theme,
    this.backend,
    this.resolveSource,
  });

  @override
  State<EditVideoPreview> createState() => _EditVideoPreviewState();
}

class _EditVideoPreviewState extends State<EditVideoPreview> {
  static const ui.Size _decodeSize = ui.Size(960, 540);

  MediaLayer? _layer;
  String? _layerSource;
  String? _layerEditId;
  ui.Image? _image;
  MediaFrame? _frame;
  String _status = 'NO VIDEO AT THIS FRAME';
  int _epoch = 0;
  int _requestSerial = 0;
  bool _scheduled = false;

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
      _disposeLayer();
      _epoch++;
    } else if (oldWidget.currentFrame != widget.currentFrame) {
      // A scrub invalidates an in-flight presentation without throwing away
      // persistent source decoders. This is the M9 epoch rule at the UI edge.
      _epoch++;
    }
    _scheduleRender();
  }

  @override
  void dispose() {
    _requestSerial++;
    _disposeLayer();
    _replaceImage(null);
    super.dispose();
  }

  void _disposeLayer() {
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

  MediaLayer _ensureLayer() {
    final MediaLayer? existing = _layer;
    if (existing != null &&
        _layerSource == widget.source &&
        _layerEditId == widget.editId) {
      return existing;
    }

    _disposeLayer();
    final EditDocumentModel model = EditDocumentModel.parse(widget.source);
    final MediaLayer next = MediaLayer(
      editDocument: model,
      backend: widget.backend ?? NativeMltMediaBackend(),
      resolveSource: widget.resolveSource ?? resolveWorkspaceMediaSource,
    );
    _layer = next;
    _layerSource = widget.source;
    _layerEditId = widget.editId;
    return next;
  }

  void _scheduleRender() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      unawaited(_renderCurrent());
    });
  }

  Future<void> _renderCurrent() async {
    final int serial = ++_requestSerial;
    final int requestEpoch = _epoch;
    final ProjectTime time = ProjectTime(
      frame: widget.currentFrame,
      epoch: requestEpoch,
      mode: ProjectClockMode.scrub,
    );

    MediaRenderResult result;
    try {
      final MediaLayer layer = _ensureLayer();
      result = layer.render(widget.editId, time, _decodeSize);
    } catch (error) {
      if (!mounted || serial != _requestSerial) return;
      setState(() {
        _replaceImage(null);
        _frame = null;
        _status = 'VIDEO PREVIEW UNAVAILABLE\n$error';
      });
      return;
    }

    if (!mounted || serial != _requestSerial || requestEpoch != _epoch) return;

    final MediaFrame? chosen = selectVisibleEditFrame(result.frames);
    if (chosen == null || chosen.rgba == null) {
      final MediaFrame? problem = result.frames.isEmpty ? null : result.frames.last;
      setState(() {
        _replaceImage(null);
        _frame = problem;
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

    // Publish the decoded frame identity immediately. Converting raw RGBA into
    // a ui.Image is asynchronous, but the source mapping is already known and
    // should not be hidden behind that presentation-only conversion. This also
    // makes the preview metadata deterministic under fast scrubbing.
    setState(() {
      _frame = chosen;
      _status = 'DECODING FRAME';
    });

    final ui.Image decoded;
    try {
      decoded = await _decodeRgba(chosen);
    } catch (error) {
      if (!mounted || serial != _requestSerial) return;
      setState(() {
        _replaceImage(null);
        _frame = chosen;
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
      _frame = chosen;
      _status = '';
    });
  }

  Future<ui.Image> _decodeRgba(MediaFrame frame) {
    final Completer<ui.Image> completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      frame.rgba!,
      frame.width,
      frame.height,
      ui.PixelFormat.rgba8888,
      completer.complete,
      rowBytes: frame.stride,
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
                        '${frame.actualSourceFrame == null ? '' : '→${frame.actualSourceFrame}'}',
                style: widget.theme.micro.copyWith(color: R3Theme.textMid),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
