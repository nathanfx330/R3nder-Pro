# Media Bin Phase 0 Journey

Phase 0 began as preparation for a media-bin quality-of-life feature. The intended user flow was simple: expose the workspace `video/` folder as thumbnails, let Edit Mode drag those assets into the timeline, and let Text Mode attach video to authored text.

Inspection showed that the architecture already supported most of that goal. The missing feature was not a second video-cue system. It was an ergonomics gap in front of systems that already existed.

## The grammar collision

The first proposal used a TEXT-level `CUE VIDEO` concept. Inspection stopped that early. `CUE` already means clip-local, source-relative triggers inside a CLIP, while `VIDEO` already names the image-sequence construct. Reusing either word at a new scope would make the script grammar ambiguous.

The existing relationship was already the correct one: TEXT references `[STRUCT:EDIT.<id>]`; the EDIT owns the CLIP; the CLIP owns media source, source in, project duration, and speed. A future Attach Media gesture should therefore create a one-clip EDIT and append the STRUCT reference rather than invent another authored representation.

## The bootstrap blocker

The next inspection found that `createEditWithClip` was not a general EDIT creator. It explicitly refused a document that already contained any EDIT blocks. That made it unsuitable for future Text Mode attachment, where a project may already contain several EDITs and the gesture must create a fresh one.

Phase 0 therefore retires the bootstrap writer. Empty EDIT creation and CLIP insertion are composed from separate operations, and every CLIP is authored through `EditSurfaceDocument.addClip`.

## One timing conversion

Import already conformed source rate into exact rational CLIP speed, but the whole-file project duration used a separate ceiling expression. Source-range attachment would have needed the same arithmetic again.

Phase 0 replaces that duplication with `sourceSpanToProjectFrames`. Whole-file import and partial source ranges now use the same conversion. `ImportedEditVideo` also retains the exact probed source-frame length so in/out validation never has to reconstruct it from a rounded project duration.

The ceiling is deliberate. A final project frame may address fractionally beyond the requested source range and clamp at the source edge, matching the existing whole-file import behavior.

## The wrong no-overlap invariant

During review we proposed a stronger rule: clips on a track should never overlap. We agreed on it and briefly treated it as locked architecture.

The existing fixtures disproved it.

Crossfades are authored as overlap. The transition operation moves the right clip backward by the transition length, and transition directives declare how that overlapping region is composited. Existing tests contained the geometry plainly: adjacent clips deliberately overlap by the authored crossfade frame count.

The important lesson was not merely that the proposed invariant was wrong. The correction came from reading fixtures rather than continuing to reason from the API surface. That is a repeatable forensic move for this codebase: when a proposed invariant affects composition, inspect authored fixtures before promoting it into validation.

The Phase 0 rule is therefore narrower. Parsing remains permissive. Direct manipulation remains able to create the overlap transition authoring already depends on. Only a plain media-placement gesture rejects occupied project frames because that gesture carries no transition intent.

A stricter future rule could distinguish declared transition overlap from undeclared overlap, but that requires an atomic transition design and does not belong in the media-bin roadmap.

## The hidden transport coupling

Applying the placement rule exposed one more behavior that had not been part of the original plan. `ADD VIDEO` used the current playhead as its insertion frame. Once plain placement rejected occupied frames, parking the playhead inside a shot and then adding another video would fail.

That coupling was invisible because the button itself has no spatial placement gesture. Phase 0 changes `ADD VIDEO` on V1 to append at the maximum `endFrameExclusive` of the target track. Document order is not assumed to be time order, and existing crossfade overlap is preserved. `ADD OVERLAY` keeps its established playhead behavior on V2.

This is the only intentional user-visible behavior change in Phase 0:

> Add Video appends. Drag will place.

Future bin drag-and-drop will supply its frame from the cursor. Future Text Mode attachment will supply its position from that workflow. The shared placement primitive does not infer any of those UI intentions.

## What Phase 0 leaves behind

The result is a single deterministic media-placement path:

- `ExactClipSpeed.unity` provides a compile-time unity value.
- `ImportedEditVideo` retains exact source length.
- `sourceSpanToProjectFrames` is the one source-to-project duration conversion.
- `conformWorkspaceMedia` separates probe/conform from copy/import.
- `appendEmptyEdit` creates a new EDIT without assuming the document is empty.
- `uniqueEditId` owns EDIT collision walking.
- `addClip` can author source in and conformed speed in one rewrite.
- `placeMediaInEdit` owns target EDIT creation, CLIP-id collision handling, range validation, and plain-placement occupancy rejection.
- `ADD VIDEO` appends to V1 rather than borrowing transport position.

The feature was never a missing video-cue system. It was an ergonomics gap in front of an architecture that already did the job.
