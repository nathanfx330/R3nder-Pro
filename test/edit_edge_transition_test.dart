// ./test/edit_edge_transition_test.dart

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/edit_surface_model.dart';
import 'package:r3nder/edit_video_compositor.dart';
import 'package:r3nder/media_layer.dart';
import 'package:r3nder/project_clock.dart';

class _SolidBackend implements MediaDecoderBackend {
  @override
  MediaDecoder open(String resolvedPath) => _SolidDecoder();
}

class _SolidDecoder implements MediaDecoder {
  @override
  DecodedMediaFrame render(int requestedSourceFrame, int width, int height) {
    final Uint8List rgba = Uint8List(width * height * 4);
    for (int i = 0; i < rgba.length; i += 4) {
      rgba[i] = 255;
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

EditVideoCompositor _compositor(String source) {
  final EditDocumentModel model = EditDocumentModel.parse(source);
  final MediaLayer layer = MediaLayer(
    editDocument: model,
    backend: _SolidBackend(),
    resolveSource: (String value) => value,
  );
  return EditVideoCompositor(
    document: EditSurfaceDocument.parse(source, 'main'),
    mediaLayer: layer,
    backend: _SolidBackend(),
    resolveSource: (String value) => value,
  );
}

List<int> _pixel(EditVideoCompositeResult result) =>
    result.rgba!.sublist(0, 4);

void main() {
  const ui.Size size = ui.Size(1, 1);

  test('incoming crossfade on an isolated clip fades from opaque black', () {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:solo:solo.mp4:0:0:6:1]
[#EDIT_TRANSITION:CROSSFADE:3]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final EditVideoCompositor compositor = _compositor(source);

    final EditVideoCompositeResult start = compositor.render(
      'main',
      ProjectTime(frame: 0, mode: ProjectClockMode.scrub),
      size,
    );
    final EditVideoCompositeResult middle = compositor.render(
      'main',
      ProjectTime(frame: 1, mode: ProjectClockMode.scrub),
      size,
    );
    final EditVideoCompositeResult end = compositor.render(
      'main',
      ProjectTime(frame: 2, mode: ProjectClockMode.scrub),
      size,
    );

    expect(start.hasImage, isTrue);
    expect(_pixel(start), <int>[0, 0, 0, 255]);
    expect(_pixel(middle), <int>[128, 0, 0, 255]);
    expect(_pixel(end), <int>[255, 0, 0, 255]);

    compositor.dispose();
  });

  test('outgoing crossfade on an isolated clip fades to opaque black', () {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:solo:solo.mp4:0:0:6:1]
[#EDIT_TRANSITION_OUT:CROSSFADE:3]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final EditVideoCompositor compositor = _compositor(source);

    final EditVideoCompositeResult start = compositor.render(
      'main',
      ProjectTime(frame: 3, mode: ProjectClockMode.scrub),
      size,
    );
    final EditVideoCompositeResult middle = compositor.render(
      'main',
      ProjectTime(frame: 4, mode: ProjectClockMode.scrub),
      size,
    );
    final EditVideoCompositeResult end = compositor.render(
      'main',
      ProjectTime(frame: 5, mode: ProjectClockMode.scrub),
      size,
    );

    expect(_pixel(start), <int>[255, 0, 0, 255]);
    expect(_pixel(middle), <int>[128, 0, 0, 255]);
    expect(end.hasImage, isTrue);
    expect(_pixel(end), <int>[0, 0, 0, 255]);

    compositor.dispose();
  });

  test('surface model serializes and clears outgoing crossfade independently', () {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:solo:solo.mp4:0:0:12:1]
[#EDIT_TRANSITION:CROSSFADE:3]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final EditSurfaceDocument document = EditSurfaceDocument.parse(source, 'main');
    final String withOut = document.setOutgoingTransition(
      'V1',
      'solo',
      const EditTransition.crossfade(4),
    );
    final EditSurfaceClip clip =
        EditSurfaceDocument.parse(withOut, 'main').clip('V1', 'solo');

    expect(clip.transition, const EditTransition.crossfade(3));
    expect(clip.outgoingTransition, const EditTransition.crossfade(4));
    expect(withOut, contains('[#EDIT_TRANSITION_OUT:CROSSFADE:4]'));

    final String cleared = EditSurfaceDocument.parse(withOut, 'main')
        .setOutgoingTransition('V1', 'solo', const EditTransition.none());
    final EditSurfaceClip clearedClip =
        EditSurfaceDocument.parse(cleared, 'main').clip('V1', 'solo');

    expect(clearedClip.transition, const EditTransition.crossfade(3));
    expect(clearedClip.outgoingTransition, const EditTransition.none());
    expect(cleared, isNot(contains('EDIT_TRANSITION_OUT')));
  });

  test('split keeps incoming on left and outgoing on right', () {
    const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:solo:solo.mp4:0:0:12:1]
[#EDIT_TRANSITION:CROSSFADE:3]
[#EDIT_TRANSITION_OUT:CROSSFADE:4]
[/CLIP]
[/TRACK]
[/EDIT]
''';

    final String split = EditSurfaceDocument.parse(source, 'main')
        .splitClip('V1', 'solo', 6);
    final EditSurfaceDocument reparsed =
        EditSurfaceDocument.parse(split, 'main');

    expect(
      reparsed.clip('V1', 'solo').transition,
      const EditTransition.crossfade(3),
    );
    expect(
      reparsed.clip('V1', 'solo').outgoingTransition,
      const EditTransition.none(),
    );
    expect(
      reparsed.clip('V1', 'solo_2').transition,
      const EditTransition.none(),
    );
    expect(
      reparsed.clip('V1', 'solo_2').outgoingTransition,
      const EditTransition.crossfade(4),
    );
  });
}
