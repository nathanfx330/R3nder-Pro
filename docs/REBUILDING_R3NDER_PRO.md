# Rebuilding R3nder Pro

## A reconstruction guide for the deterministic NLE architecture

This document is written for a specific scenario:

> You are handed the R3nder Pro repository with no oral history. You need to understand it well enough to build an editor with the same fundamental capabilities and guarantees.

The goal is not to reproduce every widget pixel-for-pixel. The goal is to reproduce the architecture that makes the editor trustworthy:

- one canonical authored project;
- deterministic project time;
- exact clip/source-frame mapping;
- persistent native media decode;
- nested reusable structural sources;
- direct-manipulation NLE controls;
- presentation placements distinct from source definitions;
- top-level Preview and final BAKE parity;
- collision-safe, versioned output.

If you understand the contracts in this document, the rest of the repository becomes much easier to read.

---

# 1. Start with the product model, not the Flutter UI

R3nder Pro is easiest to understand as a source hierarchy:

```text
leaf media
   ↓
EDIT
   ↓
MOSAIC
   ↓
STRUCT placement
   ↓
TEXT program
   ↓
PREVIEW / BAKE
```

Each level has a different job.

## Leaf media

Normal media files. MLT decodes them. They do not own project time.

## EDIT

An authored time sequence of CLIPs on TRACKs.

EDIT owns:

- clip placement in project frames;
- source IN;
- duration;
- exact speed mapping;
- track membership;
- transition semantics;
- source references.

EDIT does not own whether it appears fullscreen or in a desktop window in the final presentation.

## MOSAIC

A composition of reusable structural sources, primarily EDIT sequences, arranged into panes and pane-local timelines.

MOSAIC owns composition and pane timing. It does not become the top-level presentation sequence.

## STRUCT

A main-sequence placement of an EDIT or MOSAIC.

STRUCT owns presentation facts such as:

- which structural source is placed here;
- windowed vs fullscreen;
- DEFAULT / CUSTOM / NONE chrome;
- placement title and overlay strings;
- dynamic expressions such as `[frame]`.

This source/placement split is fundamental.

The same `MOSAIC.wall` can appear once windowed and later fullscreen with different chrome because the source does not own those choices.

## TEXT

The main presentation program.

TEXT owns order, narration-driven terminal behavior, desktop presentation, and structural placements.

## PREVIEW / BAKE

These are not separate authored models. They are two consumers of the same project state and project-time contract.

---

# 2. The first invariant: the script is the project

Do not begin reconstruction with the timeline widget.

Begin with canonical state.

R3nder's authored document is the project. The GUI mutates that document. It does not maintain a second durable timeline database.

That means every serious GUI feature must answer this question:

> If the editor closes now and is reopened from only the document text, is the same creative intent reconstructed?

If not, the feature is incomplete.

This is why the parser/CST and node model matter before the visual NLE.

Relevant code families include:

- `script_cst.dart`
- `script_nodes.dart`
- `script_pipeline.dart`
- `parser.dart`
- `config_keys.dart`
- `edit_model.dart`
- structural sequence/chrome models

The exact file set evolves, but the ownership rule should not.

## Lossless editing

Because users can edit the script directly, untouched regions must survive visual editing.

Conceptually:

```text
parse
  -> identify owned structural spans
  -> edit one owned span
  -> serialize that span
  -> preserve every unrelated byte
```

Do not normalize the whole document merely because one clip moved.

This is one of the architectural differences between R3nder and a conventional editor with a hidden project database.

---

# 3. The second invariant: project frame N is explicit

A deterministic editor cannot treat callback cadence as project time.

The model is:

```text
ProjectClock
    ↓
ProjectTime(frame: N)
    ↓
scene.evaluate(...)
```

Flutter may poll at 60 Hz. The project may be 30 fps. MLT may seek slowly. ffmpeg may encode faster or slower than realtime. None of those rates is allowed to redefine authored project frame N.

The reconstruction rule is:

> Make frame evaluation explicit before building media editing.

Preview, scrub, replay, and export should all be able to ask for the same project frame.

## Audio authority

During realtime playback, audio may become the physical timing authority because the samples that reached the device are what the user actually hears.

Even then, audio reports time into the same project clock model. It does not establish a parallel timeline.

Device changes require re-anchoring, latency refresh, stale-generation protection, and bounded shutdown behavior.

Read `M4_AV_LOCK_VALIDATION.md` and the timing sections of `BUILDING_A_DETERMINISTIC_NLE.md` before modifying this subsystem.

---

# 4. Reconstruct the EDIT model before the EDIT surface

The visual timeline is a view over authored geometry.

A useful conceptual clip model is:

```text
source
AT          project start frame
IN          source start frame
DURATION    project duration
SPEED       exact source/project relationship
TRACK
transition metadata
```

Source lookup for a local project offset `p` is conceptually:

```text
sourceFrame = IN + floor(p * speed)
```

with exact/rational speed representation when required.

Do not store multiple editable fields that describe the same fact unless there is an explicit reconciliation rule.

If OUT can be derived from IN, DURATION, and SPEED, it should not casually become an independent canonical truth.

## Operations the model must support

Before polishing the UI, prove these at the model level:

- add clip;
- trim head/tail;
- move in project time;
- split;
- change track;
- change speed;
- add/remove transitions;
- preserve source mapping across splits;
- serialize back to exact authored syntax.

Then the GUI can become a set of manipulations over those operations.

Relevant files include `edit_model.dart`, edit surface/model files, edit linter/import code, and the associated tests.

---

# 5. Put MLT under the model, not above it

R3nder uses MLT as a persistent media backend.

The boundary is:

```text
R3nder
  owns project time
  owns edit geometry
  owns nesting
  owns composition
  owns final presentation

MLT
  decodes requested leaf media frames
```

This is critical.

Do not let the decoder become the project clock merely because it can play media.

## Persistent decoder identity

A real editor needs decoders that survive:

- scrubbing;
- repeated seeks;
- playback;
- transitions;
- nested EDIT/MOSAIC evaluation;
- preview/export reuse.

Opening a decoder per requested frame is a prototype, not the finished architecture.

The media abstraction should make native MLT replaceable in tests with deterministic fake backends.

That seam is what makes encoded/export regressions possible without relying on real footage.

---

# 6. Build structural recursion deliberately

The editor is not only a flat clip timeline.

The hierarchy is recursive in a controlled way:

```text
CLIP -> leaf media
EDIT -> CLIPs
MOSAIC -> structural source placements inside panes
STRUCT -> EDIT or MOSAIC in main program
```

Each layer needs a clear local time coordinate.

For any project frame you should be able to derive:

```text
program project frame
  -> STRUCT local frame
  -> MOSAIC local frame, if any
  -> EDIT local frame
  -> CLIP local frame
  -> source frame
```

If any layer reads wall time or decoder readiness to determine this mapping, deterministic behavior is broken.

## Readiness is not timing

Media may not be ready immediately.

That should affect visibility, cover frames, or loading state.

It must not insert project frames or move authored geometry.

This principle became especially important during M18 application switching.

---

# 7. Separate structural source from structural presentation

This is one of the most important lessons from M18-M20.

An EDIT/MOSAIC source is reusable content.

A STRUCT placement is how that content is presented at one point in the program.

Example:

```text
[STRUCT:MOSAIC.wall]

[STRUCT:MOSAIC.wall:FULL:OVERLAY=CUSTOM:
 TITLE="ARCHIVE [frame]":
 TOP="FRAME [frame]":
 BOTTOM="REEL [frame]"]
```

Same source. Different placement intent.

That is why player/window title and overlays belong to STRUCT rather than MOSAIC.

It is also why source export and program BAKE are different operations.

A source export has no placement identity and therefore cannot know which placement chrome to burn in.

---

# 8. Treat structural presentation as a state machine

M18 exposed a mistake that many editors make: treating adjacent visual sources as independent widget launches.

R3nder instead models presentation stages and handoff relationships.

For adjacent STRUCT placements, the planner knows whether the transition is:

- window -> window;
- fullscreen -> fullscreen;
- window -> fullscreen;
- fullscreen -> window;
- chained/seamless or ordinary.

The presentation system then derives geometry and source-local timing from exact project time.

The user-visible rule is:

> A seamless structural handoff must not expose an unintended terminal, desktop flash, wallpaper frame, or timing pause.

M18's deepest bugs were not decoder bugs. They were ownership bugs around adjacency, geometry, live cover frames, and readiness.

Read `M18_M19_STRUCTURAL_PRESENTATION_JOURNEY.md` before changing this logic.

---

# 9. Program Preview is a real integration layer

Do not confuse the EDIT preview pane with final Program Preview.

They may use related models but they exercise different integration boundaries.

A robust test ladder is:

```text
model/parser test
  ↓
structural preview widget test
  ↓
ProgramPreviewSurface runtime test
  ↓
ProgramStructuralFrameRenderer raster test
  ↓
SceneExporter encoded-file test
  ↓
real GUI visual gate
```

M20 proved why every rung matters.

A lower-level painter can be green while the real program binds the wrong placement metadata.

The top-level runtime marker and the renderer's placement list must describe the same executable placement set.

That sounds obvious after the fix. It was not obvious while the bug appeared only as “DEFAULT works, CUSTOM does not.”

---

# 10. BAKE must be a second evaluator, not a different product

Final export should consume the same authored project and exact project-time semantics as Preview.

The relevant shape is:

```text
for each output project frame i
  scene.evaluate(ProjectTime(frame: i))

  if STRUCT active
    ProgramStructuralFrameRenderer.renderIfActive(...)
  else
    terminal compositor

  ui.Image
    -> raw RGBA
    -> FIFO
    -> ffmpeg
    -> encoded output
```

The final encoder must not decide creative state.

ffmpeg should receive finished pixels and audio streams.

## End-to-end export tests

Do not stop at testing the frame renderer directly.

At least one regression should exercise:

```text
SceneExporter
  -> FIFO
  -> ffmpeg encode
  -> finished MP4/MOV
  -> decode finished file
  -> inspect pixels/streams
```

This proves the real composition rather than only one class in isolation.

---

# 11. Presentation chrome and dynamic frame expressions

M20 added authored STRUCT chrome:

```text
OVERLAY=DEFAULT
OVERLAY=CUSTOM
OVERLAY=NONE
```

CUSTOM placement data may contain dynamic expressions such as:

```text
[frame]
```

The important timing decision is that `[frame]` refers to exact structural source-local frame metadata, not widget paint count or export loop count.

That allows the same value to appear correctly in Edit, Preview, and BAKE.

Chrome is part of authored presentation once exposed as a placement option. Therefore it belongs in final BAKE too.

A “preview-only diagnostic” exemption became invalid the moment DEFAULT/CUSTOM/NONE became authored state.

---

# 12. Render identity is authored state too

M21 added:

```text
[CONFIG:RENDERNAME:documentary_cut]
```

This was intentionally placed in CONFIG rather than a transient export dialog.

Why?

Because render identity belongs with the project.

The output contract becomes:

```text
documentary_cut_1080p_v001.mp4
documentary_cut_1080p_v002.mp4
documentary_cut_1080p_v003.mp4
```

Versions are monotonic across existing siblings rather than “first missing hole wins.”

The exporter also refuses overwrite at two levels:

- path existence check before encode;
- ffmpeg no-overwrite mode.

Fill/matte companions reserve one shared version family.

This subsystem is small, but it demonstrates the same architectural philosophy as the rest of the app:

> Durable creative/output intent belongs in the canonical document whenever practical.

---

# 13. The reconstruction order

If rebuilding from zero, use this order.

Do not start with the pretty timeline.

```text
Phase 1
canonical authored document
lossless parsing / serialization

Phase 2
ProjectClock / ProjectTime
explicit scene evaluation

Phase 3
audio authority
sustained A/V lock validation

Phase 4
EDIT / TRACK / CLIP model
exact frame mapping
split / trim / move semantics

Phase 5
persistent media decoder abstraction
native MLT implementation
fake deterministic test backend

Phase 6
EDIT visual surface
scrub / playback / trim / split / transitions

Phase 7
structural source recursion
EDIT as source
MOSAIC composition

Phase 8
STRUCT placement model
source vs presentation separation

Phase 9
Program Preview
runtime placement markers
seamless structural presentation

Phase 10
SceneExporter
Preview/BAKE parity
real encoded-file tests

Phase 11
placement chrome
fullscreen/windowed presentation
expressions such as [frame]

Phase 12
render identity
versioning
no-overwrite safety
```

The order matters because later phases depend on earlier ownership decisions.

If time and canonical state are ambiguous, every GUI feature built above them becomes harder to reason about.

---

# 14. Failure-domain debugging

When something looks wrong, do not begin by changing the layer where it is visible.

Classify first.

```text
AUTHORED STATE
Did the intended value serialize into the document?

PARSER / PROJECTION
Did the correct runtime model survive preprocessing?

TIME
Did project frame N evaluate to the intended local frame?

SOURCE RESOLUTION
Did the intended EDIT/MOSAIC/CLIP resolve?

DECODE
Did the backend return the requested source frame?

PRESENTATION
Was the correct geometry/chrome/state chosen?

PAINT
Were the intended pixels drawn?

EXPORT HANDOFF
Did those exact pixels reach ffmpeg?

ENCODE
Did the finished file preserve them?
```

M20 is the canonical example.

The symptom was “CUSTOM overlay missing in BAKE.”

Several plausible fixes were wrong:

- font propagation;
- sub-pixel chrome scale;
- raw RGBA / alpha theory;
- ffmpeg stripping text;
- stale document handoff.

The actual bug class was metadata association: runtime marker indexing and raw placement indexing were derived from different transformed views of the document.

The visual source survived. The wrong chrome record could still be selected.

The lesson is:

> Correct pixels with wrong metadata can look like a renderer bug.

---

# 15. Tests that should exist in any reconstruction

A capable clone should have tests equivalent in spirit to these:

## Canonical-state tests

- untouched document round-trips byte-for-byte;
- editing one node does not normalize unrelated syntax;
- structural roots remain protected;
- STRUCT remains a reorderable placement.

## Timing tests

- frame N evaluates deterministically;
- scrub and playback agree;
- audio authority does not drift under decoder load;
- device change re-arms safely.

## Edit-model tests

- clip mapping;
- trim;
- move;
- split;
- speed;
- transition ownership.

## Structural tests

- nested source resolution;
- MOSAIC pane timing;
- fullscreen/windowed placement;
- adjacent placement handoff;
- source-local frame expression expansion;
- runtime marker/placement alignment.

## Integration tests

- EditorScreen closes with exact updated document;
- Program Preview shows authored STRUCT chrome;
- SceneExporter renders structural pixels;
- encoded MP4 retains those pixels;
- versioned BAKE never overwrites previous output.

The test suite is part of the architecture. Do not treat it as cleanup after implementation.

---

# 16. File-reading strategy for a new engineer

A practical reading order is:

1. root `README.md`
2. `docs/BUILDING_A_DETERMINISTIC_NLE.md`
3. this file
4. `docs/REFERENCE.md`
5. `script_pipeline.dart` and parser/CST files
6. `project_clock.dart`, scene evaluator/engine
7. `edit_model.dart`
8. media abstraction/native backend
9. edit workspace/surface files
10. structural sequence/chrome/export files
11. Program Preview
12. `exporter.dart`
13. tests corresponding to each subsystem
14. journey docs last, to understand why the odd-looking safeguards exist

Do not read `main.dart` first and infer the architecture from callbacks.

The UI shell is where subsystems meet. It is not where their contracts are easiest to learn.

---

# 17. What “same ability” really means

A clone has the same class of ability when all of these are true:

```text
I can author a project in one canonical model.

I can edit source-backed video directly.

I can nest reusable sequences into compositions.

I can place those compositions into a larger timed presentation.

I can scrub and play them against deterministic project time.

I can switch presentation modes without introducing hidden time.

I can preview the finished program.

I can bake the same program frame-for-frame.

I can reopen the project and reconstruct the same intent.

I can render repeatedly without destroying earlier versions.
```

That is the architecture worth reproducing.

The UI may change. The media backend may change. The language may change.

But if those contracts survive, you have rebuilt the important part of R3nder Pro.
