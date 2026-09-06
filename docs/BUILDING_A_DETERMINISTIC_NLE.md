# Building a Deterministic NLE Inside a Motion Graphics Tool

## Lessons from R3nder Pro

This is the document we wish we had before turning R3nder from a deterministic motion-graphics renderer into a tool that could also edit video.

It is not a recipe for cloning R3nder Pro, and it is not an argument that every editor should be script-first. It is a record of the engineering lessons that survived contact with a real application: clocks, audio, decoders, GUI timelines, compositing, structural sources, preview, export, tests, performance, and the many places where a plausible design turned out to be the wrong one.

R3nder Pro is unusual in one important way: the script is the canonical project state. The GUI edits that same script rather than maintaining a second hidden project database. Your tool may choose a database, graph, scene file, or timeline document instead. The transferable lesson is not “use text.” It is this:

> Pick one canonical authored model and make every editor surface answer to it.

The rest of this guide follows from that decision.

For the development chronology, see [R3NDER_PRO_JOURNEY_TO_STRUCTURAL_VIDEO.md](R3NDER_PRO_JOURNEY_TO_STRUCTURAL_VIDEO.md). For the measured playback investigation, see [EDIT_PLAYBACK_PERFORMANCE.md](EDIT_PLAYBACK_PERFORMANCE.md). For sustained native A/V lock validation, see [M4_AV_LOCK_VALIDATION.md](M4_AV_LOCK_VALIDATION.md).

---

# The short version

If you are starting an NLE or motion-graphics editor today, the order we recommend is:

```text
1. Decide who owns project time.
2. Decide what data is canonical authored state.
3. Make frame N reproducible before adding media.
4. Model clip timing with the fewest independent fields possible.
5. Keep the media backend below your timeline model.
6. Make decode persistent before making the GUI elaborate.
7. Separate source definitions from placements in the main program.
8. Treat decode readiness as a visibility concern, never a timing input.
9. Make preview and export evaluate the same authored frame contract.
10. Measure UI, decode, audio, and parser costs as separate failure domains.
11. Test the user-visible semantic contract, not implementation trivia.
12. Stop adding editor features before the editor becomes a second product.
```

The biggest mistake we nearly made several times was trying to fix a symptom in the layer where it appeared. Video stutter looked like a decoder problem. A black flash looked like a media problem. A timeline gap looked like a parser problem. A crossfade looked like a compositing-only feature. More than once, the visible symptom belonged to a different layer than the actual defect.

The cure was to keep the responsibilities narrow enough that each failure domain could be measured independently.

---

# 1. Decide who owns project time before you decode a frame

The clock is not infrastructure you can safely postpone. It is the first creative-data decision in an editor.

R3nder Pro eventually settled on:

```text
ProjectClock
    ↓
ProjectTime
    ↓
scene at frame N
```

Flutter's `Ticker` is allowed to ask what time it is. It is not allowed to decide what time it is.

MLT is allowed to decode the source frame requested for project time N. It is not allowed to decide project time N.

Audio may temporarily become the realtime clock authority because the actual samples reaching the output device are the physical event the user is hearing. Even then, the audio sink reports time into the same ProjectClock instead of establishing a parallel timeline.

This distinction sounds academic until you scrub, seek, pause, change devices, preload a frame, or export faster than realtime. Then it becomes the difference between one project and several loosely synchronized simulations.

## A useful rule

Separate these concepts from the beginning:

```text
project time
presentation polling cadence
decoder source time
audio device time
export wall-clock duration
```

They are not interchangeable.

A 30 fps project displayed on a 60 Hz monitor should normally receive presentation polls around every 16.7 ms. That does not mean the project suddenly became 60 fps. Integer project-frame ownership still changes around every 33.3 ms.

Likewise, an export taking ten seconds or ten minutes to produce frame 300 must not change what frame 300 contains.

## The invariant

> Wall-clock delay may make the user wait. It may not change authored project time.

We would establish this before building trim handles, transitions, or playback controls.

---

# 2. If audio matters, validate the clock under load before building the editor

Audio synchronization is much easier to reason about before the GUI has enough moving parts to distract you.

R3nder's native validation path deliberately tested:

```text
PulseAudio device
    ↓ measured device latency
NativeAudioSink
    ↓ cumulative played samples
ProjectClock AUDIO mode
    ↓ exact rational ProjectTime
persistent MLT decoder
```

The point was not to prove that “video plays.” It was to prove that decoder load did not make the authoritative project clock drift.

The accepted validation run showed that the ProjectClock error remained essentially constant while persistent MLT decoding ran beside it. The video decoder could have a cold-start interval without changing clock ownership. That separated two failure domains early:

```text
native timing / audio authority

versus

GUI presentation / paint cadence
```

That distinction later saved us from blaming the decoder for a Flutter repaint problem.

## Device changes are not small events

A new audio device or stream can mean:

- a new output stream;
- new measured latency;
- a new anchor;
- stale callbacks from an old generation;
- shutdown and drain paths that can hang.

Treat a device change as a clock re-arm, not as a cosmetic preference change.

Generation counters are cheap protection against late callbacks from a stream the user has already abandoned.

---

# 3. Choose one canonical authored model

R3nder Pro is language-first:

```text
script
    = canonical authored project state

GUI
    = structured editor over the script
```

That choice forced us to build a lossless concrete syntax tree before a serious visual editing surface could be trusted.

The lesson is broader than text files.

If your tool uses a JSON project file, SQLite database, scene graph, or custom binary document, pick one thing that owns creative truth. Do not let the GUI quietly become another authoritative model because it is convenient to store one more property in widget state.

A useful test for every feature is:

> If I close this editor surface and reconstruct it only from canonical project state, do I get the same authored intent back?

If the answer is no, you have created hidden project state.

## Lossless editing matters when users can touch the source directly

Because R3nder users can edit the script by hand, parsing could not imply normalization.

The rule became:

> Untouched source remains untouched.

Opening a visual editor and changing one clip should not rewrite comments, spacing, unrelated tags, or syntax the GUI does not model.

If your users never touch the storage format, byte-for-byte preservation may not matter. But semantic preservation still does. A GUI should not mutate unrelated project state as collateral damage.

---

# 4. Model clip timing with the fewest independent truths possible

The core R3nder clip model became conceptually:

```text
source
project AT
source IN
project DURATION
exact SPEED
```

An OUT value is derived rather than stored as a second independent truth.

This matters because every redundant timing field creates another pair of values that can disagree after a split, trim, speed change, or conform operation.

For a clip at project offset `p`, source lookup is conceptually:

```text
sourceFrame = IN + floor(p × speed)
```

where speed is represented exactly as a rational relationship when necessary.

The important design principle is:

> Store authored facts. Derive consequences.

If `duration`, `out`, and `end` can all be calculated from one another, do not casually make all three editable canonical fields.

## Splits are a good model test

A split looks trivial in a GUI. In the project model it proves whether you actually understand clip timing.

A correct split must preserve:

- project continuity;
- source continuity;
- exact speed mapping;
- transition ownership;
- opaque child/source structure;
- the source text around the edited region.

If a split requires ad hoc repair afterward, the clip model is probably carrying duplicated truth.

---

# 5. Keep the media backend below your timeline model

We evaluated the media backend based on editor behavior, not on whether it could decode one frame.

The questions were:

- Can it survive repeated scrubbing?
- Can decoders stay open?
- Can we request exact source frames?
- Can it tolerate seek churn?
- Can it be reused by preview and export without becoming the project clock?

MLT won that role for R3nder.

The architectural boundary became:

> MLT decodes leaf media. R3nder owns project time, composition, source hierarchy, and final pixels.

That boundary is worth protecting even if your media backend is FFmpeg, GStreamer, AVFoundation, Media Foundation, or something custom.

A decoder is excellent at decoding. It does not automatically deserve ownership of your edit language.

## Persistent decode before elaborate GUI

Opening a decoder for every requested frame may be enough for a proof of concept. It is not a useful foundation for an editor.

Persistent decoder identity matters for:

- scrubbing;
- playback;
- transition evaluation;
- nested source evaluation;
- avoiding repeated cold starts;
- predictable latency.

Build that before spending weeks polishing the timeline.

---

# 6. Conform imported media once, then make project timing canonical

R3nder imports external video into the workspace and probes its native timing.

The source's frame rate is converted into an exact relationship between source frames and project frames. A 24 fps source in a 30 fps project therefore consumes source frames at an exact `24/30 = 4/5` relationship.

The important lesson is not the specific formula. It is the ownership transition:

```text
import/probe
    learns source timing

project clip
    owns authored project duration and exact mapping from then on
```

Do not keep asking the media file to redefine your authored edit every time it is opened.

Import is also a useful place to normalize paths and filenames into something your project format can represent safely. R3nder copies external video into `<workspace>/video/` and authors a workspace-relative path. That avoids a project becoming a collection of fragile absolute filesystem references.

---

# 7. Separate source definitions from source placements

This became one of the most important structural decisions in R3nder Pro.

An EDIT defines a reusable temporal source.

A MOSAIC defines another reusable source.

A STRUCT node places one of those sources into the main TEXT program.

```text
[EDIT:main] ... [/EDIT]
    defines EDIT.main

[MOSAIC:wall] ... [/MOSAIC]
    defines MOSAIC.wall

[STRUCT:MOSAIC.wall]
    executes MOSAIC.wall here
```

Definitions consume no main-sequence time merely by existing.

Placements consume program time.

This distinction is useful in any compositional editor. A reusable sequence, comp, scene, precomp, node graph, or nested timeline is not the same thing as an occurrence of that source in the master program.

## Do not duplicate duration at the placement

STRUCT does not own a second editable duration field.

The source definition owns its authored duration. The placement owns where it occurs and the presentation choreography around it.

That prevents this class of bug:

```text
source says 323 frames
placement says 300 frames
preview guesses one
export guesses another
```

If a placement needs trim or retime semantics, make those explicit authored operations. Do not accidentally create a second authoritative duration by convenience.

---

# 8. Source time and presentation time are different

A nested video source may contain N authored frames while the presentation needs additional time to enter and leave it.

R3nder's structural placement eventually had deterministic stages:

```text
zoom out
window opening
show source
window closing
zoom in
```

The source advances only during the showing stage.

The entry and exit choreography consume program time without consuming source time.

This sounds obvious after it is stated. Before it is stated, it is very easy to use one counter for both and create source-frame drift around transitions.

The general lesson:

> Nested content time and the choreography used to present that content are separate timelines with an explicit mapping between them.

---

# 9. Define the hierarchy by what each layer is allowed to own, not by what its widget looks like

An early simplification in R3nder was:

```text
EDIT = time
MOSAIC = space
```

That was useful for getting the first MOSAIC GUI out of the weeds. It was not the final model.

M17 exposed the missing idea: a MOSAIC pane may need its own local temporal arrangement, but the things it is allowed to arrange are **whole EDIT sequences**, not loose media cuts.

The more durable hierarchy became:

```text
EDIT
    owns media clips

MOSAIC
    owns whole EDIT sequences inside panes

TEXT
    owns program order and STRUCT placements
```

This matters because UI metaphors are not architecture.

A MOSAIC pane can have a mini timeline without becoming another EDIT.

A node graph can expose temporal controls without becoming the master timeline.

The question to ask is:

> What unit is this layer allowed to manipulate?

That is a much stronger boundary than “this screen is spatial” or “this screen is temporal.”

---

# 10. Readiness is a visibility gate, never a clock

One of the hardest seams in structural preview was a one-frame black flash before the first source picture appeared.

We learned that “ready” had several meanings that had been collapsed together.

These states are different:

```text
pending decode
resolved picture
resolved empty frame
offline/error
```

A decoder request having been issued is not the same as a presentable frame existing.

RGBA bytes existing in a worker is not necessarily the same as the UI having a resident image it can paint.

A resolved empty authored frame is not pending just because no picture exists.

## The invariant that survived

> Readiness may suppress visibility. It may never alter authored geometry or authored time.

If decode is late, preview may reveal late. Project time is not allowed to wait.

That keeps machine speed out of authored choreography.

## Wait for the actual presentation boundary

In Flutter, the useful readiness boundary for the structural foreground was not “decoder returned pixels.” It was “a presentable `ui.Image` is resident.”

The foreground remained hidden until that state was true.

Tests had to wait on the same semantic marker rather than assuming `pumpAndSettle()` knew that an engine-side asynchronous image decode was still in flight.

The general lesson is:

> Define readiness at the boundary the user can actually see.

---

# 11. Empty, black, and transparent are different creative states

This distinction produced both real regressions and stale tests during M17.

For an authored EDIT timeline, an empty interval is an intentional time span in the edit. R3nder ultimately treats that authored empty time as opaque black.

That is different from:

- transparent compositing background;
- pending media;
- offline media;
- no structural source at all.

If your compositor has only a single “no frame” value, these meanings will eventually collide.

A useful internal state table is:

| State | Evaluation complete? | Visible result | Should time advance? |
|---|---:|---|---:|
| Pending decode | No | Hold/suppress according to preview policy | Yes, project time remains authored |
| Picture | Yes | Picture | Yes |
| Authored empty | Yes | Black or authored empty treatment | Yes |
| Transparent composition | Yes | Transparent | Yes |
| Offline/error | Yes | Diagnostic/fallback | Yes |

The exact visual policy is yours. The semantic distinction should exist regardless.

---

# 12. Preview and export should answer the same frame question

R3nder Pro's strongest useful invariant became:

> Ask for project frame N, and preview and bake agree on what belongs at N.

That does not mean the two paths must have identical scheduling.

Realtime preview may be late.

Export may block until a decoder produces the requested source frame.

But both paths should evaluate the same authored frame mapping and the same composition semantics.

## Do not assume you have only one preview

We lost time because we used the word “preview” for two different user-facing paths:

```text
EDIT window
    script editor + editor-side preview pane

PREVIEW mode
    top-level presentation viewer
```

The first structural round-trip worked in the editor preview and completely failed in top-level PREVIEW because the latter had never been wired to structural sources.

Name distinct runtime paths explicitly in both code and conversation. Ambiguous vocabulary hides missing integration.

## Export is an architectural test

A feature that works only in the interactive editor is not finished if the product promises export parity.

Export forces you to answer:

- who advances project time;
- what blocks on decode;
- how nested sources resolve;
- how black/transparent/offline states serialize into pixels;
- whether source geometry is duplicated in another path;
- whether audio ownership is duplicated.

Treat bake/export integration as part of the feature, not cleanup after the GUI feels right.

---

# 13. Every fast path is a semantic obligation

Editors accumulate optimization paths quickly:

- direct texture presentation;
- single-layer bypass;
- cached decoded frame;
- compositor skip;
- zero-copy surface handoff.

Each one is a second implementation of some subset of your rendering semantics.

M17 found an important example: an outgoing-only XFADE could still qualify for a native texture fast path unless the guard explicitly rejected outgoing transitions as well as incoming ones.

The safe rule is:

```text
fast path allowed only when every semantic feature
that requires composition is proven absent
```

Conceptually:

```dart
if (hasIncomingTransition ||
    hasOutgoingTransition ||
    isNestedStructuralSource ||
    needsCompositing) {
  useCompositor();
}
```

When you add a new visual feature, search for all bypass paths before assuming the main compositor implementation is enough.

A regression test for the fast-path exclusion is often more valuable than another test of the compositor itself.

---

# 14. Widget identity can be media identity

One of the structural preview bugs reopened the decoder even though the media source had not changed.

The inner preview widget had a stable key. The top-level `Positioned` layer in the `Stack` did not.

When a sibling disappeared, Flutter could remount the structural subtree because its sibling position changed. That remount disposed and reopened the decoder.

The lesson is broader than Flutter:

> In a persistent-media UI, view lifecycle identity can become decoder lifecycle identity.

Stable media objects need stable UI ownership boundaries.

Key or otherwise identify the layer that actually participates in parent reconciliation, not only a nested child you hope will survive.

This kind of bug is difficult to see in model tests because the data is correct. The failure is lifecycle ownership.

---

# 15. Visual seams are architecture tests

A one-frame artifact can be more informative than a hundred model assertions.

During structural integration we chased:

- a false “NO VIDEO” flash;
- a black client flash;
- decoder remounts;
- cursor size jumps;
- title-bar pops;
- letterbox overshoot;
- a ribbon hole during engine-owned handoff frames.

None of these were merely cosmetic.

They exposed:

- dishonest initial state;
- the wrong readiness boundary;
- unstable widget identity;
- a simplified terminal ghost that did not match the real painter;
- different fullscreen geometry between preview paths;
- timeline ownership gaps in engine-generated transition time.

The practical advice is:

> When the seam looks wrong, resist fixing only the pixel. Ask which ownership boundary the pixel is revealing.

Real-machine visual inspection belongs beside tests for an editor. The human eye is extremely good at spotting continuity violations that are difficult to express in unit assertions.

---

# 16. Measure performance before changing architecture

The worst EDIT playback stutter looked like a decoder problem.

We tried several plausible changes that did not materially fix what the user saw:

- moving decode work off the Dart thread;
- replacing a timer with Flutter Ticker;
- removing per-frame `setState` calls;
- adding an external texture path;
- preserving exact ProjectClock phase for the playhead.

The turning point was measuring Flutter `FrameTiming`.

The UI thread was spending roughly 86 to 106 ms on ordinary frames while the raster thread was much cheaper. The moving playhead lived in the same large paint region as a full-width static timeline ruler and clip display. Every playhead move caused the static timeline to be recorded again.

Separating the static timeline and moving playhead with `RepaintBoundary` dropped ordinary UI work to roughly 0.2 to 1.7 ms and made playback smooth.

The decoder was not the dominant failure.

## Establish failure-domain instrumentation

For a realtime editor, measure at least:

```text
clock progression
decoder request/ready latency
UI build/layout/paint cost
raster cost
presentation cadence
audio device/sample progression
```

Do not infer one from another.

A choppy playhead does not prove the clock is choppy.

A slow UI build does not prove video decode is slow.

A fractional project phase does not prove the displayed integer source frame is late.

## Keep the trace after the bug is fixed

R3nder kept the playback trace opt-in rather than deleting it after the crisis.

That creates a baseline future changes can be measured against instead of relying on memory of what “smooth” felt like.

---

# 17. Optimize the visible viewport, not the authored universe

The playback fix isolated the ruler so it stopped repainting every frame. It did not make the ruler itself cheap.

The ruler still knows the full authored timeline width and can lay out labels far outside the visible viewport when a genuine invalidation occurs.

That is a classic editor trap.

Timeline content may be millions of pixels wide while the user can see only a small window.

Where possible, paint and shape only the visible frame range plus a small overscan margin.

The same principle applies to:

- waveform generation;
- thumbnails;
- keyframe markers;
- node graphs;
- clip decorators;
- captions;
- image contact sheets.

Virtualize the authored universe.

---

# 18. Measure parser/CST cost before “optimizing” it

A large lossless parser can look suspicious simply because it is central and touches the whole document.

R3nder added a dedicated CST parse measurement harness rather than optimizing from intuition.

The measured source-range scan remained roughly linear and comfortably fast on real and stress documents, so no optimization project was justified.

That is a useful negative result.

> A subsystem that looks architecturally expensive is not automatically your bottleneck.

Measurement can save as much time by telling you what **not** to rewrite as by locating a defect.

---

# 19. Test the input modality the application actually uses

MOSAIC timeline interaction tests taught us several separate lessons.

First, tests were initially hitting a wrapper rather than the visible gesture region.

Then touch-style dragging lost to a horizontal scroller even though the product is a desktop application.

Switching the tests to desktop mouse gestures better matched the real interaction.

Then the tests exposed a real product bug: Flutter drag slop meant the authored edit could receive only part of the user's intended distance.

The final interaction path used exact raw pointer deltas for move and trim operations.

The general advice:

> A GUI test should reproduce the input device and hit target the user actually uses.

Do not dismiss a failing interaction test as “Flutter test weirdness” until you know whether it has exposed a real gesture arbitration or slop problem.

---

# 20. Assert user-facing semantics separately from internal identity

One late M17 test expected the MOSAIC timeline card to display an internal clip id, `edit_main`.

The product correctly displayed the user-facing source name, `EDIT.main`.

Both identities were useful, but they belonged to different contracts:

```text
canonical document
    clip id = edit_main

visible GUI
    sequence label = EDIT.main
```

The corrected regression checks both in the appropriate place.

This is a small example of a common editor-testing mistake:

> Do not make the user interface prove an internal implementation detail when the internal model can be tested directly.

Stable user-facing names and stable internal ids are different promises.

---

# 21. Classify failing tests before fixing them

A full M17 suite run produced five failures.

They were not five product bugs.

They fell into three categories:

```text
stale expectation
    old export test still expected authored gaps to be transparent

stale workflow
    old MOSAIC tests still expected loose-cut assignment

real regression
    black-frame readiness now passed through asynchronous image conversion,
    delaying a readiness signal the structural opening relied on
```

This classification mattered.

If we had treated every red test as proof the new behavior was wrong, we would have regressed intentional product semantics to satisfy stale assertions.

If we had treated every red test as stale, we would have missed the real readiness regression.

A useful failure triage is:

1. What behavior does the current product intentionally promise?
2. Does the test assert that promise or an older one?
3. Is the failure in the product, the test harness, or the test expectation?

Make the test suite defend current semantics, not historical accidents.

---

# 22. Audio ownership must be explicit in nested editors

Once EDIT and MOSAIC became reusable structural sources, another ownership question appeared: should they automatically inherit the main workspace narration and music?

The final answer was no.

```text
EDIT / MOSAIC
    picture/source authoring
    silent by default

TEXT main sequence
    narration/music ownership
```

This prevents nested sources from duplicating or accidentally re-owning the program mix.

A specialist caller may opt into inherited workspace audio, but it is not the default semantic model.

The transferable lesson:

> Nested compositions need explicit audio ownership just as much as explicit time ownership.

Do not assume that because a child sequence can technically hear the master audio, it should own or export it.

---

# 23. Build diagnostic and fallback states deliberately

Media editors spend a surprising amount of time in states that are neither “working” nor “crashed.”

Examples:

- source missing;
- source exists but decoder not ready;
- authored timeline is intentionally empty;
- nested source resolves to nothing at this frame;
- source graph is recursive;
- device disappeared;
- export was cancelled;
- source frame could not be produced.

These states need stable semantics.

A useful rule is:

> Diagnostics may explain failure. They should not silently alter authored time.

R3nder preserves timing through many failure cases because changing duration in response to an asset failure would make every later event land on a different frame.

That is particularly important in motion-graphics work where downstream timing may already be cut to narration or music.

---

# 24. Recommended build order

If we were starting again, we would build in roughly this order.

## Stage 0: write the invariants

Before code, decide:

- Who owns project time?
- What is canonical authored state?
- Does decode readiness affect time? It should not.
- What owns duration?
- What must preview and export agree on?
- What is a source definition versus a placement?
- What owns audio?

Write the answers down.

## Stage 1: project clock and deterministic evaluator

Be able to ask for project frame N and reproduce it.

Do not start with realtime playback.

## Stage 2: audio authority and timing probe

If synced audio matters, prove the native clock while the system is still small.

## Stage 3: lossless/canonical project editing

Make the project format safely editable before building a GUI that mutates it.

## Stage 4: minimal clip language/model

Implement `AT`, `IN`, `DURATION`, exact speed, and source reference.

Test split and trim arithmetic heavily.

## Stage 5: media backend bakeoff

Choose the backend against editor workloads, not one-shot playback demos.

## Stage 6: persistent decode layer

Keep decoder identity stable through scrub and playback.

## Stage 7: first visible EDIT surface

Only now invest in drag, trim, split, V1/V2, preview, and import flows.

## Stage 8: composable/nested sources

Define how one authored sequence becomes a source for another layer.

## Stage 9: program placement and realtime preview integration

Integrate nested sources into the actual main program runtime, not only the editor preview.

## Stage 10: whole-program export parity

Make frame N agree in preview and bake before adding more editing features.

## Stage 11: transitions and richer manipulation

Now add XFADEs, overlays, multi-sequence pane editing, and similar features.

Each new feature must audit fast paths and nested/export behavior.

## Stage 12: performance measurement

Instrument before broad optimization. Establish a known-good baseline.

## Stage 13: error messages and documentation

This is not post-project cleanup. This is what turns the tool into something another person can operate.

---

# 25. What we would do earlier next time

Several things would move forward in the schedule if we started again.

## Instrument presentation performance before forming decoder theories

We spent too long on plausible stutter explanations before collecting `FrameTiming`.

The next editor gets a trace mode before it gets a complicated timeline.

## Name every preview/runtime path explicitly

“Preview” was too vague once the editor preview pane and top-level PREVIEW diverged.

The next project gets names for these paths before structural integration begins.

## Define pending / picture / empty / offline as first-class states

We arrived at these distinctions reactively while fixing visual seams.

They belong in the initial media-result model.

## Add export injection seams early

If export is supposed to share semantics with preview, make the exporter testable with a fake backend before the first complicated nested source exists.

## Design fast-path eligibility as a central semantic policy

Do not scatter “can bypass compositor?” decisions across unrelated widgets and decoders.

## Cull the timeline ruler to the visible range from the start

Repaint isolation fixed realtime playback, but a long authored timeline still should not shape labels the user cannot see.

## Write the user manual before declaring the feature set finished

A manual forces you to explain the product model without implementation vocabulary. If the workflow cannot be explained simply, the product boundary may still be wrong.

---

# 26. What we would not do earlier

Some work is tempting precisely because it feels productive.

We would **not** start with:

- elaborate transition libraries;
- dozens of tracks;
- magnetic timeline behavior;
- multicam;
- effects stacks;
- background render queues;
- a node graph for everything;
- proxy management;
- a full audio mixer;
- generalized NLE interchange.

Those may all be good features in another product.

They are terrible foundations.

The foundation is ownership: time, authored state, source hierarchy, decode, composition, and export parity.

---

# 27. Scope is an engineering feature

The hardest design decision was eventually to stop.

R3nder Pro needed enough direct manipulation that a user could make an edit naturally. It did not need to become Premiere, Resolve, or Kdenlive inside a terminal motion-graphics application.

The useful scope line became:

> Enough direct manipulation that someone else can start, nothing that requires a second mental model beside the canonical project.

That is why the final feature set includes real trim, split, V1/V2, overlays, edge crossfades, and MOSAIC sequence timelines, but does not attempt to reproduce every convention of a general-purpose NLE.

A specialized editor should be judged by how much friction it removes from its own domain, not by how many boxes it checks against the largest editor on the market.

Feature restraint protects architecture.

---

# 28. Documentation and error messages are part of the editor

A tool is not finished when the author can use it from memory.

It is finished when a stranger can:

```text
install
→ make a first edit
→ understand what went wrong
→ recover without reading the source code
```

The user manual therefore matters as much as another editing feature.

So do errors that speak in the user's model rather than the parser's model.

Bad:

```text
Structural CST ownership violation at opaque source range
```

Better:

```text
EDIT.main could not be placed here because it contains an invalid nested source.
Open EDIT.main and check its source references.
```

Internal vocabulary is useful in logs. User-facing errors should explain the failed action and the next useful step.

---

# 29. A checklist before adding a new editor feature

Before adding a feature, answer these questions.

## Authored state

- Where is the feature stored canonically?
- Can the GUI reconstruct it after reload?
- Does editing it rewrite unrelated project state?

## Time

- Can it move project frame boundaries?
- If yes, which authored field owns that duration change?
- Can decoder or async completion accidentally affect its timing?

## Source hierarchy

- Which layer is allowed to own this feature?
- Does it apply to media clips, EDIT sequences, MOSAIC sequences, or program placements?
- Can nesting change the answer?

## Decode/composition

- Does the feature require the compositor?
- Which fast paths must reject it?
- What happens if a source is pending, empty, or offline?

## Preview/export

- Is the same frame mapping used in both?
- Is there a fake backend or test seam for export?
- Have we tested the top-level viewer, not only the editor preview?

## Audio

- Does it alter audio ownership or duration?
- Does a nested source accidentally inherit the master mix?

## Performance

- Which failure domain should be measured if it becomes slow?
- Does it repaint or decode more than the visible viewport needs?

## Tests

- Are we asserting user-visible semantics separately from internal identity?
- Are interaction tests using the real desktop input modality?
- Could an older test be encoding a superseded workflow?

If these answers are vague, the feature is probably being added one layer too early.

---

# 30. The architecture that survived

R3nder Pro ended up with this broad ownership graph:

```text
canonical script
    ↓
lossless structural parse
    ↓
EDIT definitions
    own media clips and source timing
    ↓
MOSAIC definitions
    own whole EDIT sequences inside panes
    ↓
STRUCT placements
    place reusable sources in program time
    ↓
TEXT program
    owns top-level order and narration/music
    ↓
ProjectClock / ProjectTime
    authoritative project time
    ↓
preview evaluator / export evaluator
    ask for frame N
    ↓
MLT
    decodes leaf media only
```

Around that graph sit two important physical boundaries:

```text
native audio sink
    may provide realtime clock authority

Flutter presentation
    displays evaluated project state
    but does not own project time
```

That architecture was not obvious at the beginning. It emerged by repeatedly asking who was allowed to own each fact.

That is probably the single most transferable lesson from the entire project.

---

# Final advice

If you want to build your own NLE inside a motion-graphics tool, start smaller than your imagination wants to.

Build one clock.

Build one canonical project model.

Build one correct clip.

Keep the decoder underneath it.

Make frame N reproducible.

Make preview and export agree.

Then add the GUI.

When playback stutters, measure before changing the decoder.

When a one-frame seam appears, inspect ownership before hiding the pixel.

When a test fails after a deliberate semantic change, decide whether the product or the test is stale.

When a new feature seems cheap, ask whether it creates a second source of truth, a second clock, a second duration, or a second rendering path.

And when the tool can finally do the job it was built for, stop adding features long enough to document it.

That last part is not administrative work.

It is how the next person gets to start where you finished.
