# CARD, SIDECARD, DOSSIER: From Clip Cues to Continuous Structural Presentation

This document records the post M24 journey from the first clip local CARD cue to the current structural DOSSIER system.

The visible feature sounds simple when stated after the fact:

```text
while a video clip keeps playing
    trigger a presentation from a source relative frame
    move the real video window aside
    show a biography card
    evolve that right hand presentation into evidence
    keep the same decoder and the same clock alive
    make Preview and BAKE agree
```

Getting there required several ownership decisions that were more important than the visual effect itself.

The feature now rests on a few rules that should be treated as architectural contracts:

> The script is the project.

> CUE belongs to CLIP source time.

> EDIT owns content. STRUCT owns desktop geometry.

> Presentation must not create a second decoder or a second clock.

> Standalone EDIT may fake the desktop for authoring, but TEXT and STRUCT own the real program shell.

> Preview and BAKE must consume the same deterministic presentation state and geometry.

This is how those rules emerged.

---

# Where the journey started

After M22 through M24, EDIT had a coherent clip inspector, source backed mutation, undo and redo, gain and mute, transitions, slip, speed, and deletion.

The next question was different.

How should a presentation be attached to a moving piece of media?

A project frame was the obvious first thought.

It was also the wrong ownership model.

If a presentation were stored as a project time event, then moving the clip would separate the event from the content it was meant to describe. Trimming, slipping, speed changes, and splitting would all need special repair logic.

The presentation was not really about project frame 900.

It was about source frame 90 of a particular clip.

That distinction created CUE.

---

# CUE: the trigger belongs to source time

The core syntax became:

```text
[CUE:90]
  [CARD:person.png:120:24,32,40:JOHN SMITH]
    Biography text.
  [/CARD]
[/CUE]
```

CUE is deliberately smaller than the presentation inside it.

It owns only one thing:

```text
source frame at which the presentation begins
```

The contained CARD, SIDECARD, or DOSSIER owns its own appearance and deterministic lifetime.

That made the mapping clean:

```text
clip source frame
    ↓
exact clip source to project mapping
    ↓
CUE trigger project frame
    ↓
presentation local frame
```

Because the trigger is source relative, it follows the clip naturally through:

```text
move
trim
slip
exact rational speed
split
```

No second timeline and no hidden cue lane were needed.

This became one of the most important decisions in the whole feature.

---

# Why CUE stayed inside CLIP

CUE is not a global presentation track.

It is authored inside the CLIP body because the event belongs to the clip's source identity.

That also means split behavior can be decided from the same source coordinate.

When a clip is split, the cue belongs only to the half that still contains its trigger source frame.

The split operation does not duplicate the presentation and then try to repair it later.

Conceptually:

```text
original clip source range
      |
      | contains CUE source frame 90
      |
     split
    /     \
left     right
  |        |
  + only the half containing source frame 90 keeps the cue
```

This is source ownership rather than project position bookkeeping.

---

# CARD: the first presentation type

CARD was the first CUE driven presentation.

The work was intentionally split into pure timing, state projection, and painting.

The important timing authority became:

```text
lib/card_presentation.dart
```

The structural projection and painter were separated so presentation lifetime could be reasoned about without involving image loading or Canvas code.

That distinction mattered later when DOSSIER became much larger.

CARD also produced one useful accident.

The first implementation could appear fullscreen over the structural source rather than beside it.

Instead of deleting that behavior, it was retained as a valid presentation form.

That gave CUE two useful ideas rather than one:

```text
CARD
    presentation over source pixels

SIDECARD
    presentation beside a continuously playing structural window
```

The accidental fullscreen form became a feature because its ownership was still coherent.

---

# SIDECARD: the first architectural mistake

SIDECARD was supposed to mean:

```text
real structural video window on the left
card as a sibling window on the right
video continues playing
```

The first visual implementation looked close enough, but it was architecturally wrong.

The card was effectively being composed inside the client video surface.

That made it look like the video player itself contained a side panel.

The desired product model was different.

The desktop should contain two siblings:

```text
STRUCT desktop
├── real live video window
└── SIDECARD panel
```

not:

```text
STRUCT desktop
└── video client
    └── fake side panel
```

That correction was significant because it established the rule we still use for DOSSIER:

> Content belongs to EDIT. Desktop geometry belongs to STRUCT.

The video client should not know that its enclosing desktop window is being moved aside to make room for another presentation.

---

# The same decoder had to stay alive

The most important runtime requirement for SIDECARD was not the card itself.

It was continuity.

The structural source already had a real `EditVideoPreview` with an MLT backed decoder and program clock relationship.

The side presentation was not allowed to solve its layout problem by opening another video player.

That would have introduced:

```text
second decoder
second seek state
second readiness state
second opportunity for drift
```

Instead, the real structural window moves.

The same playback instance remains alive while its outer rect changes.

That distinction is why SIDECARD and DOSSIER feel like presentation rather than a cut to another compositor.

The rule became:

> Move the window, not the media session.

---

# Shared SIDECARD geometry

Once Preview and BAKE both needed the same side by side composition, geometry could not remain duplicated.

The shared authority became:

```text
lib/sidecard_geometry.dart
```

It owns the common desktop relationships used by SIDECARD and DOSSIER, including the seated video window and right hand presentation area.

The geometry was designed around a 1920 by 1080 logical stage but evaluates from the actual output size.

The approximate visual intent is:

```text
outer margin
video window on left
small gap
presentation panel on right
```

The live video preserves its 16:9 client relationship while fitting inside the structural desktop.

The important point is not the exact constants.

It is that Preview and BAKE do not separately invent the same rects.

---

# The one frame snap at source truncation

SIDECARD exposed a subtle failure at the boundary between presentation lifetime and source lifetime.

A presentation can still be active when the structural source itself ends.

If STRUCT begins its close from the ordinary seated rect instead of the exact final displaced rect, the last visible side presentation frame can be followed by a one frame snap before closing.

That looks small in code and obvious in motion.

The fix was to preserve the exact outgoing rect.

The shared closing origin logic ensures STRUCT closes from where the presentation actually left the live window.

The contract became:

```text
final source frame rect
    ↓
exact STRUCT close origin
    ↓
continuous close
```

not:

```text
final source frame rect
    ↓
snap to default STRUCT rect
    ↓
close
```

This lesson carried directly into DOSSIER.

---

# State and paint were separated before DOSSIER

CARD and SIDECARD gradually converged on a useful pattern:

```text
pure timing
    ↓
pure state / geometry projection
    ↓
asset loading
    ↓
painting
```

That was important because DOSSIER was going to combine several phases, a portrait, biography text, a folder of evidence images, GRID or MOSAIC behavior, and different holds.

Trying to bury all of that inside one painter would have made Preview and BAKE parity much harder to prove.

By the time DOSSIER started, we had already learned that visual code should consume timing rather than own it.

---

# DOSSIER: identity first, evidence second

DOSSIER extends the SIDECARD idea.

The live video remains the continuous structural source.

The right hand presentation evolves.

The authored syntax is:

```text
[CUE:90]
  [DOSSIER:evidence:person.png:90:120:45:MOSAIC:24,32,40:JOHN SMITH]
    Biography text.
  [/DOSSIER]
[/CUE]
```

The fields represent:

```text
folder
portrait image
split hold
evidence hold
card lead
evidence mode
panel RGB
heading
body
```

The author facing mode tokens remain:

```text
GRID
MOSAIC
SIDE_ONLY
```

The intended structural visual is now:

```text
CUE fires
    ↓
real video window moves left
    ↓
biography card appears on right
    ↓
optional biography lead
    ↓
biography gives way to evidence
    ↓
GRID or MOSAIC evidence remains on right
    ↓
presentation exits
    ↓
video window returns
```

The video itself never stops for the presentation.

---

# Pure DOSSIER timing came before painting

The first serious DOSSIER implementation step was not UI.

It was:

```text
lib/dossier_presentation.dart
```

That file extracts deterministic DOSSIER lifetime from the older SceneEngine behavior and exposes exact stage state for any local frame.

The historical stage sequence is still retained for SceneEngine parity:

```text
opening
cardLead
galleryOpening
splitShowing
centerTransition
centerShowing
centerPanning
closing
```

At this point those names matter historically more than visually.

The current structural product does not move evidence into a center stage.

The live video stays seated on the left while the presentation changes on the right.

That semantic drift was dealt with later in the journey, but preserving the old slots first gave us a stable timing baseline.

The timing model also preserves the existing boundary convention:

```text
final visible animation frame = (duration - 1) / duration
```

The next stage owns the next frame.

This avoids ambiguous double ownership at stage boundaries.

---

# DOSSIER lifetime depends on evidence assets

CARD lifetime can be known entirely from authored numeric fields.

MOSAIC DOSSIER cannot.

The number of evidence pages depends on how many supported images currently exist in the authored folder.

That is why CUE parsing does not pretend to know the final DOSSIER lifetime.

The flow is:

```text
parse CUE
    ↓
store authored DOSSIER facts
    ↓
resolve evidence folder
    ↓
calculate page count
    ↓
build exact DossierPresentationTiming
    ↓
evaluate local frame
```

The source trigger remains pure authored state.

Asset backed page count is resolved only by the layer that actually knows the folder contents.

---

# Evidence folder ordering stayed deterministic

DOSSIER evidence uses the same `.r3nder_order` convention already used by other folder backed presentation systems.

Supported evidence formats include:

```text
png
jpg
jpeg
webp
bmp
```

MOSAIC currently groups evidence into three images per page.

The key design point is that evidence ordering is not a transient file picker order.

It is derived deterministically from the workspace folder and ordering manifest.

---

# DOSSIER state projection

The timing model is projected into structural state by:

```text
lib/dossier_overlay_state.dart
```

That layer owns cue selection and timing projection, not image decoding and not painting.

It resolves one active DOSSIER at an exact structural source frame and retains the trigger owning pane rectangle for deterministic selection.

For MOSAIC sources, later authored active cues win, matching the deterministic CARD and SIDECARD ordering rule.

The same layer also provides the final source frame placement used when STRUCT truncates an active DOSSIER.

That prevents the source end snap problem from returning under a new feature name.

---

# DOSSIER painting became one shared authority

The asset and painter authority became:

```text
lib/dossier_overlay.dart
```

That file is intentionally used by:

```text
standalone EDIT authoring preview
TEXT / STRUCT program preview
BAKE
```

The environments are not identical, but the DOSSIER presentation painter is.

The outer real video shell remains owned elsewhere.

That is the important boundary.

The DOSSIER painter paints the right hand presentation.

STRUCT owns where the live video window is.

---

# Standalone EDIT needed a fake desktop, but only there

Direct EDIT authoring has no enclosing TEXT or STRUCT desktop.

Without help, a SIDECARD or DOSSIER would be hard to author because the user could not see the side by side result.

The solution was deliberately asymmetric.

Standalone EDIT is allowed to fake the environment for authoring.

It draws a convenience desktop shell and moving video window around the same decoded EDIT image, then calls the same SIDECARD or DOSSIER panel painter.

The real program path never uses that fake shell.

The rule is explicit:

```text
EDIT preview
    may simulate structural environment for authoring

TEXT / STRUCT preview
    owns the authoritative real structural shell

BAKE
    owns the authoritative final structural shell
```

This keeps authoring useful without creating a second structural ownership model.

---

# The external texture fast path had to yield during DOSSIER

Normal EDIT playback can use the native external texture path for efficient video display.

During active standalone DOSSIER authoring, the painter needs access to the decoded image pixels because it is composing that image into the fake moving desktop window.

So the external texture shortcut is temporarily disabled only while an active DOSSIER needs that client image.

Outside that presentation, the fast path resumes.

This is a local authoring requirement, not a second playback system.

There is still one decoder and one transport.

---

# Source backed DOSSIER authoring

DOSSIER became editable from the inspector rather than requiring raw script edits.

The relevant source mutation path lives in:

```text
lib/edit_cue_authoring.dart
```

It supports:

```text
add DOSSIER cue
update DOSSIER cue
delete DOSSIER cue
split ownership
validation
serialization
```

The serialized result goes back into the CLIP source.

No hidden project database was introduced.

The GUI can hold transient dialog state while the user edits a cue, but durable state still resolves to authored source.

That preserves the same contract established by the M22 through M24 inspector work.

---

# The dedicated DOSSIER inspector

DOSSIER got its own authoring control surface rather than being forced through the simpler CARD selector.

The inspector exposes:

```text
evidence folder
portrait image
split hold
evidence hold
card lead
GRID / MOSAIC / SIDE ONLY
panel RGB
heading
biography body
```

It also shows source and project frame information so the author can see where the cue belongs in both coordinate systems.

The controls remain source backed and use the existing EDIT history seam, so DOSSIER changes participate in undo and redo with the rest of the clip edits.

---

# The first DOSSIER visual pass

Once the runtime path was stable, the right hand evidence panel received a more deliberate visual hierarchy.

The shared painter added:

```text
DOSSIER / EVIDENCE label
subject heading
accent strip derived from authored color
image mattes and borders
numbered evidence badges
folder identity
file count
GRID / SIDE ONLY status
MOSAIC page status
empty evidence state
```

This was important for a simple reason.

Architecture can prove that a frame is deterministic and still produce a presentation that feels unfinished.

The feature needed to be looked at in motion.

That visual pass was kept inside the shared painter so EDIT, STRUCT preview, and BAKE could not drift into three different DOSSIER designs.

---

# The first time we could finally run it

After the initial authoring, runtime, and visual integration, the focused regression batch reached:

```text
22 / 22 tests passed
```

At that point the feature stopped being an architecture exercise.

It could be launched, authored from the inspector, scrubbed, and played as a real DOSSIER.

That manual run was the first meaningful product acceptance gate.

The important observation was not a test count.

It was that the same structural video kept playing while the presentation happened around it.

The system finally behaved like the idea that started the work.

---

# The architecture review after it actually worked

Once DOSSIER existed in motion, a fresh architecture review found that the biggest remaining duplicated authority was not inside DOSSIER.

It was the outer STRUCT shell.

Preview and BAKE still contained parallel implementations of the same structural window choreography.

They each knew about:

```text
opening rect lerp
seamless handoff rect lerp
terminal opacity
structural opacity
closing fade
visibility ramp
```

They were intentionally different in one place:

```text
live Preview may wait for first frame readiness
BAKE never waits because its frame is resolved synchronously
```

That is exactly the kind of duplication that becomes dangerous.

Two copies are supposed to differ in one place, which makes a second accidental difference hard to notice.

The duplicated `2.2` visibility multiplier made the risk obvious.

A constant written twice is a constant that will eventually be tuned once.

---

# One outer STRUCT shell authority

The fix became:

```text
lib/structural_shell_geometry.dart
```

That file now owns the pure outer shell evaluation used by both Preview and BAKE.

Its inputs include:

```text
stage
linear progress
full terminal rect
parked terminal rect
presentation rect
previous presentation rect
closing origin rect
seamless / chained flags
contentReady
```

Its output is one `StructuralShellFrame` containing:

```text
terminal rect
structural rect
desktop opacity
terminal opacity
terminal chrome amount
structural opacity
whether structural window is present
```

The old duplicated magic value became:

```text
kStructuralShellVisibilityRamp = 2.2
```

Now visual tuning cannot change only Preview or only BAKE.

The one legitimate difference is explicit:

```text
Preview
    contentReady = first frame readiness

BAKE
    contentReady = true
```

This is a much safer architecture than two almost identical switch statements.

The focused suite after that cleanup reached:

```text
26 / 26 tests passed
```

---

# A second hidden duplicate presentation was prevented

During the shell cleanup another latent risk was closed.

The real STRUCT window already suppressed standalone client SIDECARD rendering.

DOSSIER needed the same explicit guard.

Without it, the inner EDIT client could potentially self stage a DOSSIER while the outer STRUCT shell was also staging the real DOSSIER sibling.

The structural path now explicitly disables client side DOSSIER staging.

That reinforces the ownership boundary:

```text
standalone EDIT
    may self stage for authoring

real STRUCT client
    must not self stage
```

---

# The `centerMode` semantic drift

The architecture review also caught an older naming problem.

The terminal DOSSIER model originally described a gallery moving into a center stage.

That history survived in names such as:

```text
centerMode
centerPageCount
centerTransition
centerShowing
centerPanning
```

But the structural product had deliberately evolved away from that choreography.

The current design keeps the live video window on the left.

Evidence remains on the right.

The old names had become misleading even though the timing was still useful.

This was not merely cosmetic.

A future engineer could read `centerMode` and correctly infer the old product behavior from the name, then accidentally reintroduce it.

---

# Preserve scripts and timing, fix the meaning

The important constraint was that the feature already looked good in motion.

We did not want an internal vocabulary cleanup to silently change authored DOSSIER lifetime.

So the semantic repair was intentionally conservative.

The author facing script stays exactly the same:

```text
GRID
MOSAIC
SIDE_ONLY
```

The historical timing enum also remains for SceneEngine parity.

But current structural code now has product facing evidence vocabulary:

```text
DossierEvidenceStage.opening
DossierEvidenceStage.cardLead
DossierEvidenceStage.evidencePrepare
DossierEvidenceStage.splitShowing
DossierEvidenceStage.evidenceTransition
DossierEvidenceStage.evidenceShowing
DossierEvidenceStage.evidencePanning
DossierEvidenceStage.closing
```

The timing model accepts the modern names:

```text
evidenceMode
evidencePageCount
resolvedEvidencePageCount
hasEvidenceSequence
evidenceShowingFrames
```

and retains the old names as compatibility aliases.

That lets new code describe the current product honestly without breaking older callers, parity tests, or authored scripts.

---

# The strange `galleryOpening` frames finally got a truthful name

One historical stage deserved special attention.

When `cardLead > 0`, the old terminal model allocates one ordinary window animation after the card lead.

Historically that was the gallery opening.

In structural DOSSIER, no separate gallery window now enters during those frames.

The biography remains seated.

Those frames had become visually inert but still existed in the lifetime.

Removing them would have changed timing for already authored DOSSIERs.

So current semantics call that slot:

```text
evidencePrepare
```

It is an intentional pacing runway.

The biography remains fully visible while the presentation prepares to yield to evidence.

Then the historical `centerTransition` slot becomes the actual product facing:

```text
biography → evidence transition
```

This preserves the motion that had already been manually accepted while eliminating the false implication that evidence is moving to a vanished center stage.

---

# Frame for frame compatibility is tested

The semantic rename is not based on trust.

`test/dossier_evidence_semantics_test.dart` constructs both the modern and historical spelling of the same timing model and compares them frame for frame.

It proves that the cleanup preserves:

```text
total duration
historical stage slot
current evidence stage meaning
stage age
progress
page identity
```

It also explicitly locks the two most important semantic facts:

```text
galleryOpening slot
    = evidencePrepare
    = biography still seated

centerTransition slot
    = evidenceTransition
    = biography crossfades into evidence
```

After that cleanup, the focused regression suite reached:

```text
31 / 31 tests passed
```

The next manual run also felt better simply playing through the sequence.

That matters.

The code now describes what the eye is actually seeing.

---

# The current ownership model

The feature can now be summarized as one ownership chain.

```text
CLIP source
  owns CUE trigger in source frames
        ↓
edit_cue.dart
  maps source trigger into exact project time
        ↓
CARD / SIDECARD / DOSSIER timing
  owns deterministic presentation lifetime
        ↓
CARD or DOSSIER state projection
  chooses exact visible presentation state
        ↓
STRUCT
  owns real desktop and video window geometry
        ↓
shared painter
  paints the right hand presentation
        ↓
Preview / BAKE
  consume the same authored time and geometry
```

The media path remains separate:

```text
ProjectClock
    ↓
active EDIT clip
    ↓
exact source frame
    ↓
persistent MLT decoder
    ↓
one continuously playing video client
```

The presentation does not replace that chain.

It moves around it.

---

# Current syntax examples

## CARD

```text
[CUE:90]
  [CARD:person.png:90:24,32,40:JOHN SMITH]
    Biography text.
  [/CARD]
[/CUE]
```

CARD is the fullscreen or source pixel presentation path.

## SIDECARD

```text
[CUE:90]
  [SIDECARD:person.png:90:24,32,40:JOHN SMITH]
    Biography text.
  [/SIDECARD]
[/CUE]
```

SIDECARD keeps the structural source playing in the real left desktop window while the card sits beside it.

SIDECARD is deliberately CUE local and is not registered as a general terminal presentation tag.

## DOSSIER

```text
[CUE:90]
  [DOSSIER:evidence:person.png:90:120:45:MOSAIC:24,32,40:JOHN SMITH]
    Biography text.
  [/DOSSIER]
[/CUE]
```

DOSSIER keeps the same live left video window and evolves the right hand presentation from biography into evidence.

---

# Important files

## Trigger and authored source ownership

```text
lib/edit_cue.dart
lib/edit_cue_authoring.dart
lib/edit_card_cue_controls.dart
lib/edit_dossier_cue_controls.dart
lib/edit_clip_inspector.dart
lib/edit_surface.dart
```

## CARD and SIDECARD timing / state / geometry

```text
lib/card_presentation.dart
lib/card_overlay_state.dart
lib/card_overlay.dart
lib/sidecard_geometry.dart
```

## DOSSIER timing / state / paint

```text
lib/dossier_presentation.dart
lib/dossier_overlay_state.dart
lib/dossier_overlay.dart
```

## Outer structural shell

```text
lib/structural_shell_geometry.dart
lib/structural_sequence_preview.dart
lib/program_structural_export.dart
```

## EDIT runtime client

```text
lib/edit_video_preview.dart
```

---

# Proof surface

The feature is protected by layered tests rather than one screenshot test.

Important coverage includes:

```text
test/edit_dossier_cue_test.dart
test/edit_dossier_authoring_test.dart
test/edit_dossier_cue_controls_test.dart
test/edit_dossier_cue_inspector_integration_test.dart
test/dossier_presentation_timing_test.dart
test/dossier_overlay_test.dart
test/edit_dossier_preview_test.dart
test/structural_sequence_dossier_shell_test.dart
test/program_structural_dossier_export_test.dart
test/structural_shell_geometry_test.dart
test/dossier_evidence_semantics_test.dart
```

Earlier CARD and SIDECARD coverage remains important because DOSSIER builds on those boundaries rather than replacing them.

The progression of accepted focused suites during the final integration was:

```text
22 / 22
    first integrated DOSSIER runtime and visual path

26 / 26
    shared outer STRUCT shell geometry

31 / 31
    evidence semantic cleanup with timing compatibility
```

These are focused regression results, not a claim that every repository test was run at each step.

---

# What should now be treated as settled

Several parts of this architecture survived the addition of a more complex presentation type and should not be reopened casually.

## CUE source ownership

CUE belongs to CLIP source time.

Do not turn it into a generic project track unless the product deliberately introduces a different class of event.

## EDIT / STRUCT boundary

EDIT owns content and media meaning.

STRUCT owns desktop placement and real program window geometry.

Do not move SIDECARD or DOSSIER desktop choreography into the video client.

## One decoder rule

The presentation moves the existing structural window.

Do not create a second decoder to make presentation layout easier.

## Shared shell geometry

Preview and BAKE now consume `structural_shell_geometry.dart`.

Do not copy its switch back into either caller.

## Source truncation continuity

Closing must begin from the exact final displaced rect.

Do not normalize to a default window rect before close.

## Modern DOSSIER evidence vocabulary

New structural code should reason in terms of evidence rather than center stage.

Historical center names exist for compatibility, not as a product direction.

---

# What the journey taught us

## 1. Attach presentation to the thing it describes

A cue tied to project time becomes maintenance work when the clip moves.

A cue tied to source time naturally follows the content.

## 2. A visual approximation can hide the wrong ownership

The first SIDECARD looked close while being nested in the wrong layer.

The correct test was not “does a card appear beside the video?”

It was “is the real structural video window being moved by STRUCT?”

## 3. Continuous playback is an architectural property

It is easy to fake continuity with another decoder.

The actual product requirement was stronger:

```text
same decoder
same clock
same transport
new outer geometry
```

## 4. Pure timing should exist before a complex painter

DOSSIER became manageable because lifetime and stage identity could be tested without loading one image.

## 5. Preview and BAKE parity requires shared authority, not similar code

Two nearly identical switch statements are not parity.

One evaluator with explicit environment inputs is parity.

## 6. Source end is part of presentation choreography

A clean animation can still snap if the enclosing source ends first.

The final displaced geometry is state and must be preserved into close.

## 7. Compatibility does not require preserving misleading names forever

The old center stage timing could remain stable while new code gained evidence terminology.

Compatibility aliases are better than forcing the current product to speak an obsolete visual model.

## 8. Tests prove contracts, but motion accepts presentation

The 22, 26, and 31 test passes were necessary.

They were not the moment the feature became good.

That moment came when it was run as a real DOSSIER and the motion felt coherent.

Visual presentation needs both forms of evidence.

---

# The larger arc

From M22 onward, the EDIT surface had already established that durable creative state must serialize back into the script.

CARD, SIDECARD, and DOSSIER extend that principle into presentation without abandoning it.

The arc looks like this:

```text
M22 to M24
clip editing becomes inspector driven but remains source backed

CUE
presentation trigger becomes source relative CLIP state

CARD
first deterministic clip local presentation

SIDECARD
presentation becomes a real STRUCT sibling beside one continuously playing video window

DOSSIER
right hand presentation evolves from identity into evidence without stopping the source

shared shell cleanup
Preview and BAKE stop duplicating outer STRUCT choreography

evidence semantic cleanup
current code stops implying a center stage that no longer exists
```

The result is not a generic NLE overlay track.

It is a presentation system shaped around R3nder Pro's existing ownership model.

That is why it now feels integrated rather than bolted on.

---

# Accepted baseline

As of the current accepted `main` baseline after the evidence semantic cleanup:

```text
CARD works as a clip local presentation
SIDECARD works as a true structural sibling
DOSSIER can be authored from the EDIT inspector
standalone EDIT can preview DOSSIER in a simulated desktop
TEXT / STRUCT owns the authoritative live shell
BAKE uses the same timing and geometry authorities
source truncation preserves closing continuity
Preview readiness is explicit rather than another timing model
GRID / MOSAIC / SIDE_ONLY remain stable authored tokens
evidence terminology describes the current product without changing old timing
```

The focused regression suite for the final semantic cleanup passed:

```text
31 / 31
```

The feature was then manually run again in the Linux app and accepted in motion.

The next useful work should come from repeated real use and visible friction, not from reopening the foundation simply because the foundation is finally quiet.


---

# EDITORIAL — refining the CARD face without reopening SIDECARD

The next SIDECARD problem was not structural.

The shell already behaved correctly:

```text
real structural video window on the left
CARD-family face on the right
one decoder
one clock
shared Preview / BAKE geometry
```

What felt wrong was the card face itself.

The old SIMPLE face had a strong hero image, but the text below it still read like a generated information panel:

```text
bold heading
accent rule
bold body copy
fixed type sizes
```

The EDIT inspector exposed the underlying fields, but it still felt like editing a data structure rather than designing the thing on screen.

That led to a deliberately narrow redesign.

## The rule disappeared because its job moved

The first instinct was simply that the divider line looked dated.

That was not a strong enough reason to remove it.

The richer CARD presets revealed the actual relationship. Their accent treatment exists because the kicker is painted over the photograph. The line and scrim give that over-image label a visual baseline.

EDITORIAL makes a different choice:

```text
hero image
    ↓
kicker
    ↓
heading
    ↓
body
```

The kicker moves below the photograph into the content hierarchy.

Once that happened, the divider no longer had a structural job.

So EDITORIAL removes the rule as a consequence of relocating the kicker, not as arbitrary decoration cleanup.

The older photo-treatment path remains intact for presets that still use it. EDITORIAL not needing the scrim is not evidence that the scrim should be deleted.

## One full face painter became the seam

The inspector preview could not be allowed to re-create the card with ordinary Flutter widgets.

That would have made the preview a second renderer and guaranteed drift.

The complete face was therefore extracted into one public painter:

```dart
paintPresentationCardFace(
  canvas: ...,
  cardRect: ...,
  referenceScale: ...,
  card: ...,
  image: ...,
  inheritedFontFamily: ...,
)
```

The caller still owns placement and motion.

The face painter owns:

```text
shadow
panel surface
hero image
photo treatment
simple / rich / editorial content branch
typography
```

The EDIT preview calls the same painter.

## The extraction is proved with pixels

A refactor described as visually neutral is not accepted on trust.

The parity test drives the real runtime SIDECARD path to a fully seated frame, loads a real decoded hero image through the normal cache, captures the runtime pixels, then paints the extracted face directly into the runtime-derived seated rectangle.

The RGBA buffers must match exactly.

That distinction matters.

If a test constructed an equivalent rectangle for both sides, it would only prove that the painter is deterministic. It would not prove that no fill, clip, shadow, or image treatment remained behind in the caller.

The precedent is the same one used by the structural raster handoff tests:

```text
prove the seam with pixels, not a readiness flag
```

## EDITORIAL is explicit, not a silent migration

Existing CARD and SIDECARD source keeps its old rendering.

EDITORIAL is an explicit PANEL preset.

New cards authored from the EDIT inspector opt into it, while old projects remain visually stable.

Its first defaults are intentionally restrained:

```text
hero image          about 38%
kicker              below image
heading             32 reference units
body                17 reference units
body weight         regular
heading tracking    approximately zero
body line height    about 1.5
panel               flat
divider             none
```

The hero image remains full bleed.

The face is closer to an editorial page than a streaming-service module.

## Authored size is reference composition data

The new optional PANEL directives are:

```text
HEADING_SIZE: 32
BODY_SIZE: 17
IMAGE: 38%
```

They deliberately live in `[PANEL]` rather than expanding the colon-delimited CARD or SIDECARD header.

The reference scale is:

```text
scale = min(engineW / 1920, engineH / 1080)
```

Preview and BAKE use the same rule.

Therefore an authored typographic size is a position in the 1920x1080 reference composition, not a measurement of the output.

`BODY_SIZE:17` does not mean 17 output pixels.

Treating it as pixels would make the same card wrap differently at preview, 1080p, and 4K and would silently break render parity.

The GUI applies conservative editing bounds, while the parser stays more permissive so source remains forward-compatible.

## The EDIT inspector became composition-first

The old card dialog was functional but utilitarian.

The redesigned flow starts with the actual card face and then groups the controls by the author's intent:

```text
LIVE FACE PREVIEW

CONTENT
TYPE
STYLE
TIMING
```

The preview is not an approximation.

It builds a transient CardRequest from the same drafts that will be serialized, resolves the hero through the workspace media resolver, and sends both through `paintPresentationCardFace`.

The preview also acts as a selection surface.

Clicking its kicker, heading, or body region focuses the corresponding authoring field.

This is intentionally small interaction design, but it changes the dialog from “edit properties and imagine the result” to “touch the result and edit what you touched.”

## What is deliberately not exposed

The first pass does not add knobs simply because they are possible.

The renderer still owns:

```text
line spacing
content padding
text alignment
kicker size
inter-element spacing
```

The inspector exposes the values that materially change the composition:

```text
font
heading size
body size
hero-image percentage
panel color
```

The goal is useful artistic control, not a desktop-publishing surface.

## The footer idea was deferred on purpose

A mockup suggested that a small row of supporting images might look attractive at the bottom of EDITORIAL.

It was explicitly deferred.

At SIDECARD width, that strip is not a small ornament. It trades directly against body-copy space and changes the card from one authoritative photograph plus copy into a multi-image module.

That decision should be made after watching EDITORIAL in motion, not from a still mockup.

If it is revisited later, the likely source shape is repeated PANEL directives:

```text
FOOTER: images/a.jpg
FOOTER: images/b.jpg
FOOTER: images/c.jpg
```

Repeated directives fit the existing parser model better than a comma mini-language and preserve per-line diagnostics.

But no FOOTER grammar or rendering is part of EDITORIAL v1.

## The new contract

The current CARD-family styling boundary is now:

```text
CARD / SIDECARD / DOSSIER source
        ↓
PresentationPanelContent
        ↓
paintPresentationCardFace
        ↓
runtime / inspector preview / BAKE
```

SIDECARD shell geometry remains a separate authority:

```text
sidecard_geometry.dart
        ↓
outer structural window placement
```

The face does not own the shell.

The shell does not own the face.

That separation is what allowed the visual redesign to happen without reopening the structural work that was already correct.

## Tests that make this trustworthy

The EDITORIAL pass added explicit regression coverage for:

```text
runtime seated face == direct face painter pixels
EDITORIAL parses as an explicit PANEL preset
EDITORIAL paints no kicker or photo treatment inside the hero image
HEADING_SIZE / BODY_SIZE / IMAGE round-trip through PANEL source
malformed style directives are preserved and diagnosed
new inspector-authored cards explicitly write EDITORIAL defaults
unknown PANEL directives still survive GUI edits
live face preview focuses kicker / heading / body controls
```

The important rule remains the same as the rest of r3nder:

```text
source is authority
shared pure rendering owns appearance
tests prove seams
motion still gets the final visual vote
```
