// ./test/edit_source_audio_workspace_owner_test.dart

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/audio_bed.dart';
import 'package:r3nder/edit_playback_clock.dart';
import 'package:r3nder/edit_source_audio_preview.dart';
import 'package:r3nder/edit_workspace.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/project_clock.dart';
import 'package:r3nder/ui_theme.dart';

class _FakePlaybackClock implements EditPlaybackClock {
  @override
  final RationalFrameRate rate;

  ProjectTime _current = ProjectTime.zero();
  bool running = false;
  int holds = 0;
  int playFromCalls = 0;

  _FakePlaybackClock(this.rate);

  @override
  ProjectTime sample() {
    if (running) {
      _current = ProjectTime(
        frame: _current.frame + 1,
        mode: ProjectClockMode.audio,
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
    holds++;
    running = false;
    _current = time.withMode(ProjectClockMode.scrub);
  }

  @override
  void dispose() {}
}

class _FakeAudioBedPlayer implements AudioBedPlayer {
  @override
  String get backendName => 'libpulse';

  @override
  bool get isPlaying => false;

  @override
  Future<List<PlaybackDevice>> listDevices() async => const <PlaybackDevice>[
        PlaybackDevice(id: 'sink.edit', description: 'Edit Sink'),
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
  }) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> testTone({PlaybackDevice? device}) async {}

  @override
  void dispose() {}
}

class _FakeSourceAudioPreview implements EditSourceAudioPreviewTransport {
  final void Function()? onPlay;

  int playCalls = 0;
  int stopCalls = 0;
  bool _playing = false;
  String? rawDocument;
  String? structuralSource;
  int? startFrame;
  String? resolvedSource;
  String? deviceId;

  _FakeSourceAudioPreview({this.onPlay});

  @override
  bool get isPlaying => _playing;

  @override
  Future<bool> play({
    required String rawDocument,
    required String structuralSource,
    required int startFrame,
    required String Function(String source) resolveSource,
    String? deviceId,
  }) async {
    playCalls++;
    this.rawDocument = rawDocument;
    this.structuralSource = structuralSource;
    this.startFrame = startFrame;
    resolvedSource = resolveSource('video/base.mp4');
    this.deviceId = deviceId;
    _playing = true;
    onPlay?.call();
    return true;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _playing = false;
  }

  @override
  void dispose() {
    _playing = false;
  }
}

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
  testWidgets(
    'default EDIT PLAY starts selected source audio before transport runs',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 760));
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

      _FakePlaybackClock? clock;
      late _FakeSourceAudioPreview sourceAudio;
      final _FakeAudioBedPlayer audioBackend = _FakeAudioBedPlayer();

      sourceAudio = _FakeSourceAudioPreview(
        onPlay: () {
          clock!.running = true;
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 1100,
            height: 760,
            child: EditWorkspace(
              source: source,
              currentFrame: 0,
              theme: R3Theme.of(Colors.green),
              onSourceChanged: (_) {},
              onSeek: (_) {},
              backend: _PreviewBackend(),
              resolveSource: (String value) => '/workspace/$value',
              playbackClockFactory: (RationalFrameRate rate) {
                clock = _FakePlaybackClock(rate);
                return clock!;
              },
              audioPlayerResolver: () => audioBackend,
              playbackDeviceResolver: (_) async => const PlaybackDevice(
                id: 'sink.edit',
                description: 'Edit Sink',
              ),
              sourceAudioPreviewFactory: (String backendName) {
                expect(backendName, 'libpulse');
                return sourceAudio;
              },
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('PLAY'));
      for (int i = 0; i < 10 && sourceAudio.playCalls == 0; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pump();

      expect(sourceAudio.playCalls, 1);
      expect(sourceAudio.rawDocument, source);
      expect(sourceAudio.structuralSource, 'EDIT.main');
      expect(sourceAudio.startFrame, 0);
      expect(sourceAudio.resolvedSource, '/workspace/video/base.mp4');
      expect(sourceAudio.deviceId, 'sink.edit');
      expect(clock, isNotNull);
      expect(clock!.holds, 1);
      expect(clock!.playFromCalls, 0);
      expect(find.text('PAUSE'), findsOneWidget);

      await tester.tap(find.text('PAUSE'));
      for (int i = 0; i < 10 && sourceAudio.stopCalls == 0; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pump();

      expect(sourceAudio.stopCalls, greaterThanOrEqualTo(1));
      expect(clock!.holds, greaterThanOrEqualTo(2));
      expect(find.text('PLAY'), findsOneWidget);
    },
  );
}
