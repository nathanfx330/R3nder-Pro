// ./lib/edit_playback_frame.dart
//
// Lightweight EDIT playback frame channel.
//
// ProjectClock remains the timing authority. EditWorkspace publishes the frame
// sampled at Flutter vsync through this stable listenable so descendants that
// need every presentation frame can listen directly without forcing the whole
// workspace through setState first.

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

/// Carries the stable playback listenable through EditSurface without making
/// every value change an inherited-widget rebuild. Consumers attach directly
/// to [listenable].
class EditPlaybackFrameScope extends InheritedWidget {
  final ValueListenable<EditPlaybackFrameState> listenable;

  const EditPlaybackFrameScope({
    super.key,
    required this.listenable,
    required super.child,
  });

  static ValueListenable<EditPlaybackFrameState>? maybeOf(
    BuildContext context,
  ) {
    return context
        .dependOnInheritedWidgetOfExactType<EditPlaybackFrameScope>()
        ?.listenable;
  }

  @override
  bool updateShouldNotify(EditPlaybackFrameScope oldWidget) {
    return !identical(oldWidget.listenable, listenable);
  }
}
