// ./lib/compositor.dart

import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'scene_engine.dart';
import 'scene_painter.dart';

/// The SceneCompositor is responsible for translating the current state of
/// the SceneEngine into a flat, raw pixel buffer (ui.Image).
///
/// Unlike Ananogram, R3nder does not require continuous-time trail decay or
/// recursive frame retention. Every frame is drawn from scratch. This makes
/// the compositor extremely fast and completely immune to VRAM leaks.
///
/// When the scene has no desktop configured, ScenePainter delegates directly
/// to TerminalPainter, so classic terminal-only scripts render byte-identical
/// to the pre-scene architecture.
class SceneCompositor {
  final int width;
  final int height;

  SceneCompositor({required this.width, required this.height});

  /// Renders the exact current state of the scene into a Picture.
  ui.Picture _recordFrame(SceneEngine scene, String fontFamily) {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    );

    // We instantiate the painter and manually tell it to paint onto our canvas.
    final painter = ScenePainter(scene: scene, fontFamily: fontFamily);
    painter.paint(canvas, Size(width.toDouble(), height.toDouble()));

    return recorder.endRecording();
  }

  /// Synchronously generates a ui.Image for the Live Preview.
  /// Because there are no recursive images being overlaid, `toImageSync`
  /// is perfectly safe to use here and will not leak memory.
  ui.Image advanceLive(SceneEngine scene, String fontFamily) {
    final ui.Picture picture = _recordFrame(scene, fontFamily);
    final ui.Image image = picture.toImageSync(width, height);
    picture.dispose();
    return image;
  }

  /// Asynchronously generates a ui.Image for the FFmpeg Export pipeline.
  /// Awaits the rasterization to ensure the bytes are fully available
  /// before we try to extract them as raw RGBA data.
  Future<ui.Image> advanceExportAsync(SceneEngine scene, String fontFamily) async {
    final ui.Picture picture = _recordFrame(scene, fontFamily);
    final ui.Image image = await picture.toImage(width, height);
    picture.dispose();
    return image;
  }
}