# MOSAIC Two-Window STRUCT Presentation

Status: design locked for v1. W0 and W1 passed their local gates. W2 placement
grammar/model/authoring/lint is implemented on
`mosaic-w2-placement-authoring` and awaiting local Flutter verification.

This document records the next MOSAIC presentation milestone after Trim to
shortest T0-T4. It is deliberately a STRUCT placement feature. The reusable
MOSAIC definition remains content-only.

## Goal

For an exactly two-pane populated MOSAIC, a STRUCT placement may present the two
panes as two separate desktop windows instead of one Metro-style MOSAIC client.

The mode is placement metadata. The same MOSAIC may therefore be reused in
ordinary windowed, fullscreen, or split-window placements without rewriting the
MOSAIC definition.

## Locked v1 behavior

- The mode belongs to STRUCT placement, never the MOSAIC definition.
- It is valid only for exactly two panes and both panes must be populated.
- Unsupported sources lint and fall back to ordinary windowed presentation.
- One authored client aspect belongs to the placement: 16:9, 4:3, or 9:16.
- The default authored aspect is 16:9.
- Aspect is fixed for the placement and is never inferred from media.
- Both windows are equal size, side by side, centered as a group, with a fixed
  inter-window gap.
- Footage is contained inside each client.
- Split-to-split changes are simultaneous cuts. There is no client slide.
- An aspect change between split placements also cuts geometry with no extra
  timing.
- Changes between presentation modes consume the existing entry budgets.
- Desktop entry and exit retain the existing timing budgets.
- CARD maps to the client owned by its source pane.
- SIDECARD and MAXIMIZE are unsupported in split v1. They lint and do not paint.
- Grammar is placement-owned: SPLIT is the presentation token, ASPECT carries
  authored client ratio, and stable PANE 1/PANE 2 titles derive from the
  effective STRUCT title.

## Measured reference geometry

At a 1920 x 1080 output:

```text
edge margin = width * 0.035 = 67.20
gap = width * 0.024 = 46.08
maximum client width
  = (width - 2 * edge margin - gap) / 2
  = 869.76

title height = 38 reference pixels
maximum client height
  = height * 0.78 - title height
  = 804.40
```

For authored client aspect `a`:

```text
clientHeight = min(maximumClientWidth / a, maximumClientHeight)
clientWidth  = a * clientHeight
```

The two-window group is horizontally centered while retaining the fixed gap.
Outer windows are vertically centered. When the height cap binds, width
contracts rather than changing aspect.

Reference results:

| Authored aspect | Client size | Matching footage | Windowed Metro baseline |
| --- | ---: | ---: | ---: |
| 16:9 | 869.76 x 489.24 | 41.04% | 28.14% |
| 4:3 | 869.76 x 652.32 | 54.72% | 37.52% |
| 9:16 | 452.48 x 804.40 | 35.11% | 35.11% |

16:9 and 4:3 both gain 45.86% relatively over their matching windowed Metro
baseline. Portrait split improves framing and symmetry but not total visible
footage area. Fullscreen Metro is a different comparison point: two 16:9
sources occupy 50.72% there.

These values are source-derived geometry calculations. The standard MLT 7.22
CPU loader normalizers were traced as containing and padding footage, but the
numbers above are not native pixel measurements. W3 proves the compositor and
BAKE ownership boundaries with synthetic pixel fixtures; W4 still owns the
native edge-marked circle measurement against the actual media backend.

## Rendering constraint discovered before implementation

Calling `MediaLayer.renderPane` twice is not sufficient for split rendering.
For nested EDIT/MOSAIC pane sources, MediaLayer deliberately returns structural
pending placeholders. The compositor resolves those sources recursively and
applies pane transitions.

W3 therefore needs a compositor-level pane entry point that reuses the complete
existing structural path, including nonblocking readiness behavior and recursive
leaf diagnostics. Split rendering must not create a second, weaker render path.

## Stage plan

### W0 - shared legacy MOSAIC layout

Extract the existing normalized pane rectangles into one pure helper shared by:

- `EditVideoCompositor`
- CARD structural cue ownership
- DOSSIER structural cue ownership

The compositor retains pixel rounding. No timing or visible geometry is intended
to change.

Proof is `test/mosaic_layout_test.dart`:

- empty and unsupported legacy count behavior;
- exact one-, two-, and three-pane normalized rectangles;
- CARD ownership for every pane;
- DOSSIER ownership for every pane;
- exact and available compositor paths;
- independent red/green/blue pixel fixtures;
- odd 101 x 57 output, pinning the 56/44 seam at x=57 and the stacked seam at
  y=29.

Verification gate:

```bash
flutter test test/mosaic_layout_test.dart test/mosaic_source_test.dart test/card_overlay_state_test.dart test/edit_dossier_cue_test.dart
dart run tool/check_doc_contracts.dart
```

W1 does not begin until that gate passes locally.

### W1 - pure split geometry

`lib/mosaic_split_geometry.dart` now owns the seated two-window calculation as
a pure coordinate-space-independent helper. It accepts the caller's frame
rectangle, semantic client aspect, and caller-scaled title height. It does not
know STRUCT grammar or choose chrome scale, so Preview and BAKE can later reuse
it without locking W2 authoring syntax or creating a second title-bar policy.

The helper exposes outer window, title-bar, and client rectangles for both
panes, plus the measured edge margin, gap, and maximum client bounds. The three
semantic aspect choices are 16:9, 4:3, and 9:16.

`test/mosaic_split_geometry_test.dart` proves:

- the exact 1920 x 1080 measurements for all three aspects;
- the 869.76 px width cap for 16:9 and 4:3;
- the 804.4 px client-height cap and 452.475 px contracted width for 9:16;
- equal windows and clients;
- the exact 46.08 px centered gap;
- horizontal group centering and vertical outer-window centering;
- title/client adjacency and frame bounds;
- coordinate-origin independence;
- linear 1080p to 4K scaling when caller chrome scales from 38 to 76 px;
- explicit rejection of invalid frame/title inputs.

Verification gate:

```bash
flutter test test/mosaic_split_geometry_test.dart test/mosaic_layout_test.dart test/program_structural_geometry_test.dart test/sidecard_geometry_test.dart
dart run tool/check_doc_contracts.dart
```

W2 does not begin until that gate passes locally.

### W2 - grammar, model, authoring, and lint

W2 locks the placement spelling to the existing STRUCT tail conventions:

```text
[STRUCT:MOSAIC.wall:SPLIT]
[STRUCT:MOSAIC.wall:SPLIT:ASPECT=4X3]
[STRUCT:MOSAIC.wall:SPLIT:ASPECT=9X16]
```

`SPLIT` is a bare placement presentation token like `FULL`. `ASPECT` is a
keyed value because it carries authored data. Its legal values are `16X9`,
`4X3`, and `9X16`; 16:9 is the implicit default and therefore emits no
`ASPECT` segment. `FULL` and `SPLIT` are mutually exclusive, and authored
`ASPECT` without `SPLIT` is invalid markup.

The placement model preserves two different facts:

- `splitWindowRequested`: what the document authored;
- `splitWindowSupported`: whether the current source is a MOSAIC with exactly
  two panes and both panes populated.

`splitWindow` is true only when both are true. An unsupported request remains
in source, produces a warning, and falls back to the existing ordinary windowed
presentation rather than becoming a render error or silently rewriting the
tag.

The node inspector now authors TWO WINDOWS and, while enabled, one CLIENT ASPECT.
Turning FULL on clears SPLIT and turning SPLIT on clears FULL. Opening NODES and
making unrelated edits does not materialize `SPLIT` or default
`ASPECT=16X9` into legacy tags.

Split window titles follow existing conventions rather than active clip names.
The existing effective STRUCT title is the base: blank TITLE means the canonical
source name; a custom TITLE replaces it. The two stable derived titles are:

```text
<effective title> · PANE 1
<effective title> · PANE 2
```

This matches MOSAIC's existing authored-order PANE 1/PANE 2 UI vocabulary and
prevents a pane timeline cut from renaming its desktop window.

Proof:

- `test/structural_split_placement_test.dart` covers grammar, support/fallback,
  title derivation, aspect state, and lint;
- `test/script_node_structural_split_test.dart` covers lossless/default
  round-trip and canonical node serialization;
- `test/editor_structural_split_node_test.dart` covers inspector controls,
  FULL/SPLIT exclusivity, and aspect authoring.

Verification gate:

```bash
flutter test test/structural_split_placement_test.dart test/script_node_structural_split_test.dart test/editor_structural_split_node_test.dart test/structural_chrome_test.dart test/structural_sequence_chrome_test.dart test/editor_structural_fullscreen_node_test.dart test/edit_linter_test.dart
dart run tool/check_doc_contracts.dart
```

W2 passed locally on the W2 branch, including the inspector scroll regression
gate. The documentation checker remained at 16 contracts / 80 proof files.

### W3 - BAKE

W3 adds compositor-level exact and nonblocking MOSAIC pane entry points. The
public pane API validates the MOSAIC root and pane index, then reuses the same
private pane composer and recursive structural resolver used by whole-MOSAIC
rendering. Direct MediaLayer pane output therefore never becomes the final split
client when nested EDIT/MOSAIC sources are present.

Structural source export exposes the same pane boundary for exact offline
rendering and applies the existing recursive leaf validation before returning
pixels. A nested leaf that is offline, pending in an exact render, or returns an
adjacent source frame remains a hard export failure.

Whole-program BAKE now uses the W1 geometry whenever a W2 placement has
effective split support. It renders both panes at the split client raster size,
paints two independent desktop windows, derives the stable PANE 1/PANE 2 titles,
and reuses one split-sized structural renderer per source/size so both panes
share decoder state. Unsupported authored SPLIT still reaches the unchanged
ordinary windowed path because its effective `splitWindow` flag is false.

W3 deliberately does not implement live Preview, split-to-split transition
semantics, CARD ownership, or SIDECARD/MAXIMIZE suppression; those remain W4,
W5, and W6 responsibilities.

Proof:

- `test/mosaic_split_pane_compositor_test.dart` proves exact recursive pane
  rendering, leaf diagnostics, and nonblocking pending-to-ready behavior;
- `test/program_structural_split_bake_test.dart` proves final BAKE paints two
  independent clients from a supported placement, including a nested EDIT in a
  pane, and preserves ordinary-window fallback for unsupported SPLIT.

Verification gate:

```bash
flutter test \
  test/mosaic_split_pane_compositor_test.dart \
  test/program_structural_split_bake_test.dart \
  test/structural_source_export_test.dart \
  test/edit_video_compositor_test.dart \
  test/program_structural_export_test.dart \
  test/mosaic_split_geometry_test.dart

dart run tool/check_doc_contracts.dart
```

W3 passed locally with 30 tests and the documentation checker at 16 contracts /
82 proof files.

### W4 - Preview

W4 adds live seated split presentation without creating a second structural
rendering stack. `StructuralSplitWindowPreview` owns one shared `MediaLayer`
and `EditVideoCompositor` for both panes, and each pane enters through the W3
`renderMosaicPaneAvailable` compositor boundary. Nested EDIT/MOSAIC resolution
and decoder/cache lifetime therefore remain shared across both desktop windows.

Preview and BAKE now share the exact same
`StructuralSplitWindowPainter` from
`lib/structural_split_window_painter.dart`. That painter delegates individual
window chrome and contain fitting to `lib/structural_window_painter.dart`.
The existing BAKE raster code was extracted rather than reimplemented for
Preview, so seated split geometry, chrome, shadows, clipping, title copy,
overlay copy, and image contain fitting have one production painter authority.
Both surfaces consume the W1 split geometry and the W2 stable PANE 1/PANE 2
titles.

Proof added in W4:

- `test/structural_split_window_preview_test.dart` renders a supported split
  with a nested EDIT in one pane, proves both compositor pane images are
  resident at the W1 client raster size, and verifies live Preview mounts the
  same `StructuralSplitWindowPainter` class used by whole-program BAKE;
- `test/program_preview_structural_split_test.dart` proves the compiled runtime
  REGION selects the SPLIT placement at the top-level Program Preview boundary,
  mounts the split raster rather than the ordinary single window, and opens both
  pane sources through the shared compositor;
- `test/structural_source_export_native_test.dart` adds a Linux native probe
  with a 16:9 edge-marked circular fixture rendered into a 4:3 pane request. All
  four edge marks must survive and the white circle must remain circular. This
  gate is intended to expose a real MLT sizing/crop/stretch defect rather than
  weaken the assertion if the backend disagrees with the authored contain
  contract.

W4 intentionally stops at the seated surface. Entry/exit choreography,
split-to-split cuts, aspect-change cuts, and delayed-readiness timing remain W5
work; CARD routing and SIDECARD/MAXIMIZE suppression remain W6 work.

Verification gate:

```bash
flutter test \
  test/structural_split_window_preview_test.dart \
  test/program_structural_split_bake_test.dart \
  test/mosaic_split_pane_compositor_test.dart \
  test/structural_sequence_preview_test.dart \
  test/program_preview_structural_split_test.dart \
  test/program_preview_structural_chrome_runtime_test.dart \
  test/program_preview_structural_switch_test.dart \
  test/program_preview_structural_fullscreen_test.dart \
  test/program_structural_export_test.dart \
  test/program_structural_chrome_text_bake_test.dart

flutter test test/structural_source_export_native_test.dart

dart run tool/check_doc_contracts.dart
```

W5 does not begin until that gate passes locally.

### W5 - transitions and readiness

Keep existing entry/exit budgets. Split-to-split and split aspect changes cut
simultaneously. Add delayed-readiness regression coverage so decoder state never
moves authored geometry or project time.

### W6 - cue routing and unsupported shell cues

Route CARD to the owning pane client. Lint SIDECARD and MAXIMIZE in split v1 and
do not paint them.

## Non-goals

This milestone does not change MOSAIC Trim to shortest. In particular,
`removeClip` retains exact block-span deletion, and trim primitives remain
non-rippling. Surviving cue presentations truncated at their tails are a
separate future diagnostic; they are not dormant triggers and are not part of
this milestone.
