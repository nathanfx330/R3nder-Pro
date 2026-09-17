// ./test/timeline_markers_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/marker_language.dart';
import 'package:r3nder/script_pipeline.dart';
import 'package:r3nder/structural_sequence.dart';
import 'package:r3nder/timeline_markers.dart';

void main() {
  group('MARK language', () {
    const String source = '''[MARK:"Top: [alpha]"]
[EDIT:cut]
  [MARK:4:"Edit \\"beat\\""]
  [TRACK:V1]
    [CLIP:c1:clip.mp4:10:20:20:2]
      [MARK:24:"Quote: the good part [alt]"]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

    test('scope is determined by structural ownership', () {
      final List<MarkerDefinition> markers = parseMarkerDefinitions(source);
      expect(markers, hasLength(3));

      expect(markers[0].scope, MarkerScope.text);
      expect(markers[0].localFrame, isNull);
      expect(markers[0].label, 'Top: [alpha]');

      expect(markers[1].scope, MarkerScope.edit);
      expect(markers[1].localFrame, 4);
      expect(markers[1].rootType, 'EDIT');
      expect(markers[1].rootId, 'cut');
      expect(markers[1].label, 'Edit "beat"');

      expect(markers[2].scope, MarkerScope.clip);
      expect(markers[2].localFrame, 24);
      expect(markers[2].rootType, 'EDIT');
      expect(markers[2].rootId, 'cut');
      expect(markers[2].containerId, 'V1');
      expect(markers[2].clipId, 'c1');
      expect(markers[2].label, 'Quote: the good part [alt]');
    });

    test('cross-parse marker addresses are document based', () {
      final List<MarkerDefinition> a = parseMarkerDefinitions(source);
      final List<MarkerDefinition> b = parseMarkerDefinitions(source);
      expect(
        a.map((MarkerDefinition marker) => marker.address).toList(),
        b.map((MarkerDefinition marker) => marker.address).toList(),
      );
    });

    test('formatter round trips colon bracket quote and backslash', () {
      const String label = 'Quote: [alt] says "yes" \\ maybe';
      final String tag = formatMarkerTag(frame: 90, label: label);
      final String wrapped = '''[EDIT:cut]
  [TRACK:V1]
    [CLIP:c1:clip.mp4:0:0:120:1]
      $tag
    [/CLIP]
  [/TRACK]
[/EDIT]
''';
      final MarkerDefinition parsed = parseMarkerDefinitions(wrapped).single;
      expect(parsed.localFrame, 90);
      expect(parsed.label, label);
      expect(parsed.rawSource, tag);
    });

    test('TEXT rejects absolute frame and EDIT rejects positional form', () {
      expect(
        () => parseMarkerDefinitions('[MARK:12:"wrong"]\nText'),
        throwsA(isA<MarkerFormatException>()),
      );
      expect(
        () => parseMarkerDefinitions('''[EDIT:cut]
  [MARK:"wrong"]
[/EDIT]
'''),
        throwsA(isA<MarkerFormatException>()),
      );
    });

    test('MARK-looking prose inside presentation and comment is opaque', () {
      const String opaque = '''[CARD:person.png:10:24,32,40:SUBJECT]
[MARK:"not a marker"]
[/CARD]
[# [MARK:"also not"] ]
[MARK:"real"]
''';
      final List<MarkerDefinition> markers = parseMarkerDefinitions(opaque);
      expect(markers, hasLength(1));
      expect(markers.single.label, 'real');
    });
  });

  group('engine projection', () {
    test('runtime MARK is zero-time and absent from engine text', () {
      const String plain = 'alpha\nbeta';
      const String marked = 'alpha\n[MARK:"chapter: [two]"]\nbeta';

      expect(
        stripMarkersForEngine(marked, preserveLineCoordinates: false),
        plain,
      );
      expect(
        compileScript(marked).engineText,
        compileScript(plain).engineText,
      );
    });

    test('editor projection preserves authored line coordinates', () {
      const String marked = 'alpha\n[MARK:"chapter"]\nbeta';
      final String stripped = stripMarkersForEngine(
        marked,
        preserveLineCoordinates: true,
      );
      expect(stripped, 'alpha\n\nbeta');

      final String engineText =
          compileScript(marked, lineMarkers: true).engineText;
      expect(engineText, contains('[LINE:0]alpha'));
      expect(engineText, contains('[LINE:2]beta'));
    });
  });

  group('timeline projection', () {
    test('TEXT marker follows earlier content instead of an absolute frame', () {
      const String source = 'Intro\n[PAUSE:30]\n[MARK:"beat"]\nNext';

      final List<int> firstMap = <int>[
        0,
        ...List<int>.filled(30, 1),
        3,
      ];
      final MarkerInstance first =
          projectTextMarkerInstances(source, firstMap).single;
      expect(first.frame, 31);

      const String sourceWithEarlierPause =
          'Intro\n[PAUSE:30]\n[PAUSE:30]\n[MARK:"beat"]\nNext';
      final List<int> secondMap = <int>[
        0,
        ...List<int>.filled(30, 1),
        ...List<int>.filled(30, 2),
        4,
      ];
      final MarkerInstance second =
          projectTextMarkerInstances(sourceWithEarlierPause, secondMap).single;
      expect(second.frame, 61);
    });

    test('clip-local marker follows in and exact speed mapping', () {
      const String source = '''[EDIT:cut]
  [TRACK:V1]
    [CLIP:c1:clip.mp4:100:20:20:2]
      [MARK:24:"source beat"]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';
      final MarkerInstance marker =
          projectEditMarkerInstances(source, 'cut').single;
      expect(marker.frame, 102);

      const String slipped = '''[EDIT:cut]
  [TRACK:V1]
    [CLIP:c1:clip.mp4:100:22:20:2]
      [MARK:24:"source beat"]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';
      final MarkerInstance afterSlip =
          projectEditMarkerInstances(slipped, 'cut').single;
      expect(afterSlip.frame, 101);
    });

    test('one definition produces one instance per STRUCT placement', () {
      const String source = '''[EDIT:cut]
  [TRACK:V1]
    [CLIP:c1:clip.mp4:0:0:10:1]
      [MARK:2:"same footage"]
    [/CLIP]
  [/TRACK]
[/EDIT]
[STRUCT:EDIT.cut]
[PAUSE:1]
[STRUCT:EDIT.cut]
''';
      final List<StructuralSequencePlacement> placements =
          parseStructuralSequencePlacements(source);
      expect(placements, hasLength(2));

      final List<int> lineMap = List<int>.filled(200, -1);
      lineMap[10] = placements[0].lineIndex;
      lineMap[100] = placements[1].lineIndex;

      final ProgramTimelineLandmarks projected =
          projectProgramTimelineLandmarks(
        rawDocument: source,
        rawLineAtFrame: lineMap,
      );
      final List<MarkerInstance> instances = projected.markers
          .where((MarkerInstance item) => item.label == 'same footage')
          .toList();

      expect(instances, hasLength(2));
      expect(instances[0].address, instances[1].address);
      expect(
        instances[0].frame,
        10 + placements[0].contentStartFrame + 2,
      );
      expect(
        instances[1].frame,
        100 + placements[1].contentStartFrame + 2,
      );
      expect(instances[0].placementIndex, 0);
      expect(instances[1].placementIndex, 1);
    });

    test('presentation and clip IN OUT are derived only', () {
      const String source = '''[EDIT:cut]
  [TRACK:V1]
    [CLIP:c1:clip.mp4:10:20:20:2]
      [CUE:26]
        [CARD:person.png:10:24,32,40:SUBJECT]
          Body.
        [/CARD]
      [/CUE]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

      final List<DerivedLandmark> landmarks =
          derivedLandmarksForEdit(source, 'cut');
      expect(
        landmarks.where((item) => item.kind == DerivedLandmarkKind.clipIn)
            .single
            .frame,
        10,
      );
      expect(
        landmarks.where((item) => item.kind == DerivedLandmarkKind.clipOut)
            .single
            .frame,
        30,
      );
      expect(
        landmarks
            .where(
              (item) => item.kind == DerivedLandmarkKind.presentationIn,
            )
            .single
            .frame,
        13,
      );
      expect(source, isNot(contains('[MARK:')));
    });
  });
}
