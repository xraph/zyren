# Physical materials

Use `PhysicalMaterial` when you need clearcoat, sheen, anisotropy, thin films or
transmission. Its base surface keeps the standard material's metal/roughness maps,
linear data textures and sRGB color textures. glTF factors still multiply their
mapped channels. A zero factor disables the corresponding optional lobe.

The native shader specializes inactive lobes through pipeline constants. It also
prepares view-dependent GGX, coat and sheen terms once before the punctual-light
loop. A material with a metallic factor of one can still transmit when its
metallic map lowers the sampled value, so that combination keeps transmission.

You can use up to 512 distinct built-in pipelines and 128 physical-map binding
layouts in one frame. The renderer checks the combined scene, outline and
transmission passes before it changes the cache. It retires unused variants when
subsequent frames exceed the cache capacity, including retained bind groups that
refer to retired layouts. An oversized working set returns a descriptive error;
you can retry with a smaller set without losing the previous useful pipelines.
These bounds can reject unusually diverse scenes that an unbounded cache accepted.

New variants are created separately and published only after all GPU error scopes
succeed. If creation fails, you can retry the same material keys: the previous
pipelines and layouts remain available, and failed handles never enter the cache.
This transaction covers the complete scene, outline and transmission request.

Preparation can temporarily own up to 1024 pipeline handles and 256 physical-map
variant entries: the old cache plus one admitted candidate set. Each physical-map
entry owns a shader module, a binding layout and its pipeline layouts. Successful
publication returns the cache to 512/128; failed candidates are dropped. These
counts exclude fixed renderer pipelines and handles retained by already encoded
GPU work. Pipeline memory is driver dependent, so the count bounds are not a
physical residency or byte-budget measurement.

Native readback tests compare mapped PBR batches with separately ordered draws.
The coverage includes explicit tangent handedness, nonuniform scale and mixed
transform determinant signs. These fixtures verify material behavior and cache
handling. They do not measure foreground frame rate.

## Directional energy

The base GGX lobe uses the shape-preserving scaling approximation described by
[Turquin](https://blog.selfshadow.com/publications/turquin/ms_comp_final.pdf).
For Schlick normal reflectance F0 and white directional albedo E, its scale is
`1 + F0 * (1/E - 1)`. You get the same scale in punctual lighting, environment
lighting and the isotropic LTC area approximation. The anisotropic area path
integrates the punctual response. Clearcoat uses its own roughness and lookup.

This approximation restores the isotropic perfect-reflector furnace response
while retaining colored absorption. It is view dependent and not reciprocal.
The diffuse budget uses the compensated directional dielectric energy, including
thin-film color where active. Coat attenuation uses compensated coat energy;
Charlie sheen retains its existing fitted directional energy model.

Anisotropic GGX uses an isotropic energy lookup at the geometric mean of its two
GGX widths. You should expect incomplete energy restoration. Independent tests
at anisotropy 0.8, roughness 0.3/0.65/1, NdotV 1/0.5/0.087 and tangent azimuth
0/90 degrees measured white directional energy from 0.7551 to 1.0259. These are
measurements of that grid, not bounds for every material. The IBL bent-normal
prefilter and thin-film view-angle approximation also remain approximations.

Native HDR tests check selected film and coat combinations before tone mapping.
The tested normal-view thin-film thicknesses of 250 and 400 nm with half-strength
coat produced directional channel energies from 0.9694 to 0.9989. The isotropic
LTC tests differ from independent area integration by up to 1.6% at roughness
0.35/0.65/1. You cannot infer exact layered conservation or angular lobe agreement
from a furnace measurement alone.

## Lookup data and lifetime

All three built-in BRDF table generators share one canonical integral. Red stores
Schlick A and green stores B, so A+B is white directional energy. Both axes include
their endpoints: texel `(x,y)` represents `NdotV=x/(width-1)` and
`roughness=y/(height-1)`. The shader maps those coordinates to texel centers.
Caller-supplied BRDF maps need this convention too. A one-texel sampled dimension
uses its center; the built-in generators require larger validated dimensions.

At the exact grazing column, correlated Smith masking has the analytic limit
Ewhite=1. The integrator applies that constraint to A+B while retaining its sampled
A/B ratio. This removes the total-energy endpoint bias. It does not make the
colored split or adjacent near-grazing quadrature exact. GGX keeps alpha at least
0.002025, including an authored roughness of zero.

The renderer allocates a shared 128 by 128 RGBA16F fallback table only when a
prepared PBR frame needs it. A scene using a supplied environment BRDF skips that
allocation and generation pass. Once created, the table costs 131072 registry
bytes while a published or pending view retains PBR geometry, including culled
source meshes. It stays warm across environment switches until the last owner
releases it.
Generation uses 2048 samples per texel in one ordered GPU pass, with no additional
CPU fence. The frame profile reports `energyLut` and includes that draw in totals.
The generator adds one live pipeline while the table exists.

The table stays uninitialized until generation submits. Failed preparation can
retry it. Closing the last owner or publishing an empty scene removes retained
texture and bind-group aliases across views before registry retirement; a culled
source packet still owns its table. Allocation uses the scene budget, and the
immutable table has no replacement overlap or CPU upload staging allocation.

Regenerate the shipped Dart constant after editing the canonical native WGSL:

```sh
fvm dart run tool/generate_ggx_energy.dart
fvm dart run tool/generate_ggx_energy.dart --check
```

## Moving highlights

Standard and physical materials filter specular roughness from screen-space
normal variance. You get variance 0.15 and threshold 0.2 by default. The threshold
caps variance added to alpha squared, which is perceptual roughness to the fourth
power. It is not a roughness slider. Both settings accept finite values in [0,1].

```dart
final material = PhysicalMaterial(
  roughness: .2,
  clearcoat: .5,
  specularAntiAliasingVariance: .15,
  specularAntiAliasingThreshold: .2,
);
final unfiltered = material.copyWith(specularAntiAliasingVariance: 0);
```

Set either value to zero when you need the exact authored roughness. The filter
uses mapped base and coat normals before clipping or alpha discard; it adds
bounded derivative work per fragment and can broaden highlights. Constant normals
keep their roughness. It does not recover detail already lost during normal-map
minification, and it does not replace texture mipmaps or temporal antialiasing.

Indirect specular occlusion varies with roughness and the view-normal angle.
Diffuse ambient occlusion keeps its scalar map value. Punctual and area lighting
are unaffected by the ambient occlusion map. This is an empirical visibility
approximation, so an occlusion texture is still needed for local cavity detail.

Run Shader Lab's PBR example to compare the default with the `Specular AA` toggle.
The toggle changes the public material setting, including when textures are
switched off. Its controls wrap on narrow windows.

## Transmission capture and filtering

Open PBR in Shader Lab and select `Transmission`. You can adjust roughness and
dispersion, then compare single-sample rendering with `4× MSAA`. The footer
reports actual scene and capture draws, including the fullscreen seed when the
renderer reuses opaque results.

Glass samples the current view's opaque color and depth before any transparent
surface or custom `MeshSceneInputs.opaqueColorDepth` consumer. A zero filter
radius uses one depth-aware bilinear tap. Rough transmission uses nine weighted
taps, with at most four depth and four color loads per tap. Dispersion evaluates
three paths when its factor and thickness are nonzero. A fully rejected path
adds one straight-through fallback tap; an environment supplies the offscreen
fallback when available. Foreground rejection follows the view's depth convention.
The radius uses the filtered material roughness, including specular AA.

Opaque capture is reused when its format matches the main attachment, both use
one sample, and all capture draws form a contiguous prefix of the final sorted
draw order. One fullscreen draw seeds associated color and depth, then the main
pass draws the remaining surfaces. You save the duplicate opaque mesh draws at
the cost of that fullscreen read/write. With one opaque mesh the draw count is
unchanged, and workload savings depend on geometry and material cost.

MSAA, a format mismatch, or an opaque draw after a consumer prevents reuse.
Those paths retain opaque redraw. Externally initialized depth remains
incompatible with opaque capture and is rejected before rendering. Glass keeps its existing
single-sample capture under MSAA; custom scene-input consumers use the frame's
sample count and HDR capture with nearest-covered depth resolve. Reuse does not
change clear alpha, clipping, explicit render order, transparent blending, or
jittered capture projection. Capture targets and seed bindings share ownership;
resize and view retirement invalidate every cached view that retained them.
A single-sample capture also retains one seed pipeline, included in the native
live pipeline count. The seed needs no additional texture allocation.

## Local reflection probes

You can capture nearby geometry into a linear HDR environment without GPU readback.
Create `ReflectionProbes` from a `GraphBackend` that also implements `CaptureBackend`,
or use `PluginContext.createReflectionProbes()`. Assign the collection to
`scene.reflectionProbes`, call `update` with a capture point, world bounds and content
revision, then call `advance()` once per frame while `pending` is true. Shader Lab's
Local probes controls capture the left and right halves of its material grid. The
controls show face progress, completed jobs and logical owned storage. They keep
on-demand rendering active until the update finishes or fails.

Each visible PBR object selects one containing probe by priority, then distance from
its world-space anchor to the capture point. Selection happens in double world
coordinates before origin shifting. Retained native covers keep their per-mesh
selection when camera movement reprojects them during scene staging. Materials can
set `localReflections: false`; objects outside the bounds use the existing global
environment. Both the mip-chain and volume global environment models still work.
Selection can jump when an object anchor crosses a boundary. These are capture-point
environments without parallax correction or per-pixel blending.

An update latches six CPU submissions and recomputes their individual frusta. It
preserves authored visibility, layers and clipping. Camera movement in the main view
does not cancel an update. Supply a new content revision when you want new scene
content. Geometry absent from the supplied scene or streamed tile set cannot appear
in the capture. Caller-owned mutable GPU textures and shader uniforms remain live;
pause their writes if you need them to stay consistent across all six faces.

Probe capture inherits explicit global environment and scene lighting. It excludes
local probes, main-view postprocess graphs, display transforms and temporal history.
It does not capture the main camera's volumetric cloud or atmosphere composition
graph. Atmosphere-generated global environment textures can still supply lighting.
Probes force an opaque clear, so blending produces radiance over that background
rather than filtering associated-alpha RGB as an independent environment.

The generic `SceneCaptureView` contract is narrower: it renders a caller-prepared
`FrameSubmission` to a same-device, live, matching-size RGBA16F sampled render target.
Built-in rendering produces straight-alpha linear color. A separately prepared graph
may supply linear RGBA16F output, with its own documented alpha convention. The caller
must prepare auxiliary camera uniforms, graph inputs and any histories independently.
Replaying the main camera's view-dependent graph is not supported by the probe helper.
Capture rejects display tone mapping, temporal effects and multisampling. A queued
receipt means admission and submission were accepted in queue order, not that GPU
execution or physical presentation completed. Resources remain held until completed
GPU serials permit retirement. `clear()` releases a capture cover but retains its
lease; `close()` drains queued use and releases the lease. Four leases are available
per native device, including devices owned by Flutter's native presenter.

The default face size is 32. Allowed sizes are 16, 32, 64, 128 and 256. Default
filtering uses specular width 64, diffuse width 16, BRDF size 32 and 64 samples.
Each collection permits four published probes, one candidate and one capture,
conversion or filtering job per `advance()`. Every filtering job is checked against
16,777,216 integration samples before admission. Capture geometry cost depends on the
supplied scene and is not bounded by that sample cap. The first default update takes
13 jobs: six faces, conversion, diffuse, four specular levels and BRDF. Compatible
later updates reuse the invariant BRDF and take 12 jobs.

Owned logical payload is capped at 33,554,432 bytes. The admission estimate includes
published and retired maps, the candidate, six HDR faces, panorama conversion,
filter parameters, retained environment inputs and BRDF storage. Shared published
and retired allocations are counted once; the candidate reservation conservatively
includes its BRDF even when it can be reused. Capture attachment bytes are reported
separately by `SceneCaptureReceipt.attachmentBytes`. These include reusable native
depth, alpha and transmission attachments and are outside the collection payload
cap. `sharedEnergyLutBytes` reports the shared 131,072-byte fallback energy table
when it is present during capture. It is device-wide, not an incremental allocation
per capture. Geometry uploads, material textures and renderer caches belong to
the device budget, not this environment payload cap. Queue backpressure also applies. Multiple collections
add their storage and capture work; there is no cross-application scheduler.

Publication swaps only a complete candidate. Cancellation, rejected admission and
failed work preserve the last valid map. A native view can keep an old complete map
while its replacement scene is staged or the view is inactive. Retired maps remain
charged until consuming resource-retirement tickets establish that native borrowers
and GPU work have ended and all-view cached aliases have been invalidated. A
collection permits 64 retired generation records; a device permits 1,024 tickets.
Pressure pauses updates with a recoverable error. Advance or close old views, call
`reclaim()`, then retry.

Tickets own actual native references. Duplicate tickets for one allocation coordinate
all ticket-owned references, so shared BRDF tickets cannot deadlock waiting for each
other. Consuming one ticket does not prove physical allocation reclamation while
another ticket remains. Collection disposal drops its ticket ownership and cached
aliases while preserving genuine native cover owners. Resource statistics still
report logical payload, not physical GPU residency. Capture CPU submission time and
job counts are available; auxiliary GPU timing is currently unavailable (`null`).

## Screen-space indirect lighting

Open PBR in Shader Lab, select `Screen lighting`, then enable `AO` or `Reflections`.
Both start off. The controls set the public options below; the reflection floor is
visible while this panel is selected. You can change quality, AO radius and MSAA.
The footer shows source draws and shared scratch storage.

```dart
scene.renderSettings = scene.renderSettings.copyWith(
  screenSpaceLighting: ScreenSpaceLighting(
    ambientOcclusion: true,
    reflections: true,
    quality: ScreenSpaceQuality.medium,
  ),
);
```

The receiving fragment supplies its mapped normal, filtered roughness, metallic
value and current BRDF response. AO multiplies material occlusion in environment
and hemisphere lighting. Its scalar visibility also enters the existing specular
occlusion approximation. Direct lights and emission keep their previous response.

Accepted reflections replace the eligible indirect specular radiance before the
existing Fresnel, energy and occlusion terms. Misses retain that object's selected
local probe or global environment. A missing environment gives zero on a miss;
screen hits still work. Screen radiance is captured once without these effects,
so this is a single screen-space bounce without reflection feedback.

AO supports opaque standard and physical materials, including their optional
lobes. SSR supports the isotropic base lobe. Materials with active clearcoat,
sheen, anisotropy or iridescent film keep environment reflections. Transparent,
transmissive and custom materials do not receive either effect. Alpha masks and
clipping still apply to the opaque source. Unlit opaque objects can supply reflected
radiance and occlusion, but do not receive the effects themselves.

| Quality | AO samples per fragment | Maximum reflection steps |
| --- | ---: | ---: |
| Low | 8 | 16 |
| Medium (default) | 12 | 32 |
| High | 16 | 64 |

AO uses a fixed disk kernel with a default radius of 0.5 world units, intensity 1
and bias 0.02 world units. Radius accepts finite values in (0,1000], intensity in
[0,1], and bias in [0,1]. The projected disk radius is capped at 128 pixels. The
screen depth is a visible-surface approximation, so hidden occluders are absent.

Reflections default to a maximum distance of 20 world units, thickness 0.2 world
units and maximum filtered roughness 0.6. Their finite ranges are (0,10000],
(0,100] and (0,1], respectively. Rays use quadratic step spacing, reject background
and offscreen samples, and accept a front-to-back depth crossing within thickness.
Confidence fades over the outer 5 percent of the screen and the final 20 percent
of the roughness range. Thin or distant surfaces can fall between ray steps.

Filtered roughness at or below 0.05 reads one source color sample. Rougher accepted
hits read at most four deterministic, depth-validated samples over a footprint
capped at eight pixels. The center sample remains included. This bounded cone
approximation does not integrate a full GGX lobe and cannot recover hidden or
multilayer geometry. There is no temporal accumulation, jitter or history storage.
You may see sampling edges during motion; quality changes do not add smoothing.

An enabled frame renders a full-resolution RGBA16F opaque source with Depth32F
before normal transmission and custom scene-input capture. That second capture
includes AO and SSR, so glass and custom scene consumers see the completed opaque
result. The main pass keeps compatible opaque seed reuse. Otherwise it evaluates
the effects again on its opaque draws, including under MSAA. Transparency keeps
its existing authored order. Probe-helper captures exclude screen-space lighting.
Generic auxiliary captures can explicitly use their own current-view settings.

The source always uses one sample. Main rendering still supports four samples,
but source edges have single-sample coverage. No extra MRT attachments are needed.
PBR layouts add two sampled textures and one uniform binding in group 0; the custom
scene-color/depth contract in group 3 stays unchanged. Adapter binding limits still
apply during transactional pipeline preparation.

Source attachments cost 12 bytes per pixel. One serialized scratch pair is shared
by the device, and each executing view redraws it before use. The 134,217,728-byte
cap includes current and candidate attachments, queued older uses and the 12-byte
dummy pair. A replacement that exceeds the cap fails without publishing it.
Replacement and retirement wait up to five seconds for queued native work before
releasing old aliases across views. A failed wait preserves the old scratch;
steady-size reuse adds no completion wait. Closing or disabling a different view
does not retire the current owner's pair. Native command buffers can retain the
old pair until this completion boundary, so a field swap alone is not reclamation.

`screenLightingBytes` reports the device's current logical scratch payload,
excluding the fixed 12-byte dummy pair, even when another view owns it. Device
inspection computes it when queried, including after a queued auxiliary capture.
`SceneCaptureReceipt.attachmentBytes` keeps its depth, alpha and transmission
scope and excludes this shared pair; it is not a complete scene-cost total. PBR draw
preparation also retains two 32-byte settings buffers per cached view. The profile
reports configured sample/step limits and visible eligible/excluded mesh counts.
Those counts precede batching and do not count fragments. `screenLightingSource`
records actual source draws; transmission and scene counters include their own
work. AO and SSR run inside those forward passes and have no separate GPU timings.
Missing timings remain null. Geometry cost and overdraw depend on your scene.

Every executed frame produces fresh inputs for its admitted or retained scene and
current camera. Cuts, resize and failed or staged candidates cannot publish an
older lighting history because none is retained. This statement concerns input
validity, not physical presentation or foreground frame rate.

The [October rendering qualification](../../../qualification/2026-10-03/rendering-performance/README.md)
records the combined suites and artifact limits. A 96 by 96 native fixture compares
AO and reflections at a large world origin with an equivalent local scene, including
two opposite camera offsets while replacement geometry is staged. All six complete
RGBA comparisons match exactly. This verifies those coordinate and retained-cover
cases; it does not establish foreground navigation or universal screen-space quality.
