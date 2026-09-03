// ./lib/edit_playback_clock.dart
//
// Realtime ProjectClock adapter for the EDIT workspace.
//
// Flutter supplies only the poll cadence. The native ProjectClock remains the
// authority for elapsed project time. PLAY anchors monotonic time at an exact
// ProjectTime, PAUSE/SCRUB hold an exact authored position, and sampling never
// advances the clock by itself.

import 'project_clock.dart';

abstract interface class EditPlaybackClock {
  RationalFrameRate get rate;
  ProjectTime sample();
  void playFrom(ProjectTime time);
  void holdAt(ProjectTime time);
  void dispose();
}

typedef EditPlaybackClockFactory = EditPlaybackClock Function(
  RationalFrameRate rate,
);

class NativeEditPlaybackClock implements EditPlaybackClock {
  final NativeRealtimeProjectClock _clock;

  NativeEditPlaybackClock(RationalFrameRate rate)
      : _clock = NativeRealtimeProjectClock(rate);

  @override
  RationalFrameRate get rate => _clock.rate;

  @override
  ProjectTime sample() => _clock.sample();

  @override
  void playFrom(ProjectTime time) {
    _clock.seekMonotonic(time.withMode(ProjectClockMode.monotonic));
  }

  @override
  void holdAt(ProjectTime time) {
    _clock.seekScrub(time.withMode(ProjectClockMode.scrub));
  }

  @override
  void dispose() {
    _clock.dispose();
  }
}
