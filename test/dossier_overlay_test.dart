// ./test/dossier_overlay_test.dart

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/dossier_overlay.dart';
import 'package:r3nder/presentation_requests.dart';

DossierRequest _request({
  DossierCenterMode mode = DossierCenterMode.mosaic,
}) =>
    DossierRequest(
      folder: 'evidence',
      image: 'person.png',
      holdSplit: 10,
      holdFull: 20,
      centerMode: mode,
      cardLead: 0,
      panelColor: const Color.fromARGB(255, 24, 32, 40),
      heading: 'JOHN SMITH',
      body: 'Biography text.',
    );

StructuralDossierOverlayPlacement _placement(
  DossierRequest request,
  int localFrame, {
  int pages = 3,
}) {
  final frame = structuralDossierTiming(
    request,
    centerPageCount: pages,
  ).frameAt(localFrame)!;
  return StructuralDossierOverlayPlacement(
    dossier: request,
    localFrame: localFrame,
    presentationFrame: frame,
    centerPageCount: pages,
    normalizedRect: const Rect.fromLTWH(0, 0, 1, 1),
  );
}

void main() {
  test('biography becomes evidence without releasing the video shell', () {
    final DossierRequest request = _request();

    final StructuralDossierPanelFrame opening =
        structuralDossierPanelFrame(_placement(request, 0));
    expect(opening.shellSlide, 0.0);
    expect(opening.cardSlide, 0.0);
    expect(opening.evidenceVisibility, 0.0);

    final StructuralDossierPanelFrame split =
        structuralDossierPanelFrame(_placement(request, 16));
    expect(split.shellSlide, 1.0);
    expect(split.cardSlide, 1.0);
    expect(split.evidenceVisibility, 0.0);

    final StructuralDossierPanelFrame halfwayTransition =
        structuralDossierPanelFrame(_placement(request, 32));
    expect(halfwayTransition.shellSlide, 1.0);
    expect(halfwayTransition.cardSlide, closeTo(0.5, 0.000001));
    expect(halfwayTransition.evidenceVisibility, closeTo(0.5, 0.000001));

    final StructuralDossierPanelFrame center =
        structuralDossierPanelFrame(_placement(request, 38));
    expect(center.shellSlide, 1.0);
    expect(center.cardSlide, 0.0);
    expect(center.evidenceVisibility, 1.0);
    expect(center.centerPageIndex, 0);

    final StructuralDossierPanelFrame pan =
        structuralDossierPanelFrame(_placement(request, 69));
    expect(pan.shellSlide, 1.0);
    expect(pan.evidenceVisibility, 1.0);
    expect(pan.centerPageIndex, 0);
    expect(pan.pagePan, closeTo(11 / 22, 0.000001));

    final StructuralDossierPanelFrame last =
        structuralDossierPanelFrame(_placement(request, 153));
    expect(last.shellSlide, closeTo(1 / 12, 0.000001));
    expect(last.cardSlide, 0.0);
    expect(last.evidenceVisibility, closeTo(1 / 12, 0.000001));
  });

  test('SIDE_ONLY closes the biography and shell together', () {
    final DossierRequest request = _request(mode: DossierCenterMode.sideOnly);
    final timing = structuralDossierTiming(request, centerPageCount: 0);
    final int lastFrame = timing.durationFrames - 1;
    final StructuralDossierPanelFrame last = structuralDossierPanelFrame(
      _placement(request, lastFrame, pages: 0),
    );

    expect(last.shellSlide, closeTo(1 / 16, 0.000001));
    expect(last.cardSlide, closeTo(1 / 16, 0.000001));
    expect(last.evidenceVisibility, 0.0);
  });

  test('MOSAIC page count follows ordered evidence folder size', () async {
    final Directory root =
        await Directory.systemTemp.createTemp('r3nder_dossier_overlay_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final Directory evidence = Directory('${root.path}/images/evidence')
      ..createSync(recursive: true);
    for (int i = 0; i < 7; i++) {
      File('${evidence.path}/$i.png').writeAsBytesSync(const <int>[]);
    }

    String resolve(String source) => '${root.path}/$source';

    final DossierRequest mosaic = _request();
    expect(structuralDossierImageSources(mosaic, resolve), hasLength(7));
    expect(structuralDossierCenterPageCount(mosaic, resolve), 3);

    expect(
      structuralDossierCenterPageCount(
        _request(mode: DossierCenterMode.grid),
        resolve,
      ),
      1,
    );
    expect(
      structuralDossierCenterPageCount(
        _request(mode: DossierCenterMode.sideOnly),
        resolve,
      ),
      0,
    );
  });
}
