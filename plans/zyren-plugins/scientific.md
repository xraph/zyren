# Scientific visualization

You can follow the scalar visualization work here. The first checkpoint validates
a regular scalar grid, maps values to colors, and renders an axis-aligned slice through the native backend. The package visualizes supplied results. It
does not solve a physical model or establish the accuracy of a measurement.

## Ownership and source audit

This chat owns `packages/zyren_scientific`, its package-local examples and this
plan. It stays on the current branch and uses the shared lock for workspace
registration, dependency resolution and Git index operations.

The 2026-10-02 source audit found:

- `GeometryData` accepts immutable indexed triangle data. `VertexAttribute`
  supports float32 RGB and RGBA colors, and `UnlitMaterial(vertexColors: true)`
  renders them without lighting changing the transfer colors.
- `Vec3` and scene transforms use doubles. Geometry uses float32, so a grid's
  origin belongs in the mesh transform and local coordinates need a measured
  float32 error limit before upload.
- `NativeBackend` renders scene submissions on Metal, Vulkan or DX12. It can
  read back an image for numerical checks. Readback is a verification path;
  it does not qualify Flutter viewport presentation.
- `TextureDescriptor` already supports `d3`, `r32Float`, `rgba32Float` and
  `rgba16Float`, with a 256-texel volume dimension limit and 64 MiB allocation
  cap. `ResourceScope`, shader bindings and mesh/render-graph compilers exist.
  GPU volume work needs a binding/filterability audit and depth-aware rendering
  tests, not a speculative new volume API in core.
- No scientific package or numerical fixtures existed at the audit. We do not
  depend on the pipeline, interaction or timeline workstreams to start.

## Decisions and acceptance criteria

### 1. Validated scalar data and transfer mapping

Store immutable float64 samples with an explicit validity mask. Callers mark
missing samples with null. Reject NaN, infinity, wrong dimensions, invalid
spacing, blank source identities and over-budget inputs before allocating the
owned sample arrays. Retain quantity, unit symbol, source ID, description and
provenance (`synthetic`, `measured` or `simulated`). Require a coordinate length
unit. No implicit unit conversion.

Use a caller-selected, piecewise linear RGB transfer function with ordered stops
and a declared scalar unit and range. Clamp outside that range. Give a constant
range its midpoint color. Reject a unit mismatch instead of relabeling numbers.

Acceptance: independent affine-field fixtures, transfer endpoint/interior and
constant-range checks, missing versus zero checks, invalid-input tests and
input mutation tests. Report numerical tolerances.

### 2. Slice geometry and native example

Support X, Y and Z slices at integer or fractional grid indices. Interpolate
only contributing samples, so a missing neighboring plane cannot invalidate an
exact plane. Omit a whole cell when any corner is missing. Expose omitted-cell
counts and an empty result for an all-missing slice.

Build indexed geometry with vertex colors and the existing unlit material.
Retain grid origin in the mesh transform, measure local coordinate quantization,
and reject geometry exceeding a caller's absolute coordinate tolerance. Colors
are interpolated across triangles after transfer mapping; a nonlinear transfer
is therefore sampled at vertices, not evaluated per fragment.

Default ceilings: 1,000,000 scalar samples (9,000,000 typed payload bytes),
250,000 slice cells and 16 MiB of conservative geometry payload. Preflight the
full lattice before creating geometry arrays. Report actual output bytes and
coordinate error; these are payload limits, not claims about physical GPU
residency or the Dart heap. Use private outputs under
`/tmp/zyren-scientific-evidence`.

Acceptance: exact affine slices on every axis, winding and missing-cell checks,
budget rejection before geometry generation, large-origin precision fixtures,
and a real native example with synthetic labeling and native pixel checks.
Confirm native backend and adapter separately from numerical tests. Close the
backend on failure and success. No web or browser fallback.

### 3. Isosurfaces and irregular surfaces

Add validated unstructured surface connectivity and scalar associations. Add a
bounded CPU isosurface extractor for regular grids with deterministic ambiguity
handling, shared edge vertices, missing-cell holes, stable source-cell IDs and
cancellation between bounded batches. Decide whether tiled marching cubes or
marching tetrahedra best matches expected topology before implementation.

Acceptance: sphere and plane fixtures with position and normal errors, topology
and seam checks, degenerate cells, winding, cancellation and memory ceilings.
Reuse `GeometryData`; GPU extraction remains optional.

### 4. Vector fields and streamlines

Add immutable vector grids with explicit component basis and units. Implement
sampling and bounded glyph geometry, then integration with user-selected step,
length, tolerance and stagnation rules. Stop at missing data and domain edges.

Acceptance: analytic constant, rotational and divergent fields, integration
error against known trajectories, deterministic seeding and termination, and
bounded work. A streamline depicts an input field; it is not a flow solver.

### 5. Time-varying results

Add versioned, source-identified frames with explicit time units and strictly
ordered times. Reuse timeline services through an optional adapter after its
current interfaces are inspected. Define discrete/linear interpolation and
missing-frame behavior, cancellation and bounded two-frame residency.

Acceptance: interpolation errors, deterministic seek, stale-load rejection,
missing frames, frame-demand release and native update/disposal checks.

### 6. Native GPU volume rendering

Audit float texture binding, 3D upload row/slice layout, shader interface and
native depth availability. Use existing scoped resources, transfer textures and
native shaders for a bounded ray marcher. Define sample distance in coordinate
units, opacity correction, clipping, depth compositing, capability failures,
precision limits and teardown before expanding the API.

Acceptance: homogeneous-volume analytic opacity, ramp sampling errors, depth
occlusion, missing voxels, step and texture budgets, cancellation and zero owned
resources after teardown. Qualify Metal, Vulkan and DX12 independently. Only
propose domain-independent shared APIs if a concrete test shows a gap.

## Shared changes and dependencies

Proposed shared edit: add only `packages/zyren_scientific` to root `pubspec.yaml`
and resolve workspace dependencies under `/tmp/zyren-plugin-expansion.lock`.
Re-read the manifest and neighboring plans under the lock. There is no shared
core or native API change for the first checkpoint. Future volume gaps belong
here before any shared edits.

## Checkpoint evidence

Implemented: immutable scalar data and source/unit validation, linear transfer
mapping, bounded X/Y/Z slice generation, missing-cell holes, local coordinate
error checks, scene lifecycle commands and six discoverable runtime agent tools.
The source audit required no shared core or native changes.

Verified on 2026-10-02:

- Package analysis passed. The 18-test suite passed, including real native
  Metal rendering on Apple M3 Max. Numerical affine fixtures use `1e-12 K`
  tolerance. Five native gradient samples had maximum channel error `0/255`.
- Missing-cell native pixels agreed with CPU picks. An authorized registry
  slice change produced the expected native red pixels. Removing the geometry
  cleared the output. Backend teardown completed.
- The native example rendered 1,536 cells, omitted 64, and reported maximum
  local coordinate error `2.384185793236071e-8 m`. PNG/JSON evidence is under
  `/tmp/zyren-scientific-evidence`.
- A live stdio MCP session reused `serveDevtoolsMcp` and `AgentDevtoolsBridge`.
  Discovery, schemas, viewport picking, scalar joining, read-only denial,
  granted mutation, native image change, retry, stale revisions and EOF cleanup
  passed. The analytic scalar join error was `2.682207878024201e-8 K`.
  Transcript and capture evidence are in that directory's `mcp` subdirectory.

Commands: from `packages/zyren_scientific`, run the Flutter 3.47.5 SDK's
`dart analyze`, `RUN_NATIVE_GPU=1 dart test --reporter expanded`,
`dart run example/synthetic_slice.dart`, and
`python3 example/verify_mcp.py /path/to/flutter/bin/dart <private-output>`.
Running the native test from the workspace root omitted its native build hook;
that startup failed. Running from the package fixed the invocation. The default
Flutter on PATH was 3.35.7/Dart 3.9.2, too old for this workspace, so checks used
the SDK pinned in `.fvmrc`.

Other native applications were already open. These checks used their own
headless backend and output paths; no existing app or connected-device session
was changed. Native output was offscreen readback. Flutter viewport presentation,
a human-operated screen flow, Vulkan, DX12 and mobile device checks remain
unverified. GPU residency was not measured. Milestones 3 through 6, undo and
publication remain outstanding. This is a useful implementation checkpoint,
not a complete scientific plugin.

## Runtime agent access, required work

The shared agent specification expands this checkpoint. Scientific owns dataset
source, static/temporal state, scalar units, missing values, transfer settings and
slice actions. The shared interaction owner provides registry permissions,
schemas, viewport identity, raycasting and transport.

Implement `ScientificSliceView` as the common domain command target. It owns one
slice, validates a replacement before editing the scene, rejects stale revisions
and exposes source sample queries and barycentric scalar values on real picked
triangles. Static datasets report unavailable time, never time zero. Removing or
changing the mesh externally makes subsequent domain calls stale.

The optional `agents.dart` adapter uses `zyren_agents` and registers `inspect`,
`sample`, `field_sample`, `sample_triangle`, `set_slice` and `set_transfer`. Only the host registry
grants `scientific.edit`; mutations require expected revisions and retry keys.
Registration must disappear when a view is disposed. No scientific MCP server
or network listener is introduced.

Acceptance: discovery, shared schema/conformance checks, missing-value reads,
denied/granted/stale/retried/cancelled mutations, atomic invalid changes and
provider cleanup. Enrich the shared viewport provider's real hit with dataset
identity, units, interpolation and source kind when its enrichment hook is
available. Correlate only host-supplied scene/document/viewport/camera/frame
information. CPU triangles do not establish pixel visibility. Live native plus
MCP query/action evidence remains a separate check.


Additional shared boundary request: register `packages/zyren_scientific` in
`tool/check_package_boundaries.dart` with only `zyren`, `zyren_agents` and its
own public package allowed. Devtools and native dependencies remain example/test
only. Apply the additive entry under the shared lock without changing other
owners' boundary entries.

The shared viewport callback now exposes scientific metadata on a real pick.
`sample_triangle` joins that pick's runtime object ID, scene revision, triangle
and barycentric coordinates to a scalar value. The live MCP check covers this
flow. It preserves unknown presented-frame and pixel-visibility state.

The scientific boundary entry is implemented. The workspace boundary check
currently fails only on the concurrent devtools adapter's two `zyren_agents`
imports, whose allowlist update belongs to the interaction owner. Scientific
package analysis and its own public-import boundary are clean. No unrelated
allowlist entries were changed here.


## Commit and continuation

Implementation commit: `5f38906` (`Add scientific scalar slices and runtime agent
tools`). It contains only this package, this plan, one workspace member and one
boundary entry. It was committed locally on `main`; nothing was pushed or merged.

The next implementation milestone is validated irregular surfaces and bounded
CPU isosurfaces with analytic topology/error fixtures. Continue runtime coverage
with a real Flutter viewport and human pointer flow before claiming presented
screen integration. Keep the full vector, streamline, temporal and volume scope
above; no backend, device, solver or publication claim follows from this
checkpoint's Metal readback evidence.

## Remaining implementation decisions

Use six tetrahedra per regular cell, with a consistent body diagonal and shared
edge intersection cache. Equality belongs to the low side. Triangles point toward
increasing scalar values; missing corners omit the entire cell. Retain each
triangle's source cell. Unstructured input uses validated triangle connectivity
and explicit vertex or cell scalar association.

Vector components have an explicit orthonormal basis. Streamlines integrate
normalized vectors with adaptive RK4 step doubling in coordinate length units.
You choose tolerance, step limits, maximum length and stagnation speed. They do
not advance physical time or predict flow.

Temporal sources use ordered, versioned frames and a two-frame cache. A newer
seek cancels the previous request. Linear interpolation requires matching grids,
units and source identity; a missing contributing sample stays missing. Keep the
optional timeline adapter separate from the numerical API.

Volume rendering uses the public postprocess depth interface and a sampled 3D
float texture. A fullscreen ray marcher clips against the grid and opaque scene
depth. Its transfer opacity is specified per reference length, with exponential
step correction. Bound texture size, steps and pixel work before rendering, and
close owned GPU resources on failure or disposal. This requires no shared renderer
change. Qualify each backend separately through the package-local Flutter lab.

Surface checks: four analytic/validation tests pass, along with the existing
CPU and agent tests. The 0.73 m sphere on a 0.125 m lattice has maximum vertex
radius error 0.008038175 m and maximum face-normal error 0.138300693 rad. Its
mesh is a closed, consistently oriented manifold with Euler characteristic 2.
The affine plane matches within 2e-6 scalar units and normals within 1e-6.
Exact threshold equality, missing cells, cancellation, geometry budgets and
irregular connectivity validation pass. Native surface presentation follows in
the combined device qualification; these checks establish CPU geometry only.
