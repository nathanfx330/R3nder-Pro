// ./lib/edit_video_compositor.dart
//
// Deterministic pixel compositor for EDIT video tracks.
//
// MLT decodes source frames. R3nder owns project time, track ordering,
// transition progress, and final pixels. No decoder advances the playhead.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'edit_surface_model.dart';
import 'media_layer.dart';
import 'project_clock.dart';

class EditVideoCompositeResult {
  final int width;
  final int height;
  final int stride;
  final Uint8List? rgba;
  final MediaFrame? topFrame;
  final List<MediaFrame> contributors;
  final List<MediaFrame> mediaFrames;

  const EditVideoCompositeResult({
    required this.width,
    required this.height,
    required this.stride,
    required this.rgba,
    required this.topFrame,
    required this.contributors,
    required this.mediaFrames,
  });

  bool get hasImage => rgba != null;
  bool get hasPending =>
      mediaFrames.any((MediaFrame frame) => frame.isPending);
}

class EditVideoCompositor {
  final EditSurfaceDocument document;
  final MediaLayer mediaLayer;
  final MediaDecoderBackend backend;
  final String Function(String source) resolveSource;

  final Map<String, MediaDecoder> _maskDecoders = <String, MediaDecoder>{};
  final Map<String, DecodedMediaFrame> _maskFrames =
      <String, DecodedMediaFrame>{};
  bool _disposed = false;

  EditVideoCompositor({
    required this.document,
    required this.mediaLayer,
    required this.backend,
    required this.resolveSource,
  });

  /// Exact parked-frame composition. Source decoders may wait for their native
  /// workers, so this is intentionally not the live playback path.
  EditVideoCompositeResult render(
    String editId,
    ProjectTime time,
    ui.Size size,
  ) {
    _checkAlive();
    return _compose(
      mediaLayer.render(editId, time, size),
      time,
      size,
    );
  }

  /// Nonblocking live composition. Native source decoders only publish targets
  /// and poll their read-ahead rings. A missing exact frame is represented as
  /// pending, allowing the monitor to hold its last image instead of stalling
  /// ProjectClock or the audio feeder.
  EditVideoCompositeResult renderAvailable(
    String editId,
    ProjectTime time,
    ui.Size size,
  ) {
    _checkAlive();
    return _compose(
      mediaLayer.renderAvailable(editId, time, size),
      time,
      size,
    );
  }

  EditVideoCompositeResult _compose(
    MediaRenderResult media,
    ProjectTime time,
    ui.Size size,
  ) {
    final List<_ActiveLayer> layers = <_ActiveLayer>[];

    for (int index = 0; index < media.frames.length; index++) {
      final MediaFrame frame = media.frames[index];
      if (!frame.isDecoded || frame.rgba == null) continue;
      final int? trackRank = _videoTrackRank(frame.trackId);
      if (trackRank == null) continue;

      EditSurfaceClip clip;
      try {
        clip = document.clip(frame.trackId, frame.clipId);
      } catch (_) {
        continue;
      }

      layers.add(
        _ActiveLayer(
          frame: frame,
          clip: clip,
          trackRank: trackRank,
          authoredIndex: index,
        ),
      );
    }

    layers.sort((_ActiveLayer a, _ActiveLayer b) {
      final int trackCompare = a.trackRank.compareTo(b.trackRank);
      if (trackCompare != 0) return trackCompare;
      return a.authoredIndex.compareTo(b.authoredIndex);
    });

    if (layers.isEmpty) {
      return EditVideoCompositeResult(
        width: size.width.round(),
        height: size.height.round(),
        stride: size.width.round() * 4,
        rgba: null,
        topFrame: null,
        contributors: const <MediaFrame>[],
        mediaFrames: media.frames,
      );
    }

    final int width = layers.first.frame.width;
    final int height = layers.first.frame.height;
    final int stride = width * 4;

    // The overwhelmingly common playback case is one decoded video layer with
    // no active transition. The native decoder has already produced the final
    // RGBA pixels for that picture, so allocating another buffer and running a
    // Dart alpha blend over every pixel only burns presentation time. A fully
    // completed transition is equivalent and can use the same direct path.
    if (layers.length == 1) {
      final _ActiveLayer only = layers.single;
      final MediaFrame frame = only.frame;
      final EditTransition transition = only.clip.transition;
      final int projectOffset = time.frame - only.clip.atFrame;
      final double progress = _transitionProgress(
        projectOffset,
        transition.frames,
      );
      if (transition.kind == EditTransitionKind.none || progress >= 1.0) {
        return EditVideoCompositeResult(
          width: frame.width,
          height: frame.height,
          stride: frame.stride,
          rgba: frame.rgba,
          topFrame: frame,
          contributors: List<MediaFrame>.unmodifiable(<MediaFrame>[frame]),
          mediaFrames: media.frames,
        );
      }
    }

    final Uint8List output = Uint8List(stride * height);
    final List<MediaFrame> contributors = <MediaFrame>[];
    MediaFrame? topFrame;

    for (final _ActiveLayer layer in layers) {
      final MediaFrame frame = layer.frame;
      if (frame.width != width || frame.height != height) continue;

      final int projectOffset = time.frame - layer.clip.atFrame;
      final EditTransition transition = layer.clip.transition;
      final double progress = _transitionProgress(
        projectOffset,
        transition.frames,
      );

      bool contributed = false;
      switch (transition.kind) {
        case EditTransitionKind.none:
          contributed = _blendUniform(output, frame, 1.0);
          break;
        case EditTransitionKind.crossfade:
          contributed = _blendUniform(output, frame, progress);
          break;
        case EditTransitionKind.luma:
          if (progress >= 1.0) {
            contributed = _blendUniform(output, frame, 1.0);
          } else if (progress > 0.0 && transition.lumaSource.isNotEmpty) {
            final DecodedMediaFrame? mask = _decodeMask(
              transition.lumaSource,
              width,
              height,
            );
            if (mask != null) {
              contributed = _blendLuma(output, frame, mask, progress);
            }
          }
          break;
      }

      if (contributed) {
        contributors.add(frame);
        topFrame = frame;
      }
    }

    return EditVideoCompositeResult(
      width: width,
      height: height,
      stride: stride,
      rgba: contributors.isEmpty ? null : output,
      topFrame: topFrame,
      contributors: List<MediaFrame>.unmodifiable(contributors),
      mediaFrames: media.frames,
    );
  }

  DecodedMediaFrame? _decodeMask(String source, int width, int height) {
    try {
      final String resolved = resolveSource(source);
      final String key = '$resolved@${width}x$height';
      final DecodedMediaFrame? cached = _maskFrames[key];
      if (cached != null) return cached;

      final MediaDecoder decoder = _maskDecoders.putIfAbsent(
        resolved,
        () => backend.open(resolved),
      );
      final DecodedMediaFrame decoded = decoder.render(0, width, height);
      _maskFrames[key] = decoded;
      return decoded;
    } catch (_) {
      return null;
    }
  }

  static double _transitionProgress(int projectOffset, int frames) {
    if (frames <= 0) return 1.0;
    if (frames == 1) return 1.0;
    if (projectOffset <= 0) return 0.0;
    if (projectOffset >= frames - 1) return 1.0;
    return projectOffset / (frames - 1);
  }

  static bool _blendUniform(
    Uint8List destination,
    MediaFrame source,
    double opacity,
  ) {
    if (opacity <= 0.0 || source.rgba == null) return false;
    final Uint8List pixels = source.rgba!;
    final int width = source.width;
    final int height = source.height;
    bool contributed = false;

    for (int y = 0; y < height; y++) {
      final int srcRow = y * source.stride;
      final int dstRow = y * width * 4;
      for (int x = 0; x < width; x++) {
        final int src = srcRow + x * 4;
        final int dst = dstRow + x * 4;
        if (_blendPixel(destination, dst, pixels, src, opacity)) {
          contributed = true;
        }
      }
    }
    return contributed;
  }

  static bool _blendLuma(
    Uint8List destination,
    MediaFrame source,
    DecodedMediaFrame mask,
    double progress,
  ) {
    if (source.rgba == null || progress <= 0.0) return false;
    if (mask.width != source.width || mask.height != source.height) return false;

    final Uint8List pixels = source.rgba!;
    final int threshold = math.min(
      255,
      math.max(0, (progress * 255.0).floor()),
    );
    bool contributed = false;

    for (int y = 0; y < source.height; y++) {
      final int srcRow = y * source.stride;
      final int maskRow = y * mask.stride;
      final int dstRow = y * source.width * 4;
      for (int x = 0; x < source.width; x++) {
        final int src = srcRow + x * 4;
        final int maskIndex = maskRow + x * 4;
        final int dst = dstRow + x * 4;
        final int luma = ((77 * mask.rgba[maskIndex]) +
                (150 * mask.rgba[maskIndex + 1]) +
                (29 * mask.rgba[maskIndex + 2])) >>
            8;
        if (luma <= threshold &&
            _blendPixel(destination, dst, pixels, src, 1.0)) {
          contributed = true;
        }
      }
    }
    return contributed;
  }

  static bool _blendPixel(
    Uint8List destination,
    int dst,
    Uint8List source,
    int src,
    double opacity,
  ) {
    final double sourceAlpha = (source[src + 3] / 255.0) * opacity;
    if (sourceAlpha <= 0.0) return false;

    final double destinationAlpha = destination[dst + 3] / 255.0;
    final double outAlpha =
        sourceAlpha + destinationAlpha * (1.0 - sourceAlpha);
    if (outAlpha <= 0.0) return false;

    for (int channel = 0; channel < 3; channel++) {
      final double sourceValue = source[src + channel].toDouble();
      final double destinationValue = destination[dst + channel].toDouble();
      final double value =
          (sourceValue * sourceAlpha +
                  destinationValue * destinationAlpha * (1.0 - sourceAlpha)) /
              outAlpha;
      destination[dst + channel] = math.min(
        255,
        math.max(0, value.round()),
      );
    }
    destination[dst + 3] = math.min(
      255,
      math.max(0, (outAlpha * 255.0).round()),
    );
    return true;
  }

  static int? _videoTrackRank(String trackId) {
    final RegExpMatch? match = RegExp(r'^V(\d+)$').firstMatch(trackId);
    if (match == null) return null;
    return int.parse(match.group(1)!);
  }

  void _checkAlive() {
    if (_disposed) throw StateError('EditVideoCompositor has been disposed.');
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final MediaDecoder decoder in _maskDecoders.values) {
      decoder.dispose();
    }
    _maskDecoders.clear();
    _maskFrames.clear();
  }
}

class _ActiveLayer {
  final MediaFrame frame;
  final EditSurfaceClip clip;
  final int trackRank;
  final int authoredIndex;

  const _ActiveLayer({
    required this.frame,
    required this.clip,
    required this.trackRank,
    required this.authoredIndex,
  });
}
