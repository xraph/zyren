# Native renderer profiles

Use `backend.capabilities.features` and `limits.sampleCounts` to choose a path.
The native backend queries its adapter for supported RGBA16 float and Depth32
float sample counts. A request for an unsupported count fails explicitly. The
renderer does not switch to a browser or OpenGL implementation.

| Profile | Color and depth | Available behavior | Bounds |
| --- | --- | --- | --- |
| Direct scene | Native output color, Depth32 float | Indexed meshes, unlit/diffuse/standard materials, RGBA8 maps and mipmaps, alpha masks/blending, material sides, lines/points, instances and punctual lighting | 4096 maximum 2D dimension; 65536 instances per view; 16 active lights |
| HDR effects | RGBA16 float, Depth32 float, single-sample history | Exposure, Reinhard or fitted ACES, up to eight custom screen effects, FXAA, normalized bloom | 128 MiB of targets shared by views; 36 bytes per pixel before bloom |
| Multisample HDR | Four-sample RGBA16 float and Depth32 float resolved to single-sample HDR/depth | The HDR profile with fractional coverage and nearest-sample depth | Only when `sampleCounts` contains 4; 84 bytes per pixel before bloom |
| Public GPU resources | RGBA8 linear/sRGB, RGBA16/32 float, R32 float; 2D/3D textures | Scoped buffers/textures, WGSL compilation, compute/render graphs, mesh shaders, screen effects and environment convolution | 64 MiB explicit resources; 4096 2D / 256 3D dimensions; format/usage validation |

The same scene/material/effect implementation serves explicit readback and native
presentation. Returned RGBA8 images use sRGB premultiplied alpha. Custom HDR effects
receive linear premultiplied color. `gpuTime` is nullable and remains null in this
profile; the renderer does not advertise timestamp queries or indirect draws.

## Materials and lighting

`StandardMaterial` implements isotropic metal/roughness shading with base color,
normal, metal/rough, occlusion and emissive maps. Base and emissive maps decode
sRGB; scalar and normal data remain linear. UV0/UV1, authored tangent handedness,
derivative fallback and mirrored transforms have native fixtures.

Directional lights use irradiance, and point/spot lights use inverse-square
attenuation with optional range and cone falloff. Hemisphere lighting supplies a
simple diffuse term. Environment lighting computes diffuse irradiance, roughness
prefiltering and a split-sum BRDF table through public GPU resources. This is a
single-scattering GGX/Smith/Schlick profile. It does not claim Three.js r184's
multiple-scattering material model or every physical-material extension.

Directional cascades and spot shadows share a bounded depth atlas. Resolution is
128, 256, 512 or 1024, with up to four directional cascades, one spot projection
and eight total projections per view. Shadow targets have a separate 64 MiB device
budget. Masks cast shadows; blended surfaces do not. Point-light cube shadows and
area lights are outside this profile.

Instances share geometry and use fixed picking slots. Their per-view model/normal
buffers share a 64 MiB device budget and receive contiguous dirty GPU writes.
A changed mesh still transfers its complete instance matrix array across the
scene transport. Transparent instances sort together with ordinary blended meshes.
Selection tools act on the whole mesh; `PickResult.instanceIndex` identifies an
individual slot for application-specific interaction.

The glTF loader defaults to standard materials and supports
`KHR_materials_unlit` and `KHR_lights_punctual`. Unsupported required extensions
fail. See the [glTF package](../packages/zyren_gltf/README.md),
[material contract](design/standard-materials.md),
[instance contract](design/instancing.md) and [effect contract](design/scene-effects.md).

## Qualification

| Evidence | Current result |
| --- | --- |
| Native numerical probes on macOS Metal | PBR/maps/tangents, IBL, shadows, instances, MSAA, bloom, FXAA, HDR/alpha/history and resource failure paths pass |
| Shader lab public consumer | Two shared views render the same combined scene; resize, instance edit and resource teardown pass |
| Planet renderer lab on macOS Metal | Two native views, resize and edits pass; zero presentation readbacks; zero sessions, renderers, retiring resources or held drawables after teardown |
| Model viewer | Standard glTF loading and compact desktop/narrow widget flows pass; native glTF material/light probes pass separately |
| Pixel 9 Pro Vulkan | Both native renderer tests pass: two views, resize, edits, desktop/narrow layouts, zero presentation readback and cleanup counts |
| iPhone 16 Pro Metal | Both profile tests pass: two views, resize, edits, compact controls, zero readback and clean teardown; six native presentations in the two-view test |
| Windows DX12 / Linux Vulkan | Backend paths exist; this profile has not been qualified on those hosts |

Run the visual consumer from `examples/planet` with
`fvm flutter run -d macos -t lib/renderer_lab.dart`. It uses physical materials,
environment lighting, directional and spot shadows, mirrored instances, custom
effects, MSAA where supported, FXAA and bloom. The canvas renders at one physical
pixel per logical pixel to keep the target budget practical on high-DPI displays.
You can toggle glow and orbit the scene. The model viewer adds studio key/fill
lights so models without authored lights remain visible in its standard material mode.

`benchmarks/renderer/material-effects-macos-jit.json` records the 512x384 combined
consumer on Apple M3 Max. Eight warmed JIT samples with MSAA4, FXAA and bloom range
from 2.67 to 3.48 ms including explicit readback. They use 17,562,624 target bytes,
7,168 instance bytes and a 4 MiB shadow atlas. This is a small scene and a short
sample, not a native presentation or GPU timestamp benchmark. Compare captures
under the same build, scene, dimensions and device load before drawing conclusions.

## Extension backlog

These entries are not qualified features. Each needs its own numerical and device
fixtures before a backend advertises support.

| Capability | Owner | Required evidence |
| --- | --- | --- |
| Multiple-scattering PBR, clearcoat, sheen, transmission, anisotropy and iridescence | Core materials / native PBR shader; corresponding glTF extensions | Energy and directional BRDF/BTDF references, layered materials, alpha/depth ordering |
| Area lights and point-light shadows | Core lights / native light and shadow modules | Analytical area-light integrals, cube seam/occlusion cases and budget recovery |
| KTX2/Basis, BC/ETC/ASTC and further HDR image decoders | Asset decoder / texture resource modules | Exact format admission, transcoding, mip/alpha/color fixtures and device support |
| Motion vectors, temporal AA and denoising | Core effect inputs / native history modules | Reprojection, disocclusion, moving/deforming objects, camera cuts and view isolation |
| GPU timestamps and indirect draws | Native device capability and graph modules | Adapter negotiation, valid query lifetimes, deterministic indirect bounds and cleanup |
| Spectral atmosphere and remaining source variants | Optional geospatial plugin | RGB sky/celestial/haze already has [numerical and rendered evidence](parity/atmosphere.md); spectral integration and further lighting/overlay variants need separate fixtures |
| Volumetric clouds and streamed terrain/tiles | Optional geospatial plugins | Source parameter parity, streaming/decode budgets, cancellation, geographic error and native story comparisons |
