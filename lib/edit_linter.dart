// ./lib/edit_linter.dart
//
// Structural graph validation for EDIT and MOSAIC sources.
//
// Rendering code must never discover recursion policy while it is painting.
// Structural CLIP sources are named EDIT.<id> or MOSAIC.<id>. This linter owns
// reference validation, cycle detection, and the maximum nesting depth across
// both namespaces before the compositor evaluates anything.

import 'edit_model.dart';

enum EditLintCode {
  missingEditSource,
  missingMosaicSource,
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
        'Maximum structural source nesting must be positive.',
      );
    }

    final List<StructuralSourceRef> nodes = <StructuralSourceRef>[
      for (final EditSequence edit in document.edits)
        StructuralSourceRef.tryParse('EDIT.${edit.id}')!,
      for (final MosaicSequence mosaic in document.mosaics)
        StructuralSourceRef.tryParse('MOSAIC.${mosaic.id}')!,
    ];
    final Map<StructuralSourceRef, List<StructuralSourceRef>> edges =
        <StructuralSourceRef, List<StructuralSourceRef>>{};

    for (final StructuralSourceRef node in nodes) {
      final List<StructuralSourceRef> targets = <StructuralSourceRef>[];
      for (final EditClip clip in document.clipsForStructuralSource(node)) {
        final StructuralSourceRef? target =
            StructuralSourceRef.tryParse(clip.source);
        if (target != null) targets.add(target);
      }
      edges[node] = List<StructuralSourceRef>.unmodifiable(targets);
    }

    final List<EditLintIssue> issues = <EditLintIssue>[];
    final Set<String> emitted = <String>{};

    void emit(EditLintIssue issue) {
      final String key =
          '${issue.code.name}:${issue.editPath.join('>')}:${issue.message}';
      if (emitted.add(key)) issues.add(issue);
    }

    List<String> displayPath(List<StructuralSourceRef> path) {
      final bool mixed = path.any(
        (StructuralSourceRef ref) => ref.kind == StructuralSourceKind.mosaic,
      );
      if (!mixed) {
        return List<String>.unmodifiable(
          path.map((StructuralSourceRef ref) => ref.id),
        );
      }
      return List<String>.unmodifiable(
        path.map((StructuralSourceRef ref) => ref.graphLabel),
      );
    }

    void walk(
      StructuralSourceRef node,
      List<StructuralSourceRef> path,
    ) {
      final List<StructuralSourceRef> nextPath = <StructuralSourceRef>[
        ...path,
        node,
      ];
      if (nextPath.length > maxNesting) {
        emit(
          EditLintIssue(
            code: EditLintCode.nestingLimit,
            message: 'Structural source nesting exceeds the limit of $maxNesting.',
            editPath: displayPath(nextPath),
          ),
        );
        return;
      }

      for (final StructuralSourceRef target
          in edges[node] ?? const <StructuralSourceRef>[]) {
        if (!document.containsStructuralSource(target)) {
          final bool missingEdit = target.kind == StructuralSourceKind.edit;
          emit(
            EditLintIssue(
              code: missingEdit
                  ? EditLintCode.missingEditSource
                  : EditLintCode.missingMosaicSource,
              message: missingEdit
                  ? 'EDIT "${node.id}" references missing EDIT "${target.id}".'
                  : '${node.graphLabel} references missing MOSAIC "${target.id}".',
              editPath: displayPath(<StructuralSourceRef>[...nextPath, target]),
            ),
          );
          continue;
        }

        final int cycleAt = nextPath.indexOf(target);
        if (cycleAt >= 0) {
          final List<StructuralSourceRef> cyclePath = <StructuralSourceRef>[
            ...nextPath.sublist(cycleAt),
            target,
          ];
          final bool editOnly = cyclePath.every(
            (StructuralSourceRef ref) => ref.kind == StructuralSourceKind.edit,
          );
          emit(
            EditLintIssue(
              code: EditLintCode.cycle,
              message: editOnly
                  ? 'EDIT source cycle: ${cyclePath.map((ref) => ref.id).join(' -> ')}.'
                  : 'Structural source cycle: ${cyclePath.map((ref) => ref.graphLabel).join(' -> ')}.',
              editPath: displayPath(cyclePath),
            ),
          );
          continue;
        }

        walk(target, nextPath);
      }
    }

    for (final StructuralSourceRef node in nodes) {
      walk(node, const <StructuralSourceRef>[]);
    }

    return EditLintResult(List<EditLintIssue>.unmodifiable(issues));
  }

  static String? nestedEditId(String source) {
    final StructuralSourceRef? ref = StructuralSourceRef.tryParse(source);
    if (ref == null || ref.kind != StructuralSourceKind.edit) return null;
    return ref.id;
  }

  static String? nestedMosaicId(String source) {
    final StructuralSourceRef? ref = StructuralSourceRef.tryParse(source);
    if (ref == null || ref.kind != StructuralSourceKind.mosaic) return null;
    return ref.id;
  }
}
