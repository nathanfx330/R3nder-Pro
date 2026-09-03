# M4 A/V Lock Reference

This fixture measures end to end preview sync. It does not add a second project clock and it does not infer sync from internal counters. The reference is recorded from the real monitor and real speaker together so display latency, audio device latency, and R3nder's ProjectClock handoff are all inside the same measurement.

## Reference timing

R3nder preview is 30 fps for this test.

`reference_template.txt` runs one `SVGFLASH` folder containing two files:

* `00_dark.svg` renders no visible geometry for 15 frames.
* `01_flash.svg` renders a full frame white stencil for 15 frames.

One complete dark plus bright cycle is therefore 30 frames, exactly one second. The visual edge changes every 15 frames, exactly 0.5 seconds. The template runs 300 cycles, exactly five minutes.

The matching voice bed is a 48 kHz stereo WAV with a short 1 kHz click every 0.5 seconds. Every click is therefore authored at the same project time as a visual edge.

## Prepare a workspace

From the repository root, set `WORKSPACE` to the workspace you want to use for this measurement.

```bash
export WORKSPACE=/path/to/your/workspace
mkdir -p "$WORKSPACE/images/m4_av_lock" "$WORKSPACE/audio"
cp tools/m4_av_lock/00_dark.svg "$WORKSPACE/images/m4_av_lock/"
cp tools/m4_av_lock/01_flash.svg "$WORKSPACE/images/m4_av_lock/"
cp tools/m4_av_lock/reference_template.txt templates/m4_av_lock_reference.txt
```

Generate the matching five minute click track with FFmpeg:

```bash
ffmpeg -y \
  -f lavfi \
  -i "aevalsrc=if(lt(mod(t\,0.5)\,0.006)\,0.8*sin(2*PI*1000*t)\,0):s=48000:d=300" \
  -ac 2 \
  -c:a pcm_s16le \
  "$WORKSPACE/audio/m4_av_lock.wav"
```

In R3nder:

1. Open the workspace used above.
2. Select `m4_av_lock_reference.txt` as the template.
3. Attach `m4_av_lock.wav` as the VOICE bed.
4. Leave MUSIC empty.
5. Use the normal native audio output sink you actually work with.
6. Use F11 for the largest clean picture during the measurement.

## Physical measurement

Use one continuous camera recording that sees the monitor and hears the actual speaker. A phone at 60 fps or faster is enough to resolve a 30 fps project frame. Do not use Bluetooth for the baseline unless Bluetooth latency is what you intentionally want to test.

Record the complete five minute preview in one take. That single capture clock is what lets the first and last events prove drift rather than merely proving two independent startup offsets.

In an NLE, inspect the camera recording waveform and picture. For a chosen edge:

1. Find the first recorded frame showing the visual state change.
2. Find the onset of the matching audio click in the waveform.
3. Record `audio onset minus visual edge` in milliseconds.

Measure at minimum:

* about 5 seconds
* about 150 seconds
* about 295 seconds

The sign may reflect the physical monitor and speaker path. What matters is that the offset stays bounded and does not walk over time.

## Acceptance gate

For the baseline device:

* Absolute click versus visual edge error stays within one project frame, 33.333 ms.
* Start to end change in that error stays within one project frame over five minutes.
* There is no monotonic drift trend across the start, middle, and end samples.

Then repeat short runs across five stop and restart cycles. Every restart must return inside the same one frame bound with no accumulating offset.

Finally change audio output once and restart preview on the new output. That run must also return inside the same one frame bound. This specifically exercises the sink generation, anchor, release, and rearm path on real hardware.

## Record the result

For each run, keep these values:

```text
output device:
run number:
start offset ms:
middle offset ms:
end offset ms:
start to end drift ms:
notes:
```

M4 is evidence, not a code change. If this fixture passes, the result can be documented and landed without changing the timing architecture. If it fails, the measured sign and drift pattern tell us which layer to investigate next.
