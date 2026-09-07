# M18–M19: The Structural Presentation Journey

M18 and M19 were two of the hardest milestones in R3nder Pro so far.

Not because the final behavior is complicated to describe. In the finished application it feels almost obvious:

```text
build EDIT
    ↓
build MOSAIC
    ↓
place it with STRUCT
    ↓
choose windowed or FULL SCREEN
    ↓
move cleanly into the next structural application
```

The difficulty was making that simple authoring model remain true all the way through planning, runtime timing, decoding, live preview, geometry, and bake.

This document records how those two milestones were actually won.

---

## Where we were before M18

By the time M18 started, R3nder already had a substantial structural media stack.

An `EDIT` could describe authored clips and tracks. A `MOSAIC` could compose structural sources into panes. A `STRUCT` placement could put an `EDIT` or `MOSAIC` into the main program sequence. Preview and bake already shared deterministic project time, and native media decoding had been pushed behind a media abstraction.

The missing piece was application-level continuity.

Two structural sources next to each other still behaved too much like two unrelated launches. The program knew how to show each one, but it did not yet have a rigorous concept of one structural application handing off to the next.

M18 was therefore not “add a transition.” It was:

> Make adjacent structural presentations behave like one deterministic application sequence without breaking frame ownership, source-local time, decoder lifetime, preview/bake parity, or fullscreen/windowed geometry.

That sentence turned out to contain several different problems.

---

# M18 — Structural application switching

## The contract

The authored forms were deliberately kept small:

```text
[STRUCT:MOSAIC.first]
[STRUCT:MOSAIC.second]
```

and:

```text
[STRUCT:MOSAIC.first:FULL]
[STRUCT:MOSAIC.second:FULL]
```

We decided early that M18 would **reuse the existing application-switch setting**:

```text
[CONFIG:APPSWITCH:SLIDE]
```

There would not be a second STRUCT-specific transition preference.

That gave us four presentation relationships to support under seamless switching:

- window -> window
- fullscreen -> fullscreen
- window -> fullscreen
- fullscreen -> window

The same-mode cases should hand off directly. The mixed-mode cases should use one deterministic 12-frame geometry morph.

The important part was what must *not* happen:

- no fullscreen terminal between structural applications;
- no desktop or wallpaper flash during a seamless handoff;
- no decoder reopen seam;
- no reset of incoming source time;
- no extra project frames inserted to wait for media;
- no preview-only behavior that bake could not reproduce.

The full visual contract is preserved separately in `M18_STRUCT_APP_SWITCH_VISUAL_GATE.md`.

---

## Battle 1: adjacency was not the same thing as textual adjacency

The first important failure came from a realistic script, not a tiny unit-test fixture.

The actual document looked like this in principle:

```text
[EDIT:main]
...
[/EDIT]

[MOSAIC:mosaic]
...
[/MOSAIC]

[STRUCT:MOSAIC.mosaic]

[EDIT:edit]
...
[/EDIT]

[MOSAIC:mosaic_2]
...
[/MOSAIC]

[STRUCT:MOSAIC.mosaic_2]
```

Visually, those two `STRUCT` placements are adjacent in the program sequence. The `EDIT` and `MOSAIC` definitions between them are reusable source definitions; they consume no terminal time.

But the original runtime-gap test treated those definitions as content between the two placements. That broke chaining and resurrected the fullscreen terminal between applications.

The fix was conceptual, not cosmetic:

> Structural source definitions are not program-time interruptions.

The runtime-gap classifier had to strip `EDIT` and `MOSAIC` definitions, just as it already ignored comments and configuration, before deciding whether two `STRUCT` placements were adjacent.

This produced the key commits:

- `7b470945` — Keep STRUCT chains across source definitions
- `6c80237a` — Correct STRUCT chain planner assignment
- `7bcdfed4` — Test STRUCT chains across source definitions

Once this landed, the fullscreen terminal interstitial disappeared in the real script.

That was the first major lesson of M18:

> **Program adjacency must be defined in program-time terms, not raw-text terms.**

---

## Battle 2: the one-frame wallpaper flash

After the terminal problem was fixed, one defect remained.

At the seamless A -> B boundary, the outgoing structural window would disappear for exactly one frame. The desktop wallpaper remained visible. Then the incoming structural window appeared.

The symptom was extremely specific:

```text
A structural window
→ one bare wallpaper frame
→ B structural window
```

That one frame became the hardest bug in M18.

### The first theory: top-level preview handoff

We initially attacked the problem in `ProgramPreviewSurface`.

That was a reasonable place to look. The top-level preview path owned structural handoff, readiness, and overlapping presentation. Several commits hardened that path:

- `079ad8b` — Report STRUCT preview first-frame readiness
- `5f8c146` — Hold seamless STRUCT shell until incoming picture is ready
- `ca5d501` — Test late seamless STRUCT handoff keeps outgoing shell
- `23e190b` — paint-atomic overlap attempt
- `4006cb2` — Pin STRUCT raster gate to program size
- `4b578f0` — Fix STRUCT raster gate byte capture typing

We also investigated a real Flutter rendering subtlety: an `Opacity(0)` subtree can remain mounted and keep doing work without actually painting. That gave us an important distinction between logical readiness and raster readiness.

The top-level path became better because of this work. We gained stronger overlap behavior and a raster gate.

But the GUI still flashed.

That meant the model we were testing was not the model the user was seeing.

---

## Battle 3: we were testing the wrong preview path

The decisive breakthrough came from tracing the exact editor route used by the real script.

The editor live preview did **not** go through `ProgramPreviewSurface`.

Its preview pane directly created a `StructuralSequencePreview` from the currently active structural placement.

That changed the investigation completely.

On a seamless A -> B update, the same `StructuralSequencePreview` State object received a new structural source. In `didUpdateWidget`, a source change reset:

```text
_firstFrameReady = false
```

The showing-stage logic then did exactly what the user saw:

- desktop opacity stayed at 1;
- terminal stayed hidden because this was a chained handoff;
- structural window remained logically present;
- structural opacity became 0 while the incoming first frame was unresolved.

The result was not a mysterious compositor glitch at all.

It was deterministic:

> The editor intentionally hid the structural shell for one frame while waiting for B.

Because the terminal was correctly suppressed, the only thing left to see was the wallpaper.

That was the actual root cause.

The production fix was:

- `26ea750f` — Keep editor STRUCT shell through seamless source handoff

The regression test was:

- `203653f` — Test editor seamless STRUCT handoff keeps shell

The solution preserved the outgoing, already-painted structural client as a cover while the incoming source resolved underneath it. Once B became presentable, the client swapped without destroying the shell.

Crucially, the fix did **not**:

- pause project time;
- restart B at frame zero;
- reopen the decoder;
- invent an extra transition frame;
- change the structural planning contract.

It only changed what was painted while the already-scheduled incoming picture became ready.

That is the central technical lesson of M18:

> **Readiness is not the same thing as visibility, and visibility is not the same thing as having painted pixels.**

A media system needs all three concepts to line up.

---

## The geometry contract

While the handoff bugs were being fixed, the window/fullscreen cases were locked down independently.

The structural planner carries presentation mode and previous presentation mode. Same-mode seamless handoffs require no geometry transition. Mixed-mode seamless handoffs use a 12-frame morph.

The important frame points were tested explicitly:

- frame 0 — exact previous geometry;
- frame 6 — intermediate geometry;
- frame 11 — exact target geometry;
- frame 12 — stable showing geometry.

PREVIEW and BAKE share the same geometry contract rather than each inventing their own interpretation.

That work was isolated in tests such as:

- mixed-mode preview geometry;
- public bake normalized geometry parity;
- structural runtime marker continuity;
- structural first-frame readiness;
- decoder lifetime across a seamless switch.

This mattered because a visually smooth preview with a different baked result would have been worse than an obvious bug. R3nder’s larger promise is deterministic program time, so M18 had to be a planner/runtime/export feature, not merely a widget animation.

---

## Why the real script mattered

Several smaller fixtures were green before the real visual bug was gone.

The script that finally exposed the true behavior had an important topology:

```text
MOSAIC.mosaic
  └── EDIT.main

MOSAIC.mosaic_2
  ├── EDIT.edit
  └── EDIT.main   ← reused
```

That meant the second mosaic was not simply “another video.” It reused a structural source already present in the outgoing application.

It also remained under `SPEED:MAX`, which made authored non-terminal definitions and runtime projection especially important.

The final certification therefore had two parts:

1. the exact realistic GUI script was visually clean;
2. the post-fix focused structural suite passed `+28` tests.

M18’s mainline checkpoint was:

```text
203653f  Test editor seamless STRUCT handoff keeps shell
```

At that point:

- the fullscreen terminal interstitial was gone;
- the wallpaper flash was gone;
- same-mode seamless handoffs were continuous;
- mixed-mode morphs were deterministic;
- decoder lifetime and readiness behavior were covered;
- PREVIEW and BAKE geometry agreed.

M18 was complete.

---

# M19 — Fullscreen becomes an authored GUI property

M18 made fullscreen structural presentation *work*.

M19 made it usable.

The language already had the distinction:

```text
[STRUCT:MOSAIC.mosaic_2]
```

versus:

```text
[STRUCT:MOSAIC.mosaic_2:FULL]
```

The remaining question was where that choice belongs in the GUI.

This turned out to be an ownership problem.

---

## The critical ownership decision

A `MOSAIC` is a reusable source definition.

A `STRUCT` is a placement of that source in the program.

Therefore fullscreen cannot belong to the `MOSAIC` definition itself.

The same mosaic must be allowed to appear windowed in one place and fullscreen in another:

```text
[STRUCT:MOSAIC.mosaic_2]
...
[STRUCT:MOSAIC.mosaic_2:FULL]
```

So the rule became:

> **Presentation mode belongs to the STRUCT placement.**

That keeps source structure and program presentation separate.

It also means there is no duplicate GUI-only fullscreen state. The script remains the source of truth.

---

## The first UX was technically valid and practically wrong

The first M19 slice added two choices to the Add Node palette:

```text
STRUCT MOSAIC
STRUCT MOSAIC FULL SCREEN
```

The parser and serializer were extended so `:FULL` could round-trip correctly.

The tests passed.

But the feature was not actually useful in the real workflow.

Why?

Because the user did not hand-author the mosaic from the Add Node menu. The `EDIT` and `MOSAIC` syntax was generated by dedicated panels elsewhere in the application.

By the time the user reached NODES, the important object already existed:

```text
[STRUCT:MOSAIC.mosaic_2]
```

What was needed was not “choose fullscreen while creating a new STRUCT.”

What was needed was:

> Click the existing generated STRUCT placement and change how that placement is presented.

That was the second major lesson carried forward from M18:

> **A green abstraction is not enough. Test the authoring path people actually use.**

---

## Making STRUCT a first-class node

Before M19, selecting a STRUCT placement in NODES produced the generic fallback panel:

```text
RAW MARKUP
```

That was the architectural smell.

STRUCT was important enough to the program model to have deterministic planning, preview, bake, geometry, and switching behavior, but the GUI still treated it like unknown literal syntax.

M19 fixed that mismatch.

A selected STRUCT placement now gets a real settings panel with:

```text
STRUCT SETTINGS

SOURCE
MOSAIC.mosaic_2

FULL SCREEN
[on/off]
```

The SOURCE control is populated from the actual `EDIT` and `MOSAIC` definitions already present in the document.

The FULL SCREEN control modifies only the placement:

```text
[STRUCT:MOSAIC.mosaic_2]
```

becomes:

```text
[STRUCT:MOSAIC.mosaic_2:FULL]
```

and toggling it off returns to the shortest windowed form.

The source definition itself is untouched.

The core GUI commit was:

- `4a9406f` — Make STRUCT placement first-class in node settings

The direct widget regression was:

- `db437b3` — Test first-class STRUCT fullscreen node control

The test specifically verifies that an **existing generated STRUCT node** owns SOURCE and FULL SCREEN controls and no longer exposes RAW MARKUP.

---

## One last false failure: the test viewport

The first run of the new widget test failed even though the production control was structurally correct.

The problem was the test harness.

`EditorNodeWorkspace` is a desktop editor surface. Flutter widget tests default to a smaller viewport. Mounting the full workspace into that default viewport could produce layout failure before the intended assertions completed.

The test was corrected to use a desktop-sized viewport and to explicitly bring the fullscreen control into view before clicking it:

- `3b3b1bb` — Run STRUCT node control test at desktop viewport

After that, the focused suite passed:

```text
+11: All tests passed!
```

Then the real GUI was launched.

For the first time, the complete authored path existed:

```text
EDIT panel
   ↓
MOSAIC panel
   ↓
generated STRUCT node
   ↓
NODES → STRUCT SETTINGS
   ↓
FULL SCREEN
```

The result worked visually and felt like the model had finally caught up with the engine underneath it.

M19’s mainline checkpoint was:

```text
3b3b1bb  Run STRUCT node control test at desktop viewport
```

---

# What M18 and M19 changed in the architecture

These milestones look like presentation features, but they clarified several deeper rules in R3nder.

## 1. The script remains the source of truth

Fullscreen is not stored in a widget, preference object, or side table.

The GUI writes:

```text
:FULL
```

onto the STRUCT placement, and every downstream system reads the same authored fact.

That keeps editor state, runtime planning, preview, and bake from drifting apart.

## 2. Definition and placement are different kinds of ownership

`EDIT` and `MOSAIC` own reusable structural content.

`STRUCT` owns where that content appears in the program and how it is presented there.

That distinction is now reflected in both syntax and GUI.

## 3. Non-terminal source definitions are not runtime gaps

A script is more than a stream of terminal events.

Reusable definitions can sit textually between two runtime placements without consuming program time. Runtime adjacency has to be computed after accounting for that.

## 4. Test the exact render path the user sees

The longest M18 false trail came from strengthening `ProgramPreviewSurface` while the editor’s real live preview used a different path.

Those improvements were not wasted, but they did not solve the visible defect.

The rule going forward is simple:

> Before chasing a visual bug, identify the exact widget/runtime path that produced the pixels being reported.

## 5. “Ready” needs a precise meaning

Mounted is not painted.

Decoded is not necessarily presented.

A source can be logically ready while the current raster still contains the outgoing client.

M18 forced the preview system to reason about these states more carefully.

## 6. Real-script fixtures are part of the test strategy

Small fixtures are excellent for isolating contracts.

They are not a substitute for realistic topology.

The M18 bug only became obvious when source definitions, reused EDITs, chained STRUCT placements, `SPEED:MAX`, and real media all existed together.

We need both kinds of tests.

## 7. GUI controls should expose semantic ownership, not syntax trivia

The Add Node fullscreen variant was syntactically correct but did not match the authoring workflow.

The first-class STRUCT panel does.

The right GUI question was never “how do I type `:FULL`?”

It was:

> “How should this structural application be presented here?”

That is the level the UI should operate at.

---

# The finished model

After M18 and M19, the structural presentation model is coherent from authoring to bake.

A reusable source can be defined once:

```text
[MOSAIC:mosaic_2]
...
[/MOSAIC]
```

It can then be placed windowed:

```text
[STRUCT:MOSAIC.mosaic_2]
```

or fullscreen:

```text
[STRUCT:MOSAIC.mosaic_2:FULL]
```

Adjacent placements can use the existing:

```text
[CONFIG:APPSWITCH:SLIDE]
```

to remain visually continuous, including deterministic window/fullscreen morphs.

The GUI exposes the placement as a first-class object. Preview and bake consume the same structural plan. Decoder lifetime is not tied to presentation chrome. Project time does not stop to wait for a frame.

That is a much larger result than “fullscreen mosaic works.”

It means structural video is becoming a real authored vocabulary in R3nder rather than a collection of special cases.

---

# Milestone checkpoints

## M18

Final tested mainline checkpoint:

```text
203653f  Test editor seamless STRUCT handoff keeps shell
```

Representative battle commits:

```text
7b470945  Keep STRUCT chains across source definitions
6c80237a  Correct STRUCT chain planner assignment
7bcdfed4  Test STRUCT chains across source definitions
26ea750f  Keep editor STRUCT shell through seamless source handoff
203653f   Test editor seamless STRUCT handoff keeps shell
```

Final focused certification:

```text
+28: All tests passed!
```

plus the exact real GUI script visually passing without terminal or wallpaper flash.

## M19

Final tested mainline checkpoint:

```text
3b3b1bb  Run STRUCT node control test at desktop viewport
```

Representative commits:

```text
4a9406f  Make STRUCT placement first-class in node settings
db437b3  Test first-class STRUCT fullscreen node control
3b3b1bb  Run STRUCT node control test at desktop viewport
```

Final focused certification:

```text
+11: All tests passed!
```

followed by the first successful real GUI authoring of a fullscreen structural video mosaic from the generated STRUCT node.

---

# Closing note

M18 and M19 were hard because they crossed boundaries that had previously been allowed to remain separate: parser and planner, source definitions and runtime sequence, media readiness and painted pixels, preview and bake, engine capability and GUI ownership.

The bugs kept appearing at those boundaries.

The result is that those boundaries are now much clearer.

M18 made structural applications behave continuously.

M19 made that behavior belong to the author.
