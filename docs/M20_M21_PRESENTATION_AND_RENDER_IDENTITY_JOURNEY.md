# M20–M21: Presentation Chrome, Bake Parity, and Render Identity

M20 and M21 looked smaller than M18 and M19 on paper.

They were not.

The visible requests sounded simple:

```text
let STRUCT video chrome be DEFAULT, CUSTOM, or NONE
let the title be editable
let [frame] stay dynamic
make BAKE match Edit
stop overwriting renders
let the project name its own outputs
```

Each request exposed a deeper ownership question.

By the end of M21, the system had gained two important principles:

> Presentation chrome is authored placement state, not preview decoration.

and:

> Render identity belongs to the project, not to a transient export dialog.

This document records how we got there.

---

# Where M20 started

By the end of M19, STRUCT had become a first-class placement node.

An existing generated placement such as:

```text
[STRUCT:MOSAIC.mosaic_2]
```

could be selected in NODES and changed to fullscreen without editing raw syntax by hand:

```text
[STRUCT:MOSAIC.mosaic_2:FULL]
```

The underlying source remained reusable. The placement owned presentation mode.

That naturally exposed the next limitation.

The MLT-backed video player had useful top and bottom overlays and a window title, but they were fixed presentation behavior. Once STRUCT could control presentation, those labels also wanted to become authored state.

The desired model became:

```text
OVERLAY=DEFAULT
OVERLAY=CUSTOM
OVERLAY=NONE
```

with an editable title and optional top/bottom overlay text.

That sounds like a UI feature.

It became an architecture test.

---

# M20 — authored presentation chrome

## The ownership decision

The first question was not how to draw text.

It was who owns the text.

The wrong answer would have been EDIT or MOSAIC.

Those are reusable source definitions.

If `MOSAIC.wall` owned its player title and overlay, every placement of that source would inherit the same presentation.

But the same source may appear differently in two places:

```text
[STRUCT:MOSAIC.wall]

[STRUCT:MOSAIC.wall:FULL:OVERLAY=CUSTOM:
 TITLE="ARCHIVE [frame]":
 TOP="FRAME [frame]":
 BOTTOM="REEL [frame]"]
```

So the correct owner was the STRUCT placement.

That preserved the source/placement boundary established in M19.

---

## DEFAULT, CUSTOM, NONE

The semantic contract became:

### DEFAULT

Use the standard structural player chrome, including the technical readout.

### CUSTOM

Use the authored placement strings.

### NONE

Render no structural player overlays.

The key point was that this was no longer a debug/UI preference.

Once authored in the project, the selected chrome mode had to survive:

```text
NODES
  -> Edit preview
  -> Program Preview
  -> BAKE
```

Any path that treated it as preview-only was now wrong.

---

# The `[frame]` expression

A custom string quickly exposed another need.

Static titles were useful, but the old default overlay had dynamic technical information. We did not want custom chrome to lose that ability.

The solution was a minimal expression:

```text
[frame]
```

For example:

```text
TITLE="MONITOR [frame]"
TOP="FRAME [frame]"
BOTTOM="REEL [frame]"
```

The hard part was deciding what `[frame]` means.

It could not mean:

- widget paint count;
- Flutter ticker count;
- ffmpeg output frame count;
- global program frame by accident.

It needed to mean the exact structural source-local frame currently being presented.

That kept the value stable across Edit, Program Preview, and BAKE.

The contract became:

```text
ProjectTime(frame: N)
  -> active STRUCT placement
  -> structural local frame
  -> source-local frame metadata
  -> expand [frame]
```

The expression is small. The ownership underneath it is not.

---

# The bake bug that refused to die

Edit showed the new overlays correctly.

Final BAKE did not.

This became one of the more instructive debugging sequences in the project because several plausible theories were wrong.

## Hypothesis 1: BAKE was not using an explicit font

The offscreen structural painter received a font family but did not pass it into every TextPainter.

That was a real defect and was fixed.

It was not the whole problem.

The real bake still lost CUSTOM chrome.

## Hypothesis 2: the new raster test was enough

A focused test proved `ProgramStructuralFrameRenderer` could draw the chrome.

Still, the real BAKE failed.

That taught us again that a renderer unit test is not an export test.

## Hypothesis 3: ffmpeg was stripping the text pixels

A true end-to-end test was built:

```text
SceneExporter
  -> FIFO
  -> ffmpeg encode
  -> MP4
  -> ffmpeg decode
  -> inspect encoded pixels
```

That path preserved the chrome.

So ffmpeg was innocent.

## Hypothesis 4: the dashboard had stale document text

The editor close handoff was traced and tested.

Node edits survived through EditorScreen and returned to the dashboard document.

That path was also correct.

## Hypothesis 5: fullscreen MOSAIC behaved differently from EDIT

A dedicated encoded FULL + MOSAIC + CUSTOM test was added.

It passed.

The controlled renderer/export path was still correct.

At this point the remaining bug had to depend on realistic document structure rather than simple single-placement fixtures.

---

# The actual M20 bug: two placement indexes that only looked equivalent

The crucial discovery was that runtime markers and structural chrome metadata were not guaranteed to be indexed from the same transformed document.

The runtime program numbered executable STRUCT placements after projection/root stripping.

The structural renderer rebuilt placement metadata from the raw document.

Those lists usually looked identical.

They were not guaranteed to be identical.

A STRUCT-looking line inside reusable source metadata, or markup that disappeared during projection, could shift one list without shifting the other.

That produced a particularly confusing symptom:

```text
correct structural video
wrong placement chrome
```

The renderer could be perfectly capable of drawing CUSTOM text and still receive the metadata for a different placement.

DEFAULT appearing in BAKE did not prove the intended CUSTOM placement had reached the renderer.

The fix aligned both systems around the same executable placement set.

The production rule became:

> Runtime STRUCT markers and render metadata must be derived from the same valid, executable placements in the same order.

This is the kind of invariant that should live in tests forever.

---

# Why the M20 test ladder matters

The final regression coverage became intentionally layered.

```text
parser / structural placement test
    ↓
Editor Node control test
    ↓
EditorScreen close-handoff test
    ↓
ProgramPreviewSurface runtime test
    ↓
ProgramStructuralFrameRenderer raster test
    ↓
SceneExporter encoded MP4 test
    ↓
real GUI bake
```

Each level answered a different question.

The bug survived several lower levels because the defect was not inside those lower layers.

This became one of the best examples in the repository of why end-to-end semantic tests are architectural documentation.

---

# Source export versus program BAKE

During the same investigation we found a UX ambiguity.

The EDIT/MOSAIC workspace had an `EXPORT` action that exported the reusable source itself.

A reusable source has no STRUCT placement identity.

Therefore it cannot include placement-owned chrome.

That action was renamed to make the boundary explicit:

```text
SOURCE OUTPUT
EXPORT SOURCE
```

The main dashboard BAKE remains the finished program render.

The distinction is now conceptually clean:

```text
EXPORT SOURCE
  -> EDIT/MOSAIC content only

BAKE
  -> whole program
  -> STRUCT presentation included
```

This is another direct consequence of source/placement separation.

---

# M21 — render identity and no-overwrite versioning

Once BAKE was trustworthy, another long-standing weakness became obvious.

Repeated renders could overwrite earlier output.

For an NLE-like tool, that is not acceptable.

The first idea was simply “custom output filename.”

The better design became:

```text
[CONFIG:RENDERNAME:documentary_cut]
```

That choice deserves emphasis.

We could have put render naming in a transient export dialog or app preference.

Instead, we made render identity part of the authored project.

Why?

Because the name belongs to the thing being rendered.

It should travel with the template, survive reopen, participate in version control, and be visible to automation.

The same design philosophy that made the script canonical for editing also made it the right home for render identity.

---

# Version semantics

Given:

```text
[CONFIG:RENDERNAME:documentary_cut]
```

BAKE produces:

```text
documentary_cut_1080p_v001.mp4
documentary_cut_1080p_v002.mp4
documentary_cut_1080p_v003.mp4
```

The version rule is monotonic.

If v002 is deleted but v003 exists, the next render is v004.

We deliberately did not use “first missing hole.”

Version numbers represent successive render generations, not available slots.

The naming layer also handles:

- unsafe filename sanitization;
- resolution identity;
- preroll output family separation;
- MP4/MOV format changes;
- fill/matte companion reservation.

---

# No-overwrite became a hard export contract

Version planning reduces collisions.

It does not make collision impossible.

Another process could create the planned path between naming and ffmpeg startup.

So no-overwrite protection exists at two layers:

```text
1. exporter checks whether target or matte companion already exists
2. ffmpeg runs with no-overwrite behavior
```

The final contract is stronger than “we usually generate a new name.”

It is:

> A successful BAKE must never replace bytes that already existed at its target path.

That is the correct behavior for an editing/rendering tool.

---

# Why CONFIG was the right home

M21 ended up reinforcing the project's central idea in a surprisingly elegant way.

A render name could have become another dashboard field.

Instead:

```text
[CONFIG:RENDERNAME:documentary_cut]
```

made it ordinary project state.

That gives us:

- project portability;
- visible intent;
- diffability;
- deterministic automation;
- no hidden export preference;
- a natural Node Mode editing surface.

The solution felt obvious only after we found it.

That is usually a good sign.

---

# What M20 and M21 taught us

## 1. Once a display option is authored, it is not “preview chrome” anymore

If the user can choose it in the project, final output must respect it unless the product explicitly says otherwise.

## 2. A green renderer unit test does not prove a real export

Test the composition that the user actually invokes.

## 3. Correct video with wrong labels may be a metadata-association bug

Do not assume a missing overlay is a text/painter problem.

## 4. Source and placement must remain separate even when the UI makes them feel adjacent

This protected us from putting title/chrome on MOSAIC itself and later explained why source export cannot include STRUCT presentation.

## 5. Dynamic expressions need exact semantic time

`[frame]` works because it expands from source-local structural metadata, not from rendering cadence.

## 6. Output naming is project state when it carries creative/workflow identity

The CONFIG solution is stronger than a remembered export-dialog field.

## 7. No-overwrite should be enforced, not merely intended

The exporter and ffmpeg both refuse replacement.

---

# The journey from M18 through M21

Taken together, these four milestones form one larger arc:

```text
M18
STRUCT applications can hand off seamlessly

M19
STRUCT presentation becomes first-class editable placement state

M20
STRUCT presentation chrome becomes authored and Preview/BAKE identical

M21
BAKE output gains authored identity and safe version history
```

The result is more than “video inside a terminal renderer.”

It is a coherent editing/presentation system where:

- sources are reusable;
- placements are contextual;
- time is deterministic;
- UI edits serialize back into one project;
- Preview and BAKE share the same frame contract;
- final output carries project-authored identity;
- repeated renders preserve history instead of destroying it.

Those are NLE properties.

The important part is that they were reached without abandoning the original R3nder principle:

> The script is the project.
