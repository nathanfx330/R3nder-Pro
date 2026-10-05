// ./lib/mosaic_overview_geometry.dart
//
// Pure deterministic geometry for MOSAIC OVERVIEW.
//
// One focal MAIN window occupies the upper presentation field. One to three
// chrome-free thumbnail clients sit in a centered shelf underneath, with one
// reserved label rectangle per thumbnail. Media/decoder metadata is
// deliberately absent: authored ASPECT is the sole client-aspect authority.

import 'dart:math' as math;
import 'dart:ui';

import 'mosaic_split_geometry.dart';

const double kMosaicOverviewEdgeMarginFraction = 0.035;
const double kMosaicOverviewMainBottomFraction = 0.70;
const double kMosaicOverviewShelfTopFraction = 0.73;
const double kMosaicOverviewMainWidthFraction = 0.72;

class MosaicOverviewGeometry {
  final Rect frame;
  final MosaicSplitClientAspect aspect;
  final double titleHeight;
  final int thumbnailCount;
  final Rect mainWindowRect;
  final Rect mainClientRect;
  final Rect thumbnailStripRect;
  final List<Rect> thumbnailRects;
  final List<Rect> labelRects;

  const MosaicOverviewGeometry._({
    required this.frame,
    required this.aspect,
    required this.titleHeight,
    required this.thumbnailCount,
    required this.mainWindowRect,
    required this.mainClientRect,
    required this.thumbnailStripRect,
    required this.thumbnailRects,
    required this.labelRects,
  });
}

MosaicOverviewGeometry mosaicOverviewGeometry({
  required Rect frame,
  required MosaicSplitClientAspect aspect,
  required double titleHeight,
  required int thumbnailCount,
}) {
  if (frame.width <= 0.0 || frame.height <= 0.0) {
    throw ArgumentError.value(frame, 'frame', 'OVERVIEW frame must be non-empty.');
  }
  if (!titleHeight.isFinite || titleHeight < 0.0) {
    throw ArgumentError.value(
      titleHeight,
      'titleHeight',
      'OVERVIEW title height must be finite and non-negative.',
    );
  }
  if (thumbnailCount < 1 || thumbnailCount > 3) {
    throw ArgumentError.value(
      thumbnailCount,
      'thumbnailCount',
      'OVERVIEW requires one, two, or three thumbnails.',
    );
  }

  final double edgeMargin = frame.width * kMosaicOverviewEdgeMarginFraction;
  final double verticalMargin = frame.height * kMosaicOverviewEdgeMarginFraction;
  final double scale = titleHeight > 0.0 ? titleHeight / 38.0 : 1.0;

  final Rect mainRegion = Rect.fromLTRB(
    frame.left + edgeMargin,
    frame.top + verticalMargin,
    frame.right - edgeMargin,
    frame.top + frame.height * kMosaicOverviewMainBottomFraction,
  );
  final double maxMainClientWidth =
      mainRegion.width * kMosaicOverviewMainWidthFraction;
  final double maxMainClientHeight =
      math.max(1.0, mainRegion.height - titleHeight);
  final Size mainClientSize = _fitAspect(
    aspect.widthOverHeight,
    maxWidth: maxMainClientWidth,
    maxHeight: maxMainClientHeight,
  );
  final double mainWindowHeight = mainClientSize.height + titleHeight;
  final Rect mainWindowRect = Rect.fromLTWH(
    frame.center.dx - mainClientSize.width / 2.0,
    mainRegion.top + (mainRegion.height - mainWindowHeight) / 2.0,
    mainClientSize.width,
    mainWindowHeight,
  );
  final Rect mainClientRect = Rect.fromLTWH(
    mainWindowRect.left,
    mainWindowRect.top + titleHeight,
    mainClientSize.width,
    mainClientSize.height,
  );

  final Rect thumbnailStripRect = Rect.fromLTRB(
    frame.left + edgeMargin,
    frame.top + frame.height * kMosaicOverviewShelfTopFraction,
    frame.right - edgeMargin,
    frame.bottom - verticalMargin,
  );
  final double slotGap = math.max(16.0 * scale, frame.width * 0.012);
  final double labelGap = 8.0 * scale;
  final double labelHeight = 24.0 * scale;
  final double slotWidth =
      (thumbnailStripRect.width - slotGap * (thumbnailCount - 1)) /
          thumbnailCount;
  final double imageAreaHeight = math.max(
    1.0,
    thumbnailStripRect.height - labelGap - labelHeight,
  );
  final Size thumbnailSize = _fitAspect(
    aspect.widthOverHeight,
    maxWidth: slotWidth,
    maxHeight: imageAreaHeight,
  );

  final List<Rect> thumbnails = <Rect>[];
  final List<Rect> labels = <Rect>[];
  final double imageAreaBottom =
      thumbnailStripRect.bottom - labelGap - labelHeight;
  final double imageAreaTop = thumbnailStripRect.top;
  for (int index = 0; index < thumbnailCount; index++) {
    final double slotLeft =
        thumbnailStripRect.left + index * (slotWidth + slotGap);
    final double left = slotLeft + (slotWidth - thumbnailSize.width) / 2.0;
    final double top = imageAreaTop +
        (imageAreaBottom - imageAreaTop - thumbnailSize.height) / 2.0;
    thumbnails.add(
      Rect.fromLTWH(
        left,
        top,
        thumbnailSize.width,
        thumbnailSize.height,
      ),
    );
    labels.add(
      Rect.fromLTWH(
        left,
        top + thumbnailSize.height + labelGap,
        thumbnailSize.width,
        labelHeight,
      ),
    );
  }

  return MosaicOverviewGeometry._(
    frame: frame,
    aspect: aspect,
    titleHeight: titleHeight,
    thumbnailCount: thumbnailCount,
    mainWindowRect: mainWindowRect,
    mainClientRect: mainClientRect,
    thumbnailStripRect: thumbnailStripRect,
    thumbnailRects: List<Rect>.unmodifiable(thumbnails),
    labelRects: List<Rect>.unmodifiable(labels),
  );
}

Size _fitAspect(
  double widthOverHeight, {
  required double maxWidth,
  required double maxHeight,
}) {
  double width = maxWidth;
  double height = width / widthOverHeight;
  if (height > maxHeight) {
    height = maxHeight;
    width = height * widthOverHeight;
  }
  return Size(math.max(1.0, width), math.max(1.0, height));
}
