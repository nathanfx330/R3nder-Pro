// ./test/scene_evaluation_equivalence_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/engine.dart';
import 'package:r3nder/motion.dart';
import 'package:r3nder/project_clock.dart';
import 'package:r3nder/scene_engine.dart';
import 'package:r3nder/scene_evaluator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('explicit evaluation matches reset plus ticks across scene states',
      () async {
    final Directory root =
        await Directory.systemTemp.createTemp('r3nder_eval_equivalence_');
    final Directory images = Directory('${root.path}/images')..createSync();
    final Directory sprites = Directory('${root.path}/sprites')..createSync();
    final Directory gallery = Directory('${images.path}/gallery')..createSync();
    final Directory video = Directory('${images.path}/video')..createSync();

    const String onePixelPng =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZVt8AAAAASUVORK5CYII=';
    final List<int> pngBytes = base64Decode(onePixelPng);

    for (int i = 0; i < 4; i++) {
      File('${gallery.path}/${i.toString().padLeft(2, '0')}.png')
          .writeAsBytesSync(pngBytes);
    }
    for (int i = 0; i < 6; i++) {
      File('${video.path}/${i.toString().padLeft(2, '0')}.png')
          .writeAsBytesSync(pngBytes);
    }

    const String script = '''
[SPEED:MAX]
SYSTEM
[PAUSE:2]
[BAR:6:8]
[GALLERY:gallery:4:FADE:Gallery]
[VIDEO:video:3:Video:24]
[APP:gallery:30:App:MOSAIC:3:1@1;1;1]
[BROWSER:gallery:45:Browser:SCROLL]
[CARD:missing.png:8:30,30,38:Card]
Card body.
[/CARD]
[DOSSIER:gallery:missing.png:70:12:0:MOSAIC:30,30,38:Dossier]
Dossier body.
[/DOSSIER]
[TIMELINE:8:30,30,38:Timeline]
2025 | First event
2026 | Second event
[/TIMELINE]
DONE.
''';

    final SceneEngine scene = SceneEngine();
    addTearDown(() {
      scene.disposeImages();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    await scene.setup(
      templateText: script,
      fontColor: const Color(0xFF00FF00),
      bgColor: const Color(0xFF0A0F0A),
      width: 1280,
      height: 720,
      scale: 1,
      fontPath: 'monospace',
      fontSize: 32,
      lineSpacing: 40,
      tracking: 0,
      marginTop: 60,
      marginSide: 60,
      imagesDir: images.path,
      spritesDir: sprites.path,
      paneLifeConfig: 'ON:102:INOUT',
      withPreroll: true,
    );

    final List<int> probes = _collectProbeFrames(scene);
    expect(probes.length, greaterThan(20));

    // Alternate low and high target frames. evaluate() therefore has to deal
    // with both forward requests and backward requests that force a reset and
    // replay. The reference side always starts at frame zero and ticks to the
    // same target.
    final List<int> targetOrder = _zigZag(probes);
    scene.reset();

    for (final int target in targetOrder) {
      final SceneEvaluationResult result = scene.evaluate(
        ProjectTime(frame: target, mode: ProjectClockMode.scrub),
      );
      expect(
        result.exact,
        isTrue,
        reason: 'explicit evaluation did not reach frame $target',
      );
      final Map<String, Object?> evaluated = _fingerprint(scene);

      scene.reset();
      while (scene.frameCount < target && !scene.isFinished) {
        scene.tick();
      }
      expect(
        scene.frameCount,
        target,
        reason: 'reference replay did not reach frame $target',
      );
      final Map<String, Object?> replayed = _fingerprint(scene);

      expect(
        evaluated,
        equals(replayed),
        reason: 'scene state diverged at project frame $target',
      );
    }

    scene.reset();
    final SceneEvaluationResult bounded = scene.evaluate(
      ProjectTime(frame: 20, mode: ProjectClockMode.scrub),
      maxForwardFrames: 5,
    );
    expect(bounded.reachedFrame, 5);
    expect(bounded.exact, isFalse);

    final SceneEvaluationResult completed = scene.evaluate(
      ProjectTime(frame: 20, mode: ProjectClockMode.scrub),
      maxForwardFrames: 15,
    );
    expect(completed.reachedFrame, 20);
    expect(completed.exact, isTrue);
  });
}

List<int> _collectProbeFrames(SceneEngine scene) {
  const int guardLimit = 20000;
  final Set<int> probes = <int>{0};

  scene.reset();
  var phase = scene.phase;
  int phaseStart = 0;
  int guard = 0;

  while (!scene.isFinished && guard < guardLimit) {
    scene.tick();
    guard++;

    // Regular samples make long holds and VIDEO playback observable instead
    // of checking only phase boundaries.
    if (scene.frameCount % 11 == 0) probes.add(scene.frameCount);

    if (scene.phase != phase) {
      _addIntervalProbes(probes, phaseStart, scene.frameCount - 1);
      phase = scene.phase;
      phaseStart = scene.frameCount;
    }
  }

  expect(guard, lessThan(guardLimit),
      reason: 'fixture scene failed to finish');
  _addIntervalProbes(probes, phaseStart, scene.frameCount);
  probes.add(scene.frameCount);

  final List<int> sorted = probes
      .where((frame) => frame >= 0 && frame <= scene.frameCount)
      .toList()
    ..sort();
  return sorted;
}

void _addIntervalProbes(Set<int> out, int start, int end) {
  if (end < start) return;
  out.add(start);
  if (start + 1 <= end) out.add(start + 1);
  out.add(start + ((end - start) ~/ 2));
  if (end - 1 >= start) out.add(end - 1);
  out.add(end);
}

List<int> _zigZag(List<int> sorted) {
  final List<int> out = <int>[];
  int low = 0;
  int high = sorted.length - 1;
  bool takeLow = true;

  while (low <= high) {
    if (takeLow) {
      out.add(sorted[low++]);
    } else {
      out.add(sorted[high--]);
    }
    takeLow = !takeLow;
  }
  return out;
}

Map<String, Object?> _fingerprint(SceneEngine scene) {
  final TerminalEngine t = scene.terminal;

  return <String, Object?>{
    'sceneFrame': scene.frameCount,
    'phase': scene.phase.name,
    'phaseProgress': _q(scene.phaseProgress),
    'finished': scene.isFinished,
    'preroll': scene.inPrerollSequence,
    'chainClosing': scene.isChainClosing,
    'chainOpening': scene.isChainOpening,

    'galleryCurrent': _id(scene.galleryCurrentImage),
    'galleryPrevious': _id(scene.galleryPrevImage),
    'galleryTitle': scene.galleryTitle,
    'galleryTransition': scene.galleryTransitionStyle,

    'appMosaic': scene.appIsMosaic,
    'appMaximizes': scene.appMaximizes,
    'appPage': scene.appPageIndex,
    'appPages': scene.appPageCount,
    'appTitle': scene.appTitle,
    'appIncomingTitle': scene.appTitleIncoming,
    'appPan': _q(scene.appPanT),
    'appTileOpacity': <int>[
      for (int i = 0; i < 9; i++) _q(scene.appTileOpacity(i)),
    ],
    'appPageState': <Object?>[
      for (int page = 0; page < scene.appPageCount; page++)
        <String, Object?>{
          'rects': scene.appPageRects(page).map(_rect).toList(),
          'panes': <Object?>[
            for (int i = 0; i < scene.appPageRects(page).length; i++)
              <String, Object?>{
                'image': _id(scene.appPaneImage(page, i)),
                'motion': _motion(scene.appPaneMotion(page, i)),
              },
          ],
        },
    ],

    'browserImage': _id(scene.browserImage),
    'browserIncoming': _id(scene.browserIncomingImage),
    'browserUrl': scene.browserUrl,
    'browserTab': scene.browserTabTitle,
    'browserTitle': scene.browserWindowTitle,
    'browserMode': scene.browserScrollMode.name,
    'browserMaximizes': scene.browserMaximizes,
    'browserScroll': _q(scene.browserScrollT),
    'browserLoad': _q(scene.browserLoadProgress),
    'browserPage': scene.browserPageIndex,
    'browserPages': scene.browserPageCount,

    'cardActive': scene.hasActiveCard,
    'cardImage': _id(scene.cardImage),
    'cardColor': _color(scene.cardPanelColor),
    'cardHeading': scene.cardHeading,
    'cardBody': scene.cardBody,
    'cardSlide': _q(scene.cardSlide),

    'dossierActive': scene.hasActiveDossier,
    'dossierImages': scene.dossierImages.map(_id).toList(),
    'dossierTitleImage': _id(scene.dossierTitleImage),
    'dossierColor': _color(scene.dossierPanelColor),
    'dossierHeading': scene.dossierHeading,
    'dossierBody': scene.dossierBody,
    'dossierMode': scene.dossierCenterMode.name,
    'dossierAge': scene.dossierFramesIntoPhase,
    'dossierPage': scene.dossierMosaicPageIndex,
    'dossierPan': _q(scene.dossierMosaicPanT),
    'dossierCardSlide': _q(scene.dossierCardSlide),
    'dossierGalleryOpen': _q(scene.dossierGalleryOpenness),
    'dossierPages': <Object?>[
      for (int page = 0; page < 4; page++)
        <String, Object?>{
          'rects': scene.dossierMosaicPageRects(page).map(_rect).toList(),
          'images': scene.dossierMosaicPageImages(page).map(_id).toList(),
        },
    ],

    'timelineActive': scene.hasActiveTimeline,
    'timelineHeading': scene.timelineHeading,
    'timelineColor': _color(scene.timelinePanelColor),
    'timelineEvents': <Object?>[
      for (final event in scene.timelineEvents)
        <String, Object?>{'date': event.date, 'text': event.text},
    ],
    'timelineSpine': _q(scene.timelineSpineProgress),
    'timelineSlide': _q(scene.timelineSlide),
    'timelineLine': _q(scene.timelineStageLineT),
    'timelineEventProgress': <int>[
      for (int i = 0; i < scene.timelineEvents.length; i++)
        _q(scene.timelineEventProgress(i)),
    ],
    'timelineStagePhotos': scene.timelineStagePhotos.map(_id).toList(),
    'timelineStageProgress': <int>[
      for (int i = 0; i < scene.timelineStagePairCount; i++)
        _q(scene.timelineStagePhotoProgress(i)),
    ],

    'terminal': <String, Object?>{
      'finished': t.isFinished,
      'frame': t.frameCount,
      'charIndex': t.charIndex,
      'globalCharIndex': t.globalCharIndex,
      'rawLine': t.currentRawLine,
      'cursorX': _q(t.cursorX),
      'cursorY': _q(t.cursorY),
      'currentLineWidth': _q(t.currentLineWidth),
      'align': t.currentAlign,
      'fontSize': _q(t.currentFontSize),
      'lineSpacing': _q(t.currentLineSpacing),
      'charsPerFrame': t.charsPerFrame,
      'pauseFrames': t.pauseFrames,
      'redacting': t.isRedacting,
      'scrambling': t.isScrambling,
      'scrambleFrames': t.scrambleFramesLeft,
      'scrambleTarget': t.scrambleTargetChar,
      'scrambleDisplay': t.scrambleDisplayChar,
      'endHold': t.inEndHold,
      'region': t.currentRegion,
      'penColor': _color(t.penColor),
      'penBg': _color(t.penBg),
      'flash': t.flashStyle,
      'pending': t.pendingPresentation?.runtimeType.toString(),
      'bar': _bar(t.activeBar, t.frameCount),
      'imgBand': _imgBand(t.activeImgBand),
      'svg': _svg(t.activeSvg),
      'photos': <Object?>[
        for (final photo in t.photoStack)
          <String, Object?>{
            'key': photo.key,
            'hold': photo.holdFrames,
            'color': _color(photo.color),
            'persist': photo.persist,
            'release': photo.releaseAt,
            'elapsed': photo.elapsed,
            'reveal': _q(photo.revealProgress),
          },
      ],
      'rendered':
          t.renderedLines.map((line) => _line(line, t.frameCount)).toList(),
      'current': t.currentLine.map((c) => _char(c, t.frameCount)).toList(),
    },
  };
}

Map<String, Object?> _rect(Rect r) => <String, Object?>{
      'l': _q(r.left),
      't': _q(r.top),
      'r': _q(r.right),
      'b': _q(r.bottom),
    };

Map<String, Object?> _motion(PaneMotion m) => <String, Object?>{
      'scale': _q(m.scale),
      'focusX': _q(m.focusX),
      'fit': m.fit.name,
    };

Map<String, Object?> _line(LineData line, int terminalFrame) =>
    <String, Object?>{
      'align': line.align,
      'spacing': _q(line.spacing),
      'width': _q(line.width),
      'chars': line.chars.map((c) => _char(c, terminalFrame)).toList(),
      'imgBand': line.imgBand == null
          ? null
          : <String, Object?>{
              'w': line.imgBand!.stencil.pxWidth,
              'h': line.imgBand!.stencil.pxHeight,
              'color': _color(line.imgBand!.color),
              'scale': _q(line.imgBand!.drawScale),
              'state': _imgBand(line.imgBand!.state),
            },
    };

Map<String, Object?> _char(CharData c, int terminalFrame) =>
    <String, Object?>{
      'char': c.char,
      'fg': _color(c.fgColor),
      'bg': _color(c.bgColor),
      'flash': c.flashStyle,
      'spatial': c.spatialIndex,
      'size': _q(c.fontSize),
      'region': c.regionId,
      'bar': c.barInfo == null
          ? null
          : <String, Object?>{
              'index': c.barInfo!.index,
              'fill': c.barInfo!.fill,
              'empty': c.barInfo!.empty,
              'state': _bar(c.barInfo!.state, terminalFrame),
            },
    };

Map<String, Object?>? _bar(BarState? bar, int terminalFrame) => bar == null
    ? null
    : <String, Object?>{
        'frames': bar.frames,
        'startFrame': bar.startFrame,
        'elapsed': bar.elapsedAt(terminalFrame),
        'progress': _q(bar.progressAt(terminalFrame)),
        'width': bar.width,
      };

Map<String, Object?>? _imgBand(ImgBandState? band) => band == null
    ? null
    : <String, Object?>{
        'framesPer': band.framesPer,
        'copies': band.copies,
        'release': band.releaseAt,
        'elapsed': band.elapsed,
        'revealed': band.revealedCopies,
        'scan': _q(band.scanProgress),
        'total': band.totalFrames,
        'done': band.isDone,
      };

Map<String, Object?>? _svg(ActiveSvgShow? svg) => svg == null
    ? null
    : <String, Object?>{
        'step': svg.stepIdx,
        'framesLeft': svg.framesLeft,
        'color': _color(svg.color),
        'current': svg.steps.isEmpty ? null : svg.currentKey,
        'steps': <Object?>[
          for (final step in svg.steps)
            <String, Object?>{'key': step.key, 'frames': step.frames},
        ],
      };

int _q(double value) => (value * 1000000000).round();

int? _color(Color? color) => color?.toARGB32();

int? _id(Object? object) => object == null ? null : identityHashCode(object);
