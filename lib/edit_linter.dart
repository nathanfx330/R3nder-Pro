// ./lib/edit_linter.dart
//
// Structural graph validation for EDIT sources.
//
// Rendering code must never discover recursion policy while it is painting.
// Nested edit references are represented by CLIP sources named EDIT.<id>. This
// linter owns reference validation, cycle detection, and the maximum nesting
// depth before nested edits become renderable in M11.

import 'edit_model.dart';

enum EditLintCode {
  missingEditSource,
  cycle,
  nestingLimit,
}

class EditLintIssue {
  final EditLintCode code;
  final String message;
  final List<String> editPath;

  const EditLintIssue({
    required this.code,
    required this.message,
    required this.editPath,
  });
}

class EditLintResult {
  final List<EditLintIssue> issues;

  const EditLintResult(this.issues);

  bool get isValid => issues.isEmpty;
}

class EditGraphLinter {
  static const int defaultMaxNesting = 8;

  static EditLintResult lint(
    EditDocumentModel document, {
    int maxNesting = defaultMaxNesting,
  }) {
    if (maxNesting <= 0) {
      throw ArgumentError.value(
        maxNesting,
        'maxNesting',
        'Maximum EDIT nesting must be positive.',
      );
    }

    final Map<String, EditSequence> edits = <String, EditSequence>{
      for (final EditSequence edit in document.edits) edit.id: edit,
    };
    final Map<String, List<String>> edges = <String, List<String>>{};

    for (final EditSequence edit in document.edits) {
      final List<String> targets = <String>[];
      for (final EditTrack track in edit.tracks) {
        for (final EditClip clip in track.clips) {
          final String? target = nestedEditId(clip.source);
          if (target != null) targets.add(target);
        }
      }
      edges[edit.id] = List<String>.unmodifiable(targets);
    }

    final List<EditLintIssue> issues = <EditLintIssue>[];
    final Set<String> emitted = <String>{};

    void emit(EditLintIssue issue) {
      final String key =
          '${issue.code.name}:${issue.editPath.join('>')}:${issue.message}';
      if (emitted.add(key)) issues.add(issue);
    }

    void walk(String editId, List<String> path) {
      final List<String> nextPath = <String>[...path, editId];
      if (nextPath.length > maxNesting) {
        emit(
          EditLintIssue(
            code: EditLintCode.nestingLimit,
            message: 'EDIT nesting exceeds the limit of $maxNesting.',
            editPath: List<String>.unmodifiable(nextPath),
          ),
        );
        return;
      }

      for (final String target in edges[editId] ?? const <String>[]) {
        if (!edits.containsKey(target)) {
          emit(
            EditLintIssue(
              code: EditLintCode.missingEditSource,
              message: 'EDIT "$editId" references missing EDIT "$target".',
              editPath: List<String>.unmodifiable(<String>[...nextPath, target]),
            ),
          );
          continue;
        }

        final int cycleAt = nextPath.indexOf(target);
        if (cycleAt >= 0) {
          final List<String> cyclePath = <String>[
            ...nextPath.sublist(cycleAt),
            target,
          ];
          emit(
            EditLintIssue(
              code: EditLintCode.cycle,
              message: 'EDIT source cycle: ${cyclePath.join(' -> ')}.',
              editPath: List<String>.unmodifiable(cyclePath),
            ),
          );
          continue;
        }

        walk(target, nextPath);
      }
    }

    for (final String editId in edits.keys) {
      walk(editId, const <String>[]);
    }

    return EditLintResult(List<EditLintIssue>.unmodifiable(issues));
  }

  static String? nestedEditId(String source) {
    if (!source.startsWith('EDIT.')) return null;
    final String id = source.substring('EDIT.'.length).trim();
    return id.isEmpty ? '' : id;
  }
}
