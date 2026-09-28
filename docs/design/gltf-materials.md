# glTF materials and lights

Load a model with `Gltf.asset` or `Gltf.uri`, then instantiate it into your scene.
Standard mode preserves metallic/roughness materials. The optional loader uses
ordinary core meshes, materials and lights, so renderer resource sharing and
scene edits follow the same rules as objects you create in Dart.

```dart
final model = await assets.load(Gltf.asset('models/pump.glb')).result;
final instance = model.instantiate();
scene.add(instance);
```

You must provide illumination if the asset contains no lights. The loader never
adds it. The model viewer offers a studio light for this case; your application
can use core punctual lights, a hemisphere light or `EnvironmentLighting`.

## Material conversion

A missing glTF material uses white base color, metallic 1 and roughness 1. These
are glTF defaults, independent of `StandardMaterial` convenience defaults. Normal
scale, occlusion strength, emission, alpha cutoff and double-sided state retain
the authored values. Base color and emission use sRGB image formats. Data maps
use linear formats; packed roughness reads green, metallic reads blue and
occlusion reads red. Only base color contributes texture alpha.

Image decoding runs once per referenced source. Each required color-space and
mip-generation variant owns a texture image, charged to the decoded byte budget.
Bindings share that image even when their sampler or UV set differs. Decoders
must return straight RGBA8 source channels without applying color corrections.
The loader selects the transfer function from the map's usage.

Authored float VEC4 tangents retain handedness. Missing normals produce flat
normals and discard tangents, as required by glTF. Without authored tangents,
the native shader derives a basis from position and UV derivatives. This is not
a MikkTSpace mesh generator and can differ from a baker at seams.

`KHR_materials_unlit` retains base color, alpha and sidedness while ignoring
normal, metallic/roughness, occlusion and emissive inputs. Those unused images
are not fetched. `unlitDiagnostic` gives PBR materials the same base-color preview
and records a warning. It remains an explicit inspection option.

## Light instances

`KHR_lights_punctual` definitions produce a new light beneath each referencing
node, alongside any mesh. Instances share immutable mesh resources but never
share mutable light objects. Node transforms affect position and orientation;
range, intensity and cone angles remain unchanged. Directional and spot lights
emit along local -Z. Linear RGB multiplies lux for directional lights or candela
for point and spot lights.

Range is optional for point and spot lights. Native rendering uses inverse-square
falloff and a smooth finite-range cutoff. Spotlights retain both cone angles and
use cosine-space attenuation. Shadows are opt-in core settings, since the glTF
extension does not define shadow behaviour.

`GltfLimits.maxLights` defaults to 16 and can be lowered. Admission counts light
instances in each scene, including repeated references to one definition.
Native light intensity and range are bounded at 1e12. A positive range that
underflows float32 is rejected instead of becoming infinite. Invalid definitions
and references produce source URIs and field paths before scene publication.

## Qualification boundary

Analytic native probes cover defaults, direct lighting, inverse-square falloff,
range, rotated spots, all five maps, alpha masks, emission, occlusion, unlit
behaviour and tangent handedness. Decoder tests cover independent instances,
limits, malformed fields, UV requirements, image variants and release workers.
The viewer fixture exercises authored lighting and an explicit studio fallback.

This remains a static subset. Vertex colors, animation, skins, morphs, cameras,
MikkTSpace generation, lit/textured points and lines, and advanced material
extensions are not implemented. Unknown required extensions fail. Optional ones
produce warnings and use their supported fallback data. Do not treat this profile
as full glTF conformance or complete Three.js parity.

References: [glTF 2.0](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html),
[KHR_materials_unlit](https://github.com/KhronosGroup/glTF/tree/main/extensions/2.0/Khronos/KHR_materials_unlit),
[KHR_lights_punctual](https://github.com/KhronosGroup/glTF/tree/main/extensions/2.0/Khronos/KHR_lights_punctual).
