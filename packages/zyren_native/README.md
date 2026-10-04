# zyren_native

Render zyren scenes through native Metal, Vulkan or Direct3D 12. Dart build hooks
compile the bundled Rust crate. You need Rust and the platform toolchain.

`NativeRenderer` implements the existing scene renderer. `NativeBackend` accepts
immutable `FrameSubmission` values through the advanced backend contract. Both
use the same native worker and ABI; neither requires a Flutter engine.

```sh
fvm dart run example/offscreen.dart
fvm dart run example/resources.dart
fvm dart run example/shared_views.dart
fvm dart run example/shader_compiler.dart
fvm dart run example/render_graph.dart /tmp/native-graph.png
fvm dart run example/frame_graph.dart /tmp/native-frame-graph.png
RUN_NATIVE_GPU=1 fvm dart test --concurrency=1
```

Run these commands from `packages/zyren_native` so the native build hook refreshes
the library. The root workspace has no runtime dependencies of its own.

To build a standalone executable with its native library, use:

```sh
fvm dart build cli -t example/render_graph.dart -o build/graph
build/graph/bundle/bin/render_graph /tmp/native-graph.png
```

Distribute the whole `bundle` directory. `dart compile exe` alone does not run
the native build hook or package its library.

The example renders a red box and prints the centre pixel. GPU tests require a
compatible device. In PowerShell, set `$env:RUN_NATIVE_GPU = '1'` before running
`fvm dart test`.

The default backend returns explicit RGBA8 sRGB readback. Apple shared textures
require `experimentalAppleSurfaces: true`; they remain experimental because
Flutter's texture cache delays buffer retirement. Flutter's opt-in native view
presenters are documented in the workspace README.

Use `createResourceScope()` for typed buffer and texture allocations on this
backend's device. Scopes support shared references, binary uploads, explicit
readback and deterministic close. See [GPU resource ownership](https://xraph.com/docs/zyren/gpu-resources)
for limits and ownership. Scene geometry uses the same registry with binary
uploads and changed mesh records. `createView()` returns an independent readback
view sharing the device, geometry revisions and material images. Closing a view
releases its scopes and scene references; the last view closes the worker.
Use `TextureImage.rgba` and `TextureMap` for color textures, UV selection,
wrap/filter settings and supplied or native-generated mip levels. Set
`generateMipmaps: true` to build a full chain in linear light on the GPU. `NativeImageDecoder` decodes PNG
and JPEG on a CPU isolate with bounded admission. For linear float pixels, use
`NativeHdrImageDecoder` with `HdrImageLoader`. See the
[HDR asset API](../../docs/design/hdr-assets.md) for limits and upload examples.
Dynamic geometry uploads merged attribute ranges while preserving captures held
by other views.

`NativeBufferDecoder` decodes meshopt attributes and indices on a CPU isolate.
It supports octahedral, quaternion and exponential filters. You can lower its
output budget per call; the native ceiling is 64 MiB, with at most two active
calls. The decoder creates no GPU device. See the synthetic fixtures in
`test_assets/compression` and their regeneration command.

`NativeMeshDecoder` returns triangle indices and packed attributes from Draco
2.2 meshes. Configure `MeshDecodeLimits` to bound vertices, triangles, attribute
count and decoded bytes. Sequential and EdgeBreaker connectivity run on CPU
workers, with early header checks before connectivity allocation. These limits
bound payloads and codec counts, not total process memory.

`NativeTextureDecoder` transcodes two-dimensional KTX2 Basis textures to RGBA8
on CPU workers. ETC1S, UASTC and Zstd-compressed UASTC retain authored mip levels,
alpha and linear/sRGB metadata. You can lower `ImageDecodeLimits` for all mip
bytes, dimensions and estimated workspace. Two calls may run per Dart isolate;
native workspace admission is shared with PNG/JPEG decoding. Array, cube, video,
HDR, custom swizzle and nonstandard orientation textures are outside this
profile. The default decoder produces RGBA8. Use
`NativeTextureDecoder.forDevice(backend.capabilities)` to retain ASTC, BC7 or ETC2
blocks when the device supports them. Compressed uploads and mip tails remain
compressed in GPU storage. Allocation estimates are not an RSS cap.

Worker requests carry a generation and a monotonic request ID. Worker exit or
error settles every pending request. Stale and duplicate replies are ignored.
Explicit close remains the normal path; native finalization also releases the
handle if the worker exits before it receives a dispose request. The opt-in
finalization test checks the process-local handle count with a real GPU device.

Use `MaterialAlphaMode.mask` for cutouts or `MaterialAlphaMode.blend` for
source-over transparency. Blended materials sort back to front and leave depth
writes off by default. `Mesh.renderOrder`, `DepthWrite` and `depthTest` let you
override those choices. Run `lib/material_alpha_demo.dart` from
`examples/multiple_views` on macOS or Android to try the native material controls.

For opaque transitions, set `Mesh.fragmentCoverage` to `FragmentCoverage(lower:
0, upper: progress)` and give the outgoing mesh the complementary interval.
Built-in color, PBR and shadow passes use the same deterministic pixel pattern.
Coverage edits preserve material alpha and reuse uploaded geometry. Reset with
`const FragmentCoverage.full()`. Custom shaders do not yet expose this hook;
geometric picking excludes empty intervals but does not sample the pixel pattern.

Use `Line` with `LineGeometry` for paths, `LineGeometry.segments` for independent
pairs, and `Points` with `PointGeometry` for circle or square markers. Their
materials let you choose physical pixel or world sizes. Native triangle expansion
keeps widths portable across backends, and camera or size edits reuse geometry.
Run `lib/primitives_demo.dart` to try both size modes. Current lines have butt
ends; joins, configurable caps, dashes and textured sprites remain open.

Use `createShaderCompiler()` or a plugin's `context.shaders` to validate WGSL
modules on the native worker. Source errors include Dart string locations and
leave the device usable. Compilers own their programs, and shared views can
retain them independently. See [shader compilation](https://xraph.com/docs/zyren/shaders)
for the API and limits.

Use `createGraphCompiler()` to execute compute and procedural render passes with
typed buffer, texture and sampler bindings. Failed edits preserve the active
graph, and uniform updates reuse its pipelines. The
[render graph guide](../../docs/design/render-graphs.md) covers ownership,
dependencies and limits. Plugins can use attachment-owned `context.resources`,
`context.shaders` and `context.graphs` without a native backend reference.
The example saves a native compute-to-render heatmap
as a PNG. Use `GraphDescription.sceneColor` and `output` with a scene submission
to process scene pixels on the GPU before native presentation. Plugins select the
compiled graph through an attachment-owned `context.frameGraph` binding, or use
`context.graph` to compose plugin contributions with shared resize and history
management. Both custom mesh material APIs share the same GPU resource owner.

The native graph store admits up to 256 live graphs for composed effects and
resource transitions. Its separate 16 MiB descriptor allowance still applies,
along with 128 passes and 1,024 inputs/resources per graph. Exhaustion rejects the
candidate while existing graphs remain executable. Closing a graph releases its
slot for the next candidate.

For many meshes with the same shader, compile the module once with
`shaders.compile(source)`, then call `shaders.bindMesh(module, bindings: ...)`
for each material. Each binding retains the module independently, including
after its original compiler closes. The native mesh store admits up to 4,096
material bindings and 8,192 retained pipeline variants within its existing
16 MiB descriptor allowance. Shared source modules still follow the separate
shader source limits.

You can call `configureResourceBudget(bytes)` before loading a large scene.
The default registry allowance is 256 MiB; explicit limits range from 16 MiB to
1 GiB. A reduction below live payload bytes fails without changing the limit.
This counts registry payloads. Frame targets, driver allocations and physical
GPU residency are separate. In Flutter, pass `resourceBudgetBytes` to
`SceneRuntime.nativeMetal` or `SceneRuntime.nativeAndroid` to configure the
controller's native session before plugins attach.

Native platform adapters can use `NativeGpuServices.withTransport` to reuse the
resource, shader and graph codecs with their existing renderer queue. The Metal
and Android Flutter presenters use this path. `NativeGpuBackend` provides their
common graph backend and accounting contract; application plugins still use
`PluginContext` and public core types.

On Android, the presenter returns frame diagnostics with the render receipt from
its serial native queue. You can decode that response with
`NativeGpuServices.decodeFrameProfile`, which checks the graph version, frame
request ID and response size. Unknown GPU timings stay null. A diagnostic failure
does not discard a scene upload that native rendering already accepted.

The [shader guide](https://xraph.com/docs/zyren/shaders) covers custom mesh
materials and screen effects.

Custom surfaces can opt into current-view opaque HDR color and depth with
`MeshSceneInputs.opaqueColorDepth`. The [scene-input guide](doc/mesh-scene-inputs.md)
covers shader helpers, reserved bindings, transparency and capture budgets.

Screen effects can write auxiliary storage textures from their fragment stage.
Use `TextureBinding.storage` in user groups 1-3, then sample the texture in a later
effect. Mesh materials and storage buffers remain read-only. The compiler rejects
sampling and writing the same texture in one stage and retains output resources
for the effect's lifetime. You control texture dimensions and must write every
texel the consumer reads.

Register producers with `scene.addEffect(effect, order: -1)` when they must run
before order-zero effects. Lower values run first, ties preserve insertion order,
and replacing an effect keeps its order. Render-settings effects have order zero
and precede registered effects with the same order.

## Scene draw preparation telemetry

You can read `NativeGpuServices.frameProfile()` after a scene frame to separate
uniform preparation from GPU execution. The Planet navigation summary carries
these counters into each measured phase. Missing fields from an older native
runtime remain null.

| Field | Measurement |
| --- | --- |
| `drawPreparationBuffers` | GPU uniform buffers created for mesh passes, lighting, environment settings and shadow sampling in this frame |
| `drawPreparationBindGroups` | Mesh, standard texture and physical texture bind groups created in this frame |
| `drawUniformReuses` | Existing uniform buffer slots used by this frame, including slots that need a write |
| `drawCacheReuses` | Bind groups reused after comparing their layouts and buffer, texture-view and sampler handles |
| `drawUniformWriteCalls` | Calls to `queue.write_buffer` for retained uniforms |
| `drawUniformWriteBytes` | Bytes passed to those writes, using one aligned enclosing dirty range per changed uniform |
| `drawUniformSkippedWrites` | Uniform updates skipped because the bytes match |
| `drawCacheEntries` | Retained uniform, bind-group, default texture-view and sampler entries across cached views |
| `drawCacheUniformBytes` | GPU uniform payload bytes across cached views, also charged to the native resource registry |

Stationary frames can reuse every draw binding and skip every uniform write.
Camera motion still needs matrix updates. A material edit writes its changed
bytes and rebuilds bindings only when the bound resources or layout change.
The CPU intervals include their existing preparation and encoding work;
`cpuEncodeNs` includes uniform comparisons, writes and binding preparation.
GPU time measures the completed submission separately.

The cache keeps up to eight recently used views, with a 64 MiB uniform ceiling
inside the configured registry budget. The scene draw and texture limits also
bound entry counts. Before checking the combined scene budget, admission plans
the release of unused slots and older caches. It credits only final cache owners
whose GPU use has completed, then applies the plan after validation succeeds.
An over-budget candidate leaves existing cache ownership unchanged. Closing a
view releases its cache ownership. Visibility changes prune unused slots, and a
terminal frame failure clears cached bindings
while the native retirement path keeps submitted storage alive until completion.
Resizing preserves uniforms and replaces groups that sample resized targets.

Storage slots follow the source mesh index and pass, not the sorted draw order.
They are not stable object IDs. If you reorder a packet, the cache compares and
updates the slot contents and resource handles before drawing. Opaque capture
and main rendering use separate slots because both execute in one submission.
Scene frames retain the existing completion fence at native handoff.

These counters do not measure all GPU allocations or physical residency.
Shadow caster preparation, effects and custom graph bindings have their own
paths. Reusing a GPU uniform buffer also does not eliminate native staging
allocations: wgpu allocates staging memory for `queue.write_buffer`. Read write
calls and bytes alongside object reuse counts when you compare workloads.

## Opaque ordering and automatic batches

You can keep separate mesh objects for picking and attribution. The native
renderer groups compatible opaque triangle meshes into instance draws while
retaining every source identity in `SceneAdmission.presentedIdentities`.

Explicit `renderOrder` values take priority. Within each order, the renderer uses
64-draw windows to group material and pipeline state within coarse depth bands.
It only swaps draws whose projected bounds prove they cannot produce ambiguous
overlap. Coplanar ties keep their source order. Transparent instances keep their
global depth order.

Automatic batches require matching geometry, material bindings, clipping and
render state. Depth-disabled draws, draws without depth writes, custom shaders,
deformation, explicit instances, outlined meshes, transmission materials and
partial coverage use ordinary draws. Native temporal AA also uses ordinary draws
so motion history keeps its source correspondence. Cloud reconstruction alone
does not enable native temporal AA.

The renderer caps automatic instances at 32,768 transforms (4 MiB) and 256 batches,
with at most 64 source meshes per batch. A single cached plan retains at most
4,096 source meshes. Camera changes rebuild the ordering; unchanged frames reuse
the plan after checking source resource generations. The optional buffer shares
the native allocation budget and retires after its last submission completes.
Required scene and plugin allocations can reclaim it, and rendering falls back
to ordinary draws when a batch buffer cannot fit.

### Read executed counters

`NativeFrameProfile.executedMeshDraws` counts the draws encoded for the scene,
transmission capture and outline mask. `opaqueBatchDraws` counts automatic batch
draws in those passes, while `batchedSourceDraws` counts their original mesh draws.
The corresponding pass entries expose `drawCalls`. Pipeline and bind-group
switch counters cover the same passes, including custom material bindings.
They do not include shadow, motion, graph or postprocessing commands.

`FrameStats.drawCalls` uses this native mesh count plus the existing output and
graph accounting. Older runtimes keep the packet estimate. You can check
`drawPlanReuses` to distinguish a warm plan from a rebuild, and
`automaticInstanceUploadBytes` to see internal transform uploads. The latter is
included in native `profile.uploadBytes`; `FrameStats.uploadedBytes` continues to
report packet uploads. A camera move can rebuild ordering without uploading
unchanged transforms.

Compare equal-content frames when you measure these counters. Readback timings
include synchronization and copying, so a small fixture does not establish
foreground device FPS. GPU timings remain null when the backend cannot measure
them.
