# Project Time and Audio Authority

This page defines the timing architecture that every other subsystem in R3nder Pro depends on.

The first principle is simple:

> Project time is authored state. Paint cadence, decoder latency, audio queue depth, and export wall time are observations around it, not replacements for it.

If this rule is violated, every higher-level feature becomes untrustworthy: scrub, transitions, nested sources, Preview, and BAKE can all disagree while looking locally plausible.

---

## Contract

R3nder has one canonical project-time model:

```text
ProjectClock
    ↓
ProjectTime(frame, phase, epoch, mode)
    ↓
SceneEngine.evaluate(ProjectTime)
```

The contract is:

- canonical frame rate is rational;
- canonical time is never stored as a floating-point frame number;
- asking for project frame N must mean the same authored instant in scrub, Preview, and BAKE;
- realtime polling may sample time but may not advance it;
- decoder readiness may delay visibility but may not change the requested project frame;
- a seek invalidates asynchronous work by advancing the clock epoch;
- export selects time explicitly and never depends on the realtime native clock.

Primary files:

- `lib/project_clock.dart`
- `lib/scene_evaluator.dart`
- `lib/audio_sink.dart`
- `lib/audio_bed.dart`
- `lib/audio_mix.dart`
- `lib/main.dart`

Validation history:

- `docs/M4_AV_LOCK_VALIDATION.md`

---

# 1. ProjectTime is a value

`ProjectTime` carries:

```text
frame
phaseNumerator / phaseDenominator
epoch
mode
```

`frame` is the whole authored frame.

The rational phase preserves exact sub-frame position without making a `double` canonical. The current terminal scene is frame-discrete, so most scene content still evaluates the whole frame, but the representation is already capable of exact rates and audio-sample-derived time.

`epoch` is not visual time. It is invalidation identity.

When a seek occurs, asynchronous decode work issued under the old epoch must not be allowed to become the current visual result simply because it eventually completed.

`mode` identifies the authority:

```text
monotonic   realtime wall-clock-backed preview
scrub       explicitly parked authored position
audio       audible sample playout authority
```

Do not make rendering behavior depend on mode unless the behavior is genuinely scheduling-related. The same `frame` should describe the same authored content in every mode.

---

# 2. There are two clock implementations for a reason

`NativeRealtimeProjectClock` and `ExportProjectClock` implement the same time interface but represent different physical mechanisms.

## NativeRealtimeProjectClock

Used for realtime application behavior on Linux.

The native control block owns authoritative time independently of Flutter's vsync cadence.

Flutter can call:

```text
clock.sample()
```

at 60, 120, or 144 Hz. Sampling does not advance project time. It merely asks the native authority what time it currently is.

This matters because a UI stall must not redefine the project's elapsed time.

## ExportProjectClock / explicit export time

Export is not realtime playback.

BAKE chooses frame N directly. There is no reason for it to consult a wall clock or an audio output device.

This separation guarantees that a slow frame takes longer to produce but remains the same frame.

---

# 3. Scene evaluation is an explicit-time seam

`lib/scene_evaluator.dart` exists to make callers think in terms of explicit project time even while parts of `SceneEngine` still use a mutable tick-driven implementation internally.

Conceptually:

```text
scene.evaluate(ProjectTime(frame: N))
```

means:

> Bring the deterministic scene to authored frame N.

Current behavior is compatible with a legacy state machine:

- forward requests tick until N;
- backward requests reset and replay;
- bounded realtime evaluation may stop before N and report `exact == false`;
- export requires exact evaluation and treats failure to reach N as an error.

This file is a migration boundary. Future direct-time effect evaluators can replace replay behind the same public contract.

A reconstruction should establish this seam early even if the first engine implementation is still incremental.

---

# 4. Flutter Ticker is a poller, not a clock

The main Preview loop follows this shape:

```text
vsync callback
    ↓
ProjectClock.sample()
    ↓
SceneEngine.evaluate(sampled ProjectTime)
    ↓
repaint
```

That ordering is important.

Wrong architecture:

```text
vsync callback
    ↓
frame++
```

The wrong version turns display cadence into project time. It fails immediately under:

- 60 Hz display / 30 fps project;
- window stalls;
- background scheduling;
- variable refresh;
- scrubbing;
- audio clock authority;
- export faster/slower than realtime.

The UI is allowed to decide **when to look**. It is not allowed to decide **what time it is**.

---

# 5. Audio authority

Audio has a special relationship to realtime time because the physical event the user hears is sample playout at the device, not packet submission in Dart.

The native path is conceptually:

```text
FFmpeg PCM producer
    ↓
bounded packet queue
    ↓
NativeAudioSink worker
    ↓
PulseAudio
    ↓
submitted samples - measured device latency
    ↓
ProjectClock AUDIO mode
```

The sink exposes cumulative submitted samples and measured latency.

The clock therefore represents audible position rather than how much PCM Dart happened to enqueue.

## Packet contract

Preview PCM packets are deliberately regular: full packets represent 10 ms of interleaved signed 16-bit PCM. A single shorter frame-aligned packet is allowed only as the EOF tail.

This gives the producer, sink, and timing layer a shared duration contract without making the native worker dependent on arbitrary decoder packetization.

## Backpressure

`tryEnqueue()` returning false is not failure. It means the bounded native queue is full.

The correct response is to stop feeding it temporarily.

Do not replace bounded backpressure with an unbounded Dart-side audio queue. That converts temporary scheduling pressure into unbounded latency and destroys the relationship between submitted data and audible time.

---

# 6. Device changes and stale work

An audio device change is a timing event.

It may imply:

```text
new PulseAudio stream
new measured latency
new sample origin
new clock anchor
old callbacks still completing
```

The safe model is a re-arm, not a cosmetic preference update.

Use generation/epoch identity to reject stale work.

Drain, flush, and destroy paths must also be bounded. Shutdown hangs are not just cleanup problems: they can prevent the application from returning control after a timing authority has been replaced.

---

# 7. Media decode never owns time

MLT is intentionally below ProjectTime.

The correct dependency is:

```text
ProjectTime N
    ↓
EDIT clip geometry
    ↓
requested source frame
    ↓
MLT decoder
```

Never:

```text
MLT playback position
    ↓
project time
```

A decoder may return pending. It may need to seek. It may initialize slowly. None of those facts changes authored time.

For exact offline paths, the renderer waits for the requested frame.

For live paths, the renderer can hold visibility or keep an outgoing cover while the requested frame becomes ready.

The project clock continues either way.

---

# 8. Preview and BAKE use time differently but mean the same thing

Preview:

```text
native realtime/audio authority
    ↓
sampled ProjectTime
    ↓
scene evaluation
```

BAKE:

```text
for i = 0 .. totalFrames - 1
    ↓
ProjectTime(frame: i, mode: scrub)
    ↓
exact scene evaluation
    ↓
render frame i
```

The mechanisms differ. The authored meaning must not.

This distinction is one of the most important design decisions in the repository.

Trying to force export through the realtime clock would make deterministic offline rendering dependent on wall-clock behavior. Trying to force realtime playback through export-style synchronous decode would make the UI block on media.

One time model; different schedulers.

---

# 9. Failure modes to recognize

## Symptom: playback stutters

Do not assume project time is wrong.

Measure separately:

```text
clock error
decoder readiness
Flutter UI thread cost
paint cost
texture delivery
```

M4 showed that audio-clock authority and MLT decode could remain locked while later EDIT playback still stuttered because the Flutter timeline repaint path was too expensive.

## Symptom: frame changes after a seek

Check epoch ownership. A stale asynchronous decode may have completed after the seek.

## Symptom: Preview and BAKE differ by one frame

Inspect evaluation order and whether one path ticks before paint while the other paints before tick.

The rule is explicit: project frame `i` means the same `ProjectTime(frame: i)` in both paths.

## Symptom: audio sounds early or late

Check audible device latency, not only queued/submitted sample count.

---

# 10. Proof

Useful proof includes:

- `test/audio_packet_contract_test.dart`
- `test/audio_sink_native_test.dart`
- ProjectClock tests in the test suite
- `docs/M4_AV_LOCK_VALIDATION.md`
- the A/V lock probe under `tool/`
- SceneExporter end-to-end tests that select exact frames

The strongest validation is layered:

```text
clock model tests
    +
native audio measurement
    +
media-under-load measurement
    +
Preview/BAKE exact-frame tests
```

No single layer substitutes for the others.

---

# Reconstruction checklist

Before implementing serious NLE editing, prove all of these:

- [ ] frame rate is rational canonical state;
- [ ] project time is not a `double` accumulated by UI callbacks;
- [ ] seeking creates new invalidation identity;
- [ ] Flutter repaint cadence cannot advance project time;
- [ ] exact frame N can be evaluated explicitly;
- [ ] export can select frame N without a realtime clock;
- [ ] media decode receives requested time rather than producing it;
- [ ] audio authority subtracts measured output latency;
- [ ] audio queueing is bounded;
- [ ] device replacement cannot let stale callbacks retake authority;
- [ ] Preview and BAKE agree on the meaning of frame N.

If these are true, the rest of the NLE can be built on stable ground.