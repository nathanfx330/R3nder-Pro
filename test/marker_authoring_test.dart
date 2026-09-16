// ./test/marker_authoring_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/marker_authoring.dart';
import 'package:r3nder/marker_language.dart';

void main() {
  group('MARK authoring', () {
    test('TEXT M inserts a positional marker before the owning raw line', () {
      const String source = 'alpha\nbeta\ngamma\n';
      final String next = addTextMarkerAtProgramFrame(
        source: source,
        rawLineAtFrame: const <int>[0, 1, 1, 2],
        programFrame: 1,
        label: 'beat',
      );

      expect(next, 'alpha\n[MARK:"beat"]\nbeta\ngamma\n');
      final MarkerDefinition marker = parseMarkerDefinitions(next).single;
      expect(marker.scope, MarkerScope.text);
      expect(marker.localFrame, isNull);
      expect(marker.label, 'beat');
    });

    test('EDIT M writes an explicit sequence-relative definition', () {
      const String source = '''[EDIT:cut]
  [TRACK:V1]
    [CLIP:c1:clip.mp4:0:0:20:1]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

      final String next = addEditMarkerAtProjectFrame(
        source: source,
        editId: 'cut',
        projectFrame: 12,
        label: 'turn',
      );
      final MarkerDefinition marker = parseMarkerDefinitions(next).single;

      expect(marker.scope, MarkerScope.edit);
      expect(marker.localFrame, 12);
      expect(marker.rootId, 'cut');
      expect(marker.label, 'turn');
    });

    test('selected CLIP M stores the sampled source frame, not project frame', () {
      const String source = '''[EDIT:cut]
  [TRACK:V1]
    [CLIP:c1:clip.mp4:10:20:20:2]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

      final String next = addClipMarkerAtProjectFrame(
        source: source,
        editId: 'cut',
        trackId: 'V1',
        clipId: 'c1',
        projectFrame: 14,
        label: 'quote',
      )!;
      final MarkerDefinition marker = parseMarkerDefinitions(next).single;

      expect(marker.scope, MarkerScope.clip);
      expect(marker.localFrame, 28);
      expect(marker.rootId, 'cut');
      expect(marker.containerId, 'V1');
      expect(marker.clipId, 'c1');
    });

    test('selected CLIP M refuses a project frame outside that clip', () {
      const String source = '''[EDIT:cut]
  [TRACK:V1]
    [CLIP:c1:clip.mp4:10:20:20:2]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

      expect(
        addClipMarkerAtProjectFrame(
          source: source,
          editId: 'cut',
          trackId: 'V1',
          clipId: 'c1',
          projectFrame: 9,
        ),
        isNull,
      );
    });

    test('TEXT insertion preserves CRLF documents', () {
      const String source = 'alpha\r\nbeta\r\n';
      final String next = addTextMarkerAtProgramFrame(
        source: source,
        rawLineAtFrame: const <int>[0, 1],
        programFrame: 1,
      );

      expect(next, 'alpha\r\n[MARK:""]\r\nbeta\r\n');
      expect(next.replaceAll('\r\n', '').contains('\n'), isFalse);
    });
  });
}
