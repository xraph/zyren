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
  return SceneTimelinePlugin(
    duration: duration,
    tracks: [ModelAnimationTrack(instance, animation, duration)],
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
final class ModelAnimationTrack extends TimelineTrack {
  @override
  final ModelInstance target;
  final ModelAnimation animation;
  @override
  final Duration end;
  ModelAnimationTrack(this.target, this.animation, this.end) {
    if (!target.animations.contains(animation) || end < animation.duration) {
      throw ArgumentError(
        'Track animation must belong to its instance and fit its duration.',
      );
    }
  }
  @override
  void Function() prepare(Duration time) =>
      target.preparePose(animation: animation, time: time);
}
