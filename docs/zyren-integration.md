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
graph postprocessing, screen effects, bloom, output conversion and selection
outlines in that order. Screen effects receive resolved premultiplied HDR color.
Graph postprocessing and temporal reconstruction receive straight HDR color;
the renderer converts alpha conventions at those boundaries.

When you supply a `ColorPipeline`, it controls exposure, tone mapping and the
sample count. Otherwise, `RenderSettings` supplies those values. Temporal AA
requires a single-sample HDR color pipeline and built-in triangle materials.
MSAA remains a separate choice. Reversed depth, clipping and fragment coverage
are applied consistently to visible, shadow and temporal passes.

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

The integration is tested on macOS Metal. Native Android and Windows runtime
qualification and full Three.js/Takram feature parity remain separate work.
Passing package tests does not establish those platform or parity claims.
