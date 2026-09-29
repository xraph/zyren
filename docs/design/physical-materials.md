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
Factors use [0, 1]; IOR uses [1, 10]. Rotation is in radians. Anisotropy requires
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

Scene opcode 29 carries sixteen physical floats after the standard descriptor.
Older opcodes keep their layout. Layer edits participate in delta comparison, so
they do not reupload geometry. `RenderFeature.physicalMaterials` lets adapters
reject the family before rendering.

Metal pixel checks cover normal-incidence IOR, colored specular, zero specular,
clearcoat, sheen, rotated anisotropy, emission and cleanup. The standard PBR,
environment, shadow, instance and deformation regressions remain part of the
acceptance run. This first increment does not include physical-layer maps,
transmission, volume or glTF physical-extension decoding.

Model references: [Khronos specular](https://github.com/KhronosGroup/glTF/blob/main/extensions/2.0/Khronos/KHR_materials_specular/README.md),
[Khronos anisotropy](https://github.com/KhronosGroup/glTF/blob/main/extensions/2.0/Khronos/KHR_materials_anisotropy/README.md),
[Filament](https://google.github.io/filament/main/filament.html) and the
[Three.js sheen fit](https://github.com/mrdoob/three.js/blob/r180/src/renderers/shaders/ShaderChunk/lights_physical_pars_fragment.glsl.js).
The Three.js notice is retained in `THIRD_PARTY_NOTICES.md`.
