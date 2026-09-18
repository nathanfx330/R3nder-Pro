# CUE Range Sliding Journey

CUE range sliding moves only the authored CUE trigger. It does not resize the
presentation, rebuild its payload, migrate it to another CLIP, or turn timeline
geometry into persistent project state.

## Responsibility summary

Source model
: [CUE:<sourceFrame>] remains the sole authored trigger fact.

Occupied-range policy
: projectCueOccupiedSpans() remains the authority for presentation and shell
  ranges, including resolver-aware DOSSIER duration.

Drag geometry
: edit_cue_sliding.dart snapshots occupied spans at drag start and performs
  only pure rational/interval math while the pointer moves.

UI
: CueSpanLayer paints interactive interval bars above the existing landmark
  layer. It owns transient preview state but no project state.

Commit
: moveCueTrigger() replaces only the trigger digits, re-resolves current
  DOSSIER durations, validates the drag-start monotonicity contract, reparses,
  and proves the moved CUE still has the same absolute start offset.

## Why the old inverse is not an inverse

The authored CUE projection is:

    projectOffset = ceil(sourceDelta * denominator / numerator)

The existing playback helper sourceFrameAtProjectOffset() floors the sampled
source position. That is correct for playback and wrong as an inverse for cue
authoring.

At speed 4/5, integer source deltas 0 through 9 project to:

    0, 2, 3, 4, 5, 7, 8, 9, 10, 12

Project offsets 1, 6, and 11 are not authorable by any integer source CUE.

At speed 2/1 several source frames project to the same project offset. For
project offset 1, source deltas 1 and 2 are equivalent now. Cue sliding chooses
the smallest source delta, 1, as the canonical encoding.

The range slider therefore has explicit helpers for:

- reachable offset at or after a requested project offset
- reachable offset at or before it
- nearest reachable offset, choosing lower on an exact tie
- canonical smallest source delta for a reachable offset

At 4/5 a handle can visibly stick for one mouse frame and then jump two project
frames. That is a property of the source-backed format, not pointer jitter.

## CLIP limits

A CUE trigger must remain inside its owning CLIP. The presentation may continue
past the CLIP after firing.

The leftmost trigger is always CLIP offset 0.

The rightmost trigger is not blindly durationFrames - 1. It is:

    reachableAtOrBefore(durationFrames - 1)

This matters whenever the final project offset is one of the rational mapping
gaps.

Cross-CLIP cue migration is deliberately outside this milestone.

## Three preview states

Dragging distinguishes three states.

VALID
: The proposed position introduces no new conflicting partner and total overlap
  with drag-start partners is no greater than it was at drag start.

INVALID BUT PASSABLE
: No new partner is introduced, but overlap with an already-overlapping legacy
  partner is temporarily worse. The bar follows the pointer and paints as an
  invalid state. Releasing here does not commit.

BLOCKED
: The pointer attempts to cross the owning CLIP trigger boundary or a conflicting
  span that was not a partner at drag start. The preview stops at the hard wall.
  Releasing commits the clamped boundary position.

A legal cue starts with an empty partner set and zero overlap. It can therefore
never enter INVALID BUT PASSABLE. Its common-case behavior is only VALID or
BLOCKED.

## Why partners are snapshotted

The starting partner set and starting total overlap frames are captured exactly
once when the drag begins.

Recomputing them as the pointer moves would destroy the policy: a newly reached
span could become an existing partner on the next frame and the cue could smear
through the timeline one neighbor at a time.

The release rule is:

    afterPartners is a subset of startingPartners

and:

    afterTotalOverlapFrames <= startingTotalOverlapFrames

The second condition is release validation rather than a hard wall because
overlap amount is not monotonic in trigger position. A legacy cue must be able
to pass through a temporarily worse region to emerge clear on the far side.

## Stuck legacy configuration

A legacy cue can genuinely have no immediately releasable direction: worsening
an existing overlap on one side and hitting an unrelated hard-wall neighbor on
the other. The GUI did not create that state. The remedy is to change a
duration or move the other cue. The policy is not loosened to manufacture an
escape.

## DOSSIER workspace stability

The parent resolves all occupied spans before the drag starts. The slider uses
that frozen list throughout pointer movement, so there is no filesystem scan per
mouse update and no clamp shifting under the cursor.

At release, moveCueTrigger() projects the current document again with fresh
DOSSIER durations.

A changed evidence folder does not reject by itself. The commit is rejected only
when the freshly resolved occupied ranges make the proposed move illegal.

## Trigger-only mutation

All supported cue families share the same wrapper:

    [CUE:123]
      ...
    [/CUE]

The move operation validates the absolute cue start offset, locates the closing
] of the CUE header, and replaces only the decimal digits.

Changing 99 to 100 adds one byte and shifts later absolute source offsets. It
does not shift the moved cue's own start offset because its [ lies before the
replacement.

After commit every span is rederived. The moved cue is reacquired by its
unchanged absolute sourceStartOffset, never by (track, clip, sourceFrame),
because legacy source may contain two cues at the same source frame.

## UI layering

The existing TimelineLandmarkLayer remains zero-width timing truth.

CueSpanLayer is a separate interval layer. It draws presentation and shell
ranges, a center drag handle, and a continuation indicator when an unbounded
presentation extends beyond the authored EDIT ruler.

Policy ranges remain unbounded. Only drawing is clipped to the visible ruler.

Presentation and shell lanes remain visually distinct, but every current CUE
type is a hard collision partner for every other current CUE type. In
particular, MAXIMIZE stops at CARD, SIDECARD, and DOSSIER boundaries rather
than passing fullscreen shell motion through active presentation content.

The layer is disabled during playback.

No source mutation occurs during pointer movement. A successful release produces
one source-backed commit, so one Undo restores the previous trigger.

## Regression gates

The milestone is not complete without tests covering:

- explicit 4/5 reachable set
- upward/downward reachability idempotence
- nearest tie chooses lower
- 2/1 canonical source chooses the smallest equivalent frame
- CLIP right boundary quantizes downward
- legal conflicting cue clamps at abutment
- MAXIMIZE and presentation cues hard-clamp against each other
- legal cue cannot enter invalid-but-passable state
- legacy overlap can pass through an invalid middle region and clear
- a new conflicting partner is rejected at release
- trigger 99 to 100 preserves payload bytes and own source offset
- later offsets are rederived after that digit-width change
- fresh DOSSIER duration invalidates a stale-valid release when necessary
- pointer movement leaves source untouched
- successful release is one Undo step
- playback disables range authoring
