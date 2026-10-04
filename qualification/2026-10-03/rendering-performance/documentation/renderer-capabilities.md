# Native renderer profiles

Use `backend.capabilities.features` and `limits.sampleCounts` to choose a path.
The native backend queries its adapter for supported RGBA16 float and Depth32
float sample counts. A request for an unsupported count fails explicitly. The
renderer does not switch to a browser or OpenGL implementation.

| Profile | Color and depth | Available behavior | Bounds |
| --- | --- | --- | --- |
| Direct scene | Native output color, Depth32 float | Indexed meshes, unlit/diffuse/standard materials, RGBA8 maps and mipmaps, alpha masks/blending, material sides, lines/points, instances and punctual lighting | 4096 maximum 2D dimension; 65536 instances per view; 16 active lights |
| HDR effects | RGBA16 float, Depth32 float, single-sample history | Exposure, Reinhard, fitted ACES or AgX, up to eight custom screen effects, FXAA, normalized bloom | 128 MiB of targets shared by views; 36 bytes per pixel before bloom |
| Multisample HDR | Four-sample RGBA16 float and Depth32 float resolved to single-sample HDR/depth | The HDR profile with fractional coverage and nearest-sample depth | Only when `sampleCounts` contains 4; 84 bytes per pixel before bloom |
| Selection outlines | RGBA8 coverage mask, shared scene depth | Inner edges on selected objects and descendants; material coverage, section cuts, standard/reversed depth and MSAA | 1 to 8 physical pixels; 64 MiB of masks shared by views; 4 bytes per pixel, or 20 with MSAA4 |
| Forward screen lighting | Full-resolution single-sample RGBA16F/Depth32F opaque source | Optional indirect AO and screen-space reflections using current forward material inputs | Off by default; 128 MiB shared scratch including replacement overlap; 12 bytes per pixel plus a fixed dummy pair |
| Local reflection probes | Six queued HDR face captures and filtered environment maps | Explicit bounded probe collections, per-mesh volume selection and global fallback | Four published probes plus one candidate per collection; 32 MiB declared payload; four capture leases per device |
| Public GPU resources | RGBA8 linear/sRGB, RGBA16/32 float, R32 float; 2D/3D textures | Scoped buffers/textures, WGSL compilation, compute/render graphs, mesh shaders, screen effects and environment convolution | 64 MiB explicit resources; 4096 2D / 256 3D dimensions; format/usage validation |

The same scene/material/effect implementation serves explicit readback and native
presentation. Returned RGBA8 images use sRGB premultiplied alpha. Custom HDR effects
receive linear premultiplied color. `gpuTime` is nullable. Metal reports its completed command-buffer interval;
named pass timings remain null there. Other backends negotiate the required
timestamp features. Never add overlapping CPU waits, resource totals and scene
GPU time. Indirect draws remain outside this profile.

Camera depth is independent of the color profile. `DepthStrategy.reversed` uses
Depth32 float with a zero clear, greater comparison and maximum MSAA depth resolve.
Standard depth remains the default. Both require finite clipping planes; only
backends advertising `RenderFeature.reversedDepth` accept the reversed mode.
See the [planetary depth measurements](parity/planetary-depth.md) for its tested
precision and the public screen reconstruction helpers.

Backends advertising `RenderFeature.selectionOutlines` accept `Scene.outline`.
Outlines run after postprocessing and do not enable HDR by themselves. The mask
reuses selected material shaders with a read-only depth test. Depth-writing
occluders hide it; overlays that do not write depth and coincident surfaces need
the limits described in the [outline contract](design/selection-outlines.md).
Outline masks are included in native graph diagnostics' `targetBytes`.

## Materials and lighting

`StandardMaterial` implements isotropic metal/roughness shading with base color,
normal, metal/rough, occlusion and emissive maps. Base and emissive maps decode
sRGB; scalar and normal data remain linear. UV0/UV1, authored tangent handedness,
derivative fallback and mirrored transforms have native fixtures.

Directional lights use irradiance, and point/spot lights use inverse-square
attenuation with optional range and cone falloff. Hemisphere lighting supplies a
simple diffuse term. Environment lighting computes diffuse irradiance, roughness
prefiltering and a split-sum BRDF table through public GPU resources. This is a
GGX/Smith/Schlick profile with Turquin directional energy compensation.
`PhysicalMaterial` adds clearcoat, sheen, anisotropy, thin films and transmission.
Specular antialiasing filters undersampled highlights. See the
[physical material contract](../packages/zyren_native/doc/physical-materials.md)
for approximation limits, independent HDR references and pipeline budgets.

Directional cascades and spot shadows share a bounded depth atlas. Resolution is
128, 256, 512 or 1024, with up to four directional cascades, one spot projection
and eight total projections per view. Shadow targets have a separate 64 MiB device
budget. Masks cast shadows; blended surfaces do not. Point-light cube shadows remain outside this profile. Rectangular area lights
use LTC for isotropic surfaces and bounded integration for anisotropic surfaces.

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

## Scheduling and publication

Scene uploads stage behind the last complete cover. Retained cover follows the
current camera while pending geometry keeps its own bounded ownership. Tile
publication also retains displayed picking/attribution state, and speculative
prefetch has a separate allowance that cannot displace visible work. Counts do
not prove complete geometric coverage.

Per-view uniform and binding caches reuse unchanged data. Conservative opaque
batching preserves explicit order and transparency barriers; moving cameras can
still rebuild the plan. Resource graphs queue work until a completion boundary.
Logical registry bytes include retained ownership and must not be described as
physical GPU residency.

Cloud adaptation in Planet Auto changes sampling work from measured scene GPU
pressure while retaining the allocated targets. Named quality presets stay fixed.
History publication follows executed graph receipts, including staged tile cover.
The [October qualification record](../qualification/2026-10-03/rendering-performance/README.md)
separates these checks from live provider and foreground performance evidence.

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

The 28 September macOS foreground inspection also confirms visible material
spheres, cube instances, shadows and bloom in the Planet renderer lab. Glow
toggles, orbit input, reset and native window resizing work. A separately named
bundle built from the primary checkout avoided selecting an older Planet window;
the check required no renderer changes. Narrow mobile widths retain the automated
device evidence above.

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
| Remaining material accuracy | Core materials / native PBR shader | Full anisotropic/layered energy and angular agreement beyond the documented approximation grids |
| Point-light shadows | Core lights / native shadow modules | Cube seam/occlusion cases and budget recovery |
| KTX2/Basis, BC/ETC/ASTC and further HDR image decoders | Asset decoder / texture resource modules | Exact format admission, transcoding, mip/alpha/color fixtures and device support |
| Complete source motion-vector/MRT and temporal effect parity | Core effect inputs / native history modules | Native TAA and cloud history exist; generic MRT, source motion contracts and temporal SSR accumulation remain separate work |
| Per-pass timing on remaining devices and indirect draws | Native device capability and graph modules | Native timestamp decoder tests do not establish Vulkan/DX12 device qualification or indirect-draw support |
| Spectral atmosphere and remaining source variants | Optional geospatial plugin | RGB sky/celestial/haze already has [numerical and rendered evidence](parity/atmosphere.md); spectral integration and further lighting/overlay variants need separate fixtures |
| Full cloud and streaming source-story parity | Optional geospatial plugins | Native clouds, stable cover and bounded prefetch exist; all source stories, provider coverage and wider device qualification remain |
