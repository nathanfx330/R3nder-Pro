// ./lib/edit_video_preview.dart
//
// Live MLT frame preview for the source-backed EDIT surface.
//
// R3nder owns project time, edit geometry, layer order, and final pixels. MLT
// owns persistent source decoders only. During playback, EditWorkspace publishes
// ProjectClock samples at Flutter vsync. A single plain active video clip uses
// the Linux external texture path, so its decoded RGBA never crosses into Dart.
// Overlaps, transitions, test backends, and unsupported platforms retain the
// deterministic CPU compositor fallback.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'edit_model.dart';
import 'edit_playback_frame.dart';
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

  MediaLayer? _layer;
  EditVideoCompositor? _compositor;
  EditSurfaceDocument? _surface;
  String? _layerSource;
  String? _layerEditId;

  late final ValueNotifier<ui.Image?> _image;
  late final ValueNotifier<int?> _nativeTextureId;
  late final ValueNotifier<_PreviewMetadata> _metadata;
  ValueListenable<EditPlaybackFrameState>? _playbackFrames;
  EditPlaybackFrameState? _lastPlaybackState;

  int _epoch = 0;
  int _requestSerial = 0;
  int _parkedScheduleGeneration = 0;
  bool _parkedRenderScheduled = false;

  @override
  void initState() {
    super.initState();
    _image = ValueNotifier<ui.Image?>(null);
    _nativeTextureId = ValueNotifier<int?>(null);
    _metadata = ValueNotifier<_PreviewMetadata>(
      _PreviewMetadata(
        frame: null,
        contributorCount: 0,
        projectFrame: widget.currentFrame,
        moving: widget.isPlaying || widget.fastPreview,
        nativeTexture: false,
        status: 'NO VIDEO AT THIS FRAME',
      ),
    );
    _scheduleParkedRender();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ValueListenable<EditPlaybackFrameState>? next =
        EditPlaybackFrameScope.maybeOf(context);
    if (identical(next, _playbackFrames)) return;

    _playbackFrames?.removeListener(_onPlaybackFrameChanged);
    _playbackFrames = next;
    _lastPlaybackState = next?.value;
    next?.addListener(_onPlaybackFrameChanged);
    _epoch++;
    _scheduleParkedRender();
  }

  @override
  void didUpdateWidget(covariant EditVideoPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool sourceChanged = oldWidget.source != widget.source ||
        oldWidget.editId != widget.editId ||
        oldWidget.backend != widget.backend ||
        oldWidget.resolveSource != widget.resolveSource;

    if (sourceChanged) {
      _cancelParkedRender();
      _setNativeTexture(null);
      _disposeLayer();
      _replaceImage(null);
      _epoch++;
      _scheduleParkedRender();
      return;
    }

    if (_playbackFrames == null) {
      if (oldWidget.currentFrame != widget.currentFrame ||
          oldWidget.fastPreview != widget.fastPreview ||
          oldWidget.isPlaying != widget.isPlaying) {
        _epoch++;
        _scheduleParkedRender();
      }
      return;
    }

    if (oldWidget.fastPreview != widget.fastPreview) {
      _epoch++;
      _scheduleParkedRender();
    }
  }

  @override
  void dispose() {
    _requestSerial++;
    _cancelParkedRender();
    _playbackFrames?.removeListener(_onPlaybackFrameChanged);
    _playbackFrames = null;
    _setNativeTexture(null);
    _disposeLayer();

    final ui.Image? oldImage = _image.value;
    _image.value = null;
    oldImage?.dispose();
    _image.dispose();
    _nativeTextureId.dispose();
    _metadata.dispose();
    super.dispose();
  }

  void _disposeLayer() {
    _compositor?.dispose();
    _compositor = null;
    _surface = null;
    _layer?.dispose();
    _layer = null;
    _layerSource = null;
    _layerEditId = null;
  }

  void _replaceImage(ui.Image? next) {
    final ui.Image? old = _image.value;
    if (identical(old, next)) return;
    _image.value = next;
    old?.dispose();
  }

  void _setNativeTexture(int? textureId) {
    if (_nativeTextureId.value != textureId) {
      _nativeTextureId.value = textureId;
    }
  }

  void _publishMetadata(_PreviewMetadata next) {
    if (_metadata.value != next) {
      _metadata.value = next;
    }
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
    _surface = surface;
    _layerSource = widget.source;
    _layerEditId = widget.editId;
    return compositor;
  }

  _NativeTextureTarget? _singleNativeTextureTarget(int projectFrame) {
    final EditSurfaceDocument? surface = _surface;
    if (surface == null) return null;

    _NativeTextureTarget? target;
    int activeCount = 0;

    for (final EditSurfaceTrack track in surface.tracks) {
      if (!RegExp(r'^V\d+$').hasMatch(track.id)) continue;
      for (final EditSurfaceClip clip in track.clips) {
        if (projectFrame < clip.atFrame ||
            projectFrame >= clip.endFrameExclusive) {
          continue;
        }

        activeCount++;
        if (activeCount > 1) return null;
        if (!clip.transition.isNone || clip.source.startsWith('EDIT.')) {
          return null;
        }

        final int projectOffset = projectFrame - clip.atFrame;
        target = _NativeTextureTarget(
          trackId: clip.trackId,
          clipId: clip.id,
          source: clip.source,
          sourceFrame: clip.clip.sourceFrameAtProjectOffset(projectOffset),
        );
      }
    }

    return activeCount == 1 ? target : null;
  }

  void _publishNativeMetadata(
    _NativeTextureTarget target,
    int projectFrame,
    bool moving,
  ) {
    final _PreviewMetadata current = _metadata.value;
    final MediaFrame? currentFrame = current.frame;

    // Do not rebuild the diagnostic overlay every playback frame. Once the
    // monitor has entered TEXTURE mode for this clip, the external texture can
    // advance independently at native presentation cadence.
    if (current.nativeTexture &&
        current.status.isEmpty &&
        currentFrame?.trackId == target.trackId &&
        currentFrame?.clipId == target.clipId &&
        currentFrame?.source == target.source &&
        current.moving == moving) {
      return;
    }

    _publishMetadata(
      _PreviewMetadata(
        frame: MediaFrame.pending(
          trackId: target.trackId,
          clipId: target.clipId,
          source: target.source,
          requestedSourceFrame: target.sourceFrame,
        ),
        contributorCount: 1,
        projectFrame: projectFrame,
        moving: moving,
        nativeTexture: true,
        status: '',
      ),
    );
  }

  EditPlaybackFrameState get _effectivePlaybackState {
    final ValueListenable<EditPlaybackFrameState>? scoped = _playbackFrames;
    if (scoped != null) return scoped.value;
    return EditPlaybackFrameState(
      frame: widget.currentFrame,
      isPlaying: widget.isPlaying,
    );
  }

  void _onPlaybackFrameChanged() {
    final ValueListenable<EditPlaybackFrameState>? scoped = _playbackFrames;
    if (scoped == null || !mounted) return;
    final EditPlaybackFrameState next = scoped.value;
    if (next == _lastPlaybackState) return;

    _lastPlaybackState = next;
    _cancelParkedRender();
    _epoch++;

    unawaited(
      _renderFrame(
        next.frame,
        playing: next.isPlaying,
        moving: next.isPlaying || widget.fastPreview,
      ),
    );
  }

  void _scheduleParkedRender() {
    if (_parkedRenderScheduled || !mounted) return;
    _parkedRenderScheduled = true;
    final int generation = ++_parkedScheduleGeneration;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _parkedScheduleGeneration) return;
      _parkedRenderScheduled = false;
      final EditPlaybackFrameState state = _effectivePlaybackState;
      unawaited(
        _renderFrame(
          state.frame,
          playing: state.isPlaying,
          moving: state.isPlaying || widget.fastPreview,
        ),
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _cancelParkedRender() {
    if (!_parkedRenderScheduled) return;
    _parkedScheduleGeneration++;
    _parkedRenderScheduled = false;
  }

  Future<void> _renderFrame(
    int projectFrame, {
    required bool playing,
    required bool moving,
  }) async {
    final int serial = ++_requestSerial;
    final int requestEpoch = _epoch;
    final ProjectTime time = ProjectTime(
      frame: projectFrame,
      epoch: requestEpoch,
      mode: playing ? ProjectClockMode.monotonic : ProjectClockMode.scrub,
    );
    final ui.Size decodeSize = moving ? _fastDecodeSize : _fullDecodeSize;

    late final EditVideoCompositor compositor;
    try {
      compositor = _ensureCompositor();
    } catch (error) {
      if (!mounted || serial != _requestSerial) return;
      _setNativeTexture(null);
      _replaceImage(null);
      _publishMetadata(
        _PreviewMetadata(
          frame: null,
          contributorCount: 0,
          projectFrame: projectFrame,
          moving: moving,
          nativeTexture: false,
          status: 'VIDEO PREVIEW UNAVAILABLE\n$error',
        ),
      );
      return;
    }

    // The plain one-clip case bypasses Dart pixels completely. This is the
    // production path under test for the Spring clip. If the backend is a fake,
    // another platform, an overlap, or a transition, presentNativeTexture()
    // returns null and the deterministic CPU path below remains authoritative.
    final _NativeTextureTarget? textureTarget =
        _singleNativeTextureTarget(projectFrame);
    final MediaLayer? layer = _layer;
    if (textureTarget != null && layer != null) {
      int? textureId;
      try {
        textureId = layer.presentNativeTexture(
          source: textureTarget.source,
          requestedSourceFrame: textureTarget.sourceFrame,
          width: decodeSize.width.round(),
          height: decodeSize.height.round(),
        );
      } catch (_) {
        // A texture presentation failure does not make the source offline.
        // Fall back to the same CPU compositor used by tests and transitions.
        textureId = null;
      }

      if (textureId != null && textureId > 0) {
        if (!mounted || serial != _requestSerial || requestEpoch != _epoch) {
          return;
        }
        _replaceImage(null);
        _setNativeTexture(textureId);
        _publishNativeMetadata(textureTarget, projectFrame, moving);
        return;
      }
    }

    _setNativeTexture(null);

    EditVideoCompositeResult result;
    try {
      result = moving
          ? compositor.renderAvailable(widget.editId, time, decodeSize)
          : compositor.render(widget.editId, time, decodeSize);
    } catch (error) {
      if (!mounted || serial != _requestSerial) return;
      _replaceImage(null);
      _publishMetadata(
        _PreviewMetadata(
          frame: null,
          contributorCount: 0,
          projectFrame: projectFrame,
          moving: moving,
          nativeTexture: false,
          status: 'VIDEO PREVIEW UNAVAILABLE\n$error',
        ),
      );
      return;
    }

    if (!mounted || serial != _requestSerial || requestEpoch != _epoch) return;

    if (result.hasPending) {
      if (_image.value == null) {
        _publishMetadata(
          _PreviewMetadata(
            frame: null,
            contributorCount: 0,
            projectFrame: projectFrame,
            moving: moving,
            nativeTexture: false,
            status: 'DECODE AHEAD',
          ),
        );
      }
      if (!playing) _scheduleParkedRender();
      return;
    }

    if (!result.hasImage || result.rgba == null) {
      final MediaFrame? problem =
          result.mediaFrames.isEmpty ? null : result.mediaFrames.last;
      String status;
      if (problem == null) {
        status = 'NO VIDEO AT FRAME $projectFrame';
      } else if (problem.status == MediaFrameStatus.nestedEditPending) {
        status = 'NESTED EDIT PREVIEW PENDING\n${problem.source}';
      } else {
        status = 'OFFLINE\n${problem.source}\n${problem.error ?? ''}';
      }

      _replaceImage(null);
      _publishMetadata(
        _PreviewMetadata(
          frame: problem,
          contributorCount: 0,
          projectFrame: projectFrame,
          moving: moving,
          nativeTexture: false,
          status: status,
        ),
      );
      return;
    }

    final MediaFrame? top = result.topFrame;

    _publishMetadata(
      _PreviewMetadata(
        frame: top,
        contributorCount: result.contributors.length,
        projectFrame: projectFrame,
        moving: moving,
        nativeTexture: false,
        status: '',
      ),
    );

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
      _publishMetadata(
        _PreviewMetadata(
          frame: top,
          contributorCount: result.contributors.length,
          projectFrame: projectFrame,
          moving: moving,
          nativeTexture: false,
          status: 'FRAME CONVERSION FAILED\n$error',
        ),
      );
      return;
    }

    if (!mounted || serial != _requestSerial || requestEpoch != _epoch) {
      decoded.dispose();
      return;
    }

    _replaceImage(decoded);
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
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: ValueListenableBuilder<int?>(
              valueListenable: _nativeTextureId,
              builder: (
                BuildContext context,
                int? textureId,
                Widget? child,
              ) {
                if (textureId != null && textureId > 0) {
                  return ColoredBox(
                    color: Colors.black,
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: 16 / 9,
                        child: Texture(
                          textureId: textureId,
                          filterQuality: FilterQuality.low,
                        ),
                      ),
                    ),
                  );
                }

                return CustomPaint(
                  painter: _PreviewImagePainter(_image),
                );
              },
            ),
          ),
          ValueListenableBuilder<_PreviewMetadata>(
            valueListenable: _metadata,
            builder: (
              BuildContext context,
              _PreviewMetadata metadata,
              Widget? child,
            ) {
              return Stack(
                fit: StackFit.expand,
                children: [
                  if (metadata.status.isNotEmpty)
                    Center(
                      child: Padding(
                        padding: EdgeInsets.all(sc(18)),
                        child: Text(
                          metadata.status,
                          textAlign: TextAlign.center,
                          style: widget.theme.micro.copyWith(
                            color: R3Theme.textDim,
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    left: sc(8),
                    bottom: sc(7),
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: sc(6),
                        vertical: sc(3),
                      ),
                      color: Colors.black.withValues(alpha: 0.72),
                      child: Text(
                        metadata.label(widget.editId),
                        style: widget.theme.micro.copyWith(
                          color: R3Theme.textMid,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _NativeTextureTarget {
  final String trackId;
  final String clipId;
  final String source;
  final int sourceFrame;

  const _NativeTextureTarget({
    required this.trackId,
    required this.clipId,
    required this.source,
    required this.sourceFrame,
  });
}

@immutable
class _PreviewMetadata {
  final MediaFrame? frame;
  final int contributorCount;
  final int projectFrame;
  final bool moving;
  final bool nativeTexture;
  final String status;

  const _PreviewMetadata({
    required this.frame,
    required this.contributorCount,
    required this.projectFrame,
    required this.moving,
    required this.nativeTexture,
    required this.status,
  });

  String label(String editId) {
    final MediaFrame? current = frame;
    if (current == null) return 'EDIT $editId  F$projectFrame';
    return '${current.trackId} / ${current.clipId}   '
        'P$projectFrame   '
        'SRC ${current.requestedSourceFrame}'
        '${current.actualSourceFrame == null ? '' : '→${current.actualSourceFrame}'}   '
        'LAYERS $contributorCount'
        '${nativeTexture ? '   TEXTURE' : moving ? '   ASYNC' : ''}';
  }

  @override
  bool operator ==(Object other) {
    return other is _PreviewMetadata &&
        identical(other.frame, frame) &&
        other.contributorCount == contributorCount &&
        other.projectFrame == projectFrame &&
        other.moving == moving &&
        other.nativeTexture == nativeTexture &&
        other.status == status;
  }

  @override
  int get hashCode => Object.hash(
        identityHashCode(frame),
        contributorCount,
        projectFrame,
        moving,
        nativeTexture,
        status,
      );
}

class _PreviewImagePainter extends CustomPainter {
  final ValueListenable<ui.Image?> image;

  _PreviewImagePainter(this.image) : super(repaint: image);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Colors.black,
    );

    final ui.Image? current = image.value;
    if (current == null || size.width <= 0 || size.height <= 0) return;

    final double sourceWidth = current.width.toDouble();
    final double sourceHeight = current.height.toDouble();
    final double scale = mathMin(
      size.width / sourceWidth,
      size.height / sourceHeight,
    );
    final double drawWidth = sourceWidth * scale;
    final double drawHeight = sourceHeight * scale;
    final Rect destination = Rect.fromLTWH(
      (size.width - drawWidth) / 2,
      (size.height - drawHeight) / 2,
      drawWidth,
      drawHeight,
    );

    canvas.drawImageRect(
      current,
      Rect.fromLTWH(0, 0, sourceWidth, sourceHeight),
      destination,
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(covariant _PreviewImagePainter oldDelegate) {
    return !identical(oldDelegate.image, image);
  }
}

double mathMin(double a, double b) => a < b ? a : b;
