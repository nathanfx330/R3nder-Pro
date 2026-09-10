// ./lib/edit_playback_clock.dart
//
// Realtime ProjectClock adapter for the EDIT workspace.
//
// Flutter supplies only the poll cadence. The native ProjectClock remains the
// authority for elapsed project time. PLAY anchors monotonic time at an exact
// ProjectTime, PAUSE/SCRUB hold an exact authored position, and sampling never
// advances the clock by itself.
//
// In the application, EDIT borrows Main's long-lived realtime clock. Creating a
// second native clock would replace the process-global handle used by the audio
// sink; destroying that temporary editor clock would then leave Main's still-
// live clock unreachable. Standalone tests/tools still get an owned clock when
// no application clock exists.

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
  late final NativeRealtimeProjectClock _clock;
  late final bool _ownsClock;

  NativeEditPlaybackClock(RationalFrameRate rate) {
    final NativeRealtimeProjectClock? shared = sharedRealtimeProjectClock;
    if (shared != null && shared.rate == rate) {
      _clock = shared;
      _ownsClock = false;
    } else {
      _clock = NativeRealtimeProjectClock(rate);
      _ownsClock = true;
    }
  }

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
    if (_ownsClock) _clock.dispose();
  }
}
