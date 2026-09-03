// ./lib/playback_trace.dart
//
// Buffered realtime playback diagnostics.
//
// A trace session records scheduler cadence and ProjectClock publication while
// PLAY is active, but performs no disk writes in the playback hot path. Events
// stay in memory and are written once playback stops. Development runs resolve
// the checked-out project root through resolvePortableBaseDir(), so the result
// appears beside pubspec.yaml as r3nder_playback_session_NNN.log.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'project_clock.dart';
import 'session_store.dart';

class PlaybackTrace {
  PlaybackTrace._();

  static final PlaybackTrace instance = PlaybackTrace._();

  final List<String> _lines = <String>[];
  final Stopwatch _elapsed = Stopwatch();

  bool _active = false;
  String? _path;
  int? _lastTickerElapsedUs;
  int? _lastFlutterVsyncUs;
  int _tickCount = 0;
  int _flutterFrameCount = 0;

  bool get isActive => _active;
  String? get path => _path;

  String? start({
    required int projectFps,
    required String editId,
    required int startFrame,
  }) {
    if (_active) {
      stop(reason: 'restarted');
    }

    final String root = resolvePortableBaseDir();
    final int session = _nextSessionNumber(root);
    final String fileName =
        'r3nder_playback_session_${session.toString().padLeft(3, '0')}.log';
    _path = '$root${Platform.pathSeparator}$fileName';

    _lines.clear();
    _lastTickerElapsedUs = null;
    _lastFlutterVsyncUs = null;
    _tickCount = 0;
    _flutterFrameCount = 0;
    _elapsed
      ..reset()
      ..start();
    _active = true;

    _lines.add('# R3nder playback trace v1');
    _lines.add('# file=$fileName');
    _lines.add('# root=$root');
    _lines.add('# started=${DateTime.now().toIso8601String()}');
    _lines.add('# pid=$pid');
    _lines.add('# project_fps=$projectFps');
    _lines.add('# edit=$editId');
    _lines.add('# start_frame=$startFrame');
    _lines.add(
      '# fields: trace_us STAGE key=value ...',
    );

    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
    record(
      'SESSION_START',
      'frame=$startFrame project_fps=$projectFps edit=$editId',
    );
    debugPrint('R3nder playback trace started: $_path');
    return _path;
  }

  void record(String stage, String fields) {
    if (!_active) return;
    final int traceUs = _elapsed.elapsedMicroseconds;
    _lines.add(
      '${traceUs.toString().padLeft(10, '0')} '
      '${stage.padRight(12)} $fields',
    );
  }

  void recordTick(Duration tickerElapsed, ProjectTime sampled) {
    if (!_active) return;
    final int tickerUs = tickerElapsed.inMicroseconds;
    final int? previous = _lastTickerElapsedUs;
    final int deltaUs = previous == null ? 0 : tickerUs - previous;
    _lastTickerElapsedUs = tickerUs;
    _tickCount++;

    record(
      'TICK',
      'n=$_tickCount ticker_us=$tickerUs delta_us=$deltaUs',
    );
    record(
      'CLOCK',
      'frame=${sampled.frame} '
      'phase=${sampled.phaseNumerator}/${sampled.phaseDenominator} '
      'exact=${sampled.frame}+${sampled.phaseNumerator}/${sampled.phaseDenominator} '
      'epoch=${sampled.epoch} mode=${sampled.mode.name}',
    );
  }

  void recordIntegerPublish(int frame, bool playing) {
    record('INTPUB', 'frame=$frame playing=${playing ? 1 : 0}');
  }

  void recordExactPublish(ProjectTime time, bool playing) {
    record(
      'EXACTPUB',
      'frame=${time.frame} '
      'phase=${time.phaseNumerator}/${time.phaseDenominator} '
      'exact=${time.frame}+${time.phaseNumerator}/${time.phaseDenominator} '
      'playing=${playing ? 1 : 0}',
    );
  }

  void _onFrameTimings(List<ui.FrameTiming> timings) {
    if (!_active) return;

    for (final ui.FrameTiming timing in timings) {
      final int vsyncUs =
          timing.timestampInMicroseconds(ui.FramePhase.vsyncStart);
      final int? previous = _lastFlutterVsyncUs;
      final int deltaUs = previous == null ? 0 : vsyncUs - previous;
      _lastFlutterVsyncUs = vsyncUs;
      _flutterFrameCount++;

      record(
        'FLUTTER',
        'n=$_flutterFrameCount '
        'vsync_us=$vsyncUs delta_us=$deltaUs '
        'build_us=${timing.buildDuration.inMicroseconds} '
        'raster_us=${timing.rasterDuration.inMicroseconds} '
        'total_us=${timing.totalSpan.inMicroseconds}',
      );
    }
  }

  void stop({required String reason}) {
    if (!_active) return;

    record(
      'SESSION_END',
      'reason=$reason ticks=$_tickCount flutter_frames=$_flutterFrameCount',
    );
    SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
    _elapsed.stop();
    _active = false;

    final String? target = _path;
    if (target == null) return;

    try {
      File(target).writeAsStringSync('${_lines.join('\n')}\n');
      debugPrint('R3nder playback trace written: $target');
    } catch (error) {
      debugPrint('R3nder playback trace write failed: $error');
    }
  }

  int _nextSessionNumber(String root) {
    final RegExp pattern =
        RegExp(r'^r3nder_playback_session_(\d+)\.log$');
    int highest = 0;

    try {
      for (final FileSystemEntity entity in Directory(root).listSync()) {
        if (entity is! File) continue;
        final String name = entity.uri.pathSegments.isEmpty
            ? entity.path
            : entity.uri.pathSegments.last;
        final RegExpMatch? match = pattern.firstMatch(name);
        if (match == null) continue;
        final int? value = int.tryParse(match.group(1)!);
        if (value != null && value > highest) highest = value;
      }
    } catch (_) {
      return 1;
    }

    return highest + 1;
  }
}
