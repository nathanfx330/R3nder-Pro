# R3nder Pro

R3nder Pro is a Linux-first, language-driven motion graphics and video presentation tool.

You write the presentation as a script. The GUI edits that same script. Terminal animation, desktop sequences, source-backed video edits, multi-sequence MOSAIC compositions, audio, preview, and export all resolve against one authored timeline.

There is no hidden project database beside the document.

```text
TEXT
presentation script
   ↓
EDIT
video sequence
   ↓
MOSAIC
composition of whole EDIT sequences
   ↓
STRUCT
places EDIT or MOSAIC into TEXT
   ↓
PREVIEW
runs the finished presentation
   ↓
BAKE
renders it
```

The central rule is simple:

> **The script is the project.**

A GUI action is only durable when it can be written back into the language and reconstructed from that language later. Untouched source stays untouched.

---

## What R3nder Pro does

R3nder began as a deterministic terminal animation engine: type text, pause, flash, draw stencils, open simulated desktop windows, and render the exact result without rebuilding the shot as keyframes in a compositor.

R3nder Pro keeps that model and adds structural video editing without turning the application into a second conventional NLE.

### TEXT

The main presentation is still authored as text.

```text
[SPEED:2]
Connecting to archive.
[PAUSE:20]

[GREEN]Connection established.[NORMAL]
[PAUSE:30]

[STRUCT:EDIT.main]

Retrieving records.
[STRUCT:MOSAIC.wall]

Transfer complete.
```

Plain text types on screen. Tags control timing, formatting, terminal effects, desktop presentations, and structural video placement.

### EDIT

An EDIT is a source-backed video sequence with real timeline manipulation.

You can:

- import normal video files
- trim source IN and OUT
- split clips
- move clips in project time
- work on V1 and V2
- add overlays
- author independent XFADE IN and XFADE OUT transitions
- use longer or custom transition lengths
- preview the result with persistent MLT decoding

Imported video is copied into `<workspace>/video/` and referenced from the script with a portable workspace-relative path.

### MOSAIC

A MOSAIC composes **whole EDIT sequences**, not loose video cuts.

Click an empty pane, choose an `EDIT.<name>` sequence, and it appears as a timeline item inside that pane. Add more EDIT sequences, then move, trim, and crossfade them on the pane timeline.

```text
MOSAIC.wall

PANE 1
[ EDIT.main ][ EDIT.broll ][ EDIT.alt ]
               ↑ XFADE
```

This keeps the hierarchy clean:

```text
media clips live in EDIT
EDIT sequences live in MOSAIC
EDIT/MOSAIC placements live in TEXT
```

### STRUCT

`STRUCT` places a structural video source into the presentation:

```text
[STRUCT:EDIT.main]
[STRUCT:MOSAIC.wall]
```

The source owns its duration. STRUCT does not create a second editable duration field.

### PREVIEW and BAKE

The editor has a live preview pane for authoring. Top-level **PREVIEW** mode is the presentation viewer. They are different interfaces over the same authored project.

**BAKE** renders the finished presentation.

Preview and bake share the same project-time contract. Decoder readiness may delay visibility, but it does not move authored geometry or authored time.

---

## Why the script matters

A conventional editor usually stores the real project in an internal document model and exports text only as an interchange format, if at all.

R3nder does the opposite.

The text document is canonical authored state. The editor, node forms, drag handles, trim handles, MOSAIC panes, contact sheets, and other GUI controls are views over that state.

That has practical consequences:

- projects are readable and diffable
- edits can be version-controlled normally
- opening a structured editor does not normalize unrelated text
- untouched regions round-trip byte-for-byte
- a GUI feature cannot quietly become a second source of truth
- preview, scrub, replay, and export can be asked for the same project frame

The design boundary is intentional: enough direct manipulation to work naturally, without requiring a second mental model beside the script.

---

## Deterministic time

R3nder Pro uses an authoritative `ProjectClock` and explicit `ProjectTime`.

```text
ProjectClock
    ↓
ProjectTime
    ↓
scene at frame N
```

Animation is evaluated from authored time rather than from independent widget or decoder clocks. Native audio can take clock authority during playback, with measured output latency, while MLT remains a decoder rather than a timeline owner.

The public promise is:

> Ask for project frame N, and preview, scrubbing, replay, and export agree on what belongs at N.

The full structural-video engineering history is in [docs/R3NDER_PRO_JOURNEY_TO_STRUCTURAL_VIDEO.md](docs/R3NDER_PRO_JOURNEY_TO_STRUCTURAL_VIDEO.md).

---

## Other presentation tools

Structural video sits beside the original R3nder language rather than replacing it.

The scripting system also supports:

- deterministic terminal typing and pauses
- colors, inversion, redaction, scramble, flash, progress bars, regions, and menu selections
- SVG and raster terminal stencils
- scan-style PHOTO layers
- ASCII sprites
- simulated desktop/window presentation
- image galleries
- image-sequence video windows
- browser windows from page captures
- APP grid and Metro-style image mosaics
- captions and credits
- dossier cards and evidence galleries
- visual timelines
- desktop presentation chaining
- voice and music beds
- H.264, fill-plus-matte, and ProRes 4444 export
- optional preroll/wipe choreography

The complete legacy tag and media-sequence reference is preserved in [docs/REFERENCE.md](docs/REFERENCE.md).

---

# Getting started

## Platform

R3nder Pro is currently developed and validated primarily on Linux.

The current Linux runner requires:

- Flutter with Linux desktop support
- FFmpeg and `ffprobe`
- GTK 3 development files
- `pkg-config`
- PulseAudio simple API development files (`libpulse-simple`)
- Epoxy development files
- MLT, preferably the MLT 7 pkg-config module `mlt-framework-7`
- a normal C/C++ build toolchain and CMake

Distribution package names vary, but the Linux CMake configuration checks GTK, PulseAudio simple, Epoxy, and MLT directly through pkg-config.

## Run from source

```bash
flutter pub get
flutter run -d linux
```

Release build:

```bash
flutter build linux --release
```

Run the repository test suite:

```bash
flutter test
```

---

## Workspaces

R3nder separates scripts from project assets.

Scripts live in the app-level `templates/` directory. A workspace contains the material used by those scripts.

Typical workspace:

```text
workspace/
├── audio/
├── fonts/
├── images/
├── sprites/
├── video/          # created automatically on first video import
├── output_frames/
└── workspace.json
```

On first launch, R3nder creates a default workspace and the normal asset/output folders. The `video/` folder is created when the first external video is imported into EDIT.

The active workspace and per-workspace template/font selection are remembered between launches.

---

# Your first project

For the complete first-project walkthrough, use **[MANUAL.md](MANUAL.md)**.

The shortest path is:

```text
1. Launch R3nder Pro
2. Open EDIT from the main screen to edit the TEXT document
3. Write a small terminal presentation
4. Open the structural video workspace
5. Create an EDIT and ADD VIDEO
6. Trim, split, move to V2, and add XFADEs as needed
7. Create a MOSAIC
8. Click an EMPTY pane and choose an EDIT sequence
9. Add more EDIT sequences and arrange/crossfade them
10. Place the result in TEXT with STRUCT
11. Run PREVIEW
12. BAKE the finished presentation
```

The important distinction is:

> **MOSAIC panes contain EDIT sequences. EDIT sequences contain media clips.**

That is the model the GUI and the language both preserve.

---

## A minimal TEXT script

```text
[#] Comments are stripped before playback.

[SPEED:2]
Connecting to archive.
[PAUSE:20]

[GREEN]Connection established.[NORMAL]
[PAUSE:30]

Retrieving records.
[PAUSE:20]

Transfer complete.
```

At 30 authored project frames per second, `[PAUSE:30]` is one second.

You can make a complete terminal presentation with only plain text and tags. EDIT/MOSAIC/STRUCT are there when the presentation needs source-backed video.

---

## Audio

A workspace can carry a voice bed and a music bed.

They deliberately have different timing roles:

- **Voice** may extend the piece through the terminal end hold so spoken content is not cut off.
- **Music** is trimmed to picture. It may loop to fill the picture, but it cannot extend the presentation.

Preview and bake use the same authored gain relationship. The mix is not silently renormalized when music is attached.

See [MANUAL.md](MANUAL.md) for the user workflow and [docs/REFERENCE.md](docs/REFERENCE.md) for the deeper behavior/reference notes.

---

## Export

R3nder Pro supports:

- **H.264 solid** for a normal opaque working render
- **Fill + matte H.264 pair** for compact alpha workflows
- **ProRes 4444** for true-alpha mastering

Whole-program BAKE can include TEXT, structural EDIT/MOSAIC placements, terminal/desktop presentation, and the workspace audio mix.

Structural sources can also be exported in isolation from the structural video workspace.

---

# Documentation

- **[MANUAL.md](MANUAL.md)**: beginner-first user manual. Start here.
- **[docs/REFERENCE.md](docs/REFERENCE.md)**: complete tag/media/reference manual and architecture notes preserved from the earlier documentation.
- **[docs/R3NDER_PRO_JOURNEY_TO_STRUCTURAL_VIDEO.md](docs/R3NDER_PRO_JOURNEY_TO_STRUCTURAL_VIDEO.md)**: engineering history from ProjectClock through structural video preview/bake parity.
- **[docs/EDIT_PLAYBACK_PERFORMANCE.md](docs/EDIT_PLAYBACK_PERFORMANCE.md)**: EDIT playback performance work.
- **[docs/M4_AV_LOCK_VALIDATION.md](docs/M4_AV_LOCK_VALIDATION.md)**: sustained A/V lock validation.

---

## Current checkpoint

The current structural-video milestone includes:

- authoritative ProjectClock timing
- native audio clock handoff and A/V lock validation
- lossless structural parsing and source ownership
- EDIT/TRACK/CLIP language model
- persistent MLT media decoding
- source-backed EDIT GUI
- V1/V2 editing and overlays
- independent clip edge XFADE IN / XFADE OUT
- MOSAIC pane timelines
- MOSAIC composition from whole EDIT sequences
- structural preview inside the TEXT presentation
- whole-program structural bake/export parity
- regression coverage for authored black gaps and outgoing transition fast paths

At the M17 merge checkpoint, the full Flutter repository suite passed **190 tests**.

---

## Design invariants

If you are changing R3nder Pro rather than using it, protect these first:

1. **The script is the sole authored truth.**
2. **Authored duration is authoritative.** Decoder readiness does not retime the project.
3. **Preview and bake must agree.**
4. **One compile path, one simulation contract.**
5. **MLT decodes media; it does not own project time.**
6. **Untouched source round-trips untouched.**

The deeper rationale belongs in the reference and journey documents rather than in this front page.

---

## License

MIT License

Copyright (c) 2026 Nathaniel Westveer

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.