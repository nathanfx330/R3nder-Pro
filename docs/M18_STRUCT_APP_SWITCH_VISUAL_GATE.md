# M18 Structural App-Switch Visual Gate

This is the manual validation gate for M18 after the focused automated gates are green.

The old six-line visual matrix was not reliably recovered, so this document uses an explicit **eight-case reconstruction** instead of pretending the original list is known. The purpose is coverage, not historical fidelity.

## What this gate validates

M18 owns whole-STRUCT presentation switching on the finished program plane.

The authored forms are adjacent structural placements such as:

```text
[STRUCT:MOSAIC.first]
[STRUCT:MOSAIC.second]
```

or fullscreen placements:

```text
[STRUCT:MOSAIC.first:FULL]
[STRUCT:MOSAIC.second:FULL]
```

The existing setting:

```text
[CONFIG:APPSWITCH:SLIDE]
```

also controls seamless STRUCT switching. There is no second STRUCT-specific switch setting.

This gate is about presentation behavior. It is not a replacement for the isolated automated gates for decoder lifetime, readiness, PREVIEW geometry, or PREVIEW/BAKE geometry parity.

## Fixture

Use two known-good structural sources with visibly different content. `MOSAIC.first` and `MOSAIC.second` are the canonical examples below, but any two real structural sources are acceptable as long as both resolve and are easy to distinguish visually.

A minimal authored shape is:

```text
[MOSAIC:first]
[PANE:pane1]
[CLIP:a:video/a.mp4:0:0:90:1]
[/CLIP]
[/PANE]
[/MOSAIC]

[MOSAIC:second]
[PANE:pane1]
[CLIP:b:video/b.mp4:0:0:90:1]
[/CLIP]
[/PANE]
[/MOSAIC]
```

Replace `video/a.mp4` and `video/b.mp4` with two short, known-good workspace clips if those paths do not already exist. The visual gate should use real decoded picture rather than an intentionally offline source, because black-flash and preload behavior are part of what is being watched.

## Expected default behavior

Without `APPSWITCH:SLIDE`, adjacency remains ordinary application choreography:

1. A closes toward the desktop.
2. The desktop is the interstitial plane.
3. B opens from the desktop into its authored presentation mode.
4. The terminal must **not** become fullscreen between adjacent STRUCT applications.
5. No stale frame from A may appear inside B.
6. No black flash should appear except an honest late/offline decode condition.

## Expected SLIDE behavior

With:

```text
[CONFIG:APPSWITCH:SLIDE]
```

seamless adjacency keeps the structural presentation alive.

- window -> window: direct structural handoff, no desktop/terminal interstitial.
- fullscreen -> fullscreen: direct structural handoff, no desktop/terminal interstitial.
- window -> fullscreen: deterministic 12-frame shell morph from the window rectangle to the full program frame.
- fullscreen -> window: deterministic 12-frame shell morph from the full program frame to the window rectangle.

For either mixed-mode morph:

- incoming local frame 0 is exactly the previous presentation geometry;
- the midpoint is between the two geometries;
- local frame 11 is exactly the target geometry;
- local frame 12 begins showing at the stable target geometry;
- terminal opacity remains zero through the seamless handoff;
- the incoming source must already be resident if preload completed normally;
- no decoder reopen seam or black flash should be visible.

## Eight-case reconstruction

Run each case in PREVIEW and scrub frame-by-frame across the A -> B boundary.

### 1. Default: window -> window

```text
[STRUCT:MOSAIC.first]
[STRUCT:MOSAIC.second]
```

Expected: A closes to desktop, B opens from desktop. Terminal never jumps fullscreen.

### 2. Default: fullscreen -> fullscreen

```text
[STRUCT:MOSAIC.first:FULL]
[STRUCT:MOSAIC.second:FULL]
```

Expected: A leaves fullscreen through normal close choreography, desktop is the interstitial plane, B opens to fullscreen. No terminal fullscreen interstitial.

### 3. Default: window -> fullscreen

```text
[STRUCT:MOSAIC.first]
[STRUCT:MOSAIC.second:FULL]
```

Expected: normal close-to-desktop then open-to-fullscreen choreography. There is **no** seamless 12-frame morph without `APPSWITCH:SLIDE`.

### 4. Default: fullscreen -> window

```text
[STRUCT:MOSAIC.first:FULL]
[STRUCT:MOSAIC.second]
```

Expected: normal close-to-desktop then open-to-window choreography. There is **no** seamless 12-frame morph without `APPSWITCH:SLIDE`.

### 5. SLIDE: window -> window

```text
[CONFIG:APPSWITCH:SLIDE]
[STRUCT:MOSAIC.first]
[STRUCT:MOSAIC.second]
```

Expected: direct structural handoff in the existing window shell. No desktop or terminal flash.

### 6. SLIDE: fullscreen -> fullscreen

```text
[CONFIG:APPSWITCH:SLIDE]
[STRUCT:MOSAIC.first:FULL]
[STRUCT:MOSAIC.second:FULL]
```

Expected: direct structural handoff on the full program plane. No desktop or terminal flash.

### 7. SLIDE: window -> fullscreen

```text
[CONFIG:APPSWITCH:SLIDE]
[STRUCT:MOSAIC.first]
[STRUCT:MOSAIC.second:FULL]
```

Expected: B appears in A's window geometry at handoff and morphs continuously to fullscreen over exactly 12 frames. No terminal resurrection, remount flash, or B decoder reopen.

### 8. SLIDE: fullscreen -> window

```text
[CONFIG:APPSWITCH:SLIDE]
[STRUCT:MOSAIC.first:FULL]
[STRUCT:MOSAIC.second]
```

Expected: B appears on A's fullscreen plane at handoff and morphs continuously to the window rectangle over exactly 12 frames. No terminal resurrection, remount flash, or B decoder reopen.

## PREVIEW inspection

Use the frame-exact scrubber, preferably with the editor in full-frame preview (`F11`). For each case:

- watch at normal speed once;
- scrub back to the A -> B boundary;
- inspect every frame around the handoff;
- confirm source-local picture continuity;
- confirm no one-frame desktop/terminal leak in a SLIDE case;
- confirm no black frame between the preloaded B and visible B;
- confirm mixed-mode geometry moves monotonically toward the target and lands exactly once.

## BAKE inspection

The automated BAKE gate already checks the mixed-mode geometry contract. The manual BAKE check is therefore a visual/raster smoke test, not a duplicate geometry unit test.

Bake at minimum the four `APPSWITCH:SLIDE` cases and inspect the same handoff in the encoded output.

For the two mixed-mode cases, compare PREVIEW and BAKE around the 12-frame morph. They must agree on:

- starting geometry;
- direction of travel;
- target geometry;
- no terminal interstitial;
- no black flash;
- B picture appearing in the same structural shell rather than as a remounted application.

If a BAKE-only raster issue appears while the public geometry gate remains green, treat it as a separate raster/compositor bug rather than rewriting the planning contract.

## Pass criteria

M18 may be called complete only when:

- focused structural test suite is green;
- decoder lifetime gate is green;
- readiness gate is green;
- mixed-mode PREVIEW geometry gate is green;
- PREVIEW/BAKE geometry parity gate is green;
- all eight reconstructed PREVIEW cases look correct;
- the four SLIDE BAKE smoke cases match PREVIEW visually;
- no black flash, stale source frame, decoder reopen seam, terminal fullscreen interstitial, or off-by-one geometry landing is observed.

VIDEO and PANEL behavior are outside this M18 visual gate except where they are used as leaf media inside a structural source.