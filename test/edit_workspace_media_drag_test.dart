// ./test/edit_workspace_media_drag_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_media_import.dart';
import 'package:r3nder/edit_surface_model.dart';
import 'package:r3nder/edit_workspace.dart';
import 'package:r3nder/project_media_bin.dart';
import 'package:r3nder/project_media_bin_view.dart';
import 'package:r3nder/ui_theme.dart';

void main() {
  testWidgets('dragging project media onto V1 authors at the drop coordinate', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    String latest = '''[EDIT:main]
[/EDIT]
''';
    final ProjectMediaItem item = ProjectMediaItem(
      fileName: 'shot.mp4',
      resolvedPath: '/workspace/video/shot.mp4',
      authoredSource: 'video/shot.mp4',
      sizeBytes: 100,
      modifiedAt: DateTime.fromMicrosecondsSinceEpoch(1),
      usability: ProjectMediaUsability.usable,
    );
    final ProjectMediaBinScanner scanner = ({String? workspaceRoot}) {
      expect(workspaceRoot, '/workspace');
      return <ProjectMediaItem>[item];
    };
    final ProjectMediaThumbnailLoader thumbnailLoader =
        (ProjectMediaItem item, {required bool projectClockRunning}) async {
          return null;
        };

    final R3Theme theme = R3Theme.of(Colors.green);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme.materialTheme(),
        home: Scaffold(
          body: EditWorkspace(
            source: latest,
            currentFrame: 0,
            theme: theme,
            onSourceChanged: (String source) => latest = source,
            onSeek: (_) {},
            workspaceRootResolver: () => '/workspace',
            scanProjectMedia: scanner,
            loadProjectMediaThumbnail: thumbnailLoader,
            conformProjectMedia: (String resolvedPath) {
              expect(resolvedPath, item.resolvedPath);
              return const ImportedEditVideo(
                authoredSource: 'video/shot.mp4',
                resolvedPath: '/workspace/video/shot.mp4',
                clipBaseId: 'shot',
                durationFrames: 30,
                sourceLengthFrames: 30,
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('edit-media-drop-V1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('edit-media-drop-V2')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('project-media-bin-toggle')),
    );
    await tester.pumpAndSettle();

    final Finder tile = find.byKey(
      const ValueKey<String>('project-media:/workspace/video/shot.mp4'),
    );
    final Finder target = find.byKey(
      const ValueKey<String>('edit-media-drop-V1'),
    );
    expect(tile, findsOneWidget);
    expect(target, findsOneWidget);

    final Rect targetRect = tester.getRect(target);
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(tile),
    );
    await gesture.moveBy(const Offset(8, 0));
    await tester.pump();
    await gesture.moveTo(Offset(targetRect.left + 120, targetRect.center.dy));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('edit-media-drop-preview-V1')),
      findsOneWidget,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    final EditSurfaceDocument document = EditSurfaceDocument.parse(
      latest,
      'main',
    );
    final clip = document.clip('V1', 'shot');
    expect(clip.atFrame, 60);
    expect(clip.durationFrames, 30);
    expect(clip.source, 'video/shot.mp4');
  });
}
