// ./tool/measure_script_cst.dart
//
// Measurement-only harness for ScriptCstDocument.parse.
//
// This deliberately does not assert a performance threshold and does not
// change parser behavior. It measures the current CST cost on synthetic
// structural documents with and without opaque terminal-language regions, and
// can also measure a real authored script supplied on the command line.
//
// Usage:
//   dart run tool/measure_script_cst.dart
//   dart run tool/measure_script_cst.dart path/to/script.txt
//   dart run tool/measure_script_cst.dart path/to/script.txt --iterations=200

import 'dart:convert';
import 'dart:io';

import 'package:r3nder/script_cst.dart';

class _Stats {
  final int iterations;
  final double meanMs;
  final double p50Ms;
  final double p95Ms;
  final double minMs;
  final double maxMs;

  const _Stats({
    required this.iterations,
    required this.meanMs,
    required this.p50Ms,
    required this.p95Ms,
    required this.minMs,
    required this.maxMs,
  });
}

int _percentileIndex(int length, double percentile) {
  if (length <= 1) return 0;
  return ((length - 1) * percentile)
      .round()
      .clamp(0, length - 1)
      .toInt();
}

_Stats _measure(String source, {required int iterations}) {
  const int warmupIterations = 20;
  int rootSink = 0;

  for (int i = 0; i < warmupIterations; i++) {
    rootSink += ScriptCstDocument.parse(source).roots.length;
  }

  final List<int> samplesUs = <int>[];
  samplesUs.length = iterations;

  for (int i = 0; i < iterations; i++) {
    final Stopwatch stopwatch = Stopwatch()..start();
    final ScriptCstDocument document = ScriptCstDocument.parse(source);
    stopwatch.stop();
    rootSink += document.roots.length;
    samplesUs[i] = stopwatch.elapsedMicroseconds;
  }

  if (rootSink == -1) {
    stderr.writeln('unreachable: $rootSink');
  }

  final List<int> sorted = List<int>.from(samplesUs)..sort();
  final int totalUs = samplesUs.fold<int>(0, (int a, int b) => a + b);

  double ms(int microseconds) => microseconds / 1000.0;

  return _Stats(
    iterations: iterations,
    meanMs: ms(totalUs) / iterations,
    p50Ms: ms(sorted[_percentileIndex(sorted.length, 0.50)]),
    p95Ms: ms(sorted[_percentileIndex(sorted.length, 0.95)]),
    minMs: ms(sorted.first),
    maxMs: ms(sorted.last),
  );
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MiB';
}

int _lineCount(String source) {
  if (source.isEmpty) return 0;
  int lines = 1;
  for (final int unit in source.codeUnits) {
    if (unit == 10) lines++;
  }
  return lines;
}

void _printResult(
  String label,
  String source,
  int rootCount,
  _Stats stats,
) {
  final int byteLength = utf8.encode(source).length;
  stdout.writeln(
    '${label.padRight(24)} '
    '${_formatBytes(byteLength).padLeft(10)}  '
    '${_lineCount(source).toString().padLeft(6)} lines  '
    '${rootCount.toString().padLeft(5)} roots  '
    'n=${stats.iterations.toString().padLeft(3)}  '
    'mean ${stats.meanMs.toStringAsFixed(3).padLeft(8)} ms  '
    'p50 ${stats.p50Ms.toStringAsFixed(3).padLeft(8)} ms  '
    'p95 ${stats.p95Ms.toStringAsFixed(3).padLeft(8)} ms  '
    'min ${stats.minMs.toStringAsFixed(3).padLeft(8)}  '
    'max ${stats.maxMs.toStringAsFixed(3).padLeft(8)}',
  );
}

String _structuralEdit(int index) {
  return '''[EDIT:edit_$index]
[TRACK:V1]
[CLIP:clip_$index:video/source_$index.mp4:0:0:90:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';
}

String _opaquePayload(int index) {
  return '''[# opaque comment containing [EDIT:ghost_comment_$index]
[CARD:placeholder.png:1:30,30,38:OPAQUE $index]
[EDIT:ghost_card_$index]
[TRACK:V1]
[CLIP:ghost:video/ghost.mp4:0:0:10:1]
[/CLIP]
[/TRACK]
[/EDIT]
[/CARD]
[DEF_MENU:opaque_$index]
[EDIT:ghost_menu_$index]
[/EDIT]
[/DEF_MENU]
''';
}

String _syntheticDocument(int editCount, {required bool opaqueHeavy}) {
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < editCount; i++) {
    out.write(_structuralEdit(i));
    if (opaqueHeavy && i % 5 == 0) {
      out.write(_opaquePayload(i));
    }
  }
  return out.toString();
}

int _iterationsFor(String source, int requested) {
  if (requested > 0) return requested;
  if (source.length >= 500000) return 30;
  if (source.length >= 150000) return 60;
  return 120;
}

int _parseIterations(List<String> args) {
  for (final String arg in args) {
    if (!arg.startsWith('--iterations=')) continue;
    final int? parsed = int.tryParse(arg.substring('--iterations='.length));
    if (parsed != null && parsed > 0) return parsed;
  }
  return 0;
}

String? _parseInputPath(List<String> args) {
  for (final String arg in args) {
    if (!arg.startsWith('--')) return arg;
  }
  return null;
}

void _measureSyntheticPair(int edits, int requestedIterations) {
  final String plain = _syntheticDocument(edits, opaqueHeavy: false);
  final String opaque = _syntheticDocument(edits, opaqueHeavy: true);

  final int plainRoots = ScriptCstDocument.parse(plain).roots.length;
  final int opaqueRoots = ScriptCstDocument.parse(opaque).roots.length;
  if (plainRoots != edits || opaqueRoots != edits) {
    throw StateError(
      'Synthetic corpus escaped opaque ownership: '
      'expected $edits roots, got plain=$plainRoots opaque=$opaqueRoots.',
    );
  }

  final int plainIterations = _iterationsFor(plain, requestedIterations);
  final int opaqueIterations = _iterationsFor(opaque, requestedIterations);
  final _Stats plainStats = _measure(plain, iterations: plainIterations);
  final _Stats opaqueStats = _measure(opaque, iterations: opaqueIterations);

  _printResult('structural $edits', plain, plainRoots, plainStats);
  _printResult('opaque-heavy $edits', opaque, opaqueRoots, opaqueStats);

  final double ratio = plainStats.meanMs <= 0.0
      ? 0.0
      : opaqueStats.meanMs / plainStats.meanMs;
  stdout.writeln(
    '  opaque-heavy / structural mean ratio: ${ratio.toStringAsFixed(2)}x\n',
  );
}

void main(List<String> args) {
  final int requestedIterations = _parseIterations(args);

  stdout.writeln('ScriptCstDocument.parse measurement');
  stdout.writeln('No performance threshold. No parser mutation.');
  stdout.writeln(
    'Synthetic pair isolates the practical cost of adding opaque terminal '
    'regions to the same structural workload.\n',
  );

  for (final int edits in <int>[25, 100, 400]) {
    _measureSyntheticPair(edits, requestedIterations);
  }

  final String? inputPath = _parseInputPath(args);
  if (inputPath == null) {
    stdout.writeln(
      'Tip: pass your longer authored script to measure the real document:\n'
      '  dart run tool/measure_script_cst.dart path/to/script.txt\n',
    );
    return;
  }

  final File file = File(inputPath);
  if (!file.existsSync()) {
    stderr.writeln('Input file does not exist: $inputPath');
    exitCode = 2;
    return;
  }

  final String source = file.readAsStringSync();
  final ScriptCstDocument parsed = ScriptCstDocument.parse(source);
  final int iterations = _iterationsFor(source, requestedIterations);
  final _Stats stats = _measure(source, iterations: iterations);

  stdout.writeln('Actual authored document');
  _printResult(
    file.path,
    source,
    parsed.roots.length,
    stats,
  );
}
