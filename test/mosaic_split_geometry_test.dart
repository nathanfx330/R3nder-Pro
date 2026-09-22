// ./test/mosaic_split_geometry_test.dart

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/mosaic_split_geometry.dart';

void _expectClose(double actual, double expected) {
  expect(actual, closeTo(expected, 0.000001));
}

void _expectRect(Rect actual, Rect expected) {
  _expectClose(actual.left, expected.left);
  _expectClose(actual.top, expected.top);
  _expectClose(actual.right, expected.right);
  _expectClose(actual.bottom, expected.bottom);
}

void _expectReferenceContract(
  MosaicSplitWindowGeometry geometry, {
  required Size clientSize,
  required double top,
  required double left,
}) {
  _expectClose(geometry.edgeMargin, 67.2);
  _expectClose(geometry.gap, 46.08);
  _expectClose(geometry.maximumClientWidth, 869.76);
  _expectClose(geometry.maximumClientHeight, 804.4);
  _expectClose(geometry.clientSize.width, clientSize.width);
  _expectClose(geometry.clientSize.height, clientSize.height);

  _expectRect(
    geometry.leftWindowRect,
    Rect.fromLTWH(
      left,
      top,
      clientSize.width,
      clientSize.height + 38.0,
    ),
  );
  _expectRect(
    geometry.rightWindowRect,
    Rect.fromLTWH(
      960.0 + 23.04,
      top,
      clientSize.width,
      clientSize.height + 38.0,
    ),
  );

  _expectRect(
    geometry.leftTitleRect,
    Rect.fromLTWH(left, top, clientSize.width, 38.0),
  );
  _expectRect(
    geometry.leftClientRect,
    Rect.fromLTWH(
      left,
      top + 38.0,
      clientSize.width,
      clientSize.height,
    ),
  );
  _expectRect(
    geometry.rightTitleRect,
    Rect.fromLTWH(
      960.0 + 23.04,
      top,
      clientSize.width,
      38.0,
    ),
  );
  _expectRect(
    geometry.rightClientRect,
    Rect.fromLTWH(
      960.0 + 23.04,
      top + 38.0,
      clientSize.width,
      clientSize.height,
    ),
  );
}

void main() {
  const Rect hd = Rect.fromLTWH(0, 0, 1920, 1080);

  test('16:9 reference geometry matches measured split-window contract', () {
    final MosaicSplitWindowGeometry geometry = mosaicSplitWindowGeometry(
      frame: hd,
      aspect: MosaicSplitClientAspect.aspect16x9,
      titleHeight: 38.0,
    );

    _expectReferenceContract(
      geometry,
      clientSize: const Size(869.76, 489.24),
      top: 276.38,
      left: 67.2,
    );
    _expectClose(
      geometry.clientSize.width / geometry.clientSize.height,
      16.0 / 9.0,
    );
  });

  test('4:3 reference geometry keeps maximum width and authored aspect', () {
    final MosaicSplitWindowGeometry geometry = mosaicSplitWindowGeometry(
      frame: hd,
      aspect: MosaicSplitClientAspect.aspect4x3,
      titleHeight: 38.0,
    );

    _expectReferenceContract(
      geometry,
      clientSize: const Size(869.76, 652.32),
      top: 194.84,
      left: 67.2,
    );
    _expectClose(
      geometry.clientSize.width / geometry.clientSize.height,
      4.0 / 3.0,
    );
  });

  test('9:16 reference geometry height-caps and contracts width symmetrically',
      () {
    final MosaicSplitWindowGeometry geometry = mosaicSplitWindowGeometry(
      frame: hd,
      aspect: MosaicSplitClientAspect.aspect9x16,
      titleHeight: 38.0,
    );

    _expectReferenceContract(
      geometry,
      clientSize: const Size(452.475, 804.4),
      top: 118.8,
      left: 484.485,
    );
    _expectClose(
      geometry.clientSize.width / geometry.clientSize.height,
      9.0 / 16.0,
    );
    _expectClose(
      geometry.clientSize.height,
      geometry.maximumClientHeight,
    );
    expect(
      geometry.clientSize.width,
      lessThan(geometry.maximumClientWidth),
    );
  });

  test('MAX split fills horizontal halves while aspect owns height', () {
    final MosaicSplitWindowGeometry wide = mosaicSplitWindowGeometry(
      frame: hd,
      aspect: MosaicSplitClientAspect.aspect16x9,
      titleHeight: 38.0,
      maximized: true,
    );
    expect(wide.maximized, isTrue);
    _expectClose(wide.edgeMargin, 0.0);
    _expectClose(wide.gap, 0.0);
    _expectClose(wide.maximumClientWidth, 960.0);
    _expectClose(wide.maximumClientHeight, 1042.0);
    _expectClose(wide.clientSize.width, 960.0);
    _expectClose(wide.clientSize.height, 540.0);
    _expectRect(
      wide.leftWindowRect,
      const Rect.fromLTWH(0, 251, 960, 578),
    );
    _expectRect(
      wide.rightWindowRect,
      const Rect.fromLTWH(960, 251, 960, 578),
    );
    _expectRect(
      wide.leftClientRect,
      const Rect.fromLTWH(0, 289, 960, 540),
    );
    _expectRect(
      wide.rightClientRect,
      const Rect.fromLTWH(960, 289, 960, 540),
    );

    final MosaicSplitWindowGeometry classic = mosaicSplitWindowGeometry(
      frame: hd,
      aspect: MosaicSplitClientAspect.aspect4x3,
      titleHeight: 38.0,
      maximized: true,
    );
    _expectClose(classic.clientSize.width, 960.0);
    _expectClose(classic.clientSize.height, 720.0);
    _expectClose(classic.leftWindowRect.top, 161.0);
    _expectClose(classic.leftWindowRect.height, 758.0);

    final MosaicSplitWindowGeometry portrait = mosaicSplitWindowGeometry(
      frame: hd,
      aspect: MosaicSplitClientAspect.aspect9x16,
      titleHeight: 38.0,
      maximized: true,
    );
    _expectClose(portrait.clientSize.width, 960.0);
    _expectClose(portrait.clientSize.height, 1042.0);
    _expectClose(portrait.leftWindowRect.top, 0.0);
    _expectClose(portrait.leftWindowRect.height, 1080.0);
    expect(
      portrait.clientSize.height,
      portrait.maximumClientHeight,
    );
  });

  test('every aspect stays bounded, equal, gapped, and centered as one group',
      () {
    for (final MosaicSplitClientAspect aspect
        in MosaicSplitClientAspect.values) {
      final MosaicSplitWindowGeometry geometry = mosaicSplitWindowGeometry(
        frame: hd,
        aspect: aspect,
        titleHeight: 38.0,
      );

      expect(hd.contains(geometry.leftWindowRect.topLeft), isTrue);
      expect(hd.contains(geometry.leftWindowRect.bottomRight), isTrue);
      expect(hd.contains(geometry.rightWindowRect.topLeft), isTrue);
      expect(hd.contains(geometry.rightWindowRect.bottomRight), isTrue);

      _expectClose(
        geometry.rightWindowRect.left - geometry.leftWindowRect.right,
        46.08,
      );
      _expectClose(
        geometry.leftWindowRect.width,
        geometry.rightWindowRect.width,
      );
      _expectClose(
        geometry.leftWindowRect.height,
        geometry.rightWindowRect.height,
      );
      _expectClose(
        geometry.leftClientRect.size.width,
        geometry.rightClientRect.size.width,
      );
      _expectClose(
        geometry.leftClientRect.size.height,
        geometry.rightClientRect.size.height,
      );
      _expectClose(
        geometry.leftTitleRect.height,
        geometry.titleHeight,
      );
      _expectClose(
        geometry.rightTitleRect.height,
        geometry.titleHeight,
      );
      _expectClose(
        geometry.leftClientRect.top,
        geometry.leftTitleRect.bottom,
      );
      _expectClose(
        geometry.rightClientRect.top,
        geometry.rightTitleRect.bottom,
      );

      final double groupCenter = (
            geometry.leftWindowRect.left +
            geometry.rightWindowRect.right
          ) /
          2.0;
      _expectClose(groupCenter, hd.center.dx);
      _expectClose(
        geometry.leftWindowRect.center.dy,
        hd.center.dy,
      );
      _expectClose(
        geometry.rightWindowRect.center.dy,
        hd.center.dy,
      );
    }
  });

  test('frame origin and chrome scale preserve linear geometry scaling', () {
    final MosaicSplitWindowGeometry hdGeometry = mosaicSplitWindowGeometry(
      frame: hd,
      aspect: MosaicSplitClientAspect.aspect4x3,
      titleHeight: 38.0,
    );
    final MosaicSplitWindowGeometry uhdGeometry = mosaicSplitWindowGeometry(
      frame: const Rect.fromLTWH(100, 50, 3840, 2160),
      aspect: MosaicSplitClientAspect.aspect4x3,
      titleHeight: 76.0,
    );

    _expectClose(
      uhdGeometry.clientSize.width,
      hdGeometry.clientSize.width * 2.0,
    );
    _expectClose(
      uhdGeometry.clientSize.height,
      hdGeometry.clientSize.height * 2.0,
    );
    _expectClose(uhdGeometry.gap, hdGeometry.gap * 2.0);
    _expectClose(
      uhdGeometry.leftWindowRect.left - 100.0,
      hdGeometry.leftWindowRect.left * 2.0,
    );
    _expectClose(
      uhdGeometry.leftWindowRect.top - 50.0,
      hdGeometry.leftWindowRect.top * 2.0,
    );
    _expectClose(
      uhdGeometry.rightWindowRect.right - 100.0,
      hdGeometry.rightWindowRect.right * 2.0,
    );
    _expectClose(
      uhdGeometry.rightWindowRect.bottom - 50.0,
      hdGeometry.rightWindowRect.bottom * 2.0,
    );
  });

  test('invalid frame or title inputs are rejected explicitly', () {
    expect(
      () => mosaicSplitWindowGeometry(
        frame: Rect.zero,
        aspect: MosaicSplitClientAspect.aspect16x9,
        titleHeight: 38.0,
      ),
      throwsArgumentError,
    );
    expect(
      () => mosaicSplitWindowGeometry(
        frame: hd,
        aspect: MosaicSplitClientAspect.aspect16x9,
        titleHeight: -1.0,
      ),
      throwsArgumentError,
    );
  });
}
