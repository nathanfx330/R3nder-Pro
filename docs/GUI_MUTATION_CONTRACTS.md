# GUI Mutation Contracts

R3nder Pro deliberately avoids a hidden project database. That means every GUI surface must behave as an editor over canonical authored state rather than as a second durable model.

This page explains the mutation rules that keep TEXT, NODES, EDIT, MOSAIC, Preview, and BAKE synchronized.

Primary files:

- `lib/editor_node_workspace.dart`
- `lib/script_nodes.dart`
- `lib/edit_surface_model.dart`
- `lib/edit_surface.dart`
- editor screen/workspace code
- `lib/main.dart`

---

## Contract

Every GUI mutation must satisfy:

```text
current document
    ↓
parse current owner/model
    ↓
perform one semantic mutation
    ↓
serialize new document text
    ↓
parent adopts that text as canonical state
```

The GUI may cache view state, but creative project state must be written back into the document.

Closing and reopening any editor surface from only the document must reconstruct the same authored intent.

---

# 1. View state versus project state

It is useful to classify every widget field before implementing it.

## View state

Examples:

```text
selected node
scroll offset
hovered trim handle
open inspector panel
current recycle-browser selection
playhead drag gesture state
```

These may live only in widget state.

## Project state

Examples:

```text
clip AT / IN / duration / speed
track membership
STRUCT fullscreen
STRUCT overlay mode and copy
CONFIG values
render name
transition kind and duration
```

These must survive editor close and application restart, so they belong in authored project state.

The practical rule is:

> If losing the value changes the user's creative result, it is probably not merely widget state.

---

# 2. NODES edits the document, not ScriptNode objects

`EditorNodeWorkspace` parses the document into `ScriptNode` views.

A field edit updates the selected node, composes the node list back into source, and emits the complete updated text through `onTextChanged`.

The parent owns the live document buffer.

The local ScriptNode instance is disposable. A reparse may replace every node object.

That is why cross-parse addressing uses stable document position/index where necessary rather than assuming generated node IDs survive independent parses.

---

# 3. Protected structural roots

EDIT and MOSAIC roots appear in NODES so the document remains understandable, but the generic node form is not allowed to regenerate their nested source.

Those cards are protected views over CST-owned bytes.

Their role is closer to:

```text
show structural source exists
show id/summary
allow navigation
```

than to:

```text
serialize nested TRACK/PANE/CLIP tree generically
```

Actual structural source editing happens through the EDIT/MOSAIC model/surfaces that understand nested ownership.

This is an important anti-corruption boundary between generic node editing and the NLE.

---

# 4. STRUCT is a first-class ordinary placement node

STRUCT is different from protected EDIT/MOSAIC definitions.

A STRUCT node is main-program authored state and can be reordered or edited normally.

Its inspector owns controls such as:

```text
source
fullscreen
DEFAULT / CUSTOM / NONE overlay
window title
top overlay
bottom overlay
```

Changing a STRUCT node mutates only that placement. It must not modify the referenced reusable source.

This is what lets the same `MOSAIC.wall` appear twice with different presentation metadata.

---

# 5. CONFIG is first-class project metadata

CONFIG keys use one generic syntax and one shared registry.

The node UI derives available keys and editing kind from `config_keys.dart`.

This makes settings such as:

```text
APPSWITCH
CAPTION
RENDERNAME
```

ordinary document state rather than one-off preferences stored elsewhere.

The key architectural benefit is reconstruction: a copied template carries the output/presentation intent that belongs to that project.

---

# 6. EDIT operations return text

The visual timeline should not directly mutate long-lived clip objects as canonical state.

The pattern is:

```text
parse EditSurfaceDocument from current source
    ↓
move/trim/split/add transition/etc.
    ↓
return new source string
    ↓
parent replaces live editor text
    ↓
reparse
```

This is why model-level edit operations are so important. Widgets convert gestures into frame-domain intent, then delegate authored mutation.

---

# 7. Gesture coordinates are not durable state

A timeline drag starts in pixels but ends in frames.

Conceptually:

```text
pointer delta
    ↓
view transform / zoom / scroll
    ↓
integer project-frame delta
    ↓
model operation
```

Never store a clip's durable position as an X coordinate.

The same rule applies to trim handles, playhead scrubbing, and pane-local timelines.

The view may be resized or zoomed later. Project frames must remain unchanged.

---

# 8. Editor close/handoff is a real architectural boundary

A critical integration path is:

```text
NODES edits
    ↓
live editor text buffer
    ↓
EDIT/MOSAIC workspace may inspect/edit same buffer
    ↓
Back / Escape closes editor
    ↓
EditorScreen.onClose(latestText)
    ↓
main adopts latestText as _docText
    ↓
Preview / BAKE consumes _docText
```

M20 forced this path to be tested because a local inspector can look correct while final program state is stale.

The handoff test should assert exact serialized syntax, not only that a callback fired.

---

# 9. External asset mutation is separate from text mutation

Some GUI actions change files on disk without changing script text.

Examples:

- importing into an already-referenced image folder;
- recycling/restoring assets;
- replacing folder contents.

`EditorNodeWorkspace` therefore distinguishes:

```text
onTextChanged
onAssetsChanged
```

This is necessary because scene caches may have decoded the old folder contents even though the authored tag string did not change.

The broader lesson is:

> Canonical authored state and external resource identity are separate invalidation domains.

Do not force filesystem mutation through fake text changes merely to trigger refresh.

---

# 10. Source export versus final program action must be named honestly

The EDIT/MOSAIC workspace exports a reusable source.

The dashboard BAKE exports the whole program including STRUCT presentation.

When both buttons were effectively labelled “export,” users could reasonably assume they were equivalent.

The source workspace action now says **EXPORT SOURCE**.

UI labels are part of architectural correctness when two actions intentionally operate at different ownership levels.

---

# 11. Dirty state and reparse

A node or timeline operation that changes text should:

- update the live buffer immediately;
- mark the document dirty according to existing save policy;
- invalidate any warm simulation whose identity depends on changed content/config;
- reparse models whose source spans are now stale.

Do not keep old CST offsets or semantic objects after a length-changing rewrite.

Source spans are valid only for the parse that produced them.

---

# 12. Avoid duplicated defaults

A frequent GUI failure mode is enumerating the same concept in several widgets.

CONFIG keys previously had duplicated lists/default maps before being centralized in `config_keys.dart`.

The same danger applies to:

- supported tags;
- structural overlay modes;
- export formats;
- transition kinds;
- asset-field types.

Prefer one registry/model from which palette, inspector, defaults, and serializer derive.

Duplicated knowledge usually fails silently: the parser supports a feature that the UI cannot discover, or the UI emits a value the runtime never implemented.

---

# 13. Failure modes to recognize

## It works until the editor closes

The change probably lived only in widget/controller state.

## BAKE uses older values than the inspector showed

Trace the exact editor close/handoff into main document state.

## Opening NODES causes a huge source diff

Untouched nodes are being normalized rather than round-tripped verbatim.

## Editing STRUCT changes the MOSAIC source globally

Placement and source ownership have been conflated.

## Asset disappears from folder but Preview still shows it

Filesystem invalidation was missed because script text did not change.

## A new CONFIG key parses but is absent from the GUI

Enumeration is duplicated instead of using the central registry.

---

# 14. Proof

Useful integration tests include:

- node round-trip tests;
- `test/editor_structural_fullscreen_node_test.dart`;
- structural chrome node tests;
- `test/editor_structural_chrome_close_handoff_test.dart`;
- `test/render_name_config_node_test.dart`;
- edit-surface widget tests;
- source import/asset mutation tests.

The strongest GUI test asserts the final authored text after a realistic route, for example:

```text
NODES
→ set CUSTOM chrome
→ switch to EDIT
→ close editor
→ callback returns exact CUSTOM STRUCT syntax
```

That proves state crossed UI boundaries rather than merely changing an on-screen field.

---

# Reconstruction checklist

- [ ] classify each GUI field as view state or project state;
- [ ] project state always serializes into canonical authored state;
- [ ] generic NODES cannot regenerate protected structural roots;
- [ ] STRUCT remains an editable placement node;
- [ ] EDIT mutations are model operations returning source text;
- [ ] pointer coordinates convert to frames before durable mutation;
- [ ] editor close returns the latest text exactly;
- [ ] main Preview/BAKE consume that same returned buffer;
- [ ] filesystem mutations have a separate invalidation signal;
- [ ] source export and final BAKE are clearly named and separated;
- [ ] registries/defaults are centralized rather than duplicated across widgets.

If these rules hold, the GUI can grow substantially without quietly becoming a second project format.