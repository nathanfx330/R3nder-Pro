// ./test/presentation_card_face_parity_test.dart

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/card_overlay.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/presentation_panel_painter.dart';

const Size _size = Size(640, 360);

Future<Uint8List> _makeHeroPng() async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 16, 9),
    Paint()..color = const Color(0xFF29445C),
  );
  canvas.drawRect(
    const Rect.fromLTWH(0, 5, 16, 4),
    Paint()..color = const Color(0xFFB88648),
  );
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(16, 9);
  picture.dispose();
  try {
    final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('Unable to encode test hero PNG.');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
  }
}

Future<Uint8List> _render(
  void Function(Canvas canvas) paint,
) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  paint(canvas);
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(
    _size.width.toInt(),
    _size.height.toInt(),
  );
  picture.dispose();
  try {
    final ByteData? data =
        await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) throw StateError('Unable to read rendered test pixels.');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
  }
}

StructuralCardOverlayPlacement _seatedPlacement(String body) {
  final String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:shot:video/shot.mp4:0:0:120:1]
[CUE:0][SIDECARD:hero.png:45:30,32,40:ELK IN THE HIGH COUNTRY]$body[/SIDECARD][/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
''';
  final EditDocumentModel model = EditDocumentModel.parse(source);
  final StructuralSourceRef root = StructuralSourceRef.tryParse('EDIT.main')!;
  final StructuralCardOverlayPlacement placement =
      structuralCardOverlayPlacements(model, root, 16).single;
  expect(placement.isSideCard, isTrue);
  expect(placement.slide, 1.0);
  return placement;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final MapEntry<String, String> fixture in <String, String>{
    'legacy simple': 'Body copy for the legacy simple face.',
    'structured documentary': '''[PANEL]
PRESET: DOCUMENTARY
KICKER: WILDLIFE
SUBTITLE: Seasonal migration
[/PANEL]
Body copy for the documentary face.''',
  }.entries) {
    test(
      'shared face painter is pixel-identical to seated SIDECARD runtime: '
      '${fixture.key}',
      () async {
        final Directory root = Directory.systemTemp.createTempSync(
          'r3nder_card_face_parity_',
        );
        final File hero = File('${root.path}/hero.png');
        await hero.writeAsBytes(await _makeHeroPng(), flush: true);

        final StructuralCardOverlayPlacement placement =
            _seatedPlacement(fixture.value);
        final CardOverlayImageCache images = CardOverlayImageCache(
          (String source) => source.endsWith('hero.png') ? hero.path : source,
        );

        addTearDown(() {
          images.dispose();
          if (root.existsSync()) root.deleteSync(recursive: true);
        });

        final bool changed = await images.ensure(
          <StructuralCardOverlayPlacement>[placement],
        );
        expect(changed, isTrue);
        final ui.Image? decoded = images.imageFor(placement.card);
        expect(decoded, isNotNull);

        final Uint8List runtime = await _render((Canvas canvas) {
          paintStructuralSideCardPanel(
            canvas: canvas,
            size: _size,
            placement: placement,
            images: images,
            fontFamily: 'monospace',
          );
        });

        // Use the exact seated rectangle owned by the runtime geometry. The
        // test deliberately does not reconstruct an equivalent rectangle,
        // because it is proving that no visual responsibility remained in the
        // caller after face extraction.
        final Rect runtimeRect = sideCardSeatedPanelRect(_size);
        final Uint8List direct = await _render((Canvas canvas) {
          paintPresentationCardFace(
            canvas: canvas,
            compositionSize: _size,
            cardRect: runtimeRect,
            card: placement.card,
            image: decoded,
            inheritedFontFamily: 'monospace',
          );
        });

        expect(
          direct,
          orderedEquals(runtime),
          reason:
              'The seated runtime path and direct shared face painter must be '
              'pixel-identical; any mismatch means visual work stayed behind '
              'in the caller.',
        );
      },
    );
  }
}
