part of 'clip.dart';

/// Immutable playback snapshot. The referenced action may have advanced again
/// by the time a listener receives this event.
sealed class AnimationEvent {
  final AnimationAction action;
  final double timeSeconds;
  final int completedRepetitions;

  /// Playback speed direction, independent of ping-pong reflection. Zero speed
  /// on an immediately finished clip uses the forward direction (1).
  final int direction;
  Duration get time => Duration(microseconds: (timeSeconds * 1e6).round());
  AnimationEvent._(this.action)
    : timeSeconds = action.timeSeconds,
      completedRepetitions = action.completedRepetitions,
      direction = action.speed < 0 ? -1 : 1;
}

/// One event per action/update, even when a step crosses several boundaries.
final class AnimationLoopEvent extends AnimationEvent {
  final int repetitionsDelta;
  AnimationLoopEvent._(super.action, this.repetitionsDelta) : super._();
}

/// Natural completion. Seek, pause and stop never emit this event.
final class AnimationFinishedEvent extends AnimationEvent {
  AnimationFinishedEvent._(super.action) : super._();
}
