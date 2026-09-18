# CUE Overlap Authoring Policy Journey

Parser / runtime
: Existing overlapping CUEs remain parseable and deterministic.

GUI cue authoring
: Creation and duration edits reject new same-lane occupied-range overlap.

Clip geometry
: Slip, trim, and speed remain independent and may later create overlap through source-to-project rounding. That is permitted.

Resolver-aware diagnostics
: Current workspace state can report resulting overlap without turning filesystem-dependent truth into source lint.

## Why this is a policy, not a document invariant

A CUE authors only a source-relative trigger. CARD, SIDECARD, and MAXIMIZE have deterministic project-frame presentation lifetimes, but DOSSIER lifetime can depend on the number of evidence pages currently present in its workspace folder. Adding an image can therefore change DOSSIER occupied time without changing one byte of script source.

The GUI can truthfully prevent an overlap using the workspace state it can see at authoring time. The parser cannot truthfully declare the same document invalid without acquiring an external asset dependency, so it does not.

## Hybrid timing

CUE occupied ranges are half-open project intervals:

    [startFrame, endFrameExclusive)

The start is projected from the authored source frame through the CLIP's current IN and exact rational speed. The duration is already a project-frame quantity owned by the presentation timing model.

That hybrid is intentional. It also means a later slip, trim-IN, or speed edit can change the rounded distance between two triggers even when neither CUE changes.

The authoring policy does not guard those CLIP operations.

## Collision lanes

Presentation lane:

- CARD
- SIDECARD
- DOSSIER

Shell lane:

- MAXIMIZE

Same-lane intersection is rejected while authoring a new CUE or changing a CUE duration. Exact abutment is legal.

CARD/SIDECARD/DOSSIER do not block MAXIMIZE. MAXIMIZE blocks another MAXIMIZE.

## No visibility clamp

The occupied range is not clamped to its source CLIP, the authored EDIT duration, or a parent container.

Presentation CUEs may continue after the CLIP that triggered them has ended. Reusable EDITs may also be truncated differently when embedded in other structural sources. A container-specific visibility clamp would make the authoring answer depend on where the EDIT happened to be viewed.

The policy therefore uses one unbounded EDIT-timeline projection everywhere.

## DOSSIER dependency seam

The range projector never opens folders. DOSSIER duration is injected as an already-resolved project-frame count.

The EDIT UI obtains that duration from the same asset-backed page-count and DOSSIER timing authorities used by structural Preview and BAKE. Unit tests can instead inject a constant duration and stay filesystem-free.

## Legacy overlap and diagnostics

Historical or hand-authored overlap still parses and plays. The old stacking-order runtime test remains, with its intent changed from supported GUI authoring to runtime tolerance.

A separate resolver-aware diagnostic projection scans current occupied ranges and reports same-lane overlap. It is not ScriptLinter or EditGraphLinter. This distinction matters because the same unchanged script can gain or lose a DOSSIER overlap when workspace assets change.

The EDIT surface displays these diagnostics as warnings. They do not rewrite source.

## Regression boundary

The test suite protects both halves of the design:

- exact abutment is accepted
- same-lane intersection is rejected on creation
- duration expansion into a neighbor is rejected
- CARD and MAXIMIZE may overlap
- CARD/SIDECARD/DOSSIER mutually block
- edit self-comparison is excluded by exact CUE source offset
- inert CUEs outside the current CLIP source window block nothing
- DOSSIER diagnostics change with injected resolved duration
- overlap is checked across all clips in the EDIT
- legacy overlapping source remains deterministic at runtime
- a rational-speed slip may turn legal abutment into overlap, the slip remains permitted, and diagnostics report the result

That last test is deliberate documentation. If it starts failing because slip becomes blocked, the cue authoring policy has leaked into CLIP geometry.
