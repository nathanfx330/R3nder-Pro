# R3nder Pro Documentation Map

This directory has one job: make the system understandable enough that another engineer can reconstruct an editor of the same class without depending on tribal knowledge.

That means the documentation is not only a user manual and not only a history. It is an executable architectural record.

The target reader should be able to answer four questions from the repository alone:

1. What is canonical project state?
2. Who owns project time?
3. How does a source frame become a program pixel?
4. Which tests prove that Preview, Edit, and BAKE agree?

If those answers are unclear, the documentation is incomplete.

---

## Read in this order

### 1. `README.md` at repository root

Start there for the product model:

```text
TEXT
  ↓
EDIT
  ↓
MOSAIC
  ↓
STRUCT
  ↓
PREVIEW
  ↓
BAKE
```

The most important rule in the project is introduced there:

> The script is the project.

The GUI is an editor over that project, not a second project database.

### 2. `BUILDING_A_DETERMINISTIC_NLE.md`

This is the transferable engineering guide.

Read it if you want to build another editor with the same architectural properties but not necessarily the same UI or language.

It covers:

- authoritative project time;
- audio-clock ownership;
- lossless authored state;
- clip timing;
- persistent media decode;
- source/placement separation;
- preview/export parity;
- debugging by failure domain;
- semantic regression testing.

### 3. `REBUILDING_R3NDER_PRO.md`

This is the implementation map.

Read it if the question is:

> If I had this repository but had to rebuild the editor from scratch, what would I implement, in what order, and which files define each contract?

It maps the major subsystems, their ownership boundaries, the reconstruction order, and the tests that act as architectural proof.

### 4. `REFERENCE.md`

This is the language and media reference.

Use it when you need exact authored syntax and behavior.

### 5. Journey documents

The journey documents explain why the architecture looks the way it does.

They preserve failed hypotheses, misleading symptoms, and the engineering battles that are easy to forget once the final implementation looks obvious.

Read:

- `R3NDER_PRO_JOURNEY_TO_STRUCTURAL_VIDEO.md` — ProjectClock through structural video and Preview/BAKE parity.
- `M18_M19_STRUCTURAL_PRESENTATION_JOURNEY.md` — seamless structural application switching and first-class fullscreen STRUCT authoring.
- `M20_M21_PRESENTATION_AND_RENDER_IDENTITY_JOURNEY.md` — authored player chrome, dynamic `[frame]` expressions, bake parity, render naming, and no-overwrite versioning.
- `EDIT_PLAYBACK_PERFORMANCE.md` — measured editor playback investigation.
- `M4_AV_LOCK_VALIDATION.md` — native A/V lock validation.

### 6. Visual gates

Some contracts are not adequately captured by model tests.

`M18_STRUCT_APP_SWITCH_VISUAL_GATE.md` and its fixture preserve one such case: continuity during adjacent structural application handoff.

These files exist because a deterministic model can still produce a visually wrong result if paint/readiness ownership is wrong.

---

# Documentation philosophy

R3nder Pro should be documented as five layers, not as a list of widgets.

## Layer 1 — Authored state

Questions:

- What does the user actually author?
- Which syntax owns the fact?
- Can the GUI close and reconstruct itself from that state?

Primary files include the parser/CST, script node model, edit model, structural sequence model, config model, and reference documentation.

## Layer 2 — Time

Questions:

- Who owns project frame N?
- Which clocks are authorities and which are observers?
- Can project frame N be reproduced without wall-clock dependence?

Primary concepts include `ProjectClock`, `ProjectTime`, explicit scene evaluation, audio authority, and exact frame mapping.

## Layer 3 — Source evaluation

Questions:

- Given project frame N, which source frame is requested?
- Who owns clip geometry?
- Who owns structural nesting?
- Where does MLT stop and R3nder begin?

Primary concepts include EDIT, TRACK, CLIP, MOSAIC, persistent media decoders, source references, transitions, and structural sequence placements.

## Layer 4 — Presentation

Questions:

- How is the evaluated source shown?
- Windowed or fullscreen?
- Which title/overlay belongs to the placement rather than the source?
- How are adjacent structural applications chained?

Primary concepts include STRUCT presentation mode, structural chrome, seamless application switching, first-frame readiness, and top-level Program Preview.

## Layer 5 — Finalization

Questions:

- Does BAKE render the same authored frame contract as Preview?
- How are audio and structural video composed into final output?
- How are render files named and protected from overwrite?

Primary concepts include `SceneExporter`, `ProgramStructuralFrameRenderer`, ffmpeg handoff, `RENDERNAME`, monotonic versions, and no-overwrite behavior.

---

# The reconstruction standard

A subsystem is not fully documented merely because its classes are named.

For each major subsystem we want four things:

```text
CONTRACT
What the subsystem promises.

OWNERSHIP
Which layer owns each fact.

DATA FLOW
What enters, what leaves, and which transformations occur.

PROOF
Which tests demonstrate the contract.
```

Example:

```text
STRUCT presentation chrome

CONTRACT
A placement may be windowed or fullscreen and may use DEFAULT, CUSTOM,
or NONE chrome. CUSTOM expressions such as [frame] resolve from exact
structural source-local frame metadata.

OWNERSHIP
The STRUCT placement owns the presentation chrome. EDIT/MOSAIC source
definitions do not.

DATA FLOW
serialized STRUCT
  -> StructuralSequencePlacement
  -> ProgramPreviewSurface / ProgramStructuralFrameRenderer
  -> exact frame metadata
  -> rendered title/overlays

PROOF
preview runtime tests + SceneExporter encoded MP4 tests
```

That is the level of documentation required if the repo is supposed to teach another engineer how to rebuild the system.

---

# Tests are part of the documentation

R3nder's most valuable tests are not line-coverage tests. They are executable statements of product truth.

Examples of useful proof classes:

- parser round-trip tests;
- frame mapping tests;
- A/V lock tests;
- structural marker alignment tests;
- top-level Program Preview tests;
- encoded SceneExporter tests;
- EditorScreen handoff tests;
- render naming/versioning tests;
- visual gates for seams that only appear in realistic GUI composition.

When a bug requires three or four isolated tests before the real failure appears, the missing end-to-end test becomes part of the architecture afterward.

The M20 chrome bug is the model example: painter tests were green, then Program Preview was green, then isolated SceneExporter was green, and only realistic placement association exposed the defect. The final regression now documents that ownership rule better than a paragraph alone could.

---

# What remains to document

The repository already has strong narrative and reference documentation, but reconstruction-grade documentation should continue until these areas each have an explicit subsystem page:

- project clock and audio authority;
- script pipeline and lossless CST;
- EDIT timing model and edit operations;
- persistent MLT decoder lifecycle;
- structural source recursion and composition;
- MOSAIC pane/timeline semantics;
- STRUCT planning, presentation, and chrome;
- Preview architecture;
- BAKE architecture and ffmpeg handoff;
- audio bed/music graph;
- render naming/versioning;
- workspace asset ownership;
- GUI-to-script mutation contracts;
- native Linux integration.

The objective is not more prose for its own sake.

The objective is that a technically competent reader can begin with authored text and independently reproduce the same chain:

```text
canonical document
  -> exact project time
  -> exact source frame
  -> deterministic composition
  -> interactive NLE controls
  -> preview
  -> final encoded output
```

When that is possible from the repository alone, the documentation is doing its job.
