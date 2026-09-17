// ./lib/project_media_references.dart
//
// Read-only authored-reference projection for the project media bin.
//
// The filesystem bin answers "what files exist?" This layer answers the
// separate question "what video/ sources does structural authoring reference?"
// Keeping those questions separate lets the UI derive OFFLINE state without
// inventing missing ProjectMediaItem records or mutating source.

import 'edit_model.dart';

class ProjectMediaReference {
  final String authoredSource;
  final String structuralSource;
  final String laneId;
  final String clipId;

  const ProjectMediaReference({
    required this.authoredSource,
    required this.structuralSource,
    required this.laneId,
    required this.clipId,
  });

  bool get belongsToEdit => structuralSource.startsWith('EDIT.');
}

class ProjectMediaReferenceCatalog {
  final List<ProjectMediaReference> references;

  const ProjectMediaReferenceCatalog._(this.references);

  const ProjectMediaReferenceCatalog.empty()
    : references = const <ProjectMediaReference>[];

  List<ProjectMediaReference> referencesFor(String authoredSource) =>
      List<ProjectMediaReference>.unmodifiable(
        references.where(
          (ProjectMediaReference reference) =>
              reference.authoredSource == authoredSource,
        ),
      );

  List<String> get authoredSources {
    final Set<String> seen = <String>{};
    final List<String> out = <String>[];
    for (final ProjectMediaReference reference in references) {
      if (seen.add(reference.authoredSource)) {
        out.add(reference.authoredSource);
      }
    }
    return List<String>.unmodifiable(out);
  }
}

ProjectMediaReferenceCatalog projectMediaReferences(EditDocumentModel model) {
  final List<ProjectMediaReference> references = <ProjectMediaReference>[];

  void addClip({
    required String structuralSource,
    required String laneId,
    required EditClip clip,
  }) {
    // Structural CLIPs reference another EDIT/MOSAIC, not a file. The media bin
    // also deliberately projects only the workspace video/ namespace; direct
    // paths outside that namespace remain valid authored source but do not
    // masquerade as missing project-bin media.
    if (StructuralSourceRef.tryParse(clip.source) != null ||
        !clip.source.startsWith('video/')) {
      return;
    }
    references.add(
      ProjectMediaReference(
        authoredSource: clip.source,
        structuralSource: structuralSource,
        laneId: laneId,
        clipId: clip.id,
      ),
    );
  }

  for (final EditSequence edit in model.edits) {
    for (final EditTrack track in edit.tracks) {
      for (final EditClip clip in track.clips) {
        addClip(
          structuralSource: 'EDIT.${edit.id}',
          laneId: track.id,
          clip: clip,
        );
      }
    }
  }

  for (final MosaicSequence mosaic in model.mosaics) {
    for (final MosaicPane pane in mosaic.panes) {
      for (final EditClip clip in pane.clips) {
        addClip(
          structuralSource: 'MOSAIC.${mosaic.id}',
          laneId: pane.id,
          clip: clip,
        );
      }
    }
  }

  return ProjectMediaReferenceCatalog._(
    List<ProjectMediaReference>.unmodifiable(references),
  );
}
