// ./test/edit_workspace_test.dart

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_linter.dart';
import 'package:r3nder/edit_media_import.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/edit_playback_clock.dart';
import 'package:r3nder/edit_surface_model.dart';
import 'package:r3nder/edit_workspace.dart';
import 'package:r3nder/exporter.dart';
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

  testWidgets('ADD VIDEO authors source rate conform speed into CLIP',
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
            pickVideo: () async => '/outside/spring.webm',
            importVideo: (_) => const ImportedEditVideo(
              authoredSource: 'video/spring.webm',
              resolvedPath: '/workspace/video/spring.webm',
              clipBaseId: 'spring',
              durationFrames: 13925,
              speedNumerator: 4,
              speedDenominator: 5,
              sourceFpsNumerator: 24,
              sourceFpsDenominator: 1,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('ADD VIDEO'));
    await tester.pumpAndSettle();

    final EditSurfaceDocument document = EditSurfaceDocument.parse(latest, 'main');
    final clip = document.clip('V1', 'spring');
    expect(clip.durationFrames, 13925);
    expect(clip.speed.numerator, 4);
    expect(clip.speed.denominator, 5);
    expect(clip.clip.sourceFrameAtProjectOffset(30), 24);
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

  testWidgets(
      'PLAY samples ProjectClock on Flutter frames and PAUSE publishes parked frame',
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

    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 17));
    }
    expect(fake, isNotNull);
    expect(fake!.samples, greaterThanOrEqualTo(3));
    expect(find.textContaining('EDIT main   F'), findsOneWidget);
    expect(lastSeek, 0);

    await tester.tap(find.text('PAUSE'));
    await tester.pump();
    expect(find.text('PLAY'), findsOneWidget);
    expect(fake!.holds, greaterThan(0));
    expect(fake!.running, isFalse);
    expect(lastSeek, greaterThan(0));
  });

  testWidgets('GUI can build MOSAIC from EDIT then use MOSAIC as EDIT CLIP source',
      (WidgetTester tester) async {
    String latest = '''[EDIT:main]
[TRACK:V1]
[CLIP:base:video/base.mp4:0:0:60:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 1100,
          height: 760,
          child: EditWorkspace(
            source: latest,
            currentFrame: 0,
            theme: R3Theme.of(Colors.green),
            onSourceChanged: (String value) => latest = value,
            onSeek: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('NEW MOSAIC'));
    await tester.pumpAndSettle();

    EditDocumentModel model = EditDocumentModel.parse(latest);
    expect(model.mosaics, hasLength(1));
    expect(model.mosaic('mosaic').pane('pane').clip('source').source, 'EDIT.main');
    expect(find.textContaining('MOSAIC mosaic'), findsWidgets);
    expect(find.textContaining('PANE pane'), findsOneWidget);

    await tester.tap(find.text('NEW EDIT'));
    await tester.pumpAndSettle();

    model = EditDocumentModel.parse(latest);
    expect(model.edits.map((EditSequence edit) => edit.id), <String>['main', 'edit']);
    expect(find.textContaining('EDIT edit   F'), findsOneWidget);

    await tester.tap(find.text('ADD SOURCE'));
    await tester.pumpAndSettle();

    final Finder dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    final Finder picker = find.descendant(
      of: dialog,
      matching: find.byType(DropdownButton<String>),
    );
    expect(picker, findsOneWidget);
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(find.text('MOSAIC.mosaic').last);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: dialog, matching: find.text('ADD')));
    await tester.pumpAndSettle();

    model = EditDocumentModel.parse(latest);
    final EditClip nested = model.edit('edit').track('V1').clips.single;
    expect(nested.source, 'MOSAIC.mosaic');
    expect(nested.durationFrames, 60);
    expect(EditGraphLinter.lint(model).isValid, isTrue);
  });

  testWidgets(
    'EXPORT sends selected MOSAIC root to structural exporter',
    (WidgetTester tester) async {
      // Widget tests run in Flutter's fake async zone. Real asynchronous file
      // system futures can wait forever there unless routed through runAsync.
      // This test only needs a writable path, so create and remove it
      // synchronously instead of introducing unrelated real async work.
      final Directory temp = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'r3nder_edit_workspace_export_${pid}_${DateTime.now().microsecondsSinceEpoch}',
      );
      if (temp.existsSync()) temp.deleteSync(recursive: true);
      temp.createSync(recursive: true);

      try {
        const String source = '''[MOSAIC:wall]
[PANE:pane]
[CLIP:source:video/base.mp4:0:0:30:1]
[/CLIP]
[/PANE]
[/MOSAIC]
''';

        String? exportedSource;
        String? exportedPath;
        VideoExportFormat? exportedFormat;
        int? exportedWidth;
        int? exportedHeight;
        int? exportedFps;

        await tester.pumpWidget(
          MaterialApp(
            home: SizedBox(
              width: 1200,
              height: 760,
              child: EditWorkspace(
                source: source,
                currentFrame: 0,
                theme: R3Theme.of(Colors.green),
                onSourceChanged: (_) {},
                onSeek: (_) {},
                workspaceRootResolver: () => temp.path,
                exportSource: ({
                  required String source,
                  required String structuralSource,
                  required String outputPath,
                  required VideoExportFormat format,
                  required int fps,
                  required int width,
                  required int height,
                  required String Function(String source) resolveSource,
                  void Function(int done, int total)? onProgress,
                  void Function(String status)? onStatus,
                  ExportCancelToken? cancelToken,
                }) async {
                  exportedSource = structuralSource;
                  exportedPath = outputPath;
                  exportedFormat = format;
                  exportedWidth = width;
                  exportedHeight = height;
                  exportedFps = fps;
                  onStatus?.call('Rendering Structural Source...');
                  onProgress?.call(30, 30);
                  return ExportResult(
                    success: true,
                    cancelled: false,
                    framesWritten: 30,
                    outputPath: outputPath,
                  );
                },
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.textContaining('MOSAIC wall'), findsWidgets);
        expect(find.text('EXPORT'), findsOneWidget);

        await tester.tap(find.text('EXPORT'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        final Finder dialog = find.byType(AlertDialog);
        expect(dialog, findsOneWidget);
        expect(
          find.byKey(const ValueKey<String>('structural-export-resolution')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey<String>('structural-export-format')),
          findsOneWidget,
        );

        await tester.tap(
          find.descendant(of: dialog, matching: find.text('EXPORT')),
        );
        await tester.pump();

        for (int i = 0; i < 20 && exportedSource == null; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(exportedSource, 'MOSAIC.wall');

        for (int i = 0;
            i < 20 &&
                find
                    .byKey(const ValueKey<String>('structural-export-status'))
                    .evaluate()
                    .isEmpty;
            i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }

        expect(exportedFormat, VideoExportFormat.h264Solid);
        expect(exportedWidth, 1920);
        expect(exportedHeight, 1080);
        expect(exportedFps, 30);
        expect(
          exportedPath,
          '${temp.path}${Platform.pathSeparator}output_frames'
          '${Platform.pathSeparator}mosaic_wall_1080p.mp4',
        );
        expect(
          find.byKey(const ValueKey<String>('structural-export-status')),
          findsOneWidget,
        );
        expect(find.textContaining('EXPORTED'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      } finally {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );
}
