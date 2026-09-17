// ./test/presentation_panel_painter_test.dart

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/presentation_panel_content.dart';
import 'package:r3nder/presentation_panel_painter.dart';

void main() {
  test('authored PANEL font overrides inherited font and blank inherits', () {
    final PresentationPanelContent authored = parsePresentationPanelContent(
      heading: 'ALICE',
      body: '''[PANEL]
PRESET: DOCUMENTARY
FONT: DejaVu Serif
[/PANEL]
Biography.''',
    );
    final PresentationPanelContent inherited = parsePresentationPanelContent(
      heading: 'ALICE',
      body: '''[PANEL]
PRESET: DOCUMENTARY
[/PANEL]
Biography.''',
    );

    expect(presentationPanelFontFamily(authored, 'monospace'), 'DejaVu Serif');
    expect(presentationPanelFontFamily(inherited, 'monospace'), 'monospace');
  });

  test('authored kicker overrides preset label and blank keeps preset default', () {
    final PresentationPanelContent authored = parsePresentationPanelContent(
      heading: 'ALICE',
      body: '''[PANEL]
PRESET: DOCUMENTARY
KICKER: ARCHIVE / INTERVIEW
[/PANEL]''',
    );
    final PresentationPanelContent documentaryDefault =
        parsePresentationPanelContent(
      heading: 'ALICE',
      body: '''[PANEL]
PRESET: DOCUMENTARY
[/PANEL]''',
    );
    final PresentationPanelContent dossierDefault = parsePresentationPanelContent(
      heading: 'ALICE',
      body: '''[PANEL]
PRESET: DOSSIER
[/PANEL]''',
    );

    expect(presentationPanelKickerText(authored), 'ARCHIVE / INTERVIEW');
    expect(
      presentationPanelKickerText(documentaryDefault),
      'PROFILE / DOCUMENTARY',
    );
    expect(
      presentationPanelKickerText(dossierDefault),
      'DOSSIER / SUBJECT FILE',
    );
  });

  test('documentary PANEL semantic painter accepts identity facts and biography', () {
    final PresentationPanelContent content = parsePresentationPanelContent(
      heading: 'JOHN SMITH',
      body: '''[PANEL]
PRESET: DOCUMENTARY
KICKER: ARCHIVE / INTERVIEW
SUBTITLE: Investigative Reporter
META: ORGANIZATION | Example News
META: LOCATION | Washington, DC
META: RANGE | 1990 | 1995
[/PANEL]
Reported on the case for six years.''',
    );
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);

    expect(
      () => paintPresentationPanelContent(
        canvas: canvas,
        cardRect: const Rect.fromLTWH(0, 0, 560, 920),
        contentTop: 310,
        content: content,
        pad: 30,
        scale: 1,
        panelColor: const Color(0xFF1E1E26),
        headColor: const Color(0xFFF2F0EC),
        bodyColor: const Color(0xDDE8E5E0),
        inheritedFontFamily: 'sans-serif',
        showKicker: false,
      ),
      returnsNormally,
    );
    recorder.endRecording().dispose();
  });

  test('photo treatment paints independently of shell choreography', () {
    final PresentationPanelContent content = parsePresentationPanelContent(
      heading: 'SUBJECT',
      body: '''[PANEL]
PRESET: DOSSIER
KICKER: CASE FILE / 17A
SUBTITLE: Case Officer
[/PANEL]''',
    );
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);

    expect(
      () => paintPresentationPanelPhotoTreatment(
        canvas: canvas,
        imageRect: const Rect.fromLTWH(0, 0, 560, 320),
        content: content,
        panelColor: const Color(0xFF1E1E26),
        headColor: const Color(0xFFF2F0EC),
        inheritedFontFamily: 'sans-serif',
        scale: 1,
      ),
      returnsNormally,
    );
    recorder.endRecording().dispose();
  });
}
