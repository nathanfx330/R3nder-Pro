// ./lib/mosaic_trim_impact.dart

import 'edit_cue.dart';
import 'edit_model.dart';
import 'mosaic_trim.dart';
import 'structural_sequence.dart';

/// A direct consumer whose authored source requests exceed the trimmed source.
class MosaicTrimConsumerOverrun {
  final String location;
  final int lastSourceFrame;
  final bool alreadyOverran;

  const MosaicTrimConsumerOverrun({
    required this.location,
    required this.lastSourceFrame,
    required this.alreadyOverran,
  });
}

/// The exact pending source edit and its authored effects, before confirmation.
class MosaicTrimImpact {
  final String sourceAfter;
  final int beforeFrames;
  final int afterFrames;
  final int clipsTrimmed;
  final int clipsRemoved;
  final int dormantCues;
  final int removedCues;
  final List<int> placementLines;
  final List<MosaicTrimConsumerOverrun> consumerOverruns;

  MosaicTrimImpact._({
    required this.sourceAfter,
    required this.beforeFrames,
    required this.afterFrames,
    required this.clipsTrimmed,
    required this.clipsRemoved,
    required this.dormantCues,
    required this.removedCues,
    required List<int> placementLines,
    required List<MosaicTrimConsumerOverrun> consumerOverruns,
  })  : placementLines = List<int>.unmodifiable(placementLines),
        consumerOverruns =
            List<MosaicTrimConsumerOverrun>.unmodifiable(consumerOverruns);

  int get framesRemoved => beforeFrames - afterFrames;

  String get summary {
    final StringBuffer out = StringBuffer()
      ..writeln('Composition: $beforeFrames to $afterFrames frames '
          '($framesRemoved removed).')
      ..writeln('Clips trimmed: $clipsTrimmed. Clips removed: $clipsRemoved.')
      ..writeln('Pane cues made dormant: $dormantCues.')
      ..writeln('Cues deleted with removed clips: $removedCues.')
      ..writeln()
      ..writeln('STRUCT placements affected: ${placementLines.length}.');
    if (placementLines.isNotEmpty) {
      out
        ..writeln('Document lines: ${placementLines.join(', ')}.')
        ..writeln('These placements get shorter. Later TEXT timing moves earlier.');
    }
    out
      ..writeln()
      ..writeln('Consumer clips that will overrun: ${consumerOverruns.length}.');
    for (final MosaicTrimConsumerOverrun consumer in consumerOverruns) {
      out.writeln('${consumer.location}: requests frame '
          '${consumer.lastSourceFrame}; source now ends at ${afterFrames - 1}'
          '${consumer.alreadyOverran ? ' (already overran before this trim)' : ''}.');
    }
    out
      ..writeln()
      ..write('Referenced EDITs and consumer clips stay unchanged. '
          'Existing gaps remain.');
    return out.toString();
  }
}

/// Prepares the same pure trim used by the authoring operation. No state is
/// committed here. Cue counts cover cues owned by this MOSAIC's pane clips,
/// matching the structural overlay resolver; referenced EDIT cues are not
/// copied into pane cue ownership. Existing dormant cues are not counted again.
MosaicTrimImpact? previewMosaicTrim(String source, String mosaicId) {
  final String next = trimMosaicToShortest(source, mosaicId);
  if (next == source) return null;
  final EditDocumentModel before = EditDocumentModel.parse(source);
  final EditDocumentModel after = EditDocumentModel.parse(next);
  final MosaicSequence mosaic = before.mosaic(mosaicId);
  final MosaicSequence trimmed = after.mosaic(mosaicId);
  int clipsTrimmed = 0;
  int clipsRemoved = 0;
  int dormantCues = 0;
  int removedCues = 0;

  for (final MosaicPane pane in mosaic.panes) {
    for (final EditClip clip in pane.clips) {
      if (clip.endFrameExclusive <= trimmed.projectFrameCount) continue;
      final List<int> triggers = <int>[
        ...parseClipCardCues(clip).map((EditCardCue cue) => cue.sourceFrame),
        ...parseClipDossierCues(clip).map((EditDossierCue cue) => cue.sourceFrame),
        ...parseClipMaximizeCues(clip).map((EditMaximizeCue cue) => cue.sourceFrame),
      ];
      if (clip.atFrame >= trimmed.projectFrameCount) {
        clipsRemoved++;
        removedCues += triggers.length;
        continue;
      }
      clipsTrimmed++;
      final EditClip nextClip = trimmed.pane(pane.id).clip(clip.id);
      for (final int trigger in triggers) {
        if (cueProjectOffset(clip, trigger) != null &&
            cueProjectOffset(nextClip, trigger) == null) {
          dormantCues++;
        }
      }
    }
  }

  final List<MosaicTrimConsumerOverrun> overruns = <MosaicTrimConsumerOverrun>[];
  void inspectConsumer(String location, EditClip clip) {
    final StructuralSourceRef? ref = StructuralSourceRef.tryParse(clip.source);
    if (ref?.kind != StructuralSourceKind.mosaic || ref?.id != mosaicId) return;
    final int last = clip.sourceFrameAtProjectOffset(clip.durationFrames - 1);
    if (last < trimmed.projectFrameCount) return;
    overruns.add(MosaicTrimConsumerOverrun(
      location: location,
      lastSourceFrame: last,
      alreadyOverran: last >= mosaic.projectFrameCount,
    ));
  }

  // Source order keeps consumer reporting stable across EDIT and MOSAIC roots.
  final List<(int, String, EditClip)> consumers = <(int, String, EditClip)>[
    for (final EditSequence edit in after.edits)
      for (final EditTrack track in edit.tracks)
        for (final EditClip clip in track.clips)
          (clip.block.startOffset, 'EDIT.${edit.id} / ${track.id} / ${clip.id}', clip),
    for (final MosaicSequence item in after.mosaics)
      for (final MosaicPane pane in item.panes)
        for (final EditClip clip in pane.clips)
          (clip.block.startOffset, 'MOSAIC.${item.id} / ${pane.id} / ${clip.id}', clip),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  for (final (_, location, clip) in consumers) {
    inspectConsumer(location, clip);
  }

  return MosaicTrimImpact._(
    sourceAfter: next,
    beforeFrames: mosaic.projectFrameCount,
    afterFrames: trimmed.projectFrameCount,
    clipsTrimmed: clipsTrimmed,
    clipsRemoved: clipsRemoved,
    dormantCues: dormantCues,
    removedCues: removedCues,
    placementLines: <int>[
      for (final StructuralSequencePlacement placement
          in parseStructuralSequencePlacements(source))
        if (placement.sourceRef.kind == StructuralSourceKind.mosaic &&
            placement.sourceRef.id == mosaicId)
          placement.lineIndex + 1,
    ],
    consumerOverruns: overruns,
  );
}
