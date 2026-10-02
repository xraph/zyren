# Reality capture: point clouds and Gaussian splats

You can follow both packages here. This work owns `packages/zyren_pointclouds`,
`packages/zyren_splats` and their package examples. Neither package is published.

## Source audit and decisions

The audit on 2026-10-02 found native `PointGeometry`, `PointsMaterial` and point
packet support. Core `Raycaster` queries triangles only. `AssetLoader`,
`AssetDecodeContext` and `LoadCancellation` provide bounded source loading;
`GpuScope` owns native resources and drains accepted work on close.

`RenderPassDescriptor` supports procedural instances and premultiplied alpha.
Its public attachments expose color, with no depth attachment or sampled scene
depth. Mesh shaders can access the scene depth pipeline, but custom displacement
has no matching point or Gaussian CPU query. The particle implementation is a
useful lifecycle reference, not a Gaussian renderer.

We will keep two packages. Both identify a record by the tuple `(sourceUri,
sourceVersion, recordIndex)`. These values survive rendering and sorting. Scene
object IDs are runtime handles and must not replace source identity. Both use
core `Object3D` transforms and scoped ownership, with no Flutter or geospatial
dependency. You supply coordinate units and any geospatial transform.

Point positions retain float64 source values. Native markers use positions
relative to a source origin. Picking reports the source sample and transformed
world position using an explicit world-space radius; it does not infer a measured
surface from marker pixels. Splats provide appearance, not measurement accuracy.

## Phases and acceptance

1. Bounded point import, native markers and source picking.
   - Strict XYZ text through the core asset loader, byte/line/point/decoded limits,
     finite validation, cancellation and stable record indices.
   - Recentered native point geometry with an explicit float32 error limit.
     Source coordinates remain independent of the display approximation.
   - Query transformed samples, respect visibility and supplied clipping planes,
     deterministic ties, reject closed handles, and remove owned scene objects.
   - Accept when budget and malformed input tests pass, asset scope loading works,
     and a native offscreen image contains the expected points. Report GPU checks
     separately from tests that only execute Dart.
2. Minimal anisotropic Gaussian rendering.
   - Validate positive-definite 3D covariance, color and opacity. Project covariance
     through an orthographic camera, sort far to near with stable record ties,
     evaluate `exp(-0.5 * d^T C^-1 d)` and blend premultiplied color natively.
   - Use a bounded offscreen color pass. No scene-depth integration is claimed.
     This is an orthographic Gaussian slice, not general perspective 3DGS support.
   - Accept when numerical projection and ordering tests pass, native pixels match
     an analytic Gaussian and overlapping colors, and scoped cleanup releases the
     render buffers and target. Include an executable native example.
3. Point streaming and domain attributes.
   - Spatial hierarchy, screen error LOD, frame demand and cancellation on eviction;
     independent CPU/GPU/cache budgets, source-index maps and recovery tests.
   - Classifications, intensity, return metadata and selection filters. Make clipping
     and queries use the same visible subset. Preserve original measurement samples.
   - LAS/LAZ/E57 adapters with explicit scale/offset, units, source mappings, bounded
     decompression, malformed corpus tests and real licensed fixture provenance.
     Inspect pipeline bundle contracts before adding an optional adapter.
4. Splat scenes and streaming.
   - Perspective covariance Jacobian, near-plane handling and numeric conditioning;
     spherical harmonics, documented format adapters and color-space conversion.
   - Camera-driven sorting, GPU sorting and blending qualification, tile streaming,
     LOD, cancellation and separate data/sort/target memory budgets.
   - Integrate scene depth and transforms, shared frame demand, clipping, diagnostics
     and appearance-only source selection. Qualify Metal, Vulkan and DX12 separately.
   - Test sort ambiguity for intersecting Gaussians, multi-view lifetimes and mobile
     budgets. An image comparison alone does not establish geometric accuracy.

## Shared files and dependencies

Requested shared edit: add these two workspace members to `pubspec.yaml`, then run
dependency resolution under `/tmp/zyren-plugin-expansion.lock`. Preserve every
other member. No shared Dart or native API edits are planned for the first slices.
The depth attachment requirement remains a later API proposal, pending ownership
and backend review. No speculative dependency on the pipeline or interaction
packages is required.

## Evidence and current checkpoint

Both first slices are implemented. Fourteen CPU tests passed for asset integration,
budgets, cancellation, precision, transforms, covariance, sorting and agent calls. Two native
offscreen tests passed on Metal: point pixels and source identity, Gaussian falloff
and sorted blending within 2/255, then frame-resource and pipeline retirement.
The active `planet` application was left running; these checks used independent
offscreen contexts. No connected mobile device was used.

Use Flutter 3.47.5 from `.fvmrc`. The default shell Flutter was 3.35.7 and failed
resolution with Dart 3.9.2. `flutter test` executed CPU tests, but its runner could
not start this native backend. `fvm dart test` successfully ran the native checks.
This was a runner distinction, not a missing Metal capability.

Interactive desktop/narrow Flutter layouts, Vulkan and DX12 are unverified.
Both native examples also ran on Metal and wrote private PPM outputs under
`artifacts/reality-capture`. They exercised actual imports/rendering and cleanup.

Verification command: `RUN_NATIVE_GPU=1 fvm dart test --concurrency=1
packages/zyren_pointclouds/test packages/zyren_splats/test`, 16 tests passed.
The native cases also invoke the registered point/splat providers and check that
closing removes discovery. The splat test covers target-budget rejection, hidden
output, overlapping-call rejection and close during an accepted frame.

## Required agent runtime integration

The shared `zyren_agents` contract is required for package completion. Both
packages expose optional `agents.dart` providers using its registry, schemas
and lifecycle. Read tools report source/runtime IDs, classification when supplied,
single-resident-chunk state and exact query coverage. Point geometry queries use
the original samples; Gaussian queries report opacity estimates and unknown scene
occlusion, never measured surfaces or confirmed pixels.

Screen-point adapters use the shared `AgentViewportProvider` for document, scene,
viewport, camera, DPR, revisions and presented-frame correlation. Registry tests
cover discovery, schemas, stale revisions/cameras/frames, deleted targets, bounded
hits and cleanup. Reads leave the scene revision unchanged. Point hits expose
classification bytes or null; splat estimates expose opacity and unknown coverage.
These providers are read-only. No independent MCP server was added. Live MCP and
host-authorized mutation/undo flows remain required before plugin completion.

Existing-plugin adapter backlog: optional `zyren_geospatial` and `zyren_3d_tiles`
context enrichment with source coordinate reference, tileset/tile/feature identity,
LOD and loading state. Inspect the public contracts before implementation. Missing
metadata must remain unknown. These adapters are not established by a source URI.

Remaining work includes phases 3 and 4 in full, the existing-plugin enrichment
adapters, richer source formats, independent point GPU budgets, and qualification
outside offscreen Metal. The first splat slice is an orthographic color pass and
does not join normal scene rendering. No package is complete or ready for rollout.
