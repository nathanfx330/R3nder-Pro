// ./lib/edit_linter.dart
//
// Structural graph validation for EDIT and MOSAIC sources.
//
// Rendering code must never discover recursion policy while it is painting.
// Structural CLIP sources are named EDIT.<id> or MOSAIC.<id>. This linter owns
// reference validation, cycle detection, and the maximum nesting depth across
// both namespaces before the compositor evaluates anything.
//
// CLIP suffix vocabulary is also linted here. Unknown suffixes are warnings,
// never parse failures: source preservation allows a newer script to round trip
// through an older build without silently pretending an unknown key worked.

import 'edit_cue.dart';
import 'edit_model.dart';
import 'presentation_requests.dart';
import 'structural_sequence.dart';

enum EditLintSeverity {
  warning,
  error,
}

enum EditLintCode {
  missingEditSource,
  missingMosaicSource,
  cycle,
  nestingLimit,
  unknownClipOption,
  unsupportedSplitPlacement,
  unsupportedSplitSideCard,
  unsupportedSplitMaximize,
}

class EditLintIssue {
  final EditLintCode code;
  final EditLintSeverity severity;
  final String message;
  final List<String> editPath;

  const EditLintIssue({
    required this.code,
    this.severity = EditLintSeverity.error,
    required this.message,
    required this.editPath,
  });
}

class EditLintResult {
  final List<EditLintIssue> issues;

  const EditLintResult(this.issues);

  bool get isValid => issues.every(
        (EditLintIssue issue) => issue.severity != EditLintSeverity.error,
      );

  Iterable<EditLintIssue> get warnings => issues.where(
        (EditLintIssue issue) => issue.severity == EditLintSeverity.warning,
      );

  Iterable<EditLintIssue> get errors => issues.where(
        (EditLintIssue issue) => issue.severity == EditLintSeverity.error,
      );
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

    // Warnings are appended after graph errors so legacy callers that display
    // the first issue continue to lead with blocking structural failures.
    for (final StructuralSourceRef node in nodes) {
      for (final EditClip clip in document.clipsForStructuralSource(node)) {
        for (final String rawToken in clip.unknownOptionTokens) {
          final String key = _clipOptionKey(rawToken);
          emit(
            EditLintIssue(
              code: EditLintCode.unknownClipOption,
              severity: EditLintSeverity.warning,
              message: 'CLIP "${clip.id}" has unknown option "$key".',
              editPath: <String>[node.graphLabel, clip.id],
            ),
          );
        }
      }
    }

    void lintSplitCueClip(
      EditClip clip, {
      required StructuralSourceRef splitRoot,
      required String splitPaneId,
      required List<String> nestedPath,
      required Set<StructuralSourceRef> path,
    }) {
      bool hasSideCard = false;
      bool hasMaximize = false;
      try {
        hasSideCard = parseClipCardCues(clip).any(
          (EditCardCue cue) => cue.card is SideCardRequest,
        );
      } catch (_) {
        // Malformed cue syntax belongs to the cue/script lint layer.
      }
      try {
        hasMaximize = parseClipMaximizeCues(clip).isNotEmpty;
      } catch (_) {
        // Malformed cue syntax belongs to the cue/script lint layer.
      }

      final List<String> issuePath = <String>[
        'STRUCT',
        splitRoot.canonicalSource,
        'PANE.$splitPaneId',
        ...nestedPath,
        clip.id,
      ];

      if (hasSideCard) {
        emit(
          EditLintIssue(
            code: EditLintCode.unsupportedSplitSideCard,
            severity: EditLintSeverity.warning,
            message: 'SIDECARD reachable from PANE "$splitPaneId" is not '
                'supported by STRUCT ${splitRoot.canonicalSource} SPLIT v1 '
                'and will not paint.',
            editPath: issuePath,
          ),
        );
      }

      if (hasMaximize) {
        emit(
          EditLintIssue(
            code: EditLintCode.unsupportedSplitMaximize,
            severity: EditLintSeverity.warning,
            message: 'MAXIMIZE reachable from PANE "$splitPaneId" is not '
                'supported by STRUCT ${splitRoot.canonicalSource} SPLIT v1 '
                'and will not paint.',
            editPath: issuePath,
          ),
        );
      }

      final StructuralSourceRef? nested =
          StructuralSourceRef.tryParse(clip.source);
      if (nested == null ||
          nested.id.isEmpty ||
          !document.containsStructuralSource(nested) ||
          path.contains(nested)) {
        return;
      }

      final Set<StructuralSourceRef> nestedSet =
          <StructuralSourceRef>{...path, nested};
      switch (nested.kind) {
        case StructuralSourceKind.edit:
          final EditSequence edit = document.edit(nested.id);
          for (final EditTrack track in edit.tracks) {
            for (final EditClip child in track.clips) {
              lintSplitCueClip(
                child,
                splitRoot: splitRoot,
                splitPaneId: splitPaneId,
                nestedPath: <String>[
                  ...nestedPath,
                  nested.canonicalSource,
                  'TRACK.${track.id}',
                ],
                path: nestedSet,
              );
            }
          }
          break;

        case StructuralSourceKind.mosaic:
          final MosaicSequence mosaic = document.mosaic(nested.id);
          for (final MosaicPane pane in mosaic.panes) {
            for (final EditClip child in pane.clips) {
              lintSplitCueClip(
                child,
                splitRoot: splitRoot,
                splitPaneId: splitPaneId,
                nestedPath: <String>[
                  ...nestedPath,
                  nested.canonicalSource,
                  'PANE.${pane.id}',
                ],
                path: nestedSet,
              );
            }
          }
          break;
      }
    }

    for (final StructuralSequencePlacement placement
        in parseStructuralSequencePlacements(document.cst.source)) {
      if (!placement.splitWindow) continue;

      final StructuralSourceRef ref = placement.sourceRef;
      if (ref.kind != StructuralSourceKind.mosaic ||
          !document.containsStructuralSource(ref)) {
        continue;
      }

      final MosaicSequence mosaic = document.mosaic(ref.id);
      for (final MosaicPane pane in mosaic.panes) {
        for (final EditClip clip in pane.clips) {
          lintSplitCueClip(
            clip,
            splitRoot: ref,
            splitPaneId: pane.id,
            nestedPath: const <String>[],
            path: <StructuralSourceRef>{ref},
          );
        }
      }
    }

    for (final StructuralSequencePlacement placement
        in parseStructuralSequencePlacements(document.cst.source)) {
      if (!placement.splitWindowRequested || placement.splitWindowSupported) {
        continue;
      }

      final StructuralSourceRef ref = placement.sourceRef;
      String reason;
      if (!document.containsStructuralSource(ref)) {
        reason = 'the source does not resolve';
      } else if (ref.kind != StructuralSourceKind.mosaic) {
        reason = 'the source is not a MOSAIC';
      } else {
        final MosaicSequence mosaic = document.mosaic(ref.id);
        if (mosaic.panes.length != 2) {
          reason = 'the MOSAIC has ${mosaic.panes.length} panes instead of 2';
        } else {
          final int empty = mosaic.panes
              .where((MosaicPane pane) => pane.clips.isEmpty)
              .length;
          reason = empty == 1
              ? 'one MOSAIC pane is empty'
              : '$empty MOSAIC panes are empty';
        }
      }

      emit(
        EditLintIssue(
          code: EditLintCode.unsupportedSplitPlacement,
          severity: EditLintSeverity.warning,
          message: 'STRUCT ${ref.canonicalSource} requests SPLIT, but $reason; '
              'ordinary windowed presentation will be used.',
          editPath: <String>['STRUCT', ref.canonicalSource],
        ),
      );
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

String _clipOptionKey(String rawToken) {
  final String token = rawToken.trim();
  final int equals = token.indexOf('=');
  if (equals <= 0) return token;
  return token.substring(0, equals).trim();
}
