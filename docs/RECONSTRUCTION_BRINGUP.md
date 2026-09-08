# Reconstruction Bring-Up: Turning the Architecture Into a Working NLE

This is the practical companion to `REBUILDING_R3NDER_PRO.md`.

That document answers:

> What should I build, and in what architectural order?

This one answers:

> I built it. How do I know it actually works on a real machine?

The distinction matters.

A deterministic NLE can be architecturally correct and still fail at the integration boundary because real audio devices, media decoders, Flutter paint behavior, external textures, process I/O, and codecs introduce observations that unit tests cannot manufacture faithfully.

The purpose of this document is not to eliminate hardware work. It is to make that work legible, staged, and reproducible.

The core rule is:

> Do not debug the layer where the symptom is visible. First identify the lowest boundary that can still explain the observation, then measure that boundary.

---

# 1. What this playbook assumes

Before using this document, the reconstruction should already follow the contracts described in:

- `REBUILDING_R3NDER_PRO.md`
- `PROJECT_TIME_AND_AUDIO.md`
- `SCRIPT_AND_CST.md`
- `EDIT_MODEL.md`
- `MEDIA_AND_MLT.md`
- `STRUCTURAL_COMPOSITION.md`
- `PREVIEW_AND_BAKE.md`
- `GUI_MUTATION_CONTRACTS.md`
- `RENDER_OUTPUTS.md`
- `TEST_STRATEGY.md`
- `CONTRACT_TEST_MANIFEST.md`

In particular, the implementation should already have:

```text
one canonical authored document
one explicit ProjectTime model
EDIT / TRACK / CLIP semantics above MLT
persistent media decode
structural recursion
Program Preview
whole-program BAKE
```

If those ownership decisions are still unsettled, hardware debugging will produce misleading fixes.

---

# 2. Bring-up order

Use this order on a new machine or a reconstruction.

```text
1. static repository integrity
2. compile and launch
3. exact project-time behavior
4. native audio authority
5. persistent leaf-media decode
6. EDIT realtime presentation
7. nested EDIT/MOSAIC recursion
8. STRUCT presentation and readiness
9. Program Preview
10. whole-program BAKE
11. encoded output inspection
12. render identity / no-overwrite
```

Do not begin with a large real project.

Each stage should have a tiny fixture with one obvious expected result.

---

# 3. Stage 0 — repository integrity

Start with the cheapest checks.

From the repository root:

```bash
flutter pub get

dart run tool/check_doc_contracts.dart

flutter test
```

The documentation check ensures that architectural contracts still point to real proof artifacts.

The full Flutter suite is not a substitute for the native measurements later in this document. Its purpose here is to establish that the authored model, parser, compositor seams, Program Preview, exporter fixtures, and documented contracts are internally coherent before hardware observations are introduced.

If this stage fails, do not proceed to audio, MLT, or GUI diagnosis.

---

# 4. Stage 1 — compile and launch the real Linux application

The ordinary development launch is:

```bash
flutter run -d linux
```

For release-mode performance measurement:

```bash
flutter build linux --release
./build/linux/x64/release/bundle/r3nder
```

At this stage prove only that:

- the application opens;
- the workspace loads;
- a minimal authored document renders;
- TEXT/NODES/EDIT can be entered and exited without replacing canonical document state;
- native platform services initialize without deadlock.

Do not evaluate smoothness yet.

A slow first media frame is not evidence of a clock failure. A silent application is not yet evidence of timeline failure. Keep observations scoped.

---

# 5. Stage 2 — prove project time before proving playback

A reconstruction should demonstrate that frame identity survives different ways of reaching the same authored position.

Use a tiny deterministic scene containing visible frame-dependent state.

Exercise:

```text
scrub to frame N
play through frame N
seek backward then return to N
export frame N
```

The content at frame N must agree.

Things to verify:

- ProjectTime is explicit;
- Flutter callbacks sample time rather than incrementing it;
- a backward seek advances invalidation identity;
- stale asynchronous media results cannot retake visual ownership after the seek;
- export selects frame N directly rather than waiting for realtime playback to reach it.

If this is wrong, stop here. Media and presentation work built above an unstable time model will only hide the defect.

---

# 6. Stage 3 — native audio authority

Realtime audio is the first place where real hardware matters.

R3nder's accepted architecture is:

```text
PCM producer
    ↓
bounded packets
    ↓
NativeAudioSink
    ↓
PulseAudio
    ↓
submitted samples - measured device latency
    ↓
ProjectClock AUDIO mode
```

Preview PCM uses regular 10 ms packets. At 48 kHz that is 480 sample frames per full packet.

That size is not merely an arbitrary buffer preference. It is part of the timing contract between producer, native sink, and clock authority.

Run the real A/V lock probe:

```bash
dart run tool/av_lock_probe.dart
```

The accepted R3nder validation procedure is documented in `M4_AV_LOCK_VALIDATION.md`.

The historical accepted run used:

```text
project rate:          30 fps
presentation sampling: 60 Hz
PCM:                   48 kHz stereo s16le
video source:          1920x1080 30 fps H.264
MLT decode request:    960x540
run length:            15 s per mode
```

The important shape of the result was not merely a small error number. It was a **constant** error rather than accumulated drift.

Accepted session behavior showed microsecond-scale constant clock error in both baseline and video-load runs, one clock mode transition, no post-readiness video holds, and no observed requested/presented integer frame mismatch.

## What to look for

Good:

```text
clock error stays essentially constant
queue remains bounded
mode does not oscillate
video decode load does not increase clock drift over time
```

Bad:

```text
error grows with run length
submitted samples are treated as audible samples without latency subtraction
packet queues grow without bound
clock authority repeatedly drops/re-arms during steady playback
```

A stepped visible clock can still occur even when the underlying sample accounting is correct if publication is quantized too coarsely. Measure sample-derived time rather than judging only from a moving label.

---

# 7. Stage 4 — persistent MLT leaf decode

Now prove media independently from the GUI timeline.

The media contract is:

```text
requested source frame N
    ↓
persistent decoder identity
    ↓
actual decoded frame identity
```

The decoder does not own project time.

Validate:

- open once, seek many;
- exact source-frame request identity;
- actual returned frame identity;
- cold-start readiness;
- stale request rejection;
- restart/recovery after source changes;
- no process-per-frame behavior;
- nested `EDIT.*` / `MOSAIC.*` references are not handed to MLT as filesystem paths.

Relevant proof includes:

```text
test/media_layer_test.dart
test/media_decoder_native_test.dart
linux/runner/media_decoder_test.cc
```

A decoder returning `pending` is not a timing failure. It means the requested visual data is not ready yet.

The live presentation layer decides what remains visible while that happens. Project time continues.

---

# 8. Stage 5 — EDIT realtime presentation

This is where a correct decoder can be blamed for a Flutter problem.

The historical M10 failure is the model case.

## Symptom

EDIT playback looked roughly 12–15 fps or worse. Video and playhead chugged together.

Several plausible decoder/clock changes did not fix it.

The useful measurement was Flutter `FrameTiming`.

Enable the existing trace on a release build:

```bash
R3NDER_PLAYBACK_TRACE=1 ./build/linux/x64/release/bundle/r3nder
```

A stopped PLAY session writes:

```text
r3nder_playback_session_001.log
r3nder_playback_session_002.log
...
```

Inspect:

```text
TICK
CLOCK
EXACTPUB
INTPUB
FLUTTER build_us / raster_us / total_us
```

The accepted fix separated the moving exact playhead from the large static timeline with independent repaint boundaries.

Historical measured behavior:

```text
before:
UI-thread work roughly 86–106 ms on ordinary frames
Ticker commonly ~116.7 ms apart

accepted fix:
typical UI build work roughly 0.2–1.7 ms
Ticker mostly ~16.7 ms with occasional missed refreshes
```

The lesson is diagnostic, not cosmetic:

```text
large build_us + modest raster_us
→ inspect build/layout/paint recording

large raster_us
→ inspect raster/GPU work

clock advancing correctly while both video and playhead jump
→ presentation cadence may be the problem, not media timing
```

See `EDIT_PLAYBACK_PERFORMANCE.md` for the full measurement history.

---

# 9. Stage 6 — nested EDIT and MOSAIC

Once leaf decode and EDIT are healthy, prove structural recursion.

Use deliberately tiny graphs:

```text
EDIT A
  → leaf video

EDIT B
  → EDIT A

MOSAIC C
  pane 1 → EDIT A
  pane 2 → EDIT B
```

Verify at exact project frames:

- local frame mapping;
- pane geometry;
- recursive source resolution;
- recursion-depth rejection;
- pending/offline propagation;
- exact structural source export.

Do not introduce STRUCT presentation yet. First prove that a reusable structural source has correct pixels by itself.

---

# 10. Stage 7 — STRUCT presentation and readiness

STRUCT is not just another media layer.

It owns **placement**:

```text
source selection
windowed/fullscreen presentation
entry/switch geometry
DEFAULT/CUSTOM/NONE chrome
window title
dynamic [frame] expressions
```

The reusable EDIT/MOSAIC source does not own those facts.

This distinction is crucial during debugging.

## Readiness contract

An incoming structural source may not have its first frame ready immediately.

Correct behavior:

```text
project time continues
outgoing shell/source may remain visible as cover
incoming frame becomes visible when ready
source-local time is not restarted
```

Incorrect behavior:

```text
insert project frames while waiting
show wallpaper/desktop for one frame
reset the structural source to frame 0 when readiness completes
let a fullscreen terminal appear between adjacent apps
```

Use the M18 visual gate and fixture:

```text
docs/M18_STRUCT_APP_SWITCH_VISUAL_GATE.md
docs/M18_STRUCT_APP_SWITCH_VISUAL_FIXTURE.txt
```

Some presentation defects are easiest to accept visually even when the underlying planner has pure tests.

---

# 11. Stage 8 — top-level Program Preview

Do not confuse an editor-local structural preview with the final Program Preview boundary.

Program Preview additionally exercises:

```text
compiled runtime projection
REGION markers
placement identity
raw authored metadata association
base scene paint
structural cover/readiness behavior
```

A direct `StructuralSequencePreview` test can be green while `ProgramPreviewSurface` is wrong.

That happened during M20.

Relevant tests include:

```text
test/program_preview_structural_chrome_runtime_test.dart
test/program_preview_structural_fullscreen_test.dart
test/program_preview_structural_switch_test.dart
test/program_preview_structural_late_handoff_test.dart
```

When the editor preview is right but the dashboard preview is wrong, investigate this boundary before touching MLT or ffmpeg.

---

# 12. Stage 9 — whole-program BAKE

BAKE is not realtime playback captured to disk.

The contract is:

```text
for every output frame i
    ↓
construct ProjectTime(frame: i)
    ↓
exact scene evaluation
    ↓
exact structural frame evaluation
    ↓
compose final frame
    ↓
encode
```

A slow frame may take a long time to produce. It must still be frame i.

First test the offscreen program structural renderer.

Then test the true exporter boundary:

```text
SceneExporter.export()
    ↓
FIFO
    ↓
ffmpeg
    ↓
encoded MP4/MOV
    ↓
ffmpeg decode back to raw pixels
    ↓
assert the finished file
```

Relevant encoded tests include:

```text
test/scene_exporter_structural_chrome_end_to_end_test.dart
test/scene_exporter_structural_mosaic_custom_end_to_end_test.dart
```

The second test exists because a smaller EDIT-only fixture was not enough to reproduce a real MOSAIC placement failure class.

---

# 13. Stage 10 — inspect the finished file, not only internal pixels

The final encoded file is a separate acceptance boundary.

Check:

- expected frame count;
- expected resolution;
- expected codec/container;
- audio presence and alignment;
- fullscreen/window geometry;
- DEFAULT/CUSTOM/NONE chrome;
- dynamic `[frame]` values;
- final filename/version identity.

If pre-encode RGBA is correct and the decoded output file is wrong, then the problem is genuinely downstream.

Do not assume that merely because ffmpeg is the final process it is therefore the likely cause. During M20, real exporter tests proved ffmpeg preserved the chrome and forced the investigation back toward metadata association.

---

# 14. Stage 11 — render identity and destructive-safety

A reconstruction is not complete if repeated BAKE silently destroys its own history.

With:

```text
[CONFIG:RENDERNAME:documentary_cut]
```

repeated renders should produce a monotonic family such as:

```text
documentary_cut_1080p_v001.mp4
documentary_cut_1080p_v002.mp4
documentary_cut_1080p_v003.mp4
```

Deleted gaps are not reused.

Format changes remain in the same logical version family.

Fill/matte companions reserve one version together.

The application checks collisions before encoding and ffmpeg itself is invoked in no-overwrite mode.

This is both a product feature and a safety invariant.

---

# 15. Symptom → boundary map

Use this table before making changes.

| Symptom | First boundary to measure | Do not assume |
| --- | --- | --- |
| playback stutters | Flutter build/raster timing + clock trace | decoder is slow |
| video and playhead jump together | ProjectClock continuity + FrameTiming | source mapping is wrong |
| audio gradually drifts | sample-derived clock error over run length | packet queue alone is the cause |
| first media frame is late | decoder cold-start/readiness | project time should wait |
| old frame appears after seek | epoch/generation rejection | decoder returned the wrong frame synchronously |
| one-frame wallpaper flash | structural paint/readiness ownership | MLT failed |
| fullscreen source briefly shows terminal/desktop between apps | executable adjacency + outgoing cover | transition duration is wrong |
| editor preview correct, Program Preview wrong | runtime projection / placement association | chrome painter is wrong |
| Preview correct, BAKE wrong | ProgramStructuralFrameRenderer / SceneExporter boundary | realtime clock is wrong |
| renderer raster test green, real BAKE wrong | real SceneExporter + realistic document topology | add more painter assertions |
| correct video but wrong/missing chrome | STRUCT metadata association/index identity | font/ffmpeg must be wrong |
| source export lacks STRUCT title/chrome | verify whether user invoked source export or program BAKE | source export is supposed to include placement presentation |
| test hangs | fake-async / real I/O / image readback boundary | production deadlocked |
| test fails to compile | test harness types/imports/constants | product regressed |
| old render vanished | output collision/version policy | encoder is entitled to overwrite |

The table is intentionally biased against the most visually obvious theory.

---

# 16. Measurement discipline

When a bug only exists on real hardware, record enough context that the observation can become engineering evidence.

For every measurement session, record:

```text
commit SHA
branch
machine / display refresh
project frame rate
output resolution
media codec/resolution
relevant environment flags
run duration
fixture/document used
raw log path
what changed from previous run
```

Change one boundary at a time.

Do not combine a decoder rewrite, a clock rewrite, and a Flutter repaint optimization into one experiment and then call the resulting smoothness proof.

A useful experiment makes one causal statement possible.

Example from the EDIT playback investigation:

```text
change:
separate static timeline and moving playhead repaint regions

unchanged:
MLT decoder
ProjectClock
source mapping
external texture

observation:
UI build time dropped by roughly sixty times
playback became smooth
```

That is evidence.

---

# 17. Failed hypotheses are part of the bring-up record

Keep the wrong theories.

They teach future engineers which symptoms are misleading.

The M20 chrome failure produced several plausible theories:

```text
font family mismatch
sub-pixel chrome scale
fullscreen clipping
alpha/readback
ffmpeg stripping text
```

Lower-level tests eventually proved all of those wrong.

The actual failure class was **placement metadata association** in a realistic document topology.

The durable lesson is:

> Correct pixels associated with the wrong metadata can look exactly like a renderer defect.

Do not erase that history once the final fix is known.

---

# 18. What can and cannot be transferred through documentation

The reconstruction docs can transfer:

- architecture;
- ownership boundaries;
- invariants;
- build order;
- known failure classes;
- proving tests;
- accepted measurement procedures;
- diagnostic questions.

They cannot transfer:

- the physical latency of a new audio device;
- a GPU driver's behavior;
- a new Flutter engine performance regression;
- an MLT/backend quirk on unseen media;
- scheduler behavior on another machine;
- the hours required to observe a novel integration defect.

That limitation is not a documentation failure.

The goal is to ensure those hours are spent **measuring the new problem**, not rediscovering the old architecture.

---

# 19. Reconstruction acceptance

A rebuilt editor of this class is not accepted merely because it opens and can cut clips.

It should be able to demonstrate, on the target hardware:

```text
canonical document survives GUI round-trip

frame N is explicit and reproducible

audio clock authority does not accumulate drift under MLT load

persistent decoder returns requested leaf-frame identity

EDIT playback remains smooth without redefining project time

nested EDIT/MOSAIC composition is exact

STRUCT readiness changes visibility, not authored timing

Program Preview uses the compiled runtime placement identity

whole-program BAKE preserves Preview semantics

encoded output preserves the intended pixels/audio

repeat BAKE creates a new version rather than replacing history
```

Only then has the architecture survived contact with the machine.

---

# Final principle

The written architecture shortens the design phase.

The proof manifest shortens the refactor/review phase.

This bring-up playbook shortens the integration diagnosis phase.

None of them makes hardware observation unnecessary.

They make it much harder to spend a week measuring the wrong thing.