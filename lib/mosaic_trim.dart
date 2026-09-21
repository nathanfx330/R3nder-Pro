// ./lib/mosaic_trim.dart

import 'edit_model.dart';

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
