# R3nder Pro: From ProjectClock to Structural Video Preview and Bake Parity

This document records the development path that led R3nder Pro from a terminal-driven renderer with a new timing foundation to a system that can author reusable video structures, place them into the main TEXT sequence, present them as desktop windows, play them in both EDIT and top-level PREVIEW, bake those same structural frames into the final program, and return cleanly to the terminal.

It happened over several working sessions and many branches. The important part is not the number of commits. It is the sequence of architectural decisions that made the final round-trip and eventual preview/bake parity possible.

The short version is:

```text
ProjectClock
    ↓
explicit-time scene evaluation
    ↓
native audio authority and A/V lock
    ↓
lossless structural CST
    ↓
EDIT / TRACK / CLIP
    ↓
persistent MLT media
    ↓
visual edit surface
    ↓
EDIT and MOSAIC as reusable sources
    ↓
STRUCT as a main-sequence placement
    ↓
editor-side structural round-trip
    ↓
top-level PREVIEW runtime bridge
    ↓
real themed terminal handoff
    ↓
whole-program STRUCT BAKE
    ↓
PREVIEW frame N ≈ BAKE frame N
```

The final result looks simple. Getting there was not.

---

## 1. The reset: timing had to become real first

The turning point came when we stopped trying to layer more features onto an ambiguous playback clock and made **ProjectClock** the foundation.

The early rule was straightforward: Flutter could decide when to poll, but it could not be the authority on project time. Scene evaluation had to be driven by explicit project time, and any frame had to remain reproducible from the same authored state.

That work became M1 and M2:

- ProjectClock became the common time model.
- Scene evaluation moved toward explicit project-time inputs.
- Preview polling and scene state were separated.
- The renderer stopped treating callback cadence as if it were timeline truth.

That sounds like infrastructure because it was. It also became the reason later video work could be reasoned about in integer frames instead of by feel.

A second process rule was established at the same time: **whole-file replacements only for source changes**. After enough failed patch-script experiments, we stopped trying to perform clever textual surgery on the repo. Every code change had to be inspectable as a complete file. It made the work slower in individual edits and much safer across a long sequence of architectural changes.

---

## 2. M3 and M4: audio became an authority, not decoration

Once ProjectClock existed, the next problem was A/V truth.

Audio could not merely start “around the same time” as video. The system needed to know what had actually reached the output device, what latency had been negotiated, and how playback should re-anchor after a device change or stream restart.

M3 and M3.1 established native audio-clock authority and hardened it:

- anchor timing was corrected;
- release-to-monotonic timing was clamped;
- generation counters protected against stale callbacks;
- flush and destroy paths received bounded shutdown behavior;
- device-change behavior was treated as a full re-arm rather than a minor edge case.

M4 then validated sustained A/V lock.

The important lesson was not “audio works.” It was that **timing correctness had to be proven before editing and compositing could mean anything**. If the clock moved underneath us later, every measurement made by the editor would have been suspect.

That is why the clock work came first.

---

## 3. M5 and M6: the script had to survive being edited

The next major problem was representation.

R3nder already had a script language. What it did not have was a safe way to let a GUI structurally edit that language without destroying formatting, comments, opaque regions, or syntax it did not understand.

The answer was a lossless concrete syntax tree.

M5 and M6 established a CST that could recognize structural regions while preserving the original document exactly. Structural blocks such as EDIT, TRACK, MOSAIC, PANE, and CLIP became real nested ownership regions, while lexical areas such as CARD, DOSSIER, TIMELINE, DEF_MENU, and comments remained opaque where appropriate.

This was the first major separation of responsibilities:

```text
TEXT script
    owns program order and narration-driven presentation

structural CST
    owns reusable video source definitions
```

The critical contract became:

> Parsing structure must not imply rewriting the rest of the document.

Untouched markup had to round-trip byte-for-byte.

That contract later made it possible for the node editor, the visual EDIT surface, and hand-authored script to coexist instead of fighting over ownership.

---

## 4. M7: EDIT / TRACK / CLIP became a real authored model

With lossless structure available, the editor language could finally become more than a sketch.

M7 introduced the authored model:

```text
[EDIT:main]
  [TRACK:V1]
    [CLIP:...]
    [/CLIP]
  [/TRACK]
[/EDIT]
```

The important decision was that CLIP geometry would be expressed in exact project and source frames.

A clip had to know:

- where it lived in project time;
- where it entered the source;
- how many authored project frames it occupied;
- its exact speed relationship;
- its source reference.

We deliberately avoided inventing a second canonical “out” value that could drift from duration. The model had to have one source of truth for each piece of timing information.

This was where R3nder started becoming an editor rather than only a renderer with video attached.

---

## 5. M8 and M9: MLT became the persistent media layer

The media backend was treated as a bakeoff before it became architecture.

The requirement was not simply “can this decode a frame?” It was whether the backend could survive the way an editor actually behaves:

- repeated scrubbing;
- exact source-frame requests;
- decoder reuse;
- seek churn;
- structural composition;
- preview and export needing the same source semantics.

MLT won that role.

The rule that emerged was:

> MLT decodes leaf media. R3nder owns project time, structure, composition, and final pixels.

That distinction stayed important. R3nder did not hand its timeline model over to MLT. It used MLT as a persistent media engine underneath its own deterministic frame model.

M9 turned that into a persistent media layer instead of a one-shot decoder path.

---

## 6. M10: the edit surface became visible

M10 was where the backend work finally had to survive contact with the GUI.

The visual edit surface grew into something recognizably editor-like:

- V1 and V2 lanes;
- clip dragging;
- source-backed live preview;
- split operations;
- crossfade and LUMA transition authoring;
- ADD VIDEO and ADD OVERLAY flows;
- persistent decoder scrubbing with exact source-frame mapping.

Splitting was a good example of the standard we adopted. A split could not merely look right. It had to produce two valid authored CLIPs, preserve the exact source mapping, and keep incoming transition ownership on the correct side.

Several apparently small GUI failures were useful because they exposed incorrect assumptions:

- invalid Dart regex forms;
- variable shadowing that broke model getters;
- preview lookup failures;
- controls rendered off-screen;
- missing Material ancestors;
- RenderFlex overflows.

None of these were glamorous, but they mattered because M10 was the first point where the architecture had to behave as an application rather than as isolated model tests.

---

## 7. M11 through M14: structural sources became composable

The next leap was conceptual.

An EDIT could not remain only something visible inside the EDIT workspace. It had to become a **source**.

Then a MOSAIC had to become a source too.

M11 introduced structural composability. M12 carried that model into structural export. M13 handled structural-source audio behavior. M14 added preview seams and decoder injection so these paths could be exercised independently.

The hierarchy settled into:

```text
raw video
   ↓
EDIT          cut and timing
   ↓
MOSAIC        spatial arrangement
   ↓
STRUCT        placement in main program
   ↓
TEXT sequence + narration/music
```

This hierarchy solved a problem that had been lurking since the first GUI experiments: **definition is not execution**.

An EDIT block defines a reusable source.

A MOSAIC block defines another reusable source.

Neither should consume main-sequence time merely by existing in the document.

That distinction became the foundation of M16.

---

## 8. M15: ownership had to be audited before the GUI could trust it

Before going hard into GUI integration, structural ownership received its own audit.

M15 locked the nesting and ownership rules so that a block had to belong to the parse that claimed it. Structural roots were isolated from ordinary node parsing, export resolver seams were tested, and nested source ownership was made explicit.

This was one of those milestones that is almost invisible in the final UI and essential to it.

Once the GUI started creating, reordering, and referencing structural sources, there could be no ambiguity over who owned which part of the source document.

At the end of M15, the focused closure tests, targeted tests, and full repo tests were all green. That was the point where we deliberately moved away from backend-only work and into the GUI.

---

## 9. M16: stop proving pieces and make it a tool

The goal of M16 was explicit: **see R3nder come together as a tool**.

The GUI workflow became:

```text
create/open EDIT
→ import clips
→ trim and split visually
→ create MOSAIC
→ assign cuts spatially
→ place structural source into main sequence
→ scrub/play in TEXT
→ return to terminal
```

### EDIT trim controls

Selected clips gained source controls and direct actions:

```text
SOURCE IN
SOURCE OUT
CUT

TRIM IN
TRIM OUT
SPLIT
```

The existing draggable trim handles remained.

### MOSAIC became spatial

An early MOSAIC workflow still thought too much like a timeline. That was wrong for the job.

MOSAIC was changed to be layout-first:

- one, two, or three panes;
- existing EDIT cuts assigned into those panes;
- ASSIGN CUT, CHANGE CUT, CLEAR;
- no duplicate range-authoring workflow inside MOSAIC.

The division became clean:

```text
EDIT = time
MOSAIC = space
```

That was a much better mental model.

---

## 10. Audio ownership had to be separated again

When structural preview first entered the main environment, it inherited narration/music behavior in places where it should not have.

That exposed another ownership problem.

The final rule became:

```text
EDIT / MOSAIC
    picture/source authoring
    silent by default

TEXT main sequence
    narration/music ownership
```

Structural authoring can opt into workspace audio for specialized cases, but it does not inherit it by default.

This mattered for the next step, because a structural video call inside the main TEXT program needed the narration/music bed to continue from the main sequence rather than being duplicated by the source definition.

---

## 11. STRUCT: the missing bridge between definitions and the program

The key syntax arrived as a standalone sequence placement:

```text
[STRUCT:EDIT.main]
```

or:

```text
[STRUCT:MOSAIC.wall]
```

The meaning is intentionally simple:

> At this point in the main sequence, present this already-authored structural source.

That gave us a clean distinction:

```text
[EDIT:main] ... [/EDIT]
    defines EDIT.main

[MOSAIC:wall] ... [/MOSAIC]
    defines MOSAIC.wall

[STRUCT:MOSAIC.wall]
    executes MOSAIC.wall here
```

STRUCT owns no duplicate source duration. The source definition remains the authority for its authored hold.

The GUI gained **ADD TO SEQUENCE**, so normal workflow no longer required hand-writing STRUCT markup.

NODES also learned that STRUCT is a real sequence node:

- visible;
- reorderable;
- deletable;
- duplicable;
- distinct from the protected EDIT/MOSAIC definition cards.

This was the point where reusable video structure entered the main program model.

---

## 12. Structural timing: source time and presentation time are different

A structural source might contain 323 authored frames, but a main-sequence presentation of that source also needs time to enter and leave the desktop.

Those are not the same duration.

The placement model was expanded into deterministic stages:

```text
zoomOut
opening
showing
closing
zoomIn
```

Using the native SceneEngine timing constants:

```text
18 frames  terminal zoom out
12 frames  window handoff/open
N frames   structural source
12 frames  close/handoff
18 frames  terminal zoom in
```

So a 323-frame source occupies 383 main-sequence frames.

Source media advances only during the showing portion. Presentation choreography consumes sequence time without corrupting source time.

That separation was essential to making the event feel like part of R3nder rather than a video widget pasted over the preview.

---

## 13. The first structural preview worked, but it did not feel real

The first version proved the bridge technically. It did not prove it visually.

The structural preview initially appeared as a generic shell. It did not inherit the desktop choreography convincingly.

We then worked through the transition in visible steps.

### Attempt 1: shrink terminal, show structural window

The terminal shrank to one geometry while the new video window appeared at another.

The result looked like a jump.

### Attempt 2: continuous geometry

The new window started from the terminal's parked rect and interpolated to its destination.

The jump disappeared, but the terminal got too small and the destination still felt arbitrary.

### Attempt 3: aim directly at final video-panel geometry

The terminal now resized directly toward the final panel geometry.

Better, but the handoff still looked like a fade rather than a new window coming forward.

### Attempt 4: foreground emergence

The structural window started slightly smaller and lower, then rose and grew toward its final position with a stronger shadow.

Now it felt like it was physically coming forward.

The terminal faded behind it instead of simply disappearing.

That got the opening close.

---

## 14. The black flash: a one-frame artifact that exposed several real bugs

The final opening seam looked tiny: the structural window would briefly show either:

```text
NO VIDEO AT THIS FRAME
```

or a black client before the first real image appeared.

Fixing that one flash turned into one of the most instructive parts of the whole journey.

### First diagnosis: preload frame 0

We moved the frame-zero decode into the terminal zoom-out, while the structural window was still invisible.

That was necessary, but not sufficient.

### Second diagnosis: the initial status was lying

`EditVideoPreview` initialized itself with:

```text
NO VIDEO AT THIS FRAME
```

before it had evaluated anything.

That meant the UI could display a false negative while the first image was simply still decoding.

The initial state was changed to neutral. A true no-video message now appears only after actual frame evaluation proves there is no picture.

The text flash disappeared.

The black flash remained.

### Third diagnosis: readiness had to mean “image is resident”

Decoder request was not enough.

RGBA pixels existing somewhere in the media pipeline was not enough.

The foreground window had to stay invisible until Flutter had an actual presentable `ui.Image` resident.

A first-frame readiness signal was added at that boundary.

The terminal would not begin yielding and the structural window would not gain opacity until that readiness signal fired.

### Fourth diagnosis: the tests were not waiting for engine image decode

`pumpAndSettle()` could return before `ui.decodeImageFromPixels()` had completed because the callback came from the engine async loop rather than Flutter's normal scheduled-frame queue.

The tests had been confusing “decoder asked” with “picture ready.”

The test helper was changed to wait for an explicit readiness marker.

### Fifth diagnosis: the decoder was actually remounting

One remaining test showed the fake backend opening twice.

The media configuration had not changed. The resolver was stable. The source was stable.

The real cause was widget identity.

The structural preview itself had a key, but the top-level `Positioned` wrapper in the `Stack` did not. When the terminal sibling disappeared, the structural window shifted sibling position. Flutter could remount that subtree even though the nested preview key looked stable.

That remount destroyed and reopened the decoder.

The fix was to key the **top-level Stack layers themselves**.

After that:

```text
00:03 +11: All tests passed!
```

And, more importantly, the visual black flash was gone.

This was the moment the structural-video opening became truly seamless.

---

## 15. The ribbon exposed hidden engine-owned time

Once the video call looked right, the ribbon made another seam obvious.

There was a visible black gap immediately before the STRUCT event even though the preview was actively transitioning.

The cause was the frame-to-line map.

During a short outgoing desktop/window animation, some frames had no authored node owner. `buildRibbonBlocks()` treated those frames as nobody's time, closed the previous block, and waited until the next authored node appeared.

For a timeline UI, that was the wrong interpretation.

Those engine-owned handoff frames belong visually to the presentation that led into them.

The ribbon was changed so a short unmapped runtime span inherits the previous authored event until the next real node takes ownership. End-hold remains excluded.

STRUCT also received the presentation/window band instead of falling through as ordinary TEXT.

Now the ribbon describes the runtime continuously.

---

## 16. The return path: a window must become the terminal

The opening was now seamless. The return still felt wrong.

The structural video window receded and the terminal returned, but the terminal's top bar did not merge correctly into fullscreen.

The problem was chrome geometry.

The terminal ghost kept a full 38-pixel title bar while the terminal rectangle expanded. Then the title bar simply disappeared when normal fullscreen terminal rendering resumed.

Native ScenePainter does not do that.

Its terminal return is:

```text
parked terminal with full chrome
→ terminal grows
→ title bar shrinks
→ corners flatten
→ border and shadow collapse
→ fullscreen terminal with no chrome
```

The structural terminal ghost was given a chrome parameter from 0 to 1.

That parameter now drives:

- title-bar height;
- corner radius;
- border;
- shadow;
- title visibility.

The top bar physically collapses into the terminal as the terminal grows.

The return finally read as one object changing state rather than one window being replaced by another.

---

## 17. The last editor-side seam: fullscreen meant the wrong rectangle

One final mismatch remained in the editor-side structural preview.

The terminal return looked correct until it reached “fullscreen,” because structural preview was using the entire editor preview widget as the fullscreen rectangle.

Normal ScenePainter does something different: it fits the project's output frame into the preview pane and centers it, leaving letterbox outside when the pane aspect does not match.

R3nder currently exposes 1080p and 4K output formats, both 16:9.

So in an 800×500 editor preview:

```text
outer preview: 800 × 500
render frame:   800 × 450
letterbox:       25 px top
                 25 px bottom
```

Structural preview was expanding the terminal into all 800×500 and then snapping back to 800×450 when ScenePainter resumed.

The structural desktop, terminal, and video choreography were moved inside the same fitted 16:9 render frame.

The letterbox remains outside the program frame, exactly as it does for normal preview.

That removed the last visible editor-side geometry mismatch.

---

## 18. The first round-trip

At the end of M16, we successfully completed the first clean structural video call round-trip inside the **EDIT window**, the mode with the script text editor and its own preview pane:

```text
TEXT / terminal
→ terminal pulls back into the desktop
→ first structural frame preloads invisibly
→ structural window comes forward with picture already resident
→ terminal fades behind it
→ structural video plays
→ structural window recedes
→ terminal returns beneath it
→ terminal chrome collapses while geometry expands
→ terminal reaches the fitted 16:9 render frame
→ TEXT continues
```

No false no-video warning.

No black flash.

No decoder reopen.

No ribbon hole.

No title-bar pop.

No letterbox overshoot.

That was the first major milestone.

R3nder Pro could take a reusable structural video source, call it from the main program, give it a real presentation lifecycle, and return to the terminal cleanly inside the editor environment.

But one assumption was still hiding in plain sight: **EDIT preview and top-level PREVIEW were not the same runtime path.**

---

## 19. What the first round-trip changed about R3nder Pro

Before this milestone, R3nder had several powerful subsystems:

- a deterministic scene engine;
- audio authority;
- a script language;
- a video edit model;
- MLT decoding;
- structural composition;
- a GUI editor.

After this milestone, those systems could participate in one continuous program inside the editor.

The key model was now:

```text
EDIT
    reusable temporal source

MOSAIC
    reusable spatial source

STRUCT
    placement of a structural source into program time

TEXT
    top-level authored program and narration/music owner
```

That is a much stronger architecture than making every feature a special case inside one timeline.

It gave R3nder a vocabulary for building programs out of reusable visual structures.

---

## 20. M16.1: readiness became a visibility gate, never a clock

After the first round-trip, we hardened the rules that made the choreography deterministic.

An earlier implementation had allowed first-frame decode completion to influence opening geometry by remembering the frame on which readiness arrived.

That was rejected.

The invariant became:

> Readiness may suppress visibility. It may never alter authored geometry or authored time.

And, equivalently:

> If decode is late, preview can be late. Project time is not.

The structural window now evaluates its geometry from the authored current frame regardless of when decode finishes. Until a presentable frame is resident, the foreground stays hidden. Once ready, it reveals at the geometry belonging to the current authored project frame.

This removed a machine-speed dependency from the presentation model.

### Resolved empty is not pending

The same pass also clarified another important state boundary.

These are not the same:

```text
PENDING decode
resolved picture
resolved empty frame
offline/error
```

A resolved empty structural frame is finished evaluation even though it has no picture. A pending decode is not.

`EditVideoPreview` now reports first resolved state for stable picture, stable empty, and stable failure cases, while a genuinely pending decode continues waiting.

### Hard recursion depth

Nested EDIT/MOSAIC sources also received a runtime recursion ceiling independent of graph linting.

The default remains eight structural levels. The root is depth 1, depth 8 is allowed, depth 9 is a hard stop.

That means malformed or adversarial nesting cannot recurse forever even if it reaches the renderer through a path that did not run the normal linter first.

The full repository suite passed after this hardening and M16.1 was merged into `main` at commit:

```text
875678f  Merge post-M16 determinism and recursion hardening
```

---

## 21. M16.2 began with a correction: PREVIEW is not the editor preview pane

The next breakthrough started with a naming mistake.

We had been talking about “preview” as if there were one preview path. There are actually two user-facing modes:

```text
EDIT mode / Edit Window
    contains the script text editor
    also contains an editor-side preview pane

PREVIEW mode
    separate top-level program playback/viewer
    no script text editor
```

The first structural round-trip worked in the editor-side preview pane.

Top-level PREVIEW did not work at all.

Once the distinction was made explicit, the reason became obvious in the code.

Top-level PREVIEW was still simply:

```text
_setupScene()
→ compile script
→ SceneEngine
→ ScenePainter
```

There was no structural layer in that path.

The editor worked because its preview pane explicitly mounted `StructuralSequencePreview`.

This was not a small bug in STRUCT. Top-level PREVIEW had simply never been wired to structural video.

---

## 22. The runtime REGION bridge gave PREVIEW structural identity without a second clock

The fix had to preserve the strongest rule in the project: **SceneEngine remains the authority on main-sequence time.**

We did not want a second structural playhead living beside it.

The solution was an engine-internal runtime marker built on the terminal's existing REGION channel.

The author still writes only:

```text
[STRUCT:EDIT.foo]
```

For real PREVIEW and BAKE compilation, that placement projects internally into a reserved structural REGION plus the compensated PAUSE that already owns its timing.

Conceptually:

```text
[REGION:STRUCTSEQ_<placement>_<duration>][PAUSE:<compensated>]
```

The terminal exposes `currentRegion`, so top-level PREVIEW can ask:

```text
which STRUCT placement is active?
what is its authored duration?
how far through its PAUSE-owned event are we?
```

From that, it derives the exact structural local frame.

The new top-level bridge became:

```text
ProgramPreviewSurface
    paints normal ScenePainter program image
    reads SceneEngine.currentRegion
    resolves active STRUCT placement
    derives local structural frame from engine pause state
    overlays StructuralSequencePreview
```

No second main-sequence clock was introduced.

No user-visible parser syntax was added.

And `SPEED:MAX` received a regression so the internal marker and its PAUSE could not collapse into one engine tick.

---

## 23. Structural metadata had to consume zero terminal layout

Once top-level PREVIEW actually understood STRUCT, another old behavior suddenly became visible.

While PREVIEW crossed an EDIT/MOSAIC definition, the blinking cursor walked down the screen even though the structural metadata itself was not supposed to appear.

The source definitions had been projected out by replacing every non-newline character with nothing while preserving all of their newlines.

That made sense for the editor line map, which needs authored raw-line identity.

It was wrong for runtime PREVIEW and BAKE.

A hidden EDIT definition with ten lines was effectively becoming ten blank terminal lines.

The corrected rule became:

```text
runtime PREVIEW / BAKE
    structural definitions consume zero pixels
    structural definitions consume zero terminal rows
    structural definitions consume zero program ticks

editor simulation
    raw line coordinates are preserved long enough
    to inject [LINE:n] ownership markers
```

Runtime structural roots are now replaced by one internal parser-stripped comment token rather than a run of blank lines.

That fixed the walking cursor without sacrificing editor line ownership.

It also invalidated one older test that expected runtime line count to equal authored source line count. The final full-suite pass later caught that stale assertion, and the test was updated to verify the real two-part contract instead.

---

## 24. The cursor seam revealed that the terminal ghost itself was the wrong abstraction

Top-level PREVIEW was now “a lot better,” but the handoff still had a visible cursor problem.

The cursor became taller and changed aspect as the terminal moved toward the MOSAIC window.

The first diagnosis was straightforward: the simplified structural terminal ghost used a fixed cursor:

```text
7 × 14 pixels
```

The real terminal cursor is derived from the current font size and the resolved font baseline.

PREVIEW was changed to supply exact live terminal cursor proportions.

That fixed PREVIEW.

Then the same problem became obvious in EDIT.

A proportional fallback improved it, but the cursor still changed size when the handoff switched between the real terminal and the simplified ghost.

That was the clue that the cursor was not really the root problem.

The transition was still doing this:

```text
real themed terminal
→ reconstructed terminal ghost
→ structural window
→ reconstructed terminal ghost
→ real themed terminal
```

Even perfect cursor math could not make that truly seamless.

### The correct fix: stop impersonating the terminal

`ScenePainter` already had the real terminal window renderer.

So the structural handoff was changed to reuse the actual live terminal renderer rather than rebuilding its appearance in Flutter widgets.

Production EDIT and PREVIEW now supply the live `SceneEngine` and terminal font to the structural presentation layer.

During the transition, the terminal side is painted through the same ScenePainter/TerminalPainter path as normal program rendering.

That means structural handoff inherits the real:

- terminal background;
- phosphor/text color;
- font;
- cursor;
- configured window title;
- Yaru/theme chrome;
- wallpaper/chroma plate;
- border;
- corners;
- shadow.

This was the point where the terminal transition stopped approximating R3nder's visual language and actually became part of it.

The result was immediate: the remaining cursor jump disappeared, the active terminal theme carried through the transition, and EDIT and PREVIEW finally spoke the same visual language.

---

## 25. Native chrome exposed one more editor geometry mismatch

Reusing the real terminal renderer also revealed a subtle size mismatch in the structural foreground window.

The structural window had been using a fixed 38-pixel title bar in widget space.

ScenePainter's native chrome is specified in logical engine pixels and then scaled into the preview.

In a smaller editor pane, the real terminal title bar could therefore be much smaller than 38 widget pixels while the structural foreground window still used the full 38.

That created another handoff discontinuity.

The structural foreground chrome was changed to use the same engine-to-preview scale as the native terminal.

Now, at the handoff boundary:

```text
terminal chrome scale
=
structural window chrome scale
```

The visual system was finally continuous in both modes.

---

## 26. Whole-program BAKE: STRUCT had to enter the exporter without creating a second renderer model

Once PREVIEW was correct, the remaining major gap was whole-program export.

Structural sources could already be exported in isolation, but `SceneExporter` still rendered every program frame through the ordinary SceneCompositor/ScenePainter path.

It never asked whether the engine was currently inside a STRUCT runtime region.

The bake target became simple:

```text
PREVIEW frame N
≈
BAKE frame N
```

The implementation reused the pieces that already existed instead of inventing another timeline:

```text
SceneEngine evaluates project frame N
        ↓
current STRUCT runtime REGION
        ↓
placement index + exact local frame
        ↓
StructuralSourceFrameRenderer
        ↓
exact authored source frame
        ↓
structural desktop/window choreography
        ↓
real ScenePainter terminal/desktop underneath
        ↓
final RGBA frame to existing ffmpeg export pipe
```

The main application passes BAKE the raw authored document and the same workspace media resolver used by PREVIEW.

That matters because relative media paths must resolve against the active workspace, not against whatever directory happened to launch the application.

The exporter keeps its historical path outside STRUCT. The structural compositor is an override only while a valid structural runtime marker is active.

Decoder speed may make export take longer. It does not move project time or substitute a neighbouring media frame.

---

## 27. The bake test taught us where not to test pixels

The first whole-program bake test tried to prove the entire final `ui.Image` under `flutter_test`.

It hung.

An attempted `runAsync` wrapper still hung until the external timeout killed the test process, which produced misleading shutdown errors such as:

```text
Bad state: Cannot close sink while adding stream.
```

Those errors were not the product bug. They were fallout from terminating Flutter's test harness while an engine image callback was still outstanding.

The lesson was to test the deterministic contract at the correct layer.

The focused bake gate was rewritten to avoid `ui.Image` creation entirely. It now proves synchronously:

```text
compileScript
→ SceneEngine runtime REGION
→ correct placement
→ correct local structural frame
→ correct source frame
→ StructuralSourceFrameRenderer
→ decoder receives frame 0
→ next project frame receives frame 1
→ runtime REGION eventually ends
```

That test completed immediately:

```text
00:00 +1: All tests passed!
```

The real running application became the pixel-level integration test, which is where the final raster path actually matters.

---

## 28. The first real bake worked, and then exposed a normalized-coordinate aspect bug

The first real whole-program bake succeeded.

The video played smoothly.

But the structural player window in the baked file was much wider than the same window in EDIT and PREVIEW. It was wide enough that the 16:9 video acquired obvious pillar bars inside the player.

This looked like a video framing problem.

It was actually a coordinate-system bug.

### PREVIEW computed geometry in pixels

The preview target window uses the real render-frame dimensions:

```text
max width  = 86% of frame width
max height = 78% of frame height
```

It creates a 16:9 client in pixel space, adds the title bar, then applies the vertical cap if necessary.

### BAKE had copied the same-looking formula into normalized coordinates

After X and Y were independently normalized to 0..1, BAKE still did conceptually:

```text
clientHeight = clientWidth × 9 / 16
```

That is wrong in normalized space because one normalized X unit and one normalized Y unit do not represent the same number of pixels on a 16:9 frame.

For a nominal width of 0.86, BAKE calculated a normalized client height of about 0.484 and concluded it was comfortably below the vertical cap.

So the baked player remained about 86% of frame width.

PREVIEW's correct pixel-space calculation was constrained by height and produced a player around 74.5% of frame width.

That was exactly the visible mismatch.

### The fix

BAKE now computes the structural target rectangle in real output pixels first, using the same 16:9 client and title-bar constraints as PREVIEW, and only then normalizes the finished rectangle for ScenePainter.

A geometry regression locks the rule at both 1080p and 4K.

The next bake matched PREVIEW.

The pillar bars caused by the oversized client disappeared.

That was the final visual parity bug.

---

## 29. The real validation: a longer authored program

The short bake proved the mechanism.

The more important validation came next: a longer real script was run through the complete path.

It behaved correctly.

That matters because a longer program exercises far more than the isolated STRUCT event:

- earlier and later TEXT state;
- more engine timing;
- real terminal content;
- structural source lookup;
- desktop handoff;
- exact media frame progression;
- return to TEXT;
- exporter continuity across many ordinary frames around the structural event.

The result was described simply:

> “ran it through my longer script and it did perfectly”

At that point the feature had moved beyond a focused demo.

It was behaving as part of an authored R3nder program.

---

## 30. The final regression gate caught one stale assumption, then went fully green

The final full repository run initially produced one failure:

```text
Expected: 16
Actual:   6
```

The failing MOSAIC test still expected runtime compilation to preserve one output line for every structural metadata line.

That expectation described the old placeholder-newline behavior that had caused the top-level PREVIEW cursor to walk down the screen.

Production behavior was correct.

The stale test was updated to verify the real contract instead:

```text
runtime PREVIEW / BAKE
    structural metadata removed from terminal layout

editor simulation
    authored raw line ownership preserved through [LINE:n]
```

The full suite then completed:

```text
00:42 +163: All tests passed!
```

That became the merge gate.

---

## 31. The parity checkpoint

PR #3, **Complete STRUCT preview and bake parity**, merged the M16.2 branch into `main`.

The merge commit is:

```text
8f32e685356ee70e8a017aa8557c0d08c9d5bd88
```

The PR contained 39 commits across 20 changed files.

The validation recorded at merge time was:

```text
long real-world script preview: visually validated
long real-world script bake:    visually validated
whole-program STRUCT bake:      matches PREVIEW
full repository suite:          163 / 163 passed
```

This is the point worth preserving:

> R3nder Pro successfully round-trips structural video through the main TEXT program in both EDIT and top-level PREVIEW, and bakes that same authored structural presentation into the final program.

The earlier checkpoint was “STRUCT can round-trip.”

The new checkpoint is stronger:

```text
EDIT preview
    = same structural language

PREVIEW mode
    = same structural language

BAKE
    = same project-time structural language
```

The structural path is no longer an editor-only feature.

It is part of the program renderer.

---

## 32. What this means architecturally now

The current execution model is:

```text
TEXT
    top-level program order
    narration/music ownership
    SceneEngine project-time authority

STRUCT
    sequence placement
    presentation lifecycle
    runtime identity through engine REGION

EDIT
    reusable temporal source
    exact source/project frame mapping

MOSAIC
    reusable spatial source

MLT
    persistent leaf-media decoding

R3nder compositor
    structural recursion
    geometry
    source composition
    final pixels
```

The crucial part is that PREVIEW and BAKE do not each own a separate structural clock.

They observe the same SceneEngine-authored STRUCT runtime event and derive the same local structural frame from it.

The media backend can be slower or faster. The project frame does not move because of that.

That is the architecture we were trying to reach when ProjectClock work began.

---

## 33. What remains after preview/bake parity

The largest structural-video gap from the previous version of this document is now closed.

Whole-program export parity is no longer future work.

The fake-terminal fidelity issue is also no longer a production limitation. EDIT and PREVIEW now use the real live terminal renderer during structural handoff.

What remains is primarily authoring polish and diagnostics rather than a missing execution path.

### STRUCT node polish

STRUCT is a real NODES item, but its property UI can become more specific:

- structural-source selector;
- derived source duration;
- derived full presentation duration;
- missing-source warning;
- clearer visual distinction from source definitions.

### Missing-reference lint

An unresolved STRUCT reference currently falls back safely rather than crashing, but a specific lint finding should make the authoring error explicit.

### More complex real-world bake coverage

The long-script validation was a meaningful application test. Future milestones can extend that matrix across:

- several STRUCT events in one program;
- mixed EDIT and MOSAIC placements;
- nested structural sources near the recursion ceiling;
- 4K bake;
- more terminal themes and desktop configurations;
- explicit media-offline cases.

These are hardening and authoring improvements around a path that now exists end-to-end.

---

## 34. Engineering lessons from the journey

A few principles survived every stage of this work.

### Time must have one authority

Project time, audio time, source time, and presentation time can be different coordinate systems. They cannot be vague.

Most later bugs became tractable because the system had integer-frame ownership instead of accumulated timing guesses.

The PREVIEW/BAKE work reinforced this again: both consume the SceneEngine-owned runtime STRUCT marker rather than inventing their own sequence playheads.

### Definition and execution are different concepts

EDIT and MOSAIC definitions do not run merely because they exist.

STRUCT is the execution site.

That single distinction kept reusable source authoring separate from main-program order.

The metadata cursor bug sharpened this further: definitions also do not consume runtime terminal **layout** merely because they occupy authored source lines.

### A visual seam is often an ownership bug

The problems that looked like animation polish repeatedly turned out to be deeper:

- black flash: readiness ownership;
- decoder reopen: widget identity ownership;
- ribbon gap: runtime-frame ownership;
- audio duplication: mix ownership;
- title-bar pop: chrome ownership;
- editor letterbox snap: render-frame ownership;
- PREVIEW doing nothing: runtime-path ownership;
- walking cursor: metadata/layout ownership;
- cursor/theme jump: terminal-renderer ownership;
- wide baked player: coordinate-system ownership.

The final animation became smooth because those ownership boundaries became explicit, not because more easing curves were added.

### Readiness is not time

A decoder finishing on frame 10 instead of frame 3 cannot be allowed to re-author the transition.

Readiness can decide whether a foreground is visible.

It cannot decide where authored project time is.

This distinction is now one of the most important determinism rules in structural preview.

### Preview and bake should share contracts, not copied appearances

Several bugs came from code that looked mathematically equivalent but lived in a different coordinate system or renderer path.

The strongest fixes reused the real contract:

- real ScenePainter terminal rendering rather than a better fake terminal;
- SceneEngine runtime REGION rather than a parallel STRUCT timer;
- exact StructuralSourceFrameRenderer frames rather than media-playback time;
- pixel-space target geometry before bake normalization rather than copied normalized aspect math.

### Tests have to model the real lifecycle at the correct layer

Several tests initially gave misleading results because they jumped directly into a later frame, assumed `pumpAndSettle()` meant native image conversion had completed, or tried to force engine raster callbacks through `flutter_test`.

The useful split became:

```text
unit/focused tests
    deterministic ownership
    frame mapping
    geometry
    decoder requests

running application
    real raster integration
    visual continuity
    actual encoded output
```

The final bake test became better when it stopped trying to prove pixels in the wrong test environment.

### Persistent media means persistent widget identity too

A persistent decoder can still be accidentally destroyed by the UI tree.

Backend lifetime and Flutter element lifetime are part of the same playback system.

### The GUI is an architectural test

Backend tests can prove a model is internally consistent. They cannot prove the model feels like one tool.

M16 exposed issues that only existed when all layers were visible together. M16.2 did the same again when the editor path was compared with top-level PREVIEW and then with BAKE.

That was not a distraction from architecture. It was the next level of architecture testing.

---

## 35. The journey to this point

The project began this arc by asking a basic question: can R3nder have a trustworthy clock underneath a media system?

That question eventually became:

```text
Can a reusable authored video structure
live inside the same deterministic program
as the terminal itself?
```

The answer now is yes.

Not just in an isolated EDIT preview.

Not just in a structural-source exporter.

But through the whole program path:

```text
TEXT
→ terminal pulls back
→ real themed terminal becomes a desktop window
→ STRUCT window emerges
→ exact EDIT/MOSAIC frames play
→ STRUCT recedes
→ the same terminal returns
→ TEXT continues
→ the same event bakes into the encoded program
```

That path survived a longer real script and the entire 163-test repository suite.

This is the current checkpoint.

R3nder Pro is no longer only accumulating editing features.

It now has a coherent execution model that connects authored text, structural video, live preview, and final bake.