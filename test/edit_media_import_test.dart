// ./test/edit_media_import_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_media_import.dart';

void main() {
  test('external video is copied into workspace video folder and probed', () {
    final Directory temp = Directory.systemTemp.createTempSync('r3nder_import_');
    try {
      final Directory workspace = Directory('${temp.path}/workspace')..createSync();
      final File external = File('${temp.path}/My Shot.mp4')
        ..writeAsBytesSync(<int>[1, 2, 3, 4]);
      String? probed;

      final ImportedEditVideo imported = importVideoToWorkspace(
        external.path,
        workspaceRoot: workspace.path,
        probeFrames: (String path) {
          probed = path;
          return 87;
        },
      );

      expect(imported.authoredSource, 'video/My Shot.mp4');
      expect(imported.clipBaseId, 'My_Shot');
      expect(imported.durationFrames, 87);
      expect(File(imported.resolvedPath).existsSync(), isTrue);
      expect(File(imported.resolvedPath).readAsBytesSync(), <int>[1, 2, 3, 4]);
      expect(probed, imported.resolvedPath);
    } finally {
      temp.deleteSync(recursive: true);
    }
  });

  test('script delimiter characters are removed from imported filenames', () {
    final Directory temp = Directory.systemTemp.createTempSync('r3nder_import_');
    try {
      final Directory workspace = Directory('${temp.path}/workspace')..createSync();
      final File external = File('${temp.path}/Interview [final]:A.mp4')
        ..writeAsBytesSync(<int>[5, 6, 7]);

      final ImportedEditVideo imported = importVideoToWorkspace(
        external.path,
        workspaceRoot: workspace.path,
        probeFrames: (_) => 61,
      );

      expect(
        imported.authoredSource,
        'video/Interview _final__A.mp4',
      );
      expect(imported.clipBaseId, 'Interview_final_A');
      expect(imported.authoredSource, isNot(contains('[')));
      expect(imported.authoredSource, isNot(contains(']')));
      expect(imported.authoredSource, isNot(contains(':')));
      expect(File(imported.resolvedPath).existsSync(), isTrue);
    } finally {
      temp.deleteSync(recursive: true);
    }
  });

  test('filename collision gets a deterministic suffix', () {
    final Directory temp = Directory.systemTemp.createTempSync('r3nder_import_');
    try {
      final Directory workspace = Directory('${temp.path}/workspace')..createSync();
      final Directory video = Directory('${workspace.path}/video')..createSync();
      File('${video.path}/shot.mp4').writeAsBytesSync(<int>[9]);
      final File external = File('${temp.path}/shot.mp4')
        ..writeAsBytesSync(<int>[1, 2]);

      final ImportedEditVideo imported = importVideoToWorkspace(
        external.path,
        workspaceRoot: workspace.path,
        probeFrames: (_) => 42,
      );

      expect(imported.authoredSource, 'video/shot_2.mp4');
      expect(imported.clipBaseId, 'shot_2');
      expect(File('${video.path}/shot.mp4').readAsBytesSync(), <int>[9]);
      expect(File('${video.path}/shot_2.mp4').readAsBytesSync(), <int>[1, 2]);
    } finally {
      temp.deleteSync(recursive: true);
    }
  });

  test('failed probe removes a newly copied media file', () {
    final Directory temp = Directory.systemTemp.createTempSync('r3nder_import_');
    try {
      final Directory workspace = Directory('${temp.path}/workspace')..createSync();
      final File external = File('${temp.path}/bad.mp4')
        ..writeAsBytesSync(<int>[1, 2, 3]);

      expect(
        () => importVideoToWorkspace(
          external.path,
          workspaceRoot: workspace.path,
          probeFrames: (_) => throw StateError('not media'),
        ),
        throwsStateError,
      );

      expect(File('${workspace.path}/video/bad.mp4').existsSync(), isFalse);
      expect(external.existsSync(), isTrue);
    } finally {
      temp.deleteSync(recursive: true);
    }
  });
}
