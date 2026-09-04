// ./lib/edit_video_compositor.dart
//
// Deterministic pixel compositor for structural video sources.
//
// MLT decodes leaf source frames. R3nder owns project time, track ordering,
// transition progress, EDIT recursion, MOSAIC pane geometry, and final pixels.
// No decoder or nested source advances the playhead. A structural CLIP source
// is evaluated at the exact integer source frame selected by its outer CLIP and
// composited into one synthetic frame before the outer rules are applied.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'edit_linter.dart';
import 'edit_model.dart';
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
  bool get hasPending => mediaFrames.any(
        (MediaFrame frame) =>
            frame.status == MediaFrameStatus.pending ||
            frame.status == MediaFrameStatus.nestedEditPending ||
            frame.status == MediaFrameStatus.nestedMosaicPending,
      );
}

class EditVideoCompositor {
  static const double _mosaicHeroFraction = 0.56;

  static final RegExp _paneCrossfadeDirective = RegExp(
    r'\[#EDIT_TRANSITION:CROSSFADE:(\d+)\]',
  );
  static final RegExp _paneLumaDirective = RegExp(
    r'\[#EDIT_TRANSITION:LUMA:([^\]\r\n:]+):(\d+)\]',
  );

  final EditDocumentModel model;
  final String source;
  final MediaLayer mediaLayer;
  final MediaDecoderBackend backend;
  final String Function(String source) resolveSource;

  final EditLintResult _graphLint;
  final Map<String, EditSurfaceDocument> _surfaces =
      <String, EditSurfaceDocument>{};
  final Map<String, MediaDecoder> _maskDecoders = <String, MediaDecoder>{};
  final Map<String, DecodedMediaFrame> _maskFrames =
      <String, DecodedMediaFrame>{};
  bool _disposed = false;

  /// Back-compatible constructor for callers already holding an EDIT surface.
  EditVideoCompositor({
    required EditSurfaceDocument document,
    required this.mediaLayer,
    required this.backend,
    required this.resolveSource,
  })  : model = document.model,
        source = document.source,
        _graphLint = EditGraphLinter.lint(document.model) {
    _surfaces[document.editId] = document;
  }

  /// Structural-source constructor used when the selected root may be MOSAIC
  /// and therefore does not need an arbitrary EDIT merely to anchor the model.
  EditVideoCompositor.forModel({
    required this.model,
    required this.mediaLayer,
    required this.backend,
    required this.resolveSource,
  })  : source = model.source,
        _graphLint = EditGraphLinter.lint(model);

  /// Back-compatible exact EDIT composition.
  EditVideoCompositeResult render(
    String editId,
    ProjectTime time,
    ui.Size size,
  ) {
    return renderSource('EDIT.$editId', time, size);
  }

  /// Back-compatible nonblocking EDIT composition.
  EditVideoCompositeResult renderAvailable(
    String editId,
    ProjectTime time,
    ui.Size size,
  ) {
    return renderSourceAvailable('EDIT.$editId', time, size);
  }

  /// Exact composition of any canonical structural source.
  EditVideoCompositeResult renderSource(
    String source,
    ProjectTime time,
    ui.Size size,
  ) {
    _checkAlive();
    _checkGraph();
    final StructuralSourceRef ref = _requireStructuralSource(source);
    return _renderStructuralSource(
      ref,
      time,
      size,
      nonBlocking: false,
    );
  }

  /// Nonblocking composition of any canonical structural source.
  EditVideoCompositeResult renderSourceAvailable(
    String source,
    ProjectTime time,
    ui.Size size,
  ) {
    _checkAlive();
    _checkGraph();
    final StructuralSourceRef ref = _requireStructuralSource(source);
    return _renderStructuralSource(
      ref,
      time,
      size,
      nonBlocking: true,
    );
  }

  StructuralSourceRef _requireStructuralSource(String source) {
    final StructuralSourceRef? ref = StructuralSourceRef.tryParse(source);
    if (ref == null || ref.id.isEmpty) {
      throw ArgumentError.value(
        source,
        'source',
        'Expected EDIT.<id> or MOSAIC.<id>.',
      );
    }
    if (!model.containsStructuralSource(ref)) {
      throw StateError('No structural source named "${ref.canonicalSource}".');
    }
    return ref;
  }

  EditVideoCompositeResult _renderStructuralSource(
    StructuralSourceRef ref,
    ProjectTime time,
    ui.Size size, {
    required bool nonBlocking,
  }) {
    switch (ref.kind) {
      case StructuralSourceKind.edit:
        return _renderEdit(
          ref.id,
          time,
          size,
          nonBlocking: nonBlocking,
        );
      case StructuralSourceKind.mosaic:
        return _renderMosaic(
          ref.id,
          time,
          size,
          nonBlocking: nonBlocking,
        );
    }
  }

  EditVideoCompositeResult _renderEdit(
    String editId,
    ProjectTime time,
    ui.Size size, {
    required bool nonBlocking,
  }) {
    final MediaRenderResult media = nonBlocking
        ? mediaLayer.renderAvailable(editId, time, size)
        : mediaLayer.render(editId, time, size);
    final MediaRenderResult resolved = _resolveStructuralFrames(
      media,
      nonBlocking: nonBlocking,
    );
    return _composeEdit(resolved, time, size);
  }

  EditVideoCompositeResult _renderMosaic(
    String mosaicId,
    ProjectTime time,
    ui.Size size, {
    required bool nonBlocking,
  }) {
    final int width = size.width.round();
    final int height = size.height.round();
    if (!size.width.isFinite ||
        !size.height.isFinite ||
        width <= 0 ||
        height <= 0) {
      throw ArgumentError.value(
        size,
        'size',
        'MOSAIC render size must be positive.',
      );
    }

    final MosaicSequence mosaic = model.mosaic(mosaicId);
    final List<ui.Rect> layout = _mosaicLayout(mosaic.panes.length);
    final Uint8List output = Uint8List(width * height * 4);
    final List<MediaFrame> mediaFrames = <MediaFrame>[];
    final List<MediaFrame> contributors = <MediaFrame>[];
    MediaFrame? topFrame;
    bool hasImage = false;

    for (int i = 0; i < mosaic.panes.length; i++) {
      final MosaicPane pane = mosaic.panes[i];
      final _PixelRect rect = _pixelRect(layout[i], width, height);
      if (rect.width <= 0 || rect.height <= 0) continue;

      final ui.Size paneSize = ui.Size(
        rect.width.toDouble(),
        rect.height.toDouble(),
      );
      final MediaRenderResult media = nonBlocking
          ? mediaLayer.renderPaneAvailable(
              mosaicId,
              pane.id,
              time,
              paneSize,
            )
          : mediaLayer.renderPane(
              mosaicId,
              pane.id,
              time,
              paneSize,
            );
      final MediaRenderResult resolved = _resolveStructuralFrames(
        media,
        nonBlocking: nonBlocking,
      );
      final EditVideoCompositeResult paneResult = _composePane(
        pane,
        resolved,
        time,
        paneSize,
      );

      mediaFrames.addAll(paneResult.mediaFrames);
      contributors.addAll(paneResult.contributors);
      if (paneResult.topFrame != null) topFrame = paneResult.topFrame;

      if (paneResult.rgba != null) {
        _blitPane(
          output,
          width,
          rect,
          paneResult.rgba!,
          paneResult.stride,
        );
        hasImage = true;
      }
    }

    return EditVideoCompositeResult(
      width: width,
      height: height,
      stride: width * 4,
      rgba: hasImage ? output : null,
      topFrame: topFrame,
      contributors: List<MediaFrame>.unmodifiable(contributors),
      mediaFrames: List<MediaFrame>.unmodifiable(mediaFrames),
    );
  }

  /// MediaLayer deliberately returns structural sources as placeholders. This
  /// resolves both EDIT and MOSAIC recursively while retaining the outer CLIP
  /// frame request as the synthetic frame's identity.
  MediaRenderResult _resolveStructuralFrames(
    MediaRenderResult media, {
    required bool nonBlocking,
  }) {
    bool changed = false;
    final List<MediaFrame> frames = <MediaFrame>[];

    for (final MediaFrame frame in media.frames) {
      if (!frame.isStructuralPending) {
        frames.add(frame);
        continue;
      }

      changed = true;
      final StructuralSourceRef? ref = StructuralSourceRef.tryParse(frame.source);
      if (ref == null || ref.id.isEmpty) {
        frames.add(
          MediaFrame.offline(
            trackId: frame.trackId,
            clipId: frame.clipId,
            source: frame.source,
            requestedSourceFrame: frame.requestedSourceFrame,
            error: 'Invalid structural source "${frame.source}".',
          ),
        );
        continue;
      }

      if (!model.containsStructuralSource(ref)) {
        frames.add(
          MediaFrame.offline(
            trackId: frame.trackId,
            clipId: frame.clipId,
            source: frame.source,
            requestedSourceFrame: frame.requestedSourceFrame,
            error: 'Missing structural source "${ref.canonicalSource}".',
          ),
        );
        continue;
      }

      final int sourceFrameCount = model.structuralSourceFrameCount(ref);

      // Outer CLIP duration remains authoritative. Asking beyond a nested
      // source's authored range contributes transparent pixels rather than
      // shortening the outer CLIP or inventing a hold frame.
      if (frame.requestedSourceFrame < 0 ||
          frame.requestedSourceFrame >= sourceFrameCount) {
        frames.add(_transparentStructuralFrame(frame, media.outputSize));
        continue;
      }

      final ProjectTime nestedTime = ProjectTime(
        frame: frame.requestedSourceFrame,
        epoch: media.projectTime.epoch,
        mode: media.projectTime.mode,
      );
      final EditVideoCompositeResult nested = _renderStructuralSource(
        ref,
        nestedTime,
        media.outputSize,
        nonBlocking: nonBlocking,
      );

      if (nested.hasPending) {
        frames.add(frame);
        continue;
      }

      if (nested.rgba == null) {
        final MediaFrame? offline = _firstOfflineFrame(nested.mediaFrames);
        if (offline != null) {
          frames.add(
            MediaFrame.offline(
              trackId: frame.trackId,
              clipId: frame.clipId,
              source: frame.source,
              requestedSourceFrame: frame.requestedSourceFrame,
              error: offline.error ??
                  'Structural source "${ref.canonicalSource}" is offline.',
            ),
          );
        } else {
          frames.add(_transparentStructuralFrame(frame, media.outputSize));
        }
        continue;
      }

      frames.add(
        MediaFrame.decoded(
          trackId: frame.trackId,
          clipId: frame.clipId,
          source: frame.source,
          decoded: DecodedMediaFrame(
            requestedSourceFrame: frame.requestedSourceFrame,
            actualSourceFrame: frame.requestedSourceFrame,
            width: nested.width,
            height: nested.height,
            stride: nested.stride,
            rgba: nested.rgba!,
          ),
        ),
      );
    }

    if (!changed) return media;
    return MediaRenderResult(
      editId: media.editId,
      projectTime: media.projectTime,
      outputSize: media.outputSize,
      frames: List<MediaFrame>.unmodifiable(frames),
    );
  }

  MediaFrame _transparentStructuralFrame(MediaFrame frame, ui.Size size) {
    final int width = size.width.round();
    final int height = size.height.round();
    return MediaFrame.decoded(
      trackId: frame.trackId,
      clipId: frame.clipId,
      source: frame.source,
      decoded: DecodedMediaFrame(
        requestedSourceFrame: frame.requestedSourceFrame,
        actualSourceFrame: frame.requestedSourceFrame,
        width: width,
        height: height,
        stride: width * 4,
        rgba: Uint8List(width * height * 4),
      ),
    );
  }

  static MediaFrame? _firstOfflineFrame(List<MediaFrame> frames) {
    for (final MediaFrame frame in frames) {
      if (frame.status == MediaFrameStatus.offline) return frame;
    }
    return null;
  }

  EditVideoCompositeResult _composeEdit(
    MediaRenderResult media,
    ProjectTime time,
    ui.Size size,
  ) {
    final EditSurfaceDocument surface = _surfaceFor(media.editId);
    final List<_ActiveLayer> layers = <_ActiveLayer>[];

    for (int index = 0; index < media.frames.length; index++) {
      final MediaFrame frame = media.frames[index];
      if (!frame.isDecoded || frame.rgba == null) continue;
      final int? trackRank = _videoTrackRank(frame.trackId);
      if (trackRank == null) continue;

      EditSurfaceClip clip;
      try {
        clip = surface.clip(frame.trackId, frame.clipId);
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
      return _emptyResult(size, media.frames);
    }

    final int width = layers.first.frame.width;
    final int height = layers.first.frame.height;
    final int stride = width * 4;

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
      final bool contributed = _blendWithTransition(
        output,
        frame,
        layer.clip.transition,
        projectOffset,
        width,
        height,
      );

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

  EditVideoCompositeResult _composePane(
    MosaicPane pane,
    MediaRenderResult media,
    ProjectTime time,
    ui.Size size,
  ) {
    final List<_PaneLayer> layers = <_PaneLayer>[];

    for (int index = 0; index < media.frames.length; index++) {
      final MediaFrame frame = media.frames[index];
      if (!frame.isDecoded || frame.rgba == null) continue;
      EditClip clip;
      try {
        clip = pane.clip(frame.clipId);
      } catch (_) {
        continue;
      }
      layers.add(
        _PaneLayer(
          frame: frame,
          clip: clip,
          transition: _transitionForPaneClip(clip),
          authoredIndex: index,
        ),
      );
    }

    layers.sort((_PaneLayer a, _PaneLayer b) =>
        a.authoredIndex.compareTo(b.authoredIndex));
    if (layers.isEmpty) return _emptyResult(size, media.frames);

    final int width = size.width.round();
    final int height = size.height.round();
    final int stride = width * 4;

    if (layers.length == 1) {
      final _PaneLayer only = layers.single;
      final int projectOffset = time.frame - only.clip.atFrame;
      final double progress = _transitionProgress(
        projectOffset,
        only.transition.frames,
      );
      if (only.transition.kind == EditTransitionKind.none || progress >= 1.0) {
        return EditVideoCompositeResult(
          width: only.frame.width,
          height: only.frame.height,
          stride: only.frame.stride,
          rgba: only.frame.rgba,
          topFrame: only.frame,
          contributors:
              List<MediaFrame>.unmodifiable(<MediaFrame>[only.frame]),
          mediaFrames: media.frames,
        );
      }
    }

    final Uint8List output = Uint8List(stride * height);
    final List<MediaFrame> contributors = <MediaFrame>[];
    MediaFrame? topFrame;

    for (final _PaneLayer layer in layers) {
      final MediaFrame frame = layer.frame;
      if (frame.width != width || frame.height != height) continue;
      final int projectOffset = time.frame - layer.clip.atFrame;
      final bool contributed = _blendWithTransition(
        output,
        frame,
        layer.transition,
        projectOffset,
        width,
        height,
      );
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

  EditVideoCompositeResult _emptyResult(
    ui.Size size,
    List<MediaFrame> mediaFrames,
  ) {
    final int width = size.width.round();
    final int height = size.height.round();
    return EditVideoCompositeResult(
      width: width,
      height: height,
      stride: width * 4,
      rgba: null,
      topFrame: null,
      contributors: const <MediaFrame>[],
      mediaFrames: mediaFrames,
    );
  }

  bool _blendWithTransition(
    Uint8List output,
    MediaFrame frame,
    EditTransition transition,
    int projectOffset,
    int width,
    int height,
  ) {
    final double progress = _transitionProgress(
      projectOffset,
      transition.frames,
    );

    switch (transition.kind) {
      case EditTransitionKind.none:
        return _blendUniform(output, frame, 1.0);
      case EditTransitionKind.crossfade:
        return _blendUniform(output, frame, progress);
      case EditTransitionKind.luma:
        if (progress >= 1.0) {
          return _blendUniform(output, frame, 1.0);
        }
        if (progress <= 0.0 || transition.lumaSource.isEmpty) return false;
        final DecodedMediaFrame? mask = _decodeMask(
          transition.lumaSource,
          width,
          height,
        );
        if (mask == null) return false;
        return _blendLuma(output, frame, mask, progress);
    }
  }

  EditTransition _transitionForPaneClip(EditClip clip) {
    final String body = clip.block.innerSource;
    final RegExpMatch? crossfade = _paneCrossfadeDirective.firstMatch(body);
    if (crossfade != null) {
      return EditTransition.crossfade(int.parse(crossfade.group(1)!));
    }
    final RegExpMatch? luma = _paneLumaDirective.firstMatch(body);
    if (luma != null) {
      return EditTransition.luma(
        luma.group(1)!,
        int.parse(luma.group(2)!),
      );
    }
    return const EditTransition.none();
  }

  static List<ui.Rect> _mosaicLayout(int count) {
    if (count <= 0) return const <ui.Rect>[];
    if (count == 1) {
      return const <ui.Rect>[ui.Rect.fromLTRB(0, 0, 1, 1)];
    }
    if (count == 2) {
      return const <ui.Rect>[
        ui.Rect.fromLTRB(0, 0, _mosaicHeroFraction, 1),
        ui.Rect.fromLTRB(_mosaicHeroFraction, 0, 1, 1),
      ];
    }
    return const <ui.Rect>[
      ui.Rect.fromLTRB(0, 0, _mosaicHeroFraction, 1),
      ui.Rect.fromLTRB(_mosaicHeroFraction, 0, 1, 0.5),
      ui.Rect.fromLTRB(_mosaicHeroFraction, 0.5, 1, 1),
    ];
  }

  static _PixelRect _pixelRect(ui.Rect rect, int width, int height) {
    final int left = (rect.left * width).round();
    final int top = (rect.top * height).round();
    final int right = (rect.right * width).round();
    final int bottom = (rect.bottom * height).round();
    return _PixelRect(
      left: left,
      top: top,
      right: right,
      bottom: bottom,
    );
  }

  static void _blitPane(
    Uint8List destination,
    int destinationWidth,
    _PixelRect rect,
    Uint8List source,
    int sourceStride,
  ) {
    final int rowBytes = rect.width * 4;
    for (int y = 0; y < rect.height; y++) {
      final int src = y * sourceStride;
      final int dst = ((rect.top + y) * destinationWidth + rect.left) * 4;
      destination.setRange(dst, dst + rowBytes, source, src);
    }
  }

  EditSurfaceDocument _surfaceFor(String editId) {
    final EditSurfaceDocument? existing = _surfaces[editId];
    if (existing != null) return existing;
    final EditSurfaceDocument parsed = EditSurfaceDocument.parse(source, editId);
    _surfaces[editId] = parsed;
    return parsed;
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

  void _checkGraph() {
    if (_graphLint.isValid) return;
    final EditLintIssue issue = _graphLint.issues.first;
    throw StateError(
      'Structural source graph is not renderable: ${issue.message} '
      'Path: ${issue.editPath.join(' -> ')}',
    );
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
    _surfaces.clear();
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

class _PaneLayer {
  final MediaFrame frame;
  final EditClip clip;
  final EditTransition transition;
  final int authoredIndex;

  const _PaneLayer({
    required this.frame,
    required this.clip,
    required this.transition,
    required this.authoredIndex,
  });
}

class _PixelRect {
  final int left;
  final int top;
  final int right;
  final int bottom;

  const _PixelRect({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  int get width => right - left;
  int get height => bottom - top;
}
