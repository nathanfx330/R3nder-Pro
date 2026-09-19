# r3nder Pro: Making APPSWITCH:SLIDE Actually Slide Between STRUCTs

This document records the September 2026 follow-up to the original M18 structural application-switch work.

M18 solved continuity. Adjacent STRUCT placements could remain on the desktop without flashing the terminal or wallpaper between them. `[CONFIG:APPSWITCH:SLIDE]` suppressed unnecessary close/open choreography, preserved decoder continuity, and let one structural application hand directly to the next.

What M18 did **not** yet do was literally slide the outgoing structural client away while the incoming client entered.

That distinction finally became visible when the application was used rather than merely inspected through the planner:

> “The app slide doesn't slide between structs.”

That sentence exposed a semantic gap between the name of the mode and what the renderer actually did.

The work that followed touched structural planning, two separate preview paths, readiness ownership, raster testing, editor projection timing, and structural audio. It also uncovered two unrelated-but-real pieces of technical debt that only became obvious because the new transition exercised the exact boundary where source time, presentation time, and editor line ownership meet.

The short version is:

```text
APPSWITCH:SLIDE already existed
        ↓
STRUCT planner removed close/open budgets
        ↓
visual handoff still hard-swapped clients
        ↓
reuse APP's 22-frame horizontal pan language
        ↓
implement in editor StructuralSequencePreview
        ↓
discover Program Preview has a separate keyed handoff path
        ↓
implement there too without losing preload/no-flash behavior
        ↓
stale raster guard fails for the wrong title-bar color
        ↓
repair the guard rather than weakening it
        ↓
live slide works
        ↓
AUDIO-enabled seamless STRUCT reports 328 of 329 source frames
        ↓
trace editor projection framing
        ↓
discover editor PAUSE compensation was one frame too short
        ↓
split runtime and editor projection budgets
        ↓
all focused tests pass
        ↓
live verification confirms both SLIDE and ordinary desktop switching
        ↓
PR #15 → main cd5ad51
```

The live Preview result is simple to describe:

> Under `APPSWITCH:SLIDE`, compatible adjacent STRUCT applications now visibly pan from one client to the next, inside a fixed structural shell, without adding project time or disturbing the existing desktop APP switching language.

This session did **not** add the equivalent two-source pan to `ProgramStructuralFrameRenderer`. Whole-program BAKE still renders the single active STRUCT placement. The journey therefore records live Preview motion as complete, while final BAKE pixel parity for that motion remains open.

Getting there required understanding exactly what “slide” owned.

---

# 1. The starting point: continuity was not motion

The existing planner already understood:

```text
[CONFIG:APPSWITCH:SLIDE]

[STRUCT:EDIT.a]
[STRUCT:EDIT.b]
```

and `StructuralSequencePlacement` already carried:

```text
seamlessFromPrevious
seamlessToNext
```

Under SLIDE, compatible adjacent placements suppressed the window close/open budgets that would normally sit between them.

That was valuable. It prevented the structural shell from tearing down between applications.

But when we traced the actual render path, the behavior was effectively:

```text
A remains visible while B becomes ready
        ↓
B paints one presentable frame
        ↓
A disappears
        ↓
B remains
```

The shell stayed alive, so there was no wallpaper flash. But the client content changed by cut.

In other words, the implementation had reached:

> seamless CUT

while the authored language said:

> SLIDE

That difference matters. A configuration name is part of the product contract. If an author selects SLIDE, suppressing close/open choreography is necessary but not sufficient. The visible application content has to move.

The first decision was therefore not to invent a new transition or a second STRUCT-specific configuration.

The mode already existed. Its visual meaning needed to be completed.

---

# 2. Reuse the APP motion language

r3nder already had a working visual definition of an application slide in the desktop APP/MOSAIC system.

That path used:

- a fixed horizontal pan;
- outgoing content moving left;
- incoming content entering from the right;
- `Curves.easeInOutCubic`;
- a 22-frame budget, `kAppPanFrames`;
- fixed window chrome while the content moves beneath it;
- title crossfade when the outgoing and incoming titles differ.

That gave us the correct design target immediately.

The STRUCT implementation should not invent a second visual dialect for the same authored word.

The rule became:

```text
APPSWITCH:SLIDE

APP → APP
    uses the existing APP page-pan language

STRUCT → STRUCT
    uses the same visual language inside the structural shell
```

We named the structural timing contract:

```dart
const int kStructuralSwitchSlideFrames = kAppPanFrames;
```

The alias is intentional. STRUCT has its own semantic timing constant, while explicitly declaring that its visual budget matches APP.

The pan does **not** add 22 frames to the program.

Those frames overlap the beginning of the incoming STRUCT's already-authored showing span.

That preserves the larger r3nder timing invariant:

> A visual treatment may divide or decorate authored time. It does not silently extend the piece.

---

# 3. The first render path: editor StructuralSequencePreview

The editor live preview can reuse one `StructuralSequencePreview` State object while the active placement changes from A to B.

That path already had a useful handoff mechanism from M18.

When a seamless source change occurred, it snapshotted the outgoing source:

```text
outgoing source
outgoing raw document
outgoing source frame
outgoing source duration
outgoing overlay mode
outgoing window title
outgoing top/bottom copy
```

Then it mounted B underneath A.

Before this work, the first presentable frame callback simply cleared that outgoing cover.

That was the hard cut.

The new behavior changed the meaning of readiness.

B becoming ready no longer means:

> remove A now

It means:

> the visual slide is allowed to begin

The two clients remain in the same clipped stack.

Conceptually:

```text
fixed structural window
┌───────────────────────────────┐
│                               │
│   A ───────────────→ left     │
│       B ←──────────── right   │
│                               │
└───────────────────────────────┘
```

The outgoing translation is:

```text
x = -t
```

The incoming translation is:

```text
x = 1 - t
```

where `t` is the eased progress over the structural switch budget.

At the midpoint, both clients are present.

At the end:

- A is gone;
- B is seated at zero translation;
- source time has never restarted;
- the shell itself has never moved.

This is important because the transition is between **applications inside the shell**, not between two independent desktop windows.

---

# 4. The second render path: Program Preview was different

The first implementation fixed the reused-widget path.

Then we stopped and checked a dangerous assumption:

> Is that also the path top-level Program Preview uses?

It was not.

Program Preview preserves adjacent STRUCTs as separately keyed widgets so it can preload the incoming media source before it becomes active.

Its M18 handoff logic did this:

```text
preload B hidden
        ↓
B becomes active
        ↓
A remains on top until B earns one active paint
        ↓
remove A
```

Again, that was perfect for preventing a black or wallpaper flash.

It was not a slide.

Had we stopped after the first implementation, the editor could have slid while top-level Program Preview still cut.

That would have created exactly the kind of split runtime behavior r3nder's architecture is supposed to prevent.

The fix introduced a parent-coordinated handoff role:

```dart
enum StructuralSequenceHandoffRole {
  none,
  incoming,
  outgoing,
}
```

Program Preview now keeps both keyed placements alive through the authored switch window.

The active B layer receives the incoming role.

The previous A layer becomes an overlay-only outgoing role.

That overlay deliberately does **not** repaint another desktop and another structural shell underneath itself. It contributes only the outgoing client/title information needed for the pan.

The resulting composition is:

```text
ScenePainter / desktop
        ↓
fixed incoming structural shell
        ↓
incoming client translating from right
        ↓
outgoing client overlay translating left
```

This preserved all the useful M18 behavior:

- B can still preload;
- A still covers B until B has actually painted;
- project time does not wait for decode;
- B does not restart at source frame zero;
- the transition remains deterministic.

Readiness became a gate into authored motion rather than a timing source.

---

# 5. A subtle but important rule: readiness cannot consume transition time

The Program Preview preload path created a timing question.

Suppose B is late.

Should the slide begin 22 wall-clock frames after B finally appears?

No.

That would make project timing depend on machine speed.

The actual contract is:

```text
authored B source frame
        determines slide progress

decoder readiness
        determines only whether B may be exposed
```

So readiness can delay *visibility* of the transition, but it cannot create a new private animation clock.

The transition still derives from the incoming source frame.

That means:

- if B is ready at incoming source frame 0, the full pan is visible;
- if B becomes presentable late, the visual handoff may join at the appropriate authored progress;
- no extra frames are inserted;
- the program clock remains authoritative.

The regression test explicitly protects this idea:

> Readiness is a gate, not a timing source.

That sentence is worth keeping.

---

# 6. The first failed test was not the new bug

The focused gate initially failed in:

```text
test/program_preview_structural_raster_handoff_test.dart
```

with:

```text
Expected: a value greater than <1000>
Actual: <0>

The first B frame must still rasterize a structural shell.
```

At first glance, this looked serious.

The whole point of the M18 raster regression was to prove that a desktop-only frame never leaks through the handoff.

We did not weaken it.

Instead we traced what the test was actually counting.

The detector was searching a constrained title-bar region for:

```text
#33302F
```

But the current production structural/Yaru title bar on main was:

```text
#222222
```

The raster test had become stale.

This exact test was already known baseline debt before the new SLIDE work. The new branch had merely forced us to confront it again.

The correct fix was:

- keep the tight sample region;
- keep the `>1000` pixel threshold;
- update the expected production plate color to `#222222`.

That restored the original intent of the test:

> Prove a structural shell is physically present in the raster.

The lesson is not “update a color when a test fails.”

It is:

> A failing regression can be product failure, harness failure, or stale expectation. Preserve the contract and identify which one actually moved.

After the detector was repaired:

```text
00:02 +1: All tests passed!
```

---

# 7. Live verification found the more important timing bug

The slide then worked in the actual application.

But a new visible error appeared:

```text
ProgramStructuralAudioException:
STRUCT placement 0 exposed 328 source frames through runtime,
but the source owns 329.
```

That was exactly the kind of error we did **not** want to dismiss as “close enough.”

One missing frame at a structural boundary is a timeline contract failure.

The difference was also extremely diagnostic:

```text
expected 329
observed 328
difference 1
```

Placement 0 was the outgoing seamless STRUCT.

That told us to investigate the event boundary, not the decoder.

---

# 8. Why APPSWITCH:SLIDE exposed a hidden editor projection bug

STRUCT placement duration is projected into terminal execution differently depending on the caller.

Real Preview and BAKE use an internal runtime marker:

```text
[REGION:STRUCTSEQ_...][PAUSE:N]
```

The editor line-map projection does not need that internal REGION. It keeps the authored line identity and emits a plain PAUSE.

Those are not the same framing shape.

## Runtime projection

A runtime-marked structural event owns two framing frames outside explicit pause age:

```text
REGION entry
PAUSE entry
pause age
```

So its compensation is:

```text
event duration - 2
```

## Editor line-map projection

The editor owns only:

```text
PAUSE entry
pause age
```

There is no REGION entry frame.

So its compensation must be:

```text
event duration - 1
```

Before this bug was found, both paths reused the same `duration - 2` helper.

That made every editor-projected STRUCT event one frame too short.

Why had this not exploded earlier?

Because a normal STRUCT has exit choreography after the source showing span.

The missing event frame was usually consumed in closing/zoom territory, where it did not truncate source playback.

A seamless outgoing STRUCT under `APPSWITCH:SLIDE` can have:

```text
exitWindowFrames = 0
exitZoomFrames = 0
```

Its source showing span therefore reaches the exact event boundary.

The hidden one-frame projection error suddenly became the last source frame.

That is why the new visual slide did not *cause* the audio bug.

It removed the padding that had been hiding it.

This was the most useful architectural discovery of the session.

---

# 9. Split the projection contracts instead of adding a special case

The fix introduced explicit constants:

```dart
const int kStructuralRuntimeProjectionFramingFrames = 2;
const int kStructuralEditorProjectionFramingFrames = 1;
```

The older name remains as a compatibility alias to the runtime-marker budget.

The projection helper now receives whether runtime markers are present and chooses the framing cost accordingly.

This is better than teaching the audio tracer to tolerate one missing frame.

It repairs the source of truth:

```text
authored event duration
        ↓
correct projection
        ↓
correct editor frame map
        ↓
correct local STRUCT frame
        ↓
correct source frame
        ↓
correct structural audio span
```

The audio system remains strict.

A 329-frame source must expose 329 source frames.

That strictness is what found the bug.

---

# 10. The AUDIO + SLIDE regression

A dedicated regression was added using two adjacent AUDIO-enabled STRUCT placements under:

```text
[CONFIG:APPSWITCH:SLIDE]
```

The test requires both sources to expose their complete authored durations.

More importantly, it checks the boundary relationship:

```text
outgoing.programEndFrameExclusive
    ==
incoming.programStartFrame
```

That proves the final outgoing source frame exists and the incoming source begins immediately after it, with neither a missing frame nor an invented gap.

After the projection fix:

```text
00:02 +19: All tests passed!
```

The red in the application disappeared.

This is a useful example of why audio timing tests belong in structural-video work.

Picture can often hide a one-frame ownership error through clamping or retained visuals.

Audio span validation is less forgiving.

That is a feature.

---

# 11. The final live acceptance test

After the focused gates passed, the real application was run again.

The important observations were:

1. adjacent STRUCT applications visibly slid;
2. the outgoing client moved left;
3. the incoming client entered from the right;
4. the structural shell stayed seated;
5. the audio frame-count error was gone;
6. ordinary desktop switching language still worked independently;
7. desktop switching remained its own mode rather than being hijacked by the new STRUCT implementation.

That last check mattered.

The desired result was never:

> replace the existing desktop APP transition with the new STRUCT slide

It was:

> let the same APPSWITCH vocabulary drive the appropriate implementation at each ownership layer

So the finished model is:

```text
APPSWITCH mode
    ↓

desktop APP language
    → existing APP switching implementation

STRUCT placements
    → structural application switching implementation
```

The mode is shared.

The render owners remain distinct.

The user verified both in the same main build.

---

# 12. What changed in the current live Preview contract

After this work, `[CONFIG:APPSWITCH:SLIDE]` means more in live Preview than it did at the end of M18.

For compatible adjacent STRUCT placements:

- close/open structural shell budgets remain suppressed;
- the shell remains fixed;
- outgoing client content pans left;
- incoming client content enters from the right;
- the pan uses `easeInOutCubic`;
- the nominal visual budget matches APP at 22 frames;
- the pan overlaps incoming authored showing time rather than extending duration;
- different titles crossfade while the shell plate remains fixed;
- preload/readiness may gate visibility but cannot retime the transition;
- the editor reused-State path and top-level Program Preview keyed path both implement the behavior;
- the existing desktop APP switching implementation remains independent;
- editor line-map projection exposes the complete structural source duration;
- AUDIO-enabled seamless placements retain their final source frame.

Those statements are proven for the live Preview paths and for shared timing/audio ownership. They do **not** yet prove that final BAKE paints the same two-client pan. That visual export parity remains a separate task.

---

# 13. The tests that now protect the boundary

The important proof files are:

```text
test/structural_sequence_test.dart
```

Protects structural planning and the distinct editor/runtime projection framing budgets.

```text
test/structural_sequence_preview_test.dart
```

Protects the actual client translation in the reused editor preview path, including midpoint geometry, opposite outgoing/incoming offsets, and authored slide progress rather than fixed visual bands.

```text
test/program_preview_structural_raster_handoff_test.dart
```

Protects the top-level keyed Program Preview handoff, including the no-desktop-flash raster contract and the fact that A remains alive through the slide window rather than disappearing after B's first active paint.

```text
test/program_structural_audio_test.dart
```

Protects complete source-frame exposure under AUDIO + APPSWITCH:SLIDE and the exact outgoing/incoming audio boundary.

The live visual gate remains essential because this feature is fundamentally about continuity in motion.

---

# 14. The wrong turns were useful

Several parts of the journey are worth preserving because they are exactly the sort of mistake that will recur in a media application.

## Wrong assumption: “seamless” already meant “slide”

It did not.

The planner had implemented transition *budgeting* and shell continuity, not client motion.

A semantic name needs to be verified at the paint boundary.

## Wrong stopping point: fixing one StructuralSequencePreview path

r3nder had two real structural handoff paths:

- reused-State editor preview;
- separately keyed top-level Program Preview.

Fixing one would have created divergent behavior.

Whenever a product has “preview” in more than one place, identify the exact runtime owner before declaring a visual feature complete.

## Wrong interpretation: the raster failure proved the slide broke the shell

It did not.

The test was looking for an obsolete color.

The right response was to restore the test's semantic detector, not loosen the threshold or delete the assertion.

## Wrong possible fix: accept 328 frames because the visual result looked fine

That would have encoded a timing defect into the audio layer.

The source owned 329 frames.

The only acceptable result was to discover why the editor exposed 328.

Strict invariants are valuable because they force hidden ownership errors into the open.

---

# 15. Transferable lessons

## 1. A transition name has visual semantics

If the language says SLIDE, do not stop at continuity or budget suppression.

Trace the final pixels.

## 2. Presentation motion should not become hidden duration

The 22-frame pan is taken from authored incoming showing time.

It does not lengthen the program.

## 3. Readiness is a gate, not a clock

Decode completion may control exposure.

It may not create a private transition timeline.

## 4. Two preview paths are two implementations until proven otherwise

Shared classes do not guarantee shared lifecycle behavior.

The editor and Program Preview needed separate handoff coordination.

## 5. Zero exit budget is an excellent boundary test

Removing close/zoom frames exposed a one-frame editor projection bug that ordinary STRUCTs had hidden.

Transitions that collapse framing are valuable tests of timeline arithmetic.

## 6. Projection framing must describe the projection actually emitted

`REGION + PAUSE` and `PAUSE` do not have the same framing cost.

A shared helper was only correct while nobody exercised the boundary sharply enough.

## 7. Audio can be the best detector of picture-timing bugs

A retained image can conceal a missing frame.

A strict audio span cannot.

## 8. Preserve mode separation

Shared authoring vocabulary does not imply one renderer.

APP switching and STRUCT switching can consume the same APPSWITCH mode while remaining owned by different presentation systems.

---

# 16. Checkpoints

The feature branch was:

```text
struct-appswitch-slide
```

Important checkpoints during the session included:

```text
63a195b
    first complete visual STRUCT slide implementation

a3339c6
    repaired stale #33302F raster probe to current #222222 shell plate

54836cd
    final branch tip with corrected editor STRUCT projection timing
    and AUDIO + SLIDE regression
```

PR:

```text
#15  Slide between seamless STRUCT applications
```

Squash-merged main checkpoint:

```text
cd5ad5168f6b2fc52b3605754548251927856ab8
short: cd5ad51
```

The live acceptance on that main build confirmed:

```text
STRUCT APPSWITCH:SLIDE
    works

AUDIO structural timing
    clean

desktop APP switching language
    still works as its own mode
```

---

# Closing note

This session began with a small observation: the mode was named SLIDE, but the structural applications did not visibly slide.

Following that observation all the way down uncovered three distinct layers of truth:

```text
planner truth
    the close/open budgets were already correct

paint truth
    the clients were still hard-swapping

timeline truth
    the editor projection was silently one frame short
```

All three had to agree before the feature was actually complete.

That is a recurring pattern in r3nder Pro.

A media feature is not finished when the parser understands it, when the planner schedules it, or when one preview path looks right.

For this session, the live Preview slice was complete when authored language, deterministic time, decoder lifetime, visible motion, audio span, tests, and the real application all described the same event. Final BAKE still has one explicit piece of parity work left: paint the same two-client slide rather than only the active STRUCT.
