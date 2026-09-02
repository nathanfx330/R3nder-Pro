# R3nder Pro

**Work in progress.** R3nder Pro is the active development version of R3nder and is currently undergoing a major architectural overhaul.

A motion graphics tool for terminal sequences. You write a script in a small markup language, it plays back deterministically, and it bakes to ProRes 4444 with a real alpha channel. Linux, Flutter, no cloud, no subscription.

It exists because of an inversion I could not stop noticing. Turn on a computer and watch it boot: it draws a terminal effortlessly. Thousands of glyphs a second, perfect monospace, a cursor that blinks on its own, text that scrolls without anyone keyframing it. That is the machine's native handwriting and it costs nothing.

Then try to recreate thirty seconds of it in a compositor. Suddenly you are hand-animating a range selector for the type-on, parenting a rectangle to fake a cursor, precomping a scroll, and rebuilding all of it from scratch for the next shot because none of it generalizes. The easiest thing a computer does is one of the more tedious things to fake, and the tools are time expensive set up similar effects.

So R3nder does not animate a terminal. It runs one, counts frames, and writes them out. A script is a sequence of instructions rather than a stack of keyframes, which means a shot is something you can edit as text, diff, and re-render, and the preview you scrub is frame-identical to the file that lands on disk.

Everything past the terminal (the desktop window manager, the image and SVG stencils, the timelines, the audio bed) grew from the same principle applied to the next thing that needed to happen on screen.

R3nder is **language-first**. The script is the project state and the GUI is a set of authoring views over that state, not a second project format living beside it. A star, divider, dropdown, drag, or form edit in the node workspace is valuable only when it writes an equivalent instruction back into the script; reopening the text must be enough to reconstruct the same authored intent. Untouched source remains untouched. This is the design rule to keep in mind when adding editor features.

## ⏱️ September 2, 2026: explicit time became the architecture

On September 2, 2026, commit `deb2f7e` closed the major state/evaluation migration that began with `ProjectClock`.

```text
ProjectClock
    ↓
ProjectTime
    ↓
scene at frame N
```

Preview, scrubbing, dry runs, and export now share that timing contract. Presentation timing is evaluated from scene phase age, and the terminal systems that once carried their own mutable timing counters now derive visible state from authored timing plus terminal frame age: BAR, IMG, PHOTO, SVG, SVGFLASH, SCRAMBLE, PAUSE and the end hold, and SPRITES.

The migration was not accepted because it compiled. It was checked against reset plus deterministic ticks with evaluation equivalence tests, then exercised at runtime through the semantics that were easiest to break: PHOTO Hold and layering, SVG chaining, SVGFLASH cadence, SCRAMBLE's zero left frame, the audio extended end hold, sprite animation through pauses, PHOTO gate freeze and resume, and exact `SPRITE_OFF` freezing.

This is the point where determinism stopped being only a discipline of advancing the same counters in the same order. The public contract became explicit time: ask for project frame N, and preview, scrub, replay, and export agree on what R3nder should show.

Closing commit: `deb2f7e`, `Evaluate terminal sprites from frame age`.

---

---

## 📖 Documentation

This file is the short version: what R3nder is, what you need, and enough to get a first render out.

Everything operational is in **[MANUAL.md](MANUAL.md)**: the interface tour, the complete tag reference with every parameter and default, the window-managed desktop sequences, the audio bed, exporting, troubleshooting, and the architecture notes. If you are writing a script and need to know what a parameter does, that is the file to keep open.

## ✨ Key Features

* **Strict Determinism:** Exported videos exactly match the timeline of your live preview. No skipped frames, no sync issues.
* **Asynchronous Typing Gates:** Overlap terminal animations! Use the "early-release" parameter on `[IMG]` and `[PHOTO]` tags to start the next text, tag, or image *while* the current one is still drawing across the screen — including stacking `[PHOTO]` layers into an onion-style reveal.
* **Careful Attention To VRAM Leaks:** Frames are painted from scratch and piped directly to FFmpeg via isolates, meaning you can render massive sequences without blowing up your system memory.
* **Simulated OS Environment:** Seamlessly transition from a full-screen terminal to a 2D window-managed desktop (Ubuntu/Yaru themed) to view images, videos, app windows, and animated data panels. App windows offer a uniform tile grid or a Metro-style mosaic of unequal panels that pages horizontally, either kept as a desktop window or maximized to fill the frame.
* **Alpha Channel Export:** Export ProRes 4444 video files with true transparency, ready to drop directly into Premiere Pro, After Effects, or DaVinci Resolve. Or export a fill plus luma matte pair (two H.264 files) that carries the same information at a fraction of the size.
* **Audio Beds:** Attach a voiceover **and** a music track to a workspace, audition the mix against a chosen output sink, and hear it in sync while you scrub the editor. The bake muxes the originals at full quality and sums them without renormalizing, so the balance you rode is the balance in the file. The two slots are deliberately not peers: if the **voice** bed outlasts the script, the terminal's end hold stretches to cover it, so the last line plays out over a live blinking cursor instead of a frozen still. Music is trimmed to picture instead, because no amount of score is a reason to hold on a settled terminal, and because a four minute track under a forty second cut must not produce a four minute file. A short cue can be set to **loop**, which fills the remainder rather than leaving silence and still cannot lengthen anything: the repeat is infinite at the input and cut by the same trim. That is also what makes music free: nothing about it can move a frame boundary, so attaching, looping, or re-gaining a score costs no re-simulation.
* **Green-Screen Preroll:** Optional chroma-key preroll (green or magenta) with a terminal wipe-on reveal, for keying workflows in your NLE.
* **Selective Pane Life:** `[CONFIG:PANELIFE:ON]` enables the capability; it does **not** animate every MOSAIC pane. Motion is authored on the `[APP]` tag by grouping consecutive source images into visual panes and explicitly marking a ★ hero with `@HERO`, for example `3@2-LR;1-FIT;2@2-RL`. A selected one-image pane gets the familiar slow push. A selected multi-image pane walks its images in `LR` or `RL` order and gives the nominated hero the push/emphasis. Panes without `@HERO` stay static. Selected panes divide only the hold the page already owns, so Pane Life never extends the piece.
* **Browser Windows:** `[BROWSER]` opens a generic web browser on the desktop holding page screenshots, one per page. A page turn is a navigation rather than a fade: the address bar cuts to the next URL and a load bar sweeps the viewport, because that is the only transition a browser has. Long captures scroll inside the hold the page already owned, so a page twenty screens tall costs the same frames as one that fits. The URL and the page title cannot live in a tag segment (a URL spends two colons before it says anything) so they sit in the `.r3nder_captions` sidecar beside the images, the same place captions do and for the same reason. `SCROLL_FULL` and its siblings maximize the window, keeping the tab strip and address bar at full height: a browser without its chrome is a photograph of a webpage.
* **Photo Captions:** A MOSAIC panel can carry a label on its plate: caption above, credit line under it, smaller and dimmer. The band is not an overlay on the photograph, it is the picture rect deflated so the plate shows through, so nothing is covered and the panel's outline still wraps image and text as one unit. Captions live in a `.r3nder_captions` sidecar beside the images rather than in the script, are switched on per image, and are suppressed automatically on a panel too small to carry one legibly.
* **Pane Fit:** A pane token can end in `-FIT` or `-FITW`, scaling that pane's images to its **vertical** or **horizontal** edge instead of cropping to fill. A source that already matches is unaffected, since fitting the long edge is the scale a cover fit would have picked anyway; a source the other way round letterboxes against the panel plate rather than losing its ends, which is what a portrait scan, a full document page, or a panorama needs. Independent of Pane Life in both directions, cycled per pane from the contact sheet, and it changes no frame counts.
* **Hold Extensions:** A pane token can end in `+45`, holding one image that many frames longer. The only authored pane fact that lengthens the piece, and deliberately independent of Pane Life so that the exporter's frame-neutrality audit keeps working. Authored per image from the contact sheet profile.
* **App Switching:** `[CONFIG:APPSWITCH:SLIDE]` turns two adjacent APP tags into one window with more pages, so the transition is the horizontal pan MOSAIC already uses rather than a window closing and another opening. Like switching workspaces instead of quitting an application. Each page keeps the hold and title it was written with.
* **Workspaces:** Point the same script at different asset workspaces to produce different finished pieces.
* **Picks Up Where You Left Off:** The active workspace, and the template and font last used *with that workspace*, are restored on launch. Switching workspaces restores that workspace's own pairing rather than dropping you on whatever happens to sort first.
* **Asset Manager:** Scans your script for every referenced image, folder, and sprite; flags what's missing; reports how many files each folder actually holds; and lets you import assets by **dragging files straight from your file manager** onto the app.
* **Integrated Script Editor:** Live preview with frame-exact scrubbing, click-to-jump (click a script line, the preview jumps to it), search, and an inline RGB color picker. The editor opens on a simulation prepared in the background while you were reading the menu, so the timeline ribbon is complete on the first frame instead of arriving a second later. The node workspace is deliberately **a GUI around the script**, not a parallel document model: typed controls, asset contact sheets, MOSAIC pane dividers, ★ hero toggles, LR/RL controls, and FIT toggles all serialize back into the same language, while untouched source round-trips byte-for-byte.
* **Phosphor-Adaptive UI:** The entire control surface re-tints to match your selected phosphor color (green, amber, cyan, white).
* **Zero External Dependencies:** No pub packages beyond the Flutter SDK essentials. The SVG parser, raster thresholder, and OS drag-and-drop bridge are all built in.

---

---

## 🚀 Getting Started

### Prerequisites
1. **Linux** (primary target; developed on Ubuntu and Rocky Linux).
2. **Flutter SDK** installed and running on your system.
3. **FFmpeg** installed and accessible in your system's `PATH`. (`ffprobe` too: it is what reads bed durations.)
4. **PulseAudio (`paplay`) or ALSA (`aplay`)** for audio bed *preview* playback. Optional: baking needs no sink, so a machine with no sound card still exports audio correctly, mix included.

### Templates vs. Workspaces
R3nder separates **recipes** from **ingredients**:

* **Templates** (your `.txt` animation scripts) live at the app root in `templates/`. They never move.
* **Workspaces** hold everything else — images, fonts, sprites, and bake output. The active workspace is selected in the main menu (CREATE WS / OPEN WS), persists across launches, and can live anywhere on disk.

This means the same script can be pointed at different workspaces to produce different finished pieces: same choreography, different assets.

The pairing is remembered. R3nder stores the active workspace, and per workspace the last template and font, in `.r3nder_session.json` beside the executable. Templates are recorded by filename rather than by list position, so adding or renaming one never silently reassigns your selection, and a template that has been deleted falls back visibly instead of loading the wrong file.

```text
/your-project-root         # The portable app folder: wherever the binary lives
 ├── /templates            # Your .txt animation scripts (app-level, shared)
 ├── .r3nder_session.json  # Active workspace, and per-workspace template/font
 ├── r3nder_error.log      # Written only when something goes wrong
 └── r3nder_trace.log      # Pane Life bake audit, plus optional profiling

/any/workspace/path
 ├── /fonts                # .ttf or .otf fonts (defaults to monospace)
 ├── /images               # Wallpapers, SVGs, IMG/PHOTO stencils, and
 │                         #   Gallery/Video/App/Dossier/Stage subfolders
 │   └── /any_image_folder
 │       ├── .r3nder_order     # Authored sequence for this folder
 │       └── .r3nder_captions  # What the pictures are (caption + credit)
 ├── /sprites              # ASCII art .txt files
 ├── /audio                # Voiceover / music beds (wav, flac, mp3, m4a,
 │                         #   aac, ogg, opus, aif, aiff)
 ├── workspace.json        # Per-workspace settings (the voice and music beds)
 └── /output_frames        # FFmpeg exported videos land here
```

On first launch, R3nder auto-creates `default_workspace/` next to the app and scaffolds all subfolders.

Audio is an ingredient, not a recipe: both beds are properties of the workspace, never of the script. Nothing about audio appears in the markup, so pointing the same template at a different workspace picks up that workspace's voiceover and its score.

Two dotfiles can sit inside any image folder, and they follow the same principle from the other direction. `.r3nder_order` records the sequence you arranged the folder into; `.r3nder_captions` records what the photographs are, a caption and a credit line per file. Both are optional, both are plain text you can hand edit, and both travel inside the folder they describe, so moving or copying a workspace carries them with it. The script owns composition, the folder owns provenance: the same scan used in two films carries the same date and the same collection line, and neither belongs in the choreography.

### First Run
1. Launch R3nder (`flutter run` or a built binary).
2. Hit **EDIT** — if no templates exist, one is created for you with starter text.
3. Type, watch the live preview, hit **SAVE**, then **BACK**.
4. Hit **PREVIEW** for a full-speed run, or **BAKE** to export video.

### Your first script

Everything that is not a tag is typed on screen, one character at a time, in order. That is the whole model. Tags interrupt to change how the typing behaves or to take over the screen for a while.

```
[#] Comments are stripped before anything runs.
[CONFIG:WINTITLE:operator@field-terminal: ~]

[SPEED:2]
Connecting to archive.
[PAUSE:20]

[GREEN]Connection established.[NORMAL]
[PAUSE:30]

[#] Take over the screen with a stencil, then come back to typing.
[SVG:logo.svg:90]

Retrieving records.
[PAUSE:15]

[#] Leave the terminal entirely for a desktop window, then return.
[GALLERY:evidence:120:FADE:Archive Viewer]

Transfer complete.
```

To run it: put `logo.svg` in `<workspace>/images/`, put a few images in `<workspace>/images/evidence/`, then EDIT, paste, SAVE, BACK, PREVIEW.

Four things worth taking from that example:

* **Order is time.** There is no timeline to arrange. The script runs top to bottom and the frame count falls out of it.
* **`[PAUSE:n]` is your only timing control between events,** measured in frames at 30fps. `[PAUSE:30]` is one second.
* **Some tags return to the terminal, some leave it.** `[SVG]` and `[IMG]` draw on the terminal screen itself. `[GALLERY]`, `[APP]`, `[BROWSER]`, `[CARD]`, `[DOSSIER]` and `[TIMELINE]` zoom out to a window-managed desktop and then come back.
* **Assets are named, not linked.** `evidence` means the folder `images/evidence/`. Nothing embeds, nothing has an absolute path, and moving the workspace moves everything with it.

---

## Where to go next

You have a workspace and a script that runs. From here:

* **[Syntax & Tag Reference](MANUAL.md#-syntax--tag-reference)** for the full tag list. Every parameter, every default, optional trailing ones marked as such.
* **[Desktop OS & Media Sequences](MANUAL.md#-desktop-os--media-sequences)** for galleries, app windows, cards, dossiers, and timelines. These leave the terminal and have the most moving parts.
* **[Exporting to Video](MANUAL.md#-exporting-to-video)** before your first real bake, particularly the note on when alpha is and is not meaningful.
* **[Troubleshooting](MANUAL.md#-troubleshooting)** when something plays as a hole in the timing rather than an error. That is by design, and the table says where the app already tried to tell you.

If you are changing the code rather than writing scripts, read **[Invariants](#-invariants)** below first.

---

## 🧱 Invariants

Rules the codebase leans on that are easy to break by accident, because
breaking them produces symptoms nowhere near the cause. Each is documented at
its definition too; this is the index.

Where the same knowledge has to appear twice, it gets a registry instead.
`config_keys.dart` is the single list of `[CONFIG:...]` keys, read by both the
node dropdown and the ADD NODE palette, because those were the two places that
enumerated them by hand and either one being forgotten fails silently.

### The script is the authority

R3nder is a program built around a language. The text document is the canonical
authored state; the GUI is a structured way to read and edit it. Do not add
creative state that exists only in a widget, painter, cache, or editor-side
model. If an author can make a meaningful choice in the GUI, that choice must
have a script representation, and loading that script again must reconstruct
the same choice.

This is also why node editing is lossless. Parsing a document does not grant the
GUI permission to rewrite it. A node keeps its original source span verbatim
until that node is actually edited; then only the edited construct is
serialized. The same rule applies to visual authoring controls such as MOSAIC
pane breaks and Pane Life stars: they are language controls with a graphical
hit target, not hidden metadata.

### One compile, one simulation

`compileScript()` in `script_pipeline.dart` is the only path from a document to
the text an engine runs: comment stripping, macro expansion, and (for the
editor) `[LINE:n]` injection. `runEditorSimulation()` in `editor_warmup.dart` is
the only path from that text to a measured timeline.

Preview, bake, the editor, and the dashboard warm-up all route through both.
That is not tidiness. Determinism is the one promise this tool makes, and two
implementations of "the same" transformation agree right up until they do not,
at which point the preview shows frames the export will never produce. A local
shortcut that recompiles or re-simulates on the side is how that promise breaks
quietly.

Anything that can move a frame boundary belongs in `ScriptWarmKey`: the
compiled text, both asset directories, the font, size, leading, tracking, both
margins, the bed length, and the colors. The key is deliberately eager to
invalidate. A key that changes too readily costs a cold open. One that changes
too rarely serves a confident lie.

### Every positional segment must resolve

Tag grammar is positional, so reaching segment N means emitting every segment
before it. If one of those resolves to nothing, `_emitTag` writes a bare `::`,
which `tagRegex` rejects, so the whole construct stops matching and types onto
the screen as literal text. The document still round-trips and the node panel
still looks right; the damage only appears in the render.

Every `_Opt` that can be followed by another therefore needs a non-empty `def`
or `fallback`, and `_emitTag` asserts it. That assertion found two live bugs the
day it was added: `[TIMELINE]` with a thumbnail width but no stage, and
`[PHOTO]` with a release but no tint. Both grammar groups
(`[a-zA-Z0-9_\-/]+` and `\d+,\d+,\d+`) are incapable of matching empty, so
both tags had been silently breaking.

`[APP]` is seven segments deep and `panes` sits at the end. The next tail makes
this more likely, not less.

### The image cache hands out clones

`SceneEngine` keeps a static, LRU-capped cache of decoded images and built
stencils, keyed on path plus modification time plus size. Editing a script does
not touch that key; replacing a file on disk does, with nothing to remember.

**The cache owns the original. Every caller of `_loadImage` receives a
`clone()` and owns it.** Flutter reference-counts these, so disposing the
original leaves outstanding clones valid and frees pixels only when the last
handle goes. That property is what makes eviction safe while a warm engine, a
preview engine, and the editor may all hold the same file.

Break it in either direction and the damage lands somewhere unrelated. Forget
to dispose a clone and you leak on every setup, which is often. Dispose the
shared original instead and you tear a live texture out from under two other
engines, and the blank gallery shows up in a feature you were not touching.

`disposeImages()` releases one engine's handles. `clearAssetCache()` drops the
originals, and is called on workspace switch.

The stencil cache alongside it is capped by entry count with the same LRU rule.
Counted rather than measured, because a `Path` exposes no size and a byte figure
would be a guess dressed as a number.

### Motion never extends a hold

`[CONFIG:PANELIFE:ON]` only enables Pane Life. Selection lives in the APP pane
language: a pane token without `@HERO` is static, while a token with `@HERO`
opts that pane into motion. This distinction must survive parser → request →
scene state → motion plan; `null` hero is meaningful and must never silently
become image zero.

Pane FIT travels the same parser → request → scene state path but is applied
downstream of the motion plan rather than inside it, because a pane fits its
vertical edge whether or not it moves and whether or not Pane Life is enabled
at all. Several branches of the pane frame lookup return an identity motion to
mean "this pane is not animating", which is a statement about motion and not
about scaling, so fit is stamped once at the boundary where every one of those
branches has already returned.

Only **selected** panes divide `holdFrames`. One starred pane gets the whole
page hold, two split it, three split it three ways; unstarred panes consume no
Pane Life slot. The budget is still `cascadeTotalFrames + holdFrames`, which the
page already owned and which decides when it advances. Nothing new is scheduled,
so toggling Pane Life selection, direction, or fit cannot re-time a finished page. Two things are allowed to change duration and both are explicit: grouping, which changes how many pages there are, and a `+FRAMES` hold extension, which is a request for more time rather than a side effect of a look. Pane
grouping is a separate structural edit: because it can change the number of visual
panes and therefore the number of pages, changing grouping can legitimately
change the APP's total duration.

The exporter checks this on every bake rather than leaving it to be remembered.
After the dry run that establishes the frame count, if Pane Life is enabled a
second dry run executes with it forced off, from the same engine and the same
decoded assets. Both totals go to `r3nder_trace.log` as a `[panelife]` line. A
mismatch is reported, not thrown: the export is not wrong, it is a different
length than the design promised, and that is worth knowing rather than worth
failing a render over.

`_ActiveApp.rebuildPanePlan()` keeps every selected slot inside that existing
budget. If the hold is too short to give each selected pane the minimum readable
move, Pane Life is skipped for that page rather than buying itself more room.

A one-image selected pane preserves the original centred slow push. A grouped
selected pane walks its consecutive source images in authored `LR`/`RL` order;
only its nominated hero receives scale emphasis. Cover-fit crop bias is clamped
inside the source, so directional movement cannot expose an empty image edge.

The verification remains a bake before, a bake after, and a duration diff.

### Voice owns the length, music does not

A workspace can attach two beds and they are not peers. The voice bed's length
in frames is the single integer that crosses into the render path, because a
trailing voiceover line is content and the end hold stretches to let it finish.
Music is trimmed to picture by the exporter's output `-t`, and that same trim is what makes an infinite `-stream_loop` finite when a short cue is set to repeat.

That asymmetry is load bearing in three places. It is what keeps the
single-integer boundary contract intact through a second track. It is why music
is absent from `ScriptWarmKey`, so attaching or re-gaining a score costs no
re-simulation, and adding that call for symmetry would silently make every music
edit as expensive as a script edit. And it is why the ribbon clamps the music
lane at picture end while letting the voice lane run to the edge: the same
picture means dead air on one and discarded frames on the other.

The sum lives in `audio_mix.dart`, read by both the preview player and the
exporter, which are otherwise unrelated code paths. `normalize=0` is the part
that matters: `amix` defaults to dividing by the input count, so attaching a
score would drop the voice 6dB with no fader moved and nothing said. Two hot
tracks can therefore clip, and the gain faders are the answer. A limiter would
be an opinion about someone's mix, applied invisibly.

### Measure before you guess

`diag.dart` writes to `r3nder_trace.log` in the app folder, and works in release
builds, which matters because R3nder is normally built rather than run. Two
`const bool` flags feed it, both false, both compiled away when off:

* `kProfileSetup` in `scene_engine.dart` breaks `setup()` into phases: text
  layout, wallpaper, folder decode, SVG parse, stencil build, sprites, total.
* `kProfileWarm` in `editor_warmup.dart` reports every warm-up build and the
  editor's adopt-or-discard decision, with both keys when they disagree.

They are kept rather than deleted for a specific reason. Reading this code
produced three confident and wrong answers about where a slow editor open was
going: a layout shift, a duplicated simulation pass, a cold warm-up. Switching
the first flag on found the real one, a serial `await` loop over image decodes,
in a single run. The second found a warm-up that was building against
`"monospace"` because the font list loaded asynchronously after it, a failure
invisible from the outside because a broken warm and an absent warm look
identical.

Turn them on before forming a theory, not after.

---

## ⚖️ License

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