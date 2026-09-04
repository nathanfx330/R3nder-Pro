// ./test/mosaic_surface_model_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_linter.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/mosaic_surface_model.dart';

void main() {
  test('createMosaicWithSource appends canonical source without changing edit', () {
    const String source = '''PREFIX
[EDIT:interview]
[TRACK:V1]
[CLIP:a:video/a.mp4:0:0:90:1]
[/CLIP]
[/TRACK]
[/EDIT]
SUFFIX
''';

    final String next = createMosaicWithSource(
      source: source,
      mosaicId: 'wall',
      paneId: 'left',
      clipId: 'interview_source',
      structuralSource: 'EDIT.interview',
      durationFrames: 90,
    );

    expect(next.startsWith(source), isTrue);
    final EditDocumentModel model = EditDocumentModel.parse(next);
    expect(model.edit('interview').projectFrameCount, 90);
    final MosaicSequence mosaic = model.mosaic('wall');
    expect(mosaic.projectFrameCount, 90);
    expect(mosaic.pane('left').clip('interview_source').source, 'EDIT.interview');
    expect(EditGraphLinter.lint(model).isValid, isTrue);
  });

  test('setClipSource rewrites only selected CLIP opening tag', () {
    const String source = '''[EDIT:a]
[TRACK:V1]
[CLIP:x:video/a.mp4:0:0:20:1]
[/CLIP]
[/TRACK]
[/EDIT]
[EDIT:b]
[TRACK:V1]
[CLIP:y:video/b.mp4:0:0:30:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
  [PANE:left]
    [CLIP:inside:EDIT.a:4:2:12:1/2]
opaque body stays exact
[/CLIP]
  [/PANE]
[/MOSAIC]
''';

    final MosaicSurfaceDocument document =
        MosaicSurfaceDocument.parse(source, 'wall');
    final EditClip before = document.clip('left', 'inside');
    final String prefix = source.substring(0, before.block.startOffset);
    final String suffix = source.substring(before.block.openEndOffset);

    final String next = document.setClipSource('left', 'inside', 'EDIT.b');

    expect(next.startsWith(prefix), isTrue);
    expect(next.endsWith(suffix), isTrue);
    final EditClip after =
        MosaicSurfaceDocument.parse(next, 'wall').clip('left', 'inside');
    expect(after.source, 'EDIT.b');
    expect(after.atFrame, 4);
    expect(after.inFrame, 2);
    expect(after.durationFrames, 12);
    expect(after.speed, ExactClipSpeed(1, 2));
    expect(after.block.innerSource, before.block.innerSource);
  });

  test('addPane authors a second pane and preserves explicit duration', () {
    const String source = '''[EDIT:a]
[TRACK:V1]
[CLIP:x:video/a.mp4:0:0:20:1]
[/CLIP]
[/TRACK]
[/EDIT]
[EDIT:b]
[TRACK:V1]
[CLIP:y:video/b.mp4:0:0:80:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:left]
[CLIP:first:EDIT.a:0:0:50:1]
[/CLIP]
[/PANE]
[/MOSAIC]
''';

    final MosaicSurfaceDocument document =
        MosaicSurfaceDocument.parse(source, 'wall');
    final String next = document.addPane(
      paneId: 'right',
      clipId: 'second',
      structuralSource: 'EDIT.b',
      atFrame: 10,
      durationFrames: 25,
    );

    final MosaicSurfaceDocument reparsed =
        MosaicSurfaceDocument.parse(next, 'wall');
    expect(reparsed.mosaic.panes.map((MosaicPane p) => p.id), <String>[
      'left',
      'right',
    ]);
    final EditClip second = reparsed.clip('right', 'second');
    expect(second.atFrame, 10);
    expect(second.durationFrames, 25);
    expect(second.source, 'EDIT.b');
    expect(reparsed.projectFrameCount, 50);
  });

  test('addClip creates another timeline clip inside one PANE', () {
    const String source = '''[EDIT:a]
[TRACK:V1]
[CLIP:x:video/a.mp4:0:0:20:1]
[/CLIP]
[/TRACK]
[/EDIT]
[EDIT:b]
[TRACK:V1]
[CLIP:y:video/b.mp4:0:0:20:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:left]
[CLIP:first:EDIT.a:0:0:10:1]
[/CLIP]
[/PANE]
[/MOSAIC]
''';

    final MosaicSurfaceDocument document =
        MosaicSurfaceDocument.parse(source, 'wall');
    final String next = document.addClip(
      paneId: 'left',
      clipId: 'second',
      structuralSource: 'EDIT.b',
      atFrame: 10,
      inFrame: 3,
      durationFrames: 8,
      speed: ExactClipSpeed(2),
    );

    final MosaicSurfaceDocument reparsed =
        MosaicSurfaceDocument.parse(next, 'wall');
    expect(reparsed.pane('left').clips, hasLength(2));
    final EditClip clip = reparsed.clip('left', 'second');
    expect(clip.source, 'EDIT.b');
    expect(clip.atFrame, 10);
    expect(clip.inFrame, 3);
    expect(clip.durationFrames, 8);
    expect(clip.speed, ExactClipSpeed(2));
  });

  test('authoring rejects a mixed cycle before source is returned', () {
    const String source = '''[EDIT:a]
[TRACK:V1]
[CLIP:x:MOSAIC.wall:0:0:20:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:left]
[CLIP:first:EDIT.a:0:0:20:1]
[/CLIP]
[/PANE]
[/MOSAIC]
''';

    expect(
      () => MosaicSurfaceDocument.parse(source, 'wall')
          .setClipDuration('left', 'first', 10),
      throwsA(
        isA<StateError>().having(
          (StateError error) => '$error',
          'message',
          contains('Structural source cycle'),
        ),
      ),
    );
  });

  test('more than three panes is rejected by authoring model', () {
    const String source = '''[EDIT:a]
[TRACK:V1]
[CLIP:x:video/a.mp4:0:0:20:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:p1][CLIP:c1:EDIT.a:0:0:20:1][/CLIP][/PANE]
[PANE:p2][CLIP:c2:EDIT.a:0:0:20:1][/CLIP][/PANE]
[PANE:p3][CLIP:c3:EDIT.a:0:0:20:1][/CLIP][/PANE]
[/MOSAIC]
''';

    final MosaicSurfaceDocument document =
        MosaicSurfaceDocument.parse(source, 'wall');
    expect(
      () => document.addPane(
        paneId: 'p4',
        clipId: 'c4',
        structuralSource: 'EDIT.a',
        atFrame: 0,
        durationFrames: 20,
      ),
      throwsStateError,
    );
  });
}
