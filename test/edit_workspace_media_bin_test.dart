// ./test/edit_workspace_media_bin_test.dart

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_workspace.dart';
import 'package:r3nder/ui_theme.dart';

void main() {
  testWidgets('Edit workspace exposes project video directory as media bin', (
    WidgetTester tester,
  ) async {
    final Directory temp = Directory.systemTemp.createTempSync(
      'r3nder_edit_bin_',
    );
    try {
      final Directory video = Directory('${temp.path}/video')..createSync();
      File('${video.path}/interview.mp4').writeAsBytesSync(<int>[1, 2, 3]);

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 1200,
            height: 900,
            child: EditWorkspace(
              source: 'Hello\n',
              currentFrame: 0,
              theme: R3Theme.of(Colors.green),
              onSourceChanged: (_) {},
              onSeek: (_) {},
              workspaceRootResolver: () => temp.path,
            ),
          ),
        ),
      );

      expect(find.text('MEDIA BIN'), findsOneWidget);
      expect(find.text('1 FILE'), findsOneWidget);
      expect(find.text('interview.mp4'), findsNothing);
      expect(find.textContaining('NO VIDEO EDIT YET'), findsOneWidget);
    } finally {
      temp.deleteSync(recursive: true);
    }
  });
}
