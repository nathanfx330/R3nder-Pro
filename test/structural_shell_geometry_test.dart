// ./test/structural_shell_geometry_test.dart

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/structural_sequence.dart';
import 'package:r3nder/structural_shell_geometry.dart';

void main() {
  const Rect full = Rect.fromLTWH(0, 0, 1, 1);
  const Rect parked = Rect.fromLTWH(0.10, 0.12, 0.80, 0.70);
  const Rect presentation = Rect.fromLTWH(0.08, 0.10, 0.84, 0.74);
  const Rect previous = Rect.fromLTWH(0.02, 0.03, 0.96, 0.90);
  const Rect closingOrigin = Rect.fromLTWH(0.04, 0.18, 0.58, 0.56);

  StructuralShellFrame frame(
    StructuralSequenceStage stage,
    double progress, {
    bool ready = true,
    bool seamless = false,
    bool chainedFrom = false,
    bool chainedTo = false,
  }) {
    return structuralShellFrameAt(
      stage: stage,
      linearProgress: progress,
      fullTerminalRect: full,
      terminalParkRect: parked,
      presentationRect: presentation,
      previousPresentationRect: previous,
      closingOriginRect: closingOrigin,
      seamlessFromPrevious: seamless,
      chainedFromPrevious: chainedFrom,
      chainedToNext: chainedTo,
      contentReady: ready,
    );
  }

  test('preview readiness is the only opening/showing gate', () {
    final Rect emergence = structuralShellEmergenceRect(parked);

    final StructuralShellFrame waiting = frame(
      StructuralSequenceStage.opening,
      0.75,
      ready: false,
    );
    expect(waiting.structuralRect, emergence);
    expect(waiting.structuralOpacity, 0.0);
    expect(waiting.terminalOpacity, 1.0);

    final StructuralShellFrame ready = frame(
      StructuralSequenceStage.opening,
      0.75,
    );
    expect(ready.structuralRect, isNot(emergence));
    expect(ready.structuralOpacity, greaterThan(0.0));
    expect(ready.terminalOpacity, lessThan(1.0));

    final StructuralShellFrame showingWaiting = frame(
      StructuralSequenceStage.showing,
      0.0,
      ready: false,
    );
    expect(showingWaiting.structuralRect, emergence);
    expect(showingWaiting.structuralOpacity, 0.0);

    final StructuralShellFrame showingReady = frame(
      StructuralSequenceStage.showing,
      0.0,
    );
    expect(showingReady.structuralRect, presentation);
    expect(showingReady.structuralOpacity, 1.0);
  });

  test('seamless handoff holds previous rect until incoming content is ready', () {
    final StructuralShellFrame waiting = frame(
      StructuralSequenceStage.opening,
      0.6,
      ready: false,
      seamless: true,
    );
    expect(waiting.structuralRect, previous);
    expect(waiting.structuralOpacity, 0.0);
    expect(waiting.terminalOpacity, 0.0);

    final StructuralShellFrame ready = frame(
      StructuralSequenceStage.opening,
      0.6,
      seamless: true,
    );
    expect(ready.structuralRect, isNot(previous));
    expect(ready.structuralOpacity, 1.0);
    expect(ready.terminalOpacity, 0.0);
  });

  test('closing starts from supplied truncation origin', () {
    final StructuralShellFrame first = frame(
      StructuralSequenceStage.closing,
      0.0,
    );
    expect(first.structuralRect, closingOrigin);
    expect(first.structuralOpacity, 1.0);

    final StructuralShellFrame chained = frame(
      StructuralSequenceStage.closing,
      0.5,
      chainedTo: true,
    );
    expect(chained.terminalOpacity, 0.0);
    expect(chained.structuralWindowPresent, isTrue);
  });

  test('same shell evaluator is coordinate-space invariant', () {
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

    for (final StructuralSequenceStage stage in StructuralSequenceStage.values) {
      final StructuralShellFrame normalizedFrame = structuralShellFrameAt(
        stage: stage,
        linearProgress: 0.43,
        fullTerminalRect: full,
        terminalParkRect: parked,
        presentationRect: presentation,
        previousPresentationRect: previous,
        closingOriginRect: closingOrigin,
        seamlessFromPrevious: false,
        chainedFromPrevious: false,
        chainedToNext: false,
        contentReady: true,
      );
      final StructuralShellFrame pixelFrame = structuralShellFrameAt(
        stage: stage,
        linearProgress: 0.43,
        fullTerminalRect: pixels(full),
        terminalParkRect: pixels(parked),
        presentationRect: pixels(presentation),
        previousPresentationRect: pixels(previous),
        closingOriginRect: pixels(closingOrigin),
        seamlessFromPrevious: false,
        chainedFromPrevious: false,
        chainedToNext: false,
        contentReady: true,
      );

      final Rect roundTripTerminal = normalized(pixelFrame.terminalRect);
      final Rect roundTripStructural = normalized(pixelFrame.structuralRect);
      expect(roundTripTerminal.left, closeTo(normalizedFrame.terminalRect.left, 1e-9));
      expect(roundTripTerminal.top, closeTo(normalizedFrame.terminalRect.top, 1e-9));
      expect(roundTripTerminal.right, closeTo(normalizedFrame.terminalRect.right, 1e-9));
      expect(roundTripTerminal.bottom, closeTo(normalizedFrame.terminalRect.bottom, 1e-9));
      expect(roundTripStructural.left, closeTo(normalizedFrame.structuralRect.left, 1e-9));
      expect(roundTripStructural.top, closeTo(normalizedFrame.structuralRect.top, 1e-9));
      expect(roundTripStructural.right, closeTo(normalizedFrame.structuralRect.right, 1e-9));
      expect(roundTripStructural.bottom, closeTo(normalizedFrame.structuralRect.bottom, 1e-9));
      expect(pixelFrame.desktopOpacity, normalizedFrame.desktopOpacity);
      expect(pixelFrame.terminalOpacity, normalizedFrame.terminalOpacity);
      expect(pixelFrame.terminalChrome, normalizedFrame.terminalChrome);
      expect(pixelFrame.structuralOpacity, normalizedFrame.structuralOpacity);
      expect(
        pixelFrame.structuralWindowPresent,
        normalizedFrame.structuralWindowPresent,
      );
    }
  });
}
