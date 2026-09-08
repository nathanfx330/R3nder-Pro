# Linux Native Layer

R3nder Pro is currently developed and validated primarily on Linux. The native layer is not a generic platform wrapper; it carries several performance- and timing-critical responsibilities that Flutter/Dart deliberately do not own.

Primary files:

```text
linux/CMakeLists.txt
linux/runner/audio_sink.cc
linux/runner/audio_sink.h
linux/runner/media_decoder.cc
linux/runner/media_decoder.h
linux/runner/media_texture.cc
linux/runner/media_texture.h
linux/runner/project_clock.cc        (or equivalent native clock source)
linux/runner/project_clock.h
linux/runner/my_application.cc
```

Native validation also includes files such as:

```text
linux/runner/audio_sink_test.cc
linux/runner/media_decoder_test.cc
linux/runner/av_lock_probe.cc
```

Dart/FFI counterparts include:

```text
lib/project_clock.dart
lib/audio_sink.dart
lib/media_layer.dart
```

---

## Contract

The Linux native layer must guarantee:

- realtime ProjectClock authority is independent of Flutter vsync cadence;
- audio writes happen on a native worker rather than blocking the Flutter UI thread;
- audio queueing is bounded and observable;
- measured device latency is available to project-time calculation;
- MLT decoder objects persist across seeks/frame requests;
- live media decode can run asynchronously/nonblocking;
- decoded frames can be delivered to Dart or an external Flutter texture without changing project-time ownership;
- native shutdown/drain/flush behavior is bounded and cannot strand the application;
- Dart-facing FFI contracts remain narrow enough to fake/replace in tests.

---

# 1. Why native code exists

Flutter is excellent for the application/editor UI, but several operations should not be tied to the UI isolate or vsync scheduler:

```text
high-resolution monotonic timing
blocking PulseAudio writes
MLT decode / seek work
external texture delivery
```

Putting those responsibilities in native workers lets Flutter poll or present results without becoming the timing or decode authority.

The important design is not “native is faster.”

It is:

> Native workers own physical I/O and blocking work; authored timeline semantics remain in Dart/R3nder models.

---

# 2. Build dependencies

The top-level Linux CMake configuration discovers the native dependencies used by the runner.

A rebuild environment needs, at minimum, the dependencies described in the root README, including:

- GTK 3 development support;
- PulseAudio simple API development files;
- Epoxy/OpenGL integration used by texture delivery;
- MLT, normally the MLT 7 pkg-config module;
- standard C/C++ toolchain and CMake;
- Flutter Linux desktop toolchain.

FFmpeg/ffprobe remain external process dependencies for other application paths.

A reconstruction should verify pkg-config names on the target distribution instead of hardcoding one distro's package names into architectural assumptions.

---

# 3. Native ProjectClock

The realtime clock lives behind an FFI control block.

Dart sees snapshots such as:

```text
frame
phase numerator/denominator
epoch
mode
```

The native side owns the realtime anchor and mode transitions.

Flutter can sample it frequently without changing it.

The clock also accepts audio sample state so AUDIO mode can derive audible ProjectTime from cumulative samples minus device latency.

The native clock is linked into the runner process, and Dart opens the process image through FFI rather than requiring a separately distributed timing shared library.

A rebuild should preserve that lifecycle simplicity unless there is a strong packaging reason to split it.

---

# 4. Native audio sink

`audio_sink.cc` owns the blocking device-write path.

Dart sends bounded PCM packets. The native worker:

```text
accepts queued PCM
    ↓
blocks on PulseAudio writes off the Flutter thread
    ↓
tracks cumulative submitted samples
    ↓
measures/reports latency
    ↓
updates ProjectClock audio state
```

Key properties:

- bounded queue;
- explicit drain request;
- flush semantics;
- health/draining stats;
- no unbounded buffering in Dart;
- sample count remains cumulative across operations where the clock contract requires it.

The FFI call that enqueues should be short. The blocking device operation belongs to the worker.

---

# 5. Native media decoder

`media_decoder.cc` is the persistent MLT-backed leaf decoder implementation.

Its job is not to play the project.

Its job is to service requests shaped like:

```text
source path
requested source frame
output width/height
```

and produce exact decoded frame identity/pixels.

The decoder is designed to survive repeated requests rather than reconstructing MLT state for every frame.

A live worker can receive new target frames as the project clock advances or the user scrubs.

The Dart `MediaLayer` owns decoder instances and caches them by resolved media identity.

---

# 6. External texture delivery

`media_texture.cc` provides the zero-Dart-pixel live presentation path where available.

The same persistent decoder worker can deliver its current target into a Flutter external texture rather than copying every frame through a Dart `Uint8List`.

This optimization must not change semantic ownership.

The texture path is only a delivery mechanism:

```text
ProjectTime / clip model
    decides requested frame

native decoder
    produces that frame

texture
    presents pixels
```

Do not let the texture refresh callback become a new playhead.

---

# 7. Exact offline paths may still use blocking pixels

Live external textures are useful for interactive performance, but final structural source export requires exact deterministic pixels.

That path can use blocking decoder calls and packed RGBA because wall-clock latency is irrelevant to authored time.

Trying to force the live texture path into offline export would add unnecessary GPU/window-system coupling to a deterministic render job.

One media model can therefore expose different delivery strategies without changing source-frame selection.

---

# 8. Threading and lifetime

Native object lifetime is explicit.

A decoder/audio sink/clock handle created through FFI must have one clear Dart owner and one disposal path.

Important rules:

- do not destroy a decoder merely because one async result became stale;
- do destroy native resources when the owning media layer/workspace closes;
- do not block Flutter waiting indefinitely for a worker drain/destroy;
- stale worker completions must be rejected by generation/epoch identity;
- callbacks must not reference disposed Dart/widget state.

M3.1 and later media work repeatedly showed that shutdown and stale-callback behavior are part of correctness, not cleanup trivia.

---

# 9. Native tests are different from Flutter tests

Some guarantees cannot be proven meaningfully by a Dart fake.

Examples:

- PulseAudio stream creation and latency behavior;
- worker queue/drain/flush mechanics;
- persistent MLT seek behavior;
- external texture lifecycle;
- A/V clock stability under real decode load.

That is why the repository includes native test/probe sources in `linux/runner/` and the documented M4 measurement procedure.

The correct testing strategy is layered:

```text
pure Dart model tests
    ↓
Dart/FFI contract tests
    ↓
native unit/probe tests
    ↓
real Flutter GUI playback
```

No layer replaces the others.

---

# 10. Failure modes to recognize

## UI freezes during audio playback

A blocking device write has likely leaked onto the Flutter/UI thread.

## Audio clock drifts while decode load rises

Measure native clock/sample/latency state before changing visual frame cadence.

## Every scrub causes decoder startup latency

Persistent native decoder identity is being lost.

## Native frame is correct but Flutter preview stutters

The bottleneck may be timeline painting/layout rather than native decode.

## App hangs on close or device change

Drain/destroy join paths need bounded behavior and stale-generation handling.

## External texture shows stale frame after seek

The presentation path is not validating the current requested frame/epoch identity.

---

# 11. Reconstruction order

Implement native pieces in this order:

```text
1. native monotonic ProjectClock
2. Dart FFI snapshot/seek surface
3. native audio sink with bounded queue
4. audio sample + latency clock handoff
5. persistent MLT decoder
6. exact blocking frame request
7. nonblocking request/poll worker
8. external texture delivery
9. native validation probes under sustained load
```

Do not begin with texture optimization. Exact frame identity and lifetime behavior are more important foundations.

---

# Reconstruction checklist

- [ ] Linux build discovers GTK/PulseAudio/Epoxy/MLT explicitly;
- [ ] realtime clock authority is native and independent of vsync;
- [ ] Flutter only samples/repaints;
- [ ] audio writes occur on a native worker;
- [ ] audio queue is bounded and observable;
- [ ] audible latency participates in AUDIO ProjectClock;
- [ ] MLT decoders persist across requests;
- [ ] exact blocking frame requests validate requested/actual identity;
- [ ] live decode has a nonblocking path;
- [ ] texture delivery cannot become timeline authority;
- [ ] native resources have explicit bounded teardown;
- [ ] native tests/probes validate behavior impossible to prove with fakes.

If these hold, the native layer accelerates and grounds the editor without swallowing the project's creative semantics.