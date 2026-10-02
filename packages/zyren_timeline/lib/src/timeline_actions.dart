part of '../zyren_timeline.dart';

typedef _ActionSnapshot = ({
  Duration position,
  double weight,
  Duration elapsed,
});
typedef _ActionFade = ({double from, double to, Duration duration});

/// An independent clip clock owned by an attached mixed timeline.
final class TimelineAction {
  final SceneTimelinePlugin _owner;
  final TimelineClip clip;
  Duration _position = Duration.zero, _elapsed = Duration.zero;
  double _weight;
  bool _playing = false, _disposed = false;
  bool loop, reverse;
  final bool additive;
  final Duration referenceTime;
  _ActionFade? _fade;
  TimelineAction._(
    this._owner,
    this.clip,
    this._weight,
    this.loop,
    this.reverse,
    this.additive,
    this.referenceTime,
  ) {
    if (reverse) _position = clip.duration;
  }

  Duration get position => _position;
  double get weight => _weight;
  bool get isPlaying => _playing;

  void _check() {
    _owner._attached;
    if (_disposed) throw StateError('The action has been disposed.');
  }

  void play() {
    _check();
    final previous = _position;
    if ((!reverse && _position == clip.duration) ||
        (reverse && _position == Duration.zero)) {
      _position = reverse ? clip.duration : Duration.zero;
    }
    try {
      _owner._applyPose(_owner.position);
    } catch (_) {
      _position = previous;
      rethrow;
    }
    _playing = true;
    _owner._syncActionDemand();
  }

  void pause() {
    _check();
    _playing = false;
    _owner._syncActionDemand();
  }

  /// Samples this action silently without changing the main timeline clock.
  void seek(Duration time) {
    _check();
    final previous = _position;
    _position = _clipTime(time, clip.duration);
    try {
      _owner._applyPose(_owner.position);
    } catch (_) {
      _position = previous;
      rethrow;
    }
  }

  /// Replaces an in-progress fade from its current weight.
  void fadeTo(double weight, Duration duration) {
    _check();
    if (!weight.isFinite || weight < 0 || weight > 1 || duration.isNegative) {
      throw ArgumentError(
        'Fade weights must fit zero to one and time must be nonnegative.',
      );
    }
    final previous = _weight;
    if (duration == Duration.zero) {
      _weight = weight;
      try {
        _owner._applyPose(_owner.position);
      } catch (_) {
        _weight = previous;
        rethrow;
      }
      _fade = null;
    } else {
      _fade = (from: _weight, to: weight, duration: duration);
      _elapsed = Duration.zero;
    }
    _owner._syncActionDemand();
  }

  /// Starts the destination and fades both actions from their current weights.
  void crossFadeTo(TimelineAction destination, Duration duration) {
    _check();
    destination._check();
    if (!identical(_owner, destination._owner) ||
        identical(this, destination) ||
        duration <= Duration.zero) {
      throw ArgumentError(
        'Crossfades need distinct actions on one timeline and positive time.',
      );
    }
    destination.play();
    fadeTo(0, duration);
    destination.fadeTo(1, duration);
  }

  void dispose() {
    if (_disposed) return;
    _check();
    final index = _owner._actions.indexOf(this);
    _owner._actions.removeAt(index);
    try {
      _owner._applyPose(_owner.position);
    } catch (_) {
      _owner._actions.insert(index, this);
      _playing = false;
      _fade = null;
      _owner._syncActionDemand();
      rethrow;
    }
    _disposed = true;
    _owner._syncActionDemand();
  }

  bool get _needsFrame => _playing || _fade != null;
  _ActionSnapshot _snapshot() =>
      (position: _position, weight: _weight, elapsed: _elapsed);
  void _restore(_ActionSnapshot state) {
    _position = state.position;
    _weight = state.weight;
    _elapsed = state.elapsed;
  }

  void _advance(Duration delta) {
    if (_playing) {
      final length = clip.duration.inMicroseconds;
      final local = _position.inMicroseconds;
      final deltaUs = delta.inMicroseconds;
      if (loop) {
        final phase = reverse ? length - local : local;
        final next = (phase + deltaUs % length) % length;
        _position = Duration(microseconds: reverse ? length - next : next);
      } else {
        _position = Duration(
          microseconds: reverse
              ? local - math.min(deltaUs, local)
              : local + math.min(deltaUs, length - local),
        );
        if (_position == (reverse ? Duration.zero : clip.duration)) {
          _playing = false;
        }
      }
    }
    final fade = _fade;
    if (fade != null) {
      _elapsed += Duration(
        microseconds: math.min(
          delta.inMicroseconds,
          (fade.duration - _elapsed).inMicroseconds,
        ),
      );
      final fraction = _elapsed.inMicroseconds / fade.duration.inMicroseconds;
      _weight = fade.from * (1 - fraction) + fade.to * fraction;
      if (_elapsed == fade.duration) _fade = null;
    }
  }
}

extension TimelineActions on SceneTimelinePlugin {
  /// Creates a paused action. Its clip may contain any subset of base targets.
  TimelineAction createAction(
    TimelineClip clip, {
    double weight = 0,
    bool loop = false,
    bool reverse = false,
    bool additive = false,
    Duration referenceTime = Duration.zero,
  }) {
    _attached;
    final base = _base;
    if (base == null) throw StateError('Actions require a mixed timeline.');
    if (!weight.isFinite || weight < 0 || weight > 1) {
      throw ArgumentError('Action weight must fit zero to one.');
    }
    _mixTracks(duration, base, [
      TimelineLayer(
        clip: clip,
        additive: additive,
        referenceTime: referenceTime,
        weights: [ClipWeight(Duration.zero, weight)],
      ),
    ]);
    final action = TimelineAction._(
      this,
      clip,
      weight,
      loop,
      reverse,
      additive,
      referenceTime,
    );
    _actions.add(action);
    try {
      _applyPose(position);
    } catch (_) {
      _actions.remove(action);
      rethrow;
    }
    return action;
  }

  List<TimelineTrack> _poseTracks() {
    if (_actions.isEmpty) return tracks;
    return _mixTracks(duration, _base!, [
      ..._layers,
      for (final action in _actions)
        TimelineLayer(
          clip: action.clip,
          additive: action.additive,
          referenceTime: action.referenceTime,
          weights: [ClipWeight(Duration.zero, action.weight)],
          // A constant local clock decouples actions from main-clock seeks.
          sampleTime: action.position,
        ),
    ]);
  }

  void _syncActionDemand() {
    if (_actions.any((action) => action._needsFrame)) {
      if (_actionDemand == null) {
        _actionFirstTick = true;
        _actionDemand = _attached.acquireFrameDemand();
      }
    } else {
      _actionDemand?.dispose();
      _actionDemand = null;
    }
    _notify();
  }
}
