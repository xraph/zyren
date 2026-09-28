# Native renderer profiles

Select features through `DeviceCapabilities`; rendering stays on Metal, Vulkan
or DX12. A backend that can't satisfy a requested feature returns an issue.
No browser or OpenGL fallback is part of these profiles.

| Profile | Scene color | Coverage | Final output | Effects |
| --- | --- | --- | --- | --- |
| Default | RGBA8 sRGB | One sample | SDR sRGB | Public render graph |
| HDR | Linear RGBA16Float | One or four samples | SDR sRGB after exposure and tone map | Bloom, spatial AA, custom graph passes |

`ColorPipeline` enables HDR and selects linear, Reinhard or ACES filmic tone
mapping. It does not request an HDR monitor output. Four-sample color resolves
before plugins receive it. Custom mesh materials share the scene's sample count.

The current native limits are explicit:

| Resource | Admission limit |
| --- | --- |
| Texture dimensions | 4096 pixels per axis |
| Single resource allocation or transfer | 64 MiB |
| Scene and scoped resources per device | 256 MiB, including replacement candidates |
| HDR or multisample color attachment | 64 MiB per attachment |
| PostProcessing intermediates | 64 MiB per graph by default; configurable downward |
| Punctual / hemisphere lights | 16 / 4 |
| Instances / joints / morph targets | 100000 / 256 / 64 |

These are payload admission limits. GPU padding, render targets, shadow atlases,
staging and decode working memory have separate lifetimes or limits. Resource
counters are not process RSS or total GPU memory. Shader and pipeline caches also
consume memory. See [resource accounting](design/gpu-resources.md).

Metal pixel checks cover HDR values, fractional alpha, MSAA, built-in and custom
materials, graph composition, bloom impulses, spatial edges and allocation
failure recovery. The Flutter surface fixture covers MSAA/effect toggles and
320/960-pixel layouts with no presentation readback. The benchmark runs a native
AOT CLI bundle. [Measured results](../benchmarks/renderer/README.md) include the
readback cost and preserve unknown GPU timestamps as null.

macOS Metal is the qualified host for these new effects. Android Vulkan, iOS
Metal and Windows DX12 remain separate device qualification gates. Compiling a
platform package does not qualify its presentation, driver behavior or timing.
The app could not be foregrounded during this run because the display was asleep;
a manual visual check remains open.

The core already includes scene hierarchies, camera projection and framing,
orbit controls, bounds/culling/picking/BVH, dynamic geometry, instancing,
skinning/morphs, animation blending, standard PBR, shadows, environment lighting,
custom WGSL materials, compute/render graphs, scoped assets and glTF loading.
These are implemented feature families, not a claim of complete Three.js parity.

The remaining breadth has concrete acceptance work:

| Family | Owner | Required evidence before claiming parity |
| --- | --- | --- |
| Procedural geometry and curves | Core geometry/math | Analytic bounds, winding, seams, UVs, ray picks and native pixels |
| Advanced physical materials | Core materials/native shaders | Clearcoat, transmission, volume, IOR, sheen and anisotropy reference scenes |
| Area lighting and additional shadows | Core lighting/native renderer | Photometric references, occlusion and bounded atlas behavior |
| Compressed assets | Asset plugins/native decoders | KTX2/Basis, Draco and meshopt fixtures, malformed input, cancellation and budgets |
| Further loaders and exporters | Optional asset plugins | Round trips, provenance, error recovery and allocation cleanup |
| Full camera/control and animation breadth | Core plus control plugins | Reference gestures, hierarchy transforms, clips and multiple views |
| Temporal AA and advanced effects | Core effect plugins | Motion/depth rejection, disocclusion, jitter and independent history after cuts/resize/recovery |
| Takram geospatial parity | Optional geospatial plugins | Reference story, control, atmosphere, cloud and effect fixtures |

Bloom here is a single-scale Gaussian effect. Spatial AA is a local edge-aware
filter. Neither establishes parity with UnrealBloomPass, SMAA or TAA. The existing
history API supplies lifetime and invalidation mechanics; it is not a temporal
antialiasing algorithm.
