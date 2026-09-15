// ./test/edit_sidecard_cue_controls_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_card_cue_controls.dart';
import 'package:r3nder/edit_cue.dart';
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

Widget _host({required ValueChanged<CardRequest> onAdd}) {
  final EditSurfaceClip clip =
      EditSurfaceDocument.parse(_source, 'main').clip('V1', 'shot');
  final R3Theme theme = R3Theme.of(const Color(0xFF00FF00));

  return MaterialApp(
    theme: theme.materialTheme(),
    home: Scaffold(
      body: SizedBox(
        width: 900,
        height: 720,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 340,
            child: EditCardCueControls(
              clip: clip,
              cues: const <EditCardCue>[],
              playheadFrame: 113,
              theme: theme,
              imageOptions: () => const <String>['person.png'],
              onAddAtPlayhead: onAdd,
              onChanged: null,
              onDeleted: null,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('add form can author SIDE CARD + VIDEO WINDOW',
      (WidgetTester tester) async {
    CardRequest? added;

    await tester.pumpWidget(
      _host(onAdd: (CardRequest request) => added = request),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('source F90'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('edit-card-cue-add')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('edit-card-cue-style-value')),
      findsOneWidget,
    );
    expect(find.text('FULLSCREEN CARD'), findsWidgets);

    await tester.tap(
      find.byKey(const ValueKey<String>('edit-card-cue-style-menu')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('SIDE CARD + VIDEO WINDOW').last);
    await tester.pumpAndSettle();

    expect(find.text('SIDE CARD + VIDEO WINDOW'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey<String>('edit-card-cue-heading-field')),
      'JOHN SMITH',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('edit-card-cue-body-field')),
      'Biography text.',
    );
    await tester.tap(find.byKey(const ValueKey<String>('edit-card-cue-apply')));
    await tester.pumpAndSettle();

    expect(added, isNotNull);
    expect(added, isA<SideCardRequest>());
    expect(added!.image, 'person.png');
    expect(added!.heading, 'JOHN SMITH');
    expect(added!.body, 'Biography text.');
  });
}
