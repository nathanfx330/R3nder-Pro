// ./test/scene_exporter_structural_mosaic_custom_end_to_end_test.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/engine.dart';
import 'package:r3nder/exporter.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/scene_engine.dart';
import 'package:r3nder/script_pipeline.dart';
import 'package:r3nder/structural_sequence.dart';

class _SolidBackend implements MediaDecoderBackend {
  @override
  MediaDecoder open(String resolvedPath) => _SolidDecoder();
}

class _SolidDecoder implements MediaDecoder {
  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    final Uint8List rgba = Uint8List(width * height * 4);
    for (int i = 0; i < rgba.length; i += 4) {
      rgba[i] = 180;
      rgba[i + 1] = 20;
      rgba[i + 2] = 20;
      rgba[i + 3] = 255;
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

int _lightNeutralPixels(
  Uint8List rgba,
  int width,
  int height,
  Rect region,
) {
  final int left = region.left.floor().clamp(0, width - 1);
  final int right = region.right.ceil().clamp(0, width);
  final int top = region.top.floor().clamp(0, height - 1);
  final int bottom = region.bottom.ceil().clamp(0, height);
  int count = 0;

  for (int y = top; y < bottom; y++) {
    for (int x = left; x < right; x++) {
      final int i = (y * width + x) * 4;
      final int r = rgba[i];
      final int g = rgba[i + 1];
      final int b = rgba[i + 2];
      final int hi = r > g ? (r > b ? r : b) : (g > b ? g : b);
      final int lo = r < g ? (r < b ? r : b) : (g < b ? g : b);
      if (r > 90 && g > 90 && b > 90 && hi - lo < 50) count++;
    }
  }
  return count;
}

void main() {
  testWidgets(
      'SceneExporter versions named FULL MOSAIC CUSTOM chrome in encoded H264',
      (WidgetTester tester) async {
    const int width = 640;
    const int height = 360;
    const String source = '''[CONFIG:RENDERNAME:Documentary Cut]
[SPEED:MAX]
[EDIT:main]
[TRACK:V1]
[CLIP:leaf:leaf.mp4:0:0:8:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:pane1]
[CLIP:edit_main:EDIT.main:0:0:8:1]
[/CLIP]
[/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall:FULL:OVERLAY=CUSTOM:TITLE="MONITOR [frame]":TOP="FRAME [frame]":BOTTOM="REEL [frame]"]
''';

    final ProcessResult ffmpegCheck =
        (await tester.runAsync<ProcessResult>(
      () => Process.run('ffmpeg', ['-version']),
    ))!;
    expect(ffmpegCheck.exitCode, 0, reason: 'ffmpeg is required for BAKE.');

    final StructuralSequencePlacement placement =
        parseStructuralSequencePlacements(source).single;
    expect(placement.sourceRef.canonicalSource, 'MOSAIC.wall');
    expect(placement.presentationMode, StructuralPresentationMode.fullscreen);
    expect(placement.overlayMode.name, 'custom');
    expect(placement.windowTitle, 'MONITOR [frame]');
    expect(placement.topOverlay, 'FRAME [frame]');
    expect(placement.bottomOverlay, 'REEL [frame]');

    final Directory root =
        Directory.systemTemp.createTempSync('r3_struct_mosaic_export_e2e_');
    final Directory images = Directory('${root.path}/images')
      ..createSync(recursive: true);
    final Directory sprites = Directory('${root.path}/sprites')
      ..createSync(recursive: true);
    final String requestedOutput = '${root.path}/output_1080p.mp4';
    final String expectedOutput =
        '${root.path}/Documentary_Cut_1080p_v001.mp4';
    final String decoded = '${root.path}/decoded.rgba';
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    final CompiledScript compiled = compileScript(source, lineMarkers: false);
    final SceneEngine scene = SceneEngine();
    addTearDown(scene.disposeImages);

    await tester.runAsync(() async {
      await scene.setup(
        templateText: compiled.engineText,
        fontColor: Colors.green,
        bgColor: Colors.black,
        width: width.toDouble(),
        height: height.toDouble(),
        scale: 1,
        fontPath: 'monospace',
        fontSize: 18,
        lineSpacing: 22,
        tracking: 0,
        marginTop: 20,
        marginSide: 20,
        imagesDir: images.path,
        spritesDir: sprites.path,
        paneLifeConfig: compiled.paneLife,
        captionConfig: compiled.caption,
        appSwitchConfig: compiled.appSwitch,
      );
    });

    final ExportResult result = (await tester.runAsync<ExportResult>(() {
      return SceneExporter.export(
        scene: scene,
        fontFamily: 'monospace',
        outputPath: requestedOutput,
        format: VideoExportFormat.h264Solid,
        fps: engineFps,
        width: width,
        height: height,
        structuralDocument: source,
        resolveStructuralSource: (String value) => value,
        structuralBackend: _SolidBackend(),
      );
    }))!;

    expect(result.success, isTrue, reason: result.error);
    expect(result.outputPath, expectedOutput);
    expect(File(expectedOutput).existsSync(), isTrue);
    expect(File(requestedOutput).existsSync(), isFalse,
        reason: 'The legacy dashboard filename must never be overwritten.');

    final ProcessResult decodeResult =
        (await tester.runAsync<ProcessResult>(
      () => Process.run(
        'ffmpeg',
        <String>[
          '-y',
          '-v',
          'error',
          '-i',
          result.outputPath,
          '-f',
          'rawvideo',
          '-pix_fmt',
          'rgba',
          decoded,
        ],
      ),
    ))!;
    expect(decodeResult.exitCode, 0, reason: '${decodeResult.stderr}');

    final Uint8List all = File(decoded).readAsBytesSync();
    final int frameBytes = width * height * 4;
    expect(all.length, greaterThanOrEqualTo(frameBytes));
    final int frameCount = all.length ~/ frameBytes;

    final Rect headerRegion = Rect.fromLTWH(0, 0, width.toDouble(), 38);
    final Rect bottomRegion = Rect.fromLTWH(
      0,
      height - 50.0,
      width * 0.65,
      50,
    );

    int bestHeader = 0;
    int bestBottom = 0;
    for (int frame = 0; frame < frameCount; frame++) {
      final Uint8List rgba = Uint8List.sublistView(
        all,
        frame * frameBytes,
        (frame + 1) * frameBytes,
      );
      final int header = _lightNeutralPixels(
        rgba,
        width,
        height,
        headerRegion,
      );
      final int bottom = _lightNeutralPixels(
        rgba,
        width,
        height,
        bottomRegion,
      );
      if (header > bestHeader) bestHeader = header;
      if (bottom > bestBottom) bestBottom = bottom;
    }

    expect(
      bestHeader,
      greaterThan(20),
      reason: 'Encoded MOSAIC MP4 must retain STRUCT title/top chrome pixels.',
    );
    expect(
      bestBottom,
      greaterThan(5),
      reason: 'Encoded MOSAIC MP4 must retain STRUCT bottom chrome pixels.',
    );
  });
}
