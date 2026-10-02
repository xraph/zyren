# zyren

A general-purpose 3D scene library for Dart. Build geometry, materials, cameras
and plugins without depending on Flutter or a native GPU.

[Documentation](https://xraph.com/docs/zyren) ·
[Workspace and examples](https://github.com/xraph/zyren) ·
[Package guide](https://xraph.com/docs/zyren/packages)

## Build a scene

```dart
import 'package:zyren/zyren.dart';

final scene = Scene();
final cube = Mesh(
  BoxGeometry(),
  UnlitMaterial(color: Color3.hex(0x497ee8)),
);
scene.add(cube);
final camera = PerspectiveCamera(position: Vec3(3, 2, 5));
final snapshot = scene.snapshot(camera, 1);
```

You can construct and inspect this scene without a Flutter engine. To render
it, supply a `backendFactory` to `SceneEngine.create`. Use `NativeBackend.create`
from `zyren_native` for
native Metal, Vulkan or Direct3D 12 output, or `flutter_zyren` for Flutter views
and managed controllers.

## Included in the core

- Scene hierarchies, transforms and camera-relative snapshots.
- Geometry, unlit/diffuse/standard material descriptions, textures and lights.
- Perspective and orthographic cameras, input contracts and picking.
- Asset scopes, cancellation, limits and source resolution contracts.
- Plugin lifecycle hooks, typed services and dependency ordering.
- Public rendering contracts, GPU resource descriptors and frame statistics.

The core describes rendering work. Your backend determines which features and
limits it can execute. Inspect capabilities before requesting optional features.
Advanced contracts are exported from `package:zyren/rendering.dart`.

## Add only what you need

| Your app needs | Package |
| --- | --- |
| A Flutter viewport | `flutter_zyren` |
| Headless native rendering | `zyren_native` |
| glTF/GLB loading and animation | `zyren_gltf` |
| Globe coordinates and terrain | `zyren_geospatial` |
| 3D Tiles streaming | `zyren_3d_tiles` |
| Selection and measurements | `zyren_tools` |
| Authored transform/camera playback | `zyren_timeline` |
| Fullscreen filters and color grading | `zyren_effects` |
| Read-only scene inspection | `zyren_devtools` |
| Stable IDs and review notes | `zyren_engineering` |

Geospatial uses the public core extension points. You can build a model viewer
without pulling in globe math or terrain.

## Development status

Advanced output and backend contracts are in `package:zyren/rendering.dart`.
Scenes default to a transparent canvas. Set `scene.background` for a color fill,
and `backgroundOpacity` for partial coverage. Mesh materials support opaque, mask
and blend modes. Physical materials include transmission, iridescence and
dispersion. Check the integration guide for supported combinations and the
remaining platform qualification work.

## Vertex colors

You can add `VertexSemantic.color` to `BufferGeometry.fromAttributes` and opt
in with `UnlitMaterial(vertexColors: true)`. Diffuse, standard, line and point
materials accept the same flag. Your existing geometry and material can still
be shared across meshes.

Use float RGB, float RGBA or normalized byte RGBA attributes. Values are linear,
in [0, 1]. RGB supplies alpha 1. Vertex color multiplies the material's base color
and base-color map, while emission stays independent. Masked and blended materials
also multiply vertex alpha by map alpha and opacity; opaque materials ignore alpha.

For dynamic geometry, call `updateAttribute(VertexSemantic.color, values,
firstVertex: start)`. The values must match the original attribute format.
Triangle updates upload only affected GPU rows and preserve previously captured
views. Expanded lines and points upload their full recipe when edited.

See [vertex color usage and limits](../../docs/design/vertex-colors.md).

This is an alpha workspace package with `publish_to: none`. Use it from the
repository workspace, with the pinned Flutter/Dart toolchain. APIs may change.
Run `fvm dart test` from this package after resolving workspace dependencies.
The [workspace README](../../README.md) covers native tools, runnable examples,
platform qualification and third-party notices.

Screen effects declare `PostProcessStage.hdr` (the default) or
`PostProcessStage.display`. HDR effects run before bloom, exposure and tone
mapping. Display effects receive premultiplied sRGB after those operations and
run before output FXAA. `historyColor` always holds the previous HDR result.
Within each stage, `Scene.addEffect` preserves the requested order and stable
ties. `ToneMapping.aces` retains the original approximation; `acesFilmic`,
`cineon`, `agx` and `neutral` follow the Three.js r184 operators.

A `PostProcessDescriptor.target` redirects its draw to a scoped 2D RGBA16F
render attachment. The main scene-color chain stays unchanged until a later
effect samples that target and returns its composite. The target sets the draw
resolution; vertex UV spans it, while `screen.viewport` describes the scene.
Materials retain their targets and reject aliases with their own bindings.
A view supports up to 32 screen effects within the existing GPU resource budgets.
