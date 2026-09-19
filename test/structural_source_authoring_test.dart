// ./test/structural_source_authoring_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/structural_sequence.dart';
import 'package:r3nder/structural_source_authoring.dart';

void main() {
  test('renaming EDIT refactors structural references but not ordinary text', () {
    const String source = '''EDIT.main is ordinary prose and must stay literal.
[EDIT: main ]
  [TRACK:V1]
    [CLIP:a:video/a.mp4:0:0:20:1]
    [/CLIP]
  [/TRACK]
[/EDIT]
[MOSAIC:wall]
  [PANE:pane1]
    [CLIP:edit_main: EDIT.main :0:0:20:1]
    [/CLIP]
  [/PANE]
[/MOSAIC]
[STRUCT:EDIT.main:TITLE="EDIT.main display title"]
[STRUCT:MOSAIC.wall]
''';

    final StructuralSourceRef from =
        StructuralSourceRef.tryParse('EDIT.main')!;
    final String next = renameStructuralSource(
      source: source,
      sourceRef: from,
      newId: 'interview',
    );

    expect(next, contains('EDIT.main is ordinary prose'));
    expect(next, contains('[EDIT: interview ]'));
    expect(
      next,
      contains('[CLIP:edit_main: EDIT.interview :0:0:20:1]'),
    );
    expect(
      next,
      contains('[STRUCT:EDIT.interview:TITLE="EDIT.main display title"]'),
    );
    expect(next, isNot(contains('[STRUCT:EDIT.main:')));

    final EditDocumentModel model = EditDocumentModel.parse(next);
    expect(model.edit('interview').id, 'interview');
    expect(model.mosaic('wall').pane('pane1').clip('edit_main').source,
        'EDIT.interview');

    final List<StructuralSequencePlacement> placements =
        parseStructuralSequencePlacements(next);
    expect(placements.first.sourceRef.canonicalSource, 'EDIT.interview');
    expect(placements.first.windowTitle, 'EDIT.main display title');
  });

  test('renaming MOSAIC updates EDIT clip and STRUCT placement references', () {
    const String source = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:wall:MOSAIC.wall:0:0:10:1]
    [/CLIP]
  [/TRACK]
[/EDIT]
[MOSAIC:wall]
  [PANE:pane1]
    [CLIP:a:video/a.mp4:0:0:10:1]
    [/CLIP]
  [/PANE]
[/MOSAIC]
[STRUCT:MOSAIC.wall]
''';

    final String next = renameStructuralSource(
      source: source,
      sourceRef: StructuralSourceRef.tryParse('MOSAIC.wall')!,
      newId: 'evidence_wall',
    );

    expect(next, contains('[MOSAIC:evidence_wall]'));
    expect(next, contains('[CLIP:wall:MOSAIC.evidence_wall:0:0:10:1]'));
    expect(next, contains('[STRUCT:MOSAIC.evidence_wall]'));

    final EditDocumentModel model = EditDocumentModel.parse(next);
    expect(model.mosaic('evidence_wall').id, 'evidence_wall');
    expect(model.edit('main').track('V1').clip('wall').source,
        'MOSAIC.evidence_wall');
  });

  test('rename rejects invalid ids and same-namespace collisions', () {
    const String source = '''[EDIT:main]
[/EDIT]
[EDIT:other]
[/EDIT]
[MOSAIC:main]
  [PANE:pane1]
  [/PANE]
[/MOSAIC]
''';
    final StructuralSourceRef main =
        StructuralSourceRef.tryParse('EDIT.main')!;

    expect(
      () => renameStructuralSource(
        source: source,
        sourceRef: main,
        newId: 'bad name',
      ),
      throwsArgumentError,
    );
    expect(
      () => renameStructuralSource(
        source: source,
        sourceRef: main,
        newId: 'other',
      ),
      throwsStateError,
    );

    // EDIT and MOSAIC have separate namespaces.
    final String unchangedNamespace = renameStructuralSource(
      source: source,
      sourceRef: main,
      newId: 'main_2',
    );
    expect(unchangedNamespace, contains('[MOSAIC:main]'));
    expect(unchangedNamespace, contains('[EDIT:main_2]'));
  });
}
