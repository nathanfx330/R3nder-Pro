// ./test/edit_workspace_resolver_seam_test.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_workspace.dart';
import 'package:r3nder/exporter.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/ui_theme.dart';

class _ResolverTestBackend implements MediaDecoderBackend {
  @override
  MediaDecoder open(String resolvedPath) => _ResolverTestDecoder();
}

class _ResolverTestDecoder implements MediaDecoder {
  @override
  DecodedMediaFrame render(
    int requestedSourceFrame,
    int width,
    int height,
  ) {
    return DecodedMediaFrame(
      requestedSourceFrame: requestedSourceFrame,
      actualSourceFrame: requestedSourceFrame,
      width: width,
      height: height,
      stride: width * 4,
      rgba: Uint8List(width * height * 4),
    );
  }

  @override
  void dispose() {}
}

void main() {
  testWidgets(
    'structural export receives the same injected media resolver as preview',
    (WidgetTester tester) async {
      final Directory temp = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'r3nder_export_resolver_${pid}_${DateTime.now().microsecondsSinceEpoch}',
      );
      if (temp.existsSync()) temp.deleteSync(recursive: true);
      temp.createSync(recursive: true);

      try {
        String? resolvedByExport;

        const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:base:video/base.mp4:0:0:1:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';

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
                backend: _ResolverTestBackend(),
                resolveSource: (String value) => '/injected/$value',
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
                  String? audioPath,
                  double audioGainDb = 0.0,
                  String? musicPath,
                  double musicGainDb = 0.0,
                  bool musicLoop = false,
                  void Function(int done, int total)? onProgress,
                  void Function(String status)? onStatus,
                  ExportCancelToken? cancelToken,
                }) async {
                  resolvedByExport = resolveSource('video/base.mp4');
                  return ExportResult(
                    success: true,
                    cancelled: false,
                    framesWritten: 1,
                    outputPath: outputPath,
                  );
                },
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.text('EXPORT'), findsOneWidget);
        await tester.tap(find.text('EXPORT'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        final Finder dialog = find.byType(AlertDialog);
        expect(dialog, findsOneWidget);

        await tester.tap(
          find.descendant(of: dialog, matching: find.text('EXPORT')),
        );
        await tester.pump();

        for (int i = 0; i < 20 && resolvedByExport == null; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }

        expect(resolvedByExport, '/injected/video/base.mp4');

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      } finally {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );
}
