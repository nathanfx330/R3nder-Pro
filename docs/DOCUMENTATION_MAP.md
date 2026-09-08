# R3nder Pro Documentation Map

R3nder Pro now has enough surface area that one document cannot serve every reader well.

The documentation is deliberately split by **job** rather than by historical accident.

The standard is:

> A new user should be able to finish a project without reading internals. A contributor should be able to change a subsystem without guessing who owns what. A competent engineer should be able to reconstruct an NLE with R3nder Pro's capabilities by reading the repository and the reconstruction documentation.

That requires several different kinds of writing.

---

# Start here by role

## I want to use R3nder Pro

Read:

1. [`README.md`](../README.md)
2. [`MANUAL.md`](../MANUAL.md)

The README explains the product and its mental model.

The manual walks from a new workspace through TEXT, EDIT, MOSAIC, STRUCT, PREVIEW, and BAKE.

Do not begin with the architecture documents unless you are trying to change the program.

---

## I know the program and need exact syntax or behavior

Read:

1. [`REFERENCE.md`](REFERENCE.md)

This is the lookup manual: tags, media behavior, export formats, workspace rules, troubleshooting, and architecture notes that are too detailed for the beginner manual.

The reference answers questions of the form:

- What is the exact authored form?
- What does this parameter mean?
- What is the default?
- What is legal here?
- What file/folder does this feature use?
- What happens at runtime?

---

## I want to understand why the architecture looks like this

Read:

1. [`BUILDING_A_DETERMINISTIC_NLE.md`](BUILDING_A_DETERMINISTIC_NLE.md)
2. [`R3NDER_PRO_JOURNEY_TO_STRUCTURAL_VIDEO.md`](R3NDER_PRO_JOURNEY_TO_STRUCTURAL_VIDEO.md)
3. [`M18_M19_STRUCTURAL_PRESENTATION_JOURNEY.md`](M18_M19_STRUCTURAL_PRESENTATION_JOURNEY.md)
4. [`M20_M21_LAST_MILE_JOURNEY.md`](M20_M21_LAST_MILE_JOURNEY.md)

`BUILDING_A_DETERMINISTIC_NLE.md` is the distilled engineering argument: clocks, canonical authored state, media ownership, source hierarchy, readiness, preview/export parity, and debugging method.

The JOURNEY documents preserve chronology, false hypotheses, visual failures, and the reasons certain boundaries became non-negotiable.

These are important because final code often hides the cost of discovering the correct model.

---

## I want to rebuild an editor of this class from the repo

Read:

1. [`RECONSTRUCTION_GUIDE.md`](RECONSTRUCTION_GUIDE.md)
2. [`BUILDING_A_DETERMINISTIC_NLE.md`](BUILDING_A_DETERMINISTIC_NLE.md)
3. [`REFERENCE.md`](REFERENCE.md)
4. the subsystem files and tests named by the reconstruction guide

`RECONSTRUCTION_GUIDE.md` is intentionally different from the lessons document.

Its question is not:

> What did R3nder teach us?

Its question is:

> What must exist, in what order, with what ownership boundaries and acceptance tests, to reproduce an NLE with these capabilities?

That guide is the construction specification.

---

# The documentation layers

## 1. README — product map

**Audience:** everyone.

**Must contain:**

- what the application is;
- the TEXT → EDIT → MOSAIC → STRUCT → PREVIEW → BAKE hierarchy;
- the canonical-state rule;
- installation/run commands;
- documentation entry points;
- current architectural checkpoint.

**Must not become:** a complete syntax reference or implementation diary.

---

## 2. MANUAL — user workflow

**Audience:** a person making a project.

**Must contain:**

- actions in the order a user encounters them;
- what each editor surface owns;
- what the important GUI controls mean;
- enough authored syntax to make the GUI transparent rather than mysterious;
- the distinction between final BAKE and isolated source export;
- render naming/version behavior;
- common user-facing failure modes.

**Must not require:** understanding Flutter, MLT, ProjectClock, CST ownership, or native audio timing.

---

## 3. REFERENCE — exact contract

**Audience:** experienced users and contributors.

**Must contain:**

- accepted syntax;
- defaults;
- ownership rules;
- media path rules;
- timing semantics;
- export formats;
- troubleshooting;
- edge behavior that cannot be inferred safely from the GUI.

The reference is where a claim such as `STRUCT presentation metadata belongs to the placement, not the source definition` gets spelled out precisely.

---

## 4. BUILDING A DETERMINISTIC NLE — transferable lessons

**Audience:** editor/media engineers.

This document explains the principles that survived implementation:

- one authoritative project timeline;
- one canonical authored model;
- exact frame evaluation;
- persistent decode;
- source definitions versus placements;
- source time versus presentation time;
- readiness as visibility rather than timing;
- preview and export answering the same frame question;
- realistic fixtures and semantic regression tests.

It is intentionally broader than R3nder's source tree.

---

## 5. RECONSTRUCTION GUIDE — implementation specification

**Audience:** someone rebuilding the capability.

This is the most important addition for long-term preservation.

Every major subsystem should be documented with the same headings:

```text
Purpose
Canonical owner
Inputs
Outputs
Time semantics
Important data structures
Primary files
Preview path
Bake path
Failure states
Acceptance tests
Build-order dependencies
```

A reconstruction document is not complete because it describes a class name. It is complete when a reader can tell:

- why the class exists;
- which facts it may own;
- which facts it may only observe;
- what frame-number contract crosses the boundary;
- what test demonstrates that contract.

---

## 6. JOURNEY documents — design memory

**Audience:** maintainers and future debuggers.

These preserve the problems that disappear from clean final code.

Examples:

- the M18 one-frame wallpaper flash;
- testing the wrong preview path;
- the difference between decoded and paint-resident readiness;
- generated STRUCT nodes being treated as raw markup in M19;
- source export being mistaken for final program BAKE;
- CUSTOM chrome succeeding in one path and disappearing in real BAKE;
- runtime placement-index divergence caused by differently transformed document views;
- render naming becoming authored CONFIG instead of hidden dialog state.

These are not anecdotes for their own sake. They tell a future engineer what *not* to collapse back together.

---

## 7. Validation documents — measured evidence

Examples:

- [`M4_AV_LOCK_VALIDATION.md`](M4_AV_LOCK_VALIDATION.md)
- [`EDIT_PLAYBACK_PERFORMANCE.md`](EDIT_PLAYBACK_PERFORMANCE.md)
- [`M18_STRUCT_APP_SWITCH_VISUAL_GATE.md`](M18_STRUCT_APP_SWITCH_VISUAL_GATE.md)

These exist when a subsystem has a claim that deserves measured or visual evidence rather than prose alone.

---

# Documentation maintenance contract

A feature is not fully documented merely because its syntax appears somewhere.

When a change lands, ask which layers changed.

## User-visible workflow changed

Update:

- `MANUAL.md`
- `README.md` if the product map changed

## Syntax, defaults, or semantic behavior changed

Update:

- `REFERENCE.md`
- `MANUAL.md` when normal users need to know it

## Ownership, timing, rendering, or source hierarchy changed

Update:

- `RECONSTRUCTION_GUIDE.md`
- `BUILDING_A_DETERMINISTIC_NLE.md` if the lesson is general

## A hard bug changed our understanding of the architecture

Update or add:

- a JOURNEY document
- a targeted validation document when useful

## A new invariant was added

Put it in:

- code comments at the boundary;
- the reconstruction guide;
- at least one semantic regression test.

The test is part of the documentation.

---

# The reconstruction standard

The long-term target for this repository is stronger than “the code is readable.”

Imagine a competent engineer receives:

```text
R3nder-Pro/
```

with no access to the original development conversations.

They should be able to answer, from the repo and docs:

1. What is the canonical project state?
2. Who owns project time?
3. How is project frame N evaluated?
4. How is a media source conformed to project time?
5. How are clips represented, trimmed, split, layered, and transitioned?
6. How are EDIT sequences reused inside MOSAIC?
7. How are EDIT/MOSAIC definitions distinguished from STRUCT placements?
8. How does a STRUCT placement add presentation time without corrupting source time?
9. How do windowed/fullscreen application handoffs work?
10. What does decode readiness change, and what is it forbidden to change?
11. How do editor preview, top-level PREVIEW, and BAKE remain semantically aligned?
12. How is placement-owned chrome authored and expanded dynamically?
13. Why is isolated source export different from program BAKE?
14. How are output names versioned without overwriting earlier renders?
15. Which tests prove each of those claims?

If one of those questions cannot be answered without reverse-engineering large amounts of code, the documentation still has a hole.

---

# A rule for future files

Where practical, source files should begin with a short path comment and then explain their ownership boundary before implementation detail.

Good boundary comments answer:

```text
What does this file own?
What does it deliberately not own?
What is its time unit?
What calls it in preview?
What calls it in bake?
```

The most expensive R3nder bugs were usually ownership mistakes disguised as visual symptoms. Documentation should make those ownership boundaries difficult to miss.

---

# Final principle

R3nder Pro is reconstructable only if the documentation preserves more than API names.

It must preserve the **reasoning boundaries**:

```text
one project time
one authored truth
media below the timeline
sources separate from placements
source time separate from presentation time
readiness separate from time
preview and bake answer the same frame question
presentation metadata belongs to the placement
final export cannot silently destroy earlier output
```

Those are the architecture.

The Dart files are one implementation of it.
