# EDIT Model and Editing Operations

This page describes the authored NLE model underneath the visual timeline.

The EDIT surface is not the source of truth. It is a direct-manipulation view over the script-owned structural model.

Primary files:

- `lib/edit_model.dart`
- `lib/edit_surface_model.dart`
- `lib/edit_surface.dart`
- `lib/edit_linter.dart`
- `lib/edit_media_import.dart`
- `lib/edit_video_compositor.dart`

Representative tests:

- `test/edit_model_test.dart`
- `test/edit_model_validation_test.dart`
- `test/edit_surface_model_test.dart`
- `test/edit_surface_test.dart`
- `test/edit_clip_creation_test.dart`
- `test/edit_edge_transition_test.dart`
- `test/edit_edge_transition_ui_test.dart`
- `test/edit_v2_and_long_xfade_ui_test.dart`

---

## Contract

An EDIT is an authored project-time sequence of CLIPs on TRACKs.

The model must guarantee:

- clip position is expressed in project frames;
- source IN is expressed in source frames;
- duration is authored in project frames;
- speed is exact rational state;
- source frame lookup is deterministic;
- source duration does not silently change because media is missing or replaced;
- split/move/trim operations preserve source mapping;
- transitions have explicit edge ownership;
- visual operations return new authored script text;
- no edit operation creates a parallel durable project database.

Canonical structure:

```text
[EDIT:main]
  [TRACK:V1]
    [CLIP:clipA:video/a.mp4:0:120:90:1]
    [/CLIP]
  [/TRACK]
[/EDIT]
```

Conceptually the CLIP header contains:

```text
id
source
AT
IN
DURATION
SPEED
```

---

# 1. Store authored facts, derive consequences

R3nder deliberately avoids redundant timing truths where possible.

A CLIP stores:

```text
atFrame
inFrame
durationFrames
speed
```

Its project end is derived:

```text
endFrameExclusive = atFrame + durationFrames
```

The integer source frame at local project offset `p` is:

```text
IN + floor(p * speedNumerator / speedDenominator)
```

This is implemented by `EditClip.sourceFrameAtProjectOffset()`.

Do not add a second editable OUT field unless the model also defines exactly how OUT, duration, IN, and speed reconcile after every operation.

A useful general rule is:

> Store facts the author chose. Derive values that are consequences of those facts.

---

# 2. Speed is exact

`ExactClipSpeed` stores a reduced numerator/denominator.

It accepts integer, decimal, or rational authoring forms but converts them into exact rational state.

Why this matters:

- repeated frame mapping should not accumulate floating-point error;
- splits must preserve the same source relationship;
- nested structural evaluation depends on exact integer source requests;
- Preview and BAKE must agree at long durations and non-integer rates.

The canonical source-frame mapping floors the rational position because the authored media contract is frame-exact.

---

# 3. Duration belongs to the authored container

`EditDocumentModel` explicitly treats clip and structural source duration as authored state.

Missing media is a decode problem, not a duration rewrite.

That distinction allows the project to remain stable when:

- a file is temporarily offline;
- media is replaced;
- a decoder fails;
- a nested source is not yet ready.

The timeline must not collapse or stretch because the media backend cannot currently produce pixels.

For EDIT, sequence duration is the greatest clip end across its tracks.

For MOSAIC, duration is the greatest pane-local clip end across panes.

---

# 4. Source references can be leaf or structural

A CLIP source may be a media resource or a canonical structural reference:

```text
video/file.mp4
EDIT.main
MOSAIC.wall
```

`StructuralSourceRef` makes EDIT and MOSAIC namespaces explicit.

This prevents ambiguity and gives recursive composition a canonical spelling.

The edit model itself recognizes structural references but does not decode them as files. Recursive resolution happens in the compositor.

---

# 5. The edit surface model returns text

`EditSurfaceDocument` is the mutation API used by the visual NLE.

Its file header states the central rule directly: it owns no project database.

Operations conceptually look like:

```text
current authored text
    ↓
parse EditSurfaceDocument
    ↓
perform one operation
    ↓
return new authored text
    ↓
reparse for fresh spans/model
```

That shape matters more than the widget implementation.

A reconstruction should make model operations usable without Flutter first. The GUI then becomes a client of a proven text mutation layer.

---

# 6. Core editing operations

A useful minimum set is:

## Create

Create an EDIT, TRACK, and first CLIP from an imported media asset.

The operation must validate identifiers, media source spelling, non-negative AT, and positive duration.

## Add clip

Insert a new CLIP into a CST-owned TRACK.

The insertion should be anchored to the TRACK's closing tag rather than a guessed raw offset.

## Move

Change project AT without changing source IN.

The project location changes; source sampling does not.

## Trim head

Moving the left edge normally changes:

```text
AT
IN
DURATION
```

while preserving the mapping of the surviving visual frames.

## Trim tail

Changes duration while preserving AT and IN.

## Split

A split is one of the best model correctness tests.

For a split at local project offset `s`:

```text
left.duration = s
right.at       = old.at + s
right.in       = sourceFrameAtProjectOffset(s)
right.duration = old.duration - s
right.speed    = old.speed
```

The two clips must reproduce the original source mapping with no gap or duplication at the boundary according to the project's discrete-frame convention.

## Track move

Changing V1/V2 membership is a structural ownership change: remove from one TRACK and insert into another while retaining the CLIP's authored timing/source facts.

## Speed

Speed changes the source mapping but does not silently invent a new project duration unless the operation explicitly says so.

---

# 7. Transition ownership is on edges

R3nder supports explicit incoming and outgoing transitions.

Incoming historical directives include:

```text
[#EDIT_TRANSITION:CROSSFADE:N]
[#EDIT_TRANSITION:LUMA:path:N]
```

Outgoing crossfade is represented separately:

```text
[#EDIT_TRANSITION_OUT:CROSSFADE:N]
```

This matters because saying “clip has a transition” is ambiguous.

A clip has a left edge and a right edge, and operations such as split or reorder need to know which edge owns which authored transition.

The transition model therefore carries:

```text
incoming transition
outgoing transition
```

A split must preserve edge ownership intentionally rather than copying all transition metadata blindly to both halves.

---

# 8. Track ordering and composition

EDIT tracks define compositing depth/order. The compositor decides which active CLIPs contribute at a requested ProjectTime.

V1/V2 are editor-facing names, but the deeper contract is:

```text
track membership + authored order
    → deterministic contributor order
```

The compositor is not allowed to choose project time. It receives an exact `ProjectTime` and resolves active clips against it.

---

# 9. Media import is project authoring

Imported media is copied into the workspace rather than leaving arbitrary external absolute paths as project dependencies.

The project then references a workspace-relative media source.

A reconstruction should treat import as two coordinated operations:

```text
filesystem ownership
    +
authored script mutation
```

The source path in the project should remain portable inside the workspace.

Do not make media import only a UI file-picker feature. It is part of project reproducibility.

---

# 10. Graph lint before recursive render

Once CLIPs can reference EDIT/MOSAIC sources, the model becomes a graph.

The linter must reject or diagnose:

- cycles;
- excessive nesting;
- missing structural references;
- unsupported relationships.

The runtime compositor also carries an independent recursion depth guard as defense in depth.

Do not rely solely on preflight lint to prevent unbounded recursion in the renderer.

---

# 11. GUI coordinate conversion

The visual timeline converts pointer positions into authored frames.

That conversion must be explicit and centralized:

```text
screen X
    ↓
scroll/zoom transform
    ↓
project frame
    ↓
model operation
```

Do not let drag widgets mutate pixel positions as durable state.

Pixel position is a view coordinate. `atFrame` is project state.

The same rule applies to trim handles: pointer movement becomes an integer frame delta, then the model decides the authored consequences.

---

# 12. Failure modes to recognize

## Split looks right but later drifts

The right clip's IN was probably computed from a rounded UI quantity instead of exact source mapping.

## Moving a clip rewrites comments around it

The operation regenerated an enclosing EDIT rather than replacing CST-owned spans.

## Missing media changes sequence duration

Decode state has leaked into authored geometry.

## Long/non-integer speed differs between Preview and BAKE

Floating-point speed became canonical somewhere in the mapping path.

## Transition jumps to the wrong side after split

Transition ownership was modeled as a clip property rather than edge properties.

## Timeline drag feels correct but reopening moves the clip back

The widget mutated local state without writing the authored document.

---

# 13. Proof

The EDIT model should be considered trustworthy only when model tests cover operations independent of Flutter.

Useful proof includes:

```text
edit_model_test.dart
edit_model_validation_test.dart
edit_surface_model_test.dart
edit_clip_creation_test.dart
edit_edge_transition_test.dart
```

Widget tests then prove the GUI calls those operations correctly:

```text
edit_surface_test.dart
edit_edge_transition_ui_test.dart
edit_v2_and_long_xfade_ui_test.dart
```

The hierarchy of proof is important:

```text
model semantics first
GUI wiring second
real playback third
```

A widget test should not be the only specification of clip arithmetic.

---

# Reconstruction checklist

Before calling the timeline an NLE, prove:

- [ ] CLIP geometry is integer project/source frame state;
- [ ] speed is exact rational state;
- [ ] OUT/end is derived where possible;
- [ ] source frame lookup is deterministic;
- [ ] missing media cannot change authored duration;
- [ ] create/add/move/trim/split are model operations independent of Flutter;
- [ ] operations return authored text, not hidden model state;
- [ ] split preserves source mapping;
- [ ] transition ownership is edge-specific;
- [ ] recursive structural references are linted;
- [ ] runtime recursion is independently bounded;
- [ ] timeline pixel coordinates are converted into project frames before mutation;
- [ ] reopening from the document reconstructs the same edit.

When these are true, the timeline UI is a view over a real editing model rather than a draggable mock-up.