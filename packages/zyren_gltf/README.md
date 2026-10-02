# zyren_gltf

Load glTF models and transform animations into ordinary `zyren` scene objects. This optional package
uses the public Dart core and can decode models without Flutter or a GPU device.

```dart
import 'package:zyren/zyren.dart';
import 'package:zyren_gltf/zyren_gltf.dart';

final assets = AssetScope(services: services);
final task = assets.load(Gltf.asset('assets/models/assembly.glb'));
final progress = task.progress.listen(onProgress);
final model = await task.result;
final first = model.instantiate(name: 'Assembly A');
final second = model.instantiate(name: 'Assembly B')
  ..position = const Vec3(3, 0, 0);
scene..add(first)..add(second);
await progress.cancel();

assets.release(model); // Existing instances keep their shared CPU resources.
await assets.close();
```

In Flutter, use `controller.assets` or create a scope from
`SceneRuntime.assetServices`. The runtime supplies bundle/URI resolution and a
native image decoder and MikkTSpace tangent generator. `Gltf.uri` accepts an absolute URI. Relative buffers and
images resolve against the source's effective URI, including permitted redirects.

## Ownership and cancellation

Requests with the same source, version and options share work while in flight.
Each consumer receives its own scope-owned template. `instantiate` clones the
node hierarchy and shares immutable geometry, materials and images. You can move
an instance or replace its material without changing a sibling instance.

Call `task.cancel()` to cancel one consumer. The last cancellation terminates parser
workers and prevents results from being published. An active native image or
tangent job finishes within its limits before its storage is reclaimed. Closing
the scope also cancels outstanding loads. Releasing a template
prevents future instantiation. Existing instances stay usable, and each renderer
owns the lifetime of its uploaded resources. Completed URI loads are not cached.

`model.scenes` exposes scene names and indices. `instantiate(sceneIndex: index)`
selects one scene; the declared default or first scene is used when you omit it.
A document without scenes can load as metadata but cannot be instantiated.

## Animation

`instantiate` returns a `ModelInstance`, which is also an ordinary `Group`.
Its `nodes` map uses source node indices, and `animations` retains source clip
order and names. Duplicate display names do not affect binding. Each instance
owns a lazy `mixer`; keyframes and geometry remain shared.

```dart
// Register this plugin before attaching your Flutter view.
final playback = controller.use(AnimationSystem());

// Models can finish loading after the view starts.
final model = await controller.assets.load(Gltf.asset('animated.glb')).result;
final instance = model.instantiate();
controller.scene.add(instance);
final registration = playback.add(instance.mixer);
final action = instance.mixer.play(instance.animations.first);
action.pause();
action.seek(const Duration(milliseconds: 500));

registration.dispose(); // Release automatic playback when removing this model.
controller.scene.remove(instance);
```

Standalone Dart code can call `instance.mixer.update(delta)` instead. Do not
advance a mixer manually while its system also advances it. Removing a mixer
keeps its pose and action state; `stopAll()` restores its captured rest pose.

`model.animations` contains all source channels. Instance clips omit channels
outside the selected scene but retain the original duration and index. A clip
with no targets in that scene has an empty `tracks` list. Use that to disable
unavailable clips in your controls. Template release does not invalidate existing
instances or their playback. See [animation](../../docs/design/animation.md).

The importer validates time bounds, strictly increasing seconds, output shape,
channel uniqueness and transform/morph targets before publishing a model. Rotation outputs
accept float and normalized 8/16-bit integer quaternions; sparse accessors work
for animation too. Cubic tangents keep their authored magnitudes and signs.
Singular scale keys are rejected. If interpolation later produces a singular
scale or zero quaternion, the mixer rejects that update and keeps its prior pose.

## Material profile

Standard mode imports metallic/roughness triangle materials as `StandardMaterial`.
You get base color, normal, packed metallic/roughness, occlusion and emissive maps,
with their factors, UV sets, alpha modes and sidedness. `KHR_materials_unlit`
materials use `UnlitMaterial` and ignore lighting-only maps.

For inspection without lighting, you can still choose the diagnostic preview:

```dart
final request = Gltf.uri(uri, options: const GltfOptions(
  materialMode: GltfMaterialMode.unlitDiagnostic,
));
```

That mode approximates PBR with unlit base color and records a warning in
`model.issues`. It does not provide faithful PBR shading. Keep that warning visible
in your viewer. Unsupported required extensions fail before scene publication;
unknown optional extensions produce warnings and use the core fallback data.

| Feature | Current support and fixture |
| --- | --- |
| JSON/GLB, relative buffers, sparse/interleaved/normalized accessors | Container, buffer and accessor tests |
| Node names, multiple scenes, TRS and reflected matrices | `model_test`, `geometry_model_test` |
| Triangle lists, strips and fans; flat normals when absent | `geometry_model_test` |
| Untextured points, segments, loops and strips | `geometry_model_test`; one-pixel native primitives |
| Unlit base color, opacity, mask/blend, front or double-sided faces | `material_model_test`; native alpha and side fixtures |
| PNG/JPEG sources, image buffer views, data URIs, UV0/UV1 and samplers | `image_model_test`; native glTF texture/lifetime fixture |
| `COLOR_0` float or normalized byte/short RGB/RGBA | `vertex_color_model_test`; native interpolation, alpha and shadow probes |
| `KHR_materials_unlit` | Listed static features, including vertex color and alpha |
| PBR triangle materials and authored tangents | `pbr_model_test`; native analytic reference pixels |
| Missing normal-map tangents, morph seams/deltas and UV0/UV1 selection | `tangent_model_test`; pinned MikkTSpace reference and native pixel checks |
| `KHR_lights_punctual` | Directional, point and spot instances, transforms, units, range and cones; bounded native profile |
| Translation, rotation and scale animation | STEP, LINEAR and CUBICSPLINE; independent instance mixers |
| Skins and morph targets | Four influences, 256 joints, 64 position/normal/tangent targets; instance-local bindings |
| Morph-weight animation | STEP, LINEAR and CUBICSPLINE scalar channels; sparse and normalized integer accessors |
| Imported cameras, extra joint sets and color/UV morph deltas | Explicit unsupported-feature error |
| Lit or textured lines/points, UV sets above one, singular or out-of-range native transforms | Explicit unsupported-feature error |
| Draco, meshopt, Basis/KTX2 and other required extensions | Explicit unsupported-feature error |

Missing normal-map tangents require `AssetServices.tangentGenerator`. Flutter's
native runtimes supply it. The service generates base tangents and morph tangent
deltas while preserving seams from every target. Standalone Dart callers can use
`NativeTangentGenerator` from `zyren_native`, or provide their own implementation
of the core `TangentGenerator` interface. See [tangent preparation](../../docs/design/tangent-generation.md)
for limits and direct geometry usage.

## Lighting and image ownership

`KHR_lights_punctual` definitions become ordinary core lights beneath their glTF
nodes. Each instance gets editable light objects. Transforming a node moves or
orients its light; range and intensity keep their authored values. Directional
intensity is lux, while point and spot intensity is candela. Shadow flags are not
part of this extension and remain opt-in through the core API.

The loader adds no ambient or studio light. Supply lights or an environment for
PBR assets that contain neither. The model viewer provides a labelled studio
control for that case. See the [import profile](../../docs/design/gltf-materials.md).

Base color and emission use sRGB textures. Normal, metallic/roughness and occlusion
use linear textures. A source image is decoded once, then shared per color-space
and mip-generation variant. Samplers remain independent. Custom image decoders
must preserve source channel values as straight RGBA8; conversion and GPU format
selection belong to the material usage.

## Limits and workers

`GltfLimits` bounds JSON metadata, accessors, nodes, depth, primitives and up to 16 light instances per scene.
Animation defaults allow 256 clips, 4096 total channels and 1,000,000 keys.
Sampler count is bounded by `maxAnimationChannels` too. Sampler keys and expanded
channel keys are each checked against `maxAnimationKeyframes`, so reusing one
sampler across many nodes cannot bypass the limit. The clip ceiling is 4096;
channel and key ceilings equal their defaults. Decoded payload accounting also
reserves space for immutable animation keys, tangents and copied time arrays. The
primitive limit also checks the expanded meshes in each scene, so repeated mesh
references cannot bypass admission. Core `AssetLimits` bounds source and decoded
payloads. Geometry accounting includes intermediate accessor arrays, generated
normals, generated tangent seam copies and owned copies. Image accounting includes decoder output and each owned
color-space/mip variant. These are payload limits, not a process-memory ceiling. Renderers
apply their own frame upload and GPU residency budgets when a model is drawn.

Flutter's default asset services include the native meshopt decoder. For a Dart
application, pass `NativeBufferDecoder()` as `AssetServices.bufferDecoder`.
Decoded views count against the job budget before accessor conversion. Fallback
buffers marked by meshopt are skipped when you configure the codec.

For Basis textures, pass `NativeTextureDecoder()` as `AssetServices.textureDecoder`.
Flutter includes it by default. Authored mip levels and alpha survive CPU
transcoding to RGBA8. A texture with one source level gets generated mips when
its sampler requests them. The material usage must agree with the texture's
linear/sRGB metadata. Native storage is RGBA8; compressed GPU uploads, arrays,
cubes, video, HDR, custom swizzles and alternate orientations are unsupported.

For Draco, use `NativeMeshDecoder()` as `AssetServices.meshDecoder`. Flutter
includes it by default. Declared position bounds may include quantization
padding; decoded vertices must remain inside that range, and the model uses
their actual bounds. The independent Khronos Box fixture checks Draco loading
and native tile rendering alongside the generated sequential/EdgeBreaker quads.

Each caller isolate admits two workers and sixteen queued jobs. Large buffers use
transferable inputs and isolate-exit results. Workers prepare immutable geometry
and image data; renderer identities are assigned on the caller. Errors include
source URIs and field paths. Compiled release tests cover the public model path,
resource identities, worker errors and cancellation.

Run `dart test packages/zyren_gltf/test` from the workspace root. The native
fixture also renders real pixels, verifies shared uploads and retires the final
resources on Metal and Pixel Vulkan. See [verification](../../docs/verification.md)
and the [glTF specification](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html).


For skin and morph models, use the same `instantiate()` and mixer API.
`instance.morphTargets[nodeIndex]` gives you the primitives controlled by that
node's weights. Geometry and clips remain shared while joints and weights stay
independent. Node weights override mesh defaults. Missing inverse bind matrices
use identity. See [deformation](../../docs/design/deformation.md) for limits,
validation rules and the native viewer example.
