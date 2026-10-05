// ./test/mosaic_overview_geometry_test.dart

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/mosaic_overview_geometry.dart';
import 'package:r3nder/mosaic_split_geometry.dart';

void main() {
  const Rect frame = Rect.fromLTWH(0, 0, 1920, 1080);
  const double titleHeight = 38.0;
  // The shared painter consumes floating-point rects directly; there is no
  // canonical pixel-snapping authority to compare against. Keep this tolerance
  // only for floating arithmetic noise. Never raise it to make an overlap
  // failure pass.
  const double overlapAreaTolerance = 0.000001;

  double area(Rect rect) =>
      rect.width > 0.0 && rect.height > 0.0 ? rect.width * rect.height : 0.0;

  void expectNoPositiveOverlap(
    Rect a,
    Rect b, {
    required String idA,
    required String idB,
    required String family,
    required MosaicSplitClientAspect aspect,
  }) {
    final Rect overlap = a.intersect(b);
    expect(
      area(overlap),
      lessThanOrEqualTo(overlapAreaTolerance),
      reason:
          'resting peers $idA and $idB overlap in $family '
          'at ASPECT=${aspect.name}',
    );
  }

  for (final MosaicSplitClientAspect aspect
      in MosaicSplitClientAspect.values) {
    for (final int thumbnailCount in <int>[1, 2, 3]) {
      test(
          'OVERVIEW +$thumbnailCount ${aspect.name} is bounded, '
          'aspect-correct, and disjoint', () {
        final MosaicOverviewGeometry geometry = mosaicOverviewGeometry(
          frame: frame,
          aspect: aspect,
          titleHeight: titleHeight,
          thumbnailCount: thumbnailCount,
        );

        expect(geometry.thumbnailRects, hasLength(thumbnailCount));
        expect(geometry.labelRects, hasLength(thumbnailCount));
        expect(frame.contains(geometry.mainWindowRect.topLeft), isTrue);
        expect(frame.contains(geometry.mainWindowRect.bottomRight), isTrue);
        expect(
          geometry.mainClientRect.width / geometry.mainClientRect.height,
          closeTo(aspect.widthOverHeight, 0.000001),
        );

        final List<({String id, Rect rect})> occupied =
            <({String id, Rect rect})>[
          (id: 'MAIN', rect: geometry.mainWindowRect),
          for (int i = 0; i < thumbnailCount; i++) ...<({String id, Rect rect})>[
            (id: 'thumb$i', rect: geometry.thumbnailRects[i]),
            (id: 'label$i', rect: geometry.labelRects[i]),
          ],
        ];

        for (int i = 0; i < thumbnailCount; i++) {
          final Rect thumb = geometry.thumbnailRects[i];
          final Rect label = geometry.labelRects[i];
          expect(frame.contains(thumb.topLeft), isTrue);
          expect(frame.contains(thumb.bottomRight), isTrue);
          expect(frame.contains(label.topLeft), isTrue);
          expect(frame.contains(label.bottomRight), isTrue);
          expect(
            thumb.width / thumb.height,
            closeTo(aspect.widthOverHeight, 0.000001),
          );
          expect(label.top, greaterThanOrEqualTo(thumb.bottom));
        }

        for (int i = 0; i < occupied.length; i++) {
          for (int j = i + 1; j < occupied.length; j++) {
            expectNoPositiveOverlap(
              occupied[i].rect,
              occupied[j].rect,
              idA: occupied[i].id,
              idB: occupied[j].id,
              family: 'OVERVIEW +$thumbnailCount',
              aspect: aspect,
            );
          }
        }
      });
    }
  }

  test('portrait 16:9 thumbnails keep labels attached', () {
    const Rect portraitFrame = Rect.fromLTWH(0, 0, 1080, 1920);

    for (final int thumbnailCount in <int>[1, 2, 3]) {
      final MosaicOverviewGeometry geometry = mosaicOverviewGeometry(
        frame: portraitFrame,
        aspect: MosaicSplitClientAspect.aspect16x9,
        titleHeight: titleHeight,
        thumbnailCount: thumbnailCount,
      );

      for (int i = 0; i < thumbnailCount; i++) {
        final Rect thumb = geometry.thumbnailRects[i];
        final Rect label = geometry.labelRects[i];
        expect(
          label.top - thumb.bottom,
          closeTo(8.0, 0.000001),
          reason: 'label $i detached for portrait +$thumbnailCount',
        );
        expect(label.bottom, lessThanOrEqualTo(geometry.thumbnailStripRect.bottom));
      }
    }
  });

  test('portrait OVERVIEW keeps MAIN and +3 shelf vertically separated', () {
    final MosaicOverviewGeometry geometry = mosaicOverviewGeometry(
      frame: frame,
      aspect: MosaicSplitClientAspect.aspect9x16,
      titleHeight: titleHeight,
      thumbnailCount: 3,
    );

    for (int i = 0; i < geometry.thumbnailRects.length; i++) {
      expect(
        geometry.thumbnailRects[i].top,
        greaterThan(geometry.mainWindowRect.bottom),
      );
      expect(
        geometry.labelRects[i].top,
        greaterThanOrEqualTo(geometry.thumbnailRects[i].bottom),
      );
    }
  });

  test('OVERVIEW rejects invalid thumbnail counts', () {
    for (final int count in <int>[0, 4]) {
      expect(
        () => mosaicOverviewGeometry(
          frame: frame,
          aspect: MosaicSplitClientAspect.aspect16x9,
          titleHeight: titleHeight,
          thumbnailCount: count,
        ),
        throwsArgumentError,
      );
    }
  });
}
