# MOSAIC Two-Window STRUCT Presentation

Status: W0 through W7 are implemented and locally exercised. W8 adds an
optional edge-to-edge MAX split presentation on
`mosaic-w8-maximized-split` and is awaiting local verification.

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
- Optional SPLIT:MAX snaps the two outer windows edge to edge across the
  program frame, with no outer margin or center gap. The authored aspect is
  preserved but dormant while MAX is enabled.
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

W4 passed locally: the non-native gate completed with 24 tests, the
Linux native MLT gate completed with 2 tests, and the documentation checker
reported 16 contracts / 84 proof files.

### W5 - transitions and readiness

W5 gives SPLIT an explicit presentation-shape identity without changing the
legacy `StructuralPresentationMode` API. Effective presentation shapes are
windowed, fullscreen, and split. Unsupported authored SPLIT remains ordinary
windowed for timing as well as rendering.

The transition contract is:

- split -> split is an immediate simultaneous two-pane cut, including an
  authored aspect change;
- split aspect changes add no project frames;
- window/fullscreen <-> split uses the existing single incoming
  `kStructuralWindowFrames` budget; the outgoing placement pays no extra close
  budget;
- any boundary involving SPLIT is excluded from the legacy horizontal
  single-client APPSWITCH slide;
- during a shape-change entry budget, the outgoing presentation remains as a
  fading cover while the incoming first source frame performs the standard
  open scale-and-fade inside the same authored budget;
- once the budget has elapsed, incoming readiness controls only visibility. A
  late incoming split continues to advance authored source time while the
  outgoing presentation remains stationary, then both panes cut together at
  the current authored source frame after one active-ready paint.

W5 initially implemented a stationary outgoing cover through that budget.
W7 keeps the same `StructuralSequenceHandoffRole.heldOutgoing` ownership and
the same frame count, but spends those frames on visible intent: the outgoing
final presentation fades while the incoming first source frame grows from the
standard emergence geometry. Preview and BAKE consume the same easing helpers.
Readiness can delay visibility but never restarts the authored progress. The
normal window/fullscreen APPSWITCH slide path is unchanged.

Proof:

- `test/structural_split_transition_plan_test.dart` pins split-to-split,
  aspect-change, window-to-split, split-to-window, and unsupported-SPLIT timing;
- `test/program_preview_structural_split_transition_test.dart` proves the
  top-level Program Preview stationary two-pane cut, one active-ready paint,
  delayed-readiness source-time advance, current-aspect reveal, and existing
  incoming budget for a window-to-split change;
- `test/program_structural_split_transition_bake_test.dart` proves BAKE holds
  the outgoing ordinary window through that same budget and then replaces it
  with both split pane colors in one cut.

Verification gate:

```bash
flutter test \
  test/structural_split_transition_plan_test.dart \
  test/program_preview_structural_split_transition_test.dart \
  test/program_structural_split_transition_bake_test.dart \
  test/program_preview_structural_switch_test.dart \
  test/program_preview_structural_late_handoff_test.dart \
  test/program_preview_structural_raster_handoff_test.dart \
  test/structural_sequence_preview_test.dart \
  test/structural_sequence_readiness_test.dart \
  test/structural_sequence_decode_timing_determinism_test.dart \
  test/program_structural_mixed_mode_bake_test.dart \
  test/program_structural_split_bake_test.dart

dart run tool/check_doc_contracts.dart
```

W6 does not begin until that gate passes locally.

### W6 - cue routing and unsupported shell cues

W6 makes cue ownership match the split presentation surface rather than the
legacy Metro MOSAIC rectangle.

For CARD, `structuralCardOverlayPlacementsForMosaicPane` evaluates one authored
pane at source time and remaps that pane to a complete 0..1 split client. It
also follows structural CLIPs recursively, which is the normal authored
topology when a MOSAIC pane points at `EDIT.foo` and the CARD lives on a media
CLIP inside that EDIT. Parent AT, IN, and rational speed map the pane frame to
the exact nested source frame before CARD timing is evaluated. Nested MOSAIC
geometry is retained inside the owning split client. Both live
`StructuralSplitWindowPreview` and whole-program BAKE composite the result
over the decoded pane image before `StructuralSplitWindowPainter` receives
it. The shared `compositeStructuralCardOverlaysToImage` helper keeps the
actual CARD face painting identical in Preview and BAKE.

SIDECARD and MAXIMIZE remain authored cue types, but an effective SPLIT
placement does not promote either cue into the outer structural shell. Preview
and BAKE suppress both active and source-end SIDECARD/MAXIMIZE shell state, so
they cannot move split geometry, alter close origin, or paint a side panel.
Unsupported authored SPLIT still falls back to ordinary windowed presentation
and therefore does not inherit this SPLIT-only cue restriction.

`EditGraphLinter` emits warning-only
`unsupportedSplitSideCard` and `unsupportedSplitMaximize` findings for those
cues when the placement is an effective supported SPLIT. Malformed cue syntax
continues to belong to the cue/script lint layer rather than making graph lint
throw.

Proof:

- `test/structural_split_cue_policy_test.dart` proves nested EDIT CARD
  ownership, parent AT/IN/speed frame projection, both warning codes through
  nested structural sources, and ordinary-window behavior for unsupported
  SPLIT fallback;
- `test/structural_split_card_preview_test.dart` uses the real
  MOSAIC -> EDIT -> media topology and proves live Preview paints a right-pane
  CARD only into the right split client while suppressing nested SIDECARD;
- `test/program_structural_split_card_bake_test.dart` uses the same nested
  topology and proves final BAKE has identical CARD ownership and no SIDECARD
  panel pixels while retaining both underlying pane images.

Verification gate:

```bash
flutter test \
  test/structural_split_cue_policy_test.dart \
  test/structural_split_card_preview_test.dart \
  test/program_structural_split_card_bake_test.dart \
  test/structural_split_window_preview_test.dart \
  test/program_structural_split_bake_test.dart \
  test/card_overlay_test.dart \
  test/card_overlay_state_test.dart \
  test/structural_sequence_sidecard_shell_test.dart \
  test/structural_sequence_maximize_test.dart \
  test/structural_split_placement_test.dart

dart run tool/check_doc_contracts.dart
```

The initial W6 gate passed with 20 tests and the documentation checker reported
16 contracts / 90 proof files. GUI validation then found that those fixtures
had authored CARD directly on a PANE CLIP instead of inside the nested EDIT used
by the real project. The strengthened nested-source proofs and production fix
must pass locally before W6 is considered complete again.

### W7 - shape-transition polish and fallback timing visibility

Post-review validation found two consequences that were deterministic but not
yet author-friendly.

First, the W5 split/non-split opening budget was visually a stationary hold.
The budget itself is correct and remains exactly
`kStructuralWindowFrames` (12 frames). W7 introduces
`structuralShapeEntryFrameAt` and `structuralShapeOutgoingOpacity` so those
same frames now show an intentional transition. The outgoing final presentation
fades while the incoming first source frame opens from the standard 84%
emergence rectangle. For SPLIT, each of the two windows applies that same
emergence-to-seated geometry independently. No source frames, project frames,
or readiness semantics are added.

GUI validation then exposed the same seated-geometry shortcut on an ordinary
SPLIT desktop entry: the two windows faded on at final size rather than using
the normal window-manager open. W7 now applies the standard emergence-to-seated
geometry to every SPLIT opening and the exact seated-to-emergence reverse curve
to every SPLIT closing. Opacity remains owned by the common structural shell,
so the two windows become visible and grow exactly during the existing window
budget rather than gaining any new timing.

Second, SPLIT timing follows the effective rendered shape, not merely the
authored request. If a two-pane MOSAIC becomes unsupported because a pane is
emptied, its requested SPLIT falls back to ordinary windowed presentation.
Inside an `APPSWITCH:SLIDE` chain that can introduce the existing 12-frame
shape-change budget at each neighboring split/windowed boundary. A middle
placement can therefore shift later TEXT timing by 24 frames without changing
the MOSAIC duration. This is intentional because reserving SPLIT timing for a
windowed fallback would make rendered geometry and timing disagree. The
fallback lint now explains this coupling.

Proof:

- `test/structural_shell_geometry_test.dart` pins the shared entry geometry,
  fade, and readiness-only opacity gate;
- `test/program_preview_structural_split_transition_test.dart` proves visible
  window-to-split and split-to-window motion in Program Preview while preserving
  delayed-readiness behavior;
- `test/program_preview_structural_split_test.dart` proves an ordinary SPLIT
  placement receives partial open progress and partial close progress from the
  top-level Program Preview rather than appearing/disappearing seated;
- `test/program_structural_split_transition_bake_test.dart` proves the same
  two directions in BAKE with pixel probes for both outgoing and incoming
  presentations;
- `test/program_structural_split_bake_test.dart` proves ordinary SPLIT open
  and close pixel bounds are smaller than the seated client bounds in BAKE;
- `test/structural_split_transition_plan_test.dart` pins the two-boundary
  24-frame fallback shift without changing source duration;
- `test/structural_split_placement_test.dart` pins the warning text that
  exposes the timing consequence.

Verification gate:

```bash
flutter test \
  test/structural_shell_geometry_test.dart \
  test/structural_split_transition_plan_test.dart \
  test/program_preview_structural_split_transition_test.dart \
  test/program_structural_split_transition_bake_test.dart \
  test/structural_split_placement_test.dart \
  test/structural_split_cue_policy_test.dart \
  test/structural_split_card_preview_test.dart \
  test/program_structural_split_card_bake_test.dart

dart run tool/check_doc_contracts.dart
```

W7 does not change the 12-frame authored budget. It changes only how those
frames are presented and makes fallback-induced timing changes explicit.

### W8 - maximized split screen

W8 adds a placement-owned MAX modifier to the existing two-window SPLIT:

```text
[STRUCT:MOSAIC.wall:SPLIT]
[STRUCT:MOSAIC.wall:SPLIT:MAX]
[STRUCT:MOSAIC.wall:SPLIT:MAX:ASPECT=4X3]
```

MAX is valid only with SPLIT. It does not create another presentation shape and
therefore does not add timing. A normal SPLIT -> MAX SPLIT or MAX SPLIT ->
normal SPLIT boundary is the same simultaneous zero-budget geometry cut already
used by split aspect changes.

The same `mosaicSplitWindowGeometry` helper remains the sole layout authority.
Normal SPLIT retains its measured margins, gap, and fixed client aspect. MAX
sets outer margin and center gap to zero, gives each outer window exactly half
the program width, and uses the full program height including title chrome.
At 1920 x 1080 with 38 px title chrome this means two 960 x 1080 outer windows
and two 960 x 1042 clients. Media remains contained within each client.

The Node STRUCT inspector exposes MAXIMIZE SPLIT only while TWO WINDOWS is on.
The aspect control remains authored and visible; while MAX is active it is
dormant so turning MAX off restores the previous normal-split aspect rather than
resetting it.

Proof is carried by the existing split boundary files:

- `test/mosaic_split_geometry_test.dart` pins exact edge-to-edge geometry for
  every authored aspect and proves aspect is geometrically dormant in MAX;
- `test/structural_split_placement_test.dart` pins SPLIT-only MAX grammar and
  placement state;
- `test/script_node_structural_split_test.dart` pins node round-trip and
  dormant aspect preservation;
- `test/editor_structural_split_node_test.dart` pins the MAXIMIZE SPLIT
  checkbox workflow and FULL/SPLIT/MAX exclusivity;
- `test/structural_split_window_preview_test.dart` proves live Preview uses
  edge-to-edge MAX geometry;
- `test/program_structural_split_bake_test.dart` proves BAKE reaches both
  program edges with no center gap;
- `test/structural_split_transition_plan_test.dart` proves normal/MAX split
  geometry changes add zero frames.

Verification gate:

```bash
flutter test \
  test/mosaic_split_geometry_test.dart \
  test/structural_split_placement_test.dart \
  test/script_node_structural_split_test.dart \
  test/editor_structural_split_node_test.dart \
  test/structural_split_window_preview_test.dart \
  test/program_structural_split_bake_test.dart \
  test/structural_split_transition_plan_test.dart

dart run tool/check_doc_contracts.dart
```

## Non-goals

This milestone does not change MOSAIC Trim to shortest. In particular,
`removeClip` retains exact block-span deletion, and trim primitives remain
non-rippling. Surviving cue presentations truncated at their tails are a
separate future diagnostic; they are not dormant triggers and are not part of
this milestone.
