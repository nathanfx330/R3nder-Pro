# M22 to M24 EDIT Inspector Baseline

This document records the accepted EDIT authoring baseline after M22, M23, and M24.

The purpose of these milestones was to make clip editing safer and more coherent without weakening the core R3nder Pro rule:

> The script is the project.

The EDIT inspector is therefore a projection of authored CLIP state. It is not a second project model.

---

## Accepted user surface

Selecting a clip in EDIT opens a right side inspector that exposes authored clip properties and actions.

The inspector currently owns:

* source and track readout
* timeline start
* source IN and derived source OUT
* authored duration
* source slip controls
* exact clip speed
* incoming transition
* outgoing transition
* luma transition configuration
* per clip audio gain
* per clip mute
* clip deletion

Timeline operations remain on the timeline and toolbar:

* trim IN
* trim OUT
* split
* move clip in project time
* move between V1 and V2
* zoom
* undo
* redo

Transition extents remain visible on clip edges, but transition editing is consolidated into the inspector.

---

## M22: clip inspector and deletion

M22 introduced a selected clip inspector and source preserving clip deletion.

Deleting a clip removes exactly that authored CLIP CST block. It does not ripple neighboring clips, repair gaps, or rewrite unrelated source.

Empty tracks are allowed to remain.

The deletion contract is deliberately narrow:

```text
selected authored CLIP block
        ↓
remove exact owned source span
        ↓
reparse
        ↓
parent adopts new complete source
```

This preserves the byte identity of unrelated authored source.

---

## M22.1: EDIT undo and redo

Destructive EDIT operations are protected by transient source history.

History stores exact complete source snapshots plus selected clip identity. It is not serialized into the project.

Every successful EDIT mutation that passes through the canonical commit seam becomes undoable, including:

* delete
* move
* trim
* split
* track move
* slip
* speed
* transitions
* gain
* mute

Undo restores the exact earlier authored source. Redo restores the exact later authored source.

A new edit after Undo clears the redo branch.

External source replacement clears local EDIT history so stale snapshots cannot overwrite a new authoring branch.

Keyboard shortcuts are focus scoped:

```text
Ctrl+Z          Undo
Ctrl+Shift+Z    Redo
Ctrl+Y          Redo
Delete          Delete selected clip
```

EDIT shortcuts fire only while the EDIT timeline owns primary focus, so normal text field undo remains normal text field undo.

---

## M23: authored clip audio gain and mute

Per clip audio gain and mute are authored in the CLIP suffix namespace.

Examples:

```text
[CLIP:id:source:at:in:duration:speed:GAIN=-6.0]
```

and:

```text
[CLIP:id:source:at:in:duration:speed:GAIN=-6.0:MUTE]
```

The first six CLIP fields remain positional and canonical.

Suffix tokens begin after speed.

Recognized suffixes are:

```text
GAIN=<dB>
MUTE
```

No GAIN token means unity gain, `0.0 dB`.

The accepted authored gain range is:

```text
-60.0 dB through +12.0 dB
```

Gain uses the normal amplitude conversion:

```text
linear = 10^(dB / 20)
```

`MUTE` wins operationally but does not erase the authored gain. Unmuting therefore restores the previous level.

Unknown future suffix tokens are preserved rather than normalized away. Known malformed suffixes fail explicitly.

The same gain and mute semantics flow through the structural audio plan and deterministic PCM renderer, so EDIT playback, TEXT program preview, and BAKE consume the same canonical audio meaning.

Gain and mute participate in structural audio cache identity.

---

## M24: inspector consolidation

M24 moved existing clip property controls into one coherent inspector.

The inspector now owns source timing and clip local presentation properties:

```text
SLIP
SPEED
INCOMING TRANSITION
OUTGOING TRANSITION
LUMA
GAIN
MUTE
DELETE
```

This is a UI ownership change, not a model semantics change.

All mutations still use `EditSurfaceDocument` and the same source backed commit path.

The toolbar remains for operations that are naturally timeline operations rather than clip properties.

This separation is intentional:

```text
clip property
    → inspector

timeline operation
    → timeline or toolbar
```

---

## Source preservation contract

Inspector edits must round trip through the canonical script and preserve unrelated authored source byte for byte.

A property that cannot be expressed in authored CLIP representation does not belong in the inspector as durable creative state.

This means the inspector may hold transient UI state while a control is being manipulated, but completion of the operation must resolve to authored source.

---

## Audio determinism contract

Per clip gain is applied in the structural PCM path together with transition envelopes.

Conceptually:

```text
source sample
    × clip gain
    × transition envelope
    = rendered sample
```

Mute resolves to zero contribution while preserving the authored gain value.

Nested EDIT audio composes through the same structural source plan rather than through a separate preview only mixer.

---

## Proof

The accepted regression surface includes:

```text
test/edit_clip_delete_test.dart
test/edit_source_history_test.dart
test/edit_surface_history_test.dart
test/edit_clip_inspector_test.dart
test/edit_clip_audio_gain_model_test.dart
test/edit_clip_audio_gain_ui_test.dart
test/structural_audio_gain_test.dart
test/structural_audio_gain_cache_test.dart
test/edit_clip_inspector_properties_test.dart
test/edit_edge_transition_ui_test.dart
test/edit_surface_test.dart
test/edit_surface_model_test.dart
test/edit_edge_transition_test.dart
```

The M22, M23, and M24 focused suites were run locally and passed.

The final EDIT surface was also manually accepted on Linux after exercising deletion, undo and redo, gain and mute, source slip, speed, incoming and outgoing transitions, luma controls, and the consolidated inspector workflow.

---

## Baseline

The accepted implementation is on `main` after M24.

M22 through M24 should be treated as the current EDIT interaction baseline for future work unless a later milestone deliberately changes one of these contracts.
