// ./test/project_media_bin_qol_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/project_media_bin.dart';
import 'package:r3nder/project_media_bin_view.dart';
import 'package:r3nder/project_media_references.dart';
import 'package:r3nder/ui_theme.dart';

void main() {
  final R3Theme theme = R3Theme.of(Colors.green);

  testWidgets('offline authored source becomes online after refresh', (
    WidgetTester tester,
  ) async {
    const String source =
        '''[EDIT:cut]\n  [TRACK:V1]\n    [CLIP:a:video/missing.mp4:0:0:30:1]\n    [/CLIP]\n  [/TRACK]\n[/EDIT]\n''';
    final ProjectMediaReferenceCatalog catalog = projectMediaReferences(
      EditDocumentModel.parse(source),
    );
    int scans = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProjectMediaBinPanel(
            theme: theme,
            projectClockRunning: false,
            initiallyExpanded: true,
            workspaceRootResolver: () => '/workspace',
            scanMedia: ({String? workspaceRoot}) {
              scans++;
              return scans == 1
                  ? const <ProjectMediaItem>[]
                  : <ProjectMediaItem>[_item('missing.mp4')];
            },
            thumbnailLoader: _noThumbnail,
            referenceCatalog: catalog,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('0 FILES · 1 OFFLINE'), findsOneWidget);
    expect(find.text('OFFLINE'), findsOneWidget);
    expect(find.text('video/missing.mp4'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('project-media-bin-refresh')),
    );
    await tester.pumpAndSettle();

    expect(find.text('1 FILE'), findsOneWidget);
    expect(find.text('OFFLINE'), findsNothing);
    expect(find.text('missing.mp4'), findsOneWidget);
    expect(find.text('USED 1'), findsOneWidget);
  });

  testWidgets(
    'reference navigation stays separate from primary media activation',
    (WidgetTester tester) async {
      const String source =
          '''[EDIT:cut]\n  [TRACK:V1]\n    [CLIP:a:video/shot.mp4:0:0:30:1]\n    [/CLIP]\n  [/TRACK]\n[/EDIT]\n''';
      final ProjectMediaReferenceCatalog catalog = projectMediaReferences(
        EditDocumentModel.parse(source),
      );
      int mediaActivations = 0;
      ProjectMediaReference? opened;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProjectMediaBinPanel(
              theme: theme,
              projectClockRunning: false,
              initiallyExpanded: true,
              workspaceRootResolver: () => '/workspace',
              scanMedia: ({String? workspaceRoot}) => <ProjectMediaItem>[
                _item('shot.mp4'),
              ],
              thumbnailLoader: _noThumbnail,
              referenceCatalog: catalog,
              onItemPressed: (_) => mediaActivations++,
              onReferencePressed: (ProjectMediaReference reference) {
                opened = reference;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('shot.mp4'));
      await tester.pump();
      expect(mediaActivations, 1);
      expect(opened, isNull);

      await tester.tap(
        find.byKey(
          const ValueKey<String>(
            'project-media-reference-open:video/shot.mp4:EDIT.cut:a',
          ),
        ),
      );
      await tester.pump();

      expect(mediaActivations, 1);
      expect(opened?.structuralSource, 'EDIT.cut');
      expect(opened?.laneId, 'V1');
      expect(opened?.clipId, 'a');
    },
  );
}

Future<String?> _noThumbnail(
  ProjectMediaItem item, {
  required bool projectClockRunning,
}) async => null;

ProjectMediaItem _item(String fileName) => ProjectMediaItem(
  fileName: fileName,
  resolvedPath: '/workspace/video/$fileName',
  authoredSource: 'video/$fileName',
  sizeBytes: 10,
  modifiedAt: DateTime.fromMicrosecondsSinceEpoch(1),
  usability: ProjectMediaUsability.usable,
);
