# 03: Resources, assets and general renderer implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the general rendering capabilities needed by a model viewer and independently authored effects plugins.

**Architecture:** Keep CPU descriptions and typed extension contracts in Dart. Upload versioned resources through a bounded native protocol and execute validated render graphs in Rust. Loaders produce ordinary scene objects; geospatial uses the same GPU APIs as every other plugin.

**Tech Stack:** Dart, Rust 1.97.1, wgpu 30.0.1/WGSL, Flutter 3.47.5 examples, glTF 2.0.

**Spec:** [Public API](../../design/native-3d-api.md), [native resource contract](../../design/native-presentation.md), [program](2026-09-26-native-3d-program.md).

## Global Constraints

- Render 3D through native Metal, Vulkan or Direct3D 12. Do not add WebGL, a WebView, JavaScript or an OpenGL renderer fallback.
- Keep geospatial an optional plugin. The general 3D core must never import geospatial.
- Target general 3D capabilities comparable to Three.js; do not claim JavaScript source compatibility or current feature parity.
- Keep scene data, geometry, materials, animation and plugin contracts usable from Dart without Flutter widgets.
- Use Flutter 3.47.5 and Rust 1.97.1 for development; keep Dart SDK >=3.10.0 <4.0.0 and Flutter >=3.38.0 declarations until a tested API requires a higher floor.
- Keep wgpu pinned to 30.0.1 while introducing native texture interoperability; review unsafe HAL code before changing that pin.
- Commit each verified task locally. Do not push or merge without a request.
- Keep shipped prose free of em dashes and attribution trailers.

## Review Focus

- A handle survives device recreation or belongs to another renderer: reject it before native access. Task 1.
- One consumer cancels a shared model request while another still awaits it: deliver the survivor and retire abandoned ownership. Task 3.
- Malformed image/accessor metadata claims huge or overflowing allocations: reject it before allocation/upload. Tasks 2/3.
- An external plugin declares cyclic passes or samples its own write target: report the pass/resource labels and preserve the last valid graph. Task 4.
- Negative scale, alpha sorting and animation disagree between the visible and pickable scene: use shared transforms/deformation semantics. Tasks 5-7.

---

## File map and prerequisites

Use the extracted packages from plan 01. Tasks 1-4 establish M2; tasks 5-8
establish M3. Native presentation can be qualified alongside this work using the
same backend contracts. Use explicit readback for deterministic image tests.

| Files | Responsibility |
| --- | --- |
| `packages/gpu3d/lib/src/resources/{buffer,texture,sampler,resource_scope}.dart` | Typed CPU descriptors and scoped handles |
| `packages/gpu3d_native/native/src/resources/{registry,buffer,texture,upload}.rs` | Native lifetime, budget and upload validation |
| `packages/gpu3d/lib/src/assets` | Source resolution, cancellation, shared jobs and asset scopes |
| `packages/gpu3d_gltf/lib/src/{request,decoder,extensions}` | glTF requests and document conversion |
| `packages/gpu3d/lib/src/rendering/{render_graph,shader,pass_descriptor}.dart` | Advanced public API |
| `packages/gpu3d_native/native/src/{render_graph,passes,shaders}` | Graph executor and render pipelines |
| `packages/gpu3d/lib/src/{materials,lights,animation,spatial}` | General scene capabilities |
| `examples/{model_viewer,shader_lab}` | Public API consumers, without private imports |
| `test_assets/{gltf,images,rendering}` | Small licensed fixtures and expected results |

Run Dart tests in their owning package, Rust commands in
`packages/gpu3d_native/native` and integration tests from each example. Shader
tests use real native compilation. Image comparisons include numeric probes and
tolerances established from the reference, with backend/driver recorded; avoid
one universal byte-identical golden across unrelated GPU implementations.

## Task 1: Versioned resources and binary uploads

Checkpoint, 2026-09-27: explicit resource scopes, typed buffer/texture descriptors,
binary scene transfers, changed mesh records and shared readback views are
implemented. Scene geometry uses the generation-checked registry and survives
visibility changes and sibling view teardown. Native GPU and Flutter integration
tests pass on macOS Metal. The physical Pixel's Vulkan scene/resource rerun also
passes with the task 2 texture checkpoint. See
[the API and protocol](../../design/gpu-resources.md).
Public Flutter platform views still own separate devices. Material/render-graph
bindings and device recovery belong to later tasks.

**Files:** Create resource modules in the map, native `tests/resource_lifetime.rs`,
`tests/upload_validation.rs` and Dart `test/resource_scope_test.dart`. Modify
native ABI/worker serialization and scene snapshots.

**Interfaces:** `ResourceScope.createBuffer(BufferDescriptor) -> Future<GpuResource<Buffer>>`,
`createTexture(TextureDescriptor) -> Future<GpuResource<Texture>>`,
`close() -> Future<void>`. Descriptors include labels, size/format/usage;
handles expose labels, not integer constructors. Internally,
`ResourceKey` contains renderer ID, device generation, slot and slot generation.
Rust `ResourceRegistry::resolve(key) -> Result<&Resource, ResourceError>` validates
all four. Binary command headers contain ABI version, opcode, request ID and
byte lengths; every table/range uses checked arithmetic.

- [x] Add Rust tests resolving a valid key, then rejecting another renderer's key, a reused slot and an old device generation. Pin arithmetic independently:

```rust
#[test]
fn overflowing_upload_range_is_rejected() {
    assert!(checked_upload_range(u64::MAX - 3, 8, 1024).is_err());
    assert_eq!(checked_upload_range(12, 16, 64).unwrap(), 12..28);
}
```

`checked_upload_range(offset: u64, length: u64, capacity: u64)` is the production
validator returning `Result<Range<u64>, ResourceError>` in `resources/upload.rs`.

- [x] Run `cargo test --test resource_lifetime --test upload_validation`; initially expect missing registry/validator. Add truncated headers, unsupported version/opcode, invalid usage, nonfinite transforms, over-budget allocation and scope close with submitted GPU references.
- [x] Implement a renderer-local registry with scope references and fence retirement. Separate CPU cache descriptions from GPU allocation. Use binary typed arrays for geometry/texture payloads and compact changed-transform commands. Retain v1 only through the migration wrapper. Never reinterpret an unvalidated byte slice as a native structure.

```text
upload: validate command framing -> check extent/range/budget -> reserve -> transfer
submit: resolve generation-checked handles -> retain submission references -> encode
scope close: reject allocations -> drop scope references -> retire after submissions
device loss: invalidate generation -> retain CPU recipes -> fail old GPU handles
```

- [x] Verify shared geometry is uploaded once per native device, survives one of two views closing, and evicts only after references/fences permit. Assert one transform edit does not upload geometry again. Run protocol fuzz/property tests with reproducible seeds plus Dart/FFI/Rust suites.
- [x] Document transfer ownership and byte accounting; commit `feat: add scoped GPU resources and binary uploads`.

## Task 2: Textures, dynamic geometry and color correctness

Opaque color texture checkpoint: `TextureImage`, `TextureMap`, independent
samplers, UV0/UV1 and supplied mip levels use binary scene opcode 11 and the
shared resource registry. The native demo exercises filtering and wrapping.
Image decode checkpoint: `NativeImageDecoder` runs bounded PNG/JPEG work on a
CPU isolate and returns core `ImageData`. `TextureImage.fromImage` strips row
padding and owns its pixels. Strict framing, CRC, extent checks and typed errors
cover malformed input; admission uses decoder workspace estimates. See
[image decoding](../../design/gpu-resources.md#decode-image-files).
Dynamic geometry checkpoint: fixed typed layouts, immutable captures and bounded
range journals reach native GPU buffers. Exclusive versions reuse storage;
shared views retain older versions until their owners advance. The core checks
tangent handedness and other typed attributes, but native materials currently
accept position, normal and UV0/UV1 only. Explicit uint16/uint32 index formats
preserve their width through native draws and dynamic copies. Native mipmaps use
linear-light area reduction, optional alpha-weighted RGB and full-chain admission.
Scene images and explicit resource scopes share the same GPU generator. Metal
and physical Pixel Vulkan checks pass. Alpha modes, opacity, cutoffs, explicit
depth policies and render ordering now use native pipeline state with stable
object sorting. Portable lines/points now use bounded native triangle expansion,
pixel/world sizes and shared versioned recipes. Native surfaces reuse those
buffers across camera and size edits. Box faces and sphere seams/poles now have
UV0 mappings verified with native texture probes. The Task 2 audit leaves the
premultiplied transparent compositor boundary open, pending the output-pass work
in Task 4. Joined/dashed strokes and order-independent transparency remain later
renderer work. See
[color textures](../../design/gpu-resources.md#color-textures) for the API.

**Files:** Add core `geometry/{vertex_attribute,vertex_layout}.dart`, resource
texture/sampler modules and native `src/resources/{image_decode,mipmap}.rs`.
Create `test_assets/images`, Dart `test/geometry_update_test.dart`, native
`tests/{texture_render,image_limits}.rs`.

**Interfaces:** `VertexSemantic` includes position, normal, uv0/uv1, tangent,
color, joints and weights. `BufferGeometry.updateAttribute(semantic, TypedData,
{firstVertex})` preserves layout and updates a validated range. `TextureDescriptor`
declares dimension, extent, format, usage, mip count and color space.
`SamplerDescriptor` declares wrap/filter/mip behavior. `ImageDecoder.decode(bytes,
limits) -> Future<ImageData>` is a core service implemented by the native package.
Pin Rust `image` 0.25.10 with default features disabled and PNG/JPEG enabled in
this task's lockfile update; verify its declared Rust floor and licenses.
The pinned crate declares Rust 1.88.0, below this repository's 1.97 floor.
JPEG decoding uses pinned zune-jpeg 0.5.15 directly because image's adapter
disables strict mode and ignores allocation limits. Engine admission accounts
for its coefficient and row buffers. Retain that audit when changing the pins.

- [x] Add an indexed quad with a 2x2 corner texture, repeat/clamp samplers and a second UV set. Probe known linear/sRGB values and alpha conversion independently. Add a dirty-range test:

```dart
final geometry = BoxGeometry(dynamic: true);
final oldRevision = geometry.revision;
geometry.updateAttribute(VertexSemantic.position,
    Float32List.fromList([2, 0, 0]), firstVertex: 0);
expect(geometry.revision, greaterThan(oldRevision));
expect(() => geometry.updateAttribute(VertexSemantic.position,
    Float32List(3), firstVertex: geometry.vertexCount), throwsRangeError);
```

- [x] Run `fvm dart test test/geometry_update_test.dart` and `cargo test --test texture_render --test image_limits`; new format/layout behavior must fail initially. Add compressed-byte limits, truncated PNG/JPEG, malicious dimensions, overflow, unsupported channel formats, mip and row-alignment cases.
- [ ] Implement attribute validation, index widths, tangent handedness and dirty-range merging. Decode images with strict extent checks plus an engine budget around decoding and output allocation. Decoder limits alone are insufficient because some allocation limits are best effort. [Image limits contract](https://docs.rs/image/0.25.10/image/struct.Limits.html).

```text
image: bound input -> read dimensions -> checked decoded byte estimate -> decode
texture: negotiate format/usage -> reserve bytes including mips -> upload aligned rows
color: sRGB decode for color images -> linear shading -> output conversion once
alpha: straight input -> blend semantics -> premultiplied compositor boundary
```

- [x] Add opaque/mask/blend modes, explicit render ordering and transparent depth-write defaults. Test lines and points with portable geometry expansion where wide native primitives are unavailable, including pixel/world size units. Unsupported format/usage returns a typed error.
- [x] Run texture/geometry/FFI tests on Metal and available Vulkan/D3D12 hosts, add a textured native example and commit `feat: render textured and dynamic geometry with explicit color rules`.

### Task 2 audit

| Requirement | Current evidence |
| --- | --- |
| Texture corners, wrap/filter, UV0/UV1 and linear/sRGB probes | `texture_render_test.dart`, native `texture_render.rs` and the textured SceneView integration |
| Dynamic attribute validation, journal merging, shared captures and index widths | Core geometry/index tests, native geometry update tests, malformed packet tests and Metal/Pixel integrations |
| Bounded PNG/JPEG decode and typed errors | `image_decoder_test.dart`, native `image_limits.rs`/`image_abi.rs`, Flutter decoder integration |
| Native mipmaps and ownership | Native mip fixtures, explicit scope regeneration, odd extents, alpha-weighted filtering and Metal/Pixel integrations |
| Alpha modes, depth, ordering and portable primitives | Material and primitive pixel fixtures plus direct native presentation on Metal/Pixel |
| Built-in UVs | Six box-face corner probes and four sphere quadrants on Metal/Pixel; seam/pole and dynamic UV tests |
| Transparent premultiplied compositor boundary | Implemented. Straight capture/effect inputs, Metal surface bytes and Pixel Flutter composition checked. Apple window-compositor pixels and other platform qualification remain open |

The implementation arrived in focused local commits listed in Git history and
`docs/verification.md`. The native test hosts available here are Metal and the
Pixel's Vulkan backend. D3D12 qualification remains open. Task 3 can proceed with
the existing textured material path while the compositor requirement stays
tracked above.

## Task 3: Typed asset loading and glTF models

Current checkpoint: typed requests, shared jobs, worker parsing/preparation and
scope-owned static model templates are implemented. `Gltf.asset` and `Gltf.uri`
produce ordinary core scene instances with shared immutable geometry and images.
The supported unlit subset, unsupported features and required diagnostic PBR
mode are listed in the [fixture matrix](../../packages/gpu3d_gltf/README.md).
The standalone model viewer passes bundle and HTTP loading, relative dependencies,
reloads and native presentation checks on Metal and physical Pixel Vulkan. Its
widget tests cover cancellation, retry, input during pending work, object names,
scene selection, route cleanup and desktop/narrow layouts. Compiled release
worker tests and native texture/lifetime probes also pass. Release builds and
manual visual inspection are tracked separately in verification; the Mac remains
locked, so no manual window inspection is claimed. Full glTF/PBR/animation parity
belongs to the later tasks and extension work.

**Files:** Implement core `assets/{asset_scope,asset_request,source_resolver,shared_load}.dart`;
create `packages/gpu3d_gltf/{pubspec.yaml,lib/gpu3d_gltf.dart}` and decoder modules.
Create `packages/gpu3d/test/shared_load_test.dart`,
`packages/gpu3d_gltf/test/{accessor,model,uri_policy,cancellation}_test.dart`,
`test_assets/gltf` and `examples/model_viewer`.

**Interfaces:** Implement `AssetRequest<T>`, `LoadTask<T>`, `ModelAsset` and
`Gltf.asset`/`Gltf.uri` from the spec. A request carries a typed
`AssetLoader<T>`, so ordinary glTF loading needs no separate registration.
`AssetDecodeContext` provides source resolver, image decoder, cancellation and
budgets. `SceneRuntime.assetServices` supplies defaults and host overrides; these
CPU services can initialize without a view. Flutter supplies bundle resolution;
core and glTF import no Flutter.

- [x] Create a memory resolver fixture implementing `ByteSourceResolver`: URI-to-byte map, per-URI request count and controllable completion. Cancel one of two consumers and assert the survivor receives an independently usable model with one underlying fetch/decode:

```dart
final first = scope.load(Gltf.uri(uri));
final second = scope.load(Gltf.uri(uri));
final cancelled = expectLater(first.result, throwsA(isA<LoadCancelled>()));
first.cancel();
resolver.complete(uri, fixtureBytes);
await cancelled;
final model = await second.result;
expect(resolver.requestCount(uri), 1);
expect(identical(model.instantiate(), model.instantiate()), isFalse);
```

- [x] Run core shared-load and glTF tests; expect missing decoder behavior initially. Cover cancellation of the final consumer, scope close during decode, progress with unknown length, relative references, redirected base URIs, URI traversal policy, bad GLB lengths, sparse/interleaved accessors, normalization and unsupported required extensions. Validate against the [glTF 2.0 specification](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html).
- [x] Implement checked parsing, source resolution and shared jobs keyed by source/version/options. Separate consumer cancellation from the job. Decode workers return transferable typed data; cancellation prevents scene publication and drops late decoded ownership. Mutable URI caches need stable content identity or explicit invalidation.

```text
consumer joins: attach its task to matching shared job
consumer cancels: remove it; cancel job only if no consumer remains
decode completes: recheck each live scope -> deliver once per consumer
deliver: one template wrapper per consumer scope over shared immutable decoded data
instantiate: clone nodes/animation state; retain immutable decoded resources
scope.release(template): stop future instantiation; retain live instance resources
```

- [x] Build bundle and URI viewers with progress, cancel/retry, object names and errors. Before PBR task 5, require an explicit unlit diagnostic override for metallic/roughness assets and label that mode. Do not claim faithful standard glTF rendering yet. Maintain a fixture-backed extension matrix.
- [x] Verify decode does not block UI input, repeated load/cancel/route removal settles all tasks, and one removed view does not invalidate another instance. Run analyzer/tests/integration; commit `feat: load glTF assets with scoped cancellation and shared resources`.

## Task 4: Public render graph and shader plugin API

Compiler checkpoint, 2026-09-27: `ShaderSource`, `ShaderCompiler`, opaque
`ShaderProgram`, typed UTF-16 diagnostics and lazy `context.shaders` ownership
are implemented. The native worker validates WGSL modules, bounds admission and
shares live modules across compilers on one device. Compiler errors preserve
the device. Custom materials, platform-view integration and the independent
effects example remain open. See
[shader compilation](../../design/shader-compilation.md).

Graph checkpoint: public typed bindings and compute-to-render execution now run
on Metal and Pixel Vulkan. Immutable candidates validate access, dependency order,
layouts and pipeline interfaces before replacing an active graph. Compiled graphs
retain their programs and resources; buffers can update without recompilation.
Whole-allocation lifetimes and weak pipeline caches are implemented. This profile
uses explicit resource textures. Lazy `context.resources` and `context.graphs`
services now own allocations and graph compilation per attachment, with explicit
execution and cleanup on failed attach. Typed output services and independent
shared-device engines pass GPU tests. Scene insertion, custom mesh materials,
resize/history and the separate effects consumer remain open. See
[render graphs](../../design/render-graphs.md).

Presenter checkpoint: Metal and Android backends now implement the native graph
backend contract through their existing platform worker queues. Plugin resources,
shaders and graph textures use the presenter's device. This closes service access
on those adapters; graph output composition and custom scene materials still need
their own rendering integration.

Frame composition checkpoint: `GraphDescription.sceneColor` and `output` connect
scene rendering, compute/render effects and native presentation in one submission.
An attachment claims `context.frameGraph` and selects a compiled replacement in
`beforeRender`. Device, dimensions, final output initialization and pending-frame
lifetime are checked. This establishes scene-first composition on Metal and
Vulkan. Automatic pass registration, custom mesh materials, resize/history and
the separate effects consumer still need implementation.

Effects consumer checkpoint: `examples/shader_lab/effects_plugin` now imports
only public core APIs and provides two spatial render passes. Its typed controls
update uniforms without recompilation. Child resource scopes support transactional
resize and cleanup, including failed candidates and closure during compilation.
Missing capabilities reject by default or bypass explicitly. The Flutter demo
uses native presentation. This closes the independent spatial consumer portion;
custom materials, automatic registration and temporal history remain open.

Custom material checkpoint, 2026-09-28: `compileMesh` returns an opaque program
for `ShaderMaterial`, with engine transforms in group 0 and read-only user
bindings in groups 1 through 3. Native pipelines validate before publication,
retain bindings, share cached variants and drain accepted frames before release.
The separate plugin now supplies a UV stripe material alongside its spatial
effects. Metal and Pixel Vulkan integration covers shader pixels, material
controls, zero-readback presentation, resize and cleanup. See
[custom mesh materials](../../design/shader-materials.md). Automatic pass
registration, temporal history and transparent compositor output remain open;
task 4 is not complete.

Preparation phase checkpoint: `GraphDescription.beforeScene` and
`FramePassStage.beforeScene` separate resource preparation from post-processing.
Dependencies sort within phases, while the scene boundary prevents backward
dependencies and early access to scene color. The native command buffer now
executes preparation, scene drawing, effects and output conversion in order.
Compute-generated material textures are verified in their producing frame.
This is the execution contract for the pending shared registration layer.

Shared registration checkpoint: attachment-owned `context.graph` now accepts
compute/render preparation and ordered effect builders. The engine combines
independent plugins, owns resize candidates, rejects stale builds and preserves
same-sized valid graphs after failed edits. `GraphRegistration` controls enabled
state, invalidation and removal. Manual composition remains an explicit exclusive
alternative. The independent effects package uses this API, and Flutter reports
nonfatal candidate issues while keeping the current viewport ready. History and
transparent compositor output remain open, so task 4 is still in progress.

Transparent output checkpoint: nullable scene backgrounds, background opacity,
straight-alpha effect inputs and captures, and native compositor conversion are
implemented. Native surface tests and Pixel Flutter composition check fractional
coverage. The image adapter preserves alpha metadata and converts at the Flutter
boundary. See [scene alpha](../../design/scene-alpha.md). Temporal history remains
open, along with Apple window-compositor pixel proof and broader platform gates.

Temporal history checkpoint: shared effect builders create `TextureHistory`
pairs with validity/generation uniforms. Two precompiled variants exchange texture
roles after successful backend completion. Resize, projection changes, camera
replacement, explicit cuts and engine recreation reset samples; failed candidates
retain valid history. The independent temporal blend and compute consumers verify
pixels and cleanup on Metal and Pixel Vulkan. See
[texture history](../../design/texture-history.md). Task 4 still needs its acceptance
audit, with Apple window-compositor proof and broader platform qualification open.
Actual HDR/TAA and motion/depth rejection stay in task 8.

Acceptance audit, 2026-09-28: task 4's public API and independent consumer are
implemented and checked. The exact compute-to-render fixture, typed bindings,
ordered hazards, labeled failures, transactional replacement, mesh materials,
typed plugin services and history run through the public Dart/native path.
See the [acceptance evidence](../../verification.md#render-graph-acceptance-2026-09-28).
Transient allocation reuse remains disabled under the recorded conservative
resource policy. Apple window-compositor inspection and iOS, Windows, Linux and
Adreno qualification remain program gates, not evidence supplied by this audit.

**Files:** Create graph/shader modules from the map, native
`src/render_graph/{compile,execute}.rs`, Dart `test/render_graph_test.dart`,
native `tests/shader_diagnostics.rs`, `examples/shader_lab` and a separate
consumer package at `examples/shader_lab/effects_plugin`.

**Interfaces:** `ShaderSource.wgsl(source, label:)`,
`ShaderCompiler.compile(ShaderSource) -> Future<ShaderProgram>`,
`ShaderCompiler.compileMesh(ShaderSource, bindings:, vertexLayout:) -> Future<MeshShaderProgram>`,
`ShaderBindings`, `Workgroups`, `ComputePassDescriptor`, `RenderPassDescriptor`.
`RenderGraph.addCompute`/`addRender` return `Registration`; descriptors declare
resource reads/writes, dependencies and load/store operations.
`GraphCompiler.compile(GraphDescription) -> CompiledGraph` validates before
replacing the active graph. `ShaderMaterial` binds a checked program/layout and
parameters. Public APIs expose no native pointers.

- [x] Create a two-pass fixture: write a storage texture with the WGSL below, then sample it on a full-screen quad. Bind group 0, binding 0 is an `rgba8unorm` storage-write texture. Dispatch `Workgroups(8, 8, 1)` for a 64x64 target:

```wgsl
@group(0) @binding(0) var output: texture_storage_2d<rgba8unorm, write>;
@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
  if (any(id.xy >= textureDimensions(output))) { return; }
  textureStore(output, vec2<i32>(id.xy), vec4<f32>(1.0, 0.0, 0.0, 1.0));
}
```

- [x] Run graph tests and `cargo test --test shader_diagnostics`; assert labeled failures for cycles, uninitialized reads, write/read alias conflicts, sample counts, bindings, invalid WGSL source locations and unsupported storage formats. A failed edit must preserve the prior valid graph.
- [x] Implement topological ordering, lifetime intervals, validation and capability negotiation. Use wgpu's validated usage model for hazards. Start without transient aliasing optimization, then enable only proven nonoverlapping compatible lifetimes. Cache pipelines by source/layout/options/device generation.

```text
registration -> immutable candidate -> validate labels and hazards
compile -> create pipelines/resources transactionally
success -> swap at frame boundary; retire old graph after submitted use
failure -> close candidate scope; keep current graph; report diagnostics
```

- [x] Add a public custom mesh material and two-pass postprocess consumer with resize/history invalidation. Include capability fallback/rejection tests. Plugins expose typed services/configuration to other plugins through attachment scopes, without private Rust access.
- [x] Analyze the separate consumer, run real GPU output tests and commit the API in focused checkpoints through `0ae2760`.

## Task 5: PBR, lights, shadows and environment maps

The static material baseline is qualified on macOS Metal and physical Pixel
Vulkan as of 28 September 2026. The checks below are complete for the documented
profile. Task 6 is next; full glTF, Three.js, Takram and other platform
qualification remain open.

Direct-light checkpoint, 2026-09-28: `StandardMaterial`, directional/point/spot
scene lights and opcode 19 now reach native Metal/Vulkan rendering. Independent
pixel probes cover BRDF values, no ambient energy, emission, roughness, point
falloff, spot cones including float32 collapse, masks and mirrored transforms.
The Flutter sphere grid exercises 12 shared-geometry materials and live light
controls. See [the current API](../../design/standard-materials.md).
Texture checkpoint: normal, metallic/roughness, occlusion and emissive maps now
share existing image ownership with independent samplers and UV sets. Explicit
tangents and dynamic ranges reach native buffers, with a derivative fallback when
attributes are absent. Hemisphere lights provide the diffuse indirect term for
occlusion checks. The HDR checkpoint adds RGBA16Float scene/resources, terminal
exposure and Linear/Reinhard/ACES curves through the existing compositor. Shared
effects preserve HDR precision and reset history when precision changes. See
[color pipeline](../../design/color-pipeline.md). Task 5 remains open for
the glTF gates listed below. This is not the full PBR profile.

HDR asset checkpoint: `HdrImageData`, `HdrImageLoader` and native RGBE decoding
preserve float pixels through CPU scopes and RGBA16F resource uploads. Flutter
presets include the HDR decoder. All eight orientations, bounded RLE parsing,
aggregate asset budgets, cancellation and finite half-float conversion have
regressions. Metal and Pixel Vulkan verify upload, mip generation and compute
sampling. See [HDR assets](../../design/hdr-assets.md) for the supported file
profile.

Environment checkpoint: `EnvironmentMap` prepares diffuse irradiance/pi, GGX
specular levels and a correlated-Smith BRDF lookup through core compute graphs.
`EnvironmentLighting` owns per-view preparation, retains the current map after
failure and publishes replacements between frames. Intensity and rotation
update without reuploading images. Native frame envelopes bind the scoped maps
to standard materials. Tests cover analytic directional convolution, independent
BRDF quadrature, HDR radiance, material pixels and resource lifetime. See
[environment lighting](../../design/environment-lighting.md) for the supported
profile and its single-scattering approximation.

Shadow checkpoint: typed light settings and mesh flags now drive native depth
atlases. Directional cascades use float64 camera-relative fitting and texel
stabilization; spotlights and point lights use perspective maps. Atlas ownership
is bounded per view and device, with dirty-input reuse and explicit diagnostics.
Pixel checks cover cascade transitions, all six point faces, alpha masks,
geometry updates, mirrored winding and planet-scale coordinates. See
[native shadows](../../design/shadows.md) for the supported profile. Standard
glTF and exact extension qualification still keep Task 5 open.

glTF material checkpoint: standard mode now imports metallic/roughness triangles,
all five texture bindings, authored tangents and punctual light instances.
Analytic native pixels cover map transfer functions, channel selection, units,
range, rotation, masks, emission, occlusion and handedness. One decoded source
can supply shared sRGB and linear image variants with independent samplers.
The viewer exposes an authored PBR assembly and a studio toggle for scenes without lights.
See [the import profile](../../design/gltf-materials.md). Vertex colors now reach
built-in triangle, line and point materials, dynamic GPU updates and masked
shadows. The loader accepts float and normalized byte/short RGB/RGBA colors.
MikkTSpace now prepares missing normal-map tangents through a bounded CPU service.
The material reference checkpoint adds 150 independent linear HDR direct-light
patches and 45 environment interpolation patches on Metal and physical Pixel
Vulkan. These checks correct intermediate-metallic blending and glossy peak
precision. See [material reference checks](../../design/material-reference-checks.md).
Advanced profiles and complete glTF or Three.js parity remain open.

**Files:** Create core `materials/standard_material.dart`,
`lights/{directional,point,spot,hemisphere}_light.dart`; native
`passes/{pbr,shadow,environment}.rs`, WGSL modules,
`test_assets/rendering/{pbr,shadows}` and `native/tests/pbr_render.rs`.

**Interfaces:** Implement `StandardMaterial` fields from the spec, named light
descriptors with explicit units, shadow settings and `EnvironmentMap` through
asset/resource APIs. A core lighting plugin owns environment prefilter/BRDF
resources. glTF conversion produces ordinary descriptors, without a separate
glTF rendering path.

- [x] Add a fixed-camera sphere grid for roughness/metallic values, maps, emissive, occlusion and shadows. Complement it with numerical fixtures for tangent handedness, alpha masks, overlap, directional/spot shadows, point-light falloff and negative scale. Compare linear-light probes and reference patches:

```text
black metal + zero environment -> no invented diffuse energy
roughness increases -> broader specular lobe without NaN/Inf output
mirrored transform -> correct normals, tangent orientation and winding
masked leaf -> matching depth/shadow silhouette at the same cutoff
transparent overlap -> documented ordering and depth-write policy
```

- [x] Run `cargo test --test pbr_render -- --include-ignored` on a real GPU. Establish tolerances independently and document sorted-transparency limitations.
- [x] Implement metallic/roughness BRDF, normal mapping, punctual lights, IBL and environment convolution through core graph/resources. Add shadow maps with bounded atlas allocation, directional cascades, bias controls and dirty invalidation. Put color conversion/tone mapping in one terminal path.

```text
scene -> lights/casters -> dirty shadow/environment passes
opaque/mask -> depth and PBR passes
blend -> sorted transparent pass with explicit depth/blend state
linear HDR -> tone map/output conversion -> presentation
```

- [x] Enable standard glTF rendering after reference fixtures pass. Qualify the supported `KHR_materials_unlit` and `KHR_lights_punctual` profile with exact tests. Keep other required extensions rejected. Advanced physical-material and area-light profiles remain individually reviewed follow-on work.
- [x] Run GPU fixtures, model-viewer lifecycle and mobile capability checks. Commit the material, lighting, shadow, glTF and numerical qualification changes in focused checkpoints.

## Task 6: Instancing, morph targets, skinning and animation

Core transform checkpoint: immutable vector/quaternion tracks, independent
mixers and playback actions now implement step, linear and cubic sampling,
weights, reverse playback, loop modes and frame-demand ownership. The native
animation lab demonstrates two separately controlled copies of one clip.
See [the API](../../design/animation.md). Task 6 remains open for skin/morph
deformation and the remaining tests below.

glTF animation checkpoint: the optional loader imports STEP, LINEAR and
CUBICSPLINE TRS channels into core clips. Model instances expose indexed nodes,
scene-filtered clips and independent mixers. `AnimationSystem` accepts mixers
after a view initializes and releases their demand on removal. The model viewer
provides clip selection, playback and seeking. Skinning, morph deformation and
broader animation features remain open.

GPU instancing checkpoint: `InstancedMesh` batches built-in triangle materials
through native instance buffers. The 10000-copy test confirms one opaque draw
and one pipeline variant. Dirty ranges, reflected normal/tangent transforms,
transparent ordering, shadow bounds and shared-view lifetimes pass native
checks. Metal and physical Pixel Vulkan presentation pass with zero readback.
See [instancing](../../design/instancing.md). Custom shader instancing, per-copy
colors and skin/morph deformation remain open; the full task stays unchecked.

Checkpoint, 28 September 2026: native vertex-stage skinning and morph targets
now use immutable source geometry with per-mesh pose buffers. Metal and physical
Pixel Vulkan checks cover material pixels, independent poses, current bounds,
shadow invalidation and zero-readback presentation. A GPU numeric oracle checks
position, normal and tangent errors below 1e-5. The demo adds playback, seeking,
speed and morph controls and verifies pause-to-idle behavior. See
[deformation](../../design/deformation.md). glTF skin/morph loading, morph-weight
animation tracks, completion events, additive mixing and finite repetition
counts remain open, so Task 6 stays unchecked.


Import checkpoint, 28 September 2026: glTF skin and morph loading now creates
instance-local joints and weight bindings over shared geometry. Typed weight
tracks cover step, linear and cubic interpolation with atomic pose updates.
The model viewer loads an authored two-ribbon GLB and frames its deformed bounds.
Metal and Pixel Vulkan integration verify imported pixels, a 400-byte pose edit,
independent state and pause-to-idle behavior with zero presentation readback.
Task 6 remains open for completion events, additive mixing, finite repetition
counts, custom shader deformation/instancing and per-instance color support.


Morph tangent checkpoint, 28 September 2026: normal-mapped glTF morphs can now
omit base tangents. The CPU worker generates every changed pose, preserves all
pose seams and stores tangent deltas within the job's shared payload and
iteration limits. Metal and Pixel Vulkan checks compare final-pose pixels with
independently generated absolute geometry, including UV1 and flat normals. The
Skin + normal map viewer sample adds a twist target, with zero-readback
presentation and 400-byte pose edits. Task 6 remains open for the animation and
custom shader work listed above.

Playback lifecycle checkpoint, 28 September 2026: actions now accept finite
repetition counts and emit typed loop/completion snapshots after the full pose
commits. Tests cover reverse and ping-pong endpoints, fractional durations,
replay, callback-driven successors and atomic failures. Native pixels retain
the completed pose without geometry uploads. The animation lab exposes run
counts and status; Metal and physical Pixel Vulkan checks verify natural
completion releases frame demand. Additive blending, custom shader deformation,
per-instance colors and the rest of Task 6 remain open.

Additive checkpoint, 28 September 2026: `AnimationBlendMode.additive` layers
sampled offsets over the normal/rest blend, using a captured reference time.
Shared clips stay immutable. Coverage includes independent morph primitive
rests, quaternion composition order, cubic references, separate clocks and
atomic rejection of singular or oversized results. Native skin/morph pixels
match explicit reference poses with 400-byte layer-weight edits. The animation
lab exposes independent layer strength. Fades/warping, custom shader support,
per-instance colors and the remaining Task 6 gates are still open.

Transition checkpoint, 28 September 2026: actions now support fades,
cross-fades and integrated speed transitions. Cross-fades schedule both actions
atomically, optionally matching rates for clips of different lengths. Tests
cover paused layers, reversals, irregular frames, fade-end clock limits,
rollback and idle demand. The animation lab reuses Swing and Reach actions and
exposes layer fades and slow-to-stop controls. Custom shader deformation and
instancing, per-instance colors and the remaining Task 6 gates stay open.

Custom geometry shader checkpoint, 28 September 2026: mesh programs declare
rigid, instanced, deformed or combined geometry. Public WGSL helpers expose the
native deformation kernel and instance transform/face conventions. Vertex
layouts cover UVs, tangents and colors. Native tests compare every profile and
layout with rigid reference geometry, including mirrored winding, and retain
old captures through pose/instance edits. The material plugin supports these
profiles and the shader lab has animated geometry controls. Per-instance colors,
custom shader shadows, separate skeletal instance palettes and remaining Task 6
gates stay open.

Instance color checkpoint, 28 September 2026: `setColor` and `setColors` publish
validated linear RGB tints with the same snapshot and dirty-range ownership as
transforms. Built-in materials multiply base RGB by the tint; custom shaders
read it at location 13. Each changed record uploads 128 bytes. Native references
cover ordinary and morphed instances, mixed winding, material/vertex color
products and shared-view retention. The 1000/10000-instance benchmark retains
one draw and stable residency through camera, transform and color edits. The
shader lab exposes a palette control. Task 6 still needs its final gate audit;
custom shader shadows and separate skeletal instance palettes remain open.

**Files:** Create core `scene/instanced_mesh.dart`, `animation/{clip,track,mixer,action}.dart`,
`geometry/{skin,morph_target}.dart`; native `passes/deformation.rs`, WGSL,
`test/animation_test.dart`, `native/tests/deformation_render.rs` and viewer controls.

**Interfaces:** `InstancedMesh.setTransform(index, Mat4)` updates one instance;
`AnimationMixer.play(AnimationClip) -> AnimationAction`; actions support `pause`,
`seek(Duration)`, `stop`, `speed`, `weight`, `loop`. Tracks bind stable node IDs
and typed properties, using step/linear/cubic interpolation. Mixers own demand
only while active. `Skin` contains joints/inverse bind matrices; morph weights
belong to instances, not templates.

- [x] Pin keyframe values, negative playback, loop boundaries and demand release. Add a two-bone fixture, normalized weights and two independent instances:

```text
first mixer seeks to 500 ms; second remains at 0 ms
-> only the first instance changes joint/morph state and visible pose
stop final action -> scheduler settles after the final pose frame
10,000 transforms -> bounded instance uploads, no per-instance pipeline creation
```

- [x] Run animation tests and `cargo test --test deformation_render -- --include-ignored`; missing deformation/shared-state defects must fail. Cover joint bounds, nonfinite weights, excess joint counts, mirrored/nonuniform transforms and zero-duration clips.
- [x] Implement track mixing, bind-pose validation, instance buffers and deformation within negotiated limits. CPU fallbacks must be explicit and measured; otherwise reject unsupported counts. Publish deformed bounds for culling/picking. Preserve cubic quaternion normalization and glTF interpolation semantics.

```text
sample typed tracks -> blend local pose -> update world transforms
resolve skin/morph state -> update changed buffers -> deform geometry
publish current bounds/revision -> draw instances -> retain until GPU completion
```

- [x] Add playback/seek/speed and morph controls. Verify demand stops when paused and resume avoids a giant time step. Compare a small GPU-deformed mesh with a CPU oracle using bounded positional error.
- [x] Run animation/GPU/asset tests and instance benchmarks; commit `feat: render instanced and animated models`.

Checkpoint audit (2026-09-28, `c6d9892`): all five task 6 gates are covered.
`animation_test.dart`, `animation_lifecycle_test.dart`, and
`animation_plugin_test.dart` pin sampling, independent mixers, loop boundaries,
and demand release. `deformation_test.dart` and `deformation_packet_test.dart`
cover pose ownership, bounds, invalid bindings, and backend limit rejection.
Native `deformation_render.rs` compares GPU output with an independent CPU
oracle; `instances.rs` covers 10,000 instances and bounded range updates.
Shader Lab exposes playback, seek, speed, morph, and instance palette controls.
The checkpoint passed 646 tests plus one macOS Metal integration test. The
instance benchmark records one draw and a 128-byte upload for one changed
transform or color among 10,000 instances. Android release compilation passed;
live Vulkan qualification and the other platform runs remain open. These checks
complete task 6, not the full library or cross-platform release qualification.

## Task 7: Cameras, bounds, culling, picking and controls

**Files:** Create core `scene/{group,orthographic_camera}.dart`,
`spatial/{bounds,frustum,ray,raycaster,bvh}.dart`, `controls/orbit_controls.dart`;
modify facade picking/input. Create `test/{raycaster,camera,controls}_test.dart`
and viewer selection integration tests. Create the optional Flutter package
`packages/gpu3d_inspector`, with `lib/gpu3d_inspector.dart`,
`lib/src/{scene_inspector,stats_overlay}.dart` and widget tests; it depends on
`flutter_gpu3d` and does not enter core dependencies.

**Interfaces:** Implement `Bounds3`, `Ray`, `Raycaster`, `OrthographicCamera`,
layer masks and `PickResult`. Use plan 01's `ViewportPoint.toNdc`.
`SceneController.pick` captures camera, logical viewport and scene revision at
request time. `OrbitControls` uses core input/frame services and holds demand
only through interaction/damping. Scene LOD selection stays generic.
The inspector exports `SceneInspector(controller:)` and
`SceneStatsOverlay(controller:)`, using public scene/status/diagnostic contracts.
They borrow the controller and own only their subscriptions.

- [ ] Test ray/triangle/box intersections, misses, edges, nearest ordering, visibility/layers, orthographic rays, instance IDs and scale. Compare a visible highlighted triangle with the pick result:

```text
same logical pick at DPR 1, 1.5, 3 and resolution scale 0.5
-> same object/world intersection within tolerance
camera moves during async pick -> result uses captured revision
animated mesh -> hit current deformed surface, not stale bind pose
```

- [ ] Run spatial/camera tests and selection integration; absent picking/culling must fail. Singular transforms and zero-size views return typed invalid requests, not NaN hits. Include overlay buttons and scroll-parent gesture competition.
- [ ] Implement CPU bounds/triangle picking, then static-geometry BVH refit/rebuild on revisions. Account for deformed/instance transforms and sidedness. Use conservative frustum bounds; unknown bounds stay visible. Correct world distance after nonuniform local transforms.

```text
capture revision -> map point to NDC once -> construct world ray
filter visible/layer bounds -> intersect matching geometry -> sort world distance
return nearest object/instance/triangle/UV and sceneRevision
```

- [ ] Add compact selection/framing/orbit controls, projection switching and independent multi-view cameras. Put the reusable inspector and throttled statistics overlay in the optional inspector package; test its subscription cleanup and desktop/narrow layouts. Verify orbit settling, pointer cancellation and focus without global event interception.
- [ ] Run unit/integration/GPU culling fixtures; commit `feat: add scene picking cameras and orbit controls`.

## Task 8: HDR effects, history and renderer profiles

Task 5 now supplies HDR scene targets and terminal tone mapping. The existing
history API inherits HDR color and resets on precision changes. Bloom, MSAA,
spatial/temporal antialiasing, profile publication and the remaining task 8
fixtures are still open.

**Files:** Create core `rendering/history_texture.dart`, native
`passes/{tone_map,antialias,bloom}.rs`, WGSL and `native/tests/postprocess_render.rs`.
Extend shader lab/viewer; create `docs/renderer-capabilities.md`, `benchmarks/renderer`.

**Interfaces:** `HistoryTexture` owns per-view ping-pong resources and validity
generation. Effects declare features/dependencies. Core provides multisample
resolve, tone mapping, antialiasing and bloom primitives. Stats expose nullable
timestamps. Profiles list formats/sample counts/features rather than OS names.

- [ ] Add HDR bright-patch, MSAA edge, bloom impulse and camera-history fixtures:

```text
resize / camera cut / projection change / device recovery
-> invalidate history before another temporal sample
two controllers share a scene -> independent history textures and indices
unsupported HDR format -> documented alternate profile or unsupportedFeature
```

- [ ] Run `cargo test --test postprocess_render -- --include-ignored` and shader-lab integration; absent history/conversion must fail. Test fractional-alpha edges and ensure output conversion happens once.
- [ ] Implement graph dependencies, negotiated floating formats, resolve ordering and budgeted history. Start with tone mapping/spatial antialiasing; enable temporal accumulation only after motion/depth/history tests pass. Capture and viewport share final output color/alpha semantics.

```text
HDR scene -> selected effects -> antialias/resolve -> tone map -> output transfer
history invalid -> seed current frame without sampling stale history
history valid -> accumulate using declared motion/depth rejection
```

- [ ] Publish implemented profiles and an extension backlog for advanced physical materials, area lighting, compressed textures, further formats and effects. Give each item a required fixture and owning module/plugin. Untested entries remain outside the qualified feature claim; Three.js breadth remains the overall target.
- [ ] Run viewer, shader lab, multi-view and representative GPU benchmarks. Verify plugins use public imports only; commit `feat: add HDR effects and qualify renderer capability profiles`.

## Exit gate

A developer can load a supported standard glTF scene, select/animate it and add
a separately packaged shader effect without editing Rust or importing private
files. Capabilities, ownership and limitations accompany working examples.
Atmosphere and clouds still belong to the optional plugin plan.
