// ./lib/edit_video_preview.dart
//
// Live MLT preview for the source-backed EDIT surface.
//
// The normal single-clip path follows the architecture already proven in
// MLT Player: MLT renders continuously into a native external Flutter texture.
// Dart does not pull RGBA frames through FFI while the playhead moves.
//
// R3nder still owns project time and edit geometry. The native preview is only
// a display follower. Multi-layer overlaps remain on the deterministic CPU
// compositor until that edit graph is moved to the same native texture path.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'edit_model.dart';
import 'edit_native_preview.dart';
import 'edit_surface_model.dart';
import 'edit_video_compositor.dart';
import 'engine.dart';
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

  /// Used only by the CPU fallback. Native texture playback stays on the
  /// source-profile render path while moving.
  final bool fastPreview;

  /// Optional seams for deterministic widget tests. Supplying either one
  /// deliberately selects the synchronous compositor path.
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
  static const Duration _texturePollInterval = Duration(milliseconds: 50);

  NativeEditPreview? _native;
  Timer? _texturePoll;
  int _textureId = -1;
  String? _nativeResolvedSource;
  String? _nativeClipKey;
  int? _nativeSourceFrame;
  bool _nativePlaying = false;
  bool _showNative = false;
  EditSurfaceClip? _nativeClip;
  String? _nativeUnavailable;

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

  bool get _hasTestSeam => widget.backend != null || widget.resolveSource != null;

  @override
  void initState() {
    super.initState();
    _initializeNativeIfAvailable();
    _scheduleRender();
  }

  @override
  void didUpdateWidget(covariant EditVideoPreview oldWidget) {
    super.didUpdateWidget(oldWidget);

    final bool pipelineChanged = oldWidget.backend != widget.backend ||
        oldWidget.resolveSource != widget.resolveSource;
    final bool authoredEditChanged = oldWidget.source != widget.source ||
        oldWidget.editId != widget.editId;

    if (pipelineChanged) {
      _disposeSynchronousLayer();
      _closeNativeSource();
      _native = null;
      _nativeUnavailable = null;
      _initializeNativeIfAvailable();
      _epoch++;
    } else if (authoredEditChanged) {
      _disposeSynchronousLayer();
      _nativeClipKey = null;
      _nativeSourceFrame = null;
      _epoch++;
    } else if (oldWidget.currentFrame != widget.currentFrame ||
        oldWidget.fastPreview != widget.fastPreview ||
        oldWidget.isPlaying != widget.isPlaying) {
      _epoch++;
    }

    _scheduleRender();
  }

  @override
  void dispose() {
    _requestSerial++;
    _texturePoll?.cancel();
    _disposeSynchronousLayer();
    _replaceImage(null);
    _native?.close();
    _native = null;
    super.dispose();
  }

  void _initializeNativeIfAvailable() {
    if (_hasTestSeam || !NativeEditPreview.isSupported) return;
    try {
      _native = NativeEditPreview();
      _refreshTextureId();
    } catch (error) {
      _native = null;
      _nativeUnavailable = '$error';
    }
  }

  void _refreshTextureId() {
    _texturePoll?.cancel();
    _texturePoll = null;
    final NativeEditPreview? native = _native;
    if (native == null || !mounted) return;

    try {
      final int next = native.textureId;
      if (next > 0) {
        if (_textureId != next) setState(() => _textureId = next);
        return;
      }
    } catch (error) {
      _nativeUnavailable = '$error';
      return;
    }

    _texturePoll = Timer(_texturePollInterval, _refreshTextureId);
  }

  void _closeNativeSource() {
    final NativeEditPreview? native = _native;
    if (native != null && _nativeResolvedSource != null) {
      try {
        native.close();
      } catch (_) {}
    }
    _nativeResolvedSource = null;
    _nativeClipKey = null;
    _nativeSourceFrame = null;
    _nativePlaying = false;
    _nativeClip = null;
    _showNative = false;
  }

  void _disposeSynchronousLayer() {
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

    _disposeSynchronousLayer();
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
    if (!_hasTestSeam && _native != null) {
      final EditSurfaceClip? nativeClip = _singleNativeClipAtCurrentFrame();
      if (nativeClip != null) {
        ++_requestSerial;
        _disposeSynchronousLayer();
        _replaceImage(null);
        _driveNative(nativeClip);
        return;
      }
    }

    if (_showNative || _nativePlaying) {
      final NativeEditPreview? native = _native;
      if (native != null && _nativeSourceFrame != null) {
        try {
          native.pauseAt(_nativeSourceFrame!);
        } catch (_) {}
      }
      _nativePlaying = false;
      _showNative = false;
      _nativeClip = null;
    }

    await _renderSynchronous();
  }

  EditSurfaceClip? _singleNativeClipAtCurrentFrame() {
    try {
      final EditSurfaceDocument document =
          EditSurfaceDocument.parse(widget.source, widget.editId);
      final List<EditSurfaceClip> active = <EditSurfaceClip>[];

      for (final EditSurfaceTrack track in document.tracks) {
        if (!RegExp(r'^V\d+$').hasMatch(track.id)) continue;
        for (final EditSurfaceClip clip in track.clips) {
          if (widget.currentFrame >= clip.atFrame &&
              widget.currentFrame < clip.endFrameExclusive) {
            active.add(clip);
          }
        }
      }

      if (active.length != 1) return null;
      final EditSurfaceClip clip = active.single;
      if (!clip.transition.isNone || clip.source.startsWith('EDIT.')) return null;
      return clip;
    } catch (_) {
      return null;
    }
  }

  void _driveNative(EditSurfaceClip clip) {
    final NativeEditPreview? native = _native;
    if (native == null) return;

    final String resolved;
    try {
      resolved = resolveWorkspaceMediaSource(clip.source);
    } catch (error) {
      _showNativeError('OFFLINE\n${clip.source}\n$error');
      return;
    }

    final int projectOffset = widget.currentFrame - clip.atFrame;
    final int sourceFrame = clip.clip.sourceFrameAtProjectOffset(projectOffset);
    final String clipKey = '${clip.trackId}:${clip.id}:${clip.source}:'
        '${clip.speed.numerator}/${clip.speed.denominator}';

    try {
      if (_nativeResolvedSource != resolved) {
        native.close();
        if (!native.open(resolved)) {
          _showNativeError('VIDEO PREVIEW UNAVAILABLE\n${native.lastError}');
          return;
        }
        _nativeResolvedSource = resolved;
        _nativeClipKey = null;
        _nativeSourceFrame = null;
        _nativePlaying = false;
        _refreshTextureId();
      }

      if (widget.isPlaying) {
        // Once playback starts, do not seek on every ProjectClock tick. MLT's
        // consumer renders and feeds the texture continuously. R3nder anchors
        // it only at play start or a canonical clip/speed boundary.
        if (!_nativePlaying || _nativeClipKey != clipKey) {
          if (!native.playFrom(
            sourceFrame: sourceFrame,
            projectRate: RationalFrameRate(engineFps),
            clipSpeed: clip.speed,
          )) {
            _showNativeError('VIDEO PLAYBACK UNAVAILABLE\n${native.lastError}');
            return;
          }
          _nativePlaying = true;
          _nativeClipKey = clipKey;
          _nativeSourceFrame = sourceFrame;
        }
      } else {
        final bool needsSeek = _nativePlaying ||
            _nativeClipKey != clipKey ||
            _nativeSourceFrame != sourceFrame;
        if (needsSeek) {
          final bool ok = _nativePlaying
              ? native.pauseAt(sourceFrame)
              : native.seekFrame(sourceFrame);
          if (!ok) {
            _showNativeError('VIDEO SEEK UNAVAILABLE\n${native.lastError}');
            return;
          }
        }
        _nativePlaying = false;
        _nativeClipKey = clipKey;
        _nativeSourceFrame = sourceFrame;
      }
    } catch (error) {
      _showNativeError('VIDEO PREVIEW UNAVAILABLE\n$error');
      return;
    }

    final bool changed = !_showNative ||
        _nativeClip?.trackId != clip.trackId ||
        _nativeClip?.id != clip.id ||
        _status.isNotEmpty;
    _showNative = true;
    _nativeClip = clip;
    _status = '';
    _frame = null;
    _contributorCount = 1;
    if (changed && mounted) setState(() {});
  }

  void _showNativeError(String message) {
    _nativePlaying = false;
    _showNative = false;
    _nativeClip = null;
    _status = message;
    if (mounted) setState(() {});
  }

  Future<void> _renderSynchronous() async {
    final int serial = ++_requestSerial;
    final int requestEpoch = _epoch;
    final ProjectTime time = ProjectTime(
      frame: widget.currentFrame,
      epoch: requestEpoch,
      mode: ProjectClockMode.scrub,
    );
    final ui.Size decodeSize =
        widget.fastPreview ? _fastDecodeSize : _fullDecodeSize;

    EditVideoCompositeResult result;
    try {
      result = _ensureCompositor().render(widget.editId, time, decodeSize);
    } catch (error) {
      if (!mounted || serial != _requestSerial) return;
      setState(() {
        _replaceImage(null);
        _frame = null;
        _contributorCount = 0;
        final String nativeNote = _nativeUnavailable == null
            ? ''
            : '\nNATIVE TEXTURE UNAVAILABLE\n$_nativeUnavailable';
        _status = 'VIDEO PREVIEW UNAVAILABLE\n$error$nativeNote';
      });
      return;
    }

    if (!mounted || serial != _requestSerial || requestEpoch != _epoch) return;

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
    final EditSurfaceClip? nativeClip = _nativeClip;
    final int? nativeExpectedSourceFrame = nativeClip == null
        ? null
        : nativeClip.clip.sourceFrameAtProjectOffset(
            widget.currentFrame - nativeClip.atFrame,
          );

    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_showNative && _textureId > 0)
            Center(
              child: AspectRatio(
                // The first native parity gate targets the same 16:9 source
                // used to expose the playback regression. Native source-size
                // getters are the next small presentation cleanup, not part of
                // the transport path itself.
                aspectRatio: 16 / 9,
                child: Texture(
                  textureId: _textureId,
                  filterQuality: FilterQuality.low,
                ),
              ),
            )
          else if (image != null)
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
                  _showNative && _textureId <= 0
                      ? 'WAITING FOR NATIVE VIDEO TEXTURE'
                      : _status,
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
                _showNative && nativeClip != null
                    ? '${nativeClip.trackId} / ${nativeClip.id}   '
                        'P${widget.currentFrame}   '
                        'SRC ${nativeExpectedSourceFrame ?? 0}   '
                        'LAYERS 1   NATIVE'
                        '${widget.isPlaying ? '   PLAY' : ''}'
                    : frame == null
                        ? 'EDIT ${widget.editId}  F${widget.currentFrame}'
                        : '${frame.trackId} / ${frame.clipId}   '
                            'P${widget.currentFrame}   '
                            'SRC ${frame.requestedSourceFrame}'
                            '${frame.actualSourceFrame == null ? '' : '→${frame.actualSourceFrame}'}   '
                            'LAYERS $_contributorCount   CPU'
                            '${widget.fastPreview ? '   FAST' : ''}',
                style: widget.theme.micro.copyWith(color: R3Theme.textMid),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
