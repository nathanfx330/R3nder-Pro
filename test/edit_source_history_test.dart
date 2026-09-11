// ./test/edit_source_history_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_source_history.dart';

EditSourceSnapshot _snapshot(
  String source, {
  String? track,
  String? clip,
}) {
  return EditSourceSnapshot(
    source: source,
    selectedTrackId: track,
    selectedClipId: clip,
  );
}

void main() {
  test('undo and redo restore exact source and selection snapshots', () {
    final EditSourceHistory history = EditSourceHistory();
    final EditSourceSnapshot before = _snapshot(
      'before\n',
      track: 'V1',
      clip: 'intro',
    );
    final EditSourceSnapshot after = _snapshot('after\n');

    history.record(before);
    final EditSourceSnapshot? undone = history.undo(after);

    expect(undone, isNotNull);
    expect(undone!.source, 'before\n');
    expect(undone.selectedTrackId, 'V1');
    expect(undone.selectedClipId, 'intro');
    expect(history.canRedo, isTrue);

    final EditSourceSnapshot? redone = history.redo(undone);
    expect(redone, isNotNull);
    expect(redone!.source, 'after\n');
    expect(redone.selectedTrackId, isNull);
    expect(redone.selectedClipId, isNull);
  });

  test('recording a new edit after undo clears redo history', () {
    final EditSourceHistory history = EditSourceHistory();
    history.record(_snapshot('a'));
    final EditSourceSnapshot? restored = history.undo(_snapshot('b'));
    expect(restored?.source, 'a');
    expect(history.canRedo, isTrue);

    history.record(_snapshot('a'));

    expect(history.canRedo, isFalse);
    expect(history.canUndo, isTrue);
  });

  test('clear drops both history directions', () {
    final EditSourceHistory history = EditSourceHistory();
    history.record(_snapshot('a'));
    history.undo(_snapshot('b'));
    expect(history.canRedo, isTrue);

    history.clear();

    expect(history.canUndo, isFalse);
    expect(history.canRedo, isFalse);
  });

  test('history retains only the configured number of oldest reachable steps', () {
    final EditSourceHistory history = EditSourceHistory(maxEntries: 2);
    history.record(_snapshot('a'));
    history.record(_snapshot('b'));
    history.record(_snapshot('c'));

    expect(history.undoDepth, 2);
    expect(history.undo(_snapshot('d'))?.source, 'c');
    expect(history.undo(_snapshot('c'))?.source, 'b');
    expect(history.undo(_snapshot('b')), isNull);
  });
}
