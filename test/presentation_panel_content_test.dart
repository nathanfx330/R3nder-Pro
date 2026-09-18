// ./test/presentation_panel_content_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/presentation_panel_content.dart';

void main() {
  test('legacy card body stays SIMPLE and byte-clean', () {
    const String body = 'First line.\r\n\r\nSecond line.';
    final PresentationPanelContent content = parsePresentationPanelContent(
      heading: 'ALICE',
      body: body,
    );

    expect(content.panelOpened, isFalse);
    expect(content.structured, isFalse);
    expect(content.preset, PresentationPanelPreset.simple);
    expect(content.heading, 'ALICE');
    expect(content.kicker, isEmpty);
    expect(content.fontFamily, isEmpty);
    expect(content.subtitle, isEmpty);
    expect(content.metadata, isEmpty);
    expect(content.body, body);
    expect(content.issues, isEmpty);
  });

  test('preset default kickers are semantic and shared', () {
    expect(
      presentationPanelDefaultKicker(PresentationPanelPreset.documentary),
      'PROFILE / DOCUMENTARY',
    );
    expect(
      presentationPanelDefaultKicker(PresentationPanelPreset.dossier),
      'DOSSIER / SUBJECT FILE',
    );
    expect(
      presentationPanelDefaultKicker(PresentationPanelPreset.simple),
      'PROFILE / DOCUMENTARY',
    );
  });

  test('documentary block parses kicker font subtitle metadata and biography', () {
    const String body = '''[PANEL]
PRESET: DOCUMENTARY
KICKER: ARCHIVE / INTERVIEW
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

    expect(content.panelOpened, isTrue);
    expect(content.structured, isTrue);
    expect(content.hasErrors, isFalse);
    expect(content.preset, PresentationPanelPreset.documentary);
    expect(content.heading, 'ALICE MORGAN');
    expect(content.kicker, 'ARCHIVE / INTERVIEW');
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

  test('missing PANEL close is explicit error and keeps raw body', () {
    const String body = '[PANEL]\r\nPRESET: DOCUMENTARY\r\nBiography survives.';

    final PresentationPanelContent content = parsePresentationPanelContent(
      heading: 'SUBJECT',
      body: body,
    );

    expect(content.panelOpened, isTrue);
    expect(content.structured, isFalse);
    expect(content.hasErrors, isTrue);
    expect(content.issues, hasLength(1));
    expect(
      content.issues.single.code,
      PresentationPanelIssueCode.missingClosingTag,
    );
    expect(content.body, body);
  });

  test('unknown directive is preserved through canonical writer', () {
    const String source = '''[PANEL]
PRESET: DOCUMENTARY
FUTURE_STYLE: archive-2
SUBTITLE: Analyst
[/PANEL]
Biography.''';

    final PresentationPanelContent parsed = parsePresentationPanelContent(
      heading: 'SUBJECT',
      body: source,
    );

    expect(parsed.hasErrors, isFalse);
    expect(parsed.hasWarnings, isTrue);
    expect(parsed.preservedDirectives, <String>['FUTURE_STYLE: archive-2']);
    expect(
      parsed.issues.single.code,
      PresentationPanelIssueCode.unknownDirective,
    );

    final String rewritten = formatPresentationPanelBody(
      preset: parsed.preset,
      kicker: parsed.kicker,
      fontFamily: parsed.fontFamily,
      subtitle: parsed.subtitle,
      metadata: parsed.metadata,
      preservedDirectives: parsed.preservedDirectives,
      body: parsed.body,
    );
    expect(rewritten, contains('FUTURE_STYLE: archive-2'));
  });

  test('malformed META is preserved and reported instead of dropped', () {
    const String source = '''[PANEL]
PRESET: DOCUMENTARY
META: BROKEN ROW
[/PANEL]
Biography.''';

    final PresentationPanelContent parsed = parsePresentationPanelContent(
      heading: 'SUBJECT',
      body: source,
    );

    expect(parsed.hasErrors, isTrue);
    expect(parsed.metadata, isEmpty);
    expect(parsed.preservedDirectives, <String>['META: BROKEN ROW']);
    expect(
      parsed.issues.single.code,
      PresentationPanelIssueCode.malformedMetadata,
    );
  });

  test('META first pipe separates label and later pipes remain value', () {
    const String source = '''[PANEL]
PRESET: DOCUMENTARY
META: RANGE | 1990 | 1995
[/PANEL]''';

    final PresentationPanelContent parsed = parsePresentationPanelContent(
      heading: 'SUBJECT',
      body: source,
    );

    expect(parsed.hasErrors, isFalse);
    expect(parsed.metadata.single.label, 'RANGE');
    expect(parsed.metadata.single.value, '1990 | 1995');
  });

  test('invalid preset is preserved and reported', () {
    const String source = '''[PANEL]
PRESET: DOCUMENTARRY
[/PANEL]''';

    final PresentationPanelContent parsed = parsePresentationPanelContent(
      heading: 'SUBJECT',
      body: source,
    );

    expect(parsed.hasErrors, isTrue);
    expect(parsed.preset, PresentationPanelPreset.simple);
    expect(parsed.preservedDirectives, <String>['PRESET: DOCUMENTARRY']);
    expect(parsed.issues.single.code, PresentationPanelIssueCode.invalidPreset);
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

  test('a kicker alone intentionally promotes SIMPLE to structured PANEL', () {
    final String body = formatPresentationPanelBody(
      preset: PresentationPanelPreset.simple,
      kicker: 'ARCHIVE / INTERVIEW',
      subtitle: '',
      metadata: const <PresentationPanelMetadata>[],
      body: 'Biography.',
    );

    expect(body, contains('PRESET: SIMPLE'));
    expect(body, contains('KICKER: ARCHIVE / INTERVIEW'));
    final PresentationPanelContent parsed = parsePresentationPanelContent(
      heading: 'SUBJECT',
      body: body,
    );
    expect(parsed.kicker, 'ARCHIVE / INTERVIEW');
    expect(parsed.body, 'Biography.');
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

  test('canonical writer round trips DOSSIER structured content font and kicker', () {
    final String body = formatPresentationPanelBody(
      preset: PresentationPanelPreset.dossier,
      kicker: 'CASE FILE / 17A',
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
    expect(parsed.kicker, 'CASE FILE / 17A');
    expect(parsed.fontFamily, 'DejaVu Sans');
    expect(parsed.subtitle, 'Case Officer');
    expect(parsed.metadata, hasLength(2));
    expect(parsed.body, 'Subject biography.');
  });

  test('EDITORIAL round trips and has no implicit kicker', () {
    final String body = formatPresentationPanelBody(
      preset: PresentationPanelPreset.editorial,
      kicker: 'WILDLIFE',
      subtitle: '',
      metadata: const <PresentationPanelMetadata>[],
      body: 'Elk move to higher elevations.',
    );

    expect(body, contains('PRESET: EDITORIAL'));
    final PresentationPanelContent parsed = parsePresentationPanelContent(
      heading: 'Elk in the High Country',
      body: body,
    );
    expect(parsed.preset, PresentationPanelPreset.editorial);
    expect(parsed.kicker, 'WILDLIFE');
    expect(
      presentationPanelDefaultKicker(PresentationPanelPreset.editorial),
      isEmpty,
    );
  });


  test('style directives round trip reference sizes and image percentage', () {
    final String body = formatPresentationPanelBody(
      preset: PresentationPanelPreset.editorial,
      headingSize: 32,
      bodySize: 17,
      imageFraction: 0.38,
      subtitle: '',
      metadata: const <PresentationPanelMetadata>[],
      body: 'Editorial copy.',
    );

    expect(body, contains('HEADING_SIZE: 32'));
    expect(body, contains('BODY_SIZE: 17'));
    expect(body, contains('IMAGE: 38%'));

    final PresentationPanelContent parsed = parsePresentationPanelContent(
      heading: 'Heading',
      body: body,
    );
    expect(parsed.headingSize, 32);
    expect(parsed.bodySize, 17);
    expect(parsed.imageFraction, 0.38);
    expect(parsed.issues, isEmpty);
  });

  test('invalid style directives are preserved instead of reinterpreted', () {
    const String body = '''[PANEL]
PRESET: EDITORIAL
HEADING_SIZE: huge
BODY_SIZE: -2
IMAGE: 70%
[/PANEL]
Copy.''';

    final PresentationPanelContent parsed = parsePresentationPanelContent(
      heading: 'Heading',
      body: body,
    );
    expect(parsed.headingSize, isNull);
    expect(parsed.bodySize, isNull);
    expect(parsed.imageFraction, isNull);
    expect(parsed.preservedDirectives, <String>[
      'HEADING_SIZE: huge',
      'BODY_SIZE: -2',
      'IMAGE: 70%',
    ]);
    expect(parsed.issues, hasLength(3));
  });

}
