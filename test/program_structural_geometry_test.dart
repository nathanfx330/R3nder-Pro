// ./test/program_structural_geometry_test.dart

import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/program_structural_export.dart';

void main() {
  test('STRUCT bake target keeps a 16:9 client at preview width', () {
    const int width = 1920;
    const int height = 1080;
    const double titleHeight = 38.0;

    final ui.Rect target = structuralProgramTargetRectForOutput(
      outputWidth: width,
      outputHeight: height,
      titleHeight: titleHeight,
    );

    final double pixelWidth = target.width * width;
    final double pixelWindowHeight = target.height * height;
    final double pixelClientHeight = pixelWindowHeight - titleHeight;

    expect(pixelWidth / pixelClientHeight, closeTo(16.0 / 9.0, 1e-9));
    expect(target.height, closeTo(0.78, 1e-9));
    expect(target.width, closeTo(0.7448148148148148, 1e-9));
    expect(target.width, lessThan(0.80));
  });

  test('STRUCT bake target is resolution invariant from 1080p to 4K', () {
    final ui.Rect hd = structuralProgramTargetRectForOutput(
      outputWidth: 1920,
      outputHeight: 1080,
      titleHeight: 38.0,
    );
    final ui.Rect uhd = structuralProgramTargetRectForOutput(
      outputWidth: 3840,
      outputHeight: 2160,
      titleHeight: 76.0,
    );

    expect(uhd.left, closeTo(hd.left, 1e-9));
    expect(uhd.top, closeTo(hd.top, 1e-9));
    expect(uhd.width, closeTo(hd.width, 1e-9));
    expect(uhd.height, closeTo(hd.height, 1e-9));
  });
}
