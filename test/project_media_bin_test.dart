// ./test/project_media_bin_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/project_media_bin.dart';

void main() {
  test('missing video directory produces an empty bin without creating it', () {
    final Directory temp = Directory.systemTemp.createTempSync('r3nder_bin_');
    try {
      final Directory workspace = Directory('${temp.path}/workspace')
        ..createSync();
      final Directory video = Directory('${workspace.path}/video');

      final List<ProjectMediaItem> items = scanProjectMediaBin(
        workspaceRoot: workspace.path,
      );

      expect(items, isEmpty);
      expect(video.existsSync(), isFalse);
    } finally {
      temp.deleteSync(recursive: true);
    }
  });

  test('scan is nonrecursive, deterministic, and exposes file metadata', () {
    final Directory temp = Directory.systemTemp.createTempSync('r3nder_bin_');
    try {
      final Directory workspace = Directory('${temp.path}/workspace')
        ..createSync();
      final Directory video = Directory('${workspace.path}/video')
        ..createSync();
      final File beta = File('${video.path}/beta.mov')
        ..writeAsBytesSync(<int>[1, 2, 3]);
      final File alpha = File('${video.path}/Alpha.mp4')
        ..writeAsBytesSync(<int>[4, 5]);
      final Directory nested = Directory('${video.path}/nested')..createSync();
      File('${nested.path}/hidden.webm').writeAsBytesSync(<int>[9]);

      final List<ProjectMediaItem> items = scanProjectMediaBin(
        workspaceRoot: workspace.path,
      );

      expect(items.map((ProjectMediaItem item) => item.fileName), <String>[
        'Alpha.mp4',
        'beta.mov',
      ]);
      expect(items.first.authoredSource, 'video/Alpha.mp4');
      expect(items.first.resolvedPath, alpha.absolute.path);
      expect(items.first.sizeBytes, 2);
      expect(items.first.modifiedAt, isA<DateTime>());
      expect(items.first.usability, ProjectMediaUsability.usable);
      expect(items.last.resolvedPath, beta.absolute.path);
      expect(items.last.sizeBytes, 3);
      expect(
        items.any((ProjectMediaItem item) => item.fileName == 'hidden.webm'),
        isFalse,
      );
      expect(() => items.add(items.first), throwsUnsupportedError);
    } finally {
      temp.deleteSync(recursive: true);
    }
  });

  test('unsafe manual names remain visible but cannot be authored', () {
    final Directory temp = Directory.systemTemp.createTempSync('r3nder_bin_');
    try {
      final Directory workspace = Directory('${temp.path}/workspace')
        ..createSync();
      final Directory video = Directory('${workspace.path}/video')
        ..createSync();

      final List<String> unsafeNames = <String>[
        'shot[final].mp4',
        'shot]final.mp4',
      ];
      for (final String name in unsafeNames) {
        File('${video.path}/$name').writeAsBytesSync(<int>[1]);
      }
      File('${video.path}/My Shot.mp4').writeAsBytesSync(<int>[2]);

      final List<ProjectMediaItem> items = scanProjectMediaBin(
        workspaceRoot: workspace.path,
      );
      final Map<String, ProjectMediaItem> byName = <String, ProjectMediaItem>{
        for (final ProjectMediaItem item in items) item.fileName: item,
      };

      for (final String name in unsafeNames) {
        expect(byName[name], isNotNull);
        expect(byName[name]!.usability, ProjectMediaUsability.unusableName);
        expect(byName[name]!.isUsable, isFalse);
        expect(byName[name]!.authoredSource, isNull);
      }

      expect(byName['My Shot.mp4']!.isUsable, isTrue);
      expect(byName['My Shot.mp4']!.authoredSource, 'video/My Shot.mp4');
    } finally {
      temp.deleteSync(recursive: true);
    }
  });

  test('grammar delimiters and control characters are unusable names', () {
    for (final String name in <String>[
      'angle:2.mp4',
      'shot[final].mp4',
      'shot]final.mp4',
      'line\nbreak.mp4',
      'clip\t01.mp4',
    ]) {
      expect(
        classifyProjectMediaFileName(name),
        ProjectMediaUsability.unusableName,
      );
    }
    expect(
      classifyProjectMediaFileName('normal clip.mp4'),
      ProjectMediaUsability.usable,
    );
  });
}
