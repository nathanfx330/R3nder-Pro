# Contract → Proof Manifest

This file is the executable index of R3nder Pro's architectural contracts.

Its purpose is simple: when documentation says a subsystem guarantees something, the repository should name the tests or measurements that prove that guarantee. If one of those proof files is deleted or renamed, `dart run tool/check_doc_contracts.dart` and the normal Flutter test suite must fail until this manifest is deliberately repaired.

This is not a list of every test. It is the minimum proof spine another engineer should preserve when rebuilding or refactoring the editor.

The standard is:

```text
CONTRACT
what must remain true

PROOF
which repository files demonstrate it
```

---

## 1. Canonical authored state remains lossless

**Contract**

The script is the project. Structural parsing identifies owned EDIT/MOSAIC regions without granting permission to normalize unrelated source. Editing one owned span must preserve untouched bytes and opaque lexical regions.

**Proof**

- `test/script_cst_baseline_test.dart`
- `test/script_cst_nested_test.dart`
- `test/script_cst_root_nesting_contract_test.dart`
- `test/script_cst_source_span_test.dart`
- `test/edit_compile_projection_test.dart`

---

## 2. EDIT timing is exact authored geometry

**Contract**

EDIT/TRACK/CLIP owns project placement, source IN, project duration, exact speed, track membership, and transition metadata. Source-frame mapping is exact integer/rational arithmetic. Split/trim/move operations mutate authored text rather than a hidden project database.

**Proof**

- `test/edit_model_test.dart`
- `test/edit_model_validation_test.dart`
- `test/edit_surface_model_test.dart`
- `test/edit_clip_creation_test.dart`
- `test/edit_edge_transition_test.dart`
- `test/edit_linter_test.dart`

---

## 3. Project frame N is explicit and reproducible

**Contract**

Flutter polling cadence, decoder latency, and export wall time do not own project time. Realtime and export scheduling both resolve through explicit ProjectTime semantics, and scene evaluation at frame N is reproducible.

**Proof**

- `test/project_clock_native_test.dart`
- `test/scene_evaluation_equivalence_test.dart`
- `test/scene_sprite_evaluation_equivalence_test.dart`
- `test/terminal_pause_explicit_age_test.dart`
- `test/terminal_scramble_explicit_age_test.dart`
- `test/terminal_sprite_explicit_age_test.dart`
- `test/terminal_svg_explicit_age_test.dart`
- `linux/runner/project_clock_test.cc`

---

## 4. Audio can become realtime clock authority without creating a second timeline

**Contract**

The native sink reports cumulative played samples and measured latency into ProjectClock AUDIO mode. Queueing remains bounded, drain/flush are explicit, and sustained MLT decode load does not create accumulated clock drift.

**Proof**

- `test/audio_packet_contract_test.dart`
- `test/audio_sink_native_test.dart`
- `linux/runner/audio_sink_test.cc`
- `tool/av_lock_probe.dart`
- `linux/runner/av_lock_probe.cc`
- `docs/M4_AV_LOCK_VALIDATION.md`

---

## 5. MLT decodes leaf media; R3nder owns timeline semantics

**Contract**

Persistent media decoders answer exact source-frame requests. Requested and actual source-frame identity stay visible. Pending/offline state does not move project time, and nested EDIT/MOSAIC references are resolved by the structural compositor rather than opened as filesystem media.

**Proof**

- `test/media_layer_test.dart`
- `test/media_decoder_native_test.dart`
- `linux/runner/media_decoder_test.cc`
- `test/edit_video_compositor_test.dart`
- `test/edit_video_compositor_depth_guard_test.dart`

---

## 6. Structural recursion is deterministic

**Contract**

EDIT may be evaluated as a reusable source, MOSAIC composes structural sources into panes, recursion is bounded, and exact offline structural export rejects pending/offline/wrong-frame leaf decode rather than silently substituting pixels.

**Proof**

- `test/mosaic_source_test.dart`
- `test/mosaic_surface_model_test.dart`
- `test/mosaic_timeline_edit_test.dart`
- `test/structural_source_export_test.dart`
- `test/structural_source_export_native_test.dart`
- `test/edit_video_compositor_depth_guard_test.dart`

---

## 7. STRUCT placement owns presentation, not the reusable source

**Contract**

A STRUCT placement selects an EDIT/MOSAIC source and owns windowed/fullscreen mode, DEFAULT/CUSTOM/NONE chrome, title/overlay copy, dynamic `[frame]` expressions, and application-switch presentation. The source definition remains reusable and unchanged.

**Proof**

- `test/structural_chrome_test.dart`
- `test/structural_sequence_chrome_test.dart`
- `test/script_node_structural_chrome_test.dart`
- `test/script_node_structural_fullscreen_test.dart`
- `test/editor_structural_fullscreen_node_test.dart`
- `test/structural_chrome_frame_expression_preview_test.dart`

---

## 8. Runtime STRUCT marker identity matches executable placement identity

**Contract**

Only executable main-sequence STRUCT placements participate in runtime marker indexing. Structural-looking text inside reusable EDIT/MOSAIC definitions or otherwise removed metadata cannot shift the placement/chrome association used by Preview or BAKE.

**Proof**

- `test/structural_runtime_marker_test.dart`
- `test/structural_sequence_definition_gap_test.dart`
- `test/structural_sequence_marker_alignment_test.dart`
- `test/edit_compile_projection_test.dart`

---

## 9. GUI mutation returns to canonical authored state

**Contract**

NODES and EDIT are editors over the document. First-class controls must serialize their meaning, and crossing NODES → EDIT → close must return the exact live authored buffer to the dashboard rather than hidden widget state or stale template text.

**Proof**

- `test/editor_structural_chrome_close_handoff_test.dart`
- `test/editor_structural_fullscreen_node_test.dart`
- `test/render_name_config_node_test.dart`
- `test/edit_workspace_test.dart`
- `test/edit_workspace_resolver_seam_test.dart`
- `test/edit_workspace_sequence_placement_test.dart`

---

## 10. Structural readiness affects visibility, never authored time

**Contract**

Decode readiness may delay when an incoming structural source is exposed, but it may not add project frames, restart source-local time, or create a desktop/wallpaper flash during seamless application handoff.

**Proof**

- `test/structural_sequence_readiness_test.dart`
- `test/structural_sequence_decode_timing_determinism_test.dart`
- `test/program_preview_structural_switch_test.dart`
- `test/program_preview_structural_late_handoff_test.dart`
- `test/program_preview_structural_raster_handoff_test.dart`
- `docs/M18_STRUCT_APP_SWITCH_VISUAL_GATE.md`
- `docs/M18_STRUCT_APP_SWITCH_VISUAL_FIXTURE.txt`

---

## 11. Top-level Program Preview consumes runtime projection, not editor-only state

**Contract**

Program Preview uses the compiled runtime REGION bridge and the same raw authored document to associate active placement metadata with structural source pixels. A direct StructuralSequencePreview test is not sufficient proof of this boundary.

**Proof**

- `test/program_preview_structural_chrome_runtime_test.dart`
- `test/program_preview_structural_fullscreen_test.dart`
- `test/program_preview_structural_switch_test.dart`
- `test/program_preview_structural_late_handoff_test.dart`

---

## 12. Whole-program BAKE preserves the same structural presentation semantics

**Contract**

SceneExporter evaluates explicit project frames, ProgramStructuralFrameRenderer composes the active STRUCT placement, and final encoded output preserves window/fullscreen geometry, DEFAULT/CUSTOM chrome, dynamic `[frame]` copy, and structural source-local frame identity.

**Proof**

- `test/program_structural_export_test.dart`
- `test/program_structural_geometry_test.dart`
- `test/program_structural_mixed_mode_bake_test.dart`
- `test/program_structural_chrome_text_bake_test.dart`
- `test/scene_exporter_structural_chrome_end_to_end_test.dart`
- `test/scene_exporter_structural_mosaic_custom_end_to_end_test.dart`

---

## 13. Source export and final program BAKE are different products

**Contract**

Structural source export renders reusable EDIT/MOSAIC content only. Placement-owned STRUCT presentation is included only in whole-program Preview/BAKE. UI wording must not imply that source export is the dressed final program.

**Proof**

- `test/structural_source_export_test.dart`
- `test/structural_source_export_native_test.dart`
- `test/program_structural_export_test.dart`
- `test/scene_exporter_structural_mosaic_custom_end_to_end_test.dart`

---

## 14. Render identity belongs to the project and never silently overwrites history

**Contract**

`[CONFIG:RENDERNAME:...]` is canonical project state. Finished BAKE output uses a sanitized human name plus resolution and a monotonic version. Deleted gaps are not reused, format changes remain in one version family, fill/matte companions reserve one version together, and existing files are protected both before ffmpeg and by ffmpeg no-overwrite mode.

**Proof**

- `test/render_naming_test.dart`
- `test/render_name_config_node_test.dart`
- `test/scene_exporter_structural_mosaic_custom_end_to_end_test.dart`

---

## 15. A production bug with green lower-level tests must gain a boundary regression

**Contract**

When the product is wrong but parser/painter/compositor tests are green, the next test must include the missing ownership boundary or realistic document topology. The suite should preserve the failure class, not merely the final private implementation.

**Proof**

- `test/structural_sequence_marker_alignment_test.dart`
- `test/editor_structural_chrome_close_handoff_test.dart`
- `test/program_preview_structural_chrome_runtime_test.dart`
- `test/scene_exporter_structural_chrome_end_to_end_test.dart`
- `test/scene_exporter_structural_mosaic_custom_end_to_end_test.dart`

---

## 16. The written proof map cannot silently detach from the repository

**Contract**

Every numbered contract in this manifest must name at least one real repository proof artifact. Renaming or deleting a cited test/probe/visual gate must fail both the standalone documentation check and the normal Flutter test suite until the manifest is deliberately updated.

**Proof**

- `tool/check_doc_contracts.dart`
- `test/documentation_contract_manifest_test.dart`

---

# Drift check

Run from the repository root:

```bash
dart run tool/check_doc_contracts.dart
```

The same rule is also enforced by:

```bash
flutter test test/documentation_contract_manifest_test.dart
```

The checker reads this manifest and verifies that every numbered contract declares proof and every backticked repository proof path still exists. A renamed or removed proof file is therefore a test failure, not silent documentation drift.

The checker deliberately does **not** claim that file existence proves behavioral correctness. The actual tests and probes still have to run. Its job is narrower: keep the written contract map attached to real repository artifacts.

A cited proof file is therefore a maintenance responsibility, not just a path that happens to exist. If a proof test or probe is rewritten, broadened, narrowed, repurposed, or substantially renamed, the person making that change must re-read the contract(s) that cite it and confirm that the file still genuinely proves those claims. If it no longer does, update the proof map or add a replacement regression in the same change. The automated drift check can prove attachment; only review can preserve semantic honesty.