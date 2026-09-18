// ./test/edit_card_cue_controls_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_card_cue_controls.dart';
import 'package:r3nder/edit_cue.dart';
import 'package:r3nder/edit_surface_model.dart';
import 'package:r3nder/presentation_panel_content.dart';
import 'package:r3nder/presentation_requests.dart';
import 'package:r3nder/ui_theme.dart';

const String _source = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:shot:video/shot.mp4:0:0:300:4/5]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

const String _sourceWithCue = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:shot:video/shot.mp4:0:0:300:1]
      [CUE:40]
        [CARD:old.png:30:30,30,38:OLD]
        Old body.
        [/CARD]
      [/CUE]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

const String _sourceWithDocumentaryDefaultKicker = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:shot:video/shot.mp4:0:0:300:1]
      [CUE:40]
        [CARD:old.png:30:30,30,38:OLD]
          [PANEL]
          PRESET: DOCUMENTARY
          SUBTITLE: Reporter
          [/PANEL]
          Biography.
        [/CARD]
      [/CUE]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

const String _sourceWithFuturePanelKey = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:shot:video/shot.mp4:0:0:300:1]
      [CUE:40]
        [CARD:old.png:30:30,30,38:OLD]
          [PANEL]
          PRESET: DOCUMENTARY
          FUTURE_STYLE: archive-2
          SUBTITLE: Reporter
          [/PANEL]
          Biography.
        [/CARD]
      [/CUE]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

const String _sourceWithEditorialGeometry = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:shot:video/shot.mp4:0:0:300:1]
      [CUE:40]
        [SIDECARD:old.png:30:30,30,38:ELK]
          [PANEL]
          PRESET: EDITORIAL
          KICKER: WILDLIFE
          HEADING_SIZE: 36
          BODY_SIZE: 18
          IMAGE: 44%
          [/PANEL]
          Biography.
        [/SIDECARD]
      [/CUE]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

const String _sourceWithSidecardMetadata = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:shot:video/shot.mp4:0:0:300:1]
      [CUE:40]
        [SIDECARD:old.png:30:30,30,38:SUBJECT]
          [PANEL]
          PRESET: DOCUMENTARY
          META: ORGANIZATION | Example News
          META: LOCATION | Washington, DC
          [/PANEL]
          Biography.
        [/SIDECARD]
      [/CUE]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

const String _sourceWithMalformedPanel = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:shot:video/shot.mp4:0:0:300:1]
      [CUE:40]
        [CARD:old.png:30:30,30,38:OLD]
          [PANEL]
          PRESET: DOCUMENTARY
          META: BROKEN ROW
          [/PANEL]
          Biography.
        [/CARD]
      [/CUE]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

Widget _host({
  required EditSurfaceClip clip,
  required List<EditCardCue> cues,
  required int playheadFrame,
  ValueChanged<CardRequest>? onAdd,
  EditCardCueChanged? onChanged,
  ValueChanged<int>? onDeleted,
}) {
  final R3Theme theme = R3Theme.of(const Color(0xFF00FF00));
  return MaterialApp(
    theme: theme.materialTheme(),
    home: Scaffold(
      body: SizedBox(
        width: 800,
        height: 720,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 330,
            child: EditCardCueControls(
              clip: clip,
              cues: cues,
              playheadFrame: playheadFrame,
              theme: theme,
              imageOptions: () => const <String>[
                'portrait.jpg',
                'people/person.png',
              ],
              onAddAtPlayhead: onAdd,
              onChanged: onChanged,
              onDeleted: onDeleted,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('add CARD cue form uses exact source frame and image picker',
      (WidgetTester tester) async {
    final EditSurfaceClip clip =
        EditSurfaceDocument.parse(_source, 'main').clip('V1', 'shot');
    CardRequest? added;

    await tester.pumpWidget(
      _host(
        clip: clip,
        cues: const <EditCardCue>[],
        playheadFrame: 113,
        onAdd: (CardRequest card) => added = card,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('source F90'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('edit-card-cue-add')));
    await tester.pumpAndSettle();

    expect(find.text('Add CARD cue · source F90'), findsOneWidget);

    expect(find.text('CONTENT'), findsOneWidget);
    expect(find.text('TYPE'), findsOneWidget);
    expect(find.text('STYLE'), findsOneWidget);
    expect(find.text('TIMING'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('edit-card-cue-preset-value')),
      findsOneWidget,
    );
    expect(find.text('EDITORIAL'), findsWidgets);

    final Finder imageMenu =
        find.byKey(const ValueKey<String>('edit-card-cue-image-menu'));
    await tester.ensureVisible(imageMenu);
    await tester.pumpAndSettle();
    await tester.tap(imageMenu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('portrait.jpg').last);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('edit-card-cue-hold-field')),
      '120',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('edit-card-cue-rgb-field')),
      '24,32,40',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('edit-card-cue-heading-field')),
      'JOHN SMITH',
    );
    final Finder body =
        find.byKey(const ValueKey<String>('edit-card-cue-body-field'));
    await tester.ensureVisible(body);
    await tester.enterText(body, 'Biography text.');
    await tester.tap(find.byKey(const ValueKey<String>('edit-card-cue-apply')));
    await tester.pumpAndSettle();

    expect(added, isNotNull);
    expect(added!.image, 'portrait.jpg');
    expect(added!.holdFrames, 120);
    expect(added!.panelColor.toARGB32(), 0xFF182028);
    expect(added!.heading, 'JOHN SMITH');
    final PresentationPanelContent addedPanel = parsePresentationPanelContent(
      heading: added!.heading,
      body: added!.body,
    );
    expect(addedPanel.preset, PresentationPanelPreset.editorial);
    expect(addedPanel.body, 'Biography text.');
    expect(addedPanel.headingSize, isNull);
    expect(addedPanel.bodySize, isNull);
    expect(addedPanel.imageFraction, isNull);
  });

  testWidgets('rich CARD GUI authors preset font subtitle metadata and body',
      (WidgetTester tester) async {
    final EditSurfaceClip clip =
        EditSurfaceDocument.parse(_source, 'main').clip('V1', 'shot');
    CardRequest? added;

    await tester.pumpWidget(
      _host(
        clip: clip,
        cues: const <EditCardCue>[],
        playheadFrame: 113,
        onAdd: (CardRequest card) => added = card,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('edit-card-cue-add')));
    await tester.pumpAndSettle();

    final Finder presetMenu =
        find.byKey(const ValueKey<String>('edit-card-cue-preset-menu'));
    await tester.ensureVisible(presetMenu);
    await tester.tap(presetMenu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('DOCUMENTARY').last);
    await tester.pumpAndSettle();

    final Finder font =
        find.byKey(const ValueKey<String>('edit-card-cue-font-field'));
    final Finder subtitle =
        find.byKey(const ValueKey<String>('edit-card-cue-subtitle-field'));
    final Finder metadata =
        find.byKey(const ValueKey<String>('edit-card-cue-metadata-field'));
    final Finder body =
        find.byKey(const ValueKey<String>('edit-card-cue-body-field'));

    await tester.ensureVisible(font);
    await tester.enterText(font, 'IBM Plex Sans');
    await tester.ensureVisible(subtitle);
    await tester.enterText(subtitle, 'Investigative Reporter');
    await tester.ensureVisible(metadata);
    await tester.enterText(
      metadata,
      'ORGANIZATION | Example News\nLOCATION | Washington, DC',
    );
    await tester.ensureVisible(body);
    await tester.enterText(body, 'Biography text.');
    await tester.tap(find.byKey(const ValueKey<String>('edit-card-cue-apply')));
    await tester.pumpAndSettle();

    expect(added, isNotNull);
    final PresentationPanelContent parsed = parsePresentationPanelContent(
      heading: added!.heading,
      body: added!.body,
    );
    expect(parsed.structured, isTrue);
    expect(parsed.preset, PresentationPanelPreset.documentary);
    expect(parsed.fontFamily, 'IBM Plex Sans');
    expect(parsed.subtitle, 'Investigative Reporter');
    expect(
      parsed.metadata,
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
    expect(parsed.body, 'Biography text.');
  });

  testWidgets('default documentary top label is visible but stays implicit',
      (WidgetTester tester) async {
    final EditSurfaceClip clip = EditSurfaceDocument.parse(
      _sourceWithDocumentaryDefaultKicker,
      'main',
    ).clip('V1', 'shot');
    final List<EditCardCue> cues = parseClipCardCues(clip.clip);
    CardRequest? changedCard;

    await tester.pumpWidget(
      _host(
        clip: clip,
        cues: cues,
        playheadFrame: 0,
        onChanged: (int index, CardRequest card) => changedCard = card,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('edit-card-cue-edit-0')));
    await tester.pumpAndSettle();

    final Finder kicker =
        find.byKey(const ValueKey<String>('edit-card-cue-kicker-field'));
    await tester.ensureVisible(kicker);
    final EditableText editable = tester.widget<EditableText>(
      find.descendant(of: kicker, matching: find.byType(EditableText)),
    );
    expect(editable.controller.text, 'PROFILE / DOCUMENTARY');

    await tester.tap(find.byKey(const ValueKey<String>('edit-card-cue-apply')));
    await tester.pumpAndSettle();

    expect(changedCard, isNotNull);
    expect(changedCard!.body, isNot(contains('KICKER:')));
    final PresentationPanelContent parsed = parsePresentationPanelContent(
      heading: changedCard!.heading,
      body: changedCard!.body,
    );
    expect(parsed.kicker, isEmpty);
    expect(
      presentationPanelDefaultKicker(parsed.preset),
      'PROFILE / DOCUMENTARY',
    );
  });

  testWidgets('top photo label can be replaced from the GUI',
      (WidgetTester tester) async {
    final EditSurfaceClip clip = EditSurfaceDocument.parse(
      _sourceWithDocumentaryDefaultKicker,
      'main',
    ).clip('V1', 'shot');
    final List<EditCardCue> cues = parseClipCardCues(clip.clip);
    CardRequest? changedCard;

    await tester.pumpWidget(
      _host(
        clip: clip,
        cues: cues,
        playheadFrame: 0,
        onChanged: (int index, CardRequest card) => changedCard = card,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('edit-card-cue-edit-0')));
    await tester.pumpAndSettle();

    final Finder kicker =
        find.byKey(const ValueKey<String>('edit-card-cue-kicker-field'));
    await tester.ensureVisible(kicker);
    await tester.enterText(kicker, 'INTERVIEW SUBJECT');
    await tester.tap(find.byKey(const ValueKey<String>('edit-card-cue-apply')));
    await tester.pumpAndSettle();

    expect(changedCard, isNotNull);
    expect(changedCard!.body, contains('KICKER: INTERVIEW SUBJECT'));
    final PresentationPanelContent parsed = parsePresentationPanelContent(
      heading: changedCard!.heading,
      body: changedCard!.body,
    );
    expect(parsed.kicker, 'INTERVIEW SUBJECT');
  });

  testWidgets('GUI preserves unknown PANEL directives on edit',
      (WidgetTester tester) async {
    final EditSurfaceClip clip = EditSurfaceDocument.parse(
      _sourceWithFuturePanelKey,
      'main',
    ).clip('V1', 'shot');
    final List<EditCardCue> cues = parseClipCardCues(clip.clip);
    CardRequest? changedCard;

    await tester.pumpWidget(
      _host(
        clip: clip,
        cues: cues,
        playheadFrame: 0,
        onChanged: (int index, CardRequest card) => changedCard = card,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('edit-card-cue-edit-0')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('edit-card-cue-panel-warning')),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('edit-card-cue-heading-field')),
      'UPDATED',
    );
    final Finder apply =
        find.byKey(const ValueKey<String>('edit-card-cue-apply'));
    await tester.ensureVisible(apply);
    await tester.tap(apply);
    await tester.pumpAndSettle();

    expect(changedCard, isNotNull);
    expect(changedCard!.body, contains('FUTURE_STYLE: archive-2'));
    final PresentationPanelContent parsed = parsePresentationPanelContent(
      heading: changedCard!.heading,
      body: changedCard!.body,
    );
    expect(parsed.preservedDirectives, <String>['FUTURE_STYLE: archive-2']);
  });

  testWidgets('malformed PANEL is visible and GUI refuses to rewrite it',
      (WidgetTester tester) async {
    final EditSurfaceClip clip = EditSurfaceDocument.parse(
      _sourceWithMalformedPanel,
      'main',
    ).clip('V1', 'shot');
    final List<EditCardCue> cues = parseClipCardCues(clip.clip);

    await tester.pumpWidget(
      _host(
        clip: clip,
        cues: cues,
        playheadFrame: 0,
        onChanged: (int index, CardRequest card) {},
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('edit-card-cue-edit-0')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('edit-card-cue-panel-error')),
      findsOneWidget,
    );
    final TextButton apply = tester.widget<TextButton>(
      find.byKey(const ValueKey<String>('edit-card-cue-apply')),
    );
    expect(apply.onPressed, isNull);
  });

  testWidgets('existing cue can be edited and deleted from inspector controls',
      (WidgetTester tester) async {
    final EditSurfaceClip clip = EditSurfaceDocument.parse(
      _sourceWithCue,
      'main',
    ).clip('V1', 'shot');
    final List<EditCardCue> cues = parseClipCardCues(clip.clip);
    int? changedIndex;
    CardRequest? changedCard;
    int? deletedIndex;

    await tester.pumpWidget(
      _host(
        clip: clip,
        cues: cues,
        playheadFrame: 0,
        onChanged: (int index, CardRequest card) {
          changedIndex = index;
          changedCard = card;
        },
        onDeleted: (int index) => deletedIndex = index,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('edit-card-cue-row-0')), findsOneWidget);
    expect(find.text('old.png'), findsOneWidget);
    expect(find.text('OLD'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('edit-card-cue-edit-0')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('edit-card-cue-heading-field')),
      'UPDATED',
    );
    await tester.tap(find.byKey(const ValueKey<String>('edit-card-cue-apply')));
    await tester.pumpAndSettle();

    expect(changedIndex, 0);
    expect(changedCard, isNotNull);
    expect(changedCard!.heading, 'UPDATED');
    final PresentationPanelContent legacyPanel = parsePresentationPanelContent(
      heading: changedCard!.heading,
      body: changedCard!.body,
    );
    expect(legacyPanel.preset, PresentationPanelPreset.simple);
    expect(legacyPanel.structured, isFalse);
    expect(legacyPanel.body.trim(), 'Old body.');
    expect(changedCard!.body, isNot(contains('[PANEL]')));

    await tester.tap(
      find.byKey(const ValueKey<String>('edit-card-cue-delete-0')),
    );
    await tester.pump();
    expect(deletedIndex, 0);
  });
  testWidgets('read-only face preview preserves authored PANEL geometry on apply',
      (WidgetTester tester) async {
    final EditSurfaceClip clip = EditSurfaceDocument.parse(
      _sourceWithEditorialGeometry,
      'main',
    ).clip('V1', 'shot');
    final List<EditCardCue> cues = parseClipCardCues(clip.clip);
    CardRequest? changedCard;

    await tester.pumpWidget(
      _host(
        clip: clip,
        cues: cues,
        playheadFrame: 0,
        onChanged: (int index, CardRequest card) => changedCard = card,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('edit-card-cue-edit-0')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('edit-card-cue-preview-slot')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey<String>('presentation-card-face-preview'),
      ),
      findsOneWidget,
    );

    final Finder apply =
        find.byKey(const ValueKey<String>('edit-card-cue-apply'));
    await tester.ensureVisible(apply);
    await tester.tap(apply);
    await tester.pumpAndSettle();

    expect(changedCard, isNotNull);
    final PresentationPanelContent parsed = parsePresentationPanelContent(
      heading: changedCard!.heading,
      body: changedCard!.body,
    );
    expect(parsed.preset, PresentationPanelPreset.editorial);
    expect(parsed.headingSize, 36.0);
    expect(parsed.bodySize, 18.0);
    expect(parsed.imageFraction, 0.44);
    expect(parsed.kicker, 'WILDLIFE');
  });

  testWidgets('Stage 5 controls author explicit type and hero geometry',
      (WidgetTester tester) async {
    final EditSurfaceClip clip =
        EditSurfaceDocument.parse(_source, 'main').clip('V1', 'shot');
    CardRequest? added;

    await tester.pumpWidget(
      _host(
        clip: clip,
        cues: const <EditCardCue>[],
        playheadFrame: 113,
        onAdd: (CardRequest card) => added = card,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('edit-card-cue-add')));
    await tester.pumpAndSettle();

    final Finder headingSize = find.byKey(
      const ValueKey<String>('edit-card-cue-heading-size-field'),
    );
    final Finder bodySize = find.byKey(
      const ValueKey<String>('edit-card-cue-body-size-field'),
    );
    final Finder imagePercent = find.byKey(
      const ValueKey<String>('edit-card-cue-image-percent-field'),
    );
    final Finder font =
        find.byKey(const ValueKey<String>('edit-card-cue-font-field'));

    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: headingSize,
              matching: find.byType(EditableText),
            ),
          )
          .controller
          .text,
      '32',
    );
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: bodySize,
              matching: find.byType(EditableText),
            ),
          )
          .controller
          .text,
      '17',
    );
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: imagePercent,
              matching: find.byType(EditableText),
            ),
          )
          .controller
          .text,
      '38',
    );

    await tester.ensureVisible(font);
    await tester.enterText(font, 'DejaVu Serif');
    await tester.ensureVisible(headingSize);
    await tester.enterText(headingSize, '36');
    await tester.enterText(bodySize, '18');
    await tester.enterText(imagePercent, '70');

    final Finder apply =
        find.byKey(const ValueKey<String>('edit-card-cue-apply'));
    await tester.ensureVisible(apply);
    await tester.tap(apply);
    await tester.pumpAndSettle();

    expect(added, isNotNull);
    final PresentationPanelContent parsed = parsePresentationPanelContent(
      heading: added!.heading,
      body: added!.body,
    );
    expect(parsed.preset, PresentationPanelPreset.editorial);
    expect(parsed.fontFamily, 'DejaVu Serif');
    expect(parsed.headingSize, 36.0);
    expect(parsed.bodySize, 18.0);
    expect(parsed.imageFraction, 0.70);
  });

  testWidgets('SIDECARD hides META controls but preserves authored META',
      (WidgetTester tester) async {
    final EditSurfaceClip clip = EditSurfaceDocument.parse(
      _sourceWithSidecardMetadata,
      'main',
    ).clip('V1', 'shot');
    final List<EditCardCue> cues = parseClipCardCues(clip.clip);
    CardRequest? changedCard;

    await tester.pumpWidget(
      _host(
        clip: clip,
        cues: cues,
        playheadFrame: 0,
        onChanged: (int index, CardRequest card) => changedCard = card,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('edit-card-cue-edit-0')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('edit-card-cue-style-value')),
      findsOneWidget,
    );
    expect(find.text('SIDE CARD + VIDEO WINDOW'), findsWidgets);
    expect(
      find.byKey(const ValueKey<String>('edit-card-cue-metadata-field')),
      findsNothing,
    );

    final Finder apply =
        find.byKey(const ValueKey<String>('edit-card-cue-apply'));
    await tester.ensureVisible(apply);
    await tester.tap(apply);
    await tester.pumpAndSettle();

    expect(changedCard, isNotNull);
    final PresentationPanelContent parsed = parsePresentationPanelContent(
      heading: changedCard!.heading,
      body: changedCard!.body,
    );
    expect(
      parsed.metadata,
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
  });


}
