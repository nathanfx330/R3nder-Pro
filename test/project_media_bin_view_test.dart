// ./test/project_media_bin_view_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/project_media_bin.dart';
import 'package:r3nder/project_media_bin_view.dart';
import 'package:r3nder/ui_theme.dart';

void main() {
  final R3Theme theme = R3Theme.of(Colors.green);

  testWidgets(
    'bin is collapsed by default and requests thumbnails only when opened',
    (WidgetTester tester) async {
      int thumbnailRequests = 0;
      final List<ProjectMediaItem> items = <ProjectMediaItem>[
        _item('alpha.mp4'),
        _item('beta.mov'),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProjectMediaBinPanel(
              theme: theme,
              projectClockRunning: false,
              workspaceRootResolver: () => '/workspace',
              scanMedia: ({String? workspaceRoot}) {
                expect(workspaceRoot, '/workspace');
                return items;
              },
              thumbnailLoader:
                  (
                    ProjectMediaItem item, {
                    required bool projectClockRunning,
                  }) async {
                    thumbnailRequests++;
                    expect(projectClockRunning, isFalse);
                    return null;
                  },
            ),
          ),
        ),
      );

      expect(find.text('MEDIA BIN'), findsOneWidget);
      expect(find.text('2 FILES'), findsOneWidget);
      expect(find.text('alpha.mp4'), findsNothing);
      expect(thumbnailRequests, 0);

      await tester.tap(
        find.byKey(const ValueKey<String>('project-media-bin-toggle')),
      );
      await tester.pumpAndSettle();

      expect(find.text('alpha.mp4'), findsOneWidget);
      expect(find.text('beta.mov'), findsOneWidget);
      expect(thumbnailRequests, 2);
    },
  );

  testWidgets('refresh rescans derived video directory state', (
    WidgetTester tester,
  ) async {
    int scans = 0;
    final String Function() rootResolver = () => '/workspace';
    final ProjectMediaBinScanner scanner = ({String? workspaceRoot}) {
      scans++;
      return scans == 1
          ? <ProjectMediaItem>[_item('first.mp4')]
          : <ProjectMediaItem>[_item('first.mp4'), _item('second.mp4')];
    };

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProjectMediaBinPanel(
            theme: theme,
            projectClockRunning: false,
            workspaceRootResolver: rootResolver,
            scanMedia: scanner,
            thumbnailLoader: _noThumbnail,
          ),
        ),
      ),
    );

    expect(find.text('1 FILE'), findsOneWidget);
    expect(scans, 1);

    await tester.tap(
      find.byKey(const ValueKey<String>('project-media-bin-refresh')),
    );
    await tester.pump();

    expect(find.text('2 FILES'), findsOneWidget);
    expect(scans, 2);
  });

  testWidgets('thumbnail request retries when playback stops', (
    WidgetTester tester,
  ) async {
    final List<bool> runningFlags = <bool>[];
    final String Function() rootResolver = () => '/workspace';
    final ProjectMediaBinScanner scanner = ({String? workspaceRoot}) =>
        <ProjectMediaItem>[_item('shot.mp4')];
    final ProjectMediaThumbnailLoader loader =
        (ProjectMediaItem item, {required bool projectClockRunning}) async {
          runningFlags.add(projectClockRunning);
          return null;
        };

    Widget build(bool running) => MaterialApp(
      home: Scaffold(
        body: ProjectMediaBinPanel(
          theme: theme,
          projectClockRunning: running,
          initiallyExpanded: true,
          workspaceRootResolver: rootResolver,
          scanMedia: scanner,
          thumbnailLoader: loader,
        ),
      ),
    );

    await tester.pumpWidget(build(true));
    await tester.pumpAndSettle();
    expect(runningFlags, <bool>[true]);

    await tester.pumpWidget(build(false));
    await tester.pumpAndSettle();
    expect(runningFlags, <bool>[true, false]);
  });

  testWidgets('unusable media remains visible and cannot activate', (
    WidgetTester tester,
  ) async {
    int activations = 0;
    final ProjectMediaItem unsafe = ProjectMediaItem(
      fileName: 'bad[name].mp4',
      resolvedPath: '/workspace/video/bad[name].mp4',
      authoredSource: null,
      sizeBytes: 1,
      modifiedAt: DateTime.fromMicrosecondsSinceEpoch(1),
      usability: ProjectMediaUsability.unusableName,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProjectMediaBinPanel(
            theme: theme,
            projectClockRunning: false,
            initiallyExpanded: true,
            workspaceRootResolver: () => '/workspace',
            scanMedia: ({String? workspaceRoot}) => <ProjectMediaItem>[unsafe],
            thumbnailLoader: _noThumbnail,
            onItemPressed: (_) => activations++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('bad[name].mp4'), findsOneWidget);
    expect(find.text('UNUSABLE NAME'), findsOneWidget);

    await tester.tap(find.text('bad[name].mp4'));
    await tester.pump();
    expect(activations, 0);
  });

  testWidgets('scan failure is surfaced without throwing out of build', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProjectMediaBinPanel(
            theme: theme,
            projectClockRunning: false,
            initiallyExpanded: true,
            workspaceRootResolver: () => throw StateError('no workspace'),
          ),
        ),
      ),
    );

    expect(find.text('UNAVAILABLE'), findsOneWidget);
    expect(find.text('PROJECT MEDIA UNAVAILABLE'), findsOneWidget);
  });
}

Future<String?> _noThumbnail(
  ProjectMediaItem item, {
  required bool projectClockRunning,
}) async {
  return null;
}

ProjectMediaItem _item(String fileName) {
  return ProjectMediaItem(
    fileName: fileName,
    resolvedPath: '/workspace/video/$fileName',
    authoredSource: 'video/$fileName',
    sizeBytes: 10,
    modifiedAt: DateTime.fromMicrosecondsSinceEpoch(1),
    usability: ProjectMediaUsability.usable,
  );
}
