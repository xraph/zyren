part of 'clip.dart';

enum AnimationLoop { once, repeat, pingPong }

final class _Playback {
  double phase, speed, weight;
  AnimationLoop loop;
  bool paused, finished, fresh;
  _Playback({
    required this.phase,
    required this.speed,
    required this.weight,
    required this.loop,
    this.paused = false,
    this.finished = false,
    this.fresh = true,
  });
  _Playback copy() => _Playback(
    phase: phase,
    speed: speed,
    weight: weight,
    loop: loop,
    paused: paused,
    finished: finished,
    fresh: fresh,
  );
  double time(double duration) =>
      loop == AnimationLoop.pingPong && phase > duration
      ? 2 * duration - phase
      : phase;
  bool get advancing => !paused && !finished && speed != 0;
}

/// Playback state belongs to one mixer. Finished and paused actions retain their
/// pose contribution until stopped; stop restores any unclaimed rest channels.
final class AnimationAction {
  final AnimationMixer _mixer;
  final AnimationClip clip;
  _Playback _state;
  bool _stopped = false;
  AnimationAction._(this._mixer, this.clip, this._state);
  bool get isStopped => _stopped;
  bool get isPaused => _state.paused;
  bool get isFinished => _state.finished;
  bool get isPlaying => !_stopped && !_state.paused && !_state.finished;
  double get timeSeconds => _state.time(clip.durationSeconds);
  Duration get time => Duration(microseconds: (timeSeconds * 1e6).round());
  double get speed => _state.speed;
  set speed(double value) {
    _speed(value);
    _change((s) {
      if (s.speed == 0 && value != 0) s.fresh = true;
      s.speed = value;
    });
  }

  double get weight => _state.weight;
  set weight(double value) {
    _weight(value);
    _change((s) => s.weight = value);
  }

  AnimationLoop get loop => _state.loop;
  set loop(AnimationLoop value) => _change((s) {
    s.phase = timeSeconds;
    s.loop = value;
    s.paused |= s.finished;
    s.finished = clip.durationSeconds == 0;
  });
  void pause() => _change((s) => s.paused = true);
  void resume() {
    if (!_stopped && !_state.paused && !_state.finished) return;
    _change((s) {
      if (s.finished && clip.durationSeconds > 0) {
        s.phase = s.speed < 0 ? clip.durationSeconds : 0;
      }
      s.finished = clip.durationSeconds == 0;
      s.paused = false;
      s.fresh = true;
    });
  }

  void seek(Duration time) {
    if (time.isNegative) throw ArgumentError.value(time, 'time');
    _change((s) {
      s.phase = (time.inMicroseconds / 1e6).clamp(0.0, clip.durationSeconds);
      s.paused |= s.finished;
      s.finished = clip.durationSeconds == 0;
      s.fresh = true;
    });
  }

  void stop() {
    if (_stopped) return;
    _mixer._apply(
      _mixer._actions.where((a) => !identical(a, this)).toList(),
      const {},
      invalidate: true,
    );
    _stopped = true;
  }

  void _change(void Function(_Playback) edit) {
    if (_stopped) {
      throw StateError(
        'This animation action has stopped. Play the clip again.',
      );
    }
    final next = _state.copy();
    edit(next);
    _mixer._apply(_mixer._actions, {this: next}, invalidate: true);
  }

  static void _speed(double value) {
    if (!value.isFinite || value.abs() > 1024) {
      throw ArgumentError.value(value, 'speed', 'Use [-1024, 1024].');
    }
  }

  static void _weight(double value) {
    if (!value.isFinite || value < 0 || value > 1) {
      throw ArgumentError.value(value, 'weight', 'Use [0, 1].');
    }
  }
}
