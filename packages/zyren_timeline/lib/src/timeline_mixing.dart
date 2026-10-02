part of '../zyren_timeline.dart';

/// An immutable custom pose track that can join the timeline's action mixer.
/// Copies must retain the target and duration. Preparation must not mutate state.
abstract class BlendableTimelineTrack extends TimelineTrack {
  BlendableTimelineTrack snapshot();
  bool canBlendWith(BlendableTimelineTrack other);
  void Function() prepareBlend(
    List<TimelineBlendSample> absolute,
    List<TimelineBlendSample> additive,
  );
}

/// A weighted local sample, with a reference time for additive contributions.
final class TimelineBlendSample {
  final BlendableTimelineTrack track;
  final Duration time, referenceTime;
  final double weight;
  const TimelineBlendSample(
    this.track,
    this.time,
    this.weight, {
    this.referenceTime = Duration.zero,
  });
}

/// A copied set of built-in tracks or opt-in blendable custom tracks.
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
  if (track is BlendableTimelineTrack) {
    final copy = track.snapshot();
    if (!identical(copy.target, track.target) ||
        copy.end != track.end ||
        !track.canBlendWith(copy) ||
        !copy.canBlendWith(track)) {
      throw ArgumentError(
        'A blendable snapshot must preserve target, duration and compatibility.',
      );
    }
    return copy;
  }
  throw ArgumentError(
    'Mixed clips require built-in or BlendableTimelineTrack tracks.',
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
  final Duration? sampleTime;
  final bool loop, reverse, additive;
  final Duration referenceTime;
  final List<ClipWeight> weights;
  TimelineLayer({
    required this.clip,
    required Iterable<ClipWeight> weights,
    this.start = Duration.zero,
    this.sampleTime,
    this.loop = false,
    this.reverse = false,
    this.additive = false,
    this.referenceTime = Duration.zero,
  }) : weights = List.unmodifiable(weights) {
    if (start.isNegative || (sampleTime?.isNegative ?? false)) {
      throw ArgumentError('Layer start must be nonnegative.');
    }
    if (referenceTime.isNegative || referenceTime > clip.duration) {
      throw ArgumentError('Additive reference time must fit the clip.');
    }
    _validateTimes(this.weights.map((weight) => weight.time));
  }

  Duration localTimeAt(Duration time) {
    if (sampleTime != null) return _clipTime(sampleTime!, clip.duration);
    final elapsed = math.max(0, (time - start).inMicroseconds);
    final local = loop
        ? elapsed % clip.duration.inMicroseconds
        : math.min(elapsed, clip.duration.inMicroseconds);
    return Duration(
      microseconds: reverse ? clip.duration.inMicroseconds - local : local,
    );
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
      final baseline = base._targets[track.target];
      final compatible =
          baseline is BlendableTimelineTrack && track is BlendableTimelineTrack
          ? baseline.canBlendWith(track) && track.canBlendWith(baseline)
          : baseline?.runtimeType == track.runtimeType;
      if (!compatible) {
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
    final additions = <TimelineLayer>[];
    var total = 0.0;
    for (final layer in layers) {
      final weight = layer.weightAt(time);
      if (weight == 0) continue;
      if (layer.additive) {
        additions.add(layer);
        continue;
      }
      total += weight;
      active.add((
        track: layer.clip._targets[target]!,
        time: layer.localTimeAt(time),
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
    if (track case final BlendableTimelineTrack custom) {
      return custom.prepareBlend(
        List.unmodifiable([
          for (final sample in active)
            TimelineBlendSample(
              sample.track as BlendableTimelineTrack,
              sample.time,
              sample.weight,
            ),
        ]),
        List.unmodifiable([
          for (final layer in additions)
            TimelineBlendSample(
              layer.clip._targets[target]! as BlendableTimelineTrack,
              layer.localTimeAt(time),
              layer.weightAt(time),
              referenceTime: layer.referenceTime,
            ),
        ]),
      );
    }
    if (track is TransformTrack) {
      var pose = _blendTransforms(active);
      for (final layer in additions) {
        pose = _addTransform(pose, layer, target, time);
      }
      return () {
        target.position = pose.position;
        target.scale = pose.scale;
        target.quaternion = pose.rotation;
        target.visible = pose.visible;
      };
    }
    var pose = _blendCameras(active);
    for (final layer in additions) {
      pose = _addCamera(pose, layer, target, time);
    }
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

TransformKeyframe _addTransform(
  TransformKeyframe pose,
  TimelineLayer layer,
  Object3D target,
  Duration time,
) {
  final track = layer.clip._targets[target] as TransformTrack;
  final sample = track._sample(layer.localTimeAt(time));
  final reference = track._sample(layer.referenceTime);
  final weight = layer.weightAt(time);
  double factor(double value, double base) {
    final ratio = value / base;
    if (ratio <= 0 || !ratio.isFinite) {
      throw ArgumentError('Additive scales must match reference signs.');
    }
    return 1 + (ratio - 1) * weight;
  }

  final r = reference.rotation;
  final delta = Quat(-r.x, -r.y, -r.z, r.w) * sample.rotation;
  return TransformKeyframe(
    Duration.zero,
    position: pose.position + (sample.position - reference.position) * weight,
    scale: Vec3(
      pose.scale.x * factor(sample.scale.x, reference.scale.x),
      pose.scale.y * factor(sample.scale.y, reference.scale.y),
      pose.scale.z * factor(sample.scale.z, reference.scale.z),
    ),
    rotation: pose.rotation * _slerp(Quat.identity, delta, weight),
    visible: pose.visible,
  );
}

CameraKeyframe _addCamera(
  CameraKeyframe pose,
  TimelineLayer layer,
  Object3D target,
  Duration time,
) {
  final track = layer.clip._targets[target] as CameraTrack;
  final sample = track._sample(layer.localTimeAt(time));
  final reference = track._sample(layer.referenceTime);
  final weight = layer.weightAt(time);
  return CameraKeyframe(
    Duration.zero,
    position: pose.position + (sample.position - reference.position) * weight,
    target: pose.target + (sample.target - reference.target) * weight,
    up: (pose.up + (sample.up - reference.up) * weight).normalized(),
  );
}
