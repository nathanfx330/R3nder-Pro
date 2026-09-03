// ./lib/native_file_dialog.dart
//
// Linux host file chooser used by source-backed EDIT media import.
//
// The runner already owns the r3nder/drop method channel for native file
// drag/drop. Method channels are bidirectional, so the same bridge also owns
// the explicit pickVideo request. No plugin dependency or shell helper is
// needed.

import 'dart:io';

import 'package:flutter/services.dart';

const MethodChannel _nativeFileChannel = MethodChannel('r3nder/drop');

Future<String?> pickNativeVideoFile() async {
  if (!Platform.isLinux) {
    throw UnsupportedError('Native video picking is currently Linux-only.');
  }

  final String? path = await _nativeFileChannel.invokeMethod<String>('pickVideo');
  if (path == null || path.trim().isEmpty) return null;
  return path;
}
