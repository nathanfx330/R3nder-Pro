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

# What followed Phase 0

Phase 0 was deliberately plumbing-first. Once it was locally validated, the rest of the roadmap could be built as projections and gestures in front of the same authored model rather than as new project state.

## Phase 1: `video/` became a projection, not a database

The first visible dependency was not a widget. It was a pure scan of the workspace `video/` directory.

The media bin does not own imports, ordering metadata, tags, or a second asset registry. It reads what is already there. Missing `video/` means an empty bin rather than creating the directory as a side effect. The scan is nonrecursive and deterministic, and each result carries the filename, resolved path, authored `video/...` source, size, modification time, and usability.

The filename edge case mattered because users can place files into `video/` without going through the importer. A manually dropped name containing CLIP grammar delimiters or control characters must not be silently rewritten. Those files remain visible but are marked unusable and expose no authored source.

That preserved a useful distinction:

> The filesystem can contain something that the script grammar cannot safely author.

The bin reports that state instead of hiding it or changing it.

## Phase 2: thumbnails stayed disposable

Thumbnail generation became a cache under `.cache/thumbs/`, keyed by media path, size, and modification time. Changing the source file therefore changes the key without requiring a persistent thumbnail manifest.

The important playback rule was stronger than simply making thumbnails asynchronous: an uncached thumbnail must never launch ffmpeg while the project clock is running. A cached thumbnail remains usable during playback, but new subprocess work waits until playback has stopped.

Generation writes a temporary JPEG and promotes it only after a successful, nonempty result. A failed ffmpeg invocation therefore leaves neither a final thumbnail nor a misleading partial cache entry.

This kept the feature in its proper place. Thumbnails are a derived convenience. They are never authored truth and never get to compete with playback for work simply because a browser widget was built.

## Phase 3: one browser surface

The reusable `ProjectMediaBinPanel` was added next. It scans immediately so the collapsed header can report the current file count, but thumbnail requests happen only when the panel is opened.

The panel is collapsible so Edit Mode does not permanently surrender timeline height. It exposes refresh, thumbnails, unusable-name status, and optional item activation while remaining nonauthoring by default.

Edit Mode and Text Mode reuse this same browser. The point was not visual consistency alone. A second media picker would have created a second set of assumptions about naming, scanning, thumbnail timing, and workspace paths.

## Phase 4: drag means place

Timeline drag-and-drop was the first new authoring gesture after Phase 0.

Usable media tiles became Flutter `Draggable` objects, and EDIT lanes became `DragTarget`s. Empty V1/V2 lanes are still rendered as drop targets, so an empty EDIT does not require an unrelated bootstrap gesture before media can be placed.

The timeline converts the actual drop x-coordinate through the current pixels-per-frame scale into an explicit project frame. The workspace conforms the existing media file and passes that concrete frame to `placeMediaInEdit`.

No transport state participates in the decision. That completed the semantic split exposed in Phase 0:

> Add means append. Drag means place.

The same placement primitive serves both, but the caller owns the answer to "where?"

## Phase 5: TEXT attachment reused STRUCT

The Text Mode workflow then proved the original grammar decision.

TEXT nodes already carry exact source spans. The attachment operation validates that the selected span still identifies exactly one TEXT node, creates a unique one-clip EDIT through the shared placement path, and inserts one standalone `[STRUCT:EDIT.<id>]` immediately after that TEXT span. Line endings are preserved and the resulting document is reparsed through both the structural model and the node parser.

The created EDIT is appended as a protected structural root, so it does not become terminal text or consume sequence time by existing at the end of the source document.

The UI reuses the same media bin inside TEXT settings. Choosing media does not open a new video-properties system. After attachment, the newly created STRUCT node becomes the selected node, and the existing STRUCT properties continue to own fullscreen, audio, title, overlay, and window presentation choices.

That is the architecture in one gesture:

```text
TEXT
  -> STRUCT:EDIT.<id>
  -> EDIT
  -> TRACK:V1
  -> CLIP:video/...
```

No new cue type was needed.

## Phase 6: offline state came from a join

The last roadmap pass added mundane project-media QoL: reference visibility, offline state, refresh, and navigation to authored owners.

This exposed another important modeling boundary. The filesystem bin can answer what files exist. It cannot answer what missing files the script still references. Conversely, the script can answer what is referenced but not whether those paths currently exist.

The solution was not to invent fake missing `ProjectMediaItem` records. A separate read-only reference catalog projects direct `video/` CLIP sources from EDIT tracks and MOSAIC panes. Structural CLIPs such as `EDIT.foo` are excluded, as are intentionally direct paths outside the workspace `video/` namespace.

The UI joins that authored reference catalog with the current filesystem scan. A referenced `video/...` source absent from the scan becomes an OFFLINE tile. Refreshing the filesystem can therefore move it back online without changing one authored byte.

Online referenced media shows a compact usage count. Reference navigation is separate from primary tile activation and drag: `OPEN` selects the owning EDIT/MOSAIC through the existing source-selection path and does not mutate the script.

Reconnect and replace are intentionally absent. Those are authored operations with their own policy questions and remain a separate design pass.

## The Phase 6 layout failures

The final QoL pass produced one more useful wrong turn during integration testing.

The first reference control rendered labels such as `OPEN EDIT.target` inside the existing narrow media-tile footer. The reference model and navigation behavior were correct in isolation, but the composed widget overflowed. In the workspace test, the overflow also moved the apparent OPEN control outside its real hit-test area, so navigation failed for a geometric reason rather than a source-selection reason.

The control was shortened to `OPEN`, with exact owner, lane, and clip information retained in a tooltip or multi-reference menu. That fixed the normal interactive path.

A second run still failed one read-only panel case because the no-callback state displayed the full structural source name. That state was compacted to `REF`, again preserving the exact reference summary in a tooltip.

Only then did the full Phase 6 regression set pass.

The lesson matches the earlier crossfade correction at a different layer: locally reasonable behavior can become wrong at composition boundaries. In Phase 0, fixtures disproved a data invariant. In Phase 6, a real widget constraint disproved a presentation assumption. Both were caught by running the composed system rather than trusting the local unit.

## The completed media-bin contract

The completed roadmap leaves these boundaries in place:

- The script remains the sole authored source of truth.
- `video/` is a project-media projection, not a second database.
- Thumbnails are disposable cache state.
- Imported and already-present workspace media share one conform model.
- `placeMediaInEdit` remains the common plain-placement writer.
- Plain placement rejects occupied frames without declaring all overlap invalid.
- Add Video appends to V1.
- Timeline drag supplies an explicit drop frame.
- TEXT attachment creates STRUCT plus a one-clip EDIT instead of new grammar.
- The same media browser is reused by Edit Mode and Text Mode.
- Offline status is derived from authored references joined with the current filesystem scan.
- Reference navigation selects existing structural owners without mutation.
- Reconnect and replace remain future authored-operation work.

The final implementation therefore ended where the original investigation pointed: not with a new video system, but with one ergonomic surface over the architecture that was already there.
