part of '../zyren_timeline.dart';

/// A copied set of built-in absolute transform or camera tracks.
final class TimelineClip {
  final Duration duration;
  final List<TimelineTrack> tracks;
  final Map<Object3D, TimelineTrack> _targets = Map.identity();
  TimelineClip({
    required this.duration,
    required Iterable<TimelineTrack> tracks,
  }) : tracks = List.unmodifiable(tracks.map(_copyTrack)) {
    if (duration <= Duration.zero) {
      throw ArgumentError('Clip duration must be positive.');
    }
    for (final track in this.tracks) {
      if (track.end > duration || _targets.containsKey(track.target)) {
        throw ArgumentError(
          'Clip tracks must fit its duration and have distinct targets.',
        );
      }
      _targets[track.target] = track;
    }
  }
}

TimelineTrack _copyTrack(TimelineTrack track) {
  if (track.runtimeType == TransformTrack) {
    final source = track as TransformTrack;
    return TransformTrack(source.target, source.keyframes);
  }
  if (track.runtimeType == CameraTrack) {
    final source = track as CameraTrack;
    return CameraTrack(source.target, source.keyframes);
  }
  throw ArgumentError(
    'Mixed clips require built-in transform or camera tracks.',
  );
}

/// A layer weight at an absolute time on the containing timeline.
final class ClipWeight {
  final Duration time;
  final double value;
  ClipWeight(this.time, this.value) {
    if (time.isNegative || !value.isFinite || value < 0 || value > 1) {
      throw ArgumentError(
        'Weights need nonnegative time and values from zero to one.',
      );
    }
  }
}

/// Absolute clip sampling with a local start offset and a global weight curve.
final class TimelineLayer {
  final TimelineClip clip;
  final Duration start;
  final List<ClipWeight> weights;
  TimelineLayer({
    required this.clip,
    required Iterable<ClipWeight> weights,
    this.start = Duration.zero,
  }) : weights = List.unmodifiable(weights) {
    if (start.isNegative) {
      throw ArgumentError('Layer start must be nonnegative.');
    }
    _validateTimes(this.weights.map((weight) => weight.time));
  }

  double weightAt(Duration time) {
    final (index, fraction) = _segment(
      weights.map((key) => key.time).toList(),
      time,
    );
    final a = weights[index],
        b = weights[math.min(index + 1, weights.length - 1)];
    return a.value * (1 - fraction) + b.value * fraction;
  }
}

List<TimelineTrack> _mixTracks(
  Duration duration,
  TimelineClip base,
  Iterable<TimelineLayer> source,
) {
  final layers = List<TimelineLayer>.unmodifiable(source);
  for (final layer in layers) {
    if (layer.weights.last.time > duration) {
      throw ArgumentError('Layer weight keys must fit the timeline duration.');
    }
    for (final track in layer.clip.tracks) {
      if (base._targets[track.target]?.runtimeType != track.runtimeType) {
        throw ArgumentError(
          'Layer tracks must match a base target and track type.',
        );
      }
    }
  }
  return [
    for (final track in base.tracks)
      _MixedTrack(duration, base, track, [
        for (final layer in layers)
          if (layer.clip._targets.containsKey(track.target)) layer,
      ]),
  ];
}

Duration _clipTime(Duration time, Duration duration) => Duration(
  microseconds: time.inMicroseconds.clamp(0, duration.inMicroseconds),
);

typedef _WeightedSample = ({TimelineTrack track, Duration time, double weight});

final class _MixedTrack extends TimelineTrack {
  @override
  final Duration end;
  final TimelineClip base;
  final TimelineTrack track;
  final List<TimelineLayer> layers;
  _MixedTrack(this.end, this.base, this.track, this.layers);
  @override
  Object3D get target => track.target;

  @override
  void Function() prepare(Duration time) {
    final active = <_WeightedSample>[];
    var total = 0.0;
    for (final layer in layers) {
      final weight = layer.weightAt(time);
      if (weight == 0) continue;
      total += weight;
      active.add((
        track: layer.clip._targets[target]!,
        time: _clipTime(time - layer.start, layer.clip.duration),
        weight: weight,
      ));
    }
    if (total < 1) {
      active.insert(0, (
        track: track,
        time: _clipTime(time, base.duration),
        weight: 1 - total,
      ));
    } else if (total > 1) {
      for (var i = 0; i < active.length; i++) {
        final sample = active[i];
        active[i] = (
          track: sample.track,
          time: sample.time,
          weight: sample.weight / total,
        );
      }
    }
    if (track is TransformTrack) {
      final pose = _blendTransforms(active);
      return () {
        target.position = pose.position;
        target.scale = pose.scale;
        target.quaternion = pose.rotation;
        target.visible = pose.visible;
      };
    }
    final pose = _blendCameras(active);
    final camera = target as Camera;
    return () => camera.batch(() {
      camera.position = pose.position;
      camera.target = pose.target;
      camera.up = pose.up;
    });
  }
}

TransformKeyframe _blendTransforms(List<_WeightedSample> active) {
  final poses = [
    for (final sample in active)
      (
        pose: (sample.track as TransformTrack)._sample(sample.time),
        weight: sample.weight,
      ),
  ];
  var dominant = poses.first;
  for (final pose in poses.skip(1)) {
    if (pose.weight > dominant.weight) dominant = pose;
  }
  final reference = dominant.pose.rotation, sign = dominant.pose.scale;
  var position = Vec3.zero, scale = Vec3.zero;
  var x = 0.0, y = 0.0, z = 0.0, w = 0.0;
  for (final entry in poses) {
    final pose = entry.pose, weight = entry.weight;
    if (pose.scale.x.sign != sign.x.sign ||
        pose.scale.y.sign != sign.y.sign ||
        pose.scale.z.sign != sign.z.sign) {
      throw ArgumentError(
        'Active clip scales must have matching signs on each axis.',
      );
    }
    position += pose.position * weight;
    scale += pose.scale * weight;
    final q = pose.rotation;
    final dot =
        q.x * reference.x +
        q.y * reference.y +
        q.z * reference.z +
        q.w * reference.w;
    final aligned = dot < 0 ? -weight : weight;
    x += q.x * aligned;
    y += q.y * aligned;
    z += q.z * aligned;
    w += q.w * aligned;
  }
  return TransformKeyframe(
    Duration.zero,
    position: position,
    scale: scale,
    rotation: Quat(x, y, z, w),
    visible: dominant.pose.visible,
  );
}

CameraKeyframe _blendCameras(List<_WeightedSample> active) {
  var position = Vec3.zero, target = Vec3.zero, up = Vec3.zero;
  for (final entry in active) {
    final pose = (entry.track as CameraTrack)._sample(entry.time);
    position += pose.position * entry.weight;
    target += pose.target * entry.weight;
    up += pose.up * entry.weight;
  }
  return CameraKeyframe(
    Duration.zero,
    position: position,
    target: target,
    up: up.normalized(),
  );
}
