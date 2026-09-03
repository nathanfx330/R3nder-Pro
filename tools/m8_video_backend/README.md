# M8 Video Backend Bakeoff

This fixture decides the R3nder Pro video backend from measured frame behavior rather than from API preference.

## What it measures

Both backends keep one decoder open per clip for the entire workload. They receive the same frame requests against the same H.264 long GOP media.

The generated references are:

```text
1280x720
30 fps
600 frames
H.264
GOP 120
2 clips
```

Every frame carries a ten bit binary marker in the upper left. The benchmark decodes that marker from the returned Y plane, so a fast request for the wrong frame is a failure rather than a good timing result.

The workloads are:

```text
forward_jumps
mixed_random
backward_scrub
two_clip_alternating
```

`two_clip_alternating` keeps both clip decoders alive and switches between them on every request. This is the workload that most closely exercises the cache shape R3nder will need once multiple CLIPs can contribute to one project time.

The files are read once before measurement to warm the operating system file cache. The result therefore emphasizes decoder and seek behavior rather than disk ordering.

## Run

From the repository root:

```bash
bash tools/m8_video_backend/run_bakeoff.sh
```

The script generates the two media files, builds the persistent native harness, runs all workloads, prints a table, and writes:

```text
tools/m8_video_backend/m8_results.csv
```

## Build dependencies

The app itself does not gain these dependencies from this fixture. They are only needed to compile the M8 benchmark.

On Ubuntu or Debian the required development packages are normally provided by:

```bash
sudo apt install g++ pkg-config ffmpeg libmlt-dev libavformat-dev libavcodec-dev libavutil-dev
```

The build script accepts either the `mlt-framework-7` or `mlt-framework` pkg-config module name.

## Acceptance rule

Correctness is mandatory first. Every row must report all requested frames correct. If either backend returns a wrong embedded frame marker, that backend fails M8 regardless of timing.

After correctness, compare the latency distribution rather than only total time. The most important rows are:

```text
1. backward_scrub
2. two_clip_alternating
3. mixed_random
4. forward_jumps
```

Median shows ordinary responsiveness. P95 and maximum show whether scrubbing develops stalls or seek spikes.

The backend decision remains limited to video behavior. MLT does not get credit merely for being a higher level framework, and direct FFmpeg does not get credit merely for being a smaller dependency. The measured seek, backward scrub, multi clip, and frame correctness results decide M8.

## Architectural boundary

Neither benchmark backend owns project time.

The eventual R3nder interface remains conceptually:

```text
render(EditId, ProjectTime, Size)
```

M8 only decides which decoder implementation should answer the media frame request underneath that interface.
