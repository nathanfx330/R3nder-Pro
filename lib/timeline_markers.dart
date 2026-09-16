// ./lib/timeline_markers.dart
//
// Pure projection of authored MARK definitions and derived EDIT landmarks onto
// visible timeline coordinates.
//
// A definition is authored once. An instance is where that definition appears
// in a particular timeline. This distinction is load-bearing: one reusable
// EDIT placed twice in TEXT produces two program instances of the same marker
// definition and no duplicate authored state.

import 'edit_cue.dart';
import 'edit_model.dart';
import 'marker_language.dart';
import 'structural_sequence.dart';

class MarkerInstance {
  final MarkerDefinition definition;
  final int frame;

  /// Null in a source-local EDIT/MOSAIC view. In TEXT program projection this
  /// is the executable STRUCT placement that produced the instance.
  final int? placementIndex;

  const MarkerInstance({
    required this.definition,
    required this.frame,
    this.placementIndex,
  });

  MarkerAddress get address => definition.address;
  String get label => definition.label;
}

enum DerivedLandmarkKind {
  cue,
  clipIn,
  clipOut,
}

/// UI-only timing truth derived from authored EDIT/CUE state.
///
/// There is intentionally no corresponding authored definition type. CUE and
/// clip boundaries therefore cannot accidentally be serialized as duplicate
/// project state merely because a timeline chooses to draw them.
class DerivedLandmark {
  final DerivedLandmarkKind kind;
  final int frame;
  final String label;
  final String? rootType;
  final String? rootId;
  final String? containerId;
  final String? clipId;
  final int? placementIndex;

  const DerivedLandmark({
    required this.kind,
    required this.frame,
    required this.label,
    this.rootType,
    this.rootId,
    this.containerId,
    this.clipId,
    this.placementIndex,
  });

  DerivedLandmark atProgramFrame(int programFrame, int placement) {
    return DerivedLandmark(
      kind: kind,
      frame: programFrame,
      label: label,
      rootType: rootType,
      rootId: rootId,
      containerId: containerId,
      clipId: clipId,
      placementIndex: placement,
    );
  }
}

class ProgramTimelineLandmarks {
  final List<MarkerInstance> markers;
  final List<DerivedLandmark> derived;

  const ProgramTimelineLandmarks({
    required this.markers,
    required this.derived,
  });
}

/// Projects positional TEXT markers through the editor's raw-line simulation.
///
/// A TEXT MARK owns no frame count. Its first program frame is the first frame
/// whose execution line has reached the marker's authored line. Consecutive
/// zero-time markers therefore naturally share one frame.
List<MarkerInstance> projectTextMarkerInstances(
  String rawDocument,
  List<int> rawLineAtFrame,
) {
  final List<MarkerInstance> out = <MarkerInstance>[];
  for (final MarkerDefinition marker in parseMarkerDefinitions(rawDocument)) {
    if (!marker.isText) continue;
    out.add(
      MarkerInstance(
        definition: marker,
        frame: _programFrameForTextMarker(marker, rawLineAtFrame),
      ),
    );
  }
  return List<MarkerInstance>.unmodifiable(out);
}

/// Projects authored markers belonging to one reusable EDIT onto EDIT sequence
/// frames. Direct EDIT markers already use this coordinate system. CLIP markers
/// are source-relative and are mapped through the exact authored clip speed.
List<MarkerInstance> projectEditMarkerInstances(
  String rawDocument,
  String editId,
) {
  final EditDocumentModel model = EditDocumentModel.parse(rawDocument);
  final EditSequence edit = model.edit(editId);
  final List<MarkerDefinition> definitions = parseMarkerDefinitions(rawDocument);
  return _markerInstancesForEdit(edit, definitions);
}

/// Derived CUE and clip-boundary landmarks for one EDIT sequence.
List<DerivedLandmark> derivedLandmarksForEdit(
  String rawDocument,
  String editId,
) {
  final EditDocumentModel model = EditDocumentModel.parse(rawDocument);
  return _derivedForEdit(model.edit(editId));
}

/// Complete TEXT-program projection.
///
/// Top-level TEXT markers are positioned from the raw line map. Markers and
/// derived landmarks inside reusable structural sources are first projected to
/// source-local frames, then instantiated once for every executable STRUCT
/// placement of that source. This is the one-to-many definition/instance
/// contract in executable form.
ProgramTimelineLandmarks projectProgramTimelineLandmarks({
  required String rawDocument,
  required List<int> rawLineAtFrame,
}) {
  final List<MarkerDefinition> definitions = parseMarkerDefinitions(rawDocument);
  final List<MarkerInstance> markers = <MarkerInstance>[];
  final List<DerivedLandmark> derived = <DerivedLandmark>[];

  for (final MarkerDefinition marker in definitions) {
    if (!marker.isText) continue;
    markers.add(
      MarkerInstance(
        definition: marker,
        frame: _programFrameForTextMarker(marker, rawLineAtFrame),
      ),
    );
  }

  EditDocumentModel? model;
  try {
    model = EditDocumentModel.parse(rawDocument);
  } catch (_) {
    // TEXT is also a repair surface. Top-level markers remain useful even when
    // structural source is malformed; nested projection simply waits until the
    // structural model parses again.
    return ProgramTimelineLandmarks(
      markers: List<MarkerInstance>.unmodifiable(markers),
      derived: const <DerivedLandmark>[],
    );
  }

  final List<StructuralSequencePlacement> placements =
      parseStructuralSequencePlacements(rawDocument);

  for (int placementIndex = 0;
      placementIndex < placements.length;
      placementIndex++) {
    final StructuralSequencePlacement placement = placements[placementIndex];
    final int? eventStart =
        _firstFrameForExactLine(rawLineAtFrame, placement.lineIndex);
    if (eventStart == null || !placement.resolves) continue;

    late final List<MarkerInstance> localMarkers;
    late final List<DerivedLandmark> localDerived;

    switch (placement.sourceRef.kind) {
      case StructuralSourceKind.edit:
        final EditSequence edit = model.edit(placement.sourceRef.id);
        localMarkers = _markerInstancesForEdit(edit, definitions);
        localDerived = _derivedForEdit(edit);
        break;
      case StructuralSourceKind.mosaic:
        final MosaicSequence mosaic = model.mosaic(placement.sourceRef.id);
        localMarkers = _markerInstancesForMosaic(mosaic, definitions);
        localDerived = _derivedForMosaic(mosaic);
        break;
    }

    for (final MarkerInstance local in localMarkers) {
      if (local.frame < 0 || local.frame > placement.sourceDurationFrames) {
        continue;
      }
      markers.add(
        MarkerInstance(
          definition: local.definition,
          frame: eventStart + placement.contentStartFrame + local.frame,
          placementIndex: placementIndex,
        ),
      );
    }

    for (final DerivedLandmark local in localDerived) {
      if (local.frame < 0 || local.frame > placement.sourceDurationFrames) {
        continue;
      }
      derived.add(
        local.atProgramFrame(
          eventStart + placement.contentStartFrame + local.frame,
          placementIndex,
        ),
      );
    }
  }

  markers.sort((MarkerInstance a, MarkerInstance b) {
    final int byFrame = a.frame.compareTo(b.frame);
    if (byFrame != 0) return byFrame;
    return a.address.documentOrder.compareTo(b.address.documentOrder);
  });
  derived.sort((DerivedLandmark a, DerivedLandmark b) {
    final int byFrame = a.frame.compareTo(b.frame);
    if (byFrame != 0) return byFrame;
    return a.kind.index.compareTo(b.kind.index);
  });

  return ProgramTimelineLandmarks(
    markers: List<MarkerInstance>.unmodifiable(markers),
    derived: List<DerivedLandmark>.unmodifiable(derived),
  );
}

List<MarkerInstance> _markerInstancesForEdit(
  EditSequence edit,
  List<MarkerDefinition> definitions,
) {
  final List<MarkerInstance> out = <MarkerInstance>[];

  for (final MarkerDefinition marker in definitions) {
    if (marker.isEdit &&
        marker.rootType == 'EDIT' &&
        marker.rootId == edit.id) {
      out.add(
        MarkerInstance(
          definition: marker,
          frame: marker.localFrame!,
        ),
      );
      continue;
    }

    if (!marker.isClip ||
        marker.rootType != 'EDIT' ||
        marker.rootId != edit.id) {
      continue;
    }

    final EditClip? clip = _findEditClip(
      edit,
      marker.containerId,
      marker.clipId,
    );
    if (clip == null) continue;
    final int? frame = sourceFrameToProjectFrame(clip, marker.localFrame!);
    if (frame == null) continue;
    out.add(MarkerInstance(definition: marker, frame: frame));
  }

  out.sort((MarkerInstance a, MarkerInstance b) {
    final int byFrame = a.frame.compareTo(b.frame);
    if (byFrame != 0) return byFrame;
    return a.address.documentOrder.compareTo(b.address.documentOrder);
  });
  return List<MarkerInstance>.unmodifiable(out);
}

List<MarkerInstance> _markerInstancesForMosaic(
  MosaicSequence mosaic,
  List<MarkerDefinition> definitions,
) {
  final List<MarkerInstance> out = <MarkerInstance>[];
  for (final MarkerDefinition marker in definitions) {
    if (!marker.isClip ||
        marker.rootType != 'MOSAIC' ||
        marker.rootId != mosaic.id) {
      continue;
    }

    final EditClip? clip = _findMosaicClip(
      mosaic,
      marker.containerId,
      marker.clipId,
    );
    if (clip == null) continue;
    final int? frame = sourceFrameToProjectFrame(clip, marker.localFrame!);
    if (frame == null) continue;
    out.add(MarkerInstance(definition: marker, frame: frame));
  }

  out.sort((MarkerInstance a, MarkerInstance b) {
    final int byFrame = a.frame.compareTo(b.frame);
    if (byFrame != 0) return byFrame;
    return a.address.documentOrder.compareTo(b.address.documentOrder);
  });
  return List<MarkerInstance>.unmodifiable(out);
}

List<DerivedLandmark> _derivedForEdit(EditSequence edit) {
  final List<DerivedLandmark> out = <DerivedLandmark>[];
  for (final EditTrack track in edit.tracks) {
    for (final EditClip clip in track.clips) {
      out.addAll(
        _derivedForClip(
          clip,
          rootType: 'EDIT',
          rootId: edit.id,
          containerId: track.id,
        ),
      );
    }
  }
  return _sortedDerived(out);
}

List<DerivedLandmark> _derivedForMosaic(MosaicSequence mosaic) {
  final List<DerivedLandmark> out = <DerivedLandmark>[];
  for (final MosaicPane pane in mosaic.panes) {
    for (final EditClip clip in pane.clips) {
      out.addAll(
        _derivedForClip(
          clip,
          rootType: 'MOSAIC',
          rootId: mosaic.id,
          containerId: pane.id,
        ),
      );
    }
  }
  return _sortedDerived(out);
}

List<DerivedLandmark> _derivedForClip(
  EditClip clip, {
  required String rootType,
  required String rootId,
  required String containerId,
}) {
  final List<DerivedLandmark> out = <DerivedLandmark>[
    DerivedLandmark(
      kind: DerivedLandmarkKind.clipIn,
      frame: clip.atFrame,
      label: '${clip.id} IN',
      rootType: rootType,
      rootId: rootId,
      containerId: containerId,
      clipId: clip.id,
    ),
    DerivedLandmark(
      kind: DerivedLandmarkKind.clipOut,
      frame: clip.endFrameExclusive,
      label: '${clip.id} OUT',
      rootType: rootType,
      rootId: rootId,
      containerId: containerId,
      clipId: clip.id,
    ),
  ];

  try {
    for (final EditCardCue cue in parseClipCardCues(clip)) {
      final int? frame = sourceFrameToProjectFrame(clip, cue.sourceFrame);
      if (frame == null) continue;
      out.add(
        DerivedLandmark(
          kind: DerivedLandmarkKind.cue,
          frame: frame,
          label: cue.isSideCard ? 'SIDECARD CUE' : 'CARD CUE',
          rootType: rootType,
          rootId: rootId,
          containerId: containerId,
          clipId: clip.id,
        ),
      );
    }
    for (final EditDossierCue cue in parseClipDossierCues(clip)) {
      final int? frame = sourceFrameToProjectFrame(clip, cue.sourceFrame);
      if (frame == null) continue;
      out.add(
        DerivedLandmark(
          kind: DerivedLandmarkKind.cue,
          frame: frame,
          label: 'DOSSIER CUE',
          rootType: rootType,
          rootId: rootId,
          containerId: containerId,
          clipId: clip.id,
        ),
      );
    }
  } catch (_) {
    // A malformed CUE must not hide clip IN/OUT diagnostic truth. The EDIT
    // inspector reports the CUE formatting problem through its normal path.
  }

  return out;
}

List<DerivedLandmark> _sortedDerived(List<DerivedLandmark> input) {
  input.sort((DerivedLandmark a, DerivedLandmark b) {
    final int byFrame = a.frame.compareTo(b.frame);
    if (byFrame != 0) return byFrame;
    final int byKind = a.kind.index.compareTo(b.kind.index);
    if (byKind != 0) return byKind;
    return (a.clipId ?? '').compareTo(b.clipId ?? '');
  });
  return List<DerivedLandmark>.unmodifiable(input);
}

/// Same exact source-to-project mapping CUE uses, exposed here as marker
/// semantics rather than borrowing CUE presentation state.
int? sourceFrameToProjectFrame(EditClip clip, int sourceFrame) {
  final int sourceDelta = sourceFrame - clip.inFrame;
  if (sourceDelta < 0) return null;

  final int numerator = clip.speed.numerator;
  final int denominator = clip.speed.denominator;
  final int projectOffset =
      (sourceDelta * denominator + numerator - 1) ~/ numerator;
  if (projectOffset < 0 || projectOffset >= clip.durationFrames) return null;
  return clip.atFrame + projectOffset;
}

int _programFrameForTextMarker(
  MarkerDefinition marker,
  List<int> rawLineAtFrame,
) {
  for (int frame = 0; frame < rawLineAtFrame.length; frame++) {
    if (rawLineAtFrame[frame] >= marker.address.lineIndex) return frame;
  }
  return rawLineAtFrame.length;
}

int? _firstFrameForExactLine(List<int> rawLineAtFrame, int line) {
  for (int frame = 0; frame < rawLineAtFrame.length; frame++) {
    if (rawLineAtFrame[frame] == line) return frame;
  }
  return null;
}

EditClip? _findEditClip(
  EditSequence edit,
  String? trackId,
  String? clipId,
) {
  if (trackId == null || clipId == null) return null;
  for (final EditTrack track in edit.tracks) {
    if (track.id != trackId) continue;
    for (final EditClip clip in track.clips) {
      if (clip.id == clipId) return clip;
    }
  }
  return null;
}

EditClip? _findMosaicClip(
  MosaicSequence mosaic,
  String? paneId,
  String? clipId,
) {
  if (paneId == null || clipId == null) return null;
  for (final MosaicPane pane in mosaic.panes) {
    if (pane.id != paneId) continue;
    for (final EditClip clip in pane.clips) {
      if (clip.id == clipId) return clip;
    }
  }
  return null;
}
