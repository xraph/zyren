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

These materials receive light from explicit light nodes and an optional environment. The legacy scene ambient
fill and `lightDirection` still apply to `DiffuseMaterial`. With no lights, environment or
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

Normal mapping uses authored float4 tangent attributes when supplied. Their
handedness follows mirrored transforms; dynamic updates preserve earlier captured
geometry in other views. Without tangents, the shader derives its frame from
position and UV screen derivatives. Degenerate UVs keep the surface normal.
Shadows and standard glTF material loading remain the next renderer stage.
Standard glTF mode continues to reject unsupported PBR profiles until those
fixtures pass. Mobile PBR qualification is also pending.


## Environment lighting

`EnvironmentLightingPlugin(EnvironmentImage(...))` accepts owned, linear RGBA
radiance in an equirectangular image with Y up. It computes diffuse irradiance,
GGX reflection slices and a BRDF table through the public resource and graph APIs.
You can consume its `environmentLighting` service from a dependent plugin. The
scene registration and GPU allocations retire when the plugin detaches.

For an existing GPU source, call `EnvironmentMap.generate` with your resource,
shader and graph scopes, then set `RenderSettings(environment: map)`. Publish a
candidate only after generation succeeds. Keep its resource scope alive, or retain
all three textures in another scope before closing the original. Textures cannot
cross devices. The source can be sampled float data; the generated tables use
RGBA16 float storage. The default bake uses 256 samples, eight roughness slices,
64 by 32 directional maps and a 64 by 64 BRDF table. Admission caps convolution
at 64 million samples.

`intensity` scales linear radiance and `rotation` turns the map about Y in radians.
The map contributes diffuse and specular indirect lighting; occlusion affects both.
It does not replace the scene background. Regenerate the maps after source edits;
changing the camera or material does not dispatch the convolution again. Increment
`historyEpoch` when updating map contents if a temporal effect uses the scene.

The algorithm uses the [split-sum approximation described by Brian Karis](https://cdn2.unrealengine.com/Resources/files/2013SiggraphPresentationsNotes-26915738.pdf),
with correlated Smith visibility and the same Fresnel approximation as the direct
BRDF. Reflection filtering assumes the view and normal follow the reflection
vector. This approximation cannot reproduce elongated grazing-angle reflections.
The implementation uses equirectangular volume slices for roughness, rather than
requiring a cubemap resource type.

Metal probes compare the BRDF table with independent hemisphere integration of
Three r184 scalar functions. They also check constant HDR radiance, directional
reflection broadening, rotation, failed budget admission, owner closure and plugin
cleanup. The fixtures are in `test_assets/rendering/pbr/environment.json` and
`packages/zyren_native/test/environment_test.dart`. Mobile qualification is pending.
