/// Optional imported-model playback adapter.
library;

import 'package:zyren_gltf/zyren_gltf.dart';
import 'package:zyren_timeline/zyren_timeline.dart';

/// Uses the main timeline clock for imported TRS, skins, morphs and events.
SceneTimelinePlugin modelTimeline(
  ModelInstance instance,
  ModelAnimation animation, {
  bool loop = false,
  bool reverse = false,
  int maxEventsPerAdvance = 1024,
}) {
  final duration = animation.duration > Duration.zero
      ? animation.duration
      : const Duration(microseconds: 1);
  return SceneTimelinePlugin.mixed(
    duration: duration,
    base: modelClip(instance, animation),
    markers: [
      for (final event in animation.events)
        TimelineMarker(event.time, id: event.id, label: event.label),
    ],
    loop: loop,
    reverse: reverse,
    maxEventsPerAdvance: maxEventsPerAdvance,
  );
}

/// One atomic instance edit. Keep other writers off its nodes and geometry.
final class ModelAnimationTrack extends BlendableTimelineTrack {
  @override
  final ModelInstance target;
  final ModelAnimation? animation;
  @override
  final Duration end;
  ModelAnimationTrack(this.target, this.animation, this.end) {
    if (!target.animations.contains(animation) || end < animation!.duration) {
      throw ArgumentError(
        'Track animation must belong to its instance and fit its duration.',
      );
    }
  }
  ModelAnimationTrack.rest(this.target, this.end) : animation = null {
    if (end <= Duration.zero) {
      throw ArgumentError('Rest clip duration must be positive.');
    }
  }
  ModelPose _sample(Duration time) =>
      target.samplePose(animation: animation, time: time, initial: true);
  @override
  ModelAnimationTrack snapshot() => animation == null
      ? ModelAnimationTrack.rest(target, end)
      : ModelAnimationTrack(target, animation!, end);
  @override
  bool canBlendWith(BlendableTimelineTrack other) =>
      other is ModelAnimationTrack && identical(target, other.target);
  @override
  void Function() prepare(Duration time) =>
      target.prepareSampledPose(_sample(time));
  @override
  void Function() prepareBlend(
    List<TimelineBlendSample> absolute,
    List<TimelineBlendSample> additive,
  ) {
    ModelPose sample(TimelineBlendSample entry, Duration time) =>
        (entry.track as ModelAnimationTrack)._sample(time);
    return target.prepareBlendedPose(
      [
        for (final entry in absolute)
          ModelPoseContribution(sample(entry, entry.time), entry.weight),
      ],
      additive: [
        for (final entry in additive)
          ModelPoseContribution(
            sample(entry, entry.time),
            entry.weight,
            reference: sample(entry, entry.referenceTime),
          ),
      ],
    );
  }
}

/// An imported clip that participates in authored layers and runtime actions.
TimelineClip modelClip(ModelInstance instance, ModelAnimation animation) {
  final duration = animation.duration > Duration.zero
      ? animation.duration
      : const Duration(microseconds: 1);
  return TimelineClip(
    duration: duration,
    tracks: [ModelAnimationTrack(instance, animation, duration)],
  );
}

/// A stable authored rest pose for action mixers and additive layers.
TimelineClip modelRestClip(
  ModelInstance instance, {
  Duration duration = const Duration(seconds: 1),
}) => TimelineClip(
  duration: duration,
  tracks: [ModelAnimationTrack.rest(instance, duration)],
);
