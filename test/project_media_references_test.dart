// ./test/project_media_references_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/project_media_references.dart';

void main() {
  test(
    'catalog projects direct video references from EDIT and MOSAIC owners',
    () {
      const String source =
          '''[EDIT:a]\n  [TRACK:V1]\n    [CLIP:a1:video/shared.mp4:0:0:30:1]\n    [/CLIP]\n  [/TRACK]\n[/EDIT]\n[EDIT:b]\n  [TRACK:V2]\n    [CLIP:b1:video/shared.mp4:10:0:20:1]\n    [/CLIP]\n  [/TRACK]\n[/EDIT]\n[MOSAIC:wall]\n  [PANE:left]\n    [CLIP:m1:video/other.mov:0:0:40:1]\n    [/CLIP]\n  [/PANE]\n[/MOSAIC]\n''';

      final ProjectMediaReferenceCatalog catalog = projectMediaReferences(
        EditDocumentModel.parse(source),
      );

      expect(catalog.references, hasLength(3));
      expect(catalog.authoredSources, <String>[
        'video/shared.mp4',
        'video/other.mov',
      ]);

      final List<ProjectMediaReference> shared = catalog.referencesFor(
        'video/shared.mp4',
      );
      expect(shared, hasLength(2));
      expect(shared[0].structuralSource, 'EDIT.a');
      expect(shared[0].laneId, 'V1');
      expect(shared[0].clipId, 'a1');
      expect(shared[0].belongsToEdit, isTrue);
      expect(shared[1].structuralSource, 'EDIT.b');

      final ProjectMediaReference mosaic = catalog
          .referencesFor('video/other.mov')
          .single;
      expect(mosaic.structuralSource, 'MOSAIC.wall');
      expect(mosaic.laneId, 'left');
      expect(mosaic.belongsToEdit, isFalse);
    },
  );

  test('catalog ignores structural CLIPs and non-bin direct sources', () {
    const String source =
        '''[EDIT:nested]\n  [TRACK:V1]\n    [CLIP:n:video/nested.mp4:0:0:20:1]\n    [/CLIP]\n  [/TRACK]\n[/EDIT]\n[EDIT:main]\n  [TRACK:V1]\n    [CLIP:struct:EDIT.nested:0:0:20:1]\n    [/CLIP]\n    [CLIP:external:/tmp/external.mp4:20:0:20:1]\n    [/CLIP]\n    [CLIP:project:video/project.mp4:40:0:20:1]\n    [/CLIP]\n  [/TRACK]\n[/EDIT]\n''';

    final ProjectMediaReferenceCatalog catalog = projectMediaReferences(
      EditDocumentModel.parse(source),
    );

    expect(catalog.authoredSources, <String>[
      'video/nested.mp4',
      'video/project.mp4',
    ]);
    expect(catalog.referencesFor('EDIT.nested'), isEmpty);
    expect(catalog.referencesFor('/tmp/external.mp4'), isEmpty);
    expect(catalog.referencesFor('video/project.mp4').single.clipId, 'project');
  });
}
