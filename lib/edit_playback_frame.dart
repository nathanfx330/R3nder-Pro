// ./lib/edit_playback_frame.dart
//
// Lightweight EDIT playback presentation channels.
//
// ProjectClock remains the timing authority. EditWorkspace publishes two
// stable listenables sampled at Flutter vsync: an integer frame channel for
// authored/edit semantics and small readouts, plus an exact rational position
// channel for presentation that must remain smooth between project frames.
// Neither channel forces the workspace itself through setState on every tick.

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

@immutable
class EditPlaybackFrameState {
  final int frame;
  final bool isPlaying;

  const EditPlaybackFrameState({
    required this.frame,
    required this.isPlaying,
  });

  @override
  bool operator ==(Object other) {
    return other is EditPlaybackFrameState &&
        other.frame == frame &&
        other.isPlaying == isPlaying;
  }

  @override
  int get hashCode => Object.hash(frame, isPlaying);
}

/// Exact realtime presentation position. Canonical time remains rational; the
/// derived double exists only for UI paint coordinates and is never fed back
/// into ProjectClock, authored clip geometry, or export.
@immutable
class EditPlaybackExactState {
  final int frame;
  final int phaseNumerator;
  final int phaseDenominator;
  final bool isPlaying;

  const EditPlaybackExactState({
    required this.frame,
    required this.phaseNumerator,
    required this.phaseDenominator,
    required this.isPlaying,
  }) : assert(phaseDenominator > 0);

  double get exactFrame => frame + phaseNumerator / phaseDenominator;

  @override
  bool operator ==(Object other) {
    return other is EditPlaybackExactState &&
        other.frame == frame &&
        other.phaseNumerator == phaseNumerator &&
        other.phaseDenominator == phaseDenominator &&
        other.isPlaying == isPlaying;
  }

  @override
  int get hashCode => Object.hash(
        frame,
        phaseNumerator,
        phaseDenominator,
        isPlaying,
      );
}

/// Carries stable playback listenables through EditSurface without making
/// value changes inherited-widget rebuilds. Consumers attach directly to the
/// channel they need.
class EditPlaybackFrameScope extends InheritedWidget {
  final ValueListenable<EditPlaybackFrameState> listenable;
  final ValueListenable<EditPlaybackExactState> exactListenable;

  const EditPlaybackFrameScope({
    super.key,
    required this.listenable,
    required this.exactListenable,
    required super.child,
  });

  static EditPlaybackFrameScope? _scope(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<EditPlaybackFrameScope>();
  }

  static ValueListenable<EditPlaybackFrameState>? maybeOf(
    BuildContext context,
  ) {
    return _scope(context)?.listenable;
  }

  static ValueListenable<EditPlaybackExactState>? maybeExactOf(
    BuildContext context,
  ) {
    return _scope(context)?.exactListenable;
  }

  @override
  bool updateShouldNotify(EditPlaybackFrameScope oldWidget) {
    return !identical(oldWidget.listenable, listenable) ||
        !identical(oldWidget.exactListenable, exactListenable);
  }
}
