// ./test/editor_node_workspace_media_attach_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_media_import.dart';
import 'package:r3nder/editor_node_workspace.dart';
import 'package:r3nder/project_media_bin.dart';
import 'package:r3nder/ui_theme.dart';

void main() {
  testWidgets(
    'TEXT media bin attaches video and opens created STRUCT settings',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final ProjectMediaItem item = ProjectMediaItem(
        fileName: 'interview.mp4',
        resolvedPath: '/workspace/video/interview.mp4',
        authoredSource: 'video/interview.mp4',
        sizeBytes: 1234,
        modifiedAt: DateTime.fromMillisecondsSinceEpoch(1000),
        usability: ProjectMediaUsability.usable,
      );
      const ImportedEditVideo media = ImportedEditVideo(
        authoredSource: 'video/interview.mp4',
        resolvedPath: '/workspace/video/interview.mp4',
        clipBaseId: 'interview',
        durationFrames: 60,
        sourceLengthFrames: 60,
      );

      String? changed;
      final R3Theme theme = R3Theme.of(const Color(0xFF00FF00));
      await tester.pumpWidget(
        MaterialApp(
          theme: theme.materialTheme(),
          home: Scaffold(
            body: EditorNodeWorkspace(
              initialText: 'Narration text\n',
              theme: theme,
              highlightedLine: -1,
              imagesDir: '/workspace/images',
              spritesDir: '/workspace/sprites',
              initialSelectedNodeIndex: 0,
              scanProjectMedia: ({String? workspaceRoot}) {
                expect(workspaceRoot, '/workspace');
                return <ProjectMediaItem>[item];
              },
              loadProjectMediaThumbnail:
                  (
                    ProjectMediaItem item, {
                    required bool projectClockRunning,
                  }) async {
                    expect(projectClockRunning, isFalse);
                    return null;
                  },
              conformProjectMedia: (String resolvedPath) {
                expect(resolvedPath, item.resolvedPath);
                return media;
              },
              onTextChanged: (String value) => changed = value,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('TEXT SETTINGS'), findsOneWidget);
      expect(find.text('MEDIA BIN'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('project-media-bin-toggle')),
      );
      await tester.pumpAndSettle();
      expect(find.text('interview.mp4'), findsOneWidget);

      await tester.tap(find.text('interview.mp4'));
      await tester.pumpAndSettle();

      expect(changed, isNotNull);
      expect(changed, startsWith('Narration text\n[STRUCT:EDIT.interview]\n'));
      expect(changed, contains('[EDIT:interview]\n'));
      expect(
        changed,
        contains('[CLIP:interview:video/interview.mp4:0:0:60:1]'),
      );
      expect(find.text('STRUCT SETTINGS'), findsOneWidget);
      expect(find.text('EDIT.interview'), findsOneWidget);
    },
  );
}
