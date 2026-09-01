// ./lib/diag.dart

import 'dart:io';

import 'package:flutter/foundation.dart';

// =====================================================================
// WHY THIS EXISTS
//
// The warm-up and setup traces were going to debugPrint, which means
// they only exist under `flutter run`. That turned out to be the wrong
// assumption: this app is normally BUILT, and a debug run surfaces a
// backlog of assertions that release has always tolerated silently
// (RenderFlex overflows, InheritedElement dependency checks, TextStyle
// factor warnings). Chasing those to read one log line is a tax on the
// wrong problem.
//
// So the trace goes to a file as well, and the file works in release.
// Set [diagLogPath] once at startup and the whole app can report into
// one place regardless of build mode.
//
// KEPT, not scaffolding. Every performance guess made about this app
// without it was wrong, and the one run with it answered the question
// outright. The flags that feed it are const false, so the calls compile
// away entirely and cost nothing when off.
// =====================================================================


/// Absolute path of the trace file, or null to log to the console only.
/// Main sets this during initState, once the app folder is resolved.
String? diagLogPath;

/// True once this run has truncated the file, so a session starts clean
/// instead of appending to yesterday's confusion, without each write
/// paying for a length check.
bool _diagTruncated = false;

/// Appends [message] to the trace file and echoes it to the console.
///
/// Never throws. A diagnostic that can take down the thing it is
/// diagnosing is worse than no diagnostic, and this runs on the asset
/// decode path where an unwritable folder is entirely plausible.
void diag(String tag, String message) {
  final String line = '[$tag] $message';
  debugPrint(line);

  final String? path = diagLogPath;
  if (path == null) return;

  try {
    final File f = File(path);
    if (!_diagTruncated) {
      _diagTruncated = true;
      f.writeAsStringSync('=== r3nder trace ${DateTime.now()} ===\n');
    }
    f.writeAsStringSync(
      '${DateTime.now().toIso8601String()}  $line\n',
      mode: FileMode.append,
    );
  } catch (_) {
    // Console echo above already happened; nothing further to do.
  }
}