// ./lib/mosaic_layout.dart
//
// Shared legacy MOSAIC pane geometry.
//
// This is normalized composition geometry only. Pixel rounding remains owned by
// the compositor so CARD/DOSSIER cue ownership and rendered pixels can share
// the same authored pane rectangles without introducing a second seam policy.

import 'dart:ui' as ui;

const double _mosaicHeroFraction = 0.56;

List<ui.Rect> mosaicPaneLayout(int count) {
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
