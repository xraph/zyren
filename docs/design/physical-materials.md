# Physical materials

Use `PhysicalMaterial` for coated, cloth or brushed surfaces. It extends
`StandardMaterial`, so you keep its base maps, opacity, side, depth and emission
controls. `copyWith` retains the physical type and all layer parameters.

```dart
final paint = PhysicalMaterial(
  baseColor: const Color3(.15, .3, .7),
  roughness: .4,
  clearcoat: 1,
  clearcoatRoughness: .15,
);
mesh.material = paint.copyWith(clearcoatRoughness: .3);
```

The implemented reflectance controls are IOR, specular intensity/color,
clearcoat amount/roughness, sheen color/roughness and anisotropy amount/rotation.
Layer factors use [0, 1]. IOR accepts zero for an ideal reflector or [1, 1e6];
specular color channels accept [0, 1e6]. Rotation is in radians. Anisotropy requires
authored tangents or tangents prepared with the public `TangentGenerator`.
It works without a texture. Missing tangents fail before GPU allocation.

Direct lighting evaluates layered GGX with correlated visibility. Dielectric
Fresnel uses IOR and specular color; metals retain their base-color reflectance.
Clearcoat attenuates the underlying reflection and emission. Sheen uses Charlie
distribution, Neubelt visibility and a directional-albedo fit to attenuate the
base. Anisotropy widens the tangent roughness using the Khronos parameterization.
The two axes coincide at zero anisotropy.

Environment lighting uses the existing prefiltered GGX map and BRDF lookup, a
bent-normal approximation for anisotropy, and the Charlie albedo fit for sheen.
That is a realtime approximation, not a path-traced reference. Hemisphere lights
remain a diffuse ambient approximation. A material with default physical factors
matches standard PBR in the native direct-light fixture.

Scene opcode 34 carries sixteen reflectance floats, eight transmission floats,
eight optical floats and twelve optional layer maps
after the standard descriptor. Older opcodes keep their layout. Layer edits participate in delta comparison, so
they do not reupload geometry. `RenderFeature.physicalMaterials` lets adapters
reject the family before rendering.

Metal pixel checks cover normal-incidence IOR, colored specular, zero specular,
clearcoat, sheen, rotated anisotropy, emission and cleanup. The standard PBR,
environment, shadow, instance and deformation regressions remain part of the
acceptance run. [Transmission and volume](transmission.md) add glass refraction
and absorption through a separate opaque capture.

You can texture all twelve layer channels:

| Map | Channels | Interpretation |
| --- | --- | --- |
| `clearcoatMap` | R | Linear layer amount |
| `clearcoatRoughnessMap` | G | Linear roughness |
| `clearcoatNormalMap` | RGB | Independent tangent-space normal, with `clearcoatNormalScale` |
| `sheenColorMap` | RGB | Color, decoded from sRGB |
| `sheenRoughnessMap` | A | Linear roughness |
| `specularIntensityMap` | A | Linear dielectric specular strength |
| `specularColorMap` | RGB | Color, decoded from sRGB |
| `anisotropyMap` | RG, B | Tangent direction in [-1, 1], then strength |
| `transmissionMap` | R | Linear transmission amount |
| `thicknessMap` | G | Linear thickness multiplier |
| `iridescenceMap` | R | Linear thin-film strength |
| `iridescenceThicknessMap` | G | Interpolated minimum/maximum film thickness |

Maps multiply their factors. Each map chooses UV0 or UV1 and keeps its sampler.
Data maps require `rgba8Unorm`; color maps use the texture format's conversion.
The coat normal has its own lighting frame for direct, area and environment
reflection. When base and coat normal maps use different UV sets, the shader
derives the coat frame from its UVs and keeps the supplied tangents for the base.
Otherwise, supplied tangents must match the selected normal-map UV frame.
Without supplied tangents, the shader derives the frame from UVs.

Native pipelines only bind active physical maps and share identical sampler
descriptors. All twelve maps require 25 sampled textures per fragment stage, including
fixed standard, environment, shadow, area and transmission bindings. They need
eight fixed samplers plus the number of distinct physical-map samplers. Adapter
limits reject unsupported combinations before uploads without poisoning the
renderer. Maps keep ordinary texture ownership and delta uploads, including when
a layer is removed and later restored.

The glTF loader supports required `KHR_materials_ior`, `KHR_materials_specular`,
`KHR_materials_clearcoat`, `KHR_materials_sheen`, `KHR_materials_anisotropy` and
`KHR_materials_emissive_strength`, plus transmission and volume. It generates missing tangents through the
configured `TangentGenerator`, using the selected normal or anisotropy UV set.
Color and data uses of one source image receive separate decoded variants.
Malformed factors, missing UVs and incompatible unlit combinations fail before
publishing a model. Native tests compare loaded layers with hand-built materials
under HDR, MSAA and TAA, plus direct, area and environment map-channel checks.

Model references: [Khronos specular](https://github.com/KhronosGroup/glTF/blob/main/extensions/2.0/Khronos/KHR_materials_specular/README.md),
[Khronos anisotropy](https://github.com/KhronosGroup/glTF/blob/main/extensions/2.0/Khronos/KHR_materials_anisotropy/README.md),
[Filament](https://google.github.io/filament/main/filament.html) and the
[Three.js sheen fit](https://github.com/mrdoob/three.js/blob/r180/src/renderers/shaders/ShaderChunk/lights_physical_pars_fragment.glsl.js).
The Three.js notice is retained in `THIRD_PARTY_NOTICES.md`.

[Optical materials](optical-materials.md) describes iridescence, dispersion and their glTF extensions.
