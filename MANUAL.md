# R3nder Manual

The operating manual for R3nder. For what R3nder is, what it needs installed, and a first script to paste in, see **[README.md](README.md)**.

---

## Using this document

* **The Interface** tours the app: Main Menu, Script Editor, Script Ribbon, Node Workspace, and Asset Manager. These are authoring views over the language, not a second project format: meaningful GUI changes write back into the script.
* **Audio Bed** covers attaching a voiceover and a music track. It sits early because attaching a voice bed changes how long the piece runs, so it is not purely an export-time concern. Music does not, and the section says why that difference exists.
* **Desktop OS & Media Sequences** goes deep on the window-managed tags: galleries, video, browser windows, app windows, cards, dossiers, timelines, and chaining. These leave the terminal, have the most parameters, and the most that can go quietly wrong.
* **Syntax & Tag Reference** is the complete tag list. This is the section to keep open while writing.
* **Exporting to Video** covers the three output formats, alpha, and the preroll wipe.
* **Troubleshooting** collects the failure modes that are silent at author time into one table.
* **Architecture Notes** explains why things work the way they do. Not needed to use R3nder, but it is where the reasoning lives if you are modifying it.

Two conventions hold throughout. Tag parameters are written in the order they appear in the markup, with optional trailing parameters noted as such. And where a tag has a failure mode that is silent at author time, it is called out where that tag is documented rather than left for you to find in a bake.

---

## 🎛️ The Interface

### Main Menu
* **Status strip:** active workspace, document selector, and a live asset tally (green = all assets resolved, red = missing count).
* **TYPE panel:** font selection plus size, leading, and tracking (drag anywhere on a slider row to adjust).
* **FRAME panel:** margins, resolution (1080p / 4K), and the four phosphor presets — Green, Amber, Cyan, White. Picking a phosphor re-tints the entire UI.
* **AUDIO panel:** voice bed and music bed selection, a gain fader for each, output sink, and audition (see the Audio Bed section). The panel header reports the state that decides what you do next: NO BACKEND, NO BED, PROBING, UNREADABLE, or a good bed with its length, channel count, and frame count. The music row carries its own readout with the same states.
* **Transport row:** Preroll toggle, SETTINGS, ASSETS, EDIT, PREVIEW, and the hot **BAKE** button.
* **Macro Menu Controller:** appears automatically when the loaded script defines interactive menus (see the Macro Menus section).

A script's `[CONFIG:FG:...]` / `[CONFIG:BG:...]` / `[CONFIG:SIZE:...]` tags override the menu's color and size settings when the template loads.

### Script Editor
* **Live preview pane** simulates the full scene (including desktop sequences) as you type, with a 250ms debounce.
* **Click-to-jump:** click any line in the script and the preview jumps to the exact frame where that line executes. The currently-executing line is highlighted during playback and scrubbing.
* **Transport bar:** play/pause plus a frame-exact scrubber with frame and seconds readout.
* **Script ribbon:** a strip above the transport showing how the piece is blocked out over time. The top lane is one skinny rectangle per node; below it sit the audio lanes, one for the voice bed and one for the music bed, when those are attached. Drag anywhere to seek, and the script view scrolls to follow. Double-click a block to jump into the node workspace with that node open and ready to edit. Deliberately its own lane rather than drawn over the scrubber: the scrubber answers "where am I" and the ribbon answers "what is this made of", and stacking them would degrade the first to fit the second.
* **Full-frame preview:** `F11` hides the script pane and gives the whole workspace to the picture. The ribbon and transport stay: watching a cut you cannot scrub, or read the pacing of, would be a smaller view rather than a bigger one. `Esc` gives the script back before it closes the editor, and there is a toggle beside the search icon for the same thing. It is `F11` rather than a bare letter because the script field is focused and character keys reach it: a bare `F` would toggle the view and type an `f` into the document.
* **Search:** `Ctrl+F`, with match count and next/previous navigation.
* **Inline color picker:** any `R,G,B` value in a tag renders as a clickable swatch; click it to open an RGB editor and write the new value back into the script.
* **Lint strip:** bracketed constructs the grammar does not match get flagged in the gutter and named in a warning strip you can click to jump to. This catches the failure mode the markup is otherwise silent about: an unmatched tag is not an error, it just types itself on screen. `[CYAN]` is the classic, since cyan is a phosphor preset but not a text color token. Malformed positional tails (a `TIMELINE` stage with no heading, a `PHOTO` release with no tint) and unclosed body tags are caught the same way.
* **ESC** closes search, then the editor. Unsaved changes still drive the menu state (macro controller, configs, asset scan) so nothing feels stale — but remember to SAVE to write to disk.

### Language-first authoring
R3nder is a program built around its scripting language. The script is the canonical project state; the text editor, node forms, contact sheets, drag handles, and other GUI controls are different ways of reading and editing that same state. There is no separate hidden composition document that becomes authoritative when you enter node mode.

That creates a simple test for editor features: **can the choice be represented in the script, and can the GUI reconstruct itself from that script?** If not, the feature is storing creative intent in the wrong place. A MOSAIC ★ is therefore not a decorative selection flag held by the widget; it writes `@HERO` into the APP pane token. A pane divider writes grouping. An LR/RL control writes direction. Reloading the text must reproduce all three.

The reverse rule matters just as much: parsing a script does not give the GUI permission to normalize or rewrite it. Untouched nodes keep their original source spans verbatim. The GUI is allowed to make the language easier to author, not to quietly become a competing representation of it.

**The stated exception: composition lives in the script, provenance lives with the assets.** Two things are deliberately not in the markup, and they are the same kind of thing. A folder's authored order lives in `.r3nder_order` inside that folder, and a photograph's caption and credit live in `.r3nder_captions` beside it. Neither is a creative choice about the shot. They are facts about the material: what sequence these scans are in, what this picture shows, which collection it came from. The same folder pointed at two scripts, or two cuts of the same film, should carry the same answers, and duplicating them into every script that touches the folder would guarantee they drift.

The test above still applies to everything else. If a choice is about the piece, it goes in the script and the GUI must reconstruct itself from it. If it is about the asset, it travels with the asset. When you are unsure which side something falls on, ask whether re-cutting the film should be able to change it.

### Script Ribbon
The strip is proportional to frames, not one equal block per node. Equal blocks would show node *order*, which the script view already shows, in a form that reads left to right instead of top to bottom. Proportional blocks show *pacing*, which nothing else in the app shows at all. Seeing that one `DOSSIER` eats a third of the runtime is the reason to build it, so the widths have to be honest.

Which means nodes that consume no frames get no block. `[COLOR:RED]`, `[SPEED:5]`, `[ALIGN:LEFT]` and their kin take no time, and a time axis is the wrong place for things that take no time. Giving them a minimum width so they were clickable would make every other block slightly wrong. They leave no gap, because they occupy no time to leave a gap in.

Both lanes share one axis. The total already covers the bed, because the engine stretches its end hold to reach it, so the audio visibly running past the last block **is** the overhang: the gap between where the script stops and where the audio stops is your dead air on a blinking cursor. Scaling the lanes independently would destroy the only thing worth reading.

The music lane is the exception, and it is an exception on purpose. Nothing stretches for a score, so a music track longer than the piece is cut by the bake rather than held for. Drawing it past the last block would show frames that will not be in the file. So the lane stops at picture end and the surplus is reported as amber ticks over the tail: *this continues and is discarded*. The same picture in the two lanes therefore means opposite things, which is exactly why they are not drawn alike. Voice running long is work you still owe. Music running long is normal.

The strip is two lanes with one bed attached, three with both, and one with neither. Height is decided by what is actually attached, so a workspace with a score and no narration gets a music lane directly under the script rather than a gap where a voiceover would have been.

The tail belongs to no node. During the end hold the engine returns from its tick before touching the read head, so every hold frame still reports the last line of the script. Walking those would hand the entire tail to whichever node happened to be last, and a long voiceover can make that tail minutes. The engine exposes an `inEndHold` flag (a flag, not a frame number: the terminal's own frame count stops while a window presentation suspends it) and the ribbon simply stops there.

Blocks carry a document **index**, not a `ScriptNode.id`. Ids come from a global counter that never resets, so parsing the same text twice yields two disjoint sets and an id cannot cross between the ribbon's parse and the node panel's. Inside the node panel ids stay correct, because they have to survive inserts and deletes; index only works as a cross-parse address.

### Node Workspace
The editor has a second mode that presents the script as a vertical list of nodes with a properties panel, so tags become forms instead of colon-delimited strings.

* **Typed controls:** frame counts are sliders with nudge arrows, enumerations are dropdowns, colors are swatches that open an RGB picker, and folder or file parameters are pickers listing what actually exists in the workspace. A reference that resolves to nothing is badged `MISSING` on the node row.
* **Positional guardrails:** several tags have tails that can only be set in order (a `TIMELINE` stage requires a heading, a thumbnail width requires a stage, a `PHOTO` release requires a tint override). The form disables each control until its predecessor is set, so it cannot produce a tag the parser would silently fail to match.
* **Structural editing:** add nodes from a filtered palette of every tag, delete, duplicate, and drag to reorder.
* **Asset previews:** any field naming a file or a folder renders what it points at, right in the panel. A single file shows a thumbnail with its pixel dimensions and size; a folder shows a contact sheet of up to twelve thumbnails with a `+N` tail and the true file count. Rasters decode at thumbnail size, so a folder of 4K stills costs the image cache thumbnails and not full plates. SVG stencils are drawn through the same parser the engine renders with, background-plate culling and fill-rule inference included, so a stencil that reads as a solid block in the preview will read as a solid block in the bake. Sprites show frame 0 of their text file.
* **Cap warnings:** `IMG` tiles cap at 512px and `PHOTO` scans at 1024px on either axis, and over the cap the runtime plays the tag as a dud with its timing preserved. That is a failure with no visible symptom until you bake, so an oversize source is badged `OVERSIZE` in amber on the preview instead.
* **Drop to import:** drag files or a folder from your file manager and drop them straight onto an asset field. No click first: the drop lands where you aimed it, the field under the cursor lights up while you drag so you can see where it will land before you let go, and the whole field is the target, not just the bar at the bottom of it. Files are copied into the workspace and the field is pointed at them. A file field takes one file into `images/` (or `sprites/`); a folder field takes any mix of files and directories. Dropping a single folder onto an *empty* folder field names the destination after the dropped folder, so a folder of stills onto a blank `GALLERY` node is one move. Loose files onto an empty field prompt for a name. Anything the field cannot draw is skipped and counted rather than copied, and a name collision suffixes rather than overwrites: R3nder never deletes anything.
* **Lossless round-trip:** the node list covers the whole document, and every node emits its original text verbatim until you actually edit it. Opening node mode and touching nothing leaves the file byte-identical, and editing one node rewrites exactly that node's span. Blank lines, comments, indentation, and anything the form does not model all survive untouched.
* **MOSAIC contact-sheet authoring:** for an `APP` using `MOSAIC` or `MOSAIC_FULL`, the folder preview also edits the pane language directly. Thumbnails remain draggable for source order. The narrow pane divider between thumbnails splits or merges visual panes; the ★ on a thumbnail toggles that image as the pane's single Pane Life hero; a selected multi-image pane exposes `LR`/`RL` to choose which end of its ordered run is visited first. Page dividers remain a separate control because `pages` and `panes` are separate language facts. Hero selection and LR/RL never add time; pane grouping can change the number of visual panes and therefore, under the default three-panes-per-page rule, can change how many page holds/pans the APP contains. Every one of these edits is serialized into the APP tag immediately.

*A field can also be **pinned** with the control on its drop bar. A pinned field catches drops that land on no field at all, on the node list or on empty panel, where there is nothing under the cursor to resolve to. One field is pinned at a time, and it is a fallback rather than a requirement: dropping directly on a field always goes to that field, pinned or not.*

A folder field also reads any `[#NEEDS:folder:N]` directive in the live document, including unsaved edits, and flags a contact sheet that has come up short against it. See the Asset Manager section for what that directive does.

### Asset Manager
Open via **ASSETS** on the main menu. R3nder scans the loaded script for every asset reference — gallery/video/app/dossier/stage folders, card images, SVG files and folders, IMG/PHOTO stencils, sprites, and the desktop wallpaper — and resolves each against the active workspace:

* **OK** — exists. Single-file assets show `OK`; folders instead report how many usable files they hold (`9 FILES`).
* **MISSING** — not on disk.
* **EMPTY FOLDER** — the folder exists but has no usable content (the runtime would treat this as a dud).
* **N OF M** — the folder has content but fewer files than the script declared it needs (see below).

Folder rows also carry a short line saying what the count will actually produce, for example `6 IMAGES: GRID FILLS ONE SCREEN, MOSAIC MAKES 2 PAGES`. A folder holding a single image is flagged in amber, because one image satisfies "not empty" while almost never being what the shot wanted.

#### Declaring how many files a folder needs
Nothing in the markup says how many images belong in a folder. `[APP:yearbook:60:Matches:MOSAIC]` names a folder, not a count, and any count renders legitimately. To have the manager hold you to a number, declare it in a comment:

```text
[#NEEDS:yearbook:9]
```

The engine never sees this: comments are stripped before the tag parser runs. The asset manager reads the raw script, so it does. A folder that comes up short reports `6 OF 9`, explains how many are missing, and counts toward the missing tally on the main menu. Folders with no directive behave exactly as they always have.

Problems sort to the top. Hit **IMPORT** on any missing asset, then either:

* **Drag and drop** the file (or a folder, or a multi-selection of files) from your file manager anywhere onto the R3nder window — the import happens instantly, or
* Type/paste a source path manually. (Blank path on a folder asset just scaffolds the empty folder.)

Dropping a whole folder onto a folder asset copies every file inside it, which is usually what you want. Dropping a single file copies just that one.

The manager also lists **unreferenced files** sitting in your workspace, so you can keep projects clean. R3nder never deletes anything.

Asset fields in the editor's node workspace accept the same drops, so you can fill a reference without leaving the script. There you drop directly onto the field you mean and no IMPORT step is needed, because that panel resolves the drop by position. This dialog does not: hitting IMPORT already named the destination, so a drop anywhere on the window means this one asset. The `[#NEEDS:...]` count above is read in the node panel too, against unsaved edits.

The menu's asset tally refreshes on every template load, editor close, workspace switch, and asset-manager visit — so you always know before you bake.

*Note: audio beds are managed from the AUDIO panel on the main menu, not here. The asset manager scans the script, and the script never mentions audio.*

---

## 🔊 Audio Bed

Drop a voiceover or a music track into the workspace `audio/` folder and pick it in the **AUDIO panel**. R3nder writes both selections to `workspace.json`, so they travel with the assets they belong to and survive a workspace switch.

There are two slots and they are **not** peers. The voice bed decides how long the piece is; the music bed does not. Everything else about them is the same, including the folder they come from, so the difference is worth reading before you use the second one. See *Which track owns the length* below.

* **Bed:** the voiceover. Dropdown of every readable file in `audio/`. Pick **None** to detach. **Rescan** re-lists the folder after you add a file without restarting.
* **Gain dB:** -40 to +12, applied by FFmpeg's `volume` filter. The preview and the bake use the same filter, so the level you hear scrubbing is the level that lands in the mux. The bed is deliberately **not** peak-normalized: normalizing would make the preview lie about the mix.
* **Music:** the score. Same folder, same list, different role. Nothing stops you picking the same file for both, which is a mix decision rather than an error.
* **Music dB:** the same range and the same filter. This fader and the one above are the only controls over the balance, on purpose: the sum does not renormalize, so riding these two **is** the mix.
* **Loop:** repeat the score until the picture ends. **Looping fills, it never extends.** The repeat is infinite at the input and finite at the output trim, so it changes what plays under the last stretch of a piece and changes no frame count at all. That is what keeps looping outside the warm-up key along with everything else about music: turning it on costs no re-simulation. Off by default, and a workspace written before looping existed reads with the behavior it was authored against.
* **Output:** enumerated sinks by name, not by guessed index. Re-enumerated on **Refresh**, because USB interfaces and Bluetooth sinks come and go while the app is open. The choice is stored per machine (`.r3nder_audio_device`), not per workspace, since a sink name is a property of the box you are sitting at.
* **Test:** a short tone straight to the selected sink. On a multi-sink Linux box the system default is frequently not the one with speakers attached, and this is how you find out in two seconds instead of twenty minutes.
* **Audition:** plays **the mix** from the menu without launching a preview. There is one Audition and one Rescan rather than a pair of each, because the point of a second track is the relationship between the two. Soloing is what pulling the other fader to -40 does.

### Which track owns the length

The voice bed stretches the piece. When the script exhausts before the voiceover does, the terminal's **end hold stretches** to cover the remainder, so a trailing line plays out over a live blinking cursor rather than a frozen still. A trailing line is content, and cutting it off would be wrong.

Music is **trimmed to picture**. Nothing stretches for a score, and the bake cuts it at the last frame. That is the designed behavior and not a limitation: a four minute track under a forty second cut must not produce a four minute file, and no amount of music is a reason to hold on a settled terminal. A score is normally longer than the shot it plays under.

When it is shorter, **Loop** fills the remainder rather than leaving silence. This is the only music control that changes what is heard rather than how loudly, and it still cannot change how long anything is: the loop is infinite at the input and cut by the same trim, so a thirty second cue under a three minute voiceover plays six times and the piece stays three minutes.

Two consequences worth knowing:

* **Music is free.** Because it cannot move a frame boundary, it is not part of the warm-up key. Attaching a score, swapping it, or riding its fader costs no re-simulation at all, unlike a change to the voice bed, which moves the total frame count and rebuilds.
* **The two ribbon lanes read differently.** In the editor the voice lane running to the right edge means dead air you still owe choreography for. The music lane is clamped at picture end instead, and any surplus is drawn as amber ticks over the tail, meaning frames the export will discard. Drawing them the same way would give one picture two meanings.
* **A looping lane reads differently again.** With Loop on, the music lane runs the full width because the score plays under every frame, and each repeat boundary is marked with a hairline so the lane says how many times the cue comes round. A short lane there would show silence the file will not contain. The repeat marks are dropped when they would sit closer together than they are wide, since a sting looping two hundred times is a solid block either way.

### How the two are summed

One FFmpeg process, one `amix`, in both the preview and the bake. Two pipelines would be two wall clocks fighting over one sink, drifting against each other differently on every scrub.

The sum runs with `normalize=0`, which is load bearing. FFmpeg's default divides by the number of inputs, so attaching a score would drop the voice 6dB on its own, with no fader moved and nothing said, and the balance you rode would not be the balance you baked. The honest cost is that two hot tracks can sum past full scale and clip, which is what the two gain controls are for. A limiter here would be an opinion about your mix, applied to every mix, and invisible in the one place the mix is supposed to be audible.

The spelling of that sum lives in `audio_mix.dart` and is read by both the preview player and the exporter. They are otherwise unrelated code paths, and this is the one fact both have to agree on.

### How it stays deterministic
The engines never learn that audio exists. `TerminalEngine` and `SceneEngine` do not import the audio library, do not observe it, and are not aware of it. Exactly one integer crosses back into the render path: the **voice** bed's length in frames, computed once from a probe before frame 0 is drawn. Music contributes nothing here, which is what makes the single-integer contract survive a second track.

That integer does one thing, described under *Which track owns the length* above. Because it is a fixed number known before the first tick, `reset()` plus N ticks still reproduces any frame, and the exporter's dry run returns the extended total without special-casing anything.

### Two unrelated consumers
1. **Preview and editor.** Wall-clock playback, an authoring aid only. FFmpeg decodes and seeks, `paplay` (or `aplay`) sinks, and the two are piped process to process so nothing is held in memory. A 30 minute voiceover costs no RAM and starts instantly instead of blocking the UI on a decode. FFmpeg owns the seek via `-ss`, which makes click-to-jump and scrubber drags close to free. Both tracks take the same seek: they are locked to one timeline, and seeking one without the other would put the score somewhere the picture never was. Editor playback is also trimmed at picture end, so scrubbing cannot imply a musical tail the file will not contain.
2. **Export.** Never touches the preview player at all. FFmpeg takes the original files as further inputs and muxes them, so the bake gets full source quality and full channel count regardless of what the preview pipe resampled to. Frame-exactness is automatic: video is engine-locked and audio carries its own timebase.

Both beds start on the frame the terminal engine first ticks, which is after the wipe with Preroll on and frame 0 without it. The exporter finds that frame in its dry run rather than hardcoding a preroll length, and it is the identical test the live preview uses to fire playback, so the two cannot drift apart. In the mux the offset is written as real silence (`adelay`), not as a container `start_time`, so tools that ignore `start_time` cannot slam the voiceover to zero and play it underneath the green.

A file FFmpeg cannot open reports as an amber **UNREADABLE** state in the panel rather than throwing. It is simply not muxed, so a bad bed can never fail a bake. That applies to the score as well, and matters more there: failing a whole render over a music file would be the wrong trade twice over.

---

## 🪟 Desktop OS & Media Sequences

R3nder is not just a fullscreen text-typer. It features a fully simulated 2D window manager (Ubuntu/Yaru themed).

By default, scripts render as a classic borderless fullscreen terminal. However, by adding a **Desktop Wallpaper**, the engine gains the ability to dynamically "zoom out" from the terminal into a windowed OS environment to display image galleries, video files, apps, and animated UI panels.

### 🖼️ 1. OS & Desktop Configuration
Drop your desktop backgrounds into the workspace `images/` directory and configure them at the top of your script:
```text
[CONFIG:DESKTOP:ubuntu_bg.jpg]
[CONFIG:WINTITLE:operator@field-terminal: ~]
```
* **DESKTOP:** The image file to use as the OS wallpaper.
* **WINTITLE:** Custom text for the terminal's window title bar (Defaults to `operator@field-terminal: ~`).

### 📂 2. Image Galleries
Pause the terminal, pull the camera back to the desktop, and open a simulated Image Viewer window to page through a folder of images. Drop a folder of images into a subfolder in `images/`.

```text
[GALLERY:folder_name:hold_frames:transition:Window Title]
```
* **folder_name:** The subfolder in `images/` (e.g., `evidence_scans`).
* **hold_frames:** (Optional) How many frames to hold on each image. *Default: 90.*
* **transition:** (Optional) How to swap images: `CUT`, `FADE`, or `FLIP`. *Default: CUT.*
* **Window Title:** (Optional) Text for the image viewer title bar. *Default: Image Viewer.*

*Example:*
```text
Extracting target data...
[GALLERY:target_photos:60:FADE:Target_Profile_044.pdf]
Data extraction complete.
```

### 🎬 3. Video Playback (Image Sequences)
Need to play a video file on the simulated desktop? Export your video as an image sequence (PNG/JPG) into a subfolder in `images/`, and use the `[VIDEO]` tag.

```text
[VIDEO:folder_name:initial_hold:Video Name:source_fps]
```
* **folder_name:** The subfolder containing your extracted image sequence.
* **initial_hold:** (Optional) Frames to pause on the first frame before hitting "play". *Default: 60.*
* **Video Name:** (Optional) Text shown in the video window title bar, e.g. `interview_01.mp4`.
* **source_fps:** (Optional) Source frame rate for the extracted sequence. *Default: 30.* Supported values: `23.976`, `24`, `25`, `29.97`, `30`, `50`, `59.94`, `60`.

*R3nder itself remains engine-locked to 30fps. VIDEO uses the declared source FPS to deterministically repeat or skip extracted source frames as needed, always uses a `CUT`, and holds the final frame for 30 R3nder frames before closing.*

### 🌐 4. Browser Windows
Pull back to the desktop and open a generic web browser holding page screenshots. One image per page. A page turn is a **navigation**, not a fade: the address bar cuts to the next URL, a load bar sweeps the top of the viewport, and the capture arrives at the midpoint. That is the only transition a browser has, which is the whole reason this is not a gallery with different chrome.

```text
[BROWSER:folder_name:hold_frames:Window Title:scroll]
```
* **folder_name:** Subfolder in `images/` holding the captures, in `.r3nder_order`.
* **hold_frames:** (Optional) Frames per page. *Default: 150.* Longer than a gallery's default on purpose: a page that scrolls has to be readable while it moves, and 90 frames of travel down a full-page capture reads as a swipe rather than as reading.
* **Window Title:** (Optional) Window title bar text. *Default: Web Browser.*
* **scroll:** (Optional) How the capture meets a viewport it almost never matches, and whether the window fills the frame. *Default: SCROLL.* Six keywords:
  * `SCROLL` fits the **width**, anchors top, then pans down through whatever is below the fold. The travel divides the hold rather than extending it, so a capture twenty screens tall costs exactly the same frames as one that fits. A hold too short to travel legibly plays static at the top rather than scrolling faster.
  * `TOP` fits the width and holds above the fold. Nothing moves.
  * `FIT` contains the whole capture, letterboxed against the page plate. For a short page or a phone capture, where a scroll would have nowhere to go.
  * `SCROLL_FULL`, `TOP_FULL`, `FIT_FULL` are the same three with the window maximized (see below).

The window is capped at **24 pages**; extras are dropped with a warning. Generous compared to the app window's nine, because pages here are sequential navigations rather than panels competing for one screen.

#### The URL is not in the script

Neither is the page title. A URL spends two colons and a pair of slashes before it says anything, and the grammar splits on `:`, so no escaping scheme would produce a language anyone would want to type. It lands on the same answer captions did, for the same reason: an address is a fact about the **screenshot**, not a choice about the shot. The same capture used in two films carries the same address in both.

Both live in the folder's `.r3nder_captions` sidecar, in columns 5 and 6:

```text
# filename<TAB>ON|OFF<TAB>caption<TAB>credit<TAB>url<TAB>page title
01_archive.png	OFF			https://archive.org/details/ilwu_local10	ILWU Local 10 records
02_finding.png	OFF			https://example.org/finding-aid
```

The ON/OFF flag does **not** govern the address bar. That flag decides whether a MOSAIC caption band draws, and a browser's address bar is chrome rather than a label: suppressing a caption on a photograph is a composition choice, while a browser window with an empty address bar is just a broken browser. The same file can therefore carry a URL for `[BROWSER]` and a switched-off caption for `[APP]` without the two interfering.

The tab caption falls back to the URL's host when no page title is given, which is what a browser does anyway. A capture with neither renders a blank bar rather than an invented address. A folder with no sidecar at all warns at setup, because a browser with an empty address bar looks like a bug in the app rather than an unauthored folder.

Four columns is still a valid sidecar. A file written before `[BROWSER]` existed reads unchanged.

#### Full frame

The `_FULL` suffix maximizes the window out to the whole frame once it has opened, and restores to its desktop rect on the way out. Same spelling as `MOSAIC_FULL`, and the same idea: one keyword carrying a composition fact and a window fact, which are pulled apart the moment the tag is parsed.

```text
[BROWSER:archive_captures:150:Archive:SCROLL_FULL]
```

**The chrome stays.** This is the one place a full browser differs from a full mosaic. When a MOSAIC maximizes, its title bar collapses and the panels grow into the vacated height, because the bar is dressing and the panels are the content. A browser's tab strip and address bar are not dressing: they are what makes the window read as a browser at all, and a full-frame capture with nothing above it is a photograph of a webpage. So both bars keep full height at every size, and maximizing gives up only the shadow, the rounded corners, and the desktop around them. Which is also what a real window manager does when you maximize a browser.

Fit and window size are independent in both directions: a windowed browser can fit, and a full one can scroll.

#### Switching between BROWSER tags

`[CONFIG:APPSWITCH:SLIDE]` works here too, and more cheaply than it does for `[APP]`. Two adjacent BROWSER tags become one window, and the join between them is the same navigation as the join between two captures inside one tag. Nothing new is drawn and nothing new is timed.

* **Each page keeps the hold, the title, and the fit it was written with.** A `SCROLL` page followed by a `FIT` page is one window that scrolled and then did not, which is also what a browser does.
* **Window size must match.** A windowed tag will not absorb a `_FULL` one, or the reverse. There is no animation between two sizes inside a navigation, so it would have to jump. A mismatched tag falls back to closing this window and opening its own, exactly as a mismatched mosaic does.


### 📱 5. App Windows (Tile Grid & Metro Mosaic)
Pull back to the desktop and open an "app" window holding your images. Two compositions are available, and whether the window fills the screen is a separate choice from which composition you use.

```text
[APP:folder_name:hold_frames:Window Title:layout:pages:panes]
```
* **folder_name:** The subfolder in `images/` (e.g., `channels`).
* **hold_frames:** (Optional) How many frames to hold *after* the cascade completes. In the mosaic layouts this applies to **each page**, the way a gallery's hold applies to each image. *Default: 90.*
* **Window Title:** (Optional) Text for the app window title bar. *Default: App.*
* **layout:** (Optional) `GRID`, `MOSAIC`, or `MOSAIC_FULL`. *Default: GRID.*
* **pages:** (Optional, MOSAIC only) Comma-separated number of **visual panes** on each page, for example `1,3,2`. Blank means chunk the visual panes three at a time. Because every page owns a hold and a pan, this field changes the duration of the APP and therefore belongs in the script.
* **panes:** (Optional, MOSAIC only) Semicolon-separated pane structure and selective Pane Life authoring. Each token is `IMAGES[@HERO][-DIRECTION][-FIT|-FITW][+FRAMES]`, for example `3@2-LR;1-FIT;2@2-RL+45`. See **Pane structure & selective Pane Life** below.

The optional tail is positional: `layout` requires a title, `pages` requires a layout, and `panes` sits after `pages`. The node workspace handles those guardrails for you.

#### GRID (default)
An adaptive grid of equal rounded-rectangle tiles with soft float shadows. Tiles cascade-fade in one by one (Wii home-menu style) in reading order, left to right and top to bottom, so the reveal reads as a diagonal wave sweeping across the grid. The grid shape is picked automatically from your image count so tiles stay proportional and fill the window cleanly (1 image = 1x1, 4 = 2x2, 9 = 3x3). Capped at 9 images; extras are dropped with a warning.

#### MOSAIC
Metro-style unequal **visual panes** built by recursive halving: a large pane running full height down one side with two stacked panes beside it. Up to three panes are shown per page by default, and the window pans horizontally from one page to the next. The large pane alternates sides on odd pages so a multi-page sequence does not read as the same slide repeated.

A visual pane is no longer required to mean one source image. With no `panes` tail, R3nder preserves the simple rule **one source image = one visual pane**. When pane structure is authored, one visual pane may consume several consecutive images from the folder order. That distinction is what makes selective Pane Life possible without inventing hidden editor state.

Panels are flat plates with a tight gap and no drop shadow, and each one rises a short distance into place as it fades in. Only the first page cascades; later pages arrive already revealed, carried by the pan.

##### Pane structure & selective Pane Life
Pane Life has two layers of language, and they intentionally do different jobs:

```text
[CONFIG:PANELIFE:ON]
[APP:yearbook:90:Evidence:MOSAIC:3:3@2-LR;1;2@2-RL]
```

`[CONFIG:PANELIFE:ON]` **enables the capability only. It selects nothing.** If an APP has no explicit `@HERO`, no Pane Life motion occurs even while the config is ON. This is deliberate: global configuration says what the engine may do; the APP syntax says what this shot actually does.

The final APP segment is one token per visual pane, separated by semicolons:

```text
IMAGES[@HERO][-DIRECTION][-FIT|-FITW][+FRAMES]
```

* **IMAGES** — how many consecutive source images from the folder order belong to this visual pane. `3` consumes three, the next pane begins with the fourth.
* **@HERO** — optional, one-based index **inside that pane**. Its presence opts this pane into Pane Life. `3@2` means a three-image pane whose second image is the selected hero. Omitting it is meaningful: `3-LR` is grouped but static.
* **DIRECTION** — optional `LR` or `RL`, default `LR`. For a selected multi-image pane this chooses which end of the ordered run is visited first. Single-image panes normally omit the suffix.
* **FIT** — optional, default fill. Three values. `FILL` crops to cover the pane and is what every pane did before this existed. `FIT` (or `FITH`) scales to the **vertical edge**: for a source wider than the pane that is the same scale cover would have chosen, so nothing changes, while a source taller than the pane letterboxes left and right against the panel plate instead of losing its top and bottom. `FITW` is the mirror, scaling to the **horizontal edge** and letterboxing above and below, which is what a panorama or a broadside in a tall pane needs. Independent of Pane Life: an unselected pane can fit, and a selected one can fill. Note the asymmetry in travel: a `FIT` pane holding a wide source has crop overflow at rest and so walks from the first frame, while a `FITW` pane is flush horizontally at rest and gains travel only once the push scales it past 100%, so it reads as a still that breathes.
* **FRAMES** — optional, default none. A `+` tail holds images longer. `+45` puts all of it on the image the pane is about (the hero, or image one when no hero is nominated); `+0,45,0` is the explicit per-image form. **This is the one pane fact that changes duration.** See *Holding an image longer* below.

Examples:

```text
1           # one image, no hero, static
1@1         # one image, selected: classic slow push
3-LR        # three images share one pane, no Pane Life
3@2-LR      # three images, image 2 is hero, walk left-to-right
2@2-RL      # two images, image 2 is hero, walk right-to-left
1-FIT       # one image, static, fitted to the pane's vertical edge
1-FITW      # one image, fitted to the horizontal edge instead
3@2-RL-FIT  # grouped, hero 2, right-to-left walk, all three fitted
1+45        # one image, held 45 frames longer than the APP hold
3@2-LR+90   # grouped, hero 2, hero held 90 frames longer
3-LR+0,60,0 # grouped, static, the middle image held 60 longer
```

For the full example `3@2-LR;1;2@2-RL`, pane one consumes folder images 1–3 and selects its second image; pane two consumes image 4 and stays static; pane three consumes images 5–6 and selects its second image with a right-to-left read. The `pages` field counts these **visual panes**, not raw source images. Grouping can therefore reduce the number of MOSAIC pages without changing the folder itself.

The node contact sheet is a graphical editor for exactly this syntax. Click ★ to add `@HERO`; click the same ★ again to remove it. Clicking another thumbnail in that pane moves the single hero. Click the pane divider to split/merge grouping. `LR`/`RL` on a selected multi-image pane toggles direction. `FIT` on the pane's first thumbnail cycles the scaling rule for that whole pane: FILL, vertical edge, horizontal edge, back. Clicking a thumbnail opens its profile, where the caption, the credit, and the hold extension are authored. None of those choices live only in the GUI.

**Do not confuse the two uses of “hero.”** The MOSAIC layout has a *large hero pane* as part of its alternating geometry. Pane Life has an *authored hero image* marked by ★/`@HERO` inside any pane. They are independent: a small stacked pane can have the Pane Life hero, and the large geometric pane can be unselected.

Pane Life motion itself is non-destructive. Only panes with `@HERO` divide the page's existing `hold_frames`: one selected pane gets the whole hold, two split it, three split it three ways. Unselected panes consume no Pane Life slot. If the resulting slot would be too short for a readable move, Pane Life is skipped for that page rather than extending it. On the first page motion begins after the cascade; later pages can begin their authored motion as soon as the page pan has landed.

Pane **grouping** is structural rather than motion timing. Grouping several source images into fewer visual panes can reduce the number of MOSAIC pages, so changing grouping can legitimately change the APP's total duration. What Pane Life promises not to change is the duration of a page once its page/pane structure is fixed.

A selected one-image pane gets the original centred push toward the configured zoom. A selected multi-image pane walks the ordered source images in `LR`/`RL`; supporting images are context beats and only the nominated hero receives scale emphasis. The directional crop is bounded by cover fit, so the move cannot reveal an empty image edge.

### Holding an image longer

Every other authored pane fact is frame-neutral: hero selection, direction, and fit all redistribute or re-scale inside a hold the page already owned. A `+` tail does not. It buys new frames, and every scene after it moves.

```text
[APP:introb:90:Photos:MOSAIC_FULL:3:1;1+45;1]
```

That page runs 45 frames longer than its `90`, and the second photograph is what gets them.

`+45` is shorthand for "all of it on the image this pane is about", which is the hero, or image one when no hero is nominated. `+0,45,0` is the explicit per-image form, and the two mean the same thing when only that image is extended: `3@2-LR+0,45,0` normalises to `3@2-LR+45` on the next write.

Three rules govern where the frames land:

* **Extensions apply whether or not Pane Life is enabled.** This is not an afterthought. If a `+45` only lengthened walks, the exporter's frame-neutrality audit would disable Pane Life, re-tick, watch the count move, and correctly report a defect. It also means holding one photograph longer in a static mosaic needs no Pane Life at all, which is the most common thing anyone wants.
* **Selected panes add rather than overlap.** Panes walk one after another inside the page hold, so two panes each buying 45 frames make the page 90 longer, not 45.
* **The frames go to the image that bought them.** Inside a walking pane, extensions come off the top and are handed to that image's beat before the usual hero/support split runs on what remains. Extend a supporting image and the supporting image gets it; the hero does not absorb it on the way past.

An extension can also rescue a page that was too tight to walk. The "hold too short" check measures each pane's real duration, base slot plus its own extension, so buying the frames a pane needs is a legitimate fix rather than a workaround.

To author it, click a thumbnail in the contact sheet and use the **Hold longer** slider in its profile. Unlike the caption above it, this writes to the APP tag rather than to the sidecar, because a hold is composition: the same scan held two seconds in one film is held four in another.

### Switching between APP tags

By default two adjacent APP tags are two windows. The first un-maximizes, shrinks away, and the second grows back out, which is four window animations and a visible trip out to the desktop.

`[CONFIG:APPSWITCH:SLIDE]` makes them one window instead. The next tag's pages are appended to the window already open, so the transition is the horizontal page pan MOSAIC already uses between its own pages, the way switching workspaces slides rather than closing anything.

```text
[CONFIG:APPSWITCH:SLIDE]
[APP:canada:60:Photos:MOSAIC_FULL:3:1-FIT;1-FIT]
[APP:brazilpaper:90:Photos:MOSAIC_FULL:3:1;1-FIT;1-FIT]
```

Those two tags become a single window of three pages, sliding twice.

* **It applies only between adjacent APP tags with the same layout and the same maximize state.** A slide from a maximized mosaic into a small windowed grid is not a space switch, it is a different window, and it still opens like one. Anything that fails the test falls back to the default behaviour with nothing else changed.
* **Each page keeps the hold it was written with.** The pages above run 60 and 60 and 90, not 60 throughout. The same is true of the window title, which crosses over during the pan when the two tags name it differently and is left alone when they do not.
* **Pages after the first do not cascade.** The panels of an incoming page are already assembled as it slides in, which is what makes it read as a space arriving rather than as content being built.
* **It makes the piece shorter**, since four window animations are replaced by one pan. This is why it is not the default: a script already cut against the old timing keeps that timing until its author asks for otherwise.

### Photo captions

A MOSAIC panel can carry a label: the caption, and under it a credit line set smaller and dimmer, the way a collection line sits under a museum label.

The band is not an overlay. The photograph's rect is deflated and the panel's own plate shows through beneath it, so nothing is covered, no scrim is drawn over the picture, and the panel's clip, corners, and hairline still wrap image and label together as one blocky unit. A `FIT` pane composes with this without a special case: the band takes its space first, and the image then fits the vertical edge of what remains.

**Captions are not in the script.** They live in a `.r3nder_captions` sidecar inside the image folder, beside `.r3nder_order`. This is the stated exception described under *Language-first authoring*: a caption is a fact about the photograph, not a choice about the shot. The practical reason is the same one that would force it anyway, since the APP tag splits on `:` and ends on `]`, and caption prose contains both.

The format is one line per image, tab separated, hand editable in any text editor:

```text
# filename<TAB>ON|OFF<TAB>caption<TAB>credit
01_strike.jpg	ON	Chicago, 1919: the strike committee outside Local 8	Swarthmore College Peace Collection, Box 14
02_hall.jpg	OFF	Ukrainian Labour Temple, interior
```

Trailing columns are optional and unknown extra columns are ignored, so a file written today still reads after the format grows a field. A leading `#` comments a line out. An unreadable sidecar is treated as absent, and a malformed line is skipped on its own rather than failing the file, so one bad hand edit costs one caption instead of all of them.

**ON/OFF is authored separately from the text, and that is the point.** Switching a caption off keeps the words. Dropping a label for one cut must never destroy the research that produced it.

To author from the GUI, click a thumbnail in the APP contact sheet. Its profile opens below the sheet with the HAS CAPTION checkbox, the caption field, and the credit field; clicking the same thumbnail again closes it. A captioned image carries a small `C` badge in the sheet so annotated files are findable in a folder of forty scans. Edits write to the sidecar immediately, and a failed write is reported rather than swallowed.

Two rules decide whether a band appears at all:

* **The band is reserved per PANE, not per image.** If any image in a pane has a caption switched on, that pane reserves band space for all of them. Otherwise a grouped pane would resize its photograph as the walk stepped onto the captioned image, and a picture that changes size mid-shot reads as a glitch rather than as a label arriving. Only the text swaps, and it swaps as a cut: crossfading two different sentences produces a frame of unreadable overlap.
* **A panel that cannot carry a label legibly does not get one.** Type is sized against the window, not the panel, so every label in the mosaic is the same size and a small panel cannot buy legibility by shrinking its text. If the band would take more than about a third of the panel, the credit line is dropped first; if it still does not fit, the whole band is suppressed. The credit is shed first on purpose, since a collection line can be carried by the film's end credits and the subject of the photograph cannot.

Captions change no frame counts. Like `FIT`, the band is geometry inside a page that already owned its time.


#### MOSAIC_FULL
The same composition, but the window **maximizes** out to the whole frame once it has opened, and restores back to its desktop rect on the way out. The title bar's height collapses as it fades, so the panel area grows into the space it vacates and the maximize reads as one continuous move.

At full frame the panels run to all four screen edges with no letterboxing. Corner rounding is kept on every interior corner and squared off at the four corners of the screen itself, which is what makes it read as a Start screen rather than a floating card.

```text
[APP:yearbook:90:FACIAL RECOGNITION MATCHES]
[APP:yearbook:60:Surveillance Grid:MOSAIC]
[APP:yearbook:60:Surveillance Grid:MOSAIC_FULL]
[APP:yearbook:90:Evidence:MOSAIC:3:3@2-LR;1;2@2-RL]
```

*The composition and the window behavior are deliberately separate. `MOSAIC` is a chromed desktop window that happens to hold unequal panels; the `_FULL` suffix is a window modifier that says it should fill the frame.*

### 📇 6. Info Cards
Slide an information panel in from the right edge of the desktop, featuring a cover image, an H1 heading, and body copy over a programmable colored background.

```text
[CARD:image_path:hold_frames:R,G,B:Heading]
Body copy goes here...
[/CARD]
```
* **image_path:** Image file inside `images/`.
* **hold_frames:** (Optional) Frames to hold fully open. *Default: 240.*
* **R,G,B:** (Optional) Panel background color. *Default: 30,30,38.* Text automatically contrasts (white or black) based on the background luminance.
* **Heading:** (Optional) H1 title text.
* **Body:** Multi-line text between the opening and closing tags. (Never types in the terminal; renders directly onto the card).

### 🗂️ 7. Dynamic Dossiers
Combine the detailed text of an Info Card with a folder of evidence images. The sequence opens in a side view: a profile card sits on the right while the gallery browses on the left. After the side hold, choose whether the gallery expands into the legacy center grid, becomes a Metro-style mosaic, or leaves with the card without entering a center stage.

```text
[DOSSIER:folder_name:image_path:hold_split:hold_full:card_lead:center_mode:R,G,B:Heading]
Body copy goes here...
[/DOSSIER]
```
* **folder_name:** Subfolder in `images/` containing the gallery photos.
* **image_path:** Single image file inside `images/` for the top of the profile card.
* **hold_split:** (Optional) Frames to hold the side gallery beside the card. *Default: 120.*
* **hold_full:** (Optional) Frames to hold the center stage. *Default: 120.* In `MOSAIC` this is per mosaic page. Ignored by `SIDE_ONLY` (the node serializer writes `0` in that positional slot).
* **card_lead:** (Optional) Frames the card sits alone before the side gallery opens. *Default: 0.*
* **center_mode:** (Optional) `GRID` *(default)*, `MOSAIC`, or `SIDE_ONLY`. `GRID` preserves the original expanding gallery. `MOSAIC` uses the same three-panels-per-page Metro treatment as `[APP:...:MOSAIC]`. `SIDE_ONLY` skips the center stage and closes the card and side gallery together.
* **R,G,B, Heading, Body:** Same behavior as `[CARD]`.

Existing DOSSIER tags do not need to change: omitting `center_mode` is identical to `GRID`.

The node panel's folder contact sheet also supports non-destructive cleanup: hover a raster thumbnail and click **×** to move it to `images/_recycle/<original-folder>/`. Recycled files are never overwritten and `_recycle` is hidden from normal asset-folder pickers, and from the asset manager's unreferenced-files list, since everything in it is unreferenced by definition.

A **Recycle** panel in the node workspace browses what is in there, restores a file to the folder it came from, and reports the total count and size. It also has the only **Purge** in R3nder, and the only place the app deletes a file. That exception is deliberate: the bin is hidden from every picker, which is what makes removal feel safe, and the cost is that there would otherwise be no way to empty it without going hunting for a folder whose name starts with an underscore. Purge is confirmed, states the count and size, and removes exactly what the browser listed, so anything in the bin it did not show (a stray non-raster, a file you put there by hand) survives.

Any of these that moves a file on disk reloads the live preview, even though none of them changes a character of script. The scene decodes every referenced image once at setup, so a folder whose *contents* changed under an unchanged `[APP:folder:...]` tag would otherwise keep rendering the images it loaded when you opened the file. The reload holds your current frame instead of snapping to the end, because an asset change is almost always made while looking at the exact frame that shows the problem, and it does not mark the document dirty, because nothing in the buffer changed.

### ⏱️ 8. Timelines & Center Stage
Slide a vertical dossier-style timeline in from the right edge. The timeline draws its spine top-to-bottom, then reveals events chronologically. Optionally, attach a "Center Stage" to map a folder of photos to the timeline events!

```text
[TIMELINE:hold_frames:R,G,B:Heading:stage_folder:thumb_width:gap:FOCUS]
1994 | Company founded
1999 | First federal contract
[/TIMELINE]
```
* **hold_frames, R,G,B, Heading:** Same behavior as `[CARD]`.
* **stage_folder:** (Optional) Subfolder in `images/` to pair photos with events. A white connector line will snake through the photos in a translucent "Photos" window, activating each photo's border and year label in lockstep with the timeline events. *(Note: Because segments are positional, you must include a Heading to use a stage).* To set `thumb_width`, `gap`, or `FOCUS` **without** a stage, write `NONE` in this position: `[TIMELINE:240:30,30,38:Heading:NONE:150]`. The segment cannot be left blank, because an empty segment produces `::`, which the grammar rejects and which types the whole tag onto the screen as literal text. The node workspace writes `NONE` for you.
* **thumb_width / gap:** (Optional) Set the pixel width and spacing of the stage thumbnails (in logical pixels @ 1080p; scaled automatically at 4K).
* **FOCUS:** (Optional) Add the `:FOCUS` keyword at the very end of the tag to cinematically dim the background wallpaper into a vignette while the timeline is active.
* **Body:** One event per line formatted as `Date | Description`. A line with no pipe continues the previous event's text.

### 🔗 9. Presentation Chaining (Desktop Montage)
If you stack multiple desktop tags (e.g. `[APP]`, `[BROWSER]`, `[CARD]`, `[DOSSIER]`, `[TIMELINE]`, `[GALLERY]`) back-to-back with **no text or pauses between them**, R3nder will automatically "chain" them together. Instead of zooming back into the terminal between each sequence, the engine will seamlessly transition directly from one UI to the next on the desktop. This holds across window archetypes too: a maximizing mosaic restores to its desktop rect and hands straight off to the next window without the terminal reappearing.

---

## 📝 Syntax & Tag Reference

R3nder uses a custom markup language. Tags are stripped from the final render and control the engine's formatting, speed, and visual effects.

### Comments & Configuration
* `[# any text]` - A comment. Stripped before rendering; never types.
* `[#NEEDS:folder:N]` - Tells the Asset Manager that `images/folder` should hold `N` files. A comment, so the engine never sees it; the manager reports `N OF M` when it comes up short.
* `[CONFIG:DESKTOP:file]` - Desktop wallpaper (enables the windowed OS mode).
* `[CONFIG:WINTITLE:text]` - Terminal window title bar text.
* `[CONFIG:FG:R,G,B]` - Override the terminal foreground (phosphor) color.
* `[CONFIG:BG:R,G,B]` - Override the terminal background color.
* `[CONFIG:SIZE:X]` - Override the base font size.
* `[CONFIG:PANELIFE:ON[:zoom[:ease]]]` - Enable Pane Life capability for MOSAIC APPs. This does **not** select panes automatically; a pane must contain explicit `@HERO` in the APP `panes` segment to move. `zoom` defaults to 102 and is clamped to 100–115. `ease` accepts `LINEAR`, `IN`, `OUT`, or `INOUT` and defaults to `INOUT`. Example: `[CONFIG:PANELIFE:ON:104:INOUT]`.
* `[CONFIG:APPSWITCH:DESKTOP|SLIDE]` - What happens between two adjacent `[APP]` tags, or two adjacent `[BROWSER]` tags. *Default: DESKTOP*, which closes one window and opens the next. `SLIDE` keeps the window and appends the next tag's pages to it.
* `[CONFIG:CAPTION:ALIGN[:size[:font]]]` - Typography for MOSAIC caption bands. `ALIGN` is `LEFT` *(default)*, `CENTER`, or `RIGHT`; `size` is in scaled pixels, default 22, clamped 10 to 48; `font` is a family name from the workspace `fonts/` folder, falling back to the script font when it did not load. Example: `[CONFIG:CAPTION:CENTER:22:Inter-Regular]`. This is typography and lives in the script; the caption TEXT is provenance and lives in the sidecar.

### Core Typing Controls
* `[PAUSE:X]` - Pause typing for `X` frames (e.g., `[PAUSE:30]` for 1 second at 30fps).
* `[SPEED:X]` - Type `X` characters per frame (e.g., `[SPEED:5]`). Use `[SPEED:MAX]` for instant text.
* `[WIPE]` - Instantly clears the terminal screen and resets the cursor to the top left.

### Text Formatting
* `[SIZE:X]` - Change font size (e.g., `[SIZE:48]`, or `[SIZE:DEFAULT]`).
* `[LEAD:X]` - Change line spacing/leading (e.g., `[LEAD:60]`, or `[LEAD:DEFAULT]`).
* `[VPAD:X]` - Insert empty vertical space (in pixels) without typing blank lines.
* `[ALIGN:X]` - Align text. Options: `LEFT`, `CENTER`, `RIGHT`.

### Visual Effects & Colors
* `[RED]`, `[GREEN]`, `[BLUE]`, `[YELLOW]`, `[WHITE]`, `[BLACK]`, `[NORMAL]` - Change text color.
* `[INVERT:on]` / `[INVERT:off]` - Swaps the text foreground and background colors.
* `[REDACT]` / `[/REDACT]` - Wraps text in a solid block (`█`) to hide sensitive data.
* `[SCRAMBLE:on]` / `[SCRAMBLE:off]` - Cypher/Hacker effect. Rapidly cycles random characters before locking the final intended character into place. (Seeded — identical on every run.)
* `[FLASH:X]` - Animates the text. Options: `INVERT`, `SPIKE`, `RED`, `GREEN`, `YELLOW`, `WAVE`, `OFF`.

### 📐 In-Terminal SVG Stencils
Draw monochrome vector stencils directly on the terminal screen (never zooms out to the desktop). The engine automatically wipes the screen, draws the SVG scaled to fit your margins, holds, and wipes again before resuming typing.

* `[SVG:file_path:hold:R,G,B]` - Displays a static vector stencil.
  * *`file_path`* - An `.svg` file located in the `images/` directory (e.g., `logo.svg`).
  * *`hold`* - (Optional) Frames to hold on screen. *Default: 60.*
  * *`R,G,B`* - (Optional) Fill color override. If omitted, the SVG automatically inherits the active terminal pen color (e.g., typing `[RED][SVG:logo.svg]` turns the logo red).
* `[SVGFLASH:folder_name:frames_per:cycles:R,G,B]` - Rapidly cycles through a folder of SVGs (sorted alphabetically) to create flickering boot-logo animations.
  * *`folder_name`* - Subfolder inside `images/` containing multiple `.svg` files.
  * *`frames_per`* - (Optional) Frames to hold each individual logo. *Default: 4.*
  * *`cycles`* - (Optional) How many times to loop through the entire folder. *Default: 3.*
* **Chaining SVGs:** Stacking SVG tags back-to-back (e.g., `[SVG:a.svg][SVG:b.svg]`) will create a seamless `CUT` between them without triggering the wipe-in/wipe-out sequence.
* *Note: R3nder uses a custom, lightweight SVG parser optimized for monochrome stencils. It extracts raw path geometry and ignores background plates, `<defs>`, strokes, text, and gradients.*

### 🕹️ In-Terminal Raster Stencils (IMG)
IBM 3279 "Programmed Symbols" emulation: stamp a small user-authored 1-bit raster tile into the terminal's line flow like an oversized glyph, repeated horizontally and revealed copy-by-copy, left to right.

```text
[IMG:file:repeat:channel:frames_per:release]
```
* **file:** Raster file inside `images/` (max 512×512). Author it in GIMP — R3nder does zero image processing.
* **repeat:** (Optional) Horizontal copy count. *Default: 1.* Clamped to the margins.
* **channel:** (Optional) `R`, `G`, or `B`. *Default: R.* The chosen channel is read as a hard binary mask (value ≥ 128 = pixel on).
* **frames_per:** (Optional) Frames between each copy revealing. *Default: 2.*
* **release:** (Optional) Percentage of the reveal (0-100) at which to open the typing gate early. Letting this trigger early allows the next text or tag to start *while this band continues revealing behind it*. *Default: 100 (blocks until fully drawn).*

On-pixels render as pen-color phosphor; off-pixels render **nothing** — the terminal background shows through, exactly like light on a tube. Nearest-neighbor hard edges by construction; no anti-aliasing, ever. Tint follows the pen color at tag-fire time (`[WHITE][IMG:...]` gives pure white), same rule as SVG. Bands respect `[ALIGN]`, and stacked `[IMG]` tags tile vertically with no seams.

**Pro-Tip:** Stack multiple `[IMG]` tags with an early release (e.g., `[IMG:row.png:10:R:2:15]`) to create overlapping, simultaneous diagonal waterfall cascades!

### 📠 In-Terminal Photo Scans (PHOTO)
A fullscreen slow "wirephoto" scan: the same 1-bit thresholding engine as `[IMG]`, but fit-and-centered to the margins and revealed top-to-bottom over 1 second, like a transmission coming in.

```text
[PHOTO:file:hold:channel:R,G,B:release]
```
* **file:** Raster file inside `images/` (max 1024×1024).
* **hold:** (Optional) Frames to hold on screen. *Default: 120.*
* **channel:** (Optional) `R`, `G`, or `B` mask channel. *Default: R.*
* **R,G,B:** (Optional) Tint override. *Default: pen color.* Positional, so a `release` value cannot skip past it: to release without a tint override, write the pen color explicitly, e.g. `[PHOTO:mesh.png:120:R:0,255,0:25]`. The node workspace fills this in for you. Leaving it blank produces `::`, which the grammar rejects.
* **release:** (Optional) Percentage of the scanline reveal (0-100) at which to open the gate early, so the *next* `[PHOTO]` (or text/tag) can start while this one is still scanning. Adding a release also switches this layer into **stacking mode** (see below). *Default: omitted = classic fullscreen behavior (blocks the full hold, then clears/chains).*

On-pixels render as pen-color phosphor; off-pixels render **nothing** — hard edges, no anti-aliasing. Use high-contrast posterization or coarse dithering when authoring — fine dither patterns are rejected to prevent geometry explosion. `[PHOTO]` and `[SVG]` tags chain with clean CUTs, same as SVG-to-SVG.

#### 🧅 Layering (Onion Reveals)
Give a `[PHOTO]` a **release** value and it stops being a fullscreen takeover — instead it becomes a **layer** that scans in *over* whatever photos are already on screen, and **persists** there until the next `[WIPE]`. A following `[PHOTO]` (fired once the previous one releases its gate) scans in directly on top of it. Because off-pixels draw nothing, the layers beneath show straight through the gaps of the ones above — peeling into the image like an onion.

The intended use is viewing into the structure of a single subject: a solid render, then its wireframe over it, then a UV/edge pass over that — all in the **same tint**, since the layering reads through *geometry*, not color. (Keep the source PNGs the same dimensions so the layers align.)

```text
[WIPE]
[PHOTO:mesh.png:120:R:0,255,0:25]
[PHOTO:wireframe.png:120:R:0,255,0:25]
[PHOTO:uvs.png:120:R:0,255,0:25]
```
Each layer scans in, releases its gate at 25% of its scan so the next begins scanning over it, and all three hold stacked until you `[WIPE]`.

* A `[PHOTO]` **without** a release is still a classic fullscreen photo that *replaces* the screen — use it (or a `[WIPE]`) to reset the stack. To add a layer that blocks until it has fully scanned but still stacks, use `:100` as the release.
* Layers are capped at **6** deep (the oldest drops off if you exceed it).

### 👾 ASCII Sprite Animations
Embed looping ASCII art animations directly into the terminal flow. The sprite snapshots the current color, alignment, and flash states when it spawns!
* `[SPRITE:path:hold]` - Commits frame 0 of a text file from the `sprites/` directory at the current cursor position, then cycles frames in place while typing continues below.
  * *`path`* - The file path (e.g., `skull.txt`).
  * *`hold`* - (Optional) How many frames to hold each animation frame (Default: 30 = 1 sec).
* `[SPRITE_OFF:path]` - Freezes the specified sprite on its current frame, stopping the animation cycle.
* **Sprite File Format:** Raw ASCII text. Separate frames using `[FRAME]` on its own line. *Note: If your frames have different line counts, the engine will automatically pad or truncate them to match the first frame to prevent layout jumps, and will display a warning in the editor.*

### UI Elements
* `[BAR:width:frames:fill:empty:brackets]` - Draws an animated progress bar.
  * *Example:* `[BAR:20:60:█: :[]]` creates a 20-char wide bar that fills with `█` over 60 frames, wrapped in `[]`.
  * Set brackets to `NONE` for a bare bar.

### Regions & Selection Highlights
Mark spans of text as addressable regions, then highlight them on demand — the building blocks for simulated menu navigation.
* `[REGION:id]` ... `[/REGION]` - Tags a span of text with an ID.
* `[SELECT:id:R,G,B]` - Instantly highlights the region with that ID (background color + high-contrast text). All other regions reset.
* `[SELECT:NONE]` - Clears all highlights.

Combine with `[PAUSE:X]` to build blink patterns, or use the Macro Menu system below to control selections from the UI without editing the script.

### Interactive Macro Menus
Define menus and use the R3nder main-menu UI to toggle selection highlights instantly without rewriting your script.
* `[DEF_MENU:menu_name]` ... `[/DEF_MENU]` - Define a menu block.
* `[ITEM:item_id]` ... `[/ITEM]` - Define selectable items inside a menu.
* `[CALL:menu_name]` - Renders the defined menu to the screen.
* `[MENU_STATE:menu_name:instance_id]` - Injects the active highlight/selection state based on what you have selected in the Menu Controller.

The Macro Menu Controller (main menu) lets you pick the selected item, highlight color (green/white), and blink pattern (solid / 1x / 2x) per menu instance. Your choices auto-save into the script as `[MACRO_CFG:...]` lines.

---

## 🎥 Exporting to Video

R3nder features a highly optimized GPU-to-Isolate readback pipeline that pipes raw RGBA frames directly into an `FFmpeg` standard input FIFO queue. The exporter dry-runs the deterministic engine first for an exact frame count, so the progress bar is honest and the file is never truncated or padded.

**Export Formats (Configurable in Settings):**
1. **H.264 Solid (.mp4):** Opaque, one file. Fast and small. No alpha.
2. **Fill + Matte Pair (.mp4 x2):** Two H.264 files. The first carries the color fill, the second carries the alpha channel as luminance. Multiply fill by matte in the comp and the plate reconstructs exactly. Both come out of a single FFmpeg invocation (one decode, `split=2`), and the fill is written **straight**, not premultiplied, because the comp applies alpha itself and a premultiplied fill would darken every soft edge. The matte file is silent by design, so dropping the pair into a timeline cannot double the audio. This exists because ProRes 4444 is intra-only and near-lossless, so it barely compresses terminal output at all: for a working cut you drop into a timeline repeatedly, the pair is a fraction of the size and carries the same information.
3. **ProRes 4444 (.mov):** True alpha channel, 12-bit, near-lossless. The mastering file. Colors are automatically unpremultiplied so glows and anti-aliasing composite perfectly in your NLE. Very large: it barely compresses this content.

*Note: alpha describes what is NOT terminal. A fullscreen script with no Preroll Wipe has nothing transparent to describe and bakes fully opaque. Settings flags this inline rather than letting you find out by baking a 4K ProRes and opening it in an NLE.*

**Audio** is muxed as further FFmpeg inputs when a workspace has a readable voice bed or music bed attached, offset with real silence to the frame the terminal starts, gain-matched to the preview, and padded to the full length of the picture. With both attached they are summed without renormalizing, so the balance you auditioned is the balance in the file, and the score is cut at picture end. ProRes takes `pcm_s24le` (a mastering file next to a 4444 video track), the H.264 paths take AAC at 192k. See the Audio Bed section.

**Framerate** is engine-locked at 30fps — the simulation and the container always agree, so playback speed never lies.

**Output** lands inside the active workspace at `<workspace>/<output folder>/output_1080p.mp4` (or `_4K`, `.mov` for ProRes, `preroll_` prefix when preroll is enabled). The fill + matte pair writes `output_1080p.mp4` alongside `output_1080p_matte.mp4`. The container is a property of the format, so the exporter coerces the extension rather than trusting the requested filename.

### 🎬 Preroll Wipe (Chroma-Key Workflow)
Enable **Preroll Wipe** in the main menu to prepend a keyable intro: 1 second of solid chroma color (green or magenta, selectable), then the terminal window wipes on left-to-right and zooms up to fullscreen. In your NLE, key out the chroma color and the terminal literally materializes over your footage. Confirmed workflow for DaVinci Resolve.

---

## 🔧 Troubleshooting

Most of what goes wrong in R3nder goes wrong *quietly*. The engine's rule is that a bad asset never crashes a bake: it plays as a dud with its timing preserved, so the piece runs the right length and simply has a hole in it. That is the right behavior for an export you started and walked away from, and it is why the editor works hard to tell you at author time instead. This table is the same information collected in one place.

| Symptom | Cause | Where the app already told you |
|---|---|---|
| A tag types itself on screen as literal text | Not a real tag. Unmatched brackets fall through to the typewriter. `[CYAN]` is the classic: cyan is a phosphor preset, not a text color. | Lint strip in the editor gutter |
| An `[IMG]` or `[PHOTO]` shows nothing but still eats its hold time | Source is over the pixel cap: 512 for `IMG`, 1024 for `PHOTO`, on either axis | Amber `OVERSIZE` badge on the asset preview in the node panel |
| A `[GALLERY]`, `[APP]` or `[VIDEO]` window opens empty | The folder is missing, or has no files of the type that tag can draw | Contact sheet reads `EMPTY FOLDER` or `FOLDER NOT ON DISK`; asset manager flags it too |
| A folder plays but is missing images you expected | Files present but not of the expected type, so they were skipped | Contact sheet count versus the `[#NEEDS:folder:N]` declaration, if you set one |
| Exported ProRes 4444 has no transparency | Alpha describes what is NOT terminal. A fullscreen script with no Preroll Wipe has nothing transparent to describe | Settings flags this inline before you bake |
| Voiceover is cut off at the end | Bed is longer than the script; without the end hold stretch it would be | Script ribbon: the audio lane visibly runs past the last block |
| Music is cut off at the end | Correct and deliberate. Nothing stretches for a score, so the bake cuts it at picture end | Script ribbon: amber ticks over the tail of the music lane show how much is discarded. Shorten the music, or lengthen the script |
| Music stops partway and leaves silence | The score is shorter than the piece and Loop is off | Tick **Loop** on the music row. The ribbon's music lane shows the gap before you bake |
| A looping score restarts from the top when I click a script line | Should not happen; a running loop is phase-aligned to the frame you land on | If you see it, the phase is not reaching the player. Preview and bake would then agree only at frame 0 |
| A looping score is cut mid-phrase at the end | Expected. The loop is bounded by picture length, which rarely divides evenly into the cue | Nothing to fix in the mix. Trim the tail in your NLE, or pick a cue that lands |
| Music plays past the end while scrubbing but not in the bake | Should not happen; editor playback is trimmed at picture end for exactly this reason | If you see it, the trim did not reach the player. The preview must never imply a tail the file does not contain |
| The voice dropped in level the moment music was attached | Should not happen. The sum runs `normalize=0` precisely so it cannot | If you see it, `amix` is renormalizing. See `audio_mix.dart`, which spells the sum once for both the preview and the bake |
| The mix distorts with both tracks up | Two hot tracks sum past full scale and clip. There is no limiter, on purpose | Pull one of the two gain faders down. Riding them is the mix; a limiter would be an opinion about it applied invisibly |
| Attaching music rebuilds the whole simulation | Should not happen. Music cannot move a frame boundary, so it is not in the warm-up key | If you see it, something is calling the warm rebuild on a music change. Only the voice bed's length may do that |
| Voiceover ends long before the picture does | Script is much longer than the bed | Script ribbon: audio lane stops well short |
| Audition and preview are silent, but the bake has audio | No `paplay`/`aplay`, or the selected sink is not the one with speakers. Baking needs no sink at all | AUDIO panel header reads `NO BACKEND`; use **Test** to find the right sink |
| A bed file will not load | FFmpeg cannot open it. It is not muxed, so it can never fail a bake | AUDIO panel reads `UNREADABLE` |
| Image sequence in `[VIDEO]` plays too fast or too slow | Source fps parameter does not match what the frames were shot at | `Source FPS` field on the VIDEO node |
| `[CONFIG:PANELIFE:ON]` is present but nothing pushes | ON only enables the capability; no MOSAIC pane has an explicit `@HERO` selection | In the APP contact sheet, toggle ★ on the pane/image you want, or author `@HERO` in the pane token |
| A MOSAIC pane groups several images but stays static | Grouping and motion selection are independent. A token like `3-LR` groups three images but deliberately has no hero | Change it to e.g. `3@2-LR`, or click ★ on the intended hero thumbnail |
| A portrait scan loses its top and bottom in a MOSAIC pane | Panes fill and crop by default, which is right for wide plates and wrong for tall ones | Click `FIT` on that pane's first thumbnail, or append `-FIT` to its pane token |
| A `FIT` pane pushes but never pans | Correct and deliberate. A letterboxed source has no crop overflow to travel through, so the LR/RL walk has nowhere to go | Nothing to fix. Use `FILL` if you want the lateral move back, at the cost of cropping the source |
| A caption is written but no band appears | The record exists with its checkbox off, or the panel is too small to carry one legibly | Tick HAS CAPTION in the image profile. If it is ticked, the panel is below the legibility floor: group fewer panes onto that page, or move the photograph to a larger panel |
| The credit line vanished but the caption is there | Deliberate. The band exceeded its share of the panel, so the credit was shed first | Shorten the caption so it fits one line, or place the photograph in a larger panel |
| A panel resizes its photo partway through a grouped pane | Should not happen; the band is reserved for the whole pane | If you see it, the pane's caption list is out of step with its images. Check that no image in the folder failed to decode |
| Captions vanished after moving the folder | The sidecar was left behind | `.r3nder_captions` is a dotfile inside the image folder. Copy hidden files when moving a workspace by hand |
| A page runs longer than the APP hold says | Correct. A pane on that page carries a `+FRAMES` hold extension | Check the pane tokens, or click the thumbnails: an extended image carries a `+45` badge in the contact sheet |
| `+FRAMES` on a supporting image seems to do nothing | It works, but supporting beats are short to begin with, so a small extension is hard to see against a hero that owns half the slot | Raise it, or star that image so it owns the readable part of the pane |
| APPSWITCH:SLIDE still closes the window | The two APP tags differ in layout or maximize state, or something sits between them in the script | Make both tags the same layout (both `MOSAIC_FULL`, say) and adjacent |
| An APP renders twice under APPSWITCH:SLIDE | A consumer advanced the terminal without releasing the outgoing request first, so it re-absorbed the window already on screen | Clear the pending request before the advance loop. See the app switch contract |
| A `FITW` pane never pans | Expected. It is flush horizontally at rest, so there is no crop overflow to travel through until the push scales it up | Nothing to fix. Use `FIT` if you want lateral movement, at the cost of cropping a wide source |
| Panes are starred but the page still renders still | The hold cannot be divided into readable slots. Each selected pane needs at least 20 frames, so three starred panes want a hold of 60 or more | Warning strip: `PANELIFE: hold too short to walk the selected panes` names the folder and the hold it wants |
| A starred pane skips some of its grouped images | The pane groups more images than its slot has frames, so the tail never gets a beat | Warning strip: `PANELIFE: a pane groups N images but its slot is only M frames` |
| A pane token seems to be ignored | Malformed tokens are dropped rather than failing the render, so a typo like `3@2-LX` silently collapses the plan | Lint strip: `Malformed pane token`, plus separate findings for a one-based `@0` and a hero past the end of its pane |
| A `[TIMELINE]` or `[PHOTO]` types on screen as literal text | A positional segment was left blank to reach a later one, producing `::`, which the grammar rejects. Both `stage_folder` and the `[PHOTO]` tint are incapable of matching empty | Write `NONE` for a skipped stage, or the explicit pen color for a skipped tint. Editing the node re-emits the tag correctly |
| Recycled or newly dropped images still show in the preview | Fixed. If you see it, your build predates the `onAssetsChanged` reload | Preview reloads on any on-disk asset change |
| Dropping files onto an asset field does nothing | The GTK runner change needs a full rebuild, not a hot reload | Pin a field and drop anywhere: the fallback path works without the rebuild |
| A `[BROWSER]` address bar is empty | The captures have no `url` column in `.r3nder_captions`. R3nder never invents an address | Warning at setup names the folder; author the URL by clicking a thumbnail in the node contact sheet |
| A `[BROWSER]` page does not scroll | The capture already fits the viewport, or the mode is `TOP` or `FIT`, or the hold is too short to travel legibly | Nothing to fix in the first case. The scrollbar only draws against real overflow, so its absence is an honest report |
| A `[BROWSER]` folder shows fewer pages than it holds | Capped at 24 pages per window | Warning at setup gives the real count. Split across two tags, or use APPSWITCH:SLIDE to join them into one session |
| APPSWITCH:SLIDE closes a BROWSER window anyway | The two tags differ in window size: one is `_FULL` and the other is not | Make both full or both windowed. Scroll mode is free to differ, only the size has to match |
| A `_FULL` browser still shows its tab strip | Correct and deliberate. A browser without its chrome is a photograph of a webpage | Nothing to fix. Use `[GALLERY]` if you want a bare full-frame image |
| Colors composite wrong in an NLE | ProRes is exported unpremultiplied; the fill of a fill-plus-matte pair is straight, not premultiplied, and the comp applies alpha | See Exporting |

**When the bake and the preview disagree,** that is a real bug and worth reporting, because they are built to be frame-identical: the exporter dry-runs the same engine to get its frame count before rendering anything.

---

## 🏗️ Architecture Notes

* **Language-authority contract:** R3nder is built around a scripting language, not around an editor document model. The raw script is canonical authored state. GUI surfaces may parse it, preview it, and mutate it, but a creative choice that exists only in widget state is a design bug. A GUI action must serialize to language, and parsing that language again must reconstruct the same intent. Untouched nodes retain their original source spans verbatim so a structured editor never normalizes the rest of the document as collateral damage.
* **Determinism contract:** No wall-clock time, no unseeded randomness, anywhere in the render path. Any frame N is reproducible by `reset()` + N ticks. The dry-run frame count, editor scrubber, live preview, and export can never disagree.
* **Pane Life selection contract:** `[CONFIG:PANELIFE:ON]` is capability, not selection. Selection is the nullable `heroIndex` authored by `@HERO` in each APP pane token. `null` must remain `null` through parsing, request DTOs, scene state, and motion planning; defaulting it to zero silently turns selective motion back into “animate everything.” Only selected panes receive motion slots, and those slots subdivide the page's existing hold rather than extending it. Grouping (`3-LR`) is valid without selection (`3@2-LR`), because visual pane structure and motion intent are separate facts. Grouping may change the number of visual panes/pages and therefore APP duration; hero selection, direction, and fit may not. A `+FRAMES` hold extension also may, and is the only other thing that does: it is authored duration, not a side effect of a look, and it must apply with Pane Life OFF or the audit that protects this rule stops working.
* **Caption provenance contract:** Captions are not script state. They live in `.r3nder_captions` inside the image folder and are keyed by filename, and the enabled flag is authored independently of the text so switching a caption off never destroys it. They must be resolved POSITIONALLY inside the folder decode loop, never looked up afterwards against the surviving image list: a file that fails to decode shortens the image list, and a later lookup would land every caption after the failure on the wrong photograph. A mislabelled archival photograph is a worse defect than an unlabelled one, because it is confidently wrong and nothing on screen says so. Band geometry is a pane-level fact, not a per-image one, so a grouped pane holds its photo rect steady and swaps only text.
* **Hold extension contract:** `+FRAMES` is the one pane fact that lengthens the piece. It must be applied to the PAGE hold independently of Pane Life, because the exporter's neutrality audit disables Pane Life and re-ticks expecting an identical frame count; make extensions walk-only and the audit starts reporting a defect that is really this feature. Selected panes run sequentially inside the hold, so extensions sum rather than max. Inside a walk, an extension is taken off the top and handed to its own beat BEFORE the hero/support split runs on the remainder, or a hero that takes half of everything will absorb frames bought for a supporting image. Beats are indexed in walk order, so a reversed pane must map image index to beat index or an extension lands on the mirror photograph.
* **App switch contract:** `APPSWITCH:SLIDE` works by appending the next APP tag's pages onto the live window, NOT by drawing two windows. That choice is what keeps it deterministic and free: the existing page pan carries it, and nothing new is timed. The compatibility test must run against a non-consuming lookahead, because deciding after the terminal has advanced means either tearing down a window that should have been kept or putting a consumed tag back. Once pages can come from different tags, per-page hold and per-page title are mandatory, not conveniences: a single scalar would time a 90-frame page against the previous tag's 60. **The outgoing request must be released before the terminal is advanced.** Activating a presentation does not clear the request that raised it, so a consumer that ticks the terminal without clearing first finds the request already pending, never advances, and is handed back the presentation currently on screen: the window absorbs itself and the same APP renders twice. `_performChainHandoff` clears in that position for the same reason, and it reads like teardown of the outgoing presentation. It is also a precondition of the loop beneath it.
* **Pane fit contract:** `FIT` and `FITW` are scaling rules, not motion settings. `FIT` means the vertical edge for reasons of release order rather than of meaning, and it stays the canonical emitted keyword so that pane tokens already on disk are never rewritten; `FITH` parses as its synonym and `FITW` is the horizontal mirror. The painter branches on a runtime enum rather than on the authoring keyword, so it never has to know that history. It applies with Pane Life off, on an unselected pane, and on every image of a grouped pane, so it must be stamped downstream of the pane-frame branches rather than inside the motion plan: several of those branches return an identity motion to mean "not animating", and an identity motion is not an instruction to fill. Edge safety is inherited, not added. Fitting the vertical edge leaves zero horizontal crop overflow on a source narrower than the pane, which the painter's existing `focusX` clamp already turns into no travel, and the 100% zoom floor means a vertically flush image only ever scales up. Any future change that lets the push scale below 100% breaks this and must letterbox or clamp deliberately.
* **Native drag-and-drop:** Implemented directly in the GTK runner (`linux/runner/my_application.cc`) — file URIs are forwarded to Dart over a method channel, along with the drop position. No plugins. The position arrives in FlView widget coordinates, which are Flutter's logical pixels 1:1 (the Linux embedder sends metrics as allocation times scale factor with `devicePixelRatio` equal to that scale factor), so Dart can hit-test a drop against a widget with no conversion. The payload is a map; the older bare-list shape is still accepted, because the C half needs a full rebuild while Dart hot-reloads and the two are routinely out of step during development.

  Drag *motion* is forwarded too, which is what drives the hover highlight, and it is filtered in two stages split by which side knows what. The C side cannot know which widget is under the cursor, since the geometry only exists in Dart, so it filters on the one thing it does know: it forwards only when the pointer has actually travelled a few pixels. Dart then resolves the position to a field and repaints only when that field changes. A drag crossing 200 pixels inside one field therefore costs a handful of channel messages and one repaint, rather than one message and one hit test per motion event at pointer frequency. Motion and leave are advisory: if they never fire, because the C half has not been rebuilt, dropping still works exactly as before.

* **Palette self-check:** the ADD NODE palette is a hand-written list, and a hand-written list drifts. A debug-only assertion checks it against the grammar whenever the menu opens: every snippet must still parse, every tag the linter knows must have an entry, no two labels may collide, and every placeholder must actually occur in its insert text. Assertion bodies are stripped in release, so this costs nothing shipped. It makes drift loud rather than impossible, which is the honest limit: labels, descriptions, and example values are editorial content a regex does not contain.
* **Positional-segment contract:** reaching segment N of a tag means emitting every segment before it. A segment that resolves to nothing writes a bare `::`, which `tagRegex` rejects, so the construct stops matching and types onto the screen as literal text: the document still round-trips and the node panel still looks correct, and only the render is wrong. Every optional segment that can be followed by another therefore declares a non-empty default or fallback, and `_emitTag` asserts it in debug. The assertion earned itself immediately, catching `[TIMELINE]` with a thumbnail width but no stage and `[PHOTO]` with a release but no tint, both of whose grammar groups are incapable of matching empty. `[APP]` is seven segments deep with `panes` at the end, so the next tail makes this more likely rather than less.
* **Pane Life frame-count audit:** the neutrality claim is checked on every bake rather than trusted. The exporter's dry run establishes the frame count with motion enabled; if Pane Life is on, a second dry run immediately follows with it forced off, using the same engine and the same decoded assets. Both totals are written to `r3nder_trace.log` as a `[panelife]` line. A mismatch is reported and not thrown, because the export is not wrong, it is a different length than the design promised, and failing a render someone is waiting on would be the worse answer. Structural pane grouping is excluded by construction: only the on/off toggle is swapped, with grouping held constant.
* **CONFIG key registry** (`config_keys.dart`): `[CONFIG:KEY:value]` parses generically, which is why a new key costs no grammar change. Two surfaces did enumerate keys by hand, the node workspace dropdown and the ADD NODE palette, and forgetting either failed silently: a key absent from the dropdown fell through to a text field labelled for a different setting, and one absent from the palette could not be discovered. Both now read the same list.
* **Decoded asset caches** (`scene_engine.dart`): `setup()` runs far more often than assets change, including on every debounced keystroke pause in the editor, so decoded images and built stencils are cached process-wide, keyed on path plus modification time plus size. The image cache hands out `clone()` handles and keeps the original, which is what makes LRU eviction safe while a warm-up engine, a preview engine, and the editor may all hold the same file; every caller owns and disposes its own handle. The stencil cache alongside it is capped by entry count rather than bytes, because a `Path` exposes no size.
* **Pure-Dart SVG parser** (`svg_path.dart`): path data (M L H V C S Q T A Z), rects, circles, ellipses, polygons; arc-to-cubic conversion; background-plate culling; fill-rule inference for counters/holes.
* **Glyph cache:** laid-out TextPainters are cached process-wide keyed on (char, family, size, color), so dense screens paint without per-frame layout costs.
* **Audio boundary contract** (`audio_bed.dart`): the render path never imports the audio library. One precomputed integer crosses back, derived from a probe of the **voice** bed before frame 0. A workspace can attach two tracks, and they are not peers: voice owns the length because a trailing line is content and the end hold stretches to let it finish, while music is trimmed to picture because no amount of score is a reason to hold on a settled terminal. That asymmetry is what keeps the single-integer contract intact through a second track, and it is why music never enters `ScriptWarmKey`: it cannot move a frame boundary, so attaching or re-gaining it costs no re-simulation. Preview playback and export mux remain deliberately unrelated code paths.
* **Music loop contract:** looping fills, it never extends. `-stream_loop -1` is infinite at the input and the output `-t` is what makes it finite again, so the loop changes what is audible and changes no frame count. That is why it stays out of `ScriptWarmKey` with the rest of the music state, and why the exporter's neutrality audit is unaffected by it. In the PREVIEW a looped track is deliberately NOT seeked with `-ss`: combining `-stream_loop` with an input seek makes the loop restart at the seek point on some ffmpeg builds, so every repeat after the first would lose its opening, which is inaudible on the first pass and obvious on the second. A looped track is decoded from zero and phase-aligned with `atrim` plus `asetpts` instead, deterministic on every build, at the cost of decoding up to one track length that is thrown away. The bake needs none of this: it starts every track at the head and offsets with real silence, so it has no phase to resolve.
* **Audio mix registry** (`audio_mix.dart`): the sum of two beds has to be true in two places, and those two places are the unrelated consumers above. Spelling it twice is the failure the CONFIG key list already produced once, so it is a registry instead: no state, no processes, no imports, readable by the preview player and the exporter without either learning about the other. `normalize=0` is the load-bearing part. `amix` defaults to dividing by the input count, so attaching a score would drop the voice 6dB with no fader moved and nothing said, which is the same defect as peak-normalizing a preview. The cost is honest: two hot tracks clip, and the gain controls are the answer. `apad` is applied after the sum rather than on each branch, since padding both inputs makes both infinite and turns `duration=longest` into a statement about nothing. Once two tracks can be attached, the mixed stream is a filter label rather than an input, so `-af` cannot address it and every export format builds its chain in `filter_complex` — including the plain H.264 path, which is why `-map 0:v` appears there: `filter_complex` disables automatic stream selection for the whole command, not just for the streams it touches.
* **Script linter** (`script_lint.dart`): an unmatched tag is not an error in this grammar, it falls through and types literally on screen, which is the worst kind of silent failure. The linter catches nonexistent tag names, malformed positional tails, and unclosed body tags by asking the actual `tagRegex` rather than a second copy of it, so it cannot drift from the parser. The APP `panes` tail needs a second pass, because its grammar group is `[^\]]+` and therefore matches any string at all: a malformed pane token never reaches the main scan, and the parser drops what it cannot read and carries on. That pass validates each token against the same pattern the parser uses, plus the two range errors the parser silently absorbs, a one-based `@0` and a hero past the end of its own pane.
* **Asset previews** (`node_asset_preview.dart`): authoring furniture, never in the render path. Raster dimensions come off the file header via `ImageDescriptor` without a full decode, so the cap warnings cost a header read rather than a decode. SVG thumbnails go through the engine's own parser, which is what makes the preview trustworthy about background plates and fill rules. Caches are process-wide and invalidated by hand after an import rather than keyed on mtime: a stat per thumbnail per rebuild is a syscall storm for a value that only changes when this app writes it.

---