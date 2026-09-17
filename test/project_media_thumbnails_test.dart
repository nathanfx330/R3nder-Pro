// ./test/project_media_thumbnails_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/project_media_bin.dart';
import 'package:r3nder/project_media_thumbnails.dart';

void main() {
  test('cache key changes with path size or modification time', () {
    final ProjectMediaItem base = _item(
      path: '/workspace/video/a.mp4',
      size: 10,
      modifiedMicros: 100,
    );

    final String key = projectMediaThumbnailCacheKey(base);
    expect(key, hasLength(16));
    expect(
      projectMediaThumbnailCacheKey(
        _item(path: '/workspace/video/b.mp4', size: 10, modifiedMicros: 100),
      ),
      isNot(key),
    );
    expect(
      projectMediaThumbnailCacheKey(
        _item(path: '/workspace/video/a.mp4', size: 11, modifiedMicros: 100),
      ),
      isNot(key),
    );
    expect(
      projectMediaThumbnailCacheKey(
        _item(path: '/workspace/video/a.mp4', size: 10, modifiedMicros: 101),
      ),
      isNot(key),
    );
  });

  test(
    'uncached thumbnail never launches ffmpeg while clock is running',
    () async {
      final Directory temp = Directory.systemTemp.createTempSync(
        'r3nder_thumb_',
      );
      try {
        final Directory workspace = Directory('${temp.path}/workspace')
          ..createSync();
        final Directory video = Directory('${workspace.path}/video')
          ..createSync();
        File('${video.path}/shot.mp4').writeAsBytesSync(<int>[1, 2, 3]);
        final ProjectMediaItem item = scanProjectMediaBin(
          workspaceRoot: workspace.path,
        ).single;
        int launches = 0;

        final ProjectMediaThumbnailService service =
            ProjectMediaThumbnailService(
              workspaceRoot: workspace.path,
              runProcess: (String executable, List<String> arguments) async {
                launches++;
                throw StateError('ffmpeg must not launch');
              },
            );

        final String? thumbnail = await service.thumbnailFor(
          item,
          projectClockRunning: true,
        );

        expect(thumbnail, isNull);
        expect(launches, 0);
        expect(Directory('${workspace.path}/.cache').existsSync(), isFalse);
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
  );

  test(
    'stopped clock generates once and cached thumbnail is reusable in play',
    () async {
      final Directory temp = Directory.systemTemp.createTempSync(
        'r3nder_thumb_',
      );
      try {
        final Directory workspace = Directory('${temp.path}/workspace')
          ..createSync();
        final Directory video = Directory('${workspace.path}/video')
          ..createSync();
        final File media = File('${video.path}/shot.mp4')
          ..writeAsBytesSync(<int>[1, 2, 3, 4]);
        final ProjectMediaItem item = scanProjectMediaBin(
          workspaceRoot: workspace.path,
        ).single;
        int launches = 0;
        List<String>? launchedArguments;

        final ProjectMediaThumbnailService service =
            ProjectMediaThumbnailService(
              workspaceRoot: workspace.path,
              runProcess: (String executable, List<String> arguments) async {
                launches++;
                launchedArguments = List<String>.from(arguments);
                expect(executable, 'ffmpeg');
                File(arguments.last).writeAsBytesSync(<int>[0xff, 0xd8, 0xff]);
                return ProcessResult(1, 0, '', '');
              },
            );

        final String? generated = await service.thumbnailFor(
          item,
          projectClockRunning: false,
        );
        expect(generated, service.thumbnailPathFor(item));
        expect(File(generated!).readAsBytesSync(), <int>[0xff, 0xd8, 0xff]);
        expect(launches, 1);
        expect(launchedArguments, contains(media.absolute.path));
        expect(
          launchedArguments,
          contains('scale=320:-2:force_original_aspect_ratio=decrease'),
        );

        final String? cached = await service.thumbnailFor(
          item,
          projectClockRunning: true,
        );
        expect(cached, generated);
        expect(launches, 1);
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
  );

  test('failed ffmpeg leaves no final or temporary thumbnail', () async {
    final Directory temp = Directory.systemTemp.createTempSync('r3nder_thumb_');
    try {
      final Directory workspace = Directory('${temp.path}/workspace')
        ..createSync();
      final Directory video = Directory('${workspace.path}/video')
        ..createSync();
      File('${video.path}/bad.mp4').writeAsBytesSync(<int>[1]);
      final ProjectMediaItem item = scanProjectMediaBin(
        workspaceRoot: workspace.path,
      ).single;

      final ProjectMediaThumbnailService service = ProjectMediaThumbnailService(
        workspaceRoot: workspace.path,
        runProcess: (String executable, List<String> arguments) async {
          File(arguments.last).writeAsBytesSync(<int>[9]);
          return ProcessResult(2, 1, '', 'decode failed');
        },
      );

      final String finalPath = service.thumbnailPathFor(item);
      final String? generated = await service.thumbnailFor(
        item,
        projectClockRunning: false,
      );

      expect(generated, isNull);
      expect(File(finalPath).existsSync(), isFalse);
      expect(File('$finalPath.tmp.jpg').existsSync(), isFalse);
    } finally {
      temp.deleteSync(recursive: true);
    }
  });

  test('stale media item does not launch ffmpeg', () async {
    final Directory temp = Directory.systemTemp.createTempSync('r3nder_thumb_');
    try {
      final Directory workspace = Directory('${temp.path}/workspace')
        ..createSync();
      int launches = 0;
      final ProjectMediaItem item = _item(
        path: '${workspace.path}/video/missing.mp4',
        size: 4,
        modifiedMicros: 10,
      );
      final ProjectMediaThumbnailService service = ProjectMediaThumbnailService(
        workspaceRoot: workspace.path,
        runProcess: (String executable, List<String> arguments) async {
          launches++;
          return ProcessResult(3, 0, '', '');
        },
      );

      expect(
        await service.thumbnailFor(item, projectClockRunning: false),
        isNull,
      );
      expect(launches, 0);
    } finally {
      temp.deleteSync(recursive: true);
    }
  });
}

ProjectMediaItem _item({
  required String path,
  required int size,
  required int modifiedMicros,
}) {
  final String fileName = path.replaceAll('\\', '/').split('/').last;
  return ProjectMediaItem(
    fileName: fileName,
    resolvedPath: path,
    authoredSource: 'video/$fileName',
    sizeBytes: size,
    modifiedAt: DateTime.fromMicrosecondsSinceEpoch(modifiedMicros),
    usability: ProjectMediaUsability.usable,
  );
}
