// ./test/edit_workspace_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_media_import.dart';
import 'package:r3nder/edit_playback_clock.dart';
import 'package:r3nder/edit_surface_model.dart';
import 'package:r3nder/edit_workspace.dart';
import 'package:r3nder/project_clock.dart';
import 'package:r3nder/ui_theme.dart';

class _FakePlaybackClock implements EditPlaybackClock {
  @override
  final RationalFrameRate rate;

  ProjectTime _current = ProjectTime.zero();
  bool running = false;
  int samples = 0;
  int holds = 0;

  _FakePlaybackClock(this.rate);

  @override
  ProjectTime sample() {
    samples++;
    if (running) {
      _current = ProjectTime(
        frame: _current.frame + 1,
        epoch: _current.epoch,
        mode: ProjectClockMode.monotonic,
      );
    }
    return _current;
  }

  @override
  void playFrom(ProjectTime time) {
    running = true;
    _current = time.withMode(ProjectClockMode.monotonic);
  }

  @override
  void holdAt(ProjectTime time) {
    running = false;
    holds++;
    _current = time.withMode(ProjectClockMode.scrub);
  }

  @override
  void dispose() {}
}

void main() {
  testWidgets('ADD VIDEO creates first edit and V1 clip without TEXT authoring',
      (WidgetTester tester) async {
    String latest = 'Hello\n';

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 1000,
          height: 700,
          child: EditWorkspace(
            source: latest,
            currentFrame: 0,
            theme: R3Theme.of(Colors.green),
            onSourceChanged: (String value) => latest = value,
            onSeek: (_) {},
            pickVideo: () async => '/outside/interview.mp4',
            importVideo: (_) => const ImportedEditVideo(
              authoredSource: 'video/interview.mp4',
              resolvedPath: '/workspace/video/interview.mp4',
              clipBaseId: 'interview',
              durationFrames: 90,
            ),
          ),
        ),
      ),
    );

    expect(find.textContaining('NO VIDEO EDIT YET'), findsOneWidget);
    await tester.tap(find.text('ADD VIDEO'));
    await tester.pumpAndSettle();

    final EditSurfaceDocument document = EditSurfaceDocument.parse(latest, 'main');
    expect(document.clip('V1', 'interview').durationFrames, 90);
    expect(find.text('V1'), findsOneWidget);
  });

  testWidgets('ADD OVERLAY creates V2 at current edit playhead',
      (WidgetTester tester) async {
    String latest = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:base:video/base.mp4:0:0:120:1]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 1000,
          height: 700,
          child: EditWorkspace(
            source: latest,
            currentFrame: 36,
            theme: R3Theme.of(Colors.green),
            onSourceChanged: (String value) => latest = value,
            onSeek: (_) {},
            pickVideo: () async => '/outside/title.mov',
            importVideo: (_) => const ImportedEditVideo(
              authoredSource: 'video/title.mov',
              resolvedPath: '/workspace/video/title.mov',
              clipBaseId: 'title',
              durationFrames: 48,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('ADD OVERLAY'));
    await tester.pumpAndSettle();

    final EditSurfaceDocument document = EditSurfaceDocument.parse(latest, 'main');
    expect(document.clip('V2', 'title').atFrame, 36);
    expect(document.clip('V2', 'title').durationFrames, 48);
  });

  testWidgets('PLAY samples ProjectClock and PAUSE holds project time',
      (WidgetTester tester) async {
    const String source = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:base:video/base.mp4:0:0:120:1]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';
    int lastSeek = 0;
    _FakePlaybackClock? fake;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 1000,
          height: 700,
          child: EditWorkspace(
            source: source,
            currentFrame: 0,
            theme: R3Theme.of(Colors.green),
            onSourceChanged: (_) {},
            onSeek: (int frame) => lastSeek = frame,
            playbackClockFactory: (RationalFrameRate rate) {
              fake = _FakePlaybackClock(rate);
              return fake!;
            },
          ),
        ),
      ),
    );

    expect(find.text('PLAY'), findsOneWidget);
    await tester.tap(find.text('PLAY'));
    await tester.pump();
    expect(find.text('PAUSE'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 34));
    expect(fake, isNotNull);
    expect(fake!.samples, greaterThan(0));
    expect(lastSeek, greaterThan(0));

    await tester.tap(find.text('PAUSE'));
    await tester.pump();
    expect(find.text('PLAY'), findsOneWidget);
    expect(fake!.holds, greaterThan(0));
    expect(fake!.running, isFalse);
  });
}
