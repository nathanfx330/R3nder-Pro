# Program Preview and BAKE

This page defines how R3nder turns canonical authored state into live presentation and final encoded output.

The most important rule is:

> Preview and BAKE may use different scheduling mechanisms, but they must evaluate the same authored frame contract.

Primary files:

- `lib/program_preview_surface.dart`
- `lib/structural_sequence_preview.dart`
- `lib/program_structural_export.dart`
- `lib/structural_source_export.dart`
- `lib/exporter.dart`
- `lib/scene_evaluator.dart`
- `lib/main.dart`

---

## Contract

For a given canonical document and project frame N:

- top-level Preview and BAKE resolve the same active sequence event;
- structural placement identity is the same;
- source-local frame is the same;
- windowed/fullscreen geometry is the same;
- transition progress is the same;
- DEFAULT/CUSTOM/NONE chrome semantics are the same;
- `[frame]` expands from the same structural source-local frame;
- decode delay may alter wall-clock completion time but never authored time;
- final encoded pixels are produced from the same structural presentation rules, not a simplified export-only interpretation.

---

# 1. Top-level Preview is not the EDIT preview pane

R3nder has several visual surfaces.

The EDIT workspace preview answers:

> What does this reusable structural source look like while I edit it?

Top-level Program Preview answers:

> What does the finished authored presentation look like at current project time?

Those are different interfaces.

The distinction became critical during M20 because a source/editor preview could be correct while whole-program placement metadata was wrong.

When debugging final BAKE parity, always establish which preview path is being observed.

---

# 2. ProgramPreviewSurface keeps ScenePainter as the base program

`ProgramPreviewSurface` does not replace the terminal renderer with a second project compositor.

Its stack is conceptually:

```text
ScenePainter
    base terminal / desktop program pixels

StructuralSequencePreview
    sibling layer only while STRUCT runtime marker is active
```

This preserves the real terminal scene, theme, wallpaper, and transition pixels during structural handoff.

The structural widget receives the same live `SceneEngine` and font identity.

That avoids reconstructing a “ghost terminal” separately for structural Preview.

---

# 3. Runtime REGION bridges the engine sequence to structural presentation

The terminal engine remains the top-level sequence clock.

During compilation, each executable STRUCT placement becomes an internal REGION marker plus timing projection.

At runtime:

```text
SceneEngine.currentRegion
    ↓
parseStructuralRuntimeRegion()
    ↓
placementIndex + duration
    ↓
StructuralSequencePlacement
    ↓
local structural frame
```

Program Preview therefore does not maintain a second main-program playhead for structural events.

This is a key parity property: the same engine event that controls terminal timing also tells the structural layer which placement is live.

---

# 4. Readiness is presentation state, not timeline state

A live native decoder may not have the incoming frame ready immediately.

Program Preview handles this as visual ownership.

Under seamless handoff:

1. the next structural source may be preloaded while the current one remains active;
2. a zero-opacity preload can decode without painting;
3. when the incoming placement becomes active it paints at full opacity underneath the outgoing cover;
4. the outgoing cover is removed only after the incoming source is ready **and has completed one active paint**.

Why require an active paint after readiness?

Because Flutter can skip painting a subtree at opacity zero. Logical readiness alone does not prove any incoming pixels have actually appeared in the composition.

This was the source of the M18 one-frame wallpaper flash.

The fix was not to pause project time. It was to keep visual ownership with the outgoing shell until the incoming shell had truly painted.

---

# 5. Preloading must not restart local time

When APPSWITCH:SLIDE preloads the next source, the hidden decoder may already be ready before the placement becomes active.

Activation must still use the authored local frame derived from the runtime marker.

Do not reset the incoming source to frame zero merely because the widget switches from hidden preload to visible active state.

Preload affects decoder readiness only.

---

# 6. BAKE uses explicit frame iteration

`SceneExporter.export()` first performs a deterministic dry run to determine exact total program frame count.

Then the render loop conceptually does:

```text
for i in 0 .. totalFrames - 1:
    scene.evaluate(ProjectTime(frame: i, mode: scrub))
    if STRUCT active:
        ProgramStructuralFrameRenderer.renderIfActive(...)
    else:
        SceneCompositor renders terminal frame
    image.toByteData(rawRgba)
    write bytes to ffmpeg FIFO
```

This is deliberately not realtime.

If frame 300 requires expensive decode, frame 300 simply takes longer to produce.

The next authored frame remains 301.

---

# 7. Whole-program STRUCT BAKE

`ProgramStructuralFrameRenderer` mirrors the structural presentation used by live Preview.

It observes the already-evaluated SceneEngine runtime marker, resolves the same placement, derives the same local frame, renders the exact EDIT/MOSAIC source through `StructuralSourceFrameRenderer`, then paints the terminal/desktop transition and placement window/chrome into one output image.

The compositor owns:

```text
terminal/desktop state
STRUCT geometry
source image
window chrome
placement title
overlay text
opacity
```

The source-level renderer owns only reusable EDIT/MOSAIC pixels and source diagnostics.

---

# 8. DEFAULT chrome versus CUSTOM chrome

DEFAULT chrome uses technical metadata produced by the actual structural source render: active track/clip, project frame, requested/actual source frame, layer count.

CUSTOM chrome uses placement-authored text.

Both are painted at the program STRUCT layer.

This is important: DEFAULT appearing in a BAKE proves the program structural layer is active. It does not automatically prove CUSTOM metadata was associated with the correct placement.

That distinction helped isolate the M20 bug.

---

# 9. The M20 placement-association failure

The hardest BAKE bug in this area produced a misleading result:

```text
video correct
DEFAULT overlay renders
CUSTOM overlay missing/wrong
Editor preview correct
isolated renderer tests green
encoded exporter tests green
```

The root problem was placement identity.

Runtime REGION markers were indexed from the executable/root-stripped projection, while another path rebuilt placement metadata from a differently interpreted raw document.

If a STRUCT-looking line existed inside non-executable source metadata, later indices could shift.

The renderer could therefore resolve the correct structural source content but pair it with the wrong placement chrome.

The durable fix was:

> Runtime marker indexing and render metadata indexing must use the same executable placement set.

This is a general lesson for any compiled authoring system. Never join runtime identity and metadata by list position unless both lists are produced by the same filtering/ordering contract.

---

# 10. Source export versus final program BAKE

There are intentionally two export concepts.

## EXPORT SOURCE

Renders a reusable EDIT/MOSAIC source.

It does not include placement-owned STRUCT presentation.

Use it when you want the structural source itself.

## Main dashboard BAKE

Renders the finished program.

It includes:

- TEXT/terminal presentation;
- STRUCT placement timing;
- fullscreen/windowed mode;
- title/overlay chrome;
- audio beds/music;
- final output format and render naming.

The UI was changed to say **EXPORT SOURCE** because the old generic “EXPORT” label hid this architectural distinction.

---

# 11. FFmpeg is a byte sink, not a project compositor

Once `SceneExporter` has chosen the final `ui.Image` for one project frame, it converts that image to raw RGBA and writes it through a FIFO to ffmpeg.

Downstream ffmpeg cannot selectively know which pixels were “text” and which were “video.”

That observation became a useful debugging boundary in M20.

If an exact frame contains chrome immediately before RGBA handoff, ordinary encoding cannot intentionally strip only those text pixels while retaining neighbouring video.

The exporter also handles audio muxing, codec/container choices, alpha workflows, and output duration.

But creative project composition is already complete before those bytes enter ffmpeg.

---

# 12. Audio in BAKE

BAKE does not route through the live preview audio player.

ffmpeg reads the original voice/music files as independent inputs and applies the same gain spelling as Preview.

The rendered picture remains authoritative for duration.

Music looping fills picture time; it does not extend the authored picture.

Voice behavior follows the terminal scene's existing end-hold semantics.

This separation lets final output retain source audio quality/channel count independent of preview resampling.

---

# 13. Encoded end-to-end tests matter

A renderer-level pixel test is necessary but not always sufficient.

M20 required progressively wider gates:

```text
StructuralSequencePreview
ProgramPreviewSurface
ProgramStructuralFrameRenderer
SceneExporter
ffmpeg encode
ffmpeg decode
pixel inspection of finished MP4
```

The end-to-end SceneExporter tests proved the real FIFO/ffmpeg handoff preserved CUSTOM chrome.

The final missing bug then had to live in real-document placement association rather than the painter or encoder.

This is a strong testing principle:

> When all unit layers are green but the product is wrong, add a test across the composition boundary instead of adding more assertions inside the same unit.

---

# 14. Failure modes to recognize

## Editor preview correct, Program Preview wrong

Investigate runtime projection/marker identity before export.

## Program Preview correct, encoded BAKE wrong

Investigate `ProgramStructuralFrameRenderer` and SceneExporter handoff.

## Renderer image correct, encoded output wrong

Inspect raw RGBA immediately before ffmpeg and then codec/container behavior.

## Correct video but wrong placement chrome

Suspect source/placement association, indexing, or stale document metadata.

## One-frame desktop/wallpaper flash during seamless handoff

Incoming source readiness has been confused with successful active paint, or outgoing cover lifetime is too short.

## BAKE appears to ignore STRUCT chrome but file is named after source

The user probably invoked EXPORT SOURCE rather than final program BAKE.

---

# 15. Proof

Important proof includes:

- `test/program_preview_structural_chrome_runtime_test.dart`
- `test/program_structural_chrome_text_bake_test.dart`
- `test/program_structural_export_test.dart`
- `test/program_structural_mixed_mode_bake_test.dart`
- `test/scene_exporter_structural_chrome_end_to_end_test.dart`
- `test/scene_exporter_structural_mosaic_custom_end_to_end_test.dart`
- structural marker alignment tests
- `docs/M18_STRUCT_APP_SWITCH_VISUAL_GATE.md`

The strongest acceptance remains a real GUI visual run after the automated gates.

---

# Reconstruction checklist

- [ ] top-level Preview and BAKE compile the same canonical document;
- [ ] SceneEngine remains the top-level sequence clock;
- [ ] structural presentation observes runtime marker identity rather than inventing a second playhead;
- [ ] readiness cannot change authored time;
- [ ] seamless handoff preserves the outgoing shell until incoming active paint is proven;
- [ ] preloading cannot restart local source time;
- [ ] BAKE selects explicit project frames;
- [ ] exact source render is validated before program composition;
- [ ] placement chrome is painted in the whole-program structural layer;
- [ ] runtime marker and metadata indexing share one executable placement set;
- [ ] source export is explicitly distinguished from final program BAKE;
- [ ] end-to-end encoded tests prove final file pixels, not merely painter output.

When these hold, Preview becomes a trustworthy view of what BAKE will produce rather than an approximation.