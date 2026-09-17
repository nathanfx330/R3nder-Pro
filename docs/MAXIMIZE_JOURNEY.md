# MAXIMIZE: From a Clip Cue to a Continuous Structural Shell Transition

This document records the journey from the first idea for a clip local MAXIMIZE cue to the final live verified implementation in both TEXT/STRUCT and standalone EDIT authoring.

The visible feature sounds almost trivial:

```text
while a video clip keeps playing
    trigger from a source relative frame
    expand the existing video window to fullscreen
    hold it there
    return the exact same window to its seat
    do not restart playback
    do not open a second decoder
    make Preview and BAKE agree
```

The implementation was not difficult because rectangle interpolation is difficult.

It was difficult because the rectangle belonged to a different architectural layer than the cue that triggered it.

MAXIMIZE became useful only after that ownership was made explicit.

The final feature rests on a few contracts:

> The script is the project.

> CUE owns the source relative trigger.

> MAXIMIZE owns only shell timing, not pixels.

> EDIT owns content. STRUCT owns desktop geometry.

> The existing decoder and playback clock must remain alive for the entire motion.

> Preview and BAKE consume the same deterministic shell state and geometry.

> Standalone EDIT may fake the structural shell for authoring, but the program path must continue to use the real STRUCT shell.

This is how those rules emerged.

---

# Where MAXIMIZE came from

CARD, SIDECARD, and DOSSIER had already forced R3nder Pro to answer a larger question:

```text
what does it mean for presentation to happen around continuously playing media?
```

CARD established source relative CUE timing.

SIDECARD established that a presentation should move the real structural video window instead of manufacturing another player.

DOSSIER established that the same structural shell could remain alive while the right hand presentation evolved through several stages.

MAXIMIZE was the next natural test of that architecture.

The desired behavior was:

```text
windowed STRUCT source
    ↓
CUE fires
    ↓
real window smoothly expands
    ↓
video occupies full program frame
    ↓
hold
    ↓
real window smoothly returns
    ↓
normal structural playback continues
```

Nothing about the media itself should restart.

The effect should be a change in the shell around the media, not a cut to a new media source.

---

# The syntax stayed intentionally small

The canonical authored form became:

```text
[CUE:420]
  [MAXIMIZE:180]
[/CUE]
```

The fields have deliberately narrow meaning.

`CUE:420` means:

```text
trigger when this CLIP reaches source frame 420
```

`MAXIMIZE:180` means:

```text
hold fullscreen for 180 project frames
```

The transition duration is not authored in v1.

The implementation uses:

```text
12 frames in
N authored hold frames
12 frames out
```

That gave MAXIMIZE one author facing number rather than turning it into a general transform animation language.

This was deliberate.

R3nder Pro did not need generic keyframes, arbitrary window tracks, or a miniature NLE effect system to express one structural action.

---

# MAXIMIZE is not a PresentationRequest

One of the first important architecture decisions was what MAXIMIZE was not.

CARD, SIDECARD, and DOSSIER are presentation content.

They own visible material:

```text
image
heading
body
metadata
evidence
panel color
```

MAXIMIZE owns none of that.

It paints no content at all.

Its only output is a shell amount:

```text
0.0 = ordinary structural window
1.0 = fullscreen program frame
```

That is why MAXIMIZE became its own cue type rather than another `PresentationRequest`.

The corresponding source model is:

```text
EditMaximizeCue
```

and the timing authority is:

```text
lib/maximize_presentation.dart
```

The file states the ownership rule directly:

```text
CUE owns the source-relative trigger
MAXIMIZE owns explicit-time shell amount
STRUCT owns the geometry that consumes it
```

That separation prevented a shell action from pretending to be content.

---

# The timing model is pure

`MaximizePresentationTiming` is deliberately small and deterministic.

It has no Flutter widget state, no decoder state, no playback listener, and no mutable animation controller.

For any local cue frame it returns the same answer regardless of evaluation order.

The stages are:

```text
entering
holding
returning
```

The fixed transition budget is:

```text
kMaximizeTransitionFrames = 12
```

For a hold of 60 frames:

```text
local 0..11    entering
local 12..71   holding
local 72..83   returning
```

The total lifetime is therefore:

```text
24 + holdFrames
```

This matters because Preview can evaluate frame 83 before frame 82, BAKE can request any exact frame directly, and neither path should depend on a previous animation state.

---

# Zero hold is a real case, not an error

A useful edge case appeared immediately.

What should this mean?

```text
[MAXIMIZE:0]
```

The tempting implementation would force a one frame fullscreen dwell so the state machine had a conventional hold phase.

That would invent authored time that the user did not request.

Instead, zero hold remains valid.

It means:

```text
12 frame push in
0 frame dwell
12 frame return
```

The first returning frame is exactly fullscreen.

The transition convention matches the CARD choreography rule:

```text
transition age divides by N, not N - 1
```

So entering reaches 11/12 on its final entering frame, and the next frame belongs to the next stage at exactly 1.0.

With zero hold, that exact 1.0 frame is the first returning frame.

The result is a clean 24 frame punch with no fabricated pause.

---

# Source time still owns the trigger

MAXIMIZE reused the most important lesson from CARD and SIDECARD.

The trigger belongs to clip source time.

It does not belong to an absolute project frame.

If a clip moves, trims, slips, changes speed, or splits, the cue must remain attached to the source moment it describes.

The mapping remains:

```text
clip source frame
    ↓
exact clip source/project mapping
    ↓
MAXIMIZE trigger project frame
    ↓
MAXIMIZE local lifetime
```

This means a cue such as:

```text
[CUE:330]
  [MAXIMIZE:60]
[/CUE]
```

is about source frame 330 of that CLIP.

It is not secretly about whatever project frame happened to contain source frame 330 when the cue was created.

That distinction keeps the cue coherent through later editing.

---

# Split ownership stayed source based

MAXIMIZE follows the same split rule as the other clip local cues.

When a CLIP is split, only the half that still contains the cue trigger source frame keeps the cue.

Conceptually:

```text
source range
    |
    | CUE at source F330
    |
   split
  /     \
left   right
          |
          + contains F330, so it owns MAXIMIZE
```

No duplicate cue is created and then reconciled later.

The operation is still source ownership, not project lane bookkeeping.

---

# STRUCT owns the geometry

The biggest architectural line is the same one learned during SIDECARD:

> Content belongs to EDIT. Desktop geometry belongs to STRUCT.

A MAXIMIZE cue may be authored inside a CLIP, but the CLIP does not own the outer application window.

The CLIP can say:

```text
at this source moment, request shell amount 0..1
```

It cannot decide:

```text
where the program desktop is
where the structural window is seated
what fullscreen means in this output
how terminal and desktop choreography are currently arranged
```

Those facts belong to STRUCT.

The source projection layer therefore produces a `StructuralMaximizePlacement`, and the structural shell geometry consumes its amount.

The pure source projection lives in:

```text
lib/maximize_shell_state.dart
```

The shell interpolation lives in:

```text
lib/structural_shell_geometry.dart
```

---

# Geometry composes after the base shell

MAXIMIZE did not become another parameter explosion inside the base structural shell evaluator.

The base shell is evaluated first.

Then MAXIMIZE is applied to the already evaluated structural rectangle.

Conceptually:

```text
STRUCT stage
    ↓
base shell rectangle
    ↓
other allowed shell displacement
    ↓
MAXIMIZE amount
    ↓
final structural rectangle
```

The shared geometry operation is essentially:

```text
Rect.lerp(baseRect, fullProgramRect, easedAmount)
```

with:

```text
Curves.easeInOutCubic
```

The same operation also derives window chrome visibility:

```text
windowChrome = 1 - easedAmount
```

So the title bar, border, and shadow disappear as the real structural window reaches fullscreen and return as it seats again.

The important part is not the curve itself.

It is that Preview and BAKE consume one shared geometry function rather than implementing similar looking animations independently.

---

# The same video player had to survive the move

The central runtime rule was continuity.

MAXIMIZE was never allowed to solve fullscreen by replacing the structural video widget.

That would have risked:

```text
new decoder
new seek
new readiness state
new audio path
new texture
one frame discontinuity
```

Instead, the same existing `EditVideoPreview` remains alive.

The outer structural window changes rectangle around it.

That means the feature is conceptually:

```text
same decoder
same source frame sequence
same audio transport
same playback clock
new shell rectangle
```

not:

```text
windowed player
CUT
fullscreen player
CUT
windowed player
```

This is the reason the motion feels continuous rather than like an effect pasted over playback.

---

# MAXIMIZE only activates during STRUCT showing

A subtle timing problem appeared around source frame zero.

A clip can contain:

```text
[CUE:0]
  [MAXIMIZE:...]
[/CUE]
```

But a STRUCT placement has its own entrance choreography before source presentation reaches its stable showing stage.

If MAXIMIZE were allowed to run during STRUCT opening, two independent shell motions would compete for the same outer rectangle.

The invariant became:

> MAXIMIZE is stage gated to `StructuralSequenceStage.showing`.

That means a source frame zero cue does not steal control from the structural opening animation.

The cue becomes eligible when the structural source is actually in its showing stage.

This was important enough to get an explicit regression test.

---

# The first test failure was actually a viewport assumption

The source-frame-zero regression produced one of the more useful debugging moments in the MAXIMIZE work.

The test expected a fullscreen rectangle with a top coordinate of 25.

The actual result was 75.

At first glance that looked like the new geometry was wrong.

It was not.

The test had assumed an 800 by 500 root.

Flutter's default test surface was 800 by 600.

The authored program frame was 16:9, so inside an 800 by 600 test surface the fitted frame was:

```text
800 × 450
```

which means vertical centering produces:

```text
(600 - 450) / 2 = 75
```

The production geometry was correct.

The test had hardcoded the wrong environment.

The correction was to compare MAXIMIZE fullscreen geometry against the actual fitted program frame rather than a guessed coordinate.

No production code changed for that fix.

The lesson was familiar but important:

> A visual geometry test should derive its expected coordinate space from the same explicit environment the widget is actually given.

---

# The first focused MAXIMIZE suite went green

After the viewport fixture correction, the focused runtime batch passed:

```text
26 / 26 tests passed
```

That batch covered the new MAXIMIZE path together with structural shell regressions.

The focused command was:

```bash
flutter test \
  test/maximize_presentation_test.dart \
  test/edit_maximize_cue_test.dart \
  test/edit_maximize_authoring_test.dart \
  test/structural_maximize_geometry_test.dart \
  test/structural_sequence_maximize_test.dart \
  test/timeline_maximize_landmark_test.dart \
  test/maximize_lint_test.dart \
  test/structural_shell_geometry_test.dart \
  test/structural_sequence_preview_test.dart
```

This proved the focused MAXIMIZE contract.

It did not mean the entire repository test suite was green.

R3nder Pro already had unrelated historical failures elsewhere, so the acceptance claim stayed intentionally narrow.

---

# SIDECARD and DOSSIER own the shell when they are active

MAXIMIZE introduced a potential conflict with existing presentation systems.

What should happen if a hand written script overlaps:

```text
SIDECARD
```

or:

```text
DOSSIER
```

with:

```text
MAXIMIZE
```

All three want to influence the structural shell.

The rule became:

> Content owns the shell.

When SIDECARD or DOSSIER is actively using the shell for its presentation, MAXIMIZE is suppressed.

This keeps one deterministic owner instead of attempting to combine incompatible outer window motions.

The runtime rule also makes hand written overlapping source survivable.

The linter can warn about invalid or undesirable overlap, but runtime behavior still remains deterministic.

---

# FULL STRUCT placement makes MAXIMIZE a geometric no-op

Another edge case came from already fullscreen placement.

If a STRUCT source is authored FULL, there is nowhere further to maximize.

The correct result is not to run a redundant animation that also fades chrome as a side effect.

So an already fullscreen structural placement treats MAXIMIZE as a harmless geometric no-op.

This matters because geometry and chrome are related in the MAXIMIZE helper.

The caller deliberately suppresses the transform for FULL placement so a cue cannot accidentally change presentation chrome when no geometric motion is needed.

---

# MOSAIC pane cues do not own the outer application window

MAXIMIZE v1 is intentionally limited to EDIT root shell ownership.

A MOSAIC pane owns pixels inside a larger composition.

It does not own the geometry of the one outer structural application window.

Therefore:

```text
MAXIMIZE inside direct EDIT source
    → may control outer STRUCT shell

MAXIMIZE inside MOSAIC pane
    → ignored for outer shell in v1
```

This avoided smuggling a future pane/window model into the first implementation.

If pane level maximize ever becomes a product feature, it should be designed explicitly rather than inferred from outer shell behavior.

---

# Source end truncation had to preserve the exact MAXIMIZE rectangle

SIDECARD had already exposed the one frame snap that can happen when a structural source ends during an active shell presentation.

MAXIMIZE inherited the same requirement.

Suppose the source ends halfway through the return animation.

The final source frame may still be partially enlarged.

STRUCT closing must begin from that exact rectangle.

The source-end projection therefore evaluates the final authored source frame:

```text
structuralMaximizePlacementAtSourceEnd(...)
```

and supplies the resulting rectangle as the structural close origin.

The contract remains:

```text
last visible source rectangle
    ↓
exact close origin
    ↓
STRUCT closing motion
```

not:

```text
last visible source rectangle
    ↓
snap to default seat
    ↓
STRUCT closing motion
```

MAXIMIZE did not need a new truncation philosophy.

It reused the correct one already learned from SIDECARD and DOSSIER.

---

# MAXIMIZE got its own ribbon vocabulary

The marker system had already separated authored MARK definitions from derived presentation landmarks.

MAXIMIZE created another useful distinction.

It is not a content presentation IN/OUT pair.

It is a shell action.

So the derived landmark vocabulary was extended with:

```text
shellIn
shellOut
```

rather than pretending MAXIMIZE was an ordinary presentation panel.

This preserved the marker architecture:

```text
authored MARK
    = durable user definition

derived CARD/DOSSIER landmarks
    = presentation diagnostics

derived MAXIMIZE landmarks
    = shell diagnostics
```

No authored marker schema changed.

The marker system stayed source derived.

---

# The first live TEXT/STRUCT check worked

Once the focused runtime suite was green, the next step was not more architecture.

It was motion.

A real clip was given a hand authored cue:

```text
[CUE:330]
  [MAXIMIZE:60]
[/CUE]
```

The expected behavior was:

```text
12 frame expansion
60 frame fullscreen hold
12 frame return
```

with the same decoder and audio continuing throughout.

The live program path did exactly that.

The first manual report was simply that it worked great.

That was the point where MAXIMIZE stopped being only a deterministic model and became a successful visible feature.

---

# Authoring still required hand editing

The runtime feature was working, but the user still had to type:

```text
[CUE:330]
  [MAXIMIZE:60]
[/CUE]
```

manually into the script.

That did not match the rest of the EDIT inspector workflow.

The next step was therefore source backed GUI authoring.

The inspector needed to support:

```text
add MAXIMIZE at playhead
edit hold length
delete MAXIMIZE
```

without creating hidden state.

The GUI was only allowed to mutate the canonical script.

---

# MAXIMIZE entered the clip inspector

The new inspector section was intentionally small.

It shows MAXIMIZE cues for the selected clip and allows the authored hold to be edited.

The add action uses the current playhead to derive the source relative CUE trigger.

The source mutation path remains in:

```text
lib/edit_cue_authoring.dart
```

and the inspector integration flows through:

```text
lib/edit_clip_inspector.dart
lib/edit_surface.dart
```

The important contract is the same one used by CARD and DOSSIER:

```text
GUI interaction
    ↓
source mutation
    ↓
canonical script text
```

The GUI is not a second cue database.

---

# Inspector tests went green

The focused MAXIMIZE authoring UI tests covered:

```text
add
edit
delete
zero hold
```

The batch passed:

```text
8 / 8 tests passed
```

At that point the feature could be authored without raw source editing while preserving the exact same script form used by the runtime.

A manual app check then confirmed that the new MAXIMIZE CUES section worked correctly in the actual clip inspector.

---

# Then live EDIT mode exposed a real mismatch

After the feature appeared complete, a live authoring observation found one more bug.

TEXT mode behaved correctly.

When the MAXIMIZE cue ended, the structural video window returned to its normal seat.

Standalone EDIT mode did not visibly unmaximize the window when the cue ended.

That difference was important because the two modes do not have the same environment.

TEXT/STRUCT already has a real program desktop and a real structural application window.

Standalone EDIT does not.

Before this fix, standalone EDIT normally showed the raw 16:9 client directly.

That meant there was no persistent visible windowed shell to return to after MAXIMIZE.

The cue could expand correctly, but once it ended the preview fell back to the ordinary raw client presentation.

Visually, that looked like the window stayed maximized.

---

# The EDIT fix followed the existing fake-shell rule

SIDECARD and DOSSIER had already established a useful asymmetry:

```text
TEXT / STRUCT
    use the real structural desktop shell

standalone EDIT
    may fake that shell for authoring
```

MAXIMIZE adopted the same rule.

If a direct EDIT contains MAXIMIZE cues, standalone authoring now keeps a stable fake desktop/window shell around the source.

The shell exists before the cue, during the cue, and after the cue.

So the visible authoring sequence becomes:

```text
seated fake EDIT window
    ↓
MAXIMIZE expands that window
    ↓
fullscreen hold
    ↓
MAXIMIZE returns that same window
    ↓
seated fake EDIT window remains
```

The program TEXT/STRUCT path was not changed by this correction.

Its real structural shell was already correct.

---

# Standalone MAXIMIZE needed client pixels

The EDIT authoring correction exposed another implementation detail.

Normal moving EDIT playback can use the external texture fast path.

But a fake authoring desktop needs to redraw the video pixels inside a moving window rectangle.

An external texture displayed directly by Flutter cannot simply be sampled by the Canvas painter as if it were an ordinary decoded `ui.Image`.

So when standalone EDIT needs the MAXIMIZE fake shell, the preview yields the texture shortcut and uses client pixels for that authoring path.

This follows the same logic already used by standalone DOSSIER composition.

The important invariant remains:

```text
one decoder
one transport
one source frame sequence
```

The authoring path changes how those pixels are composed, not who owns playback.

---

# The regression test found a test fixture problem before it found a product problem

A dedicated regression test was added for the live EDIT mismatch.

It checked three important points:

```text
before MAXIMIZE
at fullscreen
one frame after the cue lifetime
```

and required the standalone shell to remain present after the cue ended.

The first run failed with:

```text
Expected: 1
Actual:   3
```

The failure was on decoder open count.

That initially looked alarming because one of MAXIMIZE's strongest contracts is persistent decoder identity.

But the production code was not opening three decoders because of the cue.

The test rebuilt `EditVideoPreview` three times and created a brand new resolver lambda each time.

`EditVideoPreview` correctly treats a changed resolver function as a source environment change.

So it disposed and recreated the compositor for each artificially different resolver identity.

The test was asking for persistence while also telling the widget that its environment had changed.

The correction was to use one stable resolver function across all three test frames.

No production decoder behavior needed to change.

This was another reminder that identity-sensitive tests must keep their dependency identities stable when persistence is what they intend to measure.

---

# The final EDIT regression batch went green

After stabilizing the resolver fixture, the focused return batch passed:

```text
11 / 11 tests passed
```

That batch included:

```text
edit_maximize_preview_return_test.dart
edit_video_preview_test.dart
structural_sequence_maximize_test.dart
structural_maximize_geometry_test.dart
```

The new regression specifically proved that standalone EDIT could:

```text
start seated
expand
reach fullscreen
return
remain seated after cue lifetime
keep decoder reuse intact under stable dependencies
```

---

# The final live EDIT check passed

The last acceptance step was again visual.

After pulling the regression fix, the app was launched and the same MAXIMIZE cue was played through in EDIT mode.

The window now expanded, held fullscreen, and visibly returned to the fake seated authoring window.

The manual result was:

```text
yep it works!
```

That gave MAXIMIZE both automated and live acceptance across the two important preview contexts:

```text
TEXT / STRUCT program preview
standalone EDIT authoring preview
```

---

# Current architecture

The current MAXIMIZE path can be summarized as:

```text
CLIP source
  ↓
[CUE:sourceFrame]
  ↓
[MAXIMIZE:holdFrames]
  ↓
EditMaximizeCue
  ↓
source/project trigger projection
  ↓
MaximizePresentationTiming
  ↓
0..1 explicit shell amount
  ↓
StructuralMaximizePlacement
  ↓
STRUCT showing-stage gate
  ↓
shared structuralMaximizeGeometryFrameAt
  ↓
Preview or BAKE shell rectangle
  ↓
same live structural video client
```

Standalone EDIT adds one authoring-only projection around the same source:

```text
same EditVideoPreview source
  ↓
fake structural desktop/window shell
  ↓
same MAXIMIZE timing and geometry idea
  ↓
return to stable fake seat
```

The authoring fake is not the program shell.

It is a convenience projection so the user can see the structural result while editing the source definition directly.

---

# Current syntax contract

Canonical form:

```text
[CUE:<source-frame>]
  [MAXIMIZE:<fullscreen-hold-frames>]
[/CUE]
```

Example:

```text
[CUE:330]
  [MAXIMIZE:60]
[/CUE]
```

Meaning:

```text
trigger at clip source frame 330
expand over 12 frames
hold fullscreen for 60 frames
return over 12 frames
```

Zero hold is valid:

```text
[CUE:330]
  [MAXIMIZE:0]
[/CUE]
```

Meaning:

```text
12 frame push in
12 frame return
```

with no invented dwell.

---

# Current interaction rules

The v1 behavior is intentionally narrow.

```text
Direct EDIT root
    MAXIMIZE may own the outer shell while no content shell presentation owns it.

SIDECARD active
    MAXIMIZE suppressed.

DOSSIER active
    MAXIMIZE suppressed.

STRUCT FULL placement
    MAXIMIZE is a harmless geometric no-op.

MOSAIC pane cue
    does not control the outer structural application window in v1.

Source ends during MAXIMIZE
    STRUCT closes from the exact final MAXIMIZE rect.

Cue at source frame zero
    waits until STRUCT showing stage rather than fighting opening choreography.
```

These rules are part of the feature, not incidental implementation behavior.

---

# Current implementation map

The main MAXIMIZE files are:

```text
lib/edit_cue.dart
    EditMaximizeCue parsing/model

lib/edit_cue_authoring.dart
    add/update/delete and split ownership

lib/maximize_presentation.dart
    pure 12 + hold + 12 timing

lib/maximize_shell_state.dart
    source-frame projection into shell amount

lib/structural_shell_geometry.dart
    shared shell rectangle interpolation and chrome amount

lib/structural_sequence_preview.dart
    live TEXT/STRUCT program application

lib/program_structural_export.dart
    BAKE application

lib/edit_video_preview.dart
    standalone EDIT authoring shell participation

lib/card_overlay.dart
    shared fake standalone desktop/window shell helpers

lib/timeline_markers.dart
lib/timeline_landmark_layer.dart
    derived shell IN/OUT diagnostics

lib/edit_clip_inspector.dart
lib/edit_maximize_cue_controls.dart
lib/edit_surface.dart
    source-backed GUI authoring

lib/script_lint.dart
    grammar/lint participation
```

Important focused regression files include:

```text
test/maximize_presentation_test.dart
test/edit_maximize_cue_test.dart
test/edit_maximize_authoring_test.dart
test/structural_maximize_geometry_test.dart
test/structural_sequence_maximize_test.dart
test/timeline_maximize_landmark_test.dart
test/maximize_lint_test.dart
test/edit_maximize_cue_controls_test.dart
test/edit_maximize_preview_return_test.dart
```

The existing structural shell and preview tests are also part of the regression boundary because MAXIMIZE composes with, rather than replaces, that system.

---

# Verification history

The acceptance sequence mattered.

It was not one giant test pass.

The feature was verified in layers.

First, the focused runtime/geometry/parser/lint/ribbon batch reached:

```text
26 / 26 passed
```

Then the inspector authoring batch reached:

```text
8 / 8 passed
```

Then live TEXT/STRUCT playback confirmed the actual motion.

Then a real EDIT-only visual mismatch was discovered.

After the standalone shell correction, the focused return regression batch reached:

```text
11 / 11 passed
```

Finally, live EDIT playback confirmed the window actually returned after the cue.

That sequence is worth preserving because it demonstrates an important testing principle:

> Green model and widget tests are necessary, but shell choreography still needs to be watched in motion.

The live check did not replace the tests.

It found the missing boundary that the earlier tests had not represented.

The new regression then made that observation durable.

---

# Commit landmarks

A few commits are useful historical anchors for the journey.

```text
62c546611799ee2c6d38daa9a2b94dd5522a66eb
    rich CARD/PANEL work frozen before MAXIMIZE

9ec67256...
    initial pure maximize_presentation.dart work

8381ca51442bcbe409cd6c2a9ebb1e3333eaf430
    focused runtime MAXIMIZE suite corrected and green

91aeae79b0a250d861c0bb2de325bbc0135c2614
    MAXIMIZE clip inspector authoring integrated

8c38e4560bd07e76f926b5664ef28b8aeede12d2
    standalone EDIT return behavior regression path added

6cfedd109f9a3cd4f7d45580671cfcb680e07631
    stable-resolver regression test fix and final live-verified tip
```

At final acceptance, `main` pointed directly at:

```text
6cfedd109f9a3cd4f7d45580671cfcb680e07631
```

---

# What not to change casually

MAXIMIZE now looks simple because the ownership is settled.

That makes it easy to accidentally simplify the wrong thing later.

The following should be treated as frozen contracts unless there is a deliberate redesign.

Do not turn MAXIMIZE into a generic transform track merely because it moves a rectangle.

Do not move the trigger from source time to absolute project time.

Do not create a second fullscreen decoder or a second player widget.

Do not let standalone EDIT's fake shell become the authoritative program shell.

Do not duplicate Preview and BAKE geometry.

Do not let source frame zero fight STRUCT opening choreography.

Do not force a fake one frame dwell for `MAXIMIZE:0`.

Do not let FULL placement fade chrome for a motion it cannot geometrically perform.

Do not let a MOSAIC pane silently claim ownership of the outer application window.

Do not reset to the ordinary seated rect before STRUCT closing when the source ends mid-cue.

Do not treat a changed dependency identity in a persistence test as evidence of a production decoder restart.

---

# The larger lesson

MAXIMIZE is a small feature that demonstrates a larger R3nder Pro principle.

A presentation effect becomes much easier to reason about when each layer says only what it actually owns.

The CLIP knows the source moment.

The CUE knows when to trigger.

MAXIMIZE knows how much shell transition should exist at a local frame.

STRUCT knows where the application window belongs.

The media backend knows how to keep decoding the same source.

Preview and BAKE ask the same deterministic geometry question.

The inspector edits the script instead of inventing another data model.

Standalone EDIT fakes only the environment it does not own so authoring remains useful.

The final effect is visually simple because the architecture beneath it is explicit:

```text
source-owned trigger
+ pure explicit timing
+ structural geometry ownership
+ one decoder
+ one clock
+ shared Preview/BAKE evaluation
= continuous MAXIMIZE
```

That is the journey worth preserving.