# MOSAIC Layout Program Journey

Status: **MILESTONE COMPLETE.** The initial MOSAIC Layout Program merged to
`main` through PR #30 at
`6b16ec29bcfe95e3e4fb25d15818b2bf74c8c144`. Post-merge GUI testing exposed
resident-pixel, recall, and exit-paintability defects; those stabilization fixes
landed directly on `main`. The focused gate reached 51 passing tests after the
TWO UP → ONE paintability correction and 52 after the warm-recall bridge
regression. Final live GUI acceptance confirmed continuous playback, retreat /
minimize, recall, lookahead warming, and scrubbing without black flashes or
stale pre-hide frames. The milestone is closed.

This document records the path from R3nder Pro's first static MOSAIC two-window
STRUCT presentation to a reusable, frame-dependent MOSAIC layout program whose
authored meaning is shared by the MOSAIC editor viewer, TEXT/STRUCT Preview, and
final BAKE.

It is a development-history document. For the current ownership contract, read
`STRUCTURAL_COMPOSITION.md`. The exact LAYOUT spelling introduced by this
milestone is recorded here alongside the reasoning that produced it.

The short version is:

```text
static STRUCT:SPLIT
    ↓
pure two-window geometry
    ↓
persistent pane-window actors
    ↓
source-relative LAYOUT cues
    ↓
per-actor CONTINUE / REDIRECT / CREATE
    ↓
shared layout evaluation
    ↓
MOSAIC viewer + TEXT Preview
    ↓
resident-pixel hold under nonblocking decode
    ↓
exact BAKE actor rendering
    ↓
node-mode ownership cleanup
    ↓
dynamic window-slot naming
    ↓
FULL ↔ TWO UP front-layer correction
    ↓
one authored program, three consumers
```

The final result looks like a simple cue lane. The difficult part was deciding
what a cue means when windows already exist, decoders are still running, a cue
interrupts another transition, Preview is nonblocking, BAKE is exact, and the
same MOSAIC can be placed in more than one STRUCT context.

---

## 1. Where this started: static two-window STRUCT presentation

The predecessor was the MOSAIC two-window milestone documented in
`MOSAIC_TWO_WINDOW_COMPARISON.md`.

That work solved an important but narrower problem: an eligible two-pane MOSAIC
could be presented by one STRUCT placement as two desktop windows instead of one
Metro-style composite client.

The original ownership rule was intentionally placement-centric:

```text
MOSAIC
    owns reusable pane content

STRUCT
    owns whether that placement is ordinary windowed,
    FULL, SPLIT, SPLIT:MAX, and which split aspect is used
```

That model was correct for a static presentation. It gave R3nder:

- two real desktop windows;
- 16:9, 4:3, and 9:16 client geometry;
- SPLIT:MAX;
- Preview/BAKE parity for the static split;
- optional placement-owned pane-window names;
- persistent live pane decoding;
- deterministic entry/exit choreography.

It also exposed several rendering lessons that became prerequisites for the
layout-program work: pane rendering had to reuse the structural compositor;
readiness could not own authored time; persistent decoders needed raster-aware
identity; and live presentation required a residency model different from exact
BAKE.

The limitation became obvious once the two-window presentation worked well:
**the number and arrangement of MOSAIC windows was frozen for the whole STRUCT
placement.**

A real editorial desktop may need to do this instead:

```text
COMPOSITE
→ TWO UP A/B
→ ONE A
→ FULL A
→ TWO UP A/C, MAX, 4:3
→ COMPOSITE
```

That is not a property of one static STRUCT checkbox.

---

## 2. The ownership question changed

The first architectural decision was more important than the grammar.

A dynamic layout cue could have been stored on STRUCT. That would have made each
program placement own its own window choreography. It would also have meant the
same reusable MOSAIC could not carry a reusable editorial layout program.

The chosen model was:

> A MOSAIC layout cue changes the desired desktop arrangement of persistent pane
> windows at a MOSAIC project frame. It does not create content, change project
> duration, pause hidden panes, or restart a surviving pane. It does gate which
> pane audio contributes to the mix from that source frame forward.

That moved dynamic arrangement into the MOSAIC source while leaving placement
context on STRUCT.

The resulting split is:

```text
MOSAIC LAYOUT program
    owns source-relative desired arrangement
    COMPOSITE / TWO UP / ONE / FULL
    pane selection
    split aspect
    MAX
    transition duration
    pane-audio audibility at layout boundaries

STRUCT placement
    owns placement context
    base window title / overlays
    clip-audio intent
    placement-level COMPOSITE FULL/windowed choice
    optional two-window slot names
    legacy SPLIT seed for old projects
```

This is deliberately not the same as saying "all presentation belongs to
MOSAIC." The reusable source owns the **changing arrangement program**. STRUCT
still supplies the context in which that program is evaluated.

That distinction is why the same MOSAIC layout program can be placed more than
once without storing output-size geometry or placement-specific chrome inside
the reusable source.

---

## 3. The frozen semantic rule: source frame determines arrangement

The north-star invariant became:

> At source frame F, authored cues plus placement context fully determine visual
> actor arrangement.

Not:

- playback history;
- decoder readiness;
- widget lifetime;
- scrub direction;
- which frame happened to be resident first;
- whether the frame was reached by realtime playback or exact BAKE.

The pure shape is:

```text
MosaicLayoutProgram
    authored reusable cues
        +
MosaicLayoutEvaluationContext
    placement/output geometry
    COMPOSITE placement mode
    legacy seed
        ↓
MosaicResolvedLayoutProgram
        ↓
MosaicLayoutFrame(F)
```

That frame is the semantic authority consumed by live Preview and exact BAKE.

The parsed authored program may be cached by source revision. The resolved
program is placement-context-specific: output geometry and placement mode are
part of the meaning, so the evaluated result cannot be cached globally by only
"MOSAIC + source frame."

---

## 4. Grammar came after semantics

The direct MOSAIC syntax was then locked to source-relative cues:

```text
[LAYOUT:300:TWOUP:A=pane1:B=pane3:ASPECT=4X3:DUR=12]
[LAYOUT:600:TWOUP:A=pane1:B=pane3:MAX:DUR=12]
[LAYOUT:900:ONE:PANE=pane1:DUR=12]
[LAYOUT:1200:FULL:PANE=pane1:DUR=12]
[LAYOUT:1400:COMPOSITE:DUR=12]
```

Bare TWOUP remains hand-authoring shorthand for the first two authored panes.
Programmatic authoring expands explicit pane ids so later pane reordering does
not silently retarget an already-authored cue.

The cue is direct MOSAIC metadata, not a child-owned content block. It changes
presentation of persistent pane actors; it does not add media or occupy a second
timeline.

Validation was made repair-friendly but strict about semantic ambiguity:

- unknown pane references are errors;
- TWO UP may not reference the same pane twice;
- bare TWO UP requires at least two panes;
- duplicate cue frames are errors;
- negative frames/durations are syntax errors;
- cues at or beyond MOSAIC duration are retained and warned as dead;
- legacy SPLIT plus LAYOUT is retained and warned;
- redundant/no-effect cues are informational.

Pane rename rewrites explicit LAYOUT references atomically. Pane deletion is
blocked while referenced. Explicit references survive pane reordering; bare
TWOUP intentionally follows authored pane order.

---

## 5. The real model was not "states"; it was persistent actors

A state-only implementation would have been easy:

```text
frame 100 = TWO UP
frame 200 = FULL
```

It would also have been wrong.

The difficult question is what happens **between** those states, especially when
a second cue arrives before the first transition has finished.

R3nder therefore models persistent visual actors:

```text
COMPOSITE
PANE:pane1
PANE:pane2
PANE:pane3
...
```

COMPOSITE is a synthetic actor. It is not pane 1.

Pane identity remains stable across layout changes and across cuts inside a
pane. A cut changes the content delivered by the pane timeline; it does not
manufacture a new desktop actor.

Each cue reconciles every actor independently as one of three operations.

### CONTINUE

The actor's canonical terminal condition did not change.

Its current transition survives **exactly**:

- original start frame;
- original duration;
- easing;
- z-switch metadata;
- target;
- anchor.

A new cue is not allowed to retime an actor merely because some other actor
changed.

### REDIRECT

The actor exists, but its terminal condition changes.

The evaluator snapshots the exact current state at the cue frame and starts a
new transition from that snapshot.

This is the key to deterministic interruption. Redirecting an actor does not
pretend it had already reached the old target.

### CREATE

The actor was absent and becomes included.

Its entry is created from the shared structural-shell emergence geometry and the
new cue's duration.

The inverse transition to absence is an exit using the actor's canonical
resting anchor, not a recursively transformed current endpoint.

That last rule prevents pathological chains such as:

```text
E(anchor)
→ interrupted
→ E(E(anchor))
→ interrupted
→ E(E(E(anchor)))
```

The emergence function is always applied to the canonical anchor.

---

## 6. Terminal condition had to exclude transient state

A major design simplification came from defining what counts as the actor's
canonical destination.

A terminal condition contains only:

- included versus absent;
- canonical anchor rectangle;
- resting chrome;
- resting z.

It does **not** contain:

- current interpolated rectangle;
- current opacity;
- transient presence;
- transient z;
- entrant/exiting role;
- decoder readiness.

This gives reconciliation a stable question:

> Has the actor's destination actually changed?

If not, CONTINUE.

If yes, REDIRECT or CREATE.

That separation is what makes cue interruption, scrubbing, binary lookup, and
Preview/BAKE parity tractable.

---

## 7. Transition timing remained source-relative and finite

Default cue duration is 12 frames.

For duration `D >= 2`:

```text
end = S + D - 1
u   = clamp((F - S) / (D - 1))
```

Durations 0 and 1 canonicalize immediately.

A cue's DUR applies only to segments the cue creates or redirects. It does not
restart a CONTINUE actor.

Segments settle before reconciliation when their end frame is at or before the
next cue frame. Evaluation follows the same rule. This matters when cues are far
apart or land exactly on a prior segment's terminal frame.

A frame-zero cue establishes the canonical initial layout immediately. It does
not animate from an implicit COMPOSITE. Outer STRUCT entry owns the presentation
opening in that case.

---

## 8. One-deep history was enough

The evaluator does not retain an unbounded animation history.

Each actor state needs only:

- its canonical terminal condition;
- its exact current snapshot;
- at most one active segment.

At a cue boundary, the previous segment is either:

- preserved verbatim by CONTINUE;
- evaluated at that boundary and replaced by REDIRECT;
- already settled.

The resolved program stores cue boundaries containing full actor evaluator
state after reconciliation. Evaluation binary-searches the last boundary at or
before F and advances those actor states to F.

That gives:

```text
build: O(cues × actors)
evaluate: O(log cues + actors)
```

More importantly, independently built programs with the same source revision
and evaluation context canonically serialize identically. There is no hidden
playback-history dependency.

---

## 9. Z order needed to be data, not painter folklore

Actors carry a lexicographic z tuple:

```text
(band, roleRank, actorOrdinal)
```

The bands are:

```text
exiting
stable
entering
fullTarget
```

Actor ordinals are stable: COMPOSITE is 0 and authored panes follow in stable
order.

The first implementation used the general segment midpoint to switch from
start-z to target-z. This worked for many transitions and preserved deterministic
interruption state.

A later real GUI test exposed a visual exception.

The sequence was:

```text
FULL A
→ TWO UP A/B
→ FULL A
```

Geometry was correct, but during the morph the window visibly moving toward or
away from FULL could briefly fall behind the smaller peer. The model was
deterministic and still visually wrong.

The final rule is narrow:

> A surviving pane morphing between FULL and an ordinary window owns the front
> layer for the entire active morph.

The segment still records its ordinary start-z, target-z, and midpoint metadata
for deterministic history/interruption. Only effective paint depth receives the
FULL-morph exception. Once FULL → TWO UP settles, ordinary TWO UP ordering
resumes.

This was a useful reminder that a deterministic z rule is not automatically the
correct presentation rule.

---

## 10. The authoring lane made the source-relative model visible

The MOSAIC editor gained a dedicated LAYOUT CUES lane.

It is source-frame based, uses the same pixels-per-frame scale as the MOSAIC
timeline, and authors:

- COMPOSITE;
- TWO UP with explicit A/B panes;
- 16:9, 4:3, or 9:16;
- MAX;
- ONE;
- FULL;
- transition duration.

Same-frame authoring updates the existing cue rather than manufacturing an
illegal duplicate. Markers are seekable/editable and dead cues remain visible
for repair instead of disappearing.

When no cues exist, the source still has an implicit COMPOSITE initial state
rather than a hidden frame-zero cue.

A later Rocky workflow pass exposed one remaining authoring mismatch: the
runtime supported frame-zero TWO UP / ONE / FULL correctly, but the editor made
the starting state look like just another playhead cue. In practice that made a
fresh MOSAIC feel forced to enter as COMPOSITE unless the user deliberately
returned to F0.

The editor now presents two separate concepts:

```text
COME IN ON
    writes LAYOUT_START MOSAIC metadata
    defines the canonical opening arrangement
    is independent of playhead time

LAYOUT CUES
    writes LAYOUT at the current playhead
    every authored cue remains visible
```

The first UI-only correction still encoded the start as a hidden frame-zero
cue. Rocky testing showed that this was the wrong abstraction. LAYOUT_START is
now a separate grammar element consumed by the same evaluator as the initial
seed. Existing frame-zero LAYOUT cues remain a backward-compatible fallback.

A later Rocky acceptance pass exposed a second source-level ownership gap:
ONE visually dismissed a pane but structural audio still mixed every MOSAIC
pane. The first audio correction derived pane-audibility spans from LAYOUT_START and
LAYOUT cue boundaries. COMPOSITE admitted all panes, TWOUP admitted A/B, and
ONE/FULL admitted only the selected pane. Hidden panes remained on the shared
source clock.

This was the point where the data model became understandable as an editing
feature rather than only an evaluator.

---

## 11. One shared actor painter prevented another Preview/BAKE fork

Before connecting runtime consumers, window painting was extracted into a
persistent actor painter.

`MosaicLayoutWindowPainter` consumes:

- one `MosaicLayoutFrame`;
- actor visuals keyed by actor id;
- shared structural-window chrome;
- z-sorted `paintActors`.

Legacy static SPLIT delegates compatible window painting through the same
actor-level primitive where possible, while preserving its established
compatibility behavior.

The goal was not code deduplication for its own sake.

The goal was:

> Layout semantics choose actors and geometry. Raster consumers provide pixels.
> The painter must not independently reinterpret layout state.

---

## 12. Live Preview exposed the difference between authored time and resident pixels

The first layout-aware Preview path used the correct source frame for layout
evaluation but initially made a subtle pixel-availability mistake.

The visual map effectively required:

```text
residentFrame == requestedSourceFrame
```

before supplying an image to the actor painter.

Under nonblocking playback, that produced black/flicker:

```text
layout already at F+1
decoder still finishing F+1
resident image from F exists
exact-frame gate returns null
→ black client
```

This violated a lesson already learned during earlier split-window debugging.

The correct live rule is:

```text
authored geometry/time
    follows the exact current source frame

pixels
    hold the last good image while that actor remains continuously paintable
    but a recalled pane is blank until current pixels arrive
```

Readiness and pending decode may affect which pixels are resident. They may not
change the semantic layout frame. Preview holds the last good actor image for
as long as that actor remains continuously paintable, because a decoder may
legitimately lag several frames under load and black is not an acceptable
fallback. Hidden actors that are neither visible nor being warmed are evicted.
The resolved program also records paintability changes, including real
settlement into absence. A direct scrub or playback jump that skips over a
hidden interval therefore cannot resurrect a pre-exit image even if no
intermediate hidden widget frame was built. Conversely, an actor that is still
visually exiting remains paintable and keeps its last good image until that exit
actually settles.

BAKE is different: it is exact and blocking, so it renders the requested frame's
pixels rather than using resident hold.

That is not Preview/BAKE semantic divergence. It is two delivery policies
feeding the same authored actor arrangement.

---

## 13. The regression test itself briefly lied about the product

The first regression for resident-frame hold used a fake decoder that returned
frame zero and then left frame one pending forever.

That fixture caused the Preview's intentional retry loop to remain active
forever and complicated teardown.

The fixture was corrected to make frame one **temporarily** pending:

1. frame zero becomes resident;
2. layout advances to frame one;
3. frame-one decode remains pending;
4. the test proves layout is at F1 while resident pixels remain non-null;
5. frame one is released;
6. retry converges and the widget tears down cleanly.

A second test-harness issue was more instructive.

The helper rebuilt Preview with a fresh inline resolver closure each pump:

```dart
resolveSource: (String value) => value
```

Preview correctly treats resolver identity as runtime infrastructure. The new
closure therefore caused a runtime reset and cleared resident images between F0
and F1.

The production behavior was correct; the test had accidentally asked for a new
runtime.

The test now uses a stable resolver identity.

The lesson generalizes:

> Persistence tests must keep infrastructure identity stable unless reset
> behavior is the thing being tested.

---

## 14. The first real GUI run found a missing consumer

After the live structural Preview path worked, the user tested the feature in
the actual MOSAIC editor and found an asymmetry:

```text
TEXT / STRUCT Preview
    responds to LAYOUT cues

MOSAIC editor viewer
    still shows old composite behavior
```

The problem was not evaluator semantics. The editor's main MOSAIC viewer was
still constructed as the old `EditVideoPreview` and never consumed the layout
program.

The fix was to make the editor viewer detect a valid cue-bearing MOSAIC and use
the same layout-aware Preview path. Invalid source remains repairable by falling
back to the ordinary source viewer instead of making the editor unusable.

This was an important product-level boundary regression:

> A feature is not integrated merely because one runtime surface can render it.

R3nder has multiple honest views of the same authored source. Every view that
claims to show current MOSAIC presentation must consume the same program.

---

## 15. BAKE was a second missing consumer, not a small Preview fix

Once both live surfaces behaved correctly, final render still ignored LAYOUT
cues.

That exposed a clean architecture boundary.

The existing whole-program renderer still chose between:

```text
legacy static SPLIT
or
one composite structural source image
```

It never asked the new `MosaicLayoutProgram` which actors existed at the
current source frame.

The BAKE integration therefore did not copy live Preview machinery.

Instead it:

1. detects a cue-bearing MOSAIC;
2. builds the same placement-dependent layout evaluation context;
3. resolves/evaluates the same `MosaicLayoutFrame`;
4. renders each required actor synchronously at the exact source frame;
5. supplies those exact images to the shared actor painter;
6. preserves the old path for cue-less MOSAIC and legacy SPLIT.

A shared adapter now owns the placement-to-layout context and outer STRUCT
entry/exit composition used by both Preview and BAKE.

This gives the stronger guarantee:

```text
same authored source frame
+ same placement
+ same output geometry
        ↓
same MosaicLayoutFrame
```

Preview may hold resident pixels while decode catches up. BAKE blocks for exact
pixels. Neither is allowed to invent different actor geometry.

A render-level regression proves actual raster changes across authored states
rather than testing only the evaluator.

---

## 16. Node mode revealed an ownership lie left over from the old feature

The next real-use issue was not rendering at all.

The STRUCT node still exposed:

```text
TWO WINDOWS
MAXIMIZE SPLIT
CLIENT ASPECT
```

as if those controls described the whole placement.

That was accurate before LAYOUT cues. It became misleading once one MOSAIC could
be FULL, TWO UP, ONE, and FULL again inside the same placement.

The node-mode ownership was changed to match the architecture.

For a cue-bearing MOSAIC, STRUCT now shows a **LAYOUT PROGRAM** status and no
longer presents static TWO WINDOWS / MAX / CLIENT ASPECT as current
placement-wide controls.

For cue-less old MOSAIC sources, the old controls remain.

If an old SPLIT token coexists with LAYOUT cues, it is exposed specifically as a
**LEGACY TWO-WINDOW SEED**. That state is not hidden, but it is also not
misrepresented as the dynamic layout authority.

This preserved backward compatibility while making the UI tell the truth.

---

## 17. Window naming survived, but its meaning had to be clarified

The old static split feature already supported:

```text
PANENAMES
NAME1
NAME2
```

Those values remained useful, but "pane names" was no longer quite right.

A LAYOUT cue may put different pane ids into the two visible desktop slots over
time.

The final semantic is therefore placement-owned **window-slot naming**:

```text
NAME1 = left / A window slot
NAME2 = right / B window slot
```

When a dynamic TWO UP state is visible, the two active pane actors receive those
slot suffixes.

A ONE or FULL state uses the base STRUCT title without a slot suffix.

This avoids binding a chrome label permanently to a pane id while preserving
the placement-level naming feature users already had.

Preview and BAKE share the same title mapping helper so naming cannot drift
between live and final output.

---

## 18. Hidden panes never stop owning source time

LAYOUT changes presentation, not source playback.

A pane hidden by ONE, FULL, or COMPOSITE is still on the shared MOSAIC source
clock.

The layout evaluator contains no decoder or readiness state.

It exposes pure lookahead information such as:

- visible pane ids at a frame;
- panes entering within a future range;
- next appearance frame.

Live Preview may use this information for prefetch/residency decisions, but the
semantic rule remains:

> Hiding a pane is not pausing it.

When the pane returns, its content is whatever that pane timeline owns at the
current MOSAIC source frame.

This is the same reason a surviving pane actor is never recreated merely because
its window geometry changed.

---

## 19. Legacy compatibility was deliberately retained

The new program did not delete static SPLIT.

Cue-less projects keep their old behavior.

A legacy STRUCT SPLIT may seed initial layout until the first LAYOUT cue.
A LAYOUT_START state wins immediately. When no LAYOUT_START exists, a legacy
frame-zero LAYOUT cue still wins over the placement seed.

The old static path also retains its established compatibility behavior,
including its separately accepted close presentation where applicable. The new
layout actor path does not inherit that behavior accidentally.

This distinction mattered during debugging because an old intentional black
close could easily be mistaken for the new live black/flicker residency bug.
They were different mechanisms and needed to stay different.

---

## 20. What the final architecture looks like

The source side:

```text
MOSAIC raw source
    ↓
MosaicLayoutCue parser / validation
    ↓
MosaicLayoutProgram
    ↓
resolve(MosaicLayoutEvaluationContext)
    ↓
MosaicResolvedLayoutProgram
    ↓
evaluate(sourceFrame)
    ↓
MosaicLayoutFrame
```

The live side:

```text
MosaicLayoutFrame
    + persistent MediaLayer / EditVideoCompositor
    + resident actor images
    ↓
MosaicLayoutWindowPainter
    ↓
MOSAIC editor viewer or TEXT/STRUCT Preview
```

The BAKE side:

```text
MosaicLayoutFrame
    + exact synchronous actor renders
    ↓
MosaicLayoutWindowPainter
    ↓
ProgramStructuralFrameRenderer
    ↓
SceneExporter / final encoded program
```

The GUI authoring side:

```text
MOSAIC LAYOUT CUES lane
    owns changing arrangement

STRUCT node
    owns placement chrome/audio/context
    + optional two-window slot names
    + legacy seed compatibility
```

There is no second layout database in the widgets.

---

## 21. The bugs that mattered most

The feature's useful debugging history can be summarized as eleven failures.

### Failure 1: black/flickering windows during live playback

Cause: actor images were gated on resident frame equaling requested frame.

Fix: layout follows authored source time; pixels may briefly hold a recent
resident image while the next frame is pending.

### Failure 2: the residency regression would not terminate cleanly

Cause: the fake decoder left the next frame pending forever.

Fix: use controlled finite pending and release after proving resident hold.

### Failure 3: the residency assertion still failed after the product fix

Cause: the test rebuilt with a new resolver closure, which correctly reset the
runtime and cleared residency.

Fix: stable infrastructure identity in persistence tests.

### Failure 4: TEXT Preview worked but the MOSAIC editor viewer ignored cues

Cause: that viewer still used the old composite-only `EditVideoPreview`.

Fix: make the editor viewer consume the same authored layout program.

### Failure 5: live Preview worked but final render ignored cues

Cause: `ProgramStructuralFrameRenderer` still chose only old static SPLIT
versus one composite image.

Fix: BAKE evaluates the same layout frame and renders its actors exactly.

### Failure 6: FULL ↔ TWO UP geometry was right but depth looked wrong

Cause: generic midpoint z switching let the smaller peer paint over the
FULL-morphing pane.

Fix: a pane participating in a FULL morph remains on the front layer for the
whole morph, then ordinary z ordering resumes after settlement.

### Failure 7: a long-hidden pane could recall an ancient but plausible image

Cause: resident images were retained by actor id indefinitely. The 24-frame
lookahead normally refreshed a returning pane, but if playback jumped into the
warm window or decode stayed pending under load, a pane hidden hundreds of
frames earlier could return showing its pre-exit image.

Fix: resident hold is bounded by authored paintability continuity rather than
frame age. A hidden actor that is neither visible nor requested is evicted, and
any cached image is paintable only while its actor has remained paintable from
the resident frame through the current source frame. This lets playback survive
multi-frame decoder lag without black frames while still rejecting a pre-exit
image after any authored hidden interval, including intervals skipped by a
direct scrub or playback jump.

The regressions cover both paths: one hides a pane, jumps into its lookahead
window with recall decode held pending, then proves the old pre-exit image is
not supplied; another scrubs directly from a visible frame to a later visible
frame across the hidden interval and requires the cached pre-hide image to be
rejected at rebuild time.

### Failure 8: terminal absence was confused with visual exit

Cause: the first visibility-continuity table tracked each actor's terminal
`included` flag at cue boundaries. On TWO UP → ONE, the retiring pane's new
terminal condition is absent at the cue frame, but the actor remains in
`paintActors` as `exiting` until its transition settles. Residency therefore
became ineligible at the beginning of the minimizing animation and the retiring
window flashed black while shrinking away.

Fix: residency continuity is now based on **paintability**, not terminal
inclusion. An exiting actor remains in the same paintability run through the
last transitional frame. The run changes to absent only when the exit segment
actually settles. If a later cue interrupts that exit before settlement, no
absent frame is invented.

The regression drives TWO UP → ONE with decode deliberately pending at the
middle of the exit and requires the retiring pane to retain its last good image
until the exact settlement frame removes it from paint.

### Failure 9: lookahead warmed the decoder but could not bridge recall

Cause: hidden-pane lookahead rendered on the current shared source frame, but
the warmed image had no provenance saying which future appearance it was
preparing for. At the appearance boundary itself, paintability correctly
changes from absent to present, so ordinary paintability continuity rejected
the warm image. If the exact recall-frame decode was still pending, the new
window could therefore open on an empty client even though a one-frame-old warm
image was already resident.

A second implementation detail made lookahead weaker than intended:
`layoutFrame.actors` includes absent actors, so the hidden actor was found as a
"current actor" and its absent geometry could win over the upcoming appearance
geometry used for decode sizing.

Fix: Preview now stores explicit warm provenance
`actor -> appearanceFrame` alongside the resident image. A warm image may cross
that one intentional appearance boundary, after which ordinary paintability
continuity applies from the appearance frame forward. Normal pre-hide resident
images have no warm provenance and remain rejected. Hidden warm renders also use
the actor evaluated at the upcoming appearance frame for decode sizing.

The regression warms a hidden pane at F399 for an F400 appearance, holds the
F400 exact decode pending, proves the warm request used nontrivial appearance
geometry, and requires the recalled pane to paint a different non-null image
than its old pre-hide F0 resident image.

None of these failures required changing authored project time.

### Failure 10: the opening state was masquerading as a timeline cue

A Rocky workflow pass exposed that the runtime semantics were better than the
authoring model. A frame-zero LAYOUT cue could already make the MOSAIC enter as
TWO UP / ONE / FULL, but the editor treated that opening condition like an
ordinary playhead cue. Hiding the F0 marker made the source look cue-less while
still carrying authored F0 state; showing it made the user author a transition
just to choose how the application should first appear.

Fix: opening arrangement is now first-class MOSAIC metadata:

```text
[LAYOUT_START:TWOUP:A=pane1:B=pane2]
```

The editor exposes this as a single **COME IN ON** dropdown. It is not tied to
the playhead and does not appear in the cue lane. Later `[LAYOUT:F:...]`
directives remain timeline transitions and every one of them stays visible.
Legacy F0 cues remain readable and visible until COME IN ON migrates them to
LAYOUT_START.

That is the architectural success worth preserving.

### Failure 11: audio became a second layout interpreter

Review of the accepted hard-gate implementation found two coupled defects.

First, the structural-audio mixer dropped a dismissed pane at the exact sample
of the LAYOUT cue. That could create a waveform discontinuity and made sound
finish before a DUR=12 window had visibly completed its exit.

Second, the audio planner independently walked LAYOUT_START / LAYOUT cues
instead of asking the MOSAIC resolver. That duplicated the semantics Preview
and BAKE had deliberately centralized, and a source-only audio plan had no way
to receive placement-owned legacy SPLIT seed context.

The correction is architectural:

```text
STRUCT placement
    → StructuralAudioSourceContext
    → MosaicLayoutProgram.resolveForStructuralAudio(...)
    → same CREATE / CONTINUE / REDIRECT / interruption semantics
    → resolver-derived per-pane gain envelope
    → source audio renderer / cache
```

The resolver exposes each pane's audio frame from the same actor opacity state
used by picture. COMPOSITE contribution plus direct pane contribution is
clamped to unity, which keeps a represented pane stable through
COMPOSITE↔pane transitions while allowing entering/exiting panes to follow the
visual segment. The audio renderer interpolates between resolver frame gains
during active segments. True immediate DUR=0/1 changes receive only a 5 ms
declick ramp after the boundary.

Program audio memoization now keys source plus placement layout context, and
runtime tracing carries legacy SPLIT / aspect / MAX into that context. The
persistent source-audio cache hashes the resolver-derived gain envelope and its
schemas were bumped again, so a semantically different layout mix cannot reuse
a stale WAV.

This review follow-up is newer than the recorded 74-test / Rocky acceptance.
Its fresh focused gate passed **110 tests** on Rocky. Live Rocky listening then
confirmed the resolver-driven transition audio behaves correctly in practice,
including nested EDIT gain carrying through MOSAIC. A final reviewer hardening
guard now resolves the same layout program under deliberately different output
geometries and asserts identical pane-audio gain/interpolation for every pane
and frame, pinning the assumption behind the synthetic geometry used by
`resolveForStructuralAudio()`. That focused resolver guard passed **14 tests**
on Rocky. This follow-up is fully accepted.

---

## 22. Proof spine

The layout-program contract is primarily exercised by:

- `test/mosaic_layout_program_test.dart`
- `test/mosaic_layout_program_matrix_test.dart`
- `test/mosaic_layout_lane_ui_test.dart`
- `test/structural_mosaic_layout_preview_test.dart`
- `test/program_structural_split_bake_test.dart`
- `test/editor_structural_split_node_test.dart`
- `test/structural_window_actor_painter_test.dart`

The focused regression gate after the FULL/TWO UP z correction passed 50 tests
before PR #30 merged. Post-merge residency stabilization added stale-recall,
parked-scrub, multi-frame playback-lag, and TWO UP → ONE exit-motion coverage.
After the final paintability correction, the focused gate passed 51 tests. After
adding the warm-recall bridge regression, the focused gate passed 52 tests.
The later COME IN ON / LAYOUT_START and layout-driven pane-audio follow-up
expanded the focused gate to **74 passing tests**. Rocky live acceptance then
confirmed that TWO UP → ONE mutes the dismissed pane at the intended cue
boundary while the surviving pane continues cleanly.

The important proof shape is wider than one evaluator test:

```text
parser/model
→ evaluator matrix
→ authoring lane
→ actor painter
→ live structural Preview
→ MOSAIC editor viewer
→ exact program BAKE
→ node-mode ownership
→ real GUI acceptance
```

This feature repeatedly demonstrated the repository's testing rule:

> When a product bug survives green lower-level tests, add the missing ownership
> boundary to the regression instead of only adding more assertions inside the
> already-green unit.

---

## 23. What this journey changed in the larger R3nder model

The static two-window milestone established that a MOSAIC could be presented as
multiple desktop windows.

The layout-program milestone changed something deeper:

**a reusable structural source can now carry deterministic presentation
choreography across its own source time without becoming a second top-level
timeline.**

That opens a useful middle layer between content and program placement:

```text
content timeline
    pane-local clips

source-relative presentation program
    LAYOUT cues

program placement
    STRUCT context/chrome/audio
```

Those layers remain independently owned.

The architecture scales because the cue does not tell the decoder what to do,
does not add project duration, and does not store current animation state. It
only changes the desired canonical arrangement at a source frame.

---

## 24. Lessons to keep

### Store authored intent, derive transient motion

The project stores cues and duration, not current rectangles, opacity, z, or
decoder readiness.

### Persistent identity beats rebuilding widgets

A pane is an actor with continuity. Window geometry can change without
restarting its source.

### Readiness is not time

Live pixels may lag authored time. The timeline and layout evaluator do not.

### Preview and BAKE should share meaning, not necessarily delivery policy

Preview may hold the last good resident pixels through decoder lag while the
actor remains in one continuous paintability run. A hidden pane intentionally
warmed for its next appearance may also bridge that one appearance boundary,
then continues under the same paintability rule. An unwarmed recalled pane
waits for current pixels rather than reusing pre-hide content. BAKE renders
exact pixels. Both consume the same `MosaicLayoutFrame`.

### A UI control is part of the architecture

The old TWO WINDOWS checkbox became wrong even though it still serialized valid
legacy syntax. UI labels must reflect ownership, not only parser capability.

### Deterministic can still be visually wrong

The first z rule was deterministic. The FULL/TWO UP GUI test proved that
presentation depth needed one additional semantic rule.

### Real GUI abuse remains valuable after green tests

The MOSAIC-viewer gap, BAKE gap, stale node model, z-order issue, stale recalled
pane, playback black-frame regression, and TWO UP → ONE retreat flash were all
found by exercising the feature as an editor rather than only as a library.
Several of those failures appeared while focused tests were green; each one
therefore became a new ownership-boundary regression rather than only another
assertion inside an already-green lower-level test.

---

## 25. Post-merge focal dominance, audio intent, and OVERVIEW

The next MOSAIC layout work generalized two assumptions that had become too
narrow.

### Focal ownership became an explicit semantic fact

The old FULL-specific front-layer helper was removed rather than preserved
under a new name. Terminal states now declare whether a pane is focal:

```text
COMPOSITE       no dominant pane
TWOUP           no dominant pane
ONE             selected pane dominant
FULL            selected pane dominant
OVERVIEW        MAIN dominant
```

An active segment resolves focal paint ownership with this precedence:

```text
target dominance
    >
start dominance
    >
ordinary z
```

Target dominance is eligible only while the actor remains target-present. A
former focal pane exiting toward absence therefore loses focal priority
immediately, while a pane becoming MAIN owns the front from the first frame of
the morph.

This replaced the earlier FULL-morph exception without changing its visible
contract. The pre-existing FULL transition tests kept their behavioral
assertions that the focal pane remained the last painted actor; only assertions
about the old implementation mechanism changed.

Same-band `roleRank` has a separate job. It describes paint order inside a
settled peer arrangement, so a surviving actor keeps its source role rank for
the active morph and adopts the target role at settlement. It is not used as a
proxy for focal ownership.

Interruption snapshots one globally resolved current owner. Raw
`startDominant` endpoint facts may still exist on an old target-absent CONTINUE
segment, but target-presence gating makes those facts inert. The executable
invariant is therefore about the resolved active owner, not the raw count of
all stored start endpoints.

The equality definition of the terminal condition is load-bearing. In
particular, `dominant` must remain part of terminal equality. If a future
refactor removes it, the resolver must explicitly re-establish global focal
ownership uniqueness or a focal change could incorrectly CONTINUE instead of
REDIRECT.

### Resting audio intent became independent from visual opacity

The resolver now carries resting pane-audio gain as a terminal fact and
start/target audio gain on active segments. Existing layouts were initialized
to reproduce the old opacity-derived envelopes exactly.

CREATE uses the structural shell's opacity progress authority. Redirect and
exit segments use the existing eased opacity progress. Audio therefore follows
the same segment timing without deriving semantic audibility from final paint
opacity. This separation is what lets OVERVIEW keep thumbnails visually
present and continuously clocked while their resting gain is zero.

### OVERVIEW added focal plus shelf presentation

OVERVIEW is first-class MOSAIC state syntax:

```text
[LAYOUT_START:OVERVIEW:MAIN=pane1:OTHERS=pane2]
[LAYOUT:300:OVERVIEW:MAIN=pane1:OTHERS=pane2,pane3:ASPECT=4X3:DUR=12]
```

`MAIN=` is the focal pane. `OTHERS=` is an ordered, explicit left-to-right
thumbnail list. The shipped range is one to three thumbnails, so a two-pane
MOSAIC can present one large MAIN with one small live pane underneath, while a
four-pane MOSAIC can present MAIN plus three thumbnails. MAIN may not be
repeated in OTHERS and OTHERS may not contain duplicates.

OVERVIEW uses the existing authored client-aspect enum for MAIN and thumbnails.
It does not inspect media aspect. MAIN has normal window chrome, focal
dominance, and resting gain 1. Thumbnails are chrome-free, non-dominant, and
rest at gain 0 while continuing on the shared source clock.

Supporting MAIN plus three thumbnails required the MOSAIC source model itself
to accept four panes. Legacy COMPOSITE geometry therefore extends its existing
hero-plus-stack pattern to hero plus a three-item vertical stack rather than
making a four-pane source valid only inside OVERVIEW.

### Thumbnail labels are geometry, not a second actor

Each OVERVIEW thumbnail owns a reserved label rectangle carried on the same
actor frame. Preview and BAKE paint labels through the shared actor painter.
The label rectangle exists even when names are disabled, so naming cannot move
video geometry.

Labels are anchored directly below each thumbnail with the authored label gap.
This matters on portrait output: a wide 16:9 thumbnail may be width-limited and
much shorter than the shelf's available image region, so pinning labels to the
bottom of the shelf would visually detach them from the image.

The resting-peer disjointness tests intentionally use a tiny floating-area
tolerance of `1e-6`. There is no canonical pixel-snapping authority in this
paint path; the shared painter consumes floating-point rects directly. The
tolerance exists only for floating arithmetic noise and must never be raised to
make a genuine overlap failure pass.

### Window-title roles are explicit too

TWOUP placement names are no longer inferred by sorting window geometry, and
OVERVIEW is no longer detected indirectly from label opacity. The resolver
carries an explicit nullable window-title slot endpoint:

```text
TWOUP A       slot 1
TWOUP B       slot 2
everything else
              no slot
```

A source title slot remains active through a transition until settlement; an
actor created directly into TWOUP can take its target slot immediately. This
keeps TWOUP-to-OVERVIEW from dropping both slot suffixes on the first morph
frame and prevents future states that happen to use labels from silently
changing title behavior.

This follows the same architectural rule as focal dominance and audio intent:
presentation meaning is represented directly rather than inferred from an
unrelated field.


---

## 26. Review closure and structural-audio diagnostics

After OVERVIEW and the two-pane follow-up were visually accepted, a separate
review pass audited the implementation for semantic shortcuts rather than new
pixels. That review confirmed that the cleanup had moved the important
presentation facts into the resolver itself:

- focal dominance is explicit and target-end dominance wins over start-end
  dominance;
- TWOUP window-title slots are semantic endpoint facts rather than geometry
  sorting or label-opacity inference;
- OVERVIEW labels remain part of their pane actor and are anchored directly to
  their thumbnail;
- terminal equality keeps both dominance and window-title role because changes
  to either fact require reconciliation rather than an accidental CONTINUE;
- Preview catches a resolver invariant failure and renders a visible
  `MOSAIC LAYOUT ERROR` panel instead of letting a build exception escape.

One open review question remained: the structural-audio planner also consumes
the MOSAIC resolver. A resolver invariant must not become missing clip audio
that looks like valid playback.

### The three audio consumers did not originally fail the same way

Tracing `resolveForStructuralAudio` outward showed three different consumer
boundaries.

Dashboard Preview was already safe. Artifact preparation let the planner error
propagate, Main stopped the session, restored the project clock, logged the
failure, and showed a red Preview-audio diagnostic.

BAKE was also safe. Structural-audio rendering lived inside the export error
boundary, so a planning failure produced an unsuccessful export with a
`Structural audio render failed` message rather than a partial successful
movie.

The source-audio cache and renderer also propagated the exception instead of
turning it into an empty artifact.

TEXT authoring was the weak path. Its broad catch treated every structural-audio
failure like a transport outage: it showed a short
`STRUCT audio unavailable` toast, left `structuralStarted` false, and then
continued picture playback on the legacy bed path. A semantic layout failure
could therefore make authored clip audio disappear while the picture still
looked valid.

### Planning failure is now distinct from transport failure

The planner now treats the whole layout-derived audio phase as one semantic
boundary rather than classifying failures by exception type. MOSAIC layout
validation, resolver/geometry evaluation, and per-pane `paneAudioFrame`
sampling all run inside that boundary. Any error raised there is converted into
a `StructuralAudioPlanException` that names the affected structural source.
That includes resolver `StateError` invariants, geometry `ArgumentError`
failures, and envelope-sampling errors. A typical diagnostic begins:

```text
Structural audio planning for "MOSAIC.wall" ...
```

TEXT catches that typed planning exception separately. It clears the pending
play state, shows an eight-second red `STRUCT AUDIO PLANNING ERROR`, and aborts
the play attempt. It does **not** fall through to picture playback without the
authored STRUCT clip audio.

Ordinary transport and backend failures retain the historical graceful
fallback. A sink or device problem therefore does not gain semantic authority
over the document, while any failure originating in layout-derived audio
planning cannot masquerade as a valid silent plan. Clip recursion, media
decode, cache I/O, and transport remain outside that semantic boundary and keep
their own failure contracts.

### The first regression failure was the test harness, not the product

The preview-artifact regression initially wrapped
`WidgetTester.runAsync()` in `expectLater(..., throwsA(...))`. Flutter's
widget-test binding reported the async exception separately, while the matcher
saw the `runAsync` future complete with null. That produced two apparent
failures at once.

The stack trace nevertheless proved the production path was already doing the
right thing: the named `StructuralAudioPlanException` had propagated out of
the planner.

The regression was corrected to catch the exception **inside**
`runAsync`, then assert on the captured object after the async boundary.
No production behavior changed for that correction.

### Final acceptance

The final structural-audio diagnostic gate passed **23/23 tests** on Rocky.
`flutter analyze` remained at the existing **80-issue baseline**, including
only the same two pre-existing
`StructuralAudioSourceRenderCallback` argument-type errors and no new issue
from this work.

The reviewed cleanup and diagnostic follow-up were then merged to `main`.
The final accepted main revision for this sequence is:

```text
335a27eb09aadeea5c0b3e9792eba9adb4f981fd
```

A final Rocky smoke test of the merged application succeeded. The already
accepted two-pane OVERVIEW visual remained unchanged in normal landscape
Preview and BAKE while the resolver, title-role, label, and audio failure
contracts underneath it became stricter.

---

## 27. Completion state

**Milestone reached and closed.** The accepted implementation is on `main`.
The residency-focused regression gate first closed at 52 tests with successful
live GUI verification of continuous playback, TWO UP → ONE retreat, pane recall,
lookahead warming, and scrub crossings. The later COME IN ON / LAYOUT_START and
first pane-audio follow-up then reached a 74-test focused gate and Rocky live
acceptance. Review subsequently exposed the hard cue-boundary audio cut and the
second-interpreter problem recorded in Failure 11. The resolver-driven audio
correction then passed a **110-test focused Rocky gate** and a successful live
Rocky listen, including nested EDIT gain carrying through MOSAIC. That closed
the resolver-driven pane-audio architecture before the later focal-dominance,
OVERVIEW, and review-cleanup sequence.

The later OVERVIEW rollout added its own acceptance chain: a **151-test** full
feature gate, a **99-test** two-pane OVERVIEW follow-up gate, a **102-test**
post-review cleanup gate, and finally the **23-test** structural-audio
diagnostic gate described above. The final merged application was then smoke
tested successfully on Rocky.

The completed milestone leaves R3nder with:

- reusable source-relative MOSAIC LAYOUT cues;
- first-class COME IN ON / LAYOUT_START opening state;
- COMPOSITE, TWO UP, OVERVIEW, ONE, and FULL states;
- explicit pane assignment;
- 16:9 / 4:3 / 9:16 split geometry;
- MAX;
- deterministic CREATE / CONTINUE / REDIRECT interruption semantics;
- persistent pane actor identity;
- hidden-pane source-clock continuity;
- shared Preview/BAKE layout evaluation;
- resident-pixel hold bounded by continuous actor paintability rather than frame age;
- stale hidden-pane recall rejection across real absent intervals;
- resident pixels preserved through visible exit/minimize segments until settlement;
- explicit lookahead warm provenance that can bridge its intended appearance boundary;
- appearance-frame geometry used for hidden-pane warm decode sizing;
- exact actor rendering for BAKE;
- layout-aware MOSAIC editor viewer;
- layout-aware TEXT/STRUCT Preview;
- node-mode ownership that distinguishes dynamic layout from legacy SPLIT;
- explicit placement-owned window-title slot semantics;
- generalized focal dominance with target-over-start precedence;
- OVERVIEW MAIN plus one to three live thumbnails;
- four-pane MOSAIC source support;
- layout-driven MOSAIC pane audio derived from the same resolved actor program as picture;
- pane-audio gain that follows visual transition segments instead of hard-switching at cue boundaries;
- a pinned 5 ms declick for true DUR=0/1 layout edges;
- placement-owned legacy SPLIT / aspect / MAX context propagated into structural audio;
- nested EDIT clip GAIN and MUTE preserved when the EDIT is used inside a MOSAIC pane;
- placement-aware program-audio memoization and source-audio cache identity;
- visible Preview diagnostics for MOSAIC resolver invariant failures;
- typed structural-audio planning diagnostics that prevent TEXT from
  continuing with missing authored clip audio;
- legacy cue-less SPLIT compatibility.

The initial feature merged after manual Preview and BAKE acceptance in addition
to the focused automated gates. Post-merge GUI testing then found the residency,
opening-state, and audio-ownership edge cases recorded above. Each correction
was accepted only after the relevant focused gate and another live Rocky pass.
The acceptance progression is therefore 52 tests for the closed residency
milestone, 74 tests for COME IN ON plus the first pane-audio behavior, and
**110 tests plus live listening** for the resolver-driven pane-audio
architecture. The later OVERVIEW sequence then closed through 151-, 99-, and
102-test gates, followed by the 23-test planning-diagnostic gate and a final
successful merged Rocky smoke test.

The most important final rule is now broader than picture alone:

> At source frame F, authored MOSAIC state plus placement context fully determine
> the visual actor arrangement, focal ownership, title role, label geometry,
> and pane-audio presentation state.

Decode readiness, UI lifecycle, playback direction, cache lifetime, and whether
the frame is live or being baked are downstream of that semantic authority.
