# Render Outputs, Naming, and Version Safety

This page defines the final-output contract for R3nder Pro.

A finished render is not an incidental filename chosen by the application. Its identity is project-authored state, and a successful BAKE must never silently destroy an earlier render.

Primary files:

- `lib/render_naming.dart`
- `lib/config_keys.dart`
- `lib/exporter.dart`
- `lib/main.dart`

Representative tests:

- `test/render_naming_test.dart`
- `test/render_name_config_node_test.dart`
- `test/scene_exporter_structural_mosaic_custom_end_to_end_test.dart`

---

## Contract

Render output must guarantee:

- a project can author its own render base name;
- the render name travels with the template/document;
- filenames are sanitized into portable stems;
- versions increase monotonically;
- deleted version gaps are not reused;
- MP4/MOV variants belong to the same version family;
- fill/matte pairs reserve one version together;
- preroll and non-preroll families are distinct;
- existing files are never silently overwritten;
- ffmpeg itself is configured to refuse overwrite as a final safety barrier;
- direct low-level `SceneExporter` callers that deliberately choose a filename are not unexpectedly versioned unless they use the dashboard output family.

---

# 1. Render identity is authored state

The project can contain:

```text
[CONFIG:RENDERNAME:documentary_cut]
```

This is intentionally a normal CONFIG key.

That means render identity follows the same architectural rule as the rest of R3nder:

> The script is the project.

The name travels with the template, survives copy/version control, and is editable from the same first-class CONFIG node UI as other project metadata.

A hidden export-dialog preference would be weaker because the same template opened on another machine could lose its expected output identity.

---

# 2. Dashboard naming contract

The dashboard still constructs its historical internal request shape:

```text
output_1080p.mp4
output_4k.mov
preroll_output_1080p.mp4
```

`SceneExporter` recognizes only that dashboard family as eligible for automatic project-authored versioning.

It then converts the request into a planned render path.

Example:

```text
[CONFIG:RENDERNAME:documentary_cut]

first 1080p H.264 bake
→ documentary_cut_1080p_v001.mp4

second bake
→ documentary_cut_1080p_v002.mp4
```

This compatibility seam matters because tests and lower-level tools also call `SceneExporter` directly with deliberate output names. Those callers should not suddenly receive renamed files.

---

# 3. Sanitizing human names

`sanitizeRenderName()` accepts a human-authored label and creates a portable filename stem.

Conceptually it:

- trims whitespace;
- removes a trailing `.mp4`/`.mov` if the user typed one;
- converts unsupported runs to `_`;
- collapses repeated underscores;
- removes leading/trailing punctuation separators;
- falls back to `output` if nothing usable remains.

Examples:

```text
Documentary Cut
→ Documentary_Cut

  final / review : cut  
→ final_review_cut

.mp4
→ output
```

The authored string can remain friendly. Filesystem safety is handled at the output boundary.

---

# 4. Versioning is monotonic, not first-hole-wins

Suppose the output folder contains:

```text
cut_1080p_v001.mp4
cut_1080p_v003.mp4
```

The next render is:

```text
cut_1080p_v004.mp4
```

not v002.

Why?

Because render versions are history labels, not merely collision slots.

Reusing a deleted hole makes later references ambiguous and makes it easier to confuse an old v002 with a newly generated v002.

`render_naming.dart` scans the whole render family, finds the maximum existing version, and increments from there.

---

# 5. Container changes do not restart version history

The version family is based on:

```text
render name + resolution + preroll identity
```

not on file extension.

If these exist:

```text
cut_1080p_v001.mp4
cut_1080p_v002.mov
```

then the next bake is v003 regardless of which supported container is chosen.

That keeps version numbers about editorial history rather than codec choice.

---

# 6. Fill/matte pairs reserve one version

Luma-matte export produces two files:

```text
cut_1080p_v005.mp4
cut_1080p_v005_matte.mp4
```

They are one logical render.

The planner therefore checks both names before reserving a version.

If either member already exists, that version is occupied.

Do not independently version fill and matte. A mismatched pair is much harder to use safely in an NLE and makes automation error-prone.

---

# 7. Preroll is a separate family

Preroll output carries a distinct family stem.

Example:

```text
cut_1080p_v003.mp4
preroll_cut_1080p_v001.mp4
```

This allows a project to maintain ordinary and preroll histories independently.

The preroll prefix is project-output identity, not merely an encoder flag.

---

# 8. Two layers of no-overwrite protection

Planning an unused version is not sufficient by itself.

Another process can create the planned path after scanning but before ffmpeg opens the file.

R3nder therefore protects output twice.

## Application-level check

Immediately before FIFO/encode setup, `SceneExporter` checks whether the final output or matte path now exists.

If so, export fails before writing frames.

## ffmpeg-level check

ffmpeg is invoked with:

```text
-n
```

rather than:

```text
-y
```

So the encoder itself refuses to replace an existing file.

The principle is:

> Never rely on only one layer to protect destructive output.

---

# 9. Successful output paths are returned explicitly

`ExportResult` returns:

```text
outputPath
mattePath, if any
```

The dashboard reports the actual written versioned path rather than assuming its original `output_1080p.*` request remained unchanged.

This matters because naming policy belongs inside the exporter boundary for dashboard BAKEs.

A caller must treat `ExportResult.outputPath` as authoritative after export.

---

# 10. Render output belongs inside the active workspace

Dashboard BAKE lands next to the assets/template that produced it inside the active workspace setting folder.

That keeps:

```text
project state
assets
render history
```

spatially related.

A reconstruction may choose a different folder structure, but output ownership should be explicit and project-relative rather than a process-global “last export directory” if reproducibility is a goal.

---

# 11. Failure modes to recognize

## Second BAKE overwrites the first

Either version planning was bypassed or ffmpeg is still running with `-y`.

## Deleting v002 causes next BAKE to become v002

The planner is choosing the first free slot instead of `max(existing)+1`.

## Switching H.264 to ProRes resets to v001

The extension has incorrectly become part of version-family identity.

## Fill is v004, matte is v005

The pair was planned independently instead of reserving one logical version.

## User types a path separator into RENDERNAME

Sanitization must keep the result a filename stem, not allow authored output names to escape the intended directory.

## Custom render name works in UI but BAKE still writes `output_...`

Trace the canonical document passed as `structuralDocument` into `SceneExporter` and verify `renderNameFromDocument()` sees the live editor buffer.

---

# 12. Proof

`test/render_naming_test.dart` should cover pure naming semantics such as:

- sanitization;
- fallback;
- monotonic versions;
- gap skipping;
- extension-independent families;
- pair reservation;
- preroll separation.

`test/render_name_config_node_test.dart` proves the value is first-class CONFIG-authored state.

The encoded SceneExporter test proves the real BAKE path consumes RENDERNAME while still producing a valid encoded structural render.

The GUI visual gate is simple but important: bake the same project twice and verify both files remain present with incrementing version numbers.

---

# Reconstruction checklist

- [ ] render base name is canonical project state;
- [ ] human name is sanitized only at filesystem boundary;
- [ ] versions are `max(existing)+1`;
- [ ] deleted gaps are not reused;
- [ ] extension does not define version history;
- [ ] fill/matte pairs share one version reservation;
- [ ] preroll has a distinct family;
- [ ] planned output is rechecked immediately before encode;
- [ ] ffmpeg refuses overwrite independently;
- [ ] exporter returns the actual final path;
- [ ] dashboard surfaces the actual path to the user;
- [ ] low-level callers with deliberate filenames are not unexpectedly renamed.

With these rules, repeated BAKE becomes safe enough to use as an editorial workflow rather than a destructive one-shot operation.