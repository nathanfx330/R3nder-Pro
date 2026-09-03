# EDIT Playback Performance Baseline

This note records the September 3, 2026 investigation that resolved the large realtime playback stutter in the EDIT surface.

## Symptom

Playback appeared to run at roughly 12 to 15 fps or worse. The video monitor and timeline playhead chugged together and periodically slowed further.

Several reasonable changes did not materially alter the visible problem: moving MLT decode work off the Dart thread, replacing a timer with Flutter Ticker, removing per frame EditWorkspace setState calls, adding an external Linux texture path, and preserving exact ProjectClock phase for the playhead.

The useful turning point was measuring Flutter FrameTiming instead of making another architecture change.

## Session 001

`r3nder_playback_session_001.log` was captured before timeline repaint isolation.

Observed behavior:

* Flutter UI thread work was roughly 86 to 106 ms on ordinary frames, with higher outliers.
* Ticker callbacks were commonly separated by about 116.7 ms, with 133.3 and 150 ms intervals also appearing.
* ProjectClock itself continued advancing correctly, so each delayed callback arrived several project frames later.
* The playhead and video therefore jumped together because Flutter was only producing roughly eight UI frames per second.

`FrameTiming.buildDuration` is the important field here. It covers the UI thread drawFrame work, including build, layout, paint recording, and semantics. The raster thread was much cheaper, which pointed to excessive display list recording rather than expensive pixel rasterization.

## Root cause

The exact playhead was a `CustomPainter(repaint: ...)`, but it lived in the same large timeline Stack as the static ruler, tracks, clips, and audio lanes with no repaint isolation between them.

Moving the playhead marked that paint region dirty. The static timeline was therefore recorded again whenever the playhead advanced.

The ruler made this especially expensive. `_EditRulerPainter` iterates across the full authored timeline width and lays out text labels for every major tick. For a long clip at the default zoom, that means thousands of tick iterations and hundreds of `TextPainter.layout()` calls in one paint.

The existing check:

```dart
if (x > size.width) break;
```

does not cull to the visible viewport. `size.width` is the full timeline width, not the width currently visible through the horizontal scroll view.

## Proven fix

Commit `4bdfa2b` separated the paint regions:

```text
static ruler + tracks + clips + audio
    RepaintBoundary

moving exact playhead
    separate RepaintBoundary
```

No decoder, texture, source mapping, or ProjectClock behavior changed in that experiment.

## Session 002

`r3nder_playback_session_002.log` was captured after repaint isolation.

Observed behavior:

* The user reported playback as smooth.
* Typical UI thread `build_us` fell to roughly 0.2 to 1.7 ms.
* Ticker cadence became mostly 16.7 ms with occasional missed refreshes at 33.3 ms.
* The previous roughly 90 ms fixed UI thread cost disappeared.

The reduction in UI thread frame cost was about sixty times, confirming that repaint propagation through the large static timeline was the dominant playback bottleneck.

A 30 fps project does not mean Ticker should fire every 33.3 ms on a 60 Hz display. Ticker normally follows display refresh at about 16.7 ms. The integer project frame publication naturally changes at roughly 33.3 ms.

## Known remaining ruler cost

The playback problem is fixed because the ruler no longer repaints with every playhead movement. The ruler itself is still intentionally unchanged.

When an operation genuinely invalidates it, such as timeline scrolling or zooming, `_EditRulerPainter` can still record the entire full width timeline. A future optimization should paint only the visible frame range and avoid repeated text shaping outside the viewport.

If a future trace shows a large UI thread frame specifically during timeline scroll or zoom, inspect this full width ruler paint first before investigating media decode.

## Playback tracing

The tracing path remains in the tree as a diagnostic tool but is opt in.

Enable it when launching R3nder:

```bash
R3NDER_PLAYBACK_TRACE=1 ./build/linux/x64/release/bundle/r3nder
```

Each PLAY session writes a numbered file in the project root when playback stops:

```text
r3nder_playback_session_001.log
r3nder_playback_session_002.log
...
```

The trace is buffered in memory during playback and written only when the session ends. Ordinary launches with no environment flag do not register the FrameTiming callback or create playback trace files.

The most useful fields are:

```text
TICK       Flutter Ticker cadence
CLOCK      ProjectClock frame and exact rational phase
EXACTPUB   exact presentation publication
INTPUB     integer project frame publication
FLUTTER    vsync, build_us, raster_us, total_us
```

When diagnosing UI chug, compare `build_us` and `raster_us` before changing the decoder or presentation architecture. A large `build_us` with a modest `raster_us` points toward excessive UI thread build, layout, or paint recording. A large `raster_us` points toward raster thread work instead.

## Working baseline

Session 002 is the first clean realtime EDIT playback performance baseline.

Future changes to the decoder worker, external texture path, preview mapping, timeline paint, or ProjectClock presentation should be measured against this baseline rather than against the broken session 001 behavior.
