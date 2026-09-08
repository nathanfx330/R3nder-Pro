// ./test/structural_chrome_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/structural_chrome.dart';

void main() {
  test('legacy STRUCT syntax remains unchanged', () {
    final StructuralChromeSpec? windowed =
        parseStructuralChromeTag('[STRUCT:MOSAIC.wall]');
    final StructuralChromeSpec? full =
        parseStructuralChromeTag('[STRUCT:MOSAIC.wall:FULL]');

    expect(windowed, isNotNull);
    expect(windowed!.source, 'MOSAIC.wall');
    expect(windowed.fullscreen, isFalse);
    expect(windowed.overlayMode, StructuralOverlayMode.defaultOverlay);
    expect(formatStructuralChromeTag(windowed), '[STRUCT:MOSAIC.wall]');

    expect(full, isNotNull);
    expect(full!.fullscreen, isTrue);
    expect(formatStructuralChromeTag(full), '[STRUCT:MOSAIC.wall:FULL]');
  });

  test('custom chrome accepts spaces colons quotes and unicode', () {
    const String authored =
        '[STRUCT:MOSAIC.wall:FULL:OVERLAY=CUSTOM:'
        'TITLE="Archive: Viewer":TOP="FEB 1972":'
        'BOTTOM="Reel \\"A\\" · 16mm"]';

    final StructuralChromeSpec? spec = parseStructuralChromeTag(authored);
    expect(spec, isNotNull);
    expect(spec!.source, 'MOSAIC.wall');
    expect(spec.fullscreen, isTrue);
    expect(spec.overlayMode, StructuralOverlayMode.custom);
    expect(spec.windowTitle, 'Archive: Viewer');
    expect(spec.topOverlay, 'FEB 1972');
    expect(spec.bottomOverlay, 'Reel "A" · 16mm');
    expect(formatStructuralChromeTag(spec), authored);
  });

  test('none hides overlays without discarding dormant custom copy', () {
    const StructuralChromeSpec spec = StructuralChromeSpec(
      source: 'EDIT.main',
      overlayMode: StructuralOverlayMode.none,
      windowTitle: 'Program Monitor',
      topOverlay: 'Dormant top',
      bottomOverlay: 'Dormant bottom',
    );

    final String markup = formatStructuralChromeTag(spec);
    expect(
      markup,
      '[STRUCT:EDIT.main:OVERLAY=NONE:TITLE="Program Monitor":'
      'TOP="Dormant top":BOTTOM="Dormant bottom"]',
    );

    final StructuralChromeSpec? parsed = parseStructuralChromeTag(markup);
    expect(parsed, isNotNull);
    expect(parsed!.overlayMode, StructuralOverlayMode.none);
    expect(parsed.topOverlay, 'Dormant top');
    expect(parsed.bottomOverlay, 'Dormant bottom');
  });

  test('default overlay and default title emit shortest form', () {
    const StructuralChromeSpec spec = StructuralChromeSpec(
      source: 'EDIT.main',
      overlayMode: StructuralOverlayMode.defaultOverlay,
    );

    expect(formatStructuralChromeTag(spec), '[STRUCT:EDIT.main]');
    expect(spec.effectiveWindowTitle, 'EDIT.main');
  });

  test('unknown and malformed tails are rejected', () {
    expect(
      parseStructuralChromeTag('[STRUCT:MOSAIC.wall:OVERLAY=LOUD]'),
      isNull,
    );
    expect(
      parseStructuralChromeTag('[STRUCT:MOSAIC.wall:TITLE=unquoted]'),
      isNull,
    );
    expect(
      parseStructuralChromeTag('[STRUCT:MOSAIC.wall:TITLE="unterminated]'),
      isNull,
    );
    expect(
      parseStructuralChromeTag('[STRUCT:MOSAIC.wall:FULL:FULL]'),
      isNull,
    );
  });
}
