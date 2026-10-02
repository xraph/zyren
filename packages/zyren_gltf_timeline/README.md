# zyren_gltf_timeline

Play imported glTF transforms, joints and morph weights through the timeline:

```dart
import 'package:zyren_gltf_timeline/zyren_gltf_timeline.dart';

final instance = model.instantiate();
scene.add(instance);
final timeline = modelTimeline(instance, model.animations.first, loop: true);
controller.use(timeline);
await controller.ready;
timeline.play();
```

This adapter is optional. `zyren_timeline` and `zyren_gltf` remain independent
packages, and the core has no importer dependency. You can pass `reverse: true`
and `maxEventsPerAdvance` to `modelTimeline`. Seeking is silent. Playback uses
the existing timeline's frame demand, reverse/loop boundaries and bounded events.

## Crossfades and additive poses

Use `modelClip` and `modelRestClip` with a mixed timeline when you want separate
animation clocks:

```dart
final timeline = SceneTimelinePlugin.mixed(
  duration: const Duration(seconds: 1),
  base: modelRestClip(instance),
);
controller.use(timeline);
await controller.ready;
final idle = timeline.createAction(modelClip(instance, idleAnimation), weight: 1)
  ..play();
final walk = timeline.createAction(modelClip(instance, walkAnimation), loop: true);
idle.crossFadeTo(walk, const Duration(milliseconds: 250));
```

Import `package:zyren_timeline/zyren_timeline.dart` for the mixer types. You can
also create actions on the timeline returned by `modelTimeline`; its base clip
follows the main clock. Use a rest base when you want every animation controlled
by its own action.

Each clip binds the whole instance. Missing channels sample its imported rest
pose, so you get deterministic results when seeking or interrupting a fade.
Absolute layers blend local joint transforms and morph weights, then deform the
mesh once. Quaternion signs align before blending. Additive layers use local
rotation deltas, scale ratios and morph-weight differences from `referenceTime`.
You can use the same loop, reverse, pause and fade controls as other timeline actions.

`ModelAnimationTrack` implements `BlendableTimelineTrack`. It prepares one atomic
edit for the instance, including deformed geometry, and rejects incompatible
model targets or invalid poses before changing the scene. Keep other writers off
its nodes and geometry during playback. Deformation runs on the CPU and uploads
to native dynamic geometry; GPU skinning and morph kernels are not implemented.

## Imported events

You can put named events on an animation's `extras.zyrenEvents` array:

```json
{"zyrenEvents": [
  {"time": 0, "id": "start"},
  {"time": 0.5, "id": "contact", "label": "Foot contact"}
]}
```

Times are seconds, in ascending order and within the animation. IDs must be
unique and nonempty. Equal-time events keep declaration order. These are Zyren
extras, not standard glTF animation channels. The adapter turns them into timeline
markers, including silent seeking, reverse ordering, loop indices and event limits.

## Native checks

Run the pixel and upload regressions on a native GPU host:

```sh
RUN_NATIVE_GPU=1 dart test packages/zyren_gltf_timeline/test/native_animation_test.dart
```

The suite covers imported joint/morph uploads, imported pose crossfades and pose
restoration, plus authored runtime crossfades, additive actions and reverse looping. It uses explicit readback
for pixel assertions. macOS checks require Metal. Vulkan and DX12 require their
respective hosts; a macOS pass does not qualify those backends.

For production presentation, run
`examples/multiple_views/integration_test/imported_presentation_test.dart` through
Flutter on macOS or a connected Android device. It verifies imported animation
on native surfaces, resizing and resource cleanup with zero pixel readback bytes.

The [qualification record](QUALIFICATION.md) includes physical Pixel Vulkan and
macOS Metal results, with commands you can use on another host.
