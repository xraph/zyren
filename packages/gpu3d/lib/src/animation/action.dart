part of 'clip.dart';

enum AnimationLoop { once, repeat, pingPong }

final class _Playback {
  double phase, speed, weight;
  AnimationLoop loop;
  int? repetitions;
  int completedRepetitions;
  bool paused, finished, fresh;
  _Playback({
    required this.phase,
    required this.speed,
    required this.weight,
    required this.loop,
    this.repetitions,
    this.completedRepetitions = 0,
    this.paused = false,
    this.finished = false,
    this.fresh = true,
  });
  _Playback copy() => _Playback(
    phase: phase,
    speed: speed,
    weight: weight,
    loop: loop,
    repetitions: repetitions,
    completedRepetitions: completedRepetitions,
    paused: paused,
    finished: finished,
    fresh: fresh,
  );
  double time(double duration) =>
      loop == AnimationLoop.pingPong && phase > duration
      ? 2 * duration - phase
      : phase;
  void advance(double seconds, double duration) {
    final direction = speed > 0 ? 1 : -1;
    final distance = seconds * speed.abs();
    // Absorb only roundoff at clip boundaries, including split frame deltas.
    final tolerance = duration * 1.7763568394002505e-15;
    if (loop == AnimationLoop.once) {
      phase = (phase + distance * direction).clamp(0.0, duration);
      finished = direction > 0
          ? duration - phase <= tolerance
          : phase <= tolerance;
      if (finished) {
        phase = direction > 0 ? duration : 0;
        completedRepetitions = 1;
      }
      return;
    }
    final local = phase % duration;
    final first = direction > 0
        ? duration - local
        : local == 0
        ? duration
        : local;
    final remaining = repetitions == null
        ? null
        : repetitions! - completedRepetitions;
    final finishDistance = remaining == null
        ? null
        : first + (remaining - 1) * duration;
    if (finishDistance != null &&
        distance +
                math.max(tolerance, finishDistance * 1.7763568394002505e-15) >=
            finishDistance) {
      if (loop == AnimationLoop.repeat) {
        phase = direction > 0 ? duration : 0;
      } else {
        final firstEnd = direction > 0
            ? (phase < duration ? duration : 0.0)
            : (phase > 0 && phase <= duration ? 0.0 : duration);
        phase = (remaining! - 1).isOdd ? duration - firstEnd : firstEnd;
      }
      completedRepetitions = repetitions!;
      finished = true;
      return;
    }
    if (distance + tolerance >= first) {
      final additional = math.max(
        0.0,
        (distance - first + tolerance) / duration,
      );
      // Keep counters exact on every Dart target and reject before publication.
      if (!additional.isFinite ||
          additional >= 9007199254740991 - completedRepetitions) {
        throw ArgumentError(
          'An animation step exceeds the exact repetition counter range.',
        );
      }
      completedRepetitions += additional.floor() + 1;
    }
    final period = loop == AnimationLoop.pingPong ? 2 * duration : duration;
    phase = (phase + direction * (distance % period)) % period;
    if (phase <= tolerance || period - phase <= tolerance) {
      phase = 0;
    } else if (loop == AnimationLoop.pingPong &&
        (phase - duration).abs() <= tolerance) {
      phase = duration;
    }
  }

  bool get advancing => !paused && !finished && speed != 0;
}

/// Playback state belongs to one mixer. Finished and paused actions retain their
/// pose contribution until stopped; stop restores any unclaimed rest channels.
final class AnimationAction {
  final AnimationMixer _mixer;
  final AnimationClip clip;
  final AnimationBlendMode blendMode;
  final Duration referenceTime;
  final Map<KeyframeTrack, Object> _referencePose;
  _Playback _state;
  bool _stopped = false;
  AnimationAction._(
    this._mixer,
    this.clip,
    this._state, {
    required this.blendMode,
    required this.referenceTime,
    required Map<KeyframeTrack, Object> referencePose,
  }) : _referencePose = Map.unmodifiable(referencePose);
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

  /// Total traversals, including the first; null repeats indefinitely.
  int? get repetitions => _state.repetitions;
  set repetitions(int? value) {
    _repetitions(value);
    _change((s) {
      s.repetitions = value;
      s.completedRepetitions = 0;
      s.paused |= s.finished;
      s.finished = clip.durationSeconds == 0;
    });
  }

  int get completedRepetitions => _state.completedRepetitions;

  AnimationLoop get loop => _state.loop;
  set loop(AnimationLoop value) => _change((s) {
    s.phase = timeSeconds;
    s.loop = value;
    s.completedRepetitions = 0;
    s.paused |= s.finished;
    s.finished = clip.durationSeconds == 0;
  });
  void pause() => _change((s) => s.paused = true);
  void resume() {
    if (!_stopped && !_state.paused && !_state.finished) return;
    _change((s) {
      if (s.finished && clip.durationSeconds > 0) {
        s.phase = s.speed < 0 ? clip.durationSeconds : 0;
        s.completedRepetitions = 0;
      }
      s.finished = clip.durationSeconds == 0;
      s.paused = false;
      s.fresh = true;
    });
  }

  void seek(Duration time) {
    if (time.isNegative) throw ArgumentError.value(time, 'time');
    _change((s) {
      s.completedRepetitions = 0;
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

  static void _repetitions(int? value) {
    if (value != null && (value < 1 || value > 1000000000)) {
      throw ArgumentError.value(
        value,
        'repetitions',
        'Use null or [1, 1000000000].',
      );
    }
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
