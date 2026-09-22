# MOSAIC Two-Window STRUCT Presentation

Status: W0 through W8 are merged to `main` at
`c02ae600d5144cb070773655cc4618d9d479f31d` and were run successfully from
main on Linux. W8's focused gate passed 34 tests before the final
horizontal-only MAX refinement; the final geometry/render subset then passed
13 tests. The documentation checker reported 16 contracts / 90 proof files,
and the final GUI behavior was confirmed before merge.

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
- Optional SPLIT:MAX removes horizontal waste: each client takes exactly half
  the program width with no outer margin or center gap. Authored aspect remains
  active and determines client height; only over-tall results are vertically
  capped.
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
by the real project. That was a useful failure of the test topology rather than
of the basic CARD painter. The production resolver was extended to follow the
real MOSAIC -> EDIT -> media path with exact parent frame mapping, and the
strengthened nested-source gate later passed with 5 tests. GUI validation then
confirmed that a CARD authored inside the nested EDIT fills only its owning
two-window client.

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
sets outer margin and center gap to zero and gives each client exactly half the
program width. Client height still follows the authored aspect, with only the
available program height acting as a cap. At 1920 x 1080 with 38 px title
chrome, 16:9 MAX produces two 960 x 540 clients inside two 960 x 578 outer
windows, vertically centered. 4:3 produces 960 x 720 clients. A 9:16 client
would exceed the available height at 960 px wide, so that case alone reaches
the vertical cap. Media remains contained within each client.

The Node STRUCT inspector exposes MAXIMIZE SPLIT only while TWO WINDOWS is on.
The aspect control remains active and visible in MAX because it determines the
window height.

Proof is carried by the existing split boundary files:

- `test/mosaic_split_geometry_test.dart` pins exact horizontal-edge geometry,
  aspect-derived height for 16:9 and 4:3, and the portrait vertical cap;
- `test/structural_split_placement_test.dart` pins SPLIT-only MAX grammar and
  placement state;
- `test/script_node_structural_split_test.dart` pins node round-trip and
  aspect preservation;
- `test/editor_structural_split_node_test.dart` pins the MAXIMIZE SPLIT
  checkbox workflow and FULL/SPLIT/MAX exclusivity;
- `test/structural_split_window_preview_test.dart` proves live Preview uses
  full horizontal width without making a 16:9 client full-height;
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

## Journey and post-merge review

The final feature is simpler than the path that produced it. This section keeps
the wrong turns because they explain several otherwise surprising contracts.

### The first split design was intentionally conservative

The first question was not "how do we fill the screen?" It was whether two
independent desktop windows could beat the existing Metro-style MOSAIC without
breaking the structural composition model. The initial geometry therefore kept
real desktop margins, a fixed inter-window gap, one authored client aspect, and
the existing window title/chrome treatment.

That conservative version established the important ownership boundary first:
MOSAIC remained reusable content, while SPLIT remained presentation metadata on
STRUCT. It also forced the rendering path to stay compositor-level rather than
opening pane media directly. That decision is why nested EDIT/MOSAIC sources,
decoder diagnostics, CARD routing, Preview, and BAKE all still share the same
structural semantics.

### Green lower-level tests did not mean the product was done

W6 is the clearest example. The first CARD tests were green, but the GUI exposed
that the fixtures put CARD directly on a MOSAIC pane clip. The real project put
CARD inside an EDIT referenced by the pane. The product therefore failed even
though the lower-level proof passed.

The fix was not to weaken the UI expectation. The test topology was made
realistic and the resolver learned to recurse through structural clips with
exact AT/IN/speed frame mapping. This is now one of the examples behind the
repository rule that a production bug with green lower-level tests must gain a
boundary regression.

### Deterministic timing can still look wrong

W5 got the frame accounting right at split/non-split boundaries. It reused the
existing 12-frame window budget, kept source time deterministic, and prevented
decoder readiness from inserting project frames. Visually, however, those same
12 frames initially held the outgoing final image stationary. The result looked
like dropped frames even though the timeline was mathematically correct.

Post-implementation review caught that mismatch. W7 kept the exact same authored
budget and source-time rules but spent those frames on visible intent instead:
the outgoing final presentation fades while the incoming presentation grows
through the standard window emergence curve. A later GUI pass found the same
seated-geometry shortcut on ordinary SPLIT open/close, so that path was corrected
too. The lesson was that deterministic timing and perceptually legible motion
are separate contracts and both need proof.

### Effective-shape timing has a real downstream consequence

The same review also exposed a timing consequence that was easy to understate.
SPLIT timing follows the shape that actually renders, not merely the authored
request. If a middle SPLIT placement becomes unsupported because one pane is
emptied, it falls back to ordinary windowed presentation. In a seamless
`APPSWITCH:SLIDE` chain that changes both neighboring shape boundaries.

The result can be two existing 12-frame window budgets, shifting later TEXT by
24 frames even though the structural source duration itself did not change.
Using requested SPLIT timing for a windowed fallback would hide the shift but
would make timing disagree with the rendered presentation. The implementation
therefore keeps effective shape as the timing authority and exposes the
consequence in lint.

### MAX began as full-height snap and was corrected by the GUI

The first W8 interpretation of MAX was literal Windows-style half-screen snap:
two 960 x 1080 outer windows at 1920 x 1080, with 960 x 1042 clients below the
title bars. That removed all outside margin and the center gap, but 16:9 footage
sat inside a very tall client with large black areas.

The GUI made the problem obvious. The actual need was horizontal real estate,
not vertical expansion. MAX was therefore refined to remove horizontal waste
only: each client gets half the program width, while authored aspect determines
height and the pair remains vertically centered. That produced the intended
16:9 result of 960 x 540 clients and 4:3 at 960 x 720, while preserving the same
open/close choreography, timing, cue ownership, and BAKE/Preview geometry
authority.

The final W8 focused gate passed 34 tests before this geometry refinement. The
refined geometry/render subset then passed 13 tests, and the result was checked
in the Linux GUI before W0-W8 were merged to main.

### Post-merge review: the remaining portrait MAX question

A second review after merge found one deliberate edge case worth preserving in
the record. Under the current MAX rule, 9:16 first claims the full 960 px
half-width. Its authored height would be about 1706.7 px, which cannot fit below
the title bar, so the vertical cap binds. The current client therefore becomes
960 x 1042 rather than a true 9:16 rectangle. Contain fitting then places roughly
586 x 1042 portrait footage inside that wider client.

That behavior is explicitly pinned by the geometry test, so it is not an
accidental crop/stretch bug. It is a presentation choice created by the
"half-width first, then cap height" rule.

There is a cleaner alternative for a future revision: preserve the authored
aspect when the height cap binds by shrinking client width as well. At 1080p
that would produce roughly 586 x 1042 portrait clients, keep the pair centered,
and expose desktop at the outside edges. Matching portrait footage would occupy
the same visible area either way; only the window shape and surrounding desktop
would change.

No code change has been made for that alternative. The merged W8 contract
remains the current half-width-first behavior. If portrait MAX is revisited,
the decision should be made as a visible window-design choice rather than by
changing contain fitting or decoder behavior.

## Rocky Linux cold-entry readiness investigation

After W0-W8 were merged and exercised on Ubuntu, Rocky Linux exposed a
platform-sensitive Preview failure: a cold two-window placement could skip the
visible open-scale/fade and appear only after the authored opening budget had
already elapsed. The geometry itself was correct once resident.

The cause was in live split readiness polling, not authored timing.
`StructuralSplitWindowPreview._render` uses the compositor's nonblocking pane
path while playback is moving. When either pane reported a pending leaf decode,
the method returned immediately. Source frame zero remains clamped throughout a
normal STRUCT opening, and opening progress alone does not require a pane
re-render. On a slower native decoder, no later source-frame/widget change was
guaranteed before showing began, so the pending decoder could simply stop being
polled during the exact frames in which the window should have become visible.

The fix schedules another render through the widget's existing coalesced
post-frame scheduler before returning from the pending branch. This is a
presentation-readiness retry only:

- project time does not advance;
- source time does not advance;
- authored entry progress is not restarted or extended;
- both panes must resolve before the pair is exposed;
- decoder/compositor instances remain resident and are reused;
- retries stop after the request resolves;
- disposal invalidates outstanding work through the existing mounted/serial
  guards.

The first polling repair deliberately did not retime presentation around decoder
latency. Rocky visual validation then proved that limitation was still visible
in the product: BAKE rendered the complete open-scale/fade correctly, but live
TEXT playback could consume part of the 12-frame opening while native video was
still becoming resident, and dashboard PREVIEW could consume the entire opening
before the pair was ready.

That established a second live-only contract. Decode latency is wall-clock work,
not authored project time. For monotonic live playback, a cold structural
opening now reports buffering to its transport owner. The owner holds project
time at the beginning of the authored window-opening stage, shows the existing
busy indicator, and resumes from that same project frame only after readiness.
If the readiness report is first observed a few opening frames late, the live
scene is restored to opening frame zero before the hold. No project frames are
inserted, source time remains frame zero during the hold, and BAKE is unchanged.

TEXT applies the same rule to its fallback stopwatch transport. While buffering,
the stopwatch is stopped and any workspace bed/music transport is stopped. Once
the structural frame is resident, the stopwatch is re-anchored to the held
project frame and the workspace mix restarts from that same program time. This
removes the Rocky-only visible frame skip without changing authored duration.

The current hold is intentionally not applied while STRUCT clip audio owns the
native AUDIO ProjectClock. That transport requires coordinated sink pause/resume
rather than a unilateral SCRUB seek; the Rocky script that exposed this issue
does not author STRUCT clip audio. AUDIO-authority buffering remains a separate
transport extension rather than risking picture/audio divergence.

The Program Preview regression uses two genuine
`NonBlockingMediaDecoder` fakes at a partial authored opening frame while
source frame remains zero. The left pane follows a nested MOSAIC -> EDIT -> media
path, the right pane is direct media. Releasing the left decoder alone must keep
the presentation hidden. Releasing the right decoder without changing project
frame, source frame, repaint state, or widget input must make both pane images
resident at the already-authored partial entry progress and opacity. The test
also proves requests remain on source frame zero, decoder instances are reused,
and polling stops after readiness. The same boundary runs for ordinary SPLIT
and SPLIT:MAX.

BAKE has no equivalent pending-poll seam. `ProgramStructuralFrameRenderer`
renders split panes through the blocking exact compositor path, then passes
authored opening/closing progress and shell opacity into the shared
`StructuralSplitWindowPainter`. The BAKE regression is nevertheless expanded
to ordinary SPLIT and SPLIT:MAX so early opening, middle opening, seated, and
closing frames prove both colored panes grow/shrink correctly. Because final
program output is opaque, fade is proved by increasing dominant pane color over
the desktop rather than by output alpha.

Focused verification gate:

```bash
flutter test \
  test/program_preview_structural_split_transition_test.dart \
  test/program_structural_split_bake_test.dart \
  test/structural_split_window_preview_test.dart \
  test/program_structural_split_transition_bake_test.dart \
  test/edit_video_compositor_test.dart \
  test/structural_sequence_preview_test.dart

dart run tool/check_doc_contracts.dart
```

### Follow-on Ubuntu finding: same-source legacy MOSAIC raster contention

Ubuntu validation then exposed a separate ordinary-windowed MOSAIC failure. A
fresh two-pane MOSAIC with both panes pointing at the same nested EDIT rendered
correctly in the structural editor but could remain black when placed as:

```text
[STRUCT:MOSAIC.mosaic:AUDIO]
```

This was not a SPLIT parser, pane-id, clip-id, or same-EDIT ownership problem.
The legacy two-pane MOSAIC layout is intentionally asymmetric: the left pane is
56% of the client width and the right pane is 44%. Both panes may therefore
resolve the same leaf media path at the same source frame but at two different
decode raster sizes.

Dart previously cached one persistent decoder by resolved media path only. The
native worker, however, owns one active target raster at a time and clears its
frame cache when width or height changes. A live nonblocking render could
therefore alternate forever between the left and right pane sizes:

```text
shared.mp4 @ left-pane raster
shared.mp4 @ right-pane raster  -> native size reset
shared.mp4 @ left-pane raster   -> native size reset
shared.mp4 @ right-pane raster  -> native size reset
...
```

Neither request stayed resident long enough for the whole MOSAIC to become
presentable, so the outer structural window remained black.

`MediaLayer` now keys persistent decoder workers by resolved media path plus
requested width and height. Stable-size playback still reuses one worker, while
simultaneous differently-sized consumers receive independent workers. Raster
variants are bounded by a small per-source LRU so repeatedly resizing Preview
cannot accumulate an unbounded number of native decoders.

Proof is split across two levels:

- `test/edit_video_compositor_test.dart` uses a nonblocking decoder fake that
  deliberately loses progress whenever one worker is bounced between raster
  sizes. The same nested EDIT in both 56/44 panes must resolve after two polls,
  with two raster-specific workers.
- `test/structural_sequence_preview_test.dart` reproduces the author-visible
  ordinary `STRUCT:MOSAIC...:AUDIO` opening path and proves first-frame
  readiness is reached with the same nested EDIT and same pane CLIP id.

Ubuntu previously passed the expanded local gate and visual checks. Rocky then
confirmed BAKE itself is correct and exposed the remaining live transport
readiness gap described above. The updated live buffering behavior remains
unverified until the focused tests and Rocky TEXT/PREVIEW visual checks pass.

## Non-goals

This milestone does not change MOSAIC Trim to shortest. In particular,
`removeClip` retains exact block-span deletion, and trim primitives remain
non-rippling. Surviving cue presentations truncated at their tails are a
separate future diagnostic; they are not dormant triggers and are not part of
this milestone.
