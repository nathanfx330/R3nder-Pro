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

    await tester.tap(
      find.byKey(const ValueKey<String>('edit-card-cue-image-menu')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('people/person.png').last);
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
    expect(added!.image, 'people/person.png');
    expect(added!.holdFrames, 120);
    expect(added!.panelColor.toARGB32(), 0xFF182028);
    expect(added!.heading, 'JOHN SMITH');
    expect(added!.body, 'Biography text.');
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

    await tester.tap(
      find.byKey(const ValueKey<String>('edit-card-cue-delete-0')),
    );
    await tester.pump();
    expect(deletedIndex, 0);
  });
}
