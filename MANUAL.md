# R3nder Pro Manual

This is the user manual for R3nder Pro.

The goal is simple: get from a fresh launch to a finished render without requiring you to understand the parser, the clock, or the internal video engine first.

R3nder is language-first. The script is the project. The GUI is a set of editors over that same script. When you trim a clip, move something to V2, build a MOSAIC, or change a structured source, the authored result is written back into the document. There is no second hidden project format that becomes authoritative when you enter an editor.

For the complete tag reference, older media-sequence documentation, troubleshooting tables, and architecture notes, see **[docs/REFERENCE.md](docs/REFERENCE.md)**.

---

## The mental model

There are six things to understand before you start:

```text
TEXT
The presentation itself: terminal text, tags, pauses, and STRUCT placements.

EDIT
A video sequence. Media clips live here on tracks such as V1 and V2.

MOSAIC
A composition made from whole EDIT sequences.

STRUCT
Places an EDIT or MOSAIC into the TEXT presentation.

PREVIEW
Runs the finished presentation.

BAKE
Renders the finished presentation to a file.
```

The distinction between **EDIT** and **MOSAIC** matters:

> A MOSAIC pane contains whole EDIT sequences, not loose video cuts.

That one rule keeps the hierarchy understandable:

```text
media file
   ↓
EDIT sequence
   ↓
MOSAIC pane
   ↓
STRUCT placement
   ↓
TEXT presentation
   ↓
BAKE
```

---

# 1. Install and run R3nder Pro

## What you need

R3nder Pro is currently a Linux-first Flutter application.

You need:

* Flutter with Linux desktop support
* FFmpeg and `ffprobe`
* GTK 3 development files
* PulseAudio simple API development files (`libpulse-simple`)
* Epoxy development files
* MLT, preferably MLT 7 with the `mlt-framework-7` pkg-config module
* A normal Linux C/C++ build toolchain and CMake

Those native dependencies are not optional for the current Linux build. R3nder uses MLT for persistent video decoding and the PulseAudio simple API for native audio playback timing.

The Linux build checks for GTK, `libpulse-simple`, Epoxy, and MLT through pkg-config. If any of those are missing, CMake will stop and tell you which module it could not find.

## Run from source

From the repository root:

```bash
flutter pub get
flutter run -d linux
```

To make a release build:

```bash
flutter build linux --release
```

Before shipping or after a substantial change, run the test suite:

```bash
flutter test
```

---

# 2. Workspaces and scripts

R3nder separates the reusable script from the assets used by a particular project.

A workspace normally contains:

```text
workspace/
├── fonts/
├── images/
├── sprites/
├── audio/
├── video/
├── output_frames/
└── workspace.json
```

Scripts live in the application's `templates/` directory. The active workspace can live somewhere else on disk.

On first launch, R3nder can create a default workspace and its normal subfolders. You can also create or open a workspace from the main screen.

The important rule is this:

> The script owns composition. The workspace owns the material the script points at.

Video imported through the EDIT workspace is copied into the workspace so the authored script can refer to a portable workspace-relative source instead of an arbitrary path somewhere else on your machine.

---

# 3. The main screen

The main screen is the front door to the program.

The controls you will use first are:

* **EDIT**: opens the script editor. This is the TEXT authoring view and includes a live preview pane.
* **PREVIEW**: runs the finished presentation as a viewer. This is not the same thing as the preview pane inside the script editor.
* **BAKE**: renders the finished presentation.
* **ASSETS**: checks the assets referenced by the script.
* **AUDIO** controls: attach the workspace voice bed and music bed.

The editor also gives you access to structural video authoring. That is where EDIT sequences and MOSAIC compositions are created.

## Editor preview versus PREVIEW mode

These names are easy to confuse.

**Editor preview** is the picture beside the script while you are editing text. It exists so you can type, click lines, scrub, and see where the document lands.

**PREVIEW mode** is the top-level presentation viewer. It runs the piece as a presentation rather than as a text-editing workspace.

Both are looking at the same authored project. They are different interfaces, not different versions of the timeline.

---

# 4. Make your first TEXT presentation

Open **EDIT** from the main screen.

Start with something small:

```text
[#] My first R3nder project

[SPEED:2]
Connecting to archive.
[PAUSE:20]

[GREEN]Connection established.[NORMAL]
[PAUSE:30]

Retrieving records.
[PAUSE:20]

Transfer complete.
```

Plain text types onto the terminal. Tags in square brackets change behavior.

For this first script, you only need to know three tags:

* `[SPEED:2]` types two characters per frame.
* `[PAUSE:20]` holds for twenty project frames.
* `[GREEN]` and `[NORMAL]` change and restore the text color.

R3nder runs at an authored 30 fps, so `[PAUSE:30]` is one second.

Save the document.

Use the editor transport to play and scrub it. You can also click a line to jump the preview to the frame owned by that part of the script.

At this point you already have a valid R3nder presentation. You could return to the main screen and BAKE it now.

The rest of this tutorial adds edited video.

---

# 5. Make your first EDIT

An **EDIT** is a source-backed video sequence. It is not the main presentation timeline.

Open the structural video workspace from the editor and create or select an EDIT.

The first useful workflow is:

```text
EDIT
→ ADD VIDEO
→ select clip
→ TRIM IN / TRIM OUT
→ SPLIT if needed
→ move between V1 and V2
→ add XFADE IN / XFADE OUT
→ PLAY
```

## Add video

Use **ADD VIDEO** and choose a video file.

R3nder imports the file into the workspace and authors a CLIP in the selected EDIT. If there was no EDIT yet, adding the first video can create the first usable edit surface for you.

A simple authored EDIT looks roughly like this in the script:

```text
[EDIT:main]
  [TRACK:V1]
    [CLIP:interview:video/interview.mp4:0:0:120:1]
    [/CLIP]
  [/TRACK]
[/EDIT]
```

You do not need to type that by hand. The GUI is there to author it for you. It is shown here so you can see what the GUI is editing.

The important numbers belong to the authored project. The decoder does not get to decide where the clip starts or how long it lasts.

## Select and trim

Click a clip in the timeline.

The clip controls show its source IN, source OUT, and cut length.

Use:

* **TRIM IN** to move the left edge later while advancing source IN with it.
* **TRIM OUT** to shorten or extend the right edge within the available source.
* **SPLIT** to divide the clip at the playhead.

The project-time position and source-time position remain separate facts. That is what lets a trimmed clip move without losing the part of the source you selected.

## V1 and V2

R3nder supports layered video tracks.

Select a clip on V1 and use **TO V2** to move the whole authored CLIP block to V2. Select a V2 clip and use **TO V1** to move it back.

Moving tracks preserves the clip's authored source, trim, speed, and edge transitions.

Use **ADD OVERLAY** when you want to introduce new media directly on V2 at the current playhead.

A basic overlap looks like this:

```text
V2          [ clip B ]
V1    [       clip A       ]
       ───────────────────── time
```

That overlap is what lets an incoming fade on B blend picture A into picture B instead of fading B up from black.

## XFADE IN and XFADE OUT

Transitions belong to clip edges.

Right-click near the **left edge** of a clip for **XFADE IN**.

Right-click near the **right edge** for **XFADE OUT**.

The normal choices include longer, visibly testable fades such as 12, 24, 48, and 72 frames, plus a custom frame count and CLEAR.

Incoming and outgoing transitions are independent. One clip can have both.

The visual rule is:

```text
isolated XFADE IN    black → picture
isolated XFADE OUT   picture → black
clip over clip       picture → picture
```

The diagonal hatch marks on the clip edges show the authored transition extents.

## Play the EDIT

Use **PLAY** in the structural workspace to watch the selected EDIT.

This is an isolated structural-source preview. The main TEXT presentation's narration and music mix belong to the presentation layer, so do not use isolated EDIT playback to judge the final program mix.

When the EDIT feels right, leave it as a named structural source such as:

```text
EDIT.main
```

---

# 6. Make your first MOSAIC

A **MOSAIC** combines EDIT sequences into one or more pane timelines.

This is the hierarchy to remember:

```text
EDIT.main
EDIT.broll
EDIT.alt
   ↓
MOSAIC.wall
```

MOSAIC does not ask you to re-edit the media inside those EDITs. It treats each EDIT as a complete structural source.

## Create the MOSAIC

Choose **NEW MOSAIC**.

Pick a layout:

* **1 PANE**
* **2 PANES**
* **3 PANES**

Each pane has its own small timeline.

An empty pane reads **EMPTY**.

## Click EMPTY

Click the empty pane.

R3nder opens a chooser listing the EDIT sequences already authored in the document, for example:

```text
EDIT.main       240 FRAMES
EDIT.broll      180 FRAMES
EDIT.alt         96 FRAMES
```

Choose one.

The whole EDIT appears on the pane timeline as a single sequence item.

This is the key MOSAIC rule again:

> You are adding `EDIT.main`, not copying one cut out of `EDIT.main`.

Internally, the authored source is structural:

```text
[CLIP:edit_main:EDIT.main:0:0:240:1]
[/CLIP]
```

The generated clip id is an internal address. The timeline shows the useful name: `EDIT.main`.

## Add another sequence

Use **ADD SEQUENCE** in that pane and choose another EDIT.

Now the pane can look like:

```text
0────30────60────90────120────150
[      EDIT.main       ]
                  [      EDIT.broll      ]
```

## Move and trim sequences

MOSAIC panes are real mini timelines.

You can:

* drag a sequence horizontally to change its project-time position
* drag its left edge to trim the sequence IN
* drag its right edge to trim the sequence OUT
* click the ruler to seek
* use the pane playhead
* change timeline zoom

Trimming a structural sequence does not rewrite the original EDIT. The MOSAIC clip selects a range from the EDIT in exactly the same way an EDIT clip selects a range from a media source.

That means `EDIT.main` can be used in several MOSAICs, or several times in one MOSAIC, without destructively changing the EDIT itself.

## Crossfade between sequences

Between adjacent sequence items is the MOSAIC cut/transition control.

Choose a crossfade length such as 24 or 48 frames.

R3nder authors real project-time overlap between the adjacent sequence clips. The overlap is not just a visual decoration in the GUI.

For a three-sequence pane:

```text
[ EDIT.main ]
          [ EDIT.broll ]
                    [ EDIT.alt ]
      XFADE       XFADE
```

Changing an earlier crossfade keeps the downstream sequence continuous instead of accidentally opening a gap later in the pane.

Choose **HARD CUT** to remove the overlap and return to contiguous timing.

## Multiple panes

A 2- or 3-pane MOSAIC gives each pane its own authored timeline.

The pane layout controls spatial composition. The clips inside each pane control that pane's time.

The MOSAIC's total frame count comes from the authored structural sources and their project-time placement. It is not a second editable duration field.

When the MOSAIC feels right, it exists as a named source such as:

```text
MOSAIC.wall
```

---

# 7. Put EDIT or MOSAIC into the presentation with STRUCT

EDIT and MOSAIC definitions are source definitions. They do not automatically play in the TEXT presentation.

A **STRUCT placement** is the instruction that says: play this structural source here.

To place an EDIT:

```text
[STRUCT:EDIT.main]
```

To place a MOSAIC:

```text
[STRUCT:MOSAIC.wall]
```

For example:

```text
[SPEED:2]
Opening visual record.
[PAUSE:20]

[STRUCT:EDIT.main]

Record complete.
[PAUSE:20]

[STRUCT:MOSAIC.wall]

End of file.
```

The `[EDIT:...] ... [/EDIT]` and `[MOSAIC:...] ... [/MOSAIC]` definitions are structural source definitions. They consume no TEXT presentation time by themselves.

`[STRUCT:...]` consumes presentation time because it actually plays the source.

## What STRUCT looks like

A structural placement has presentation choreography around the source:

```text
zoom out
→ open structural window
→ show source
→ close structural window
→ zoom back in
```

The source's own authored duration remains authoritative. The presentation adds its entry and exit choreography around that source rather than inventing a second duration setting.

If the first authored source frame is black because the EDIT begins with a gap or fade, R3nder holds that black honestly. It does not skip ahead to the first decoded picture.

---

# 8. Check the finished presentation

At this point, use both preview surfaces for what they are good at.

## TEXT editor preview

Use the editor preview while changing the script.

Check:

* the STRUCT placement begins on the line you expect
* the entry and exit choreography is correct
* an incoming fade begins from the correct picture or black
* the presentation returns to TEXT at the right time

## PREVIEW mode

Return to the main screen and choose **PREVIEW**.

Use PREVIEW to watch the finished program rather than the script-writing interface.

This is the place to judge the presentation as a presentation.

If PREVIEW and BAKE disagree about authored frame N, that is a bug. The design contract is that authored time belongs to the project, not to whichever decoder happened to be fastest on that run.

---

# 9. Bake your first finished project

Return to the main screen and choose **BAKE**.

BAKE renders the whole TEXT presentation, including STRUCT placements.

This is different from exporting an isolated structural source from the EDIT workspace.

Use:

```text
BAKE
```

when you want the finished R3nder presentation.

Use the structural workspace's isolated export only when you specifically want the selected EDIT or MOSAIC as its own rendered source.

R3nder supports three main video output approaches:

1. **H.264 solid**: normal opaque MP4 output.
2. **Fill + matte**: two H.264 files carrying color and alpha information separately.
3. **ProRes 4444**: large mastering output with an alpha channel.

For a first test, use the simplest opaque output unless you specifically need alpha.

The important validation is not the codec. Watch the rendered file and confirm that the same EDIT trims, V1/V2 overlaps, edge transitions, MOSAIC timing, and STRUCT choreography you saw in preview are present in the bake.

That completes the first project:

```text
TEXT
→ EDIT
→ MOSAIC
→ STRUCT
→ PREVIEW
→ BAKE
```

---

# 10. Audio

Workspace audio belongs to the main presentation.

R3nder has two audio roles:

* **Voice bed** can extend the presentation's end hold so narration is not cut off.
* **Music bed** is trimmed to picture and cannot lengthen the project.

The distinction is intentional. A voiceover can contain content that still needs time. A score is accompaniment and should not create extra picture simply because the file is longer.

The music bed can loop to fill the remaining picture without extending it.

Preview and bake use the same authored project timing. Native audio playback is used to keep the live presentation locked to the project clock, while FFmpeg muxes the source audio during export.

For full audio-bed setup, gain behavior, looping, output-sink selection, and mix details, see **[Audio Bed in the reference](docs/REFERENCE.md#-audio-bed)**.

---

# 11. Assets

Use **ASSETS** from the main screen to see whether the document's referenced files and folders resolve in the current workspace.

The asset manager is especially useful for the traditional R3nder tags such as GALLERY, APP, BROWSER, IMG, PHOTO, SVG, DOSSIER, and TIMELINE.

Structural EDIT video is imported into the workspace through the video editor so the script can remain portable.

R3nder deliberately avoids turning missing media into timing changes. A missing source is an error or diagnostic, not permission for the project timeline to collapse around it.

For the full asset manager, folder sidecars, captions, image ordering, and drag-and-drop behavior, see **[The Interface in the reference](docs/REFERENCE.md#-the-interface)**.

---

# 12. The scripting language

You can use R3nder without memorizing the language, but the language is always there and remains the canonical project state.

The structural video vocabulary is:

```text
[EDIT:name]
  [TRACK:V1]
    [CLIP:id:source:at:in:duration:speed]
    ...
    [/CLIP]
  [/TRACK]
[/EDIT]

[MOSAIC:name]
  [PANE:pane1]
    [CLIP:id:EDIT.some_edit:at:in:duration:speed]
    [/CLIP]
  [/PANE]
[/MOSAIC]

[STRUCT:EDIT.name]
[STRUCT:MOSAIC.name]
```

The GUI is the preferred way to author detailed EDIT and MOSAIC geometry. The markup exists so the project is inspectable, diffable, reconstructable, and not trapped inside widget state.

For the terminal language and all traditional R3nder tags, use the complete reference:

**[Syntax & Tag Reference](docs/REFERENCE.md#-syntax--tag-reference)**

---

# 13. Common problems

## ADD SEQUENCE is not what I expected

Inside a MOSAIC pane, **ADD SEQUENCE** means add a whole EDIT sequence.

If you want another raw media file, go back to an EDIT and use **ADD VIDEO** or **ADD OVERLAY** there.

Think:

```text
EDIT adds media.
MOSAIC adds EDITs.
```

## I clicked an empty MOSAIC pane and nothing useful is listed

A MOSAIC can only offer EDIT sequences that already exist in the document.

Create an EDIT first and give it authored frames.

## My MOSAIC item says EDIT.main instead of edit_main

That is correct.

`EDIT.main` is the user-facing structural source.

`edit_main` is only the generated internal clip id used to address that placement inside the pane.

## My fade goes from black instead of another clip

An isolated clip fades against black.

For a picture-to-picture crossfade, the outgoing and incoming sources must overlap in project time.

Use V1/V2 overlap in EDIT, or the between-sequences XFADE in MOSAIC.

## The beginning of a STRUCT source is black

If the authored source begins with a gap or an incoming fade, black is correct. R3nder does not skip authored empty time to find a picture.

## I hear no workspace narration while playing an isolated EDIT

The main voice and music beds belong to the TEXT presentation mix. Isolated structural playback is for the structural source itself.

Use the finished TEXT presentation preview to judge the main program mix.

## PREVIEW and BAKE do not match

That should be treated as a bug, not as normal decoder behavior.

Record the source, the project frame where they disagree, and whether the mismatch occurs in EDIT, MOSAIC, STRUCT presentation, or the terminal layer.

## A tag types itself as literal text

The grammar did not recognize it as a valid tag. Check the editor lint strip and the full troubleshooting reference.

**[Full troubleshooting table](docs/REFERENCE.md#-troubleshooting)**

---

# 14. What to learn next

Once you have completed the first TEXT → EDIT → MOSAIC → STRUCT → BAKE project, the rest of R3nder becomes much easier to place.

Use the deep reference for:

* terminal effects and formatting
* GALLERY and legacy image-sequence VIDEO tags
* APP and browser windows
* Pane Life and APP MOSAIC image layouts
* cards, dossiers, and timelines
* asset sidecars and captions
* audio-bed internals
* alpha export workflows
* troubleshooting
* architecture and determinism notes

**[Open the complete reference](docs/REFERENCE.md)**

---

## 🪟 Desktop OS & Media Sequences

The complete documentation for GALLERY, legacy image-sequence VIDEO, BROWSER, APP, cards, dossiers, timelines, presentation chaining, Pane Life, captions, and related window-managed presentation features now lives in **[docs/REFERENCE.md](docs/REFERENCE.md#-desktop-os--media-sequences)**.

---

## 📝 Syntax & Tag Reference

The complete terminal and presentation tag reference is in **[docs/REFERENCE.md](docs/REFERENCE.md#-syntax--tag-reference)**.

---

## 🎥 Exporting to Video

The deeper format, alpha, matte, preroll, and audio-mux documentation is in **[docs/REFERENCE.md](docs/REFERENCE.md#-exporting-to-video)**.

---

## 🔧 Troubleshooting

The full symptom/cause table is in **[docs/REFERENCE.md](docs/REFERENCE.md#-troubleshooting)**.

---

## 🏗️ Architecture Notes

The architecture notes are intentionally outside the beginner path. They are useful when changing R3nder, not required to use it.

See **[docs/REFERENCE.md](docs/REFERENCE.md#-architecture-notes)** and **[docs/R3NDER_PRO_JOURNEY_TO_STRUCTURAL_VIDEO.md](docs/R3NDER_PRO_JOURNEY_TO_STRUCTURAL_VIDEO.md)**.
