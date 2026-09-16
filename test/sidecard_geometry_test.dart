// ./test/sidecard_geometry_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/sidecard_geometry.dart';

void _expectRect(Rect actual, Rect expected) {
  expect(actual.left, closeTo(expected.left, 0.0001));
  expect(actual.top, closeTo(expected.top, 0.0001));
  expect(actual.width, closeTo(expected.width, 0.0001));
  expect(actual.height, closeTo(expected.height, 0.0001));
}

void main() {
  test('SIDECARD seated geometry keeps video and card as siblings', () {
    const Size size = Size(1920, 1080);
    final Rect video = sideCardSeatedVideoWindowRect(size);
    final Rect card = sideCardSeatedPanelRect(size);

    _expectRect(
      video,
      const Rect.fromLTWH(67.2, 193.76, 1163.52, 692.48),
    );
    _expectRect(
      card,
      const Rect.fromLTWH(1276.8, 193.76, 576.0, 692.48),
    );
    expect(card.left, greaterThan(video.right));
  });

  test('shared shell evaluator owns ease and moving window lerp', () {
    const Size size = Size(1920, 1080);
    const Rect preCue = Rect.fromLTWH(0, 0, 1920, 1080);

    final SideCardShellFrame start = sideCardShellFrameAt(
      size: size,
      preCueRect: preCue,
      slide: 0.0,
    );
    _expectRect(start.videoWindowRect, preCue);
    expect(start.motionProgress, 0.0);

    final SideCardShellFrame halfway = sideCardShellFrameAt(
      size: size,
      preCueRect: preCue,
      slide: 0.5,
    );
    final double expectedEase = Curves.easeOutCubic.transform(0.5);
    expect(halfway.motionProgress, closeTo(expectedEase, 0.000001));
    _expectRect(
      halfway.videoWindowRect,
      Rect.lerp(
        preCue,
        sideCardSeatedVideoWindowRect(size),
        expectedEase,
      )!,
    );

    final SideCardShellFrame seated = sideCardShellFrameAt(
      size: size,
      preCueRect: preCue,
      slide: 1.0,
    );
    _expectRect(seated.videoWindowRect, sideCardSeatedVideoWindowRect(size));
    expect(seated.motionProgress, 1.0);
    expect(seated.desktopOpacity, 1.0);
    expect(seated.terminalOpacity, 0.0);
  });

  test('final CARD closing frame still displaces SIDECARD window', () {
    const Size size = Size(1920, 1080);
    const Rect preCue = Rect.fromLTWH(0, 0, 1920, 1080);

    final SideCardShellFrame finalClosing = sideCardShellFrameAt(
      size: size,
      preCueRect: preCue,
      slide: 1 / 16,
    );

    expect(finalClosing.motionProgress, greaterThan(0.0));
    expect(finalClosing.videoWindowRect.left, greaterThan(preCue.left));
    expect(finalClosing.videoWindowRect.width, lessThan(preCue.width));
  });

  test('source truncation preserves the final displaced closing origin', () {
    const Size size = Size(1920, 1080);
    const Rect preCue = Rect.fromLTWH(0, 0, 1920, 1080);
    const double truncatedSlide = 3 / 16;

    final Rect expected = sideCardVideoWindowRectAt(
      size: size,
      preCueRect: preCue,
      slide: truncatedSlide,
    );
    final Rect origin = sideCardClosingOriginRect(
      size: size,
      preCueRect: preCue,
      truncatedSlide: truncatedSlide,
    );

    _expectRect(origin, expected);
    expect(origin.left, greaterThan(preCue.left));
    expect(origin.width, lessThan(preCue.width));

    _expectRect(
      sideCardClosingOriginRect(
        size: size,
        preCueRect: preCue,
        truncatedSlide: null,
      ),
      preCue,
    );
  });

  test('preview-origin offset is part of the same geometry authority', () {
    const Size size = Size(800, 450);
    const Offset origin = Offset(0, 25);
    const Rect preCue = Rect.fromLTWH(56, 75, 688, 351);

    final SideCardShellFrame frame = sideCardShellFrameAt(
      size: size,
      origin: origin,
      preCueRect: preCue,
      slide: 1.0,
    );

    _expectRect(
      frame.videoWindowRect,
      sideCardSeatedVideoWindowRect(size).shift(origin),
    );
  });
}
