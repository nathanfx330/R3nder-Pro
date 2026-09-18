// ./test/edit_card_cue_inspector_integration_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_surface.dart';
import 'package:r3nder/ui_theme.dart';

const String _source = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:shot:video/shot.mp4:0:0:300:4/5:GAIN=-15.0]
      [#EDIT_TRANSITION:CROSSFADE:72]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

class _Harness extends StatefulWidget {
  const _Harness({super.key});

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  String source = _source;

  @override
  Widget build(BuildContext context) {
    final R3Theme theme = R3Theme.of(const Color(0xFF00FF00));
    return MaterialApp(
      theme: theme.materialTheme(),
      home: Scaffold(
        body: SizedBox(
          width: 1280,
          height: 720,
          child: EditSurface(
            source: source,
            editId: 'main',
            currentFrame: 113,
            theme: theme,
            onSourceChanged: (String next) {
              setState(() => source = next);
            },
            onSeek: (_) {},
            // Keep the image chooser deterministic and filesystem-free here.
            resolveSource: (String source) => '/definitely/missing/$source',
          ),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('EDIT inspector authors cue at playhead and undo restores source',
      (WidgetTester tester) async {
    final GlobalKey<_HarnessState> key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key));
    await tester.pumpAndSettle();

    await tester.tap(find.text('shot').first);
    await tester.pumpAndSettle();

    final Finder add =
        find.byKey(const ValueKey<String>('edit-card-cue-add'));
    await tester.ensureVisible(add);
    await tester.pumpAndSettle();
    final Finder playhead =
        find.byKey(const ValueKey<String>('edit-card-cue-playhead'));
    expect(playhead, findsOneWidget);
    expect(
      tester.widget<Text>(playhead).data,
      contains('source F90'),
    );

    await tester.tap(add);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('edit-card-cue-image-field')),
      'person.png',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('edit-card-cue-hold-field')),
      '90',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('edit-card-cue-rgb-field')),
      '24,32,40',
    );
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

    expect(key.currentState!.source, contains('[CUE:90]'));
    expect(
      key.currentState!.source,
      contains('[CARD:person.png:90:24,32,40:JOHN SMITH]'),
    );
    expect(key.currentState!.source, contains('Biography text.'));
    expect(key.currentState!.source, contains('GAIN=-15.0'));
    expect(
      key.currentState!.source,
      contains('[#EDIT_TRANSITION:CROSSFADE:72]'),
    );

    final Finder undo = find.byKey(const ValueKey<String>('edit-undo'));
    await tester.ensureVisible(undo);
    await tester.tap(undo);
    await tester.pumpAndSettle();

    expect(key.currentState!.source, _source);
  });
}
