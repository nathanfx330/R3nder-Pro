# M4 Sustained A/V Lock Validation

M4 validates that R3nder's native preview clock remains audio authoritative while persistent MLT video decoding runs beside it.

This is a measurement milestone, not a transport rewrite.

## Architecture under test

```text
PulseAudio device
    ↓ measured device latency
NativeAudioSink
    ↓ cumulative played samples
ProjectClock AUDIO mode
    ↓ exact rational ProjectTime
video frame request
    ↓
persistent MLT decoder worker
```

The test deliberately keeps MLT out of clock ownership. MLT decodes source frames only. ProjectClock remains canonical project time.

## Probe

Run from the repository root:

```bash
dart run tool/av_lock_probe.dart
```

The runner generates a 20 second 1920x1080 30 fps H.264 reference clip, compiles the native probe, then performs two 15 second sessions:

1. `baseline`: real PulseAudio sink plus AUDIO ProjectClock, no video decode.
2. `video`: the same audio path while persistent MLT decoding is requested at a 60 Hz presentation sampling cadence.

The generated `r3nder_av_lock_session_NNN.log` is ignored by Git through the repository's existing `*.log` rule.

## Accepted measurement

Session 001 was recorded on September 3, 2026 from branch `m4-av-lock-validation` at `40ad2fa`.

Configuration:

```text
project:              30 fps
presentation sampler: 16.667 ms
sound:                48 kHz stereo s16le silence
video source:         1920x1080 30 fps H.264
MLT decode request:   960x540
run length:           15 seconds per mode
samples:              900 per mode
```

Results:

```text
BASELINE
AUDIO samples:                899 / 900
clock mode transitions:       1
clock absolute error p50:     7.326 us
clock absolute error p95:     7.326 us
clock absolute error max:     7.326 us

VIDEO
AUDIO samples:                899 / 900
clock mode transitions:       1
clock absolute error p50:     11.774 us
clock absolute error p95:     11.774 us
clock absolute error max:     11.774 us
video ready samples:          883
video holds after readiness:  0
A/V result:                   PASS
```

The 4.448 microsecond difference between the two clock error values is not accumulated drift. Each run captured a slightly different fractional frame as the audio sink's initial ProjectClock anchor. The error then remained constant for the full run. A drifting system would show increasing error or a materially larger p95/max than p50. This run showed neither.

## Video readiness interpretation

The first 17 video samples returned `poll=0`. They were one contiguous cold start interval while the MLT decoder initialized, ending at roughly 283 ms.

After first readiness:

```text
ready presentation samples: 883 / 883
held previous frame:         0
requested frame mismatch:    0 observed
```

The original v1 probe called `exact_frame - presented_integer_frame` `visual_lag_frames`. That name was misleading. Values such as `0.944` did not mean the decoder was 0.944 frames late. When ProjectClock was at `231.944`, the requested and presented frame were both exactly `231`; `0.944` was merely the fractional ProjectClock phase inside the correctly displayed integer frame.

The probe was subsequently renamed to report that quantity as frame phase and to count integer requested/presented mismatches explicitly.

## What M4 proves

The accepted run proves the following on the validation machine:

* AUDIO ProjectClock remains locked to cumulative played samples minus measured PulseAudio device latency while MLT decoding runs concurrently.
* Sustained MLT decode load does not introduce accumulated ProjectClock drift over the 15 second validation window.
* After decoder cold start, every sampled requested source frame was available exactly when polled.
* No previous video frame had to be held after first readiness.
* The audio worker remained healthy and its queue stayed bounded while video decoding was active.

## What M4 does not prove by itself

This native probe does not exercise Flutter's external GL texture compositor or the EDIT timeline paint tree. Those are separate presentation layers.

The accepted M10 playback investigation measured that layer independently. After isolating the moving playhead from the full width static timeline with `RepaintBoundary`, Flutter UI thread cost fell from roughly 92 ms median to roughly 1.46 ms median and real machine EDIT playback became smooth.

Together, the measurements separate the two failure domains:

```text
M4
native audio authority + ProjectClock + MLT decode under sustained load

M10 session 002
Flutter presentation + external texture + EDIT timeline paint cadence
```

Neither result should be substituted for the other.

## Acceptance rule

M4 is accepted when the native probe passes both baseline and video modes and the existing ProjectClock, audio sink, media decoder, and EDIT regression tests remain green.

Do not alter source frame cadence or clock ownership in response to fractional frame phase values. A source cadence change needs a separately observed and measured presentation defect.
