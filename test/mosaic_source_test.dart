// ./test/mosaic_source_test.dart

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_linter.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/edit_surface_model.dart';
import 'package:r3nder/edit_video_compositor.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/project_clock.dart';
import 'package:r3nder/script_cst.dart';
import 'package:r3nder/script_pipeline.dart';

class _SolidBackend implements MediaDecoderBackend {
  final Map<String, List<int>> requests = <String, List<int>>{};
  int openCount = 0;

  @override
  MediaDecoder open(String resolvedPath) {
    openCount++;
    return _SolidDecoder(
      resolvedPath,
      (int frame) => requests
          .putIfAbsent(resolvedPath, () => <int>[])
          .add(frame),
    );
  }
}

class _SolidDecoder implements MediaDecoder {
  final String path;
  final void Function(int frame) onRequest;

  _SolidDecoder(this.path, this.onRequest);

  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    onRequest(requestedSourceFrame);
    final List<int> color;
    if (path.contains('red')) {
      color = const <int>[255, 0, 0, 255];
    } else if (path.contains('green')) {
      color = const <int>[0, 255, 0, 255];
    } else {
      color = const <int>[0, 0, 255, 255];
    }

    final Uint8List rgba = Uint8List(width * height * 4);
    for (int i = 0; i < rgba.length; i += 4) {
      rgba.setRange(i, i + 4, color);
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

EditVideoCompositor _compositor(
  String source,
  String editId,
  MediaDecoderBackend backend,
) {
  final EditDocumentModel model = EditDocumentModel.parse(source);
  final MediaLayer layer = MediaLayer(
    editDocument: model,
    backend: backend,
    resolveSource: (String value) => value,
  );
  return EditVideoCompositor(
    document: EditSurfaceDocument.parse(source, editId),
    mediaLayer: layer,
    backend: backend,
    resolveSource: (String value) => value,
  );
}

void main() {
  test('MOSAIC PANE CLIP is canonical structural ownership', () {
    const String source = '''before
[MOSAIC:wall]
  [PANE:left]
    [CLIP:a:red.mp4:0:0:30:1]
    [/CLIP]
  [/PANE]
  [PANE:right]
    [CLIP:b:EDIT.child:0:0:30:1]
    [/CLIP]
  [/PANE]
[/MOSAIC]
[EDIT:child]
  [TRACK:V1]
    [CLIP:c:blue.mp4:0:0:30:1]
    [/CLIP]
  [/TRACK]
[/EDIT]
after
''';

    final ScriptCstDocument cst = ScriptCstDocument.parse(source);
    expect(cst.roots.map((ScriptCstBlock block) => block.type),
        <String>['MOSAIC', 'EDIT']);

    final ScriptCstBlock mosaic = cst.roots.first;
    final ScriptCstBlock pane = mosaic.children.first;
    final ScriptCstBlock clip = pane.children.single;
    expect(mosaic.ownershipPath, <String>['MOSAIC']);
    expect(pane.ownershipPath, <String>['MOSAIC', 'PANE']);
    expect(clip.ownershipPath, <String>['MOSAIC', 'PANE', 'CLIP']);

    final EditDocumentModel model = EditDocumentModel.parse(source);
    expect(model.mosaics, hasLength(1));
    expect(model.mosaic('wall').panes.map((MosaicPane p) => p.id),
        <String>['left', 'right']);
    expect(model.mosaic('wall').projectFrameCount, 30);
    expect(model.mosaic('wall').pane('right').clip('b').source, 'EDIT.child');
  });

  test('structural roots are projected out of TerminalEngine text', () {
    const String source = '''BEFORE
[MOSAIC:wall]
[PANE:left]
[CLIP:a:red.mp4:0:0:30:1]
[/CLIP]
[/PANE]
[/MOSAIC]
MIDDLE
[EDIT:main]
[TRACK:V1]
[CLIP:m:MOSAIC.wall:0:0:30:1]
[/CLIP]
[/TRACK]
[/EDIT]
AFTER
''';

    final CompiledScript compiled = compileScript(source);
    expect(compiled.engineText, contains('BEFORE'));
    expect(compiled.engineText, contains('MIDDLE'));
    expect(compiled.engineText, contains('AFTER'));
    expect(compiled.engineText, isNot(contains('[MOSAIC:wall]')));
    expect(compiled.engineText, isNot(contains('[PANE:left]')));
    expect(compiled.engineText, isNot(contains('[EDIT:main]')));

    // Preview/Bake intentionally remove structural metadata from runtime
    // layout instead of preserving one blank line per authored metadata line.
    // The editor still needs authored line identity, so its projection keeps
    // those coordinates long enough to inject the original [LINE:n] markers.
    final CompiledScript editorCompiled =
        compileScript(source, lineMarkers: true);
    expect(editorCompiled.engineText, contains('[LINE:0]BEFORE'));
    expect(editorCompiled.engineText, contains('[LINE:7]MIDDLE'));
    expect(editorCompiled.engineText, contains('[LINE:14]AFTER'));
  });

  test('MOSAIC is one composition and caps at three panes', () {
    const String source = '''[MOSAIC:too_many]
[PANE:a][/PANE]
[PANE:b][/PANE]
[PANE:c][/PANE]
[PANE:d][/PANE]
[/MOSAIC]
''';

    expect(
      () => EditDocumentModel.parse(source),
      throwsA(isA<EditLanguageFormatException>()),
    );
  });

  test('linter catches mixed EDIT MOSAIC cycles', () {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:to_mosaic:MOSAIC.wall:0:0:20:1][/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:left]
[CLIP:to_edit:EDIT.main:0:0:20:1][/CLIP]
[/PANE]
[/MOSAIC]
''';

    final EditLintResult lint =
        EditGraphLinter.lint(EditDocumentModel.parse(source));
    expect(lint.isValid, isFalse);
    final EditLintIssue cycle = lint.issues.firstWhere(
      (EditLintIssue issue) => issue.code == EditLintCode.cycle,
    );
    expect(cycle.message, contains('Structural source cycle'));
    expect(cycle.editPath, contains('EDIT.main'));
    expect(cycle.editPath, contains('MOSAIC.wall'));
  });

  test('MOSAIC source recursively maps exact frames through PANE and EDIT', () {
    const String source = '''[MOSAIC:wall]
[PANE:left]
[CLIP:red:red.mp4:0:10:20:1][/CLIP]
[/PANE]
[PANE:right]
[CLIP:child:EDIT.child:0:4:20:1][/CLIP]
[/PANE]
[/MOSAIC]
[EDIT:child]
[TRACK:V1]
[CLIP:blue:blue.mp4:0:30:20:1][/CLIP]
[/TRACK]
[/EDIT]
[EDIT:main]
[TRACK:V1]
[CLIP:mosaic:MOSAIC.wall:0:3:10:2][/CLIP]
[/TRACK]
[/EDIT]
''';

    final _SolidBackend backend = _SolidBackend();
    final EditDocumentModel model = EditDocumentModel.parse(source);
    final MediaLayer layer = MediaLayer(
      editDocument: model,
      backend: backend,
      resolveSource: (String value) => value,
    );
    final EditVideoCompositor compositor = EditVideoCompositor(
      document: EditSurfaceDocument.parse(source, 'main'),
      mediaLayer: layer,
      backend: backend,
      resolveSource: (String value) => value,
    );

    final EditVideoCompositeResult result = compositor.render(
      'main',
      ProjectTime(frame: 2, epoch: 7, mode: ProjectClockMode.scrub),
      const ui.Size(4, 2),
    );

    // main frame 2 maps to MOSAIC frame 7. The left pane maps that to red
    // frame 17. The right pane maps to child frame 11, then blue frame 41.
    expect(backend.requests['red.mp4'], <int>[17]);
    expect(backend.requests['blue.mp4'], <int>[41]);

    expect(result.rgba, isNotNull);
    final Uint8List pixels = result.rgba!;
    expect(pixels.sublist(0, 4), <int>[255, 0, 0, 255]);
    expect(pixels.sublist(4, 8), <int>[255, 0, 0, 255]);
    expect(pixels.sublist(8, 12), <int>[0, 0, 255, 255]);
    expect(pixels.sublist(12, 16), <int>[0, 0, 255, 255]);

    expect(result.topFrame!.source, 'MOSAIC.wall');
    expect(result.topFrame!.requestedSourceFrame, 7);
    expect(result.topFrame!.actualSourceFrame, 7);
    expect(layer.cachedDecoderCount, 2);

    compositor.dispose();
    layer.dispose();
  });

  test('three PANE MOSAIC uses hero plus stacked pair geometry', () {
    const String source = '''[MOSAIC:wall]
[PANE:hero]
[CLIP:red:red.mp4:0:0:10:1][/CLIP]
[/PANE]
[PANE:top]
[CLIP:green:green.mp4:0:0:10:1][/CLIP]
[/PANE]
[PANE:bottom]
[CLIP:blue:blue.mp4:0:0:10:1][/CLIP]
[/PANE]
[/MOSAIC]
[EDIT:host]
[/EDIT]
''';

    final _SolidBackend backend = _SolidBackend();
    final EditDocumentModel model = EditDocumentModel.parse(source);
    final MediaLayer layer = MediaLayer(
      editDocument: model,
      backend: backend,
      resolveSource: (String value) => value,
    );
    final EditVideoCompositor compositor = EditVideoCompositor(
      document: EditSurfaceDocument.parse(source, 'host'),
      mediaLayer: layer,
      backend: backend,
      resolveSource: (String value) => value,
    );

    final EditVideoCompositeResult result = compositor.renderSource(
      'MOSAIC.wall',
      ProjectTime(frame: 0, mode: ProjectClockMode.scrub),
      const ui.Size(10, 4),
    );

    expect(result.rgba, isNotNull);
    List<int> pixel(int x, int y) {
      final int at = (y * result.width + x) * 4;
      return result.rgba!.sublist(at, at + 4);
    }

    expect(pixel(0, 0), <int>[255, 0, 0, 255]);
    expect(pixel(7, 0), <int>[0, 255, 0, 255]);
    expect(pixel(7, 3), <int>[0, 0, 255, 255]);

    compositor.dispose();
    layer.dispose();
  });
}
