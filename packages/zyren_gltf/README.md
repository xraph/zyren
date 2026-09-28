# zyren_gltf

Load static glTF models into ordinary `zyren` scene objects. This optional package
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
native image decoder. `Gltf.uri` accepts an absolute URI. Relative buffers and
images resolve against the source's effective URI, including permitted redirects.

## Ownership and cancellation

Requests with the same source, version and options share work while in flight.
Each consumer receives its own scope-owned template. `instantiate` clones the
node hierarchy and shares immutable geometry, materials and images. You can move
an instance or replace its material without changing a sibling instance.

Call `task.cancel()` to cancel one consumer. The last cancellation terminates the
worker; closing its scope also cancels outstanding loads. Releasing a template
prevents future instantiation. Existing instances stay usable, and each renderer
owns the lifetime of its uploaded resources. Completed URI loads are not cached.

`model.scenes` exposes scene names and indices. `instantiate(sceneIndex: index)`
selects one scene; the declared default or first scene is used when you omit it.
A document without scenes can load as metadata but cannot be instantiated.

## Material profile

Standard mode loads metallic/roughness materials with base-color, normal,
metallic/roughness, occlusion and emissive maps. Color maps use sRGB storage;
data maps use linear storage. Add physical lights or environment lighting to
your scene, or supply `KHR_lights_punctual` lights in the model.

You can still choose an unlit diagnostic preview:

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
| `KHR_materials_unlit` | Partial: the listed static features; vertex colors still unsupported |
| PBR triangle materials, authored tangents, scalar factors and five maps | `standard_model_test`; native PBR and loaded light fixtures |
| `KHR_lights_punctual` | Directional, point and spot lights, up to sixteen per scene; independent node instances |
| Animations, skins, morphs, vertex colors and imported cameras | Explicit unsupported-feature error |
| PBR or textured lines/points, UV sets above one, singular or out-of-range native transforms | Explicit unsupported-feature error |
| Draco, meshopt, Basis/KTX2 and other required extensions | Explicit unsupported-feature error |

## Limits and workers

`GltfLimits` bounds JSON metadata, accessors, nodes, depth and primitives. The
primitive limit also checks the expanded meshes in each scene, so repeated mesh
references cannot bypass admission. Core `AssetLimits` bounds source and decoded
payloads. Geometry accounting includes intermediate accessor arrays, generated
normals and owned copies. Image accounting includes decoder output and owned
texture copies. These are payload limits, not a process-memory ceiling. Renderers
apply their own frame upload and GPU residency budgets when a model is drawn.

Each caller isolate admits two workers and sixteen queued jobs. Large buffers use
transferable inputs and isolate-exit results. Workers prepare immutable geometry
and image data; renderer identities are assigned on the caller. Errors include
source URIs and field paths. Compiled release tests cover the public model path,
resource identities, worker errors and cancellation.

Run `dart test packages/zyren_gltf/test` from the workspace root. The native
fixture also renders real pixels, verifies shared uploads and retires the final
resources on Metal and Pixel Vulkan. See [verification](https://xraph.com/docs/zyren/reference/verification)
and the [glTF specification](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html).
