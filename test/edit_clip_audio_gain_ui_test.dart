// ./test/edit_clip_audio_gain_ui_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_surface.dart';
import 'package:r3nder/ui_theme.dart';

const String _source = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:intro:video/intro.mp4:10:20:40:1]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

class _GainHarness extends StatefulWidget {
  const _GainHarness({super.key});

  @override
  State<_GainHarness> createState() => _GainHarnessState();
}

class _GainHarnessState extends State<_GainHarness> {
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
            currentFrame: 0,
            theme: theme,
            onSourceChanged: (String next) {
              setState(() => source = next);
            },
            onSeek: (_) {},
          ),
        ),
      ),
    );
  }
}

Future<void> _selectIntro(WidgetTester tester) async {
  await tester.tap(find.text('intro').first);
  await tester.pumpAndSettle();
}

Future<void> _showAudioControl(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('numeric gain and mute serialize canonical CLIP suffixes',
      (WidgetTester tester) async {
    final GlobalKey<_GainHarnessState> key = GlobalKey<_GainHarnessState>();
    await tester.pumpWidget(_GainHarness(key: key));
    await tester.pumpAndSettle();
    await _selectIntro(tester);

    final Finder gainValue =
        find.byKey(const ValueKey<String>('edit-inspector-gain-value'));
    await _showAudioControl(tester, gainValue);
    expect(find.text('0.0 dB'), findsOneWidget);

    await tester.tap(gainValue);
    await tester.pumpAndSettle();
    final Finder field =
        find.byKey(const ValueKey<String>('edit-inspector-gain-field'));
    await tester.enterText(field, '-6.0');
    await tester.tap(find.text('APPLY'));
    await tester.pumpAndSettle();

    expect(key.currentState!.source, contains(':1:GAIN=-6.0]'));

    final Finder mute =
        find.byKey(const ValueKey<String>('edit-inspector-mute'));
    await _showAudioControl(tester, mute);
    await tester.tap(mute);
    await tester.pumpAndSettle();

    expect(key.currentState!.source, contains(':1:GAIN=-6.0:MUTE]'));
    expect(find.text('MUTED'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('edit-undo')));
    await tester.pumpAndSettle();
    expect(key.currentState!.source, contains(':1:GAIN=-6.0]'));
    expect(key.currentState!.source, isNot(contains(':MUTE]')));
  });

  testWidgets('gain reset removes GAIN because zero dB is the implicit default',
      (WidgetTester tester) async {
    final GlobalKey<_GainHarnessState> key = GlobalKey<_GainHarnessState>();
    await tester.pumpWidget(_GainHarness(key: key));
    await tester.pumpAndSettle();
    await _selectIntro(tester);

    final Finder gainValue =
        find.byKey(const ValueKey<String>('edit-inspector-gain-value'));
    await _showAudioControl(tester, gainValue);
    await tester.tap(gainValue);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('edit-inspector-gain-field')),
      '-8.0',
    );
    await tester.tap(find.text('APPLY'));
    await tester.pumpAndSettle();
    expect(key.currentState!.source, contains('GAIN=-8.0'));

    final Finder reset =
        find.byKey(const ValueKey<String>('edit-inspector-gain-reset'));
    await _showAudioControl(tester, reset);
    await tester.tap(reset);
    await tester.pumpAndSettle();

    expect(key.currentState!.source, _source);
  });

  testWidgets('one slider gesture creates one undoable authored edit',
      (WidgetTester tester) async {
    final GlobalKey<_GainHarnessState> key = GlobalKey<_GainHarnessState>();
    await tester.pumpWidget(_GainHarness(key: key));
    await tester.pumpAndSettle();
    await _selectIntro(tester);

    final Finder slider =
        find.byKey(const ValueKey<String>('edit-inspector-gain-slider'));
    await _showAudioControl(tester, slider);
    final Rect rect = tester.getRect(slider);
    final TestGesture gesture = await tester.startGesture(rect.center);
    await gesture.moveTo(Offset(rect.left + rect.width * 0.35, rect.center.dy));
    await gesture.moveTo(Offset(rect.left + rect.width * 0.30, rect.center.dy));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(key.currentState!.source, isNot(_source));
    expect(key.currentState!.source, contains('GAIN='));

    await tester.tap(find.byKey(const ValueKey<String>('edit-undo')));
    await tester.pumpAndSettle();
    expect(key.currentState!.source, _source);
  });
}
