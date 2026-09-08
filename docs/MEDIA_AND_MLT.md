# Media Layer and Persistent MLT Decode

This page defines the boundary between R3nder's authored timeline/compositor and the native media backend.

The central rule is:

> MLT decodes requested leaf frames. R3nder owns project time, source hierarchy, composition, and final pixels.

Primary files:

- `lib/media_layer.dart`
- `lib/edit_video_compositor.dart`
- `lib/structural_source_export.dart`
- Linux native MLT runner/plugin code under `linux/`

Related measurement:

- `docs/EDIT_PLAYBACK_PERFORMANCE.md`
- `docs/M4_AV_LOCK_VALIDATION.md`

---

## Contract

The media layer must guarantee:

- media decoders never advance project time;
- decoder lifetime is persistent across frame requests;
- exact offline requests either return the requested source frame or fail;
- live Preview may be nonblocking;
- asynchronous results are presented only if they still match current ProjectTime/epoch;
- leaf media and structural references are distinguished before file opening;
- EDIT/MOSAIC references are resolved recursively by R3nder, never handed to MLT as filenames;
- decode readiness affects visibility, not authored duration or geometry.

---

# 1. The dependency direction

The correct direction is:

```text
ProjectTime
    ↓
EDIT/MOSAIC geometry
    ↓
active CLIP
    ↓
requested source frame
    ↓
MediaLayer
    ↓
persistent MLT decoder
```

The media backend is therefore a service beneath the timeline model.

Do not let a decoder's internal playhead become the project clock.

Do not ask MLT “what frame should the project be on?”

Ask MLT “give me source frame 417 at this output size.”

---

# 2. MediaLayer owns decoder identity

`MediaLayer` holds a decoder map keyed by resolved media source.

That makes decoder lifetime longer than a single frame request.

Persistence is required for editor behavior:

- scrubbing;
- repeated seeks;
- sequential playback;
- crossfades;
- nested structural sources;
- avoiding repeated decoder cold start.

A naive implementation that opens the source for every frame can pass basic screenshot tests while becoming unusable as an NLE.

Build persistent decoder identity before spending time on elaborate timeline chrome.

---

# 3. Backend seams

The key abstractions are:

```text
MediaDecoderBackend.open(path)
    → MediaDecoder
```

A basic decoder supports exact synchronous render:

```text
render(requestedSourceFrame, width, height)
```

Live-capable decoders may implement `NonBlockingMediaDecoder`:

```text
request(frame, size)
poll(frame, size)
```

Native texture-capable decoders may expose a texture delivery path as well.

The abstraction exists for two reasons:

1. production can use persistent native MLT;
2. tests can use deterministic fake backends.

This test seam is essential. It lets structural composition, Preview, and BAKE tests specify exact decoded pixels without requiring a real codec stack for every semantic regression.

---

# 4. Exact versus live decode policy

The same authored frame contract supports two scheduling policies.

## Exact/offline

Used by structural source export and final BAKE.

Policy:

```text
request exact source frame
wait as long as necessary
validate actual == requested
produce frame or fail
```

A slow decoder makes export slow. It does not move project time.

A neighbouring source frame is not an acceptable substitute.

## Live/nonblocking

Used by interactive playback.

Policy:

```text
publish desired source frame
poll completed decoder work
show only work valid for current ProjectTime
```

If the decoder is pending, the UI can preserve an earlier visual cover or show a loading state.

The timeline continues according to ProjectClock.

This separation is how R3nder avoids choosing between deterministic export and responsive live playback.

---

# 5. MediaFrame records requested and actual identity

A decoded result carries both:

```text
requestedSourceFrame
actualSourceFrame
```

That is deliberate.

A decoder returning “some nearby frame” may look acceptable in a casual preview but violates exact export.

The system can therefore distinguish:

- decoded exact frame;
- pending frame;
- offline source;
- structural source requiring recursive composition.

`MediaFrameStatus` makes those states explicit rather than overloading null pixels to mean everything.

---

# 6. Epoch-safe presentation

`MediaRenderResult.canPresentAgainst(ProjectTime current)` compares:

```text
epoch
frame
rational phase
```

A completed asynchronous decode is useful only if it still belongs to the current request identity.

Example:

```text
user scrubs to frame 100
    → decoder starts work
user immediately scrubs to frame 500
    → epoch changes
frame 100 decode completes late
```

Without epoch checking, frame 100 can flash over frame 500.

The right answer is not necessarily to destroy the decoder. Persistent decoder caches are useful. Reject the stale *result*, not the decoder object.

---

# 7. Structural sources are not files

If a CLIP source is:

```text
EDIT.foo
MOSAIC.bar
```

`MediaLayer` must not call the backend with that string.

It returns structural-pending identity so `EditVideoCompositor` can recursively evaluate the nested source.

This is a major architectural boundary:

```text
MediaLayer
    leaf decode

EditVideoCompositor
    structural recursion + composition
```

Conflating these roles makes nesting impossible to reason about and tends to turn the media backend into an accidental project engine.

---

# 8. Composition stays in R3nder

`EditVideoCompositor` receives exact ProjectTime and produces final RGBA for an EDIT or MOSAIC source.

It owns:

- active clip selection;
- track ordering;
- transition progress;
- recursive EDIT/MOSAIC evaluation;
- MOSAIC pane layout;
- final pixel blending;
- recursive diagnostic propagation.

MLT only supplies leaf decoded pixels.

That ownership is important for Preview/BAKE parity because the same R3nder composition rules can be used with either nonblocking or exact decode policy.

---

# 9. Recursive diagnostic frames

Nested composition creates a subtle problem.

Suppose a MOSAIC contains an EDIT, and the EDIT contains two leaf media layers. One layer decodes correctly; another is offline. The nested EDIT may still produce visible pixels from the good layer.

If export validates only the synthetic outer frame, it can silently bake a partial image.

`EditVideoCompositeResult` therefore carries two channels:

```text
mediaFrames
    composition-local frames, including synthetic structural frames

diagnosticFrames
    recursive leaf decode outcomes
```

Exact structural export checks the recursive diagnostic channel.

This pattern is worth copying in any nested compositor: visible output and diagnostic provenance are not the same thing.

---

# 10. Exact structural source export

`StructuralSourceFrameRenderer` is the blocking source-level renderer for canonical `EDIT.<id>` or `MOSAIC.<id>` sources.

For every project frame it:

```text
validate source graph
    ↓
ProjectTime(frame: N, scrub)
    ↓
EditVideoCompositor.renderSource(...)
    ↓
reject pending/offline/wrong actual leaf frames
    ↓
pack exact RGBA
```

An authored gap is allowed and becomes transparent RGBA.

An offline source is not treated as a gap.

This difference prevents the exporter from silently interpreting decode failure as creative transparency.

---

# 11. Output size is part of decode identity

Decoder requests include width and height.

This matters because:

- preview may render a smaller surface than final BAKE;
- native textures may be allocated for a target size;
- read-ahead/cache identity can depend on output geometry;
- MOSAIC pane decoders receive pane-local dimensions.

Do not cache only by `(source, frame)` if the decoder's output pixels depend on requested dimensions.

---

# 12. Performance architecture

A useful performance model separates:

```text
ProjectClock cost
native decode cost
Dart/native transfer cost
Flutter paint/layout cost
```

R3nder's playback investigation found that native timing/decode could be healthy while Flutter's moving timeline caused large UI-thread repaint cost.

That is why `docs/EDIT_PLAYBACK_PERFORMANCE.md` should be read beside this page.

Never infer “decoder is slow” from a stuttering GUI without measuring the presentation layer separately.

---

# 13. Failure modes to recognize

## Every scrub feels like a cold start

Decoder identity is probably being recreated per request.

## Old frames flash after fast seeking

Asynchronous results are not checked against ProjectTime epoch/frame identity.

## BAKE occasionally uses a neighbouring frame

Exact export is trusting decoder output without validating `actualSourceFrame`.

## Nested source is opened as a path

Structural reference detection is happening too late.

## Offline nested layer disappears silently in export

The exporter is validating only outer composite pixels instead of recursive diagnostic frames.

## Playback stutters but A/V lock probe is green

Investigate Flutter paint/layout/texture presentation before changing decode cadence.

---

# 14. Proof

The media layer needs several different kinds of proof:

- source-frame mapping tests;
- fake-backend compositor tests;
- persistent decoder tests;
- native MLT tests where available;
- recursion/depth-guard tests;
- exact structural export tests;
- measured real-machine playback tests.

Representative files include:

```text
test/edit_video_compositor_test.dart
test/edit_video_compositor_depth_guard_test.dart
```

plus media-layer/native-decoder tests in the suite and the end-to-end SceneExporter tests.

---

# Reconstruction checklist

- [ ] project time selects media, never the reverse;
- [ ] decoder objects persist across frame requests;
- [ ] exact and nonblocking decode policies share one authored mapping;
- [ ] requested and actual source frame identities are both observable;
- [ ] stale async results are rejected by project-time identity;
- [ ] EDIT/MOSAIC refs never reach the leaf backend as paths;
- [ ] recursive composition belongs to the application, not MLT;
- [ ] exact export validates recursive leaf outcomes;
- [ ] authored gaps are distinct from offline decode failures;
- [ ] decode/output-size identity is explicit;
- [ ] performance measurements separate decode from Flutter presentation.

Once these hold, the media backend can be swapped or optimized without changing the NLE's project semantics.