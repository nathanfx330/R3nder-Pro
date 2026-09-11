// ./lib/edit_source_history.dart
//
// Transient undo/redo history for the source-backed EDIT surface.
//
// History never becomes project state. Each entry restores one exact complete
// authored script snapshot. It may also retain transient UI restoration
// metadata, such as the clip selection that was active at that moment, because
// selection is view state rather than authored creative state.
//
// The boundary is strict: the only project state history may restore is the
// exact authored source snapshot. History must never reconstruct, invert, or
// independently model CLIP state. Restoring history therefore means restoring
// canonical source text, then restoring useful transient view context around
// that text.

class EditSourceSnapshot {
  final String source;
  final String? selectedTrackId;
  final String? selectedClipId;

  const EditSourceSnapshot({
    required this.source,
    required this.selectedTrackId,
    required this.selectedClipId,
  });
}

class EditSourceHistory {
  final int maxEntries;
  final List<EditSourceSnapshot> _undo = <EditSourceSnapshot>[];
  final List<EditSourceSnapshot> _redo = <EditSourceSnapshot>[];

  EditSourceHistory({this.maxEntries = 100}) {
    if (maxEntries <= 0) {
      throw ArgumentError.value(
        maxEntries,
        'maxEntries',
        'EDIT history must retain at least one entry.',
      );
    }
  }

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  int get undoDepth => _undo.length;
  int get redoDepth => _redo.length;

  void record(EditSourceSnapshot before) {
    _undo.add(before);
    _trimOldest(_undo);
    _redo.clear();
  }

  EditSourceSnapshot? undo(EditSourceSnapshot current) {
    if (_undo.isEmpty) return null;
    final EditSourceSnapshot target = _undo.removeLast();
    _redo.add(current);
    _trimOldest(_redo);
    return target;
  }

  EditSourceSnapshot? redo(EditSourceSnapshot current) {
    if (_redo.isEmpty) return null;
    final EditSourceSnapshot target = _redo.removeLast();
    _undo.add(current);
    _trimOldest(_undo);
    return target;
  }

  void clear() {
    _undo.clear();
    _redo.clear();
  }

  void _trimOldest(List<EditSourceSnapshot> entries) {
    while (entries.length > maxEntries) {
      entries.removeAt(0);
    }
  }
}
