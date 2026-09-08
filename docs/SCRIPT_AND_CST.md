# Script, CST, and Canonical Authored State

R3nder Pro is language-first. The script is not an export format layered on top of a hidden project database. It is the project.

That decision determines the editor architecture:

```text
authored text
    ↓
lossless structural ownership
    ↓
semantic models
    ↓
GUI mutations
    ↓
new authored text
```

The GUI may make structural editing easier, but durable creative state must always be reconstructible from the document alone.

Primary files:

- `lib/parser.dart`
- `lib/script_cst.dart`
- `lib/script_nodes.dart`
- `lib/script_pipeline.dart`
- `lib/config_keys.dart`
- `lib/editor_node_workspace.dart`

---

## Contract

The authored-state contract is:

- the document is canonical;
- opening a GUI editor does not create a second project database;
- untouched source remains untouched;
- structural edits rewrite only the span they own;
- syntax the current GUI does not understand must survive round-trip;
- comments and opaque bodies may contain bracket-looking text without accidentally becoming structural nodes;
- EDIT/MOSAIC source definitions are metadata until explicitly placed by STRUCT;
- Preview, editor simulation, and BAKE compile through one shared script pipeline.

A useful test for every GUI feature is:

> If the application is closed and reopened from only the current document text, can the same authored intent be reconstructed?

If no, the GUI has invented hidden state.

---

# 1. Why a flat parser was not enough

The original terminal language is mostly well served by a flat tag parser. Many blocks deliberately treat their bodies as opaque text.

That is not sufficient for an NLE hierarchy.

EDIT/TRACK/CLIP and MOSAIC/PANE/CLIP need nested ownership:

```text
EDIT
  TRACK
    CLIP

MOSAIC
  PANE
    CLIP
```

When one CLIP changes, the editor needs permission to rewrite that CLIP and no more.

Regenerating an enclosing EDIT from a semantic object would normalize unrelated formatting, comments, future syntax, and hand-authored details.

`ScriptCstDocument` therefore records exact source spans for structural blocks.

The CST answers ownership questions such as:

```text
Which exact bytes belong to this CLIP opening tag?
Which bytes are inside this PANE?
Where can a new CLIP be inserted before this TRACK closes?
```

It does not need to understand every tag in the language.

---

# 2. Structural CST ownership

`lib/script_cst.dart` recognizes only structural source blocks:

```text
EDIT
TRACK
MOSAIC
PANE
CLIP
```

Each `ScriptCstBlock` records exact offsets for:

- complete block start/end;
- opening tag end;
- closing tag start;
- nested child blocks;
- parent ownership.

Mutations use operations such as:

```text
replaceBlock
replaceOpeningTag
replaceInnerSource
insertBeforeClosingTag
```

These are source-range operations, not object-tree serialization of the entire project.

The caller reparses after a length-changing mutation to obtain fresh spans.

This pattern is central to lossless editing.

---

# 3. Lexical ownership protects opaque content

Bracket syntax may appear as data inside other authored constructs.

Examples include bodies owned by:

- CARD;
- DOSSIER;
- TIMELINE;
- DEF_MENU;
- comments.

A string such as `[EDIT:foo]` inside one of those opaque regions must not suddenly become a real structural source.

`ScriptCstDocument` therefore respects pre-existing lexical ownership and ignores structural-looking tokens inside opaque spans.

This is a general parser lesson:

> Structural recognition must happen inside the language's lexical ownership rules, not by global regular-expression discovery.

The same principle later mattered for STRUCT placement indexing: a STRUCT-looking line inside a reusable source definition must not become an executable program placement.

---

# 4. The semantic structural model is separate from the CST

The CST owns bytes and nesting.

`EditDocumentModel` gives those blocks meaning.

That separation is intentional:

```text
ScriptCstDocument
    owns exact source spans

EditDocumentModel
    owns semantic interpretation
```

For example, the CST knows a CLIP opening tag and its source span. The edit model knows that its segments mean:

```text
id
source
AT
IN
DURATION
SPEED
```

This allows source-preserving rewrites such as `rewriteClip()` to change only authored fields that actually changed.

Do not merge these two concerns into one giant parser/model object. Source ownership and semantic meaning have different responsibilities.

---

# 5. ScriptNode is the node-editor view, not a second project

`lib/script_nodes.dart` builds a lossless node list for the visual NODES workspace.

Ordinary nodes retain their original raw source slice and emit it unchanged until edited.

Whitespace-only regions become hidden spacer nodes so document coverage remains total.

Protected EDIT/MOSAIC source roots are exposed as visible cards but serialize from their CST-owned source rather than letting the generic node editor reinterpret their nested content.

STRUCT placements are different: they are ordinary reorderable program nodes because their position in TEXT is meaningful sequence state.

The distinction is:

```text
EDIT/MOSAIC root
    reusable structural source definition
    protected nested ownership

STRUCT
    executable main-sequence placement
    reorderable and editable
```

That distinction prevents the node editor from accidentally becoming a second owner of structural source syntax.

---

# 6. Untouched means verbatim

A critical `ScriptNode` rule is:

```text
dirty == false
    → emit rawText exactly
```

This avoids normalization when the user merely opens NODES.

For text-capable tools, semantic equivalence is not always enough. Users may care about:

- comments;
- line layout;
- indentation;
- hand-authored future syntax;
- source-control diffs;
- unusual but valid short forms.

The safest rule is:

> Parsing is not permission to rewrite.

Only the selected owner should generate new source.

---

# 7. CONFIG is document state

`[CONFIG:KEY:value]` is deliberately generic syntax.

The supported key registry lives in `lib/config_keys.dart` so the palette, dropdown, defaults, and field type all derive from one enumeration.

Current examples include presentation and output identity:

```text
[CONFIG:DESKTOP:...]
[CONFIG:APPSWITCH:SLIDE]
[CONFIG:CAPTION:CENTER:22]
[CONFIG:RENDERNAME:documentary_cut]
```

The important architectural point is not the individual settings.

It is that output identity, presentation preferences, and visual configuration can travel with the project because they are authored state, not hidden application preferences.

Unknown CONFIG keys should remain round-trippable even if the current build cannot provide a specialized form.

---

# 8. One compilation pipeline

`lib/script_pipeline.dart` exists because Preview, BAKE, and editor simulation cannot be allowed to implement slightly different preprocessing.

The shared pipeline conceptually performs:

```text
raw document
    ↓
remove/project structural source definitions
    ↓
project executable STRUCT placements
    ↓
optional editor line markers
    ↓
parse CONFIG and macro declarations
    ↓
resolve menu/macro settings
    ↓
expand CALL / MENU_STATE
    ↓
engine-ready text
```

`compileScript()` returns both:

```text
engineText
configs + macro metadata
```

This is important because CONFIG tags are stripped from engine text. A cache or warm-up keyed only by final engine text would miss configuration changes that still affect scene setup.

That is why `CompiledScript.configDigest` exists.

---

# 9. Editor line markers are a projection detail

The editor needs to map runtime execution back to authored lines.

It injects internal `[LINE:n]` markers before macro expansion.

Why before expansion?

Because macro expansion changes line structure. Injecting markers afterward would number generated lines the user never authored.

Why skip comment interiors?

Because adding a marker inside a multiline comment can terminate the lazy comment pattern early and turn remaining comment text into visible program content.

This is a good example of an apparently diagnostic feature changing runtime semantics unless lexical ownership is respected.

---

# 10. Structural source definitions consume no main-program time

EDIT and MOSAIC roots are source definitions.

Their mere presence in the document must not move the terminal cursor or burn project frames.

During real Preview/BAKE compilation, structural roots are replaced by parser-stripped internal comments.

During editor line-map compilation, their newline coordinates are preserved long enough for authored-line mapping, then folded away by preprocessing.

Standalone STRUCT placements are different. They are executable sequence events and are projected into internal timing/region markers.

This distinction was load-bearing in M18 and M20.

---

# 11. Failure modes to recognize

## GUI edit rewrites unrelated text

The mutation probably regenerated an enclosing semantic model rather than replacing one CST-owned span.

## A bracket-looking token inside a CARD becomes structural

Lexical opaque ranges are not being respected.

## Editor Preview differs from BAKE

Check whether both call `compileScript()` and whether line-marker injection or structural projection is implemented twice.

## A CONFIG change does not invalidate a warm simulation

The warm identity may be keyed on `engineText` without `configDigest`.

## A STRUCT inside an EDIT affects program time

Placement discovery is being performed on raw text without excluding structural-root ownership.

## Node mode opens and source-control shows a huge diff

Untouched nodes are being reserialized instead of emitting their original source slices.

---

# 12. Proof

Important proof classes include:

- script/CST parser tests;
- node round-trip tests;
- EDIT compile-projection tests;
- STRUCT placement parser tests;
- CONFIG node tests, including `test/render_name_config_node_test.dart`;
- EditorScreen handoff tests;
- structural marker alignment tests.

A strong test does not merely assert that parsing succeeds. It asserts an ownership rule, for example:

```text
edit one CLIP
→ unrelated bytes remain identical
```

or:

```text
STRUCT-looking metadata inside EDIT
→ does not consume executable placement index
```

---

# Reconstruction checklist

Before building the visual timeline, prove:

- [ ] one document is canonical authored state;
- [ ] structural nested blocks have exact source spans;
- [ ] opaque lexical bodies cannot leak structural tokens;
- [ ] one owned mutation changes only its source span;
- [ ] untouched source round-trips verbatim;
- [ ] GUI nodes can reconstruct entirely from the document;
- [ ] EDIT/MOSAIC definitions do not consume program time;
- [ ] STRUCT placements do consume program time;
- [ ] Preview, editor simulation, and BAKE use one compile pipeline;
- [ ] CONFIG state remains part of project identity even though it is stripped before engine execution.

If these are true, the GUI can become sophisticated without becoming a second project format.