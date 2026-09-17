// ./test/edit_maximize_cue_controls_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_cue.dart';
import 'package:r3nder/edit_maximize_cue_controls.dart';
import 'package:r3nder/edit_surface_model.dart';
import 'package:r3nder/ui_theme.dart';

const String _source = '''[EDIT:main]
[TRACK:V1]
[CLIP:shot:video/shot.mp4:0:0:300:1]
[CUE:90]
  [MAXIMIZE:60]
[/CUE]
[/CLIP]
[/TRACK]
[/EDIT]
''';

void main() {
  testWidgets('MAXIMIZE controls add edit and delete source-backed hold values',
      (WidgetTester tester) async {
    final EditSurfaceDocument document = EditSurfaceDocument.parse(_source, 'main');
    final EditSurfaceClip clip = document.clip('V1', 'shot');
    final List<EditMaximizeCue> cues = parseClipMaximizeCues(clip.clip);
    final R3Theme theme = R3Theme.of(Colors.green);

    int? added;
    (int, int)? changed;
    int? deleted;

    await tester.pumpWidget(
      MaterialApp(
        theme: theme.materialTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 420,
            height: 620,
            child: EditMaximizeCueControls(
              clip: clip,
              cues: cues,
              playheadFrame: 120,
              theme: theme,
              onAddAtPlayhead: (int hold) => added = hold,
              onChanged: (int index, int hold) => changed = (index, hold),
              onDeleted: (int index) => deleted = index,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Playhead maps to source F120.'), findsOneWidget);
    expect(find.text('HOLD 60F   TOTAL 84F'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('edit-maximize-cue-add')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Add MAXIMIZE cue · source F120'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey<String>('edit-maximize-cue-hold-field')),
      '45',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('edit-maximize-cue-apply')),
    );
    await tester.pumpAndSettle();
    expect(added, 45);

    await tester.tap(
      find.byKey(const ValueKey<String>('edit-maximize-cue-edit-0')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Edit MAXIMIZE cue · source F90'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey<String>('edit-maximize-cue-hold-field')),
      '0',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('edit-maximize-cue-apply')),
    );
    await tester.pumpAndSettle();
    expect(changed, (0, 0));

    await tester.tap(
      find.byKey(const ValueKey<String>('edit-maximize-cue-delete-0')),
    );
    await tester.pump();
    expect(deleted, 0);
  });
}
