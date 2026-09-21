# Structural Sources, MOSAIC, and STRUCT Placement

This page explains the hierarchy that lets R3nder Pro behave like more than a flat clip timeline.

The architecture is:

```text
leaf media
    ↓
EDIT
    ↓
MOSAIC
    ↓
STRUCT
    ↓
TEXT program
```

The most important distinction is between a reusable source and a program placement.

Primary files:

- `lib/edit_model.dart`
- `lib/edit_video_compositor.dart`
- `lib/structural_sequence.dart`
- `lib/structural_chrome.dart`
- `lib/structural_source_export.dart`
- `lib/structural_sequence_preview.dart`

History:

- `docs/R3NDER_PRO_JOURNEY_TO_STRUCTURAL_VIDEO.md`
- `docs/M18_M19_STRUCTURAL_PRESENTATION_JOURNEY.md`
- `docs/M20_M21_PRESENTATION_AND_RENDER_IDENTITY_JOURNEY.md`

---

## Contract

Structural composition must guarantee:

- EDIT and MOSAIC definitions are reusable sources;
- defining a source does not consume top-level program time;
- STRUCT is the main-sequence placement mechanism;
- the source owns content duration and composition;
- the placement owns presentation mode and chrome;
- the same source can be placed multiple times with different presentation metadata;
- nested structural evaluation maps exact local frames downward without wall time;
- recursive graphs are linted and runtime depth is bounded;
- adjacent STRUCT placement planning is based on executable program adjacency, not merely raw text position;
- Preview and BAKE use the same placement plan.

---

# 1. EDIT is a reusable sequence source

An EDIT is not only a workspace tab.

Once authored, it becomes a frame-producing source addressable as:

```text
EDIT.main
```

Its duration comes from its authored clip geometry.

An EDIT may contain leaf-media CLIPs and can itself be consumed by higher structural layers.

This is what turned R3nder's visual editor into a composable system rather than an isolated timeline.

---

# 2. MOSAIC composes structural sources spatially

A MOSAIC owns a list of PANE containers.

Each pane has a pane-local CLIP timeline. Those CLIPs normally point to structural sources such as `EDIT.main`.

Conceptually:

```text
[MOSAIC:wall]
  [PANE:left]
    [CLIP:a:EDIT.main:...]
    [/CLIP]
  [/PANE]
  [PANE:right]
    [CLIP:b:EDIT.broll:...]
    [/CLIP]
  [/PANE]
[/MOSAIC]
```

Pane order determines layout.

The current model supports one composition rather than paged MOSAIC presentation. More panes than the supported geometry are rejected rather than silently moved elsewhere.

MOSAIC duration is authored geometry: the maximum pane-local CLIP end.

## Common endpoint calculation (T0)

`mosaicCommonEndFrame` in `lib/mosaic_trim.dart` calculates a candidate exclusive
endpoint for the planned **Trim to shortest** operation. It takes the minimum
`projectFrameCount` among panes containing at least one clip. It returns null
when fewer than two panes are populated or the candidate already equals the
MOSAIC duration.

This calculation uses assembled pane endings, including placement offsets and
crossfade overlap. It does not sum clip lengths, inspect source media, close
gaps, or introduce a separate duration authority. Existing IN and speed values
do not change authored project duration.

T0 is calculation only, proved by `test/mosaic_trim_test.dart`. It does not yet
provide a trim operation or button. A candidate is not permission to trim:
later validation must reject cuts that break incoming crossfades or remove all
content from a populated pane. Calculation leaves the model unchanged.

## Single pane clip removal (T1)

`MosaicSurfaceDocument.removeClip(paneId, clipId)` in
`lib/mosaic_surface_model.dart` returns source with exactly the selected CLIP
block removed. Its incoming crossfade, cues, and other body content leave with
that block. Every byte outside the block remains unchanged, including comments,
line endings, referenced EDIT definitions, other panes, and STRUCT placements.
Surviving clips keep their authored positions, source ranges, and transitions;
removal does not close gaps or shift later clips.

The operation validates the resulting structural graph before returning source.
Unknown pane or clip IDs throw. Removing a pane's final clip retains the empty
PANE and its layout position. That is valid for this primitive; the planned
trim operation must separately reject any trim that empties a populated pane.

`test/mosaic_remove_clip_test.dart` proves exact LF/CRLF preservation, scoped
removal, incoming crossfade ownership, empty pane retention, derived duration
after reparsing, and validation failures. T1 provides no new UI control.

---

# 3. Recursive local time

A structural renderer must be able to move from top-level project frame to leaf source frame through local coordinate systems.

Conceptually:

```text
program frame
    ↓
STRUCT sequence-local frame
    ↓
STRUCT source frame
    ↓
MOSAIC frame, if source is MOSAIC
    ↓
pane-local active CLIP
    ↓
EDIT source frame
    ↓
EDIT active CLIP
    ↓
leaf media source frame
```

Every arrow is a deterministic arithmetic mapping.

No layer should read the wall clock or decoder readiness to choose its local frame.

---

# 4. STRUCT is placement, not source definition

A standalone tag such as:

```text
[STRUCT:MOSAIC.wall]
```

means:

> Place this reusable source here in the main program.

The source already knows how many content frames it owns.

STRUCT adds presentation choreography around that content: terminal-to-desktop movement, window opening/closing, fullscreen/windowed geometry, and chaining into neighbouring structural applications.

This separation avoids duplicated duration state.

There is no second user-authored STRUCT duration that can drift from the EDIT/MOSAIC source.

---

# 5. Presentation mode belongs to STRUCT

The same source can be used as:

```text
[STRUCT:MOSAIC.wall]
[STRUCT:MOSAIC.wall:FULL]
```

The MOSAIC definition does not change.

This matters because “what is the video?” and “how is it presented here?” are different questions.

Source-owned facts:

```text
clip geometry
pane composition
duration
source audio
```

Placement-owned facts:

```text
windowed/fullscreen
window title
overlay mode
top/bottom overlay copy
adjacent application choreography
```

A reconstruction should preserve that boundary.

---

# 6. STRUCT chrome is keyed placement metadata

`lib/structural_chrome.dart` parses the keyed tail.

Examples:

```text
[STRUCT:MOSAIC.wall:TITLE="Archive Viewer"]
[STRUCT:MOSAIC.wall:OVERLAY=NONE]
[STRUCT:MOSAIC.wall:FULL:OVERLAY=CUSTOM:TITLE="Field Monitor":TOP="FRAME [frame]":BOTTOM="REEL 4"]
```

Current overlay modes are:

```text
DEFAULT
CUSTOM
NONE
```

CUSTOM copy is preserved even while mode is switched away from CUSTOM, so temporarily choosing DEFAULT/NONE does not destroy authored strings.

Unknown keyed segments make the tag invalid rather than being silently ignored.

That is important in a text-authored project: a typo should remain visible for repair rather than becoming a different valid presentation.

---

# 7. Dynamic chrome expressions

`[frame]` is deliberately expanded at render time, not stored as a precomputed string.

It means the exact structural source-local frame being painted.

This gives deterministic behavior under:

- scrub;
- playback;
- fullscreen/windowed modes;
- seamless handoff;
- BAKE.

The expression system is intentionally tiny. Unknown bracketed text is preserved literally.

Do not move expression expansion into the GUI. The GUI authors the expression; the renderer owns its value at frame N.

---

# 8. STRUCT event budgeting

A standalone structural presentation has entry, content, and exit stages.

Conceptually:

```text
zoom out terminal
open structural window
show source content
close window
zoom terminal back in
```

`StructuralSequencePlacement` derives stage boundaries and source-frame mapping from one planned duration.

Important fields include:

```text
sourceDurationFrames
durationFrames
presentationMode
chainedFromPrevious / chainedToNext
seamlessFromPrevious / seamlessToNext
previousPresentationMode
```

The source frame is clamped to source frame zero during entry and to the last source frame during exit. The content itself advances only through the authored source duration.

---

# 9. Executable adjacency is not raw-text adjacency

M18 exposed a major planning mistake.

A realistic document can contain reusable source definitions between two STRUCT placements:

```text
[STRUCT:MOSAIC.first]

[EDIT:second]
...
[/EDIT]
[MOSAIC:second]
...
[/MOSAIC]

[STRUCT:MOSAIC.second]
```

Those source definitions consume no program time.

Therefore the two STRUCT placements are adjacent in executable presentation even though they are separated by many raw source lines.

The planner strips/ignores:

- reusable EDIT/MOSAIC source roots;
- comments;
- CONFIG declarations;
- other zero-time metadata.

Real visible text, PAUSE, or another presentation does break the chain.

This is a recurring lesson:

> Sequence adjacency must be computed in the executable projection, not by line distance in the authoring document.

---

# 10. APPSWITCH and seamless handoff

STRUCT reuses the existing application-switch setting.

With ordinary behavior, adjacent structural apps suppress the terminal zoom between them but can still close/open through desktop choreography.

With:

```text
[CONFIG:APPSWITCH:SLIDE]
```

compatible placements keep the structural presentation shell alive.

In live Preview, same-mode STRUCT clients now use the same visual language as the existing APP page pan: outgoing content moves left while incoming content enters from the right, eased with `easeInOutCubic`. The nominal budget is `kStructuralSwitchSlideFrames`, deliberately matched to the APP pan budget. Those frames overlap the beginning of the incoming source's authored showing span; they are not added to program duration.

Mixed windowed/fullscreen transitions still use their deterministic window-geometry morph. The client pan and shell geometry are separate ownership concerns.

Important invariants:

- no fullscreen terminal flash between adjacent STRUCT placements;
- no extra project frames inserted for decode readiness or slide motion;
- incoming local source frame does not restart after preload;
- readiness may unlock exposure, but authored incoming source time determines slide progress;
- editor and top-level Program Preview both implement the live handoff;
- Preview and BAKE use the same planned event budget.

**Current parity boundary:** the literal two-client pan added at main checkpoint `cd5ad51` is implemented in live Preview paths. `ProgramStructuralFrameRenderer` still renders the single active placement in BAKE. Timing, placement, and audio boundaries remain shared, but final BAKE pixel parity for this new pan is not yet proved and must not be inferred from the Preview tests.

---

# 11. Runtime marker identity

Real Preview/BAKE compile each executable STRUCT placement into an internal REGION marker plus timing projection.

The marker contains:

```text
placementIndex
durationFrames
```

The terminal engine remains the top-level sequence clock.

Presentation layers observe `currentRegion`, parse the marker, and resolve the matching `StructuralSequencePlacement` from the same executable placement list.

M20 exposed why the phrase “same executable placement list” is essential.

If runtime markers are indexed after source-root stripping while chrome metadata is indexed from raw STRUCT-looking text, the correct video can be paired with the wrong placement metadata.

That produced the especially deceptive symptom:

```text
video correct
DEFAULT chrome visible
CUSTOM chrome missing/wrong
```

The fix was architectural: runtime marker indexing and render metadata indexing now share the same executable placement set.

---

# 12. Source export is not placement export

`StructuralSourceFrameRenderer` and the EDIT/MOSAIC workspace source export render the reusable source.

They do not know which STRUCT placement is intended.

That means source export deliberately excludes placement-owned facts such as:

- FULL/windowed presentation;
- STRUCT title;
- DEFAULT/CUSTOM/NONE player chrome.

This is why the workspace UI now says **EXPORT SOURCE**.

Final program BAKE is the path that includes STRUCT placement presentation.

A reconstruction should make this distinction explicit in both API naming and UI language.

---

# 13. Failure modes to recognize

## Correct video, wrong title/overlay

Check placement identity/index association before touching the decoder or painter.

## Terminal flashes between adjacent structural sources

Adjacency is probably being computed from raw text or the outgoing shell is being dropped before the incoming source has completed an active paint.

## Source waits and timeline stretches

Decode readiness has leaked into authored timing.

## Fullscreen setting changes the reusable MOSAIC

Presentation metadata is being stored on the source instead of the placement.

## EXPORT SOURCE lacks title/overlay

That is correct. Placement chrome belongs to program BAKE unless a future explicit placement-export feature is invoked.

---

# 14. Proof

Important proof includes:

- structural source model tests;
- structural recursion/depth-guard tests;
- M18 application-switch tests and visual gate;
- `test/editor_structural_fullscreen_node_test.dart`;
- structural chrome parser/round-trip tests;
- structural marker alignment tests;
- Program Preview runtime tests;
- SceneExporter encoded MOSAIC/CUSTOM tests.

The M18 visual gate matters because a model can be correct while Flutter briefly paints wallpaper or terminal underneath a not-yet-ready incoming source.

---

# Reconstruction checklist

- [ ] EDIT is reusable frame-producing content;
- [ ] MOSAIC composes structural sources into deterministic pane geometry;
- [ ] source duration is authored in source definitions;
- [ ] STRUCT places a source into the main program without a duplicate duration field;
- [ ] presentation mode and chrome belong to STRUCT;
- [ ] `[frame]` expands from exact source-local render time;
- [ ] executable adjacency ignores zero-time definitions/metadata;
- [ ] runtime markers and placement metadata use identical indexing rules;
- [ ] APPSWITCH planning changes choreography without changing authored content duration;
- [ ] decode readiness never inserts project time;
- [ ] source export and final program BAKE are clearly distinct.

With these contracts, a flat NLE becomes a reusable hierarchical composition system without surrendering deterministic frame ownership.