# Native renderer profiles

Select features through `DeviceCapabilities`; rendering stays on Metal, Vulkan
or DX12. A backend that can't satisfy a requested feature returns an issue.
No browser or OpenGL fallback is part of these profiles.

| Profile | Scene color | Coverage | Final output | Effects |
| --- | --- | --- | --- | --- |
| Default | RGBA8 sRGB | One sample | SDR sRGB | Public render graph |
| HDR | Linear RGBA16Float | One or four samples | SDR sRGB after exposure and tone map | Bloom, spatial AA, temporal AA, custom graph passes |

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
| Temporal histories and motion | 128 MiB per view by default; 256 MiB per device, including replacement overlap |
| Transmission capture | 128 MiB including replacement overlap; 64 MiB color attachment |
| PostProcessing intermediates | 64 MiB per graph by default; configurable within device limits |
| Punctual / hemisphere / rectangular area lights | 16 / 4 / 4 |
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

macOS Metal passes native pixel and surface checks for these effects. The iPhone
17 Pro simulator on iOS 26 passes both gallery surface cases, including effect
toggles, resize and zero presentation readback. Physical iOS, Android Vulkan and
Windows DX12 remain separate device qualification gates. Compiling a platform
package does not qualify its presentation, driver behavior or timing.
The app could not be foregrounded during this run because the display was asleep;
a manual visual check remains open.

The temporal profile passes both macOS Flutter gallery cases. The physical
gallery also passes on macOS Metal and the iPhone 17 Pro iOS 26 simulator, including
glass/area controls, MSAA/TAA/bloom switching and 320/960-pixel layouts with zero
presentation readback. The simulator uses the host GPU; it does not qualify a
physical iPhone.

The core already includes scene hierarchies, camera projection and framing,
orbit, trackball and fly controls, bounds/culling/picking/BVH, dynamic and procedural geometry,
Bézier/Catmull-Rom paths, swept tubes, instancing,
skinning/morphs, animation blending, standard PBR, shadows, environment lighting,
custom WGSL materials, compute/render graphs, scoped assets and glTF loading.
These are implemented feature families, not a claim of complete Three.js parity.

`PhysicalMaterial` adds native IOR, specular, clearcoat, sheen and anisotropy
factors, ten texture maps and glTF physical extensions. Transmission and volume
add opaque color/depth capture, refraction and absorption. Native pixels cover
direct, area and environment lighting, loaded models and deformation variants.
See [physical materials](design/physical-materials.md).

Native CPU decoders now load Draco, meshopt and Basis/KTX2 through the glTF
plugin. Real compressed models pass Metal pixels and resource cleanup; Flutter's
default services also decode them without creating a renderer. Basis transcodes
to RGBA8, so compressed GPU texture residency remains separate.
See [compressed assets](design/compressed-assets.md).

Rectangular area lights now integrate diffuse, GGX and physical-layer response
on Metal. Four oriented emitters are supported per scene. Fixed LTC tables add
128 KiB per renderer outside scoped counters. Area-light shadows and broader
device qualification remain open. See [area lights](design/area-lights.md).

Shapes with holes, beveled extrusion and topology helpers are available in Dart.
Trackball and fly plugins share the existing per-view input and frame-demand
contracts. See [geometry and controls](design/geometry-controls.md) for limits,
coordinate conventions and keyboard/gamepad integration.

The remaining breadth has concrete acceptance work:

| Family | Owner | Required evidence before claiming parity |
| --- | --- | --- |
| Further geometry utilities | Core geometry/math | Shapes with holes and beveled extrusion pass CPU/Metal checks; text, subdivision and CSG remain open |
| Further physical materials | Core materials/native shaders | Layered reflectance and capture-based transmission pass Metal checks; iridescence, dispersion, nested volumes and broader device references remain open |
| Area lighting and additional shadows | Core lighting/native renderer | Photometric references, occlusion and bounded atlas behavior |
| Compressed assets | Asset plugins/native decoders | macOS fixture, cancellation, budget and Metal checks pass; other native targets and compressed GPU residency remain open |
| Further loaders and exporters | Optional asset plugins | Round trips, provenance, error recovery and allocation cleanup |
| Full camera/control and animation breadth | Core plus control plugins | Reference gestures, hierarchy transforms, clips and multiple views |
| Temporal AA and advanced effects | Core effect plugins | Built-in triangle TAA passes Metal convergence, motion, deformation, budget and multi-view checks; custom shader/primitive motion and broader device qualification remain open |
| Takram geospatial parity | Optional geospatial plugins | Reference story, control, atmosphere, cloud and effect fixtures |

Bloom here is a single-scale Gaussian effect. Spatial AA is a local edge-aware
filter. Neither establishes parity with UnrealBloomPass or SMAA.
`TemporalAntialiasing` supplies a separate jitter, motion and depth reconstruction
path before graph effects. See [temporal AA](design/temporal-antialiasing.md) for
its supported materials, memory accounting and rejection rules.

Combined HDR/MSAA/bloom/spatial/history fixtures verify independent histories on
shared-scene views, exposure changes, camera cuts, projection changes, resize and
reattachment to a replacement native device. These checks exercise application
recovery. They do not inject a physical GPU or driver loss.
