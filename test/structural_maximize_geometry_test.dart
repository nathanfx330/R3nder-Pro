// ./test/structural_maximize_geometry_test.dart

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/structural_shell_geometry.dart';

void main() {
  const Rect base = Rect.fromLTWH(0.10, 0.12, 0.80, 0.70);
  const Rect full = Rect.fromLTWH(0, 0, 1, 1);

  test('amount zero preserves window and amount one reaches full frame', () {
    final StructuralMaximizeGeometryFrame zero =
        structuralMaximizeGeometryFrameAt(
      baseRect: base,
      fullRect: full,
      amount: 0.0,
    );
    expect(zero.structuralRect, base);
    expect(zero.windowChrome, 1.0);

    final StructuralMaximizeGeometryFrame one =
        structuralMaximizeGeometryFrameAt(
      baseRect: base,
      fullRect: full,
      amount: 1.0,
    );
    expect(one.structuralRect, full);
    expect(one.windowChrome, 0.0);
  });

  test('geometry is coordinate-space invariant for preview and bake', () {
    const double sx = 1920.0;
    const double sy = 1080.0;
    Rect pixels(Rect r) => Rect.fromLTRB(
          r.left * sx,
          r.top * sy,
          r.right * sx,
          r.bottom * sy,
        );
    Rect normalized(Rect r) => Rect.fromLTRB(
          r.left / sx,
          r.top / sy,
          r.right / sx,
          r.bottom / sy,
        );

    final StructuralMaximizeGeometryFrame n =
        structuralMaximizeGeometryFrameAt(
      baseRect: base,
      fullRect: full,
      amount: 0.43,
    );
    final StructuralMaximizeGeometryFrame p =
        structuralMaximizeGeometryFrameAt(
      baseRect: pixels(base),
      fullRect: pixels(full),
      amount: 0.43,
    );
    final Rect roundTrip = normalized(p.structuralRect);

    expect(roundTrip.left, closeTo(n.structuralRect.left, 1e-9));
    expect(roundTrip.top, closeTo(n.structuralRect.top, 1e-9));
    expect(roundTrip.right, closeTo(n.structuralRect.right, 1e-9));
    expect(roundTrip.bottom, closeTo(n.structuralRect.bottom, 1e-9));
    expect(p.windowChrome, n.windowChrome);
  });

  test('rect movement is monotonic toward fullscreen', () {
    Rect previous = base;
    for (int i = 1; i <= 12; i++) {
      final StructuralMaximizeGeometryFrame current =
          structuralMaximizeGeometryFrameAt(
        baseRect: base,
        fullRect: full,
        amount: i / 12,
      );
      expect(current.structuralRect.left, lessThanOrEqualTo(previous.left));
      expect(current.structuralRect.top, lessThanOrEqualTo(previous.top));
      expect(current.structuralRect.right, greaterThanOrEqualTo(previous.right));
      expect(current.structuralRect.bottom, greaterThanOrEqualTo(previous.bottom));
      previous = current.structuralRect;
    }
  });
}
