# Test Strategy: Executable Architecture

R3nder Pro's most valuable tests are not coverage statistics. They are executable statements of product truth.

This page explains how to test the system so another engineer can distinguish parser correctness, model correctness, runtime timing, media decode, Flutter presentation, and final encoded output.

The central rule is:

> Test the ownership boundary where the bug could exist, and widen the boundary when every smaller layer is green but the product is still wrong.

The companion file `CONTRACT_TEST_MANIFEST.md` names the minimum proof files for the architectural contracts described here. `tool/check_doc_contracts.dart` verifies that those references do not silently rot when tests are renamed or removed.

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

- `test/script_cst_baseline_test.dart`
- `test/script_cst_nested_test.dart`
- `test/edit_model_test.dart`
- `test/edit_model_validation_test.dart`
- `test/edit_surface_model_test.dart`
- `test/structural_chrome_test.dart`
- `test/render_naming_test.dart`

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

- `test/editor_structural_fullscreen_node_test.dart`
- `test/editor_structural_chrome_close_handoff_test.dart`
- `test/render_name_config_node_test.dart`
- `test/edit_workspace_test.dart`

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

Representative proof includes:

- `test/project_clock_native_test.dart`
- `test/scene_evaluation_equivalence_test.dart`
- `test/structural_runtime_marker_test.dart`
- the explicit-age terminal tests.

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

- `test/media_layer_test.dart`
- `test/edit_video_compositor_test.dart`
- `test/edit_video_compositor_depth_guard_test.dart`

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
linux/runner/project_clock_test.cc
linux/runner/audio_sink_test.cc
linux/runner/media_decoder_test.cc
linux/runner/av_lock_probe.cc
```

The accepted A/V validation procedure is documented in `M4_AV_LOCK_VALIDATION.md` and driven by `tool/av_lock_probe.dart`.

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

Representative examples:

- `test/program_preview_structural_chrome_runtime_test.dart`
- `test/program_preview_structural_fullscreen_test.dart`
- `test/program_preview_structural_switch_test.dart`
- `test/program_preview_structural_late_handoff_test.dart`
- `test/program_preview_structural_raster_handoff_test.dart`

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

- `test/program_structural_chrome_text_bake_test.dart`
- `test/program_structural_export_test.dart`
- `test/program_structural_geometry_test.dart`
- `test/program_structural_mixed_mode_bake_test.dart`

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

- `test/scene_exporter_structural_chrome_end_to_end_test.dart`
- `test/scene_exporter_structural_mosaic_custom_end_to_end_test.dart`

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

`test/structural_sequence_marker_alignment_test.dart` is the canonical M20 example: the regression is not merely “CUSTOM chrome paints.” It preserves the real failure class that executable runtime marker order and raw metadata placement order must remain aligned.

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

Current example:

- `docs/M18_STRUCT_APP_SWITCH_VISUAL_GATE.md`
- `docs/M18_STRUCT_APP_SWITCH_VISUAL_FIXTURE.txt`

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

The sequence there was instructive:

```text
chrome parser/painter green
→ ProgramStructuralFrameRenderer green
→ top-level Program Preview green
→ SceneExporter → ffmpeg encoded output green
→ real project still wrong
→ realistic placement association/index topology added
→ production indexing defect exposed
```

The lesson is not “keep adding bigger tests forever.” It is “when every tested layer is correct, identify the untested transformation between them.”

---

# 16. Make documentation drift visible

A contract document that names no concrete proof can remain plausible long after the implementation changes.

`CONTRACT_TEST_MANIFEST.md` therefore maps the reconstruction-critical contracts to the exact test/probe/visual-gate files that prove them.

Run:

```bash
dart run tool/check_doc_contracts.dart
```

The checker verifies two things:

1. every numbered contract section declares at least one proof path;
2. every declared proof path still exists in the repository.

This catches a narrow but important form of rot: a document continuing to cite a test that was deleted or renamed.

It deliberately does not infer behavioral correctness from file existence. The actual proof still comes from running the relevant suite or native measurement.

When changing an architectural contract, update four things together:

```text
production implementation
proving test(s)
subsystem documentation
CONTRACT_TEST_MANIFEST.md
```

That makes documentation maintenance part of the engineering change rather than a cleanup task for later.

---

# Reconstruction proof checklist

A rebuild should be able to point to concrete proof at every layer. These are the current anchor files; the fuller mapping lives in `CONTRACT_TEST_MANIFEST.md`.

- [ ] **canonical/lossless document:** `test/script_cst_baseline_test.dart`, `test/script_cst_nested_test.dart`, `test/script_cst_source_span_test.dart`
- [ ] **EDIT timing arithmetic:** `test/edit_model_test.dart`, `test/edit_surface_model_test.dart`, `test/edit_edge_transition_test.dart`
- [ ] **GUI writes canonical state:** `test/editor_structural_chrome_close_handoff_test.dart`, `test/editor_structural_fullscreen_node_test.dart`
- [ ] **project-time identity:** `test/project_clock_native_test.dart`, `test/scene_evaluation_equivalence_test.dart`
- [ ] **fake media/compositor:** `test/media_layer_test.dart`, `test/edit_video_compositor_test.dart`
- [ ] **native audio/MLT:** `test/audio_sink_native_test.dart`, `test/media_decoder_native_test.dart`, `tool/av_lock_probe.dart`
- [ ] **structural recursion/export:** `test/structural_source_export_test.dart`, `test/edit_video_compositor_depth_guard_test.dart`
- [ ] **runtime placement/index alignment:** `test/structural_sequence_marker_alignment_test.dart`, `test/structural_runtime_marker_test.dart`
- [ ] **Program Preview runtime:** `test/program_preview_structural_chrome_runtime_test.dart`, `test/program_preview_structural_switch_test.dart`
- [ ] **program structural BAKE frame:** `test/program_structural_chrome_text_bake_test.dart`, `test/program_structural_mixed_mode_bake_test.dart`
- [ ] **real encoded SceneExporter:** `test/scene_exporter_structural_chrome_end_to_end_test.dart`, `test/scene_exporter_structural_mosaic_custom_end_to_end_test.dart`
- [ ] **render identity/version safety:** `test/render_naming_test.dart`, `test/render_name_config_node_test.dart`
- [ ] **visible handoff seam:** `docs/M18_STRUCT_APP_SWITCH_VISUAL_GATE.md`, `docs/M18_STRUCT_APP_SWITCH_VISUAL_FIXTURE.txt`
- [ ] **manifest references are current:** `dart run tool/check_doc_contracts.dart`

If the test suite is built this way, it becomes a second form of documentation: an executable map of what the editor promises.