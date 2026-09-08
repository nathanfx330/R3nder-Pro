# Test Strategy: Executable Architecture

R3nder Pro's most valuable tests are not coverage statistics. They are executable statements of product truth.

This page explains how to test the system so another engineer can distinguish parser correctness, model correctness, runtime timing, media decode, Flutter presentation, and final encoded output.

The central rule is:

> Test the ownership boundary where the bug could exist, and widen the boundary when every smaller layer is green but the product is still wrong.

---

## Why layered tests matter

R3nder combines several systems with different failure domains:

```text
authored syntax
CST/model ownership
project time
audio authority
media decode
structural recursion
Flutter layout/paint
Program Preview
SceneExporter
ffmpeg/container output
```

A symptom in one layer can originate in another.

Examples from the development history:

- video stutter looked like decode trouble but was largely Flutter repaint cost;
- a wallpaper flash looked like media readiness but was outgoing-shell paint ownership;
- missing CUSTOM chrome looked like a font/painter/ffmpeg issue but was placement metadata association;
- missing render-name tests locally were a branch-sync problem, not code failure.

Testing should therefore preserve boundaries rather than hiding everything inside one giant integration test.

---

# 1. Pure syntax and model tests

These are the fastest and most important tests for authored semantics.

They should not mount Flutter unless necessary.

Examples of contracts to prove:

```text
parse → serialize preserves untouched source
clip source mapping is exact
split preserves source continuity
CONFIG round-trips
STRUCT chrome parser rejects malformed keyed tails
render version planner is monotonic
```

Representative test families:

- `edit_model_test.dart`
- `edit_model_validation_test.dart`
- `edit_surface_model_test.dart`
- structural parser/model tests
- `render_naming_test.dart`

These tests answer:

> Is the project model itself correct?

Do not use a widget test as the only specification of arithmetic or serialization.

---

# 2. GUI wiring tests

Widget tests prove that controls call the model correctly and that state survives GUI boundaries.

Useful examples:

```text
select STRUCT node
→ inspector shows first-class controls
→ toggle FULL
→ exact authored syntax changes
```

or:

```text
NODES
→ edit CUSTOM chrome
→ switch to EDIT
→ close editor
→ parent receives exact updated STRUCT line
```

Representative tests include:

- `editor_structural_fullscreen_node_test.dart`
- `editor_structural_chrome_close_handoff_test.dart`
- `render_name_config_node_test.dart`
- edit-surface widget tests

These tests answer:

> Does the UI actually write the canonical project state it appears to edit?

---

# 3. Project-time tests

Timing tests should prove explicit frame identity independent of wall-clock cadence.

Test:

- rational ProjectTime normalization;
- seek/epoch behavior;
- forward/backward scene evaluation;
- exact export frame selection;
- local structural frame mapping from runtime markers;
- clip project-to-source frame mapping.

These tests answer:

> When the system says frame N, do all models agree what N means?

---

# 4. Fake-backend media/compositor tests

The media abstraction allows deterministic decoder fakes.

Use them to test:

- active clip selection;
- V1/V2 compositing;
- transition progress;
- nested EDIT/MOSAIC recursion;
- MOSAIC pane geometry;
- pending/offline propagation;
- recursion-depth guards.

Representative tests include:

- `edit_video_compositor_test.dart`
- `edit_video_compositor_depth_guard_test.dart`

A fake should be simple enough that the expected pixel result is obvious.

These tests answer:

> Given exact decoded source frames, does R3nder compose the right pixels?

---

# 5. Native tests and probes

Some claims require the real Linux stack.

Examples:

- PulseAudio queue/drain/flush behavior;
- measured latency;
- persistent MLT seek/decode behavior;
- ProjectClock AUDIO mode under sustained decode load;
- external texture delivery.

Native sources include:

```text
linux/runner/audio_sink_test.cc
linux/runner/media_decoder_test.cc
linux/runner/av_lock_probe.cc
```

The accepted A/V validation procedure is documented in `M4_AV_LOCK_VALIDATION.md`.

These tests answer:

> Does the physical/native implementation satisfy the contract the Dart model assumes?

---

# 6. Top-level Program Preview tests

A direct `StructuralSequencePreview` test is not the same as a `ProgramPreviewSurface` test.

Program Preview adds:

- runtime REGION projection;
- placement-index lookup;
- base ScenePainter layering;
- preload/cover behavior;
- top-level document association.

When a bug appears only after leaving the editor workspace, add a Program Preview gate rather than more isolated structural-widget tests.

Representative example:

- `program_preview_structural_chrome_runtime_test.dart`

This layer was essential during M20 because isolated chrome rendering was already green.

---

# 7. ProgramStructuralFrameRenderer tests

These test the whole-program offscreen structural frame before ffmpeg.

They should cover:

- windowed and fullscreen geometry;
- mixed-mode morphs;
- DEFAULT chrome;
- CUSTOM chrome;
- `[frame]` expansion;
- placement source-local frame identity.

Representative tests include:

- `program_structural_chrome_text_bake_test.dart`
- `program_structural_export_test.dart`
- `program_structural_mixed_mode_bake_test.dart`

These answer:

> If BAKE asks the program structural renderer for frame N, is the complete image correct before encoding?

---

# 8. Encoded SceneExporter end-to-end tests

When final output is wrong, renderer tests are not enough.

A true exporter test should execute:

```text
SceneExporter.export()
    ↓
real FIFO
    ↓
real ffmpeg encode
    ↓
finished MP4/MOV
    ↓
ffmpeg decode back to raw pixels
    ↓
assert encoded result
```

Representative tests:

- `scene_exporter_structural_chrome_end_to_end_test.dart`
- `scene_exporter_structural_mosaic_custom_end_to_end_test.dart`

These tests proved that CUSTOM structural chrome survived the real exporter and codec path.

That result ruled out several attractive but wrong hypotheses and forced the investigation toward real-document metadata association.

These answer:

> Did the final encoded file preserve the intended pixels and output semantics?

---

# 9. Test realistic document shapes, not only tiny fixtures

Many architectural bugs require realistic source layout.

M18 and M20 both exposed this.

A tiny fixture like:

```text
[EDIT:main]...[/EDIT]
[STRUCT:EDIT.main]
```

may pass while a real document contains:

```text
structural definitions
comments
CONFIG
more definitions
multiple same-duration STRUCT placements
hidden STRUCT-looking metadata
```

Tests should include the source shapes that challenge ownership/indexing rules.

When a production bug appears despite green unit tests, the regression should reproduce the real document topology that made it possible.

---

# 10. Visual gates

Some defects are visible composition seams that are difficult to specify only by model state.

M18 preserved a manual visual gate for adjacent structural application switching.

A visual gate is appropriate when acceptance includes statements such as:

- no one-frame wallpaper flash;
- no fullscreen terminal between apps;
- no visible shell reset;
- incoming source appears under outgoing cover before handoff.

Visual gates should be narrowly scripted and repeatable, not vague “play around and see if it feels right” sessions.

Keep the exact fixture beside the checklist when possible.

---

# 11. Distinguish compile errors from product failures

Several development cycles produced new regression tests that initially failed to compile because of harness mistakes:

- nullable `runAsync<T>()` results;
- `Future<Image?>` versus `Future<Image>`;
- `const Rect` using runtime conversions;
- widget viewport constraints;
- fake-async image readback boundaries.

These are not production regressions.

Treat test harness correctness as its own problem:

```text
compile/load failure
    ≠
assertion failure
    ≠
real GUI failure
```

Fix the harness without touching production unless the assertion actually demonstrates a product defect.

---

# 12. Flutter fake-async rules

Widget tests need care around operations that escape Flutter's fake async environment.

Common examples:

- filesystem setup;
- external processes;
- `ui.Image.toByteData()`;
- ffmpeg;
- asynchronous native/image work.

Use `tester.runAsync()` around the entire operation that needs the real async/event loop, including dependent readback work.

Do not split a GPU/image operation so creation occurs inside `runAsync` and readback occurs outside it; that can hang.

For widget layout tests, change the root test view size (`tester.view.physicalSize`) rather than wrapping a larger child in a `SizedBox` that cannot override root constraints.

---

# 13. Tests should encode ownership rules

The best regression names tell a future engineer why the architecture exists.

Good examples:

```text
hidden source metadata does not shift STRUCT runtime marker index
EditorScreen preserves CUSTOM STRUCT chrome through NODES → EDIT → close
SceneExporter preserves FULL MOSAIC CUSTOM chrome in encoded H264
render versions remain monotonic across deleted gaps
```

These are better than tests named after private helper functions.

A private implementation can change. The ownership rule should survive.

---

# 14. Acceptance ladder for a new NLE feature

A useful default ladder is:

```text
1. parser/model unit test
2. mutation/serialization test
3. compositor/media fake test, if pixels involved
4. widget integration test
5. top-level Program Preview test, if presentation involved
6. SceneExporter/end-to-end encoded test, if BAKE involved
7. real GUI visual gate
```

Not every feature needs every rung.

But if the feature crosses a boundary, test that boundary.

---

# 15. When the product is wrong but tests are green

Do not immediately rewrite production code.

Ask:

```text
What exact path did the real user take that the tests did not?
What larger ownership boundary exists outside the tested unit?
What real document topology is missing?
What state handoff occurs between the green tests?
```

Then add the smallest end-to-end regression that includes that missing boundary.

This method was decisive in M20.

---

# Reconstruction checklist

A rebuild should have proof at each layer:

- [ ] syntax/CST round-trip tests;
- [ ] edit-model arithmetic tests;
- [ ] GUI-to-document mutation tests;
- [ ] ProjectTime/frame-mapping tests;
- [ ] fake media/compositor tests;
- [ ] native audio/MLT tests;
- [ ] Program Preview runtime tests;
- [ ] program structural bake-frame tests;
- [ ] real SceneExporter + ffmpeg encoded tests;
- [ ] realistic multi-placement/indexing fixtures;
- [ ] scripted visual gates for paint/readiness seams;
- [ ] regression names describe product contracts rather than implementation trivia.

If the test suite is built this way, it becomes a second form of documentation: an executable map of what the editor promises.