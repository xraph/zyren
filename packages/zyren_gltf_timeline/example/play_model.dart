import 'package:zyren_gltf/zyren_gltf.dart';
import 'package:zyren_gltf_timeline/zyren_gltf_timeline.dart';
import 'package:zyren_timeline/zyren_timeline.dart';

/// Add the returned instance to your scene and attach its timeline before play.
({ModelInstance instance, SceneTimelinePlugin timeline}) animatedModel(
  ModelAsset asset, {
  int animationIndex = 0,
  bool loop = true,
  bool reverse = false,
}) {
  final instance = asset.instantiate();
  final timeline = modelTimeline(
    instance,
    asset.animations[animationIndex],
    loop: loop,
    reverse: reverse,
  );
  return (instance: instance, timeline: timeline);
}
