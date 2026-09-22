// ./lib/mosaic_split_geometry.dart
//
// Pure geometry for the planned two-window MOSAIC STRUCT presentation.
//
// This file intentionally knows nothing about STRUCT grammar, parsing, media,
// readiness, transitions, or painting. Callers supply the coordinate-space
// frame and the title-bar height they already use. Preview and BAKE can
// therefore share one split layout without creating a second chrome scale.

import 'dart:math' as math;
import 'dart:ui';

const double kMosaicSplitEdgeMarginFraction = 0.035;
const double kMosaicSplitGapFraction = 0.024;
const double kMosaicSplitMaxWindowHeightFraction = 0.78;

/// Internal geometry choices for the three v1 authored client aspects.
///
/// W2 owns the eventual grammar spelling. W1 deliberately exposes only the
/// semantic aspect choices so geometry cannot lock authoring syntax early.
enum MosaicSplitClientAspect {
  aspect16x9(16.0 / 9.0),
  aspect4x3(4.0 / 3.0),
  aspect9x16(9.0 / 16.0);

  const MosaicSplitClientAspect(this.widthOverHeight);

  final double widthOverHeight;
}

class MosaicSplitWindowGeometry {
  const MosaicSplitWindowGeometry({
    required this.frame,
    required this.aspect,
    required this.maximized,
    required this.edgeMargin,
    required this.gap,
    required this.titleHeight,
    required this.maximumClientWidth,
    required this.maximumClientHeight,
    required this.clientSize,
    required this.leftWindowRect,
    required this.rightWindowRect,
    required this.leftTitleRect,
    required this.rightTitleRect,
    required this.leftClientRect,
    required this.rightClientRect,
  });

  final Rect frame;
  final MosaicSplitClientAspect aspect;
  final bool maximized;
  final double edgeMargin;
  final double gap;
  final double titleHeight;
  final double maximumClientWidth;
  final double maximumClientHeight;
  final Size clientSize;

  /// Outer desktop-window rectangles, including title-bar chrome.
  final Rect leftWindowRect;
  final Rect rightWindowRect;

  /// Title-bar rectangles inside the two outer windows.
  final Rect leftTitleRect;
  final Rect rightTitleRect;

  /// Content/client rectangles below the title bars.
  final Rect leftClientRect;
  final Rect rightClientRect;

  List<Rect> get windowRects =>
      <Rect>[leftWindowRect, rightWindowRect];

  List<Rect> get titleRects =>
      <Rect>[leftTitleRect, rightTitleRect];

  List<Rect> get clientRects =>
      <Rect>[leftClientRect, rightClientRect];
}

/// Returns the seated two-window geometry inside [frame].
///
/// Both clients are equal.
///
/// Normal SPLIT keeps the authored edge margins, fixed gap, and authored client
/// aspect. MAX SPLIT instead snaps the two outer windows edge to edge across
/// [frame]: zero outer margin, zero gap, half the frame width per window, and
/// the full frame height including title chrome. Media still contains inside
/// each client; the authored aspect remains dormant placement state.
MosaicSplitWindowGeometry mosaicSplitWindowGeometry({
  required Rect frame,
  required MosaicSplitClientAspect aspect,
  required double titleHeight,
  bool maximized = false,
}) {
  if (!frame.width.isFinite ||
      !frame.height.isFinite ||
      frame.width <= 0.0 ||
      frame.height <= 0.0) {
    throw ArgumentError.value(
      frame,
      'frame',
      'Split-window frame must have positive finite dimensions.',
    );
  }
  if (!titleHeight.isFinite || titleHeight < 0.0) {
    throw ArgumentError.value(
      titleHeight,
      'titleHeight',
      'Split-window title height must be finite and non-negative.',
    );
  }

  final double edgeMargin =
      maximized ? 0.0 : frame.width * kMosaicSplitEdgeMarginFraction;
  final double gap =
      maximized ? 0.0 : frame.width * kMosaicSplitGapFraction;
  final double maximumClientWidth = math.max(
    0.0,
    (frame.width - edgeMargin * 2.0 - gap) / 2.0,
  );
  final double maximumClientHeight = math.max(
    0.0,
    maximized
        ? frame.height - titleHeight
        : frame.height * kMosaicSplitMaxWindowHeightFraction - titleHeight,
  );

  final double clientWidth;
  final double clientHeight;
  if (maximized) {
    clientWidth = maximumClientWidth;
    clientHeight = maximumClientHeight;
  } else {
    clientHeight = math.min(
      maximumClientWidth / aspect.widthOverHeight,
      maximumClientHeight,
    );
    clientWidth = aspect.widthOverHeight * clientHeight;
  }
  final double windowHeight = clientHeight + titleHeight;

  final double groupWidth = clientWidth * 2.0 + gap;
  final double left = frame.left + (frame.width - groupWidth) / 2.0;
  final double top = maximized
      ? frame.top
      : frame.top + (frame.height - windowHeight) / 2.0;
  final double rightLeft = left + clientWidth + gap;

  final Rect leftWindow =
      Rect.fromLTWH(left, top, clientWidth, windowHeight);
  final Rect rightWindow =
      Rect.fromLTWH(rightLeft, top, clientWidth, windowHeight);

  final Rect leftTitle =
      Rect.fromLTWH(left, top, clientWidth, titleHeight);
  final Rect rightTitle =
      Rect.fromLTWH(rightLeft, top, clientWidth, titleHeight);

  final Rect leftClient = Rect.fromLTWH(
    left,
    top + titleHeight,
    clientWidth,
    clientHeight,
  );
  final Rect rightClient = Rect.fromLTWH(
    rightLeft,
    top + titleHeight,
    clientWidth,
    clientHeight,
  );

  return MosaicSplitWindowGeometry(
    frame: frame,
    aspect: aspect,
    maximized: maximized,
    edgeMargin: edgeMargin,
    gap: gap,
    titleHeight: titleHeight,
    maximumClientWidth: maximumClientWidth,
    maximumClientHeight: maximumClientHeight,
    clientSize: Size(clientWidth, clientHeight),
    leftWindowRect: leftWindow,
    rightWindowRect: rightWindow,
    leftTitleRect: leftTitle,
    rightTitleRect: rightTitle,
    leftClientRect: leftClient,
    rightClientRect: rightClient,
  );
}
