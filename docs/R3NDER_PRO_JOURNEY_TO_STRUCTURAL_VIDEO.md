# R3nder Pro: From ProjectClock to Structural Video Round-Trip

This document records the development path that led R3nder Pro from a terminal-driven renderer with a new timing foundation to a system that can author reusable video structures, place them into the main TEXT sequence, present them as desktop windows, play them, and return cleanly to the terminal.

It happened over several working sessions and many branches. The important part is not the number of commits. It is the sequence of architectural decisions that made the final round-trip possible.

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
TEXT → desktop → structural video → terminal
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

## 17. The last seam: fullscreen meant the wrong rectangle

One final mismatch remained.

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

That removed the last visible geometry mismatch.

---

## 18. The round-trip

At the end of this sequence, we successfully completed the first clean structural video call round-trip:

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

That is the milestone.

R3nder Pro can now take a reusable structural video source, call it from the main program, give it a real presentation lifecycle, and return to the terminal cleanly.

---

## 19. What this changed about R3nder Pro

Before this milestone, R3nder had several powerful subsystems:

- a deterministic scene engine;
- audio authority;
- a script language;
- a video edit model;
- MLT decoding;
- structural composition;
- a GUI editor.

After this milestone, those systems can participate in one continuous program.

The key model is now:

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

It gives R3nder a vocabulary for building programs out of reusable visual structures.

---

## 20. What is still not finished

This milestone is substantial, but it is not the end of the structural-video work.

### Whole-program export parity

The TEXT editor now has structural timing, GUI placement, and structural preview. Structural sources can be exported in isolation.

The remaining major step is to make whole-program bake/export evaluate the active STRUCT source through the same structural frame provider used by preview, so exported scene frames contain the same structural pixels and desktop choreography seen in the editor.

That should not become a second implementation of structural timing. Preview and bake need one evaluator contract.

### Terminal ghost fidelity

The structural handoff still uses a simplified terminal ghost rather than the exact live TerminalPainter content. Geometry and chrome behavior are now correct, but perfect visual parity would eventually mean sharing more of the real ScenePainter terminal presentation path.

### STRUCT node polish

STRUCT is a real NODES item, but its property UI can become more specific:

- structural-source selector;
- derived source duration;
- derived full presentation duration;
- missing-source warning;
- clearer visual distinction from source definitions.

### Missing-reference lint

An unresolved STRUCT reference currently falls back safely rather than crashing, but a specific lint finding should make the authoring error explicit.

---

## 21. Engineering lessons from the journey

A few principles survived every stage of this work.

### Time must have one authority

Project time, audio time, source time, and presentation time can be different coordinate systems. They cannot be vague.

Most later bugs became tractable because the system had integer-frame ownership instead of accumulated timing guesses.

### Definition and execution are different concepts

EDIT and MOSAIC definitions do not run merely because they exist.

STRUCT is the execution site.

That single distinction kept reusable source authoring separate from main-program order.

### A visual seam is often an ownership bug

The problems that looked like animation polish repeatedly turned out to be deeper:

- black flash: readiness ownership;
- decoder reopen: widget identity ownership;
- ribbon gap: runtime-frame ownership;
- audio duplication: mix ownership;
- title-bar pop: chrome ownership;
- letterbox snap: render-frame ownership.

The final animation became smooth because those ownership boundaries became explicit, not because more easing curves were added.

### Tests have to model the real lifecycle

Several tests initially gave misleading results because they jumped directly into a later frame or assumed `pumpAndSettle()` meant native image conversion had completed.

The most useful tests became the ones that followed the same lifecycle as the application:

```text
mount
→ preload
→ wait for real frame readiness
→ advance transition
→ assert decoder identity and geometry
```

### Persistent media means persistent widget identity too

A persistent decoder can still be accidentally destroyed by the UI tree.

Backend lifetime and Flutter element lifetime are part of the same playback system.

### The GUI is an architectural test

Backend tests can prove a model is internally consistent. They cannot prove the model feels like one tool.

M16 exposed issues that only existed when all layers were visible together. That was not a distraction from architecture. It was the next level of architecture testing.

---

## 22. The checkpoint

The M16 GUI integration branch grew to 69 commits beyond the previous main checkpoint before merge.

The final focused gate for the structural round-trip passed, and the completed path was verified visually in the running Linux application.

This is the point worth preserving:

> R3nder Pro successfully round-tripped a structural video call through the main TEXT program and back to the terminal.

The project is no longer only accumulating editing features.

It now has a coherent execution model that connects them.
