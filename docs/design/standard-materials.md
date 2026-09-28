# Standard materials and physical lights

`StandardMaterial` shades a linear base color with metallic and roughness factors,
base-color, normal, metallic/roughness, occlusion and emissive textures. It supports the shared side, mask,
blend and depth policies. Standard materials automatically enable the HDR scene
path. Choose a tone-mapping curve in `scene.renderSettings` to retain highlights
above one in the displayed image.

```dart
scene.add(Mesh(
  SphereGeometry(),
  StandardMaterial(
    baseColor: Color3.hex(0xb46b42),
    metallic: 0.8,
    roughness: 0.3,
  ),
));
scene.add(DirectionalLight(direction: Vec3(0, 0, -1), intensity: 3));
scene.renderSettings = RenderSettings(toneMapping: ToneMapping.aces);
```

Direct lighting uses isotropic GGX, correlated Smith visibility, Schlick Fresnel
and a Lambert diffuse term weighted by one minus metallic. Roughness has a
0.0525 shading floor. The current profile uses single scattering. Its numerical
fixture extracts the scalar functions from Three r184; it does not claim pixel
parity with that release's complete multiscattering material.

Directional intensity is irradiance in lux. Point and spot intensity is candela,
with inverse-square attenuation and a smooth finite-range cutoff. Range zero has
no cutoff. Spot angles are radians; penumbra controls the transition inside the
outer cone. Directions are local ray-travel directions and follow their scene
transforms. Hemisphere lights supply diffuse sky/ground irradiance along their
local up axis. A view supports up to sixteen visible physical lights.

These materials receive light from explicit light nodes. The legacy scene ambient
fill and `lightDirection` still apply to `DiffuseMaterial`. With no lights or
emission, a standard material is black. Emission multiplies its linear color by
`emissiveIntensity`, which can exceed one.

Metal GPU probes cover twelve metallic/roughness reference samples, point falloff,
spot cutoff, hemisphere irradiance, emission, base-color textures, mirrored
transforms, masks and premultiplied transparency. Light and material edits are
captured per frame; invalid parameter values fail before native upload.

Normal, metallic/roughness and occlusion maps require linear RGBA8 storage.
The metallic/roughness texture uses green for roughness and blue for metallic;
occlusion uses red and affects indirect light only. Emissive textures multiply
the material's emission and can use sRGB storage. Each map chooses UV0 or UV1.
`normalScaleX` and `normalScaleY` control the tangent-space normal components,
and `occlusionStrength` blends between no occlusion and the sampled value.

Normal mapping currently derives its tangent frame from position and UV
screen derivatives, including mirrored geometry. Degenerate UVs keep the surface
normal. Explicit tangent attributes, environment lighting, shadows and standard
glTF material loading remain the next renderer stage.
Standard glTF mode continues to reject unsupported PBR profiles until those
fixtures pass. Mobile PBR qualification is also pending.
