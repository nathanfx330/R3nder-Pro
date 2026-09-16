// ./test/edit_dossier_cue_controls_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_cue.dart';
import 'package:r3nder/edit_dossier_cue_controls.dart';
import 'package:r3nder/edit_surface_model.dart';
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
        [DOSSIER:evidence:old.png:30:60:5:SIDE_ONLY:30,30,38:OLD]
          Old body.
        [/DOSSIER]
      [/CUE]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

Widget _host({
  required EditSurfaceClip clip,
  required List<EditDossierCue> cues,
  required int playheadFrame,
  ValueChanged<DossierRequest>? onAdd,
  EditDossierCueChanged? onChanged,
  ValueChanged<int>? onDeleted,
}) {
  final R3Theme theme = R3Theme.of(const Color(0xFF00FF00));
  return MaterialApp(
    theme: theme.materialTheme(),
    home: Scaffold(
      body: SizedBox(
        width: 900,
        height: 760,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 360,
            child: EditDossierCueControls(
              clip: clip,
              cues: cues,
              playheadFrame: playheadFrame,
              theme: theme,
              folderOptions: () => const <String>[
                'evidence',
                'evidence/archive',
              ],
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
  testWidgets('add DOSSIER cue form uses exact source frame and authored facts',
      (WidgetTester tester) async {
    final EditSurfaceClip clip =
        EditSurfaceDocument.parse(_source, 'main').clip('V1', 'shot');
    DossierRequest? added;

    await tester.pumpWidget(
      _host(
        clip: clip,
        cues: const <EditDossierCue>[],
        playheadFrame: 113,
        onAdd: (DossierRequest dossier) => added = dossier,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('source F90'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('edit-dossier-cue-add')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Add DOSSIER cue · source F90'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('edit-dossier-cue-folder-menu')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('evidence/archive').last);
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('edit-dossier-cue-image-menu')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('people/person.png').last);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('edit-dossier-cue-split-field')),
      '45',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('edit-dossier-cue-full-field')),
      '75',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('edit-dossier-cue-lead-field')),
      '12',
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('edit-dossier-cue-mode-menu')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('GRID').last);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('edit-dossier-cue-rgb-field')),
      '24,32,40',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('edit-dossier-cue-heading-field')),
      'JOHN SMITH',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('edit-dossier-cue-body-field')),
      'Biography text.',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('edit-dossier-cue-apply')),
    );
    await tester.pumpAndSettle();

    expect(added, isNotNull);
    expect(added!.folder, 'evidence/archive');
    expect(added!.image, 'people/person.png');
    expect(added!.holdSplit, 45);
    expect(added!.holdFull, 75);
    expect(added!.cardLead, 12);
    expect(added!.centerMode, DossierCenterMode.grid);
    expect(added!.panelColor.toARGB32(), 0xFF182028);
    expect(added!.heading, 'JOHN SMITH');
    expect(added!.body, 'Biography text.');
  });

  testWidgets('existing DOSSIER cue can be edited and deleted',
      (WidgetTester tester) async {
    final EditSurfaceClip clip = EditSurfaceDocument.parse(
      _sourceWithCue,
      'main',
    ).clip('V1', 'shot');
    final List<EditDossierCue> cues = parseClipDossierCues(clip.clip);
    int? changedIndex;
    DossierRequest? changedDossier;
    int? deletedIndex;

    await tester.pumpWidget(
      _host(
        clip: clip,
        cues: cues,
        playheadFrame: 0,
        onChanged: (int index, DossierRequest dossier) {
          changedIndex = index;
          changedDossier = dossier;
        },
        onDeleted: (int index) => deletedIndex = index,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('edit-dossier-cue-row-0')),
      findsOneWidget,
    );
    expect(find.text('evidence'), findsOneWidget);
    expect(find.text('OLD'), findsOneWidget);
    expect(find.textContaining('SIDE ONLY'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('edit-dossier-cue-edit-0')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('edit-dossier-cue-heading-field')),
      'UPDATED',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('edit-dossier-cue-mode-menu')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('MOSAIC').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('edit-dossier-cue-apply')),
    );
    await tester.pumpAndSettle();

    expect(changedIndex, 0);
    expect(changedDossier, isNotNull);
    expect(changedDossier!.heading, 'UPDATED');
    expect(changedDossier!.centerMode, DossierCenterMode.mosaic);

    await tester.tap(
      find.byKey(const ValueKey<String>('edit-dossier-cue-delete-0')),
    );
    await tester.pump();
    expect(deletedIndex, 0);
  });
}
