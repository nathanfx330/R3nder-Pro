// ./test/documentary_card_content_integration_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_cue.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/presentation_panel_content.dart';

void main() {
  test('CUE CARD keeps opaque PANEL content available to the shared painter', () {
    const String source = '''[EDIT:cut]
  [TRACK:V1]
    [CLIP:a:a.mp4:0:0:120:1]
      [CUE:20]
        [CARD:person.png:90:24,32,40:JOHN SMITH]
          [PANEL]
          PRESET: DOCUMENTARY
          FONT: IBM Plex Sans
          SUBTITLE: Investigative Reporter
          META: ORGANIZATION | Example News
          META: LOCATION | Washington, DC
          [/PANEL]
          Reported on the case for six years.
        [/CARD]
      [/CUE]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

    final EditDocumentModel model = EditDocumentModel.parse(source);
    final EditClip clip = model.edit('cut').tracks.single.clips.single;
    final EditCardCue cue = parseClipCardCues(clip).single;
    final PresentationPanelContent content = parsePresentationPanelContent(
      heading: cue.card.heading,
      body: cue.card.body,
    );

    expect(cue.sourceFrame, 20);
    expect(content.structured, isTrue);
    expect(content.preset, PresentationPanelPreset.documentary);
    expect(content.heading, 'JOHN SMITH');
    expect(content.fontFamily, 'IBM Plex Sans');
    expect(content.subtitle, 'Investigative Reporter');
    expect(content.metadata, hasLength(2));
    expect(content.metadata.first.label, 'ORGANIZATION');
    expect(content.metadata.first.value, 'Example News');
    expect(content.body, 'Reported on the case for six years.');
  });

  test('SIDECARD uses the same documentary content and font contract', () {
    const String source = '''[EDIT:cut]
  [TRACK:V1]
    [CLIP:a:a.mp4:0:0:120:1]
      [CUE:30]
        [SIDECARD:person.png:90:24,32,40:JOHN SMITH]
          [PANEL]
          PRESET: DOCUMENTARY
          FONT: DejaVu Serif
          SUBTITLE: Investigative Reporter
          META: FILE | A-104
          [/PANEL]
          Biography.
        [/SIDECARD]
      [/CUE]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

    final EditDocumentModel model = EditDocumentModel.parse(source);
    final EditClip clip = model.edit('cut').tracks.single.clips.single;
    final EditCardCue cue = parseClipCardCues(clip).single;
    final PresentationPanelContent content = parsePresentationPanelContent(
      heading: cue.card.heading,
      body: cue.card.body,
    );

    expect(cue.isSideCard, isTrue);
    expect(content.preset, PresentationPanelPreset.documentary);
    expect(content.fontFamily, 'DejaVu Serif');
    expect(content.metadata.single.value, 'A-104');
    expect(content.body, 'Biography.');
  });
}
