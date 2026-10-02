# Zyren core and plugin integration

Use `zyren` for scene objects, geometry, materials, animation, picking and GPU
resource contracts. Use `flutter_zyren` to present those scenes in Flutter.
`zyren_native` owns the Rust renderer and native transports. Geospatial, tiles,
tools, engineering and timeline packages depend on the public core APIs.

Rendering uses Metal, Vulkan or DX12. No browser rendering path is part of this
integration.

## API decisions

- `OrbitControls` retains the geospatial branch's upstream control behavior.
  `OrbitNavigation` names the earlier core navigation plugin. Existing users can
  choose either without changing the other's gesture contract.
- `MeshProgram` is the shared material program contract. Both `MeshShader` and
  `MeshShaderProgram` use the renderer's existing resource owner.
- `EnvironmentMap` stores the core's two-dimensional mip chain.
  `VolumeEnvironmentMap` stores the geospatial lighting plugin's three-dimensional
  roughness layers. You cannot interchange their texture layouts.
- `ModelMesh` and `ModelSkinnedMesh` expose `ModelFeatureMesh`. Feature partitions
  retain typed joint attributes and morph deltas, so animation and feature styling
  can address the same mesh.
- A scene starts with a transparent background. Set `scene.background` when you
  want an opaque backdrop. Shadow receivers opt in with `receiveShadow = true`.

## Frame composition

The renderer runs graph preparation, scene rendering, temporal reconstruction,
graph postprocessing, HDR screen effects, bloom, tone mapping, display effects,
output FXAA and selection outlines in that order. HDR effects receive resolved
premultiplied linear color; display effects receive premultiplied sRGB.
Graph postprocessing and temporal reconstruction receive straight HDR color;
the renderer converts alpha conventions at those boundaries. Outlines composite
in linear light and preserve the declared output alpha convention, including
when an effect makes an opaque scene translucent.

When you supply a `ColorPipeline`, it controls exposure, tone mapping and the
sample count. Otherwise, `RenderSettings` supplies those values. Temporal AA
requires a single-sample HDR color pipeline and built-in triangle materials.
MSAA remains a separate choice. Reversed depth, clipping and fragment coverage
are applied consistently to visible, shadow and temporal passes. Transmission
uses the active depth convention and supports both environment layouts.

`MeshShader` authors can opt into section clipping with `supportsClipping` and
call the supplied clipping helper. Other custom shaders reject section clipping
until they implement that contract. `ToneMapping.linear` aliases `none`; the
core's original `reinhard` and `acesFilmic` wire values stay stable. The added
`aces`, `cineon`, `agx` and `neutral` modes use the same enum in both pipelines.

## Native protocol

Scene packet version 36 keeps the core version 35 payload and adds bounded mesh
and frame extensions. Resource operation 11 queries compressed format support;
operation 12 creates dimension-aware textures. Float RGBA32 and R32 use format
IDs 9 and 10, after the existing compressed formats. These values are internal
transport contracts, not application APIs.

The binary fixture in `packages/zyren_native/native/tests/fixtures` is generated
by `packages/zyren_native/tool/generate_scene_fixture.dart`. It combines physical
material optics with reversed depth, clipping, fragment coverage and outlines.

## Verification scope

This integration combines the core branch with committed Zyren work through
`391b642`. Later changes in the primary checkout are outside this pinned merge.

The integration is tested on macOS Metal and Pixel 9 Pro Vulkan. See the
[native device report](native-device-qualification.md) for the Android checks and
the pending iOS, Windows and Linux qualification. Full Three.js/Takram feature
parity remains separate work.
Passing package tests does not establish those platform or parity claims.

The final integration checks cover 719 core tests, 110 Flutter tests, 197 native
GPU tests and 199 Rust tests. A further six outline checks include the added
compatibility-renderer alpha regression. The glTF, tiles, tools, timeline,
engineering, effects, diagnostics and inspector suites also pass.

Geospatial has 225 passing cases across the package run and the source-asset
run. The latter verifies the original binary/EXR atmosphere tables, cloud maps,
lighting updates and shadow transport. All 15 downloaded files matched the
attached source project's Git LFS hashes. These fixtures remain outside the
repository; set `ZYREN_SOURCE_LUTS` and `ZYREN_SOURCE_CLOUDS` to run them locally.

Native macOS app checks pass for the physical-material gallery, the atmosphere
lab and six managed SceneView tests. The atmosphere switches day, dusk, night
and orbit views and resizes down to 320 logical pixels. Presentation uses zero
readback bytes. After 100 view lifecycle cycles, sessions, renderers, retiring
views and held drawables return to zero. Explicit capture remains a separate,
measured readback operation.
