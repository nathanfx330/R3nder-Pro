// ./test/edit_workspace_test.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/audio_bed.dart';
import 'package:r3nder/edit_linter.dart';
import 'package:r3nder/edit_media_import.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/edit_playback_clock.dart';
import 'package:r3nder/edit_surface_model.dart';
import 'package:r3nder/edit_workspace.dart';
import 'package:r3nder/exporter.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/project_clock.dart';
import 'package:r3nder/ui_theme.dart';

class _FakePlaybackClock implements EditPlaybackClock {
  @override
  final RationalFrameRate rate;

  ProjectTime _current = ProjectTime.zero();
  bool running = false;
  int samples = 0;
  int holds = 0;
  int playFromCalls = 0;

  _FakePlaybackClock(this.rate);

  @override
  ProjectTime sample() {
    samples++;
    if (running) {
      _current = ProjectTime(
        frame: _current.frame + 1,
        epoch: _current.epoch,
        mode: ProjectClockMode.monotonic,
      );
    }
    return _current;
  }

  @override
  void playFrom(ProjectTime time) {
    playFromCalls++;
    running = true;
    _current = time.withMode(ProjectClockMode.monotonic);
  }

  @override
  void holdAt(ProjectTime time) {
    running = false;
    holds++;
    _current = time.withMode(ProjectClockMode.scrub);
  }

  @override
  void dispose() {}
}

class _FakeAudioBedPlayer implements AudioBedPlayer {
  @override
  final String backendName;
  final void Function()? onPlay;

  bool _playing = false;
  int stops = 0;
  String? path;
  double? startSec;
  double? gainDb;
  bool? loop;
  PlaybackDevice? device;
  String? musicPath;
  double? musicGainDb;
  bool? musicLoop;
  double? musicSeekSec;
  double? durationSec;

  _FakeAudioBedPlayer({
    this.backendName = 'libpulse',
    this.onPlay,
  });

  @override
  bool get isPlaying => _playing;

  @override
  Future<List<PlaybackDevice>> listDevices() async => const <PlaybackDevice>[
        PlaybackDevice(id: null, description: 'System Default'),
      ];

  @override
  Future<void> play(
    String path, {
    double startSec = 0.0,
    double gainDb = 0.0,
    bool loop = false,
    PlaybackDevice? device,
    String? musicPath,
    double musicGainDb = 0.0,
    bool musicLoop = false,
    double? musicSeekSec,
    double? durationSec,
  }) async {
    this.path = path;
    this.startSec = startSec;
    this.gainDb = gainDb;
    this.loop = loop;
    this.device = device;
    this.musicPath = musicPath;
    this.musicGainDb = musicGainDb;
    this.musicLoop = musicLoop;
    this.musicSeekSec = musicSeekSec;
    this.durationSec = durationSec;
    _playing = true;
    onPlay?.call();
  }

  @override
  Future<void> stop() async {
    stops++;
    _playing = false;
  }

  @override
  Future<void> testTone({PlaybackDevice? device}) async {}

  @override
  void dispose() {
    _playing = false;
  }
}

class _PreviewBackend implements MediaDecoderBackend {
  int openCount = 0;
  final List<String> openedPaths = <String>[];

  @override
  MediaDecoder open(String resolvedPath) {
    openCount++;
    openedPaths.add(resolvedPath);
    return _PreviewDecoder();
  }
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

String _previewResolve(String source) => '/virtual/$source';

void main() {
  testWidgets('ADD VIDEO creates first edit and V1 clip without TEXT authoring',
      (WidgetTester tester) async {
    String latest = 'Hello\n';

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 1000,
          height: 700,
          child: EditWorkspace(
            source: latest,
            currentFrame: 0,
            theme: R3Theme.of(Colors.green),
            onSourceChanged: (String value) => latest = value,
            onSeek: (_) {},
            backend: _PreviewBackend(),
            resolveSource: _previewResolve,
            pickVideo: () async => '/outside/interview.mp4',
            importVideo: (_) => const ImportedEditVideo(
              authoredSource: 'video/interview.mp4',
              resolvedPath: '/workspace/video/interview.mp4',
              clipBaseId: 'interview',
              durationFrames: 90,
            ),
          ),
        ),
      ),
    );

    expect(find.textContaining('NO VIDEO EDIT YET'), findsOneWidget);
    await tester.tap(find.text('ADD VIDEO'));
    await tester.pumpAndSettle();

    final EditSurfaceDocument document = EditSurfaceDocument.parse(latest, 'main');
    expect(document.clip('V1', 'interview').durationFrames, 90);
    expect(find.text('V1'), findsOneWidget);
  });

  testWidgets('ADD VIDEO authors source rate conform speed into CLIP',
      (WidgetTester tester) async {
    String latest = 'Hello\n';

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 1000,
          height: 700,
          child: EditWorkspace(
            source: latest,
            currentFrame: 0,
            theme: R3Theme.of(Colors.green),
            onSourceChanged: (String value) => latest = value,
            onSeek: (_) {},
            backend: _PreviewBackend(),
            resolveSource: _previewResolve,
            pickVideo: () async => '/outside/spring.webm',
            importVideo: (_) => const ImportedEditVideo(
              authoredSource: 'video/spring.webm',
              resolvedPath: '/workspace/video/spring.webm',
              clipBaseId: 'spring',
              durationFrames: 13925,
              speedNumerator: 4,
              speedDenominator: 5,
              sourceFpsNumerator: 24,
              sourceFpsDenominator: 1,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('ADD VIDEO'));
    await tester.pumpAndSettle();

    final EditSurfaceDocument document = EditSurfaceDocument.parse(latest, 'main');
    final clip = document.clip('V1', 'spring');
    expect(clip.durationFrames, 13925);
    expect(clip.speed.numerator, 4);
    expect(clip.speed.denominator, 5);
    expect(clip.clip.sourceFrameAtProjectOffset(30), 24);
  });

  testWidgets('ADD OVERLAY creates V2 at current edit playhead',
      (WidgetTester tester) async {
    String latest = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:base:video/base.mp4:0:0:120:1]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 1000,
          height: 700,
          child: EditWorkspace(
            source: latest,
            currentFrame: 36,
            theme: R3Theme.of(Colors.green),
            onSourceChanged: (String value) => latest = value,
            onSeek: (_) {},
            backend: _PreviewBackend(),
            resolveSource: _previewResolve,
            pickVideo: () async => '/outside/title.mov',
            importVideo: (_) => const ImportedEditVideo(
              authoredSource: 'video/title.mov',
              resolvedPath: '/workspace/video/title.mov',
              clipBaseId: 'title',
              durationFrames: 48,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('ADD OVERLAY'));
    await tester.pumpAndSettle();

    final EditSurfaceDocument document = EditSurfaceDocument.parse(latest, 'main');
    expect(document.clip('V2', 'title').atFrame, 36);
    expect(document.clip('V2', 'title').durationFrames, 48);
  });

  testWidgets(
      'PLAY samples ProjectClock on Flutter frames and PAUSE publishes parked frame',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    const String source = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:base:video/base.mp4:0:0:120:1]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';
    int lastSeek = 0;
    _FakePlaybackClock? fake;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 1000,
          height: 700,
          child: EditWorkspace(
            source: source,
            currentFrame: 0,
            theme: R3Theme.of(Colors.green),
            onSourceChanged: (_) {},
            onSeek: (int frame) => lastSeek = frame,
            backend: _PreviewBackend(),
            resolveSource: _previewResolve,
            playbackClockFactory: (RationalFrameRate rate) {
              fake = _FakePlaybackClock(rate);
              return fake!;
            },
            audioPlayerResolver: () => null,
          ),
        ),
      ),
    );

    expect(find.text('PLAY'), findsOneWidget);
    await tester.tap(find.text('PLAY'));
    await tester.pump();
    expect(find.text('PAUSE'), findsOneWidget);

    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 17));
    }
    expect(fake, isNotNull);
    expect(fake!.samples, greaterThanOrEqualTo(3));
    expect(fake!.playFromCalls, 1);
    expect(find.textContaining('EDIT main   F'), findsOneWidget);
    expect(lastSeek, 0);

    await tester.tap(find.text('PAUSE'));
    await tester.pump();
    expect(find.text('PLAY'), findsOneWidget);
    expect(fake!.holds, greaterThan(0));
    expect(fake!.running, isFalse);
    expect(lastSeek, greaterThan(0));
  });

  testWidgets(
    'libpulse structural PLAY hands exact ProjectClock point to workspace mix',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 700));
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
      });

      final Directory temp = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'r3nder_edit_audio_${pid}_${DateTime.now().microsecondsSinceEpoch}',
      );
      if (temp.existsSync()) temp.deleteSync(recursive: true);
      temp.createSync(recursive: true);

      try {
        final Directory audioDirectory = Directory(
          '${temp.path}${Platform.pathSeparator}audio',
        )..createSync(recursive: true);
        final File voice = File(
          '${audioDirectory.path}${Platform.pathSeparator}voice.wav',
        )..writeAsBytesSync(const <int>[0]);
        final File music = File(
          '${audioDirectory.path}${Platform.pathSeparator}score.wav',
        )..writeAsBytesSync(const <int>[0]);
        File('${temp.path}${Platform.pathSeparator}workspace.json')
            .writeAsStringSync('''{
  "audioBed": {"file": "voice.wav", "gainDb": -4.0},
  "musicBed": {"file": "score.wav", "gainDb": -9.5, "loop": true}
}''');

        const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:base:video/base.mp4:0:0:120:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';
        _FakePlaybackClock? clock;
        late _FakeAudioBedPlayer audio;
        audio = _FakeAudioBedPlayer(
          onPlay: () {
            clock!.running = true;
          },
        );
        const PlaybackDevice selectedDevice = PlaybackDevice(
          id: 'sink.test',
          description: 'Test Sink',
        );

        int lastSeek = 30;
        await tester.pumpWidget(
          MaterialApp(
            home: SizedBox(
              width: 1000,
              height: 700,
              child: EditWorkspace(
                source: source,
                currentFrame: 30,
                theme: R3Theme.of(Colors.green),
                onSourceChanged: (_) {},
                onSeek: (int frame) => lastSeek = frame,
                backend: _PreviewBackend(),
                resolveSource: _previewResolve,
                workspaceRootResolver: () => temp.path,
                playbackClockFactory: (RationalFrameRate rate) {
                  clock = _FakePlaybackClock(rate);
                  return clock!;
                },
                audioPlayerResolver: () => audio,
                playbackDeviceResolver: (_) async => selectedDevice,
                audioProbe: (String path) async => AudioBedInfo(
                  path: path,
                  ok: true,
                  durationSec: 0.5,
                  sampleRate: 48000,
                  channels: 2,
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        await tester.tap(find.text('PLAY'));
        for (int i = 0; i < 10 && find.text('PAUSE').evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 10));
        }

        expect(find.text('PAUSE'), findsOneWidget);
        expect(clock, isNotNull);
        expect(clock!.holds, 1);
        expect(clock!.playFromCalls, 0);
        expect(audio.isPlaying, isTrue);
        expect(audio.path, voice.path);
        expect(audio.startSec, closeTo(1.0, 0.000001));
        expect(audio.gainDb, -4.0);
        expect(audio.loop, isFalse);
        expect(audio.device, selectedDevice);
        expect(audio.musicPath, music.path);
        expect(audio.musicGainDb, -9.5);
        expect(audio.musicLoop, isTrue);
        expect(audio.musicSeekSec, closeTo(0.0, 0.000001));
        expect(audio.durationSec, closeTo(3.0, 0.000001));

        for (int i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 17));
        }
        expect(clock!.samples, greaterThan(0));
        expect(find.textContaining('EDIT main   F'), findsOneWidget);

        await tester.tap(find.text('PAUSE'));
        for (int i = 0; i < 5 && audio.stops == 0; i++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
        await tester.pump();

        expect(audio.stops, 1);
        expect(audio.isPlaying, isFalse);
        expect(clock!.holds, greaterThanOrEqualTo(2));
        expect(clock!.running, isFalse);
        expect(lastSeek, greaterThan(30));

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      } finally {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  testWidgets('GUI can build MOSAIC from EDIT then use MOSAIC as EDIT CLIP source',
      (WidgetTester tester) async {
    String latest = '''[EDIT:main]
[TRACK:V1]
[CLIP:base:video/base.mp4:0:0:60:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 1100,
          height: 760,
          child: EditWorkspace(
            source: latest,
            currentFrame: 0,
            theme: R3Theme.of(Colors.green),
            onSourceChanged: (String value) => latest = value,
            onSeek: (_) {},
            backend: _PreviewBackend(),
            resolveSource: _previewResolve,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('NEW MOSAIC'));
    await tester.pumpAndSettle();

    EditDocumentModel model = EditDocumentModel.parse(latest);
    expect(model.mosaics, hasLength(1));
    expect(model.mosaic('mosaic').pane('pane').clip('source').source, 'EDIT.main');
    expect(find.textContaining('MOSAIC mosaic'), findsWidgets);
    expect(find.textContaining('PANE pane'), findsOneWidget);

    await tester.tap(find.text('NEW EDIT'));
    await tester.pumpAndSettle();

    model = EditDocumentModel.parse(latest);
    expect(model.edits.map((EditSequence edit) => edit.id), <String>['main', 'edit']);
    expect(find.textContaining('EDIT edit   F'), findsOneWidget);

    await tester.tap(find.text('ADD SOURCE'));
    await tester.pumpAndSettle();

    final Finder dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    final Finder picker = find.descendant(
      of: dialog,
      matching: find.byType(DropdownButton<String>),
    );
    expect(picker, findsOneWidget);
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(find.text('MOSAIC.mosaic').last);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: dialog, matching: find.text('ADD')));
    await tester.pumpAndSettle();

    model = EditDocumentModel.parse(latest);
    final EditClip nested = model.edit('edit').track('V1').clips.single;
    expect(nested.source, 'MOSAIC.mosaic');
    expect(nested.durationFrames, 60);
    expect(EditGraphLinter.lint(model).isValid, isTrue);
  });

  testWidgets(
    'EXPORT sends selected MOSAIC root and workspace audio mix to structural exporter',
    (WidgetTester tester) async {
      final Directory temp = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'r3nder_edit_workspace_export_${pid}_${DateTime.now().microsecondsSinceEpoch}',
      );
      if (temp.existsSync()) temp.deleteSync(recursive: true);
      temp.createSync(recursive: true);

      try {
        final Directory audioDirectory = Directory(
          '${temp.path}${Platform.pathSeparator}audio',
        )..createSync(recursive: true);
        final File voice = File(
          '${audioDirectory.path}${Platform.pathSeparator}voice.wav',
        )..writeAsBytesSync(const <int>[0]);
        final File music = File(
          '${audioDirectory.path}${Platform.pathSeparator}score.wav',
        )..writeAsBytesSync(const <int>[0]);
        File('${temp.path}${Platform.pathSeparator}workspace.json')
            .writeAsStringSync('''{
  "audioBed": {"file": "voice.wav", "gainDb": -3.5},
  "musicBed": {"file": "score.wav", "gainDb": -11.25, "loop": true}
}''');

        const String source = '''[MOSAIC:wall]
[PANE:pane]
[CLIP:source:video/base.mp4:0:0:30:1]
[/CLIP]
[/PANE]
[/MOSAIC]
''';

        String? exportedSource;
        String? exportedPath;
        VideoExportFormat? exportedFormat;
        int? exportedWidth;
        int? exportedHeight;
        int? exportedFps;
        String? exportedAudioPath;
        double? exportedAudioGain;
        String? exportedMusicPath;
        double? exportedMusicGain;
        bool? exportedMusicLoop;
        final _PreviewBackend previewBackend = _PreviewBackend();
        final List<String> resolvedPreviewSources = <String>[];

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
                backend: previewBackend,
                resolveSource: (String value) {
                  resolvedPreviewSources.add(value);
                  return '/preview/$value';
                },
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
                  exportedSource = structuralSource;
                  exportedPath = outputPath;
                  exportedFormat = format;
                  exportedWidth = width;
                  exportedHeight = height;
                  exportedFps = fps;
                  exportedAudioPath = audioPath;
                  exportedAudioGain = audioGainDb;
                  exportedMusicPath = musicPath;
                  exportedMusicGain = musicGainDb;
                  exportedMusicLoop = musicLoop;
                  onStatus?.call('Rendering Structural Source...');
                  onProgress?.call(30, 30);
                  return ExportResult(
                    success: true,
                    cancelled: false,
                    framesWritten: 30,
                    outputPath: outputPath,
                  );
                },
              ),
            ),
          ),
        );

        for (int i = 0; i < 20 && previewBackend.openCount == 0; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(previewBackend.openCount, greaterThan(0));
        expect(resolvedPreviewSources, contains('video/base.mp4'));
        expect(previewBackend.openedPaths, contains('/preview/video/base.mp4'));

        expect(find.textContaining('MOSAIC wall'), findsWidgets);
        expect(find.text('EXPORT'), findsOneWidget);

        await tester.tap(find.text('EXPORT'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        final Finder dialog = find.byType(AlertDialog);
        expect(dialog, findsOneWidget);
        expect(
          find.byKey(const ValueKey<String>('structural-export-resolution')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey<String>('structural-export-format')),
          findsOneWidget,
        );

        await tester.tap(
          find.descendant(of: dialog, matching: find.text('EXPORT')),
        );
        await tester.pump();

        for (int i = 0; i < 20 && exportedSource == null; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(exportedSource, 'MOSAIC.wall');

        for (int i = 0;
            i < 20 &&
                find
                    .byKey(const ValueKey<String>('structural-export-status'))
                    .evaluate()
                    .isEmpty;
            i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }

        expect(exportedFormat, VideoExportFormat.h264Solid);
        expect(exportedWidth, 1920);
        expect(exportedHeight, 1080);
        expect(exportedFps, 30);
        expect(exportedAudioPath, voice.path);
        expect(exportedAudioGain, -3.5);
        expect(exportedMusicPath, music.path);
        expect(exportedMusicGain, -11.25);
        expect(exportedMusicLoop, isTrue);
        expect(
          exportedPath,
          '${temp.path}${Platform.pathSeparator}output_frames'
          '${Platform.pathSeparator}mosaic_wall_1080p.mp4',
        );
        expect(
          find.byKey(const ValueKey<String>('structural-export-status')),
          findsOneWidget,
        );
        expect(find.textContaining('EXPORTED'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      } finally {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );
}
