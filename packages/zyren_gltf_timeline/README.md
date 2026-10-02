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

`ModelAnimationTrack` prepares one atomic edit for the whole instance. Keep other
writers off that instance's nodes and deformed geometry during playback. It is a
custom timeline track, so it does not participate in the absolute transform/camera
clip mixer. Use separate model instances when you need independently playing
imported animations. Runtime crossfades for imported skeletal poses need a model
pose mixer; the transform/camera action mixer does not blend vertex buffers.

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

The suite covers imported joint/morph uploads and pose restoration, plus authored
runtime crossfades, additive actions and reverse looping. It uses explicit readback
for pixel assertions. macOS checks require Metal. Vulkan and DX12 require their
respective hosts; a macOS pass does not qualify those backends.
