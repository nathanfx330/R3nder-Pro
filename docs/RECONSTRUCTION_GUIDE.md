# Reconstructing R3nder Pro

## A build specification for a deterministic, language-driven NLE

This document has a deliberately stronger goal than the rest of the R3nder Pro documentation.

It is written for the following situation:

> You are handed this repository cold. You understand application development and media systems, but you did not participate in R3nder Pro's design. Could you rebuild an editor with the same class of capability from the architecture, code, and tests?

The answer should be yes.

This is therefore not primarily a user manual, an API catalog, or a development diary. It is a **construction specification**.

It explains:

- what must exist;
- which subsystem owns each creative fact;
- what order the system should be built in;
- what data crosses each boundary;
- how time is represented;
- how media is mapped into that time;
- how reusable sources become program placements;
- how preview and bake remain semantically aligned;
- what tests prove that each layer is trustworthy.

For general lessons, read `BUILDING_A_DETERMINISTIC_NLE.md` beside this document. For the development history, read the JOURNEY documents. For exact user syntax, use `REFERENCE.md`.

---

# 1. The capability target

A reconstruction is not complete merely because video can be placed on a timeline.

The target system must be able to do all of the following while preserving one canonical authored project:

```text
TEXT presentation
    deterministic terminal/desktop animation

EDIT
    source-backed clips
    exact source/project frame mapping
    V1/V2 layering
    trim / move / split
    edge transitions
    persistent media preview

MOSAIC
    compose whole EDIT sequences
    per-pane temporal arrangement
    trim / move / crossfade structural sequences

STRUCT
    place EDIT or MOSAIC into the main program
    windowed or fullscreen presentation
    deterministic application switching
    placement-owned title/overlay chrome

PREVIEW
    evaluate the finished program at authored project time

BAKE
    render the same program semantics to encoded video
    preserve structural video, chrome, transitions, and audio

OUTPUT
    custom authored render names
    monotonic versions
    no silent overwrite
```

A system that has these features but allows preview, export, GUI state, and stored project state to disagree is not equivalent.

The defining property is the ownership model.

---

# 2. The non-negotiable invariants

If you copy nothing else from this repository, copy these contracts.

## 2.1 One canonical authored project

R3nder's script is the project.

The GUI is an editor over that project. It is not a second project database.

```text
authored text
    ↓ parse / project / edit
GUI surfaces
    ↓ serialize
same authored text
```

A GUI-only property is technical debt unless it is intentionally ephemeral.

Creative facts such as clip timing, source selection, fullscreen presentation, custom structural chrome, and render identity must survive closing and reopening the editor because they are represented in the authored document.

## 2.2 One project timeline

The project frame is the common time coordinate.

```text
ProjectClock
    ↓
ProjectTime(frame: N)
    ↓
scene evaluation
```

Flutter repaint cadence is not project time.

Decoder time is not project time.

Wall-clock export duration is not project time.

Audio device time may temporarily become realtime authority, but it reports into the same project clock contract.

## 2.3 Frame N is reproducible

Given the same authored state and the same requested project frame N, the program should select the same:

- terminal state;
- structural placement;
- source frame;
- composition geometry;
- transition weight;
- title/overlay expansion;
- final picture semantics.

## 2.4 Media decodes; it does not own the edit

MLT is below the timeline.

The application owns:

- project time;
- clip geometry;
- source hierarchy;
- composition;
- presentation choreography;
- final program semantics.

The media backend answers requests for source frames.

## 2.5 Definitions are not placements

`EDIT` and `MOSAIC` define reusable structural sources.

`STRUCT` places those sources into the main program.

Definitions do not consume main-sequence time merely by existing in the document.

## 2.6 Source time is not presentation time

A structural source can contain N authored source frames while its program placement consumes additional frames for opening, closing, or mode morphs.

Do not use one counter for both.

## 2.7 Readiness is not time

Late decode may delay what becomes visible.

It may not retime authored project geometry.

## 2.8 Preview and BAKE answer the same frame question

Realtime preview may be late.

BAKE may block.

The two paths may schedule work differently, but they must agree on what belongs at project frame N.

## 2.9 Placement metadata belongs to the placement

Fullscreen state, structural title, overlay mode, and custom overlay strings are properties of the `STRUCT` occurrence, not of the reusable `EDIT` or `MOSAIC` source.

The same source must be reusable with different presentation properties.

## 2.10 Final output never silently destroys prior output

A render name is authored project state. Versioning is monotonic. Existing encoded files are never silently replaced.

---

# 3. The whole system in one diagram

```text
                      ┌───────────────────────────┐
                      │ canonical authored script │
                      └─────────────┬─────────────┘
                                    │
                         lossless parse / CST
                                    │
              ┌─────────────────────┼─────────────────────┐
              │                     │                     │
          TEXT program          EDIT roots           MOSAIC roots
              │                     │                     │
              │                 clips/tracks          pane timelines
              │                     │                     │
              └─────────────── STRUCT placements ─────────┘
                                    │
                             script projection
                                    │
                         runtime STRUCT markers
                                    │
                        authoritative ProjectTime
                                    │
              ┌─────────────────────┼──────────────────────┐
              │                     │                      │
       terminal/desktop       structural source       workspace audio
          evaluation             evaluation              clock/mix
              │                     │                      │
              │               persistent MLT              │
              │                     │                      │
              └────────────── final program frame ─────────┘
                                    │
                          ┌─────────┴─────────┐
                          │                   │
                       PREVIEW              BAKE
                          │                   │
                    Flutter raster      ui.Image → RGBA
                                              │
                                            FFmpeg
                                              │
                                versioned encoded output
```

That diagram is the architecture in compressed form.

The rest of this guide expands each boundary.

---

# 4. Repository map by responsibility

File names change more easily than architectural ownership, but these are the primary implementation locations at the current checkpoint.

## 4.1 Project time and scene evaluation

Primary files:

```text
lib/project_clock.dart
lib/scene_evaluator.dart
lib/scene_engine.dart
lib/engine.dart
lib/engine_state.dart
lib/engine_tick.dart
```

Responsibilities:

- represent authoritative project time;
- evaluate scene state at explicit frame N;
- keep deterministic terminal/desktop behavior independent of callback cadence;
- allow realtime playback and export to ask the same scene question.

Do not put media-decoder position ownership here.

## 4.2 Native/realtime audio timing

Primary files:

```text
lib/audio_sink.dart
lib/audio_bed.dart
lib/audio_mix.dart
linux/... native runner/audio integration
```

Responsibilities:

- measured output-device timing;
- sample-based playback authority when audio is active;
- device-latency handling;
- generation-safe stream re-arm;
- preview/bake gain relationship;
- voice versus music duration policy.

Validation:

```text
docs/M4_AV_LOCK_VALIDATION.md
```

## 4.3 Script parsing and lossless ownership

Primary files:

```text
lib/parser.dart
lib/script_cst.dart
lib/script_nodes.dart
lib/script_pipeline.dart
lib/config_keys.dart
```

Responsibilities:

- preserve untouched source;
- identify nested structural roots;
- expose editable node semantics without normalizing unrelated source;
- project non-runtime definitions out of the executable program;
- serialize edited node state back into canonical authored text;
- keep CONFIG first-class.

Key rule:

> The parser may understand structure without claiming the right to rewrite everything it understands.

## 4.4 EDIT model and GUI

Primary files:

```text
lib/edit_model.dart
lib/edit_surface_model.dart
lib/edit_surface.dart
lib/edit_workspace.dart
lib/edit_media_import.dart
lib/edit_linter.dart
```

Responsibilities:

- clip geometry;
- track ownership;
- trim/split/move operations;
- edge transition metadata;
- media import/conform;
- timeline interaction;
- source-backed editor preview wiring.

The model must remain usable independently of Flutter widget state.

## 4.5 Media decode and EDIT composition

Primary files:

```text
lib/media_layer.dart
lib/edit_video_compositor.dart
lib/edit_video_preview.dart
lib/edit_playback_clock.dart
lib/edit_playback_frame.dart
```

Responsibilities:

- persistent decoder identity;
- exact source-frame requests;
- non-blocking preview behavior;
- deterministic structural-source composition;
- compositing V1/V2 and transitions;
- converting authored empty time into the correct creative result rather than confusing it with pending decode.

## 4.6 Structural source hierarchy

Primary files:

```text
lib/structural_sequence.dart
lib/structural_chrome.dart
lib/structural_sequence_preview.dart
lib/program_preview_surface.dart
lib/program_structural_export.dart
```

Responsibilities:

- map STRUCT placement-local time to source-local time;
- model windowed/fullscreen presentation;
- model seamless adjacency and mixed-mode morphs;
- preserve outgoing shell/client while incoming media becomes presentable;
- resolve placement-owned chrome;
- expand dynamic expressions such as `[frame]`;
- mirror geometry and semantics in BAKE.

## 4.7 Editor/node authoring surfaces

Primary files:

```text
lib/editor_screen.dart
lib/editor_node_workspace.dart
lib/editor_tag_menu.dart
lib/editor_text_controller.dart
```

Responsibilities:

- edit canonical script state;
- expose first-class controls for known node types;
- preserve exact authored text on close;
- keep generated STRUCT placements editable after creation;
- avoid hidden presentation state.

## 4.8 Export and render identity

Primary files:

```text
lib/exporter.dart
lib/render_naming.dart
```

Responsibilities:

- evaluate the whole program frame-by-frame;
- ask the structural renderer for active STRUCT frames;
- fall back to terminal compositor on non-STRUCT frames;
- convert final `ui.Image` frames to raw RGBA;
- stream frames to FFmpeg;
- mux audio with the project timing contract;
- choose collision-safe dashboard output versions;
- refuse overwrite.

---

# 5. Build order

A reconstruction should not start by drawing a timeline widget.

The order matters because later layers assume the earlier contracts are already true.

## Stage 0 — Define project constants and exact time

Implement:

```text
project fps
ProjectTime
ProjectClock
explicit frame evaluation API
```

Acceptance gate:

- frame N can be evaluated repeatedly with identical result;
- changing wall-clock delay does not change frame N;
- scrub can jump directly to N without replaying every UI callback.

Do this before media.

---

## Stage 1 — Make terminal/scene evaluation explicit-time

Convert any animation system that currently advances by callback side effects into state that can be evaluated against project time.

Acceptance gate:

```text
preview(frame: 100)
export(frame: 100)
```

must reach the same scene state.

The renderer may still be terminal-only at this stage.

---

## Stage 2 — Establish native audio authority

If realtime audio matters, build the device-time bridge now.

The sink must report played samples and measured latency into ProjectClock.

Treat stream/device replacement as a clock re-arm.

Acceptance gate:

- sustained playback under decode/load does not accumulate A/V clock drift;
- device changes do not allow stale callbacks to move the current clock;
- shutdown/drain paths are bounded.

---

## Stage 3 — Build a lossless authored model

Before serious GUI editing, parse the project in a way that can preserve source not owned by the current editor.

For a language-first editor this means a CST or equivalent source-span ownership model.

Acceptance gate:

```text
parse → no edits → serialize
```

is byte-identical for untouched source.

Editing one node rewrites only the owned region.

---

## Stage 4 — Define EDIT/TRACK/CLIP

Use the fewest independent timing facts possible.

Conceptual clip facts:

```text
source
project AT
source IN
project DURATION
exact SPEED
```

Derive consequences such as source OUT.

Conceptual lookup at project-local offset p:

```text
sourceFrame = IN + floor(p × speed)
```

Use exact rational relationships when source/project rates differ.

Acceptance gates:

- trim left preserves selected content correctly;
- trim right changes duration without inventing a second timing truth;
- split produces two clips whose project and source continuity match the original;
- moving a clip changes AT without changing source IN.

---

## Stage 5 — Conform/import media

Probe external media once at import.

Learn native source timing, then convert it into project mapping.

Prefer workspace-relative authored media paths.

Acceptance gate:

- a 24 fps source in a 30 fps project maps deterministically;
- reopening the project does not ask the media file to redefine authored duration;
- imported media remains portable with the workspace.

---

## Stage 6 — Add persistent media decode

A decoder-per-frame prototype is not enough.

Create a media abstraction that allows persistent decoder identity and deterministic requests.

Conceptual interface:

```text
MediaDecoderBackend.open(source)
    → MediaDecoder

MediaDecoder.render(sourceFrame, width, height)
    → DecodedMediaFrame
```

Preview and export may choose different waiting policies, but they should use the same source-frame semantics.

Acceptance gates:

- scrubbing does not reopen the decoder for every frame;
- repeated frame requests are exact;
- seek churn does not change project timing;
- decoder cold start is observable as readiness, not timeline drift.

---

## Stage 7 — Build the EDIT compositor

For each project frame inside an EDIT:

1. determine active clips per track;
2. map project-local time to source frame;
3. decode required leaf media;
4. compute transition weights;
5. composite tracks into one structural-source frame.

Distinguish these states:

```text
pending decode
resolved picture
authored empty/off gap
offline/error
```

Do not represent all four with one nullable frame.

Acceptance gates:

- V1/V2 overlap produces deterministic picture-over-picture result;
- isolated XFADE IN/OUT correctly uses black where no other picture exists;
- authored empty intervals remain authored time;
- preview and source export agree on the same edit frame.

---

## Stage 8 — Build the EDIT GUI over the model

Now add:

- clip lanes;
- drag/move;
- trim handles;
- split;
- track moves;
- transition controls;
- playhead/scrub;
- live preview.

The GUI calls model operations and serializes them. It does not invent alternate canonical clip state.

Acceptance gate:

> Perform an edit in the GUI, close the editor, reconstruct only from the authored document, and get the same edit back.

---

## Stage 9 — Make EDIT reusable

An EDIT must become an addressable source, not merely an editor workspace.

Use a canonical source reference such as:

```text
EDIT.main
```

Nested structural evaluation must be able to ask EDIT.main for its source-local frame.

---

## Stage 10 — Add MOSAIC as composition of whole EDIT sequences

MOSAIC owns panes.

Each pane may have its own timeline, but the unit it manipulates is a whole EDIT sequence.

```text
media clips    live in EDIT
EDIT sequences live in MOSAIC panes
```

Do not let MOSAIC become a second raw-media editor.

Acceptance gates:

- the same EDIT can be used in multiple MOSAICs without destructive changes;
- trimming a MOSAIC placement selects a range from the EDIT rather than rewriting the EDIT;
- pane crossfades use authored structural overlap;
- MOSAIC duration derives from authored pane timelines.

---

## Stage 11 — Add STRUCT as main-program placement

Now create the bridge from reusable structural sources into the TEXT program.

Minimal forms:

```text
[STRUCT:EDIT.main]
[STRUCT:MOSAIC.wall]
```

The source definition owns source duration.

The placement owns occurrence and presentation.

Definitions must be projected out of executable program time.

Acceptance gate:

- placing a source adds program time;
- merely defining the source does not;
- deleting/moving a STRUCT changes program sequence without modifying the source definition.

---

## Stage 12 — Separate source-local time from placement-local presentation time

Model a structural placement with explicit stages.

R3nder's presentation conceptually includes:

```text
terminal zoom / handoff
window opening or mode transition
source showing
window closing / handoff
terminal return
```

During presentation-only frames, source-local time must not advance.

Acceptance gate:

- the first showing frame maps to source frame 0 regardless of how many presentation frames preceded it;
- the last source frame remains exact;
- preview and bake use the same mapping.

---

## Stage 13 — Add structural application continuity

Adjacent STRUCT placements are not just isolated launches.

Determine adjacency in **program-time space**, not raw-text space.

This means ignoring things that consume no runtime time, including reusable structural definitions and configuration/comment material.

Support at least:

```text
window → window
full → full
window → full
full → window
```

Same-mode seamless handoff can remain direct.

Mixed-mode handoff needs one deterministic geometry mapping.

Acceptance gates:

- no terminal interstitial between seamless structural placements;
- no wallpaper flash;
- no unnecessary decoder reopen;
- project time remains authored;
- BAKE geometry matches PREVIEW.

---

## Stage 14 — Make STRUCT first-class in the GUI

Do not stop at syntax support.

Generated STRUCT placements must be editable after they already exist.

At minimum expose:

```text
SOURCE
FULL SCREEN
OVERLAY MODE
WINDOW TITLE
CUSTOM TOP
CUSTOM BOTTOM
```

The control must mutate the placement only.

The referenced EDIT/MOSAIC definition remains untouched.

Acceptance gate:

- selecting an existing generated STRUCT node shows semantic controls rather than generic RAW MARKUP;
- toggling FULL SCREEN round-trips to authored syntax;
- closing/reopening reconstructs the same state.

---

## Stage 15 — Add placement-owned chrome

The structural source is content.

The STRUCT placement is allowed to decide how that content is presented.

Current authored presentation supports the conceptual modes:

```text
DEFAULT
CUSTOM
NONE
```

and placement fields such as:

```text
TITLE
TOP
BOTTOM
```

A representative form is:

```text
[STRUCT:MOSAIC.wall:FULL:OVERLAY=CUSTOM:TITLE="MONITOR [frame]":TOP="FRAME [frame]":BOTTOM="REEL [frame]"]
```

Dynamic expressions such as:

```text
[frame]
```

are expanded against the placement's current structural/source frame semantics at render time.

Do not pre-expand them into static authored text.

Acceptance gates:

- editor preview shows the same resolved placement metadata BAKE receives;
- DEFAULT, CUSTOM, and NONE are distinct;
- `[frame]` changes frame-by-frame;
- the same source can appear twice with different chrome.

---

## Stage 16 — Build top-level PREVIEW separately from editor preview

Do not assume there is one preview simply because both surfaces display frames.

R3nder has at least these meaningful paths:

```text
EDIT/Node authoring preview
Program PREVIEW
BAKE
```

They may have different widget/composition paths while sharing frame semantics.

Name them explicitly in code and tests.

Acceptance gate:

- a feature demonstrated in editor preview is also exercised through top-level ProgramPreviewSurface;
- structural runtime markers select the intended placement in realistic multi-placement documents.

---

## Stage 17 — Build BAKE as a semantic peer, not a screenshot recorder

For each output frame i:

```text
scene.evaluate(ProjectTime(frame: i))
    ↓
if STRUCT active:
    ProgramStructuralFrameRenderer.renderIfActive(...)
else:
    terminal SceneCompositor
    ↓
ui.Image
    ↓ rawRgba
FFmpeg
```

BAKE may wait for exact source decode.

It must not let decoder latency choose a different source frame.

Audio is muxed according to the same project timing and authored gains.

Acceptance gates:

- a controlled end-to-end test runs `SceneExporter` through a real FFmpeg encode and decodes the finished file back to pixels;
- structural chrome survives the real encoded path;
- MOSAIC/CUSTOM/FULL cases are covered, not only tiny EDIT fixtures;
- source export and whole-program BAKE are named distinctly in the UI.

---

## Stage 18 — Add render identity and no-overwrite versioning

Render identity is creative/project state, not merely a transient file-dialog decision.

R3nder authors it as CONFIG:

```text
[CONFIG:RENDERNAME:documentary_cut]
```

Dashboard BAKE derives a filename family such as:

```text
documentary_cut_1080p_v001.mp4
documentary_cut_1080p_v002.mp4
documentary_cut_1080p_v003.mp4
```

Version selection is monotonic.

If v002 is deleted while v003 remains, the next output is v004 rather than reusing v002.

Different codec extensions should not silently create conflicting version histories for the same render family.

Fill/matte companion outputs reserve the same version together.

Final safety has two layers:

1. plan an unused output path;
2. ask FFmpeg not to overwrite existing files.

Acceptance gates:

- first BAKE produces v001;
- second produces v002;
- v001 remains byte-for-byte intact;
- names are sanitized safely;
- direct exporter callers that request explicit filenames are not accidentally forced into dashboard naming semantics.

---

# 6. Structural source evaluation in more detail

A useful conceptual interface is:

```text
StructuralSourceRef
    kind = EDIT | MOSAIC
    id

resolve(ref)
    → source definition

render(ref, sourceFrame)
    → structural frame
```

The important point is that STRUCT does not ask a decoder for `MOSAIC.wall`.

`MOSAIC.wall` is an application-level source.

It may recursively evaluate EDIT sequences, which in turn evaluate media clips, which finally ask MLT for leaf frames.

The hierarchy is:

```text
STRUCT placement
    ↓
MOSAIC source
    ↓
EDIT sequence placement(s)
    ↓
EDIT source
    ↓
media CLIP
    ↓
MLT decoder
```

Each layer translates its local authored time into the next layer's source-local time.

That translation is where most edit correctness lives.

---

# 7. Transition ownership

A transition is not simply a shader applied whenever two clips happen to overlap.

R3nder treats edit transitions as authored edge semantics.

At minimum distinguish:

```text
incoming transition on left edge
outgoing transition on right edge
```

They can coexist.

For an isolated clip:

```text
incoming: black → clip
outgoing: clip → black
```

For overlapping clips:

```text
outgoing picture → incoming picture
```

The compositor needs both authored transition extent and actual neighboring picture availability.

A fast path that skips compositing because “only one clip is visible” must not accidentally skip an outgoing fade-to-black or edge effect.

Test semantic edges, not only overlap cases.

---

# 8. Readiness and decoder lifetime

This deserves explicit reconstruction because it caused some of the hardest visual bugs.

A media request moves through several states:

```text
request issued
    ↓
decoder produced bytes
    ↓
Flutter/ui image created
    ↓
frame is actually paintable
```

Do not call all four states `ready`.

During a seamless A → B structural handoff, the correct behavior may be:

- project time advances into B on schedule;
- B's first source frame is requested;
- outgoing A shell/client remains visible as cover;
- B becomes paint-resident;
- displayed client swaps to B;
- no extra project time was inserted.

That is a visibility policy, not a timing policy.

Widget identity matters too. A decoder can reopen unexpectedly if the Flutter subtree that owns it remounts even though the source did not conceptually change.

Key the ownership boundary that must remain stable, not merely a nested child.

---

# 9. Runtime projection and placement indexing

A language-first compositional system often has two views of a document:

```text
raw authored document
compiled/executable program projection
```

That is dangerous if two subsystems derive placement identity independently.

R3nder's important M20 correction was to align runtime STRUCT marker numbering with the same **executable placement set** used by the structural metadata parser.

The failure class looked like this:

```text
raw document
    contains structural-looking material inside reusable roots

runtime projection
    strips those roots

marker #1
    means executable placement B

raw placement list #1
    accidentally means some other record
```

The video source could still look correct while the placement chrome came from the wrong record.

The rule is:

> Never associate program placements by list index across two differently transformed document views unless both lists are created from the same projection contract.

Prefer a stable placement identity when practical. If index identity is used, prove the two producers enumerate the same executable set.

Test realistic documents with:

- reusable roots;
- multiple STRUCT placements;
- repeated sources;
- different chrome modes;
- comments/config between placements;
- malformed or structural-looking non-executable text.

---

# 10. Source export versus program BAKE

These are different products and should be named differently.

## Source export

Exports:

```text
EDIT.foo
or
MOSAIC.bar
```

It renders the reusable source itself.

It cannot know which placement-owned title, overlay, or fullscreen state to use because the same source may be placed differently several times.

## Program BAKE

Exports:

```text
TEXT program
+ STRUCT placements
+ placement presentation
+ audio mix
```

This path owns placement chrome.

A button labeled merely `EXPORT` inside a structural-source editor is ambiguous. The UI should say `EXPORT SOURCE` so users do not mistake a naked reusable source for the finished program.

This naming distinction is architecture documentation disguised as UX.

---

# 11. How to test the system

Tests are part of the reconstruction specification.

A strong suite has several levels.

## 11.1 Pure model tests

Prove:

- clip math;
- split/trim;
- exact source mapping;
- structural placement planning;
- presentation geometry;
- render-name sanitization/versioning;
- parser/serializer round trips.

These should be fast and narrow.

## 11.2 Widget ownership tests

Prove:

- generated STRUCT nodes expose first-class controls;
- node edits serialize back into authored text;
- editor close handoff returns the exact updated buffer;
- viewport-sensitive desktop controls remain reachable.

Use a desktop-sized widget-test viewport for desktop workspaces.

## 11.3 Runtime-path tests

Mount the actual top-level preview path.

Do not only test a nested preview widget if the product has a different program viewer.

Prove:

- runtime marker selects the intended placement;
- custom chrome expands dynamically;
- multiple placements preserve identity;
- hidden reusable definitions do not shift runtime association.

## 11.4 Raster tests

When a failure is literally about pixels, assert pixels.

Logical widget presence is insufficient for problems involving opacity, clipping, or paint-resident readiness.

## 11.5 Encoded end-to-end tests

For export-critical behavior:

```text
SceneExporter
    ↓
FIFO
    ↓
FFmpeg encode
    ↓
finished MP4/MOV
    ↓
FFmpeg decode
    ↓
inspect resulting pixels/metadata
```

This is slower and worth it for semantic parity features.

It caught the class of uncertainty that a direct renderer test cannot resolve.

## 11.6 Real-script fixtures

Small synthetic tests are necessary and insufficient.

Keep at least one realistic document topology with:

- several EDIT roots;
- several MOSAIC roots;
- reused structural sources;
- multiple STRUCT placements;
- fullscreen/windowed combinations;
- custom placement metadata;
- configuration and comments;
- real ordering patterns generated by the GUI.

The hardest bugs in R3nder frequently survived tiny fixtures because the tiny fixture had no opportunity for ownership indexes or alternate paths to diverge.

---

# 12. Debugging order when PREVIEW and BAKE disagree

Do not begin by editing the layer where the symptom appears.

Use this narrowing sequence.

## Question 1 — Which preview?

Is the user reporting:

```text
EDIT source preview
Node/Editor structural preview
Program PREVIEW
encoded BAKE
```

Name the path exactly.

## Question 2 — Is authored state correct?

Inspect the canonical document after the GUI change.

If the value is not in authored state, the renderer is not the first problem.

## Question 3 — Does the parser recover the intended semantic object?

Verify the placement/source/config object, including dynamic strings.

## Question 4 — Does runtime select the intended placement?

Check marker identity and local frame mapping.

## Question 5 — Does the structural renderer produce the pixels?

Use a raster gate.

## Question 6 — Does SceneExporter preserve them?

Use the real exporter path.

## Question 7 — Does the encoded file preserve them?

Decode the output back to raw pixels.

At each step, stop blaming layers already proven correct.

This method is slower for the first ten minutes and dramatically faster over a difficult bug.

---

# 13. Anti-patterns to avoid

## Hidden GUI truth

If a creative value exists only in widget state, reopening the project will eventually expose the lie.

## Multiple clocks

A timeline, decoder, animation ticker, and audio device must not all independently advance “time.”

## Reopening decoders per frame

Works for screenshots. Fails as an editor architecture.

## Treating source definitions as runtime events

Reusable EDIT/MOSAIC roots are not pauses in the main program.

## Duplicating duration at every layer

Source duration, placement duration, decoder duration, and UI duration should not become competing truths.

## Waiting for decode by stopping project time

This makes authored timing depend on machine performance.

## One `preview` abstraction for several user paths

If editor preview and program preview are different code paths, name and test them separately.

## Testing widgets when the bug is raster

Mounted does not mean painted.

## Testing the renderer when the bug is export integration

A renderer unit test cannot prove the exporter handed it the right authored state.

## Testing only one placement

Index/association bugs need multiple realistic placements to exist.

## Calling source export “final export”

Reusable-source export and program BAKE have different ownership semantics.

## Allowing FFmpeg `-y` on final named renders

A successful render should not destroy an earlier version by accident.

---

# 14. Minimal architecture checklist

A reconstruction is ready to call “the same class of NLE” when all of these can be answered yes.

## Authored model

- [ ] Is there exactly one canonical project representation?
- [ ] Can the GUI be reconstructed from it?
- [ ] Do untouched regions survive visual editing?

## Time

- [ ] Is project time explicit and authoritative?
- [ ] Can frame N be evaluated directly?
- [ ] Is realtime polling separate from authored time?
- [ ] Is audio authority bridged into the same timeline?

## Media

- [ ] Are decoders persistent?
- [ ] Are source-frame requests deterministic?
- [ ] Is source timing conformed into project timing?

## EDIT

- [ ] Can clips trim, move, split, layer, and transition?
- [ ] Are project/source timing facts independent and non-redundant?

## MOSAIC

- [ ] Can panes arrange whole EDIT sequences?
- [ ] Can the same EDIT be reused nondestructively?

## STRUCT

- [ ] Are source definitions separate from placements?
- [ ] Does presentation time map explicitly to source time?
- [ ] Can placements be windowed/fullscreen?
- [ ] Can adjacent placements switch without unintended interstitials?
- [ ] Does placement-owned chrome round-trip through the project?
- [ ] Do dynamic expressions expand at render time?

## Preview/export

- [ ] Does top-level PREVIEW exercise the real program path?
- [ ] Does BAKE evaluate the same authored frame contract?
- [ ] Are encoded end-to-end tests present?

## Output

- [ ] Can the project author a render base name?
- [ ] Are versions monotonic?
- [ ] Are old outputs protected from overwrite?

If every box is checked and the tests named in this guide are green, the architecture is not merely similar in appearance. It preserves the important semantics.

---

# 15. The deeper reason this architecture works

R3nder Pro did not become useful because it accumulated editor features.

It became useful because each layer was forced to answer to a narrower owner.

```text
ProjectClock
    owns project time

script/CST
    owns authored intent

EDIT
    owns leaf-media temporal editing

MOSAIC
    owns compositions of whole EDIT sequences

STRUCT
    owns occurrence and presentation in the main program

MLT
    owns media decode

Preview
    owns realtime visibility

BAKE
    owns deterministic final frame production

CONFIG:RENDERNAME
    owns project render identity
```

The system remains understandable because those owners are deliberately incomplete.

MLT is not asked to own the project.

MOSAIC is not allowed to become another raw-media editor.

STRUCT is not allowed to rewrite the source it presents.

Readiness is not allowed to own time.

The GUI is not allowed to own hidden creative truth.

FFmpeg is not allowed to decide that an old render may be overwritten.

That restraint is the real implementation recipe.

---

# 16. What to read in the source after this guide

A useful cold-reading order is:

```text
1. README.md
2. MANUAL.md
3. docs/BUILDING_A_DETERMINISTIC_NLE.md
4. lib/project_clock.dart
5. lib/scene_evaluator.dart
6. lib/script_cst.dart
7. lib/script_pipeline.dart
8. lib/edit_model.dart
9. lib/media_layer.dart
10. lib/edit_video_compositor.dart
11. lib/structural_sequence.dart
12. lib/structural_chrome.dart
13. lib/program_preview_surface.dart
14. lib/program_structural_export.dart
15. lib/exporter.dart
16. lib/render_naming.dart
17. the corresponding tests
18. JOURNEY documents for the seams that still seem strange
```

Read tests beside production code.

In this repository the tests often state the architectural contract more clearly than a class comment because they encode the failure that forced the boundary into existence.

---

# Final reconstruction rule

If you rebuild this system, do not start by copying screens.

Start by reproducing these truths:

```text
one authored project
one authoritative timeline
exact frame evaluation
persistent decode
EDIT owns media cuts
MOSAIC owns whole EDIT sequences
STRUCT owns program placement and presentation
readiness never retimes authored work
preview and bake answer the same frame question
render identity is authored and versioned
```

Once those are true, the NLE UI is comparatively straightforward.

Without them, a polished timeline is only a collection of controls waiting for the first difficult project to make the contradictions visible.
