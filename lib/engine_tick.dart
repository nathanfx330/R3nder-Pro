// ./lib/engine_tick.dart

part of 'engine.dart';

// The terminal's deterministic frame step. Keeping the command/timing loop in
// its own part lets engine.dart describe state and helpers without burying the
// central execution path. The public TerminalEngine.tick() remains unchanged.

extension _TerminalEngineTicking on TerminalEngine {
  void _tickDeterministic() {
    if (isFinished) return;

    // SUSPENDED: a [GALLERY], [APP], [CARD], [DOSSIER], or [TIMELINE] tag is
    // waiting for the SceneEngine to play out. Time (frameCount) is owned by
    // the SceneEngine until it clears.
    if (_pendingPresentation != null) return;

    // SVG SHOW: the terminal screen is displaying a stencil. The engine owns
    // this hold completely (no SceneEngine involvement): count down the
    // current step, advance to the next step (SVGFLASH flicker), and on
    // expiry either CUT into a chained SVG/SVGFLASH tag or wipe and resume.
    if (activeSvg != null) {
      final ActiveSvgShow a = activeSvg!;
      a.framesLeft--;
      frameCount++;

      if (a.framesLeft <= 0) {
        a.stepIdx++;
        if (a.stepIdx < a.steps.length) {
          // Next flicker step, CUT.
          a.framesLeft = a.steps[a.stepIdx].frames;
        } else {
          // Show over: chain or exit.
          if (!_tryConsumeChainedShow()) {
            activeSvg = null;
            wipeScreen(); // Exit wipe: clean screen for the resuming script.
          }
        }
      }
      return;
    }

    // PHOTO GATE: a photo layer is currently blocking typing. PHOTO age is
    // derived from terminal frame distance, so this branch only advances the
    // terminal frame and asks whether the authored release point has arrived.
    //
    //  - CLASSIC layer (persist == false): releaseAt is the full hold, so
    //    this blocks the whole hold and then tears down — CUT into a chained
    //    SVG/PHOTO if one immediately follows, otherwise wipe (clearing the
    //    stack) and resume typing. Byte-identical to the pre-stack path.
    //  - STACK layer (persist == true): releaseAt is a % of the scan; the
    //    gate opens early, the layer STAYS on the stack and its scan keeps
    //    deriving from terminal age while following content runs.
    if (_photoGate != null) {
      final ActivePhotoShow g = _photoGate!;
      frameCount++;

      if (g.gateReleasedAt(frameCount)) {
        _photoGate = null; // Gate opens either way.
        if (!g.persist) {
          // Classic teardown.
          if (!_tryConsumeChainedShow()) {
            wipeScreen(); // clears the (single classic) layer + resumes typing
          }
        }
        // Stack layer: nothing else — it persists and keeps scanning behind
        // whatever comes next.
      }
      return;
    }

    // Advance Sprites regardless of pause/scramble state.
    _advanceSprites();

    if (pauseFrames > 0) {
      pauseFrames--;
      frameCount++;
      // The end hold rides the pause machinery: frameCount keeps advancing
      // (so blink/flash animate to the last frame), and only when the hold
      // fully expires does the engine report finished.
      if (pauseFrames == 0 && _endHoldStarted) {
        isFinished = true;
      }
      return;
    }

    if (activeBar != null) {
      final BarState bar = activeBar!;
      frameCount++;
      if (bar.completesAt(frameCount)) {
        activeBar = null;
      }
      return;
    }

    // IMG BAND GATE: block typing until the authored release point. The
    // band's rendered line owns its start frame, so reveal progress continues
    // directly from terminal age after this gate pointer is cleared.
    if (activeImgBand != null) {
      final ImgBandState band = activeImgBand!;
      // Consume this frame either way — releasing on the threshold frame
      // costs one dead tick, matching the pre-overlap block-to-completion
      // timing so existing (full-block) scripts stay frame-identical.
      frameCount++;
      if (band.gateReleasedAt(frameCount)) {
        activeImgBand = null;
      }
      return;
    }

    if (isScrambling && scrambleFramesLeft > 0) {
      scrambleFramesLeft--;
      frameCount++;
      return;
    }

    if (isScrambling && scrambleFramesLeft == 0 && scrambleTargetChar.isNotEmpty) {
      _commitChar(scrambleTargetChar);
      charIndex++;
      scrambleTargetChar = "";
      frameCount++;
      return;
    }

    for (int step = 0; step < charsPerFrame; step++) {
      if (charIndex >= text.length) {
        // Script exhausted: enter the engine-owned end hold. This tick counts
        // as the first hold frame; the pause branch above plays out the rest.
        if (!_endHoldStarted) {
          _endHoldStarted = true;

          // frameCount here IS the script's own length, which is why the bed
          // extension resolves at this moment rather than being precomputed.
          // Precomputing would need a dry run, and a dry run needs setup, and
          // setup is where the value would have to be set: circular.
          //
          // The bed starts when this engine takes its first tick (after the
          // preroll wipe when preroll is on), so both sides of this
          // subtraction are in the same timebase and preroll cancels out.
          final int bedRemaining = bedTargetFrames - frameCount;
          pauseFrames =
              bedRemaining > kEndHoldFrames ? bedRemaining : kEndHoldFrames;
        }
        frameCount++;
        return;
      }

      String char = text[charIndex];

      // --- PARSER ---
      if (char == '[') {
        final match = tagRegex.matchAsPrefix(text, charIndex) as RegExpMatch?;
        if (match != null) {
          charIndex += match.end - match.start;

          if (match.namedGroup('wipe') != null) {
            wipeScreen();
          } else if (match.namedGroup('svgFile') != null ||
              match.namedGroup('svgfFolder') != null) {
            // In-terminal SVG show: wipe, hold the stencil, wipe, resume.
            // The entry wipe happens HERE; the exit wipe (or a CUT into a
            // chained SVG tag) happens when the hold expires in the
            // activeSvg branch at the top of tick().
            final ActiveSvgShow? show = _buildSvgShow(match);
            if (show != null) {
              wipeScreen();
              activeSvg = show;
            } else {
              // Dud (missing/unparsable asset, warned at setup): burn the
              // scripted duration as a pause so the piece's timing holds.
              pauseFrames += _svgDudFrames(match);
            }
            break;
          } else if (match.namedGroup('photoFile') != null) {
            // [PHOTO] scanline layer. A classic (no-release) photo is a
            // fullscreen takeover: wipe everything (incl. any stack) and
            // show it alone, blocking the whole hold — exactly as before.
            // A stack (release%) photo LAYERS over the existing stack: only
            // the very first layer wipes the text canvas (to build the onion
            // on clean phosphor); subsequent layers push without wiping so
            // they scan in over the layers already there.
            final ActivePhotoShow? show = _buildPhotoShow(
              match,
              startFrame: frameCount + 1,
            );
            if (show != null) {
              if (show.persist) {
                if (_photoStack.isEmpty) {
                  wipeScreen(); // first onion layer: clear the text canvas
                }
                _pushPhoto(show);
              } else {
                wipeScreen(); // classic: clear everything, incl. any stack
                _photoStack.add(show);
                _photoGate = show;
              }
            } else {
              pauseFrames += _photoDudFrames(match);
            }
            break;
          } else if (match.namedGroup('imgFile') != null) {
            // [IMG] band: Programmed Symbols tile stamping. The band takes
            // its own line and reveals copies left to right. It gates the
            // typing engine (same contract as BAR) — but only until its
            // release point: an optional 5th segment gives the % of the
            // reveal at which the gate opens, letting the NEXT tag/text
            // begin while this band finishes revealing behind it. Omitted
            // (or >= 100) blocks the full reveal, exactly as before.
            final String file = match.namedGroup('imgFile')!;
            final String channel = match.namedGroup('imgChannel') ?? 'R';
            final int repeat =
                int.parse(match.namedGroup('imgRepeat') ?? '1');
            final int framesPer =
                int.parse(match.namedGroup('imgFrames') ?? '2');
            final int releasePct =
                int.parse(match.namedGroup('imgRelease') ?? '100');

            final ImgStencil? stencil = _imgLibrary['$channel:$file'];
            if (stencil != null) {
              _commitImgBand(stencil, repeat, framesPer, releasePct);
            } else {
              // Dud (missing/undecodable file, warned at setup): burn only
              // the GATED portion as a pause, so the following content lands
              // on the same frame whether or not the tile loaded.
              pauseFrames += ImgBandState.gateFrames(
                  math.max(repeat, 1), math.max(framesPer, 1), releasePct);
            }
            break;
          } else if (match.namedGroup('spritePath') != null) {
            final path = match.namedGroup('spritePath')!;
            final holdStr = match.namedGroup('spriteHold');
            final holdFrames = holdStr != null ? int.parse(holdStr) : 30;

            final frames = _spriteLibrary[path];
            if (frames != null && frames.isNotEmpty) {
              // Force newline if mid-typing
              if (currentLine.isNotEmpty) {
                renderedLines.add(LineData(
                  chars: List.from(currentLine), align: currentAlign,
                  spacing: currentLineSpacing, width: currentLineWidth
                ));
                currentLine.clear();
                currentLineWidth = 0;
                cursorY += currentLineSpacing;
                // Wipe check if the forced newline pushed us off screen
                if (cursorY > height - marginY) wipeScreen();
              }

              final sprite = _ActiveSprite(
                path: path,
                frames: frames,
                holdFrames: holdFrames,
                startLineIdx: renderedLines.length,
                lineCount: frames[0].length,
                startGlobalCharIndex: globalCharIndex,
                align: currentAlign,
                fontSize: currentFontSize,
                lineSpacing: currentLineSpacing,
                tracking: tracking,
                fgColor: penColor,
                bgColor: penBg,
                flashStyle: flashStyle,
              );

              // Commit frame 0 immediately
              final initialLines = _buildSpriteLines(sprite, 0);
              renderedLines.addAll(initialLines);
              _activeSprites[path] = sprite;

              cursorY += (sprite.lineCount * sprite.lineSpacing);
              if (cursorY > height - marginY) wipeScreen();
            }
            break;
          } else if (match.namedGroup('spriteOff') != null) {
            final path = match.namedGroup('spriteOff')!;
            _activeSprites.remove(path); // Freezes it in place
            break;
          } else if (match.namedGroup('pause') != null) {
            final int authoredPause = int.parse(match.namedGroup('pause')!);

            // A stack PHOTO can release its typing gate before its 30-frame
            // scan has finished. If PAUSE follows immediately, authors expect
            // the requested hold to begin AFTER the visible scan completes,
            // not to be consumed while the last layer is still drawing.
            //
            // Do not freeze or add a PHOTO clock. Instead extend this pause by
            // the largest remaining derived scan age in the current stack.
            // That is equivalent to waiting until the stack settles and then
            // parsing the same PAUSE, while keeping PHOTO evaluation tied only
            // to terminal frame age.
            int photoTail = 0;
            for (final ActivePhotoShow photo in _photoStack) {
              final int remaining =
                  photo.settleFrame - photo.elapsedAt(frameCount);
              if (remaining > photoTail) photoTail = remaining;
            }

            pauseFrames = authoredPause + photoTail;
            break;
          } else if (match.namedGroup('speed') != null) {
            final spd = match.namedGroup('speed')!;
            charsPerFrame = spd == 'MAX' ? 999999 : int.parse(spd);
          } else if (match.namedGroup('size') != null) {
            final sz = match.namedGroup('size')!;
            currentFontSize = sz == 'DEFAULT' ? baseFontSize : double.parse(sz) * scale;
          } else if (match.namedGroup('lead') != null) {
            final ld = match.namedGroup('lead')!;
            currentLineSpacing = ld == 'DEFAULT' ? baseLineSpacing : double.parse(ld) * scale;
          } else if (match.namedGroup('vpad') != null) {
            final padAmount = double.parse(match.namedGroup('vpad')!) * scale;
            renderedLines.add(LineData(
              chars: List.from(currentLine),
              align: currentAlign,
              spacing: padAmount,
              width: currentLineWidth,
            ));
            currentLine.clear();
            currentLineWidth = 0;
            cursorY += padAmount;
            if (cursorY > height - marginY) {
              wipeScreen();
            }
          } else if (match.namedGroup('align') != null) {
            currentAlign = match.namedGroup('align')!;
          } else if (match.namedGroup('bW') != null) {
            int bWidth = int.parse(match.namedGroup('bW')!);
            int bFrames = int.parse(match.namedGroup('bF')!);
            String bFill = match.namedGroup('bFill') ?? "█";
            String bEmpty = match.namedGroup('bEmpty') ?? " ";
            String bBrackets = match.namedGroup('bBrack') ?? "[]";

            if (bBrackets.toUpperCase() == "NONE") bBrackets = "";

            final barState = BarState(
              frames: bFrames,
              startFrame: frameCount + 1,
              width: bWidth,
            );
            activeBar = barState;

            if (bBrackets.isNotEmpty) {
              _commitChar(bBrackets[0]);
            }
            for (int i = 0; i < bWidth; i++) {
              _commitChar(bFill,
                  barInfo: BarInfo(
                    index: i,
                    fill: bFill,
                    empty: bEmpty,
                    state: barState,
                  ));
            }
            if (bBrackets.length > 1) {
              _commitChar(bBrackets[1]);
            }
            break;
          } else if (_tryQueuePresentation(match)) {
            // Desktop presentations suspend terminal time until SceneEngine
            // consumes the typed request and plays the deterministic sequence.
            break;
          } else if (match.namedGroup('redact') != null) {
            isRedacting = !match.namedGroup('redact')!.startsWith('/');
          } else if (match.namedGroup('line') != null) {
            currentRawLine = int.parse(match.namedGroup('line')!);
          } else if (match.namedGroup('scramble') != null) {
            isScrambling = (match.namedGroup('scramble') == 'on');
          } else if (match.namedGroup('invert') != null) {
            if (match.namedGroup('invert') == 'on') {
              penBg = fontColor;
              penColor = bgColor;
            } else {
              penBg = null;
              penColor = fontColor;
            }
          } else if (match.namedGroup('flash') != null) {
            final f = match.namedGroup('flash')!;
            flashStyle = f == 'OFF' ? null : f;
          } else if (match.namedGroup('regionId') != null) {
            currentRegion = match.namedGroup('regionId');
          } else if (match.namedGroup('regionEnd') != null) {
            currentRegion = null;
          } else if (match.namedGroup('selId') != null) {
            String sId = match.namedGroup('selId')!;
            Color? sBg;
            Color sFg = fontColor;

            final selBgStr = match.namedGroup('selBg');
            if (selBgStr != null && sId != "NONE") {
              final parts = selBgStr.split(',');
              sBg = Color.fromARGB(
                  255, int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
              sFg = const Color.fromARGB(255, 0, 0, 0); // High contrast text
            }

            List<CharData> updateBufferLine(List<CharData> line) {
              return line.map((cd) {
                if (cd.regionId != null) {
                  if (cd.regionId == sId) {
                    return cd.copyWith(fgColor: sFg, bgColor: sBg);
                  } else {
                    return cd.copyWith(fgColor: fontColor, clearBg: true);
                  }
                }
                return cd;
              }).toList();
            }

            for (int i = 0; i < renderedLines.length; i++) {
              renderedLines[i] = LineData(
                chars: updateBufferLine(renderedLines[i].chars),
                align: renderedLines[i].align,
                spacing: renderedLines[i].spacing,
                width: renderedLines[i].width,
                imgBand: renderedLines[i].imgBand,
              );
            }
            currentLine = updateBufferLine(currentLine);
          } else if (match.namedGroup('color') != null) {
            String c = match.namedGroup('color')!;
            switch (c) {
              case "RED":
                penColor = const Color.fromARGB(255, 255, 50, 50);
                break;
              case "GREEN":
                penColor = const Color.fromARGB(255, 50, 255, 50);
                break;
              case "BLUE":
                penColor = const Color.fromARGB(255, 50, 150, 255);
                break;
              case "YELLOW":
                penColor = const Color.fromARGB(255, 200, 200, 50);
                break;
              case "WHITE":
                penColor = const Color.fromARGB(255, 255, 255, 255);
                break;
              case "BLACK":
                penColor = const Color.fromARGB(255, 0, 0, 0);
                break;
              case "NORMAL":
                penColor = fontColor;
                penBg = null;
                flashStyle = null;
                break;
            }
          }
          continue;
        }
      }

      if (isScrambling && char != ' ' && char != '\n') {
        scrambleFramesLeft = _random.nextInt(5) + 2;
        scrambleTargetChar = char;
        frameCount++;
        return;
      }

      _commitChar(char);
      charIndex++;
    }

    frameCount++;
  }
}
