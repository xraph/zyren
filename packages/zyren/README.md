# Zyren

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
it, supply a `rendererFactory` to `SceneEngine.create`. Use `zyren_native` for
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
| Static glTF/GLB loading | `zyren_gltf` |
| Globe coordinates and terrain | `zyren_geospatial` |
| 3D Tiles streaming | `zyren_3d_tiles` |
| Selection and measurements | `zyren_tools` |
| Authored transform/camera playback | `zyren_timeline` |
| Read-only scene inspection | `zyren_devtools` |
| Stable IDs and review notes | `zyren_engineering` |

Geospatial uses the public core extension points. You can build a model viewer
without pulling in globe math or terrain.

## Development status

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
