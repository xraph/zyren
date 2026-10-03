part of '../zyren_timeline.dart';

typedef _ActionSnapshot = ({
  Duration position,
  Duration traversal,
  double weight,
  Duration elapsed,
});
typedef _ActionFade = ({double from, double to, Duration duration});

/// An independent clip clock owned by an attached mixed timeline.
final class TimelineAction {
  final SceneTimelinePlugin _owner;
  final TimelineClip clip;
  Duration _position = Duration.zero, _elapsed = Duration.zero;
  Duration _traversal = Duration.zero;
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

  /// Signed playback travel. Seeks do not contribute; loop crossings do.
  Duration get traversal => _traversal;
  double get weight => _weight;
  bool get isPlaying => _playing;

  /// Captures the independent clock and remaining fade without sampling a pose.
  Map<String, Object?> captureState() {
    _check();
    return Map.unmodifiable({
      'version': 1,
      'position': _position.inMicroseconds,
      'traversal': _traversal.inMicroseconds,
      'elapsed': _elapsed.inMicroseconds,
      'weight': _weight,
      'playing': _playing,
      'loop': loop,
      'reverse': reverse,
      'fade': _fade == null
          ? null
          : Map<String, Object?>.unmodifiable({
              'from': _fade!.from,
              'to': _fade!.to,
              'duration': _fade!.duration.inMicroseconds,
            }),
    });
  }

  void validateState(Map<String, Object?> state) {
    _check();
    const keys = {
      'version',
      'position',
      'traversal',
      'elapsed',
      'weight',
      'playing',
      'loop',
      'reverse',
      'fade',
    };
    bool clock(Object? v, {bool signed = false}) =>
        v is int && v.abs() <= 9000000000000000 && (signed || v >= 0);
    bool weight(Object? v) => v is num && v.isFinite && v >= 0 && v <= 1;
    if (state.length != keys.length ||
        !keys.containsAll(state.keys) ||
        state['version'] != 1 ||
        !clock(state['position']) ||
        (state['position'] as int) > clip.duration.inMicroseconds ||
        !clock(state['traversal'], signed: true) ||
        !clock(state['elapsed']) ||
        !weight(state['weight']) ||
        state['playing'] is! bool ||
        state['loop'] is! bool ||
        state['reverse'] is! bool) {
      throw const FormatException('Invalid timeline action checkpoint.');
    }
    final fade = state['fade'];
    if (fade != null &&
        (fade is! Map<String, Object?> ||
            fade.length != 3 ||
            !weight(fade['from']) ||
            !weight(fade['to']) ||
            !clock(fade['duration']) ||
            (fade['duration'] as int) <= 0 ||
            (state['elapsed'] as int) > (fade['duration'] as int))) {
      throw const FormatException('Invalid timeline fade checkpoint.');
    }
  }

  void _loadState(Map<String, Object?> state) {
    _position = Duration(microseconds: state['position'] as int);
    _traversal = Duration(microseconds: state['traversal'] as int);
    _elapsed = Duration(microseconds: state['elapsed'] as int);
    _weight = (state['weight'] as num).toDouble();
    _playing = state['playing'] as bool;
    loop = state['loop'] as bool;
    reverse = state['reverse'] as bool;
    final fade = state['fade'] as Map<String, Object?>?;
    _fade = fade == null
        ? null
        : (
            from: (fade['from'] as num).toDouble(),
            to: (fade['to'] as num).toDouble(),
            duration: Duration(microseconds: fade['duration'] as int),
          );
  }

  /// Samples silently; malformed replacements leave all action state intact.
  void restoreState(Map<String, Object?> state) =>
      _owner.restoreActionStates({this: state});

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
  _ActionSnapshot _snapshot() => (
    position: _position,
    traversal: _traversal,
    weight: _weight,
    elapsed: _elapsed,
  );
  void _restore(_ActionSnapshot state) {
    _position = state.position;
    _traversal = state.traversal;
    _weight = state.weight;
    _elapsed = state.elapsed;
  }

  void _advance(Duration delta) {
    if (_playing) {
      final length = clip.duration.inMicroseconds;
      final local = _position.inMicroseconds;
      final deltaUs = delta.inMicroseconds;
      final travel = loop
          ? deltaUs
          : math.min(deltaUs, reverse ? local : length - local);
      _traversal += Duration(microseconds: reverse ? -travel : travel);
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

  /// Validates every action before applying their combined checkpoint pose.
  void restoreActionStates(Map<TimelineAction, Map<String, Object?>> states) {
    _attached;
    if (states.length > 1024 ||
        states.keys.any((action) => !identical(action._owner, this))) {
      throw const FormatException('Invalid timeline checkpoint owner.');
    }
    for (final entry in states.entries) {
      entry.key.validateState(entry.value);
    }
    final previous = {
      for (final action in states.keys) action: action.captureState(),
    };
    try {
      for (final entry in states.entries) {
        entry.key._loadState(entry.value);
      }
      _applyPose(_position);
    } catch (_) {
      for (final entry in previous.entries) {
        entry.key._loadState(entry.value);
      }
      rethrow;
    } finally {
      _syncActionDemand();
    }
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
