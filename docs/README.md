# R3nder Pro Documentation Map

This directory has one job: make the system understandable enough that another engineer can reconstruct an editor of the same class without depending on tribal knowledge.

The documentation is therefore not only a user manual and not only a development history. It is an architectural inheritance package.

A reader should be able to answer, from the repository alone:

1. What is canonical project state?
2. Who owns project time?
3. How does project frame N become a leaf-media source frame?
4. How do nested EDIT/MOSAIC sources become one structural frame?
5. How does STRUCT place that frame into the main program?
6. Why do Preview and BAKE agree?
7. Which layer owns audio timing?
8. How does the GUI mutate the project without becoming a second database?
9. How are final renders versioned without overwriting history?
10. Which tests prove each contract?
11. How do I validate those contracts on real Linux/audio/media/display hardware?

If those answers are unclear, the documentation is incomplete.

---

# Choose the right document

Several files intentionally cover the same architecture from different directions. Do not read all of them as if they were one linear manual.

| Document | Read this when you want... | Do not use it as... |
| --- | --- | --- |
| repository `README.md` | the product model and first run | an implementation specification |
| `REBUILDING_R3NDER_PRO.md` | the order and architecture needed to rebuild the NLE | an exact tag reference |
| `RECONSTRUCTION_BRINGUP.md` | the staged real-machine validation route after the architecture exists | a substitute for architecture/model design |
| subsystem specifications | ownership, data flow, implementation seams, and proof for one subsystem | a development chronology |
| `BUILDING_A_DETERMINISTIC_NLE.md` | transferable engineering lessons for another editor | a file-by-file map of R3nder |
| `REFERENCE.md` | exact author-facing language/tag/media behavior | an explanation of why the architecture exists |
| journey documents | why decisions were made, failed hypotheses, and historical debugging lessons | the shortest route to a current contract |
| `CONTRACT_TEST_MANIFEST.md` | the minimum contract → proof spine that must not drift | a replacement for running the tests |
| `TEST_STRATEGY.md` | how to choose the correct testing boundary | a catalog of every test in the repository |

That distinction matters. A 45 KB journey document may be the best place to understand *why* a bug existed and the worst place to look up the current ownership contract.

---

# Read in this order

## 1. Repository `README.md`

**Read this if:** you are new to the product and need the vocabulary.

**Skip ahead if:** you already understand TEXT → EDIT → MOSAIC → STRUCT → PREVIEW → BAKE.

Start with the product model:

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

The core rule appears there:

> The script is the project.

The GUI edits that project. It is not a second project database.

---

## 2. `REBUILDING_R3NDER_PRO.md`

**Read this if:** the question is “how would I rebuild an NLE with these capabilities and guarantees?”

**Do not use it for:** exact syntax details or the full historical narrative.

This is the top-level reconstruction plan.

It connects canonical state, deterministic time, EDIT, persistent MLT, MOSAIC, STRUCT, Preview, BAKE, and output identity.

---

## 3. Subsystem specifications

**Read these if:** you are changing or rebuilding one ownership boundary.

**Do not use them for:** the chronological story of how that boundary was discovered.

These are the implementation-grade ownership documents.

### `PROJECT_TIME_AND_AUDIO.md`

ProjectClock, ProjectTime, explicit scene evaluation, realtime versus export scheduling, native audio authority, latency, epochs, and A/V lock.

### `SCRIPT_AND_CST.md`

Canonical authored state, lossless CST ownership, ScriptNode round-trip, CONFIG, one compile pipeline, structural projection, and editor line mapping.

### `EDIT_MODEL.md`

EDIT/TRACK/CLIP semantics, exact rational speed, frame mapping, duration ownership, add/move/trim/split operations, edge transitions, track composition, and graph lint.

### `MEDIA_AND_MLT.md`

Persistent decoder identity, exact versus nonblocking decode policy, requested/actual source-frame identity, stale-result rejection, structural recursion boundary, and diagnostic provenance.

### `STRUCTURAL_COMPOSITION.md`

EDIT as a reusable source, MOSAIC pane composition, STRUCT placement semantics, presentation-owned chrome, executable adjacency, APPSWITCH planning, runtime markers, and source export versus program placement.

### `PREVIEW_AND_BAKE.md`

ProgramPreviewSurface, structural readiness/paint ownership, exact BAKE frame iteration, ProgramStructuralFrameRenderer, ffmpeg handoff, source export versus final BAKE, and the M20 placement-association failure.

### `GUI_MUTATION_CONTRACTS.md`

View state versus project state, NODES ownership, protected structural roots, first-class STRUCT/CONFIG editing, EDIT text mutations, editor-close handoff, asset invalidation, and UI naming of ownership boundaries.

### `RENDER_OUTPUTS.md`

`RENDERNAME`, filename sanitization, monotonic versions, format-independent version families, fill/matte reservation, preroll families, and two-layer no-overwrite protection.

### `LINUX_NATIVE_LAYER.md`

Linux CMake/native runner architecture, native ProjectClock, PulseAudio sink, persistent MLT decode, external textures, threading/lifetime, and native validation.

### `TEST_STRATEGY.md`

The proof architecture: pure model tests, widget handoff tests, fake media backends, native probes, Program Preview tests, structural BAKE tests, real SceneExporter→ffmpeg encoded tests, and visual gates.

### `CONTRACT_TEST_MANIFEST.md`

The minimum contract → proof map. Every numbered contract names the test/probe/visual-gate files that currently prove it.

Run:

```bash
dart run tool/check_doc_contracts.dart
```

to catch renamed or deleted proof files before the written architecture silently drifts away from the repository.

---

## 4. `RECONSTRUCTION_BRINGUP.md`

**Read this when:** the architecture exists and you need to make it survive contact with real Linux hardware.

**Do not use it for:** deciding who should own project state or time. Those decisions must already be settled.

This is the practical integration companion to the reconstruction guide.

It gives a staged route through:

```text
repository integrity
→ compile/launch
→ exact ProjectTime
→ PulseAudio authority
→ persistent MLT decode
→ EDIT presentation timing
→ structural recursion
→ STRUCT readiness/presentation
→ Program Preview
→ whole-program BAKE
→ encoded output
→ render version safety
```

It also provides a symptom → likely boundary map, the accepted M4 audio/MLT measurement shape, the EDIT `FrameTiming` procedure, the M18 visual gate, encoded SceneExporter validation, and a measurement-session discipline for hardware-only failures.

This is the document intended to reduce the “last 20%” integration cost. It cannot remove hardware observation; it is meant to stop an engineer spending that observation time at the wrong layer.

---

## 5. `BUILDING_A_DETERMINISTIC_NLE.md`

**Read this if:** you are building another editor and want the transferable lessons.

**Do not use it for:** exact current class names or the shortest path to a R3nder-specific implementation detail.

Its central lessons are:

- decide who owns project time first;
- choose one canonical authored model;
- store authored facts and derive consequences;
- keep the media backend below the timeline model;
- make decode persistent before polishing the GUI;
- separate source definition from program placement;
- treat readiness as presentation state, never timing;
- force Preview and export through the same authored frame contract;
- debug by failure domain;
- write semantic regressions rather than implementation-trivia tests.

---

## 6. `REFERENCE.md`

**Read this if:** you need exact author-facing syntax or media behavior.

**Do not use it for:** architectural ownership or debugging history.

The subsystem specifications explain *why* ownership is arranged the way it is. REFERENCE explains the concrete author-facing surface.

---

# Development history

**Read these when:** you need to understand why a current contract exists, what misleading symptoms looked like, or which failed hypotheses were eliminated.

**Do not start here when:** you merely need the current contract or API surface.

The journey documents preserve why the final architecture exists and what misleading failures taught us.

## `R3NDER_PRO_JOURNEY_TO_STRUCTURAL_VIDEO.md`

ProjectClock through structural video, Preview, and BAKE parity.

## `M18_M19_STRUCTURAL_PRESENTATION_JOURNEY.md`

Two of the hardest structural milestones: executable adjacency, seamless application switching, outgoing-shell readiness ownership, fullscreen/windowed presentation, and first-class STRUCT authoring.

## `M20_M21_PRESENTATION_AND_RENDER_IDENTITY_JOURNEY.md`

Player chrome, DEFAULT/CUSTOM/NONE, `[frame]`, missing custom overlays in final BAKE, runtime placement-index alignment, source export versus final BAKE, `RENDERNAME`, monotonic versions, and no-overwrite output.

## `EDIT_PLAYBACK_PERFORMANCE.md`

Measured EDIT playback performance and separation of native decode timing from Flutter UI repaint cost.

## `M4_AV_LOCK_VALIDATION.md`

Measured native audio authority and A/V lock while persistent MLT decoding runs concurrently.

---

# Visual acceptance documents

Some guarantees are visible composition contracts rather than pure model properties.

Read:

- `M18_STRUCT_APP_SWITCH_VISUAL_GATE.md`
- `M18_STRUCT_APP_SWITCH_VISUAL_FIXTURE.txt`

These exist because a deterministic model can still produce a visually wrong frame when paint/readiness ownership is incorrect.

---

# Documentation standard

Every subsystem page should answer four things.

```text
CONTRACT
What must always be true?

OWNERSHIP
Which layer owns each fact?

DATA FLOW
What enters, what leaves, and how is identity transformed?

PROOF
Which tests or measurements demonstrate the contract?
```

Example:

```text
STRUCT presentation chrome

CONTRACT
A placement can be windowed/fullscreen and DEFAULT/CUSTOM/NONE.
Dynamic [frame] copy resolves deterministically.

OWNERSHIP
STRUCT placement owns chrome.
EDIT/MOSAIC source does not.

DATA FLOW
authored STRUCT
  → StructuralChromeSpec
  → StructuralSequencePlacement
  → runtime marker / exact local frame
  → Preview or ProgramStructuralFrameRenderer
  → final pixels

PROOF
parser tests
+ Program Preview runtime tests
+ encoded SceneExporter tests
+ real visual BAKE gate
```

The corresponding concrete proof filenames belong in `CONTRACT_TEST_MANIFEST.md`, not only in prose.

---

# The reconstruction path

If rebuilding the editor from zero, use this order:

```text
1. Canonical authored document
2. Lossless structural ownership / CST
3. Exact ProjectTime and explicit evaluation seam
4. Native realtime/audio clock authority
5. EDIT / TRACK / CLIP model
6. Model-level add/move/trim/split/transition operations
7. Persistent leaf-media backend
8. Exact and nonblocking source-frame delivery
9. EDIT pixel compositor
10. Structural recursion
11. MOSAIC pane composition
12. STRUCT main-sequence placement planning
13. Visual NLE controls over authored operations
14. Program Preview runtime bridge
15. Exact structural source export
16. Whole-program structural BAKE
17. Presentation chrome and dynamic expressions
18. Audio mux/final output formats
19. Project-authored render identity and version safety
20. End-to-end encoded and visual acceptance gates
21. Target-hardware bring-up through `RECONSTRUCTION_BRINGUP.md`
```

Do not reverse the first half of that list.

A polished timeline built before canonical timing/model/media ownership is settled tends to become a second application that later has to be reconciled with the renderer.

---

# Tests are documentation

The strongest tests in this repository describe product truths.

Examples:

```text
split preserves exact source mapping

hidden source metadata does not shift STRUCT runtime marker identity

EditorScreen preserves CUSTOM STRUCT chrome through NODES → EDIT → close

SceneExporter preserves FULL MOSAIC CUSTOM chrome in encoded H.264

render versions remain monotonic across deleted gaps
```

When a production bug appears despite green unit tests, add a regression across the missing ownership boundary rather than only adding assertions deeper inside the already-green unit.

`TEST_STRATEGY.md` explains how to choose that boundary. `CONTRACT_TEST_MANIFEST.md` names the proof spine that must continue to exist. `RECONSTRUCTION_BRINGUP.md` explains how to turn hardware-only observations into evidence instead of guesses.

---

# Documentation drift is a build problem

Contracts rot when class names, test files, or ownership boundaries change and prose is not updated.

The first automated guard is intentionally small:

```bash
dart run tool/check_doc_contracts.dart
```

It verifies that every repository proof path named by the numbered contracts in `CONTRACT_TEST_MANIFEST.md` still exists.

This does not replace running the suite. It prevents a quieter failure: documentation continuing to claim proof from a test that no longer exists.

When a contract changes deliberately, update the implementation, its proving tests, the relevant subsystem page, and the manifest in the same change.

When a proof file is substantially rewritten or repurposed, re-check every contract that cites it. File existence proves attachment, not semantic honesty.

---

# What is still worth documenting

The reconstruction-critical NLE path and its target-hardware bring-up route are now covered by dedicated pages.

The next documentation areas should be narrower supporting systems rather than more broad architecture essays:

- workspace/asset import and portability;
- image-folder ordering/caption sidecars;
- terminal/presentation tag implementation internals;
- music/voice preview lifecycle in more operational detail;
- release/build/packaging procedures;
- platform parity if macOS/Windows become supported production targets.

The objective is not documentation volume.

The objective is that a technically competent reader can begin with the project document and reproduce this chain without oral explanation:

```text
canonical authored state
  → exact project time
  → exact active clip
  → exact source frame
  → deterministic recursive composition
  → direct-manipulation NLE edits
  → structural program placement
  → live Preview
  → identical final BAKE semantics
  → safe versioned output
  → measured acceptance on the target machine
```

When the repository itself teaches that chain, the documentation is doing its job.