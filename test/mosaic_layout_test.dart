// ./test/mosaic_layout_test.dart

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/card_overlay_state.dart';
import 'package:r3nder/dossier_overlay_state.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/edit_video_compositor.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/mosaic_layout.dart';
import 'package:r3nder/project_clock.dart';

const ui.Size _outputSize = ui.Size(101, 57);
const List<int> _red = <int>[255, 0, 0, 255];
const List<int> _green = <int>[0, 255, 0, 255];
const List<int> _blue = <int>[0, 0, 255, 255];

class _FixtureBackend implements MediaDecoderBackend {
  @override
  MediaDecoder open(String resolvedPath) {
    switch (resolvedPath) {
      case 'red.mp4':
        return _FixtureDecoder(_red);
      case 'green.mp4':
        return _FixtureDecoder(_green);
      case 'blue.mp4':
        return _FixtureDecoder(_blue);
      default:
        throw StateError('Unexpected fixture source "$resolvedPath".');
    }
  }
}

class _FixtureDecoder implements MediaDecoder {
  _FixtureDecoder(this.color);

  final List<int> color;

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    final Uint8List rgba = Uint8List(width * height * 4);
    for (int i = 0; i < rgba.length; i += 4) {
      rgba.setRange(i, i + 4, color);
    }
    return DecodedMediaFrame(
      requestedSourceFrame: requestedSourceFrame,
      actualSourceFrame: requestedSourceFrame,
      width: width,
      height: height,
      stride: width * 4,
      rgba: rgba,
    );
  }

  @override
  void dispose() {}
}

String _sourceFor(int count, {int? dossierPane}) {
  final List<String> media = <String>['red.mp4', 'green.mp4', 'blue.mp4'];
  final StringBuffer out = StringBuffer('[MOSAIC:wall]\n');
  for (int i = 0; i < count; i++) {
    out
      ..writeln('[PANE:p$i]')
      ..writeln('[CLIP:c$i:${media[i]}:0:0:300:1]')
      ..writeln('[CUE:0]')
      ..writeln('[CARD:overlay.png:10:30,30,38:CARD $i]')
      ..writeln('Card $i body.')
      ..writeln('[/CARD]')
      ..writeln('[/CUE]');
    if (dossierPane == i) {
      out
        ..writeln('[CUE:0]')
        ..writeln(
          '[DOSSIER:evidence:person.png:10:20:0:MOSAIC:24,32,40:DOSSIER $i]',
        )
        ..writeln('Dossier $i body.')
        ..writeln('[/DOSSIER]')
        ..writeln('[/CUE]');
    }
    out
      ..writeln('[/CLIP]')
      ..writeln('[/PANE]');
  }
  out.writeln('[/MOSAIC]');
  return out.toString();
}

Uint8List _expectedPixels(int count) {
  const int width = 101;
  const int height = 57;
  final Uint8List rgba = Uint8List(width * height * 4);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final List<int> color;
      if (count == 1 || x < 57) {
        color = _red;
      } else if (count == 2 || y < 29) {
        color = _green;
      } else {
        color = _blue;
      }
      final int offset = (y * width + x) * 4;
      rgba.setRange(offset, offset + 4, color);
    }
  }
  return rgba;
}

List<int> _pixel(Uint8List rgba, int x, int y) {
  final int offset = (y * 101 + x) * 4;
  return rgba.sublist(offset, offset + 4);
}

void _expectRenderedPixels(EditVideoCompositeResult result, int count) {
  expect(result.width, 101);
  expect(result.height, 57);
  expect(result.stride, 404);
  expect(result.rgba, isNotNull);
  final Uint8List rgba = result.rgba!;
  expect(rgba, orderedEquals(_expectedPixels(count)));

  if (count >= 2) {
    expect(_pixel(rgba, 56, 0), _red);
    expect(_pixel(rgba, 57, 0), _green);
  }
  if (count == 3) {
    expect(_pixel(rgba, 57, 28), _green);
    expect(_pixel(rgba, 57, 29), _blue);
  }
}

void _verifyLayout(int count, List<ui.Rect> expected) {
  expect(mosaicPaneLayout(count), expected);

  final String cardSource = _sourceFor(count);
  final EditDocumentModel cardModel = EditDocumentModel.parse(cardSource);
  final StructuralSourceRef root =
      StructuralSourceRef.tryParse('MOSAIC.wall')!;

  final List<StructuralCardOverlayPlacement> cards =
      structuralCardOverlayPlacements(cardModel, root, 0);
  expect(cards, hasLength(count));
  for (int i = 0; i < count; i++) {
    expect(cards[i].card.heading, 'CARD $i');
    expect(cards[i].normalizedRect, expected[i]);
  }

  for (int pane = 0; pane < count; pane++) {
    final EditDocumentModel dossierModel =
        EditDocumentModel.parse(_sourceFor(count, dossierPane: pane));
    final StructuralDossierOverlayPlacement? dossier =
        structuralDossierPlacement(
      dossierModel,
      root,
      0,
      evidencePageCountFor: (_) => 1,
    );
    expect(dossier, isNotNull);
    expect(dossier!.dossier.heading, 'DOSSIER $pane');
    expect(dossier.normalizedRect, expected[pane]);
  }

  final _FixtureBackend backend = _FixtureBackend();
  final MediaLayer layer = MediaLayer(
    editDocument: cardModel,
    backend: backend,
    resolveSource: (String value) => value,
  );
  final EditVideoCompositor compositor = EditVideoCompositor.forModel(
    model: cardModel,
    mediaLayer: layer,
    backend: backend,
    resolveSource: (String value) => value,
  );
  final ProjectTime time =
      ProjectTime(frame: 0, mode: ProjectClockMode.scrub);

  try {
    _expectRenderedPixels(
      compositor.renderSource('MOSAIC.wall', time, _outputSize),
      count,
    );
    _expectRenderedPixels(
      compositor.renderSourceAvailable('MOSAIC.wall', time, _outputSize),
      count,
    );
  } finally {
    compositor.dispose();
    layer.dispose();
  }
}

void main() {
  test('legacy empty and unsupported count behavior is preserved', () {
    expect(mosaicPaneLayout(0), isEmpty);
    expect(mosaicPaneLayout(-1), isEmpty);
    expect(
      mosaicPaneLayout(4),
      const <ui.Rect>[
        ui.Rect.fromLTRB(0, 0, 0.56, 1),
        ui.Rect.fromLTRB(0.56, 0, 1, 0.5),
        ui.Rect.fromLTRB(0.56, 0.5, 1, 1),
      ],
    );
  });

  test('one pane shares exact legacy geometry across pixels and cues', () {
    _verifyLayout(
      1,
      const <ui.Rect>[ui.Rect.fromLTRB(0, 0, 1, 1)],
    );
  });

  test('two panes share exact legacy geometry across pixels and cues', () {
    _verifyLayout(
      2,
      const <ui.Rect>[
        ui.Rect.fromLTRB(0, 0, 0.56, 1),
        ui.Rect.fromLTRB(0.56, 0, 1, 1),
      ],
    );
  });

  test('three panes share exact legacy geometry across pixels and cues', () {
    _verifyLayout(
      3,
      const <ui.Rect>[
        ui.Rect.fromLTRB(0, 0, 0.56, 1),
        ui.Rect.fromLTRB(0.56, 0, 1, 0.5),
        ui.Rect.fromLTRB(0.56, 0.5, 1, 1),
      ],
    );
  });
}
