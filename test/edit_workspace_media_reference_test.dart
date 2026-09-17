// ./test/edit_workspace_media_reference_test.dart

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_workspace.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/project_media_bin.dart';
import 'package:r3nder/ui_theme.dart';

class _PreviewBackend implements MediaDecoderBackend {
  @override
  MediaDecoder open(String resolvedPath) => _PreviewDecoder();
}

class _PreviewDecoder implements MediaDecoder {
  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    final Uint8List rgba = Uint8List(width * height * 4);
    for (int i = 3; i < rgba.length; i += 4) {
      rgba[i] = 255;
    }
    return DecodedMediaFrame(
      requestedSourceFrame: requestedSourceFrame,
      actualSourceFrame: requestedSourceFrame,
      width: width,
      height: height,
      stride: width * 4,
      rgba: rgba,
    );
  }

  @override
  void dispose() {}
}

void main() {
  testWidgets('media reference OPEN selects its authored EDIT without mutation', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const String source =
        '''[EDIT:first]\n[/EDIT]\n[EDIT:target]\n  [TRACK:V1]\n    [CLIP:shot:video/shot.mp4:0:0:30:1]\n    [/CLIP]\n  [/TRACK]\n[/EDIT]\n''';
    final ProjectMediaItem item = ProjectMediaItem(
      fileName: 'shot.mp4',
      resolvedPath: '/workspace/video/shot.mp4',
      authoredSource: 'video/shot.mp4',
      sizeBytes: 10,
      modifiedAt: DateTime.fromMicrosecondsSinceEpoch(1),
      usability: ProjectMediaUsability.usable,
    );
    int sourceMutations = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditWorkspace(
            source: source,
            currentFrame: 0,
            theme: R3Theme.of(Colors.green),
            onSourceChanged: (_) => sourceMutations++,
            onSeek: (_) {},
            workspaceRootResolver: () => '/workspace',
            scanProjectMedia: ({String? workspaceRoot}) => <ProjectMediaItem>[
              item,
            ],
            loadProjectMediaThumbnail:
                (
                  ProjectMediaItem item, {
                  required bool projectClockRunning,
                }) async => null,
            backend: _PreviewBackend(),
            resolveSource: (String source) => '/workspace/$source',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('edit:first')), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('project-media-bin-toggle')),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(
        const ValueKey<String>(
          'project-media-reference-open:video/shot.mp4:EDIT.target:shot',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('edit:target')), findsOneWidget);
    expect(sourceMutations, 0);
  });
}
