// ./test/presentation_panel_content_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/presentation_panel_content.dart';

void main() {
  test('legacy card body stays SIMPLE and untouched', () {
    const String body = 'First line.\n\nSecond line.';
    final PresentationPanelContent content = parsePresentationPanelContent(
      heading: 'ALICE',
      body: body,
    );

    expect(content.structured, isFalse);
    expect(content.preset, PresentationPanelPreset.simple);
    expect(content.heading, 'ALICE');
    expect(content.fontFamily, isEmpty);
    expect(content.subtitle, isEmpty);
    expect(content.metadata, isEmpty);
    expect(content.body, body);
  });

  test('documentary block parses font subtitle metadata and biography', () {
    const String body = '''[PANEL]
PRESET: DOCUMENTARY
FONT: IBM Plex Sans
SUBTITLE: Investigative Reporter
META: ORGANIZATION | Example News
META: LOCATION | Washington, DC
[/PANEL]
Reported on the case for six years.''';

    final PresentationPanelContent content = parsePresentationPanelContent(
      heading: 'ALICE MORGAN',
      body: body,
    );

    expect(content.structured, isTrue);
    expect(content.preset, PresentationPanelPreset.documentary);
    expect(content.heading, 'ALICE MORGAN');
    expect(content.fontFamily, 'IBM Plex Sans');
    expect(content.subtitle, 'Investigative Reporter');
    expect(
      content.metadata,
      const <PresentationPanelMetadata>[
        PresentationPanelMetadata(
          label: 'ORGANIZATION',
          value: 'Example News',
        ),
        PresentationPanelMetadata(
          label: 'LOCATION',
          value: 'Washington, DC',
        ),
      ],
    );
    expect(content.body, 'Reported on the case for six years.');
  });

  test('missing PANEL close degrades to legacy visible text', () {
    const String body = '''[PANEL]
PRESET: DOCUMENTARY
FONT: serif
SUBTITLE: Analyst
Biography survives.''';

    final PresentationPanelContent content = parsePresentationPanelContent(
      heading: 'SUBJECT',
      body: body,
    );

    expect(content.structured, isFalse);
    expect(content.preset, PresentationPanelPreset.simple);
    expect(content.fontFamily, isEmpty);
    expect(content.body, body);
  });

  test('canonical writer keeps old SIMPLE body source-clean', () {
    expect(
      formatPresentationPanelBody(
        preset: PresentationPanelPreset.simple,
        subtitle: '',
        metadata: const <PresentationPanelMetadata>[],
        body: 'Biography.',
      ),
      'Biography.',
    );
  });

  test('a font alone intentionally promotes SIMPLE to structured PANEL', () {
    final String body = formatPresentationPanelBody(
      preset: PresentationPanelPreset.simple,
      fontFamily: 'serif',
      subtitle: '',
      metadata: const <PresentationPanelMetadata>[],
      body: 'Biography.',
    );

    expect(body, contains('PRESET: SIMPLE'));
    expect(body, contains('FONT: serif'));
    final PresentationPanelContent parsed = parsePresentationPanelContent(
      heading: 'SUBJECT',
      body: body,
    );
    expect(parsed.preset, PresentationPanelPreset.simple);
    expect(parsed.fontFamily, 'serif');
    expect(parsed.body, 'Biography.');
  });

  test('canonical writer round trips DOSSIER structured content and font', () {
    final String body = formatPresentationPanelBody(
      preset: PresentationPanelPreset.dossier,
      fontFamily: 'DejaVu Sans',
      subtitle: 'Case Officer',
      metadata: const <PresentationPanelMetadata>[
        PresentationPanelMetadata(label: 'FILE', value: 'A-104'),
        PresentationPanelMetadata(label: 'STATUS', value: 'ACTIVE'),
      ],
      body: 'Subject biography.',
    );

    final PresentationPanelContent parsed = parsePresentationPanelContent(
      heading: 'JOHN SMITH',
      body: body,
    );

    expect(parsed.structured, isTrue);
    expect(parsed.preset, PresentationPanelPreset.dossier);
    expect(parsed.fontFamily, 'DejaVu Sans');
    expect(parsed.subtitle, 'Case Officer');
    expect(parsed.metadata, hasLength(2));
    expect(parsed.body, 'Subject biography.');
  });
}
