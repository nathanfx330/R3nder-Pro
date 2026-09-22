// ./lib/mosaic_trim.dart

import 'edit_model.dart';
import 'mosaic_surface_model.dart';

/// Returns the exclusive authored endpoint for aligning populated pane endings.
///
/// Each pane contributes its assembled timeline end, not its shortest clip or
/// the duration of its referenced source. Empty panes are excluded. Returns
/// null when fewer than two panes are populated or their ends already agree.
///
/// This is a candidate only: it does not mutate the model, close gaps, or check
/// whether trimming would break a crossfade or empty a populated pane. Those
/// conflicts must be validated before a caller applies a trim.
int? mosaicCommonEndFrame(MosaicSequence mosaic) {
  int populatedPaneCount = 0;
  int? commonEnd;

  for (final MosaicPane pane in mosaic.panes) {
    if (pane.clips.isEmpty) continue;
    populatedPaneCount++;
    final int paneEnd = pane.projectFrameCount;
    if (commonEnd == null || paneEnd < commonEnd) {
      commonEnd = paneEnd;
    }
  }

  if (populatedPaneCount < 2 || commonEnd == mosaic.projectFrameCount) {
    return null;
  }
  return commonEnd;
}

enum MosaicTrimConflictKind {
  incomingCrossfade,
  emptyPane,
}

/// One blocking conflict, indexed in the original authored pane/clip order.
class MosaicTrimConflict {
  final MosaicTrimConflictKind kind;
  final String paneId;
  final String? clipId;
  final int paneIndex;
  final int? clipIndex;
  final String message;

  const MosaicTrimConflict._({
    required this.kind,
    required this.paneId,
    required this.clipId,
    required this.paneIndex,
    required this.clipIndex,
    required this.message,
  });
}

/// All trim conflicts, ordered by authored pane then authored clip position.
class MosaicTrimException implements Exception {
  final String mosaicId;
  final int endFrameExclusive;
  final List<MosaicTrimConflict> conflicts;

  MosaicTrimException._({
    required this.mosaicId,
    required this.endFrameExclusive,
    required List<MosaicTrimConflict> conflicts,
  }) : conflicts = List<MosaicTrimConflict>.unmodifiable(conflicts);

  String get message =>
      'Cannot trim MOSAIC "$mosaicId" to frame $endFrameExclusive:\n'
      '${conflicts.map((MosaicTrimConflict conflict) => conflict.message).join('\n')}';

  @override
  String toString() => message;
}

/// Aligns populated pane endings by returning one complete authored script.
///
/// All conflicts are collected before any rewrite. Clips beginning at or after
/// the exclusive endpoint are removed; clips crossing it are trimmed. Existing
/// gaps and referenced sources remain untouched. The caller adopts the result
/// once, so this operation can occupy one undo entry. With no candidate, the
/// original source is returned unchanged.
String trimMosaicToShortest(String source, String mosaicId) {
  final MosaicSurfaceDocument document =
      MosaicSurfaceDocument.parse(source, mosaicId);
  final int? end = mosaicCommonEndFrame(document.mosaic);
  if (end == null) return source;

  final List<MosaicTrimConflict> conflicts = <MosaicTrimConflict>[];
  final List<MosaicPane> panes = document.mosaic.panes;
  for (int paneIndex = 0; paneIndex < panes.length; paneIndex++) {
    final MosaicPane pane = panes[paneIndex];
    if (pane.clips.isEmpty) continue;

    if (pane.clips.every((EditClip clip) => clip.atFrame >= end)) {
      conflicts.add(MosaicTrimConflict._(
        kind: MosaicTrimConflictKind.emptyPane,
        paneId: pane.id,
        clipId: null,
        paneIndex: paneIndex,
        clipIndex: null,
        message: 'PANE "${pane.id}": trimming would remove all its clips.',
      ));
      continue;
    }

    for (int clipIndex = 0; clipIndex < pane.clips.length; clipIndex++) {
      final EditClip clip = pane.clips[clipIndex];
      if (clip.endFrameExclusive <= end || clip.atFrame >= end) continue;
      final int remaining = end - clip.atFrame;
      final int fade = document.incomingCrossfadeFrames(pane.id, clip.id);
      if (fade <= remaining) continue;
      conflicts.add(MosaicTrimConflict._(
        kind: MosaicTrimConflictKind.incomingCrossfade,
        paneId: pane.id,
        clipId: clip.id,
        paneIndex: paneIndex,
        clipIndex: clipIndex,
        message: 'PANE "${pane.id}", CLIP "${clip.id}": '
            '${fade}F incoming crossfade exceeds the $remaining remaining frames.',
      ));
    }
  }

  // Order diagnostics explicitly, independently of conflict collection order.
  conflicts.sort((MosaicTrimConflict a, MosaicTrimConflict b) {
    final int byPane = a.paneIndex.compareTo(b.paneIndex);
    if (byPane != 0) return byPane;
    final int byClip = (a.clipIndex ?? -1).compareTo(b.clipIndex ?? -1);
    if (byClip != 0) return byClip;
    return a.kind.index.compareTo(b.kind.index);
  });
  if (conflicts.isNotEmpty) {
    throw MosaicTrimException._(
      mosaicId: mosaicId,
      endFrameExclusive: end,
      conflicts: conflicts,
    );
  }

  // Validation above is against the original authored model. The rewrite loop
  // therefore relies on removeClip and trimClipEnd remaining non-rippling:
  // surviving clip AT positions must not move as earlier blocks are rewritten.
  String next = source;
  for (final MosaicPane pane in panes) {
    for (final EditClip clip in pane.clips) {
      if (clip.endFrameExclusive <= end) continue;
      // Every rewrite changes source offsets, so resolve the next clip afresh.
      final MosaicSurfaceDocument current =
          MosaicSurfaceDocument.parse(next, mosaicId);
      next = clip.atFrame >= end
          ? current.removeClip(pane.id, clip.id)
          : current.trimClipEnd(pane.id, clip.id, end);
    }
  }
  return next;
}
