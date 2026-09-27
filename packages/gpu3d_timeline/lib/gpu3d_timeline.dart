library;

import 'dart:async';
import 'dart:math' as math;
import 'package:gpu3d/gpu3d.dart';

const sceneTimeline = ServiceKey<SceneTimelinePlugin>('gpu3d.timeline');

/// A custom track validates and samples without mutation before returning its edit.
abstract class TimelineTrack {
  Object3D get target;
  Duration get end;
  void Function() prepare(Duration time);
  void apply(Duration time) => prepare(time)();
}

final class TransformKeyframe {
  final Duration time;
  final Vec3 position, scale;
  final Quat rotation;
  final bool visible;
  TransformKeyframe(
    this.time, {
    this.position = Vec3.zero,
    this.scale = Vec3.one,
    Quat rotation = Quat.identity,
    this.visible = true,
  }) : rotation = rotation.normalized() {
    if (time.isNegative ||
        !position.isFinite ||
        !scale.isFinite ||
        scale.x == 0 ||
        scale.y == 0 ||
        scale.z == 0) {
      throw ArgumentError(
        'Keyframes need nonnegative time and finite, nonsingular transforms.',
      );
    }
  }
}

class TransformTrack extends TimelineTrack {
  @override
  final Object3D target;
  final List<TransformKeyframe> keyframes;
  TransformTrack(this.target, Iterable<TransformKeyframe> keyframes)
    : keyframes = List.unmodifiable(keyframes) {
    _validateTimes(this.keyframes.map((key) => key.time));
    for (var i = 1; i < this.keyframes.length; i++) {
      final a = this.keyframes[i - 1].scale, b = this.keyframes[i].scale;
      if (a.x.sign != b.x.sign ||
          a.y.sign != b.y.sign ||
          a.z.sign != b.z.sign) {
        throw ArgumentError('Scale interpolation must not cross zero.');
      }
    }
  }
  @override
  Duration get end => keyframes.last.time;
  @override
  void Function() prepare(Duration time) {
    final (index, fraction) = _segment(
      keyframes.map((key) => key.time).toList(),
      time,
    );
    final a = keyframes[index],
        b = keyframes[math.min(index + 1, keyframes.length - 1)];
    final position = _lerp(a.position, b.position, fraction);
    final scale = _lerp(a.scale, b.scale, fraction);
    final rotation = _slerp(a.rotation, b.rotation, fraction);
    final visible = fraction == 1 ? b.visible : a.visible;
    return () {
      target.position = position;
      target.scale = scale;
      target.quaternion = rotation;
      target.visible = visible;
    };
  }
}

final class CameraKeyframe {
  final Duration time;
  final Vec3 position, target, up;
  CameraKeyframe(
    this.time, {
    required this.position,
    required this.target,
    this.up = const Vec3(0, 1, 0),
  }) {
    if (time.isNegative) {
      throw ArgumentError('Keyframe time must be nonnegative.');
    }
    _validateCamera(position, target, up);
  }
}

class CameraTrack extends TimelineTrack {
  @override
  final Camera target;
  final List<CameraKeyframe> keyframes;
  CameraTrack(this.target, Iterable<CameraKeyframe> keyframes)
    : keyframes = List.unmodifiable(keyframes) {
    _validateTimes(this.keyframes.map((key) => key.time));
  }
  @override
  Duration get end => keyframes.last.time;
  @override
  void Function() prepare(Duration time) {
    final (index, fraction) = _segment(
      keyframes.map((key) => key.time).toList(),
      time,
    );
    final a = keyframes[index],
        b = keyframes[math.min(index + 1, keyframes.length - 1)];
    final position = _lerp(a.position, b.position, fraction);
    final lookAt = _lerp(a.target, b.target, fraction);
    final up = _lerp(a.up, b.up, fraction);
    _validateCamera(position, lookAt, up);
    return () => target.batch(() {
      target.position = position;
      target.target = lookAt;
      target.up = up.normalized();
    });
  }
}

/// Absolute scene playback. Paused timelines do not request continuous frames.
class SceneTimelinePlugin extends ScenePlugin {
  @override
  String get id => 'gpu3d.timeline';
  final Duration duration;
  final List<TimelineTrack> tracks;
  bool loop;
  final _changes = StreamController<void>.broadcast();
  final _parents = Map<Object3D, Object3D?>.identity();
  PluginContext? _context;
  Registration? _demand;
  Duration _position = Duration.zero;
  bool _playing = false, _firstTick = true;
  SceneTimelinePlugin({
    required this.duration,
    required Iterable<TimelineTrack> tracks,
    this.loop = false,
  }) : tracks = List.unmodifiable(tracks) {
    if (duration <= Duration.zero) {
      throw ArgumentError('Timeline duration must be positive.');
    }
    final targets = Set<Object3D>.identity();
    for (final track in this.tracks) {
      if (track.end > duration || !targets.add(track.target)) {
        throw ArgumentError(
          'Tracks must fit the duration and have distinct targets.',
        );
      }
    }
  }
  Duration get position => _position;
  bool get isPlaying => _playing;
  Stream<void> get changes => _changes.stream;
  PluginContext get _attached =>
      _context ?? (throw StateError('Attach the timeline before playback.'));

  @override
  void attach(PluginContext context) {
    _context = context;
    for (final track in tracks) {
      _checkTarget(track.target);
      _parents[track.target] = track.target.parent;
    }
    context.provide(sceneTimeline, this);
  }

  void _checkTarget(Object3D target) {
    final context = _attached;
    if (target is Camera) {
      if (identical(target, context.camera)) return;
    } else if (!identical(target, context.scene)) {
      for (var node = target.parent; node != null; node = node.parent) {
        if (identical(node, context.scene)) return;
      }
    }
    throw StateError('Track target is outside the active scene or camera.');
  }

  /// Clamps to the clip range. Seeking preserves the current playback state.
  void seek(Duration time) {
    final context = _attached;
    final next = Duration(
      microseconds: time.inMicroseconds.clamp(0, duration.inMicroseconds),
    );
    try {
      final edits = <void Function()>[];
      for (final track in tracks) {
        _checkTarget(track.target);
        if (!identical(_parents[track.target], track.target.parent)) {
          throw StateError('Track target was reparented after attachment.');
        }
        edits.add(track.prepare(next));
      }
      context.scene.batch(() {
        for (final edit in edits) {
          edit();
        }
      });
      _position = next;
      _notify();
    } catch (_) {
      pause();
      rethrow;
    }
  }

  void play() {
    final context = _attached;
    if (_playing) return;
    seek(_position >= duration ? Duration.zero : _position);
    _firstTick = true;
    _demand = context.acquireFrameDemand();
    _playing = true;
    _notify();
  }

  void pause() {
    _demand?.dispose();
    _demand = null;
    _playing = false;
    _notify();
  }

  void _notify() {
    _changes.add(null);
    _context?.invalidate();
  }

  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
    if (!_playing) return;
    if (_firstTick) {
      _firstTick = false;
      return;
    }
    final next = _position + frame.delta;
    if (loop) {
      seek(
        Duration(microseconds: next.inMicroseconds % duration.inMicroseconds),
      );
    } else {
      seek(next);
      if (_position >= duration) pause();
    }
  }

  @override
  void detach(PluginContext context) {
    _context = null;
    pause();
    _parents.clear();
  }
}

void _validateTimes(Iterable<Duration> times) {
  Duration? previous;
  for (final time in times) {
    if (time.isNegative || (previous != null && time <= previous)) {
      throw ArgumentError('Keyframe times must increase strictly.');
    }
    previous = time;
  }
  if (previous == null) {
    throw ArgumentError('A track needs at least one keyframe.');
  }
}

(int, double) _segment(List<Duration> times, Duration time) {
  if (time <= times.first || times.length == 1) return (0, 0);
  for (var i = 1; i < times.length; i++) {
    if (time <= times[i]) {
      return (
        i - 1,
        (time - times[i - 1]).inMicroseconds /
            (times[i] - times[i - 1]).inMicroseconds,
      );
    }
  }
  return (times.length - 1, 0);
}

Vec3 _lerp(Vec3 a, Vec3 b, double t) => a * (1 - t) + b * t;

Quat _slerp(Quat a, Quat b, double t) {
  var dot = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
  if (dot < 0) {
    b = Quat(-b.x, -b.y, -b.z, -b.w);
    dot = -dot;
  }
  double left, right;
  if (dot > .9995) {
    left = 1 - t;
    right = t;
  } else {
    final angle = math.acos(dot.clamp(-1.0, 1.0)),
        sine = math.sin(math.acos(dot.clamp(-1.0, 1.0)));
    left = math.sin((1 - t) * angle) / sine;
    right = math.sin(t * angle) / sine;
  }
  return Quat(
    a.x * left + b.x * right,
    a.y * left + b.y * right,
    a.z * left + b.z * right,
    a.w * left + b.w * right,
  ).normalized();
}

void _validateCamera(Vec3 position, Vec3 target, Vec3 up) {
  final back = (position - target).normalized();
  up.normalized().cross(back).normalized();
  if (!position.isFinite || !target.isFinite) {
    throw ArgumentError('Camera pose must be finite.');
  }
}
