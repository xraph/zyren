# Professional ocean implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking. Execute sequentially in this chat, as selected on 2026-10-03.

**Goal:** Deliver a native spectral ocean with globe LOD, realistic optics and effects, physical buoyancy and effective quality controls.

**Architecture:** Keep wave state and queries independent of rendering detail. Compose native compute/material/effect contributions through the geospatial extension host and existing renderer. A separate physics package consumes samples and applies native body impulses under the shared simulation clock.

**Tech Stack:** Dart/FVM Flutter 3.47.5, WGSL, native wgpu, zyren_geospatial, zyren_physics and an optional zyren_particles adapter.

**Spec:** [Ocean specification](ocean-design.md), [approved platform](design.md), [reference audit](water-reference-audit.md). Depends on [plan 01](01-foundation-plan.md) and [plan 02](02-offline-plan.md).

## Global constraints

- Rendering remains native Metal, Vulkan or DX12.
- The core stays independent of geospatial, Flutter, provider APIs and simulation domains.
- Mesh refinement depends on the view. Wave coordinates do not.
- Changing a visual preset cannot alter mean sea level, water density, the canonical sea state or simulation tick rate.
- The shared simulation owner advances physics once.
- A shader compile is not device qualification.
- Preserve current branch and concurrent edits. Commit focused changes after checks, without pushes, merges or co-author trailers.
- Apply `rex-voice` and embedded `humanizer` to repository prose. Use the workspace FVM SDK.

## Review focus

- Render LOD or a second camera changing quality must not move the physical surface: W2-W4 and W9.
- Choppy-wave inversion failure and stale GPU samples must stop or degrade according to explicit policy: W4 and W9.
- Chart seams, cube corners, poles and rebases must preserve phase and coverage: W3.
- Failed quality allocation must preserve the previous usable resources: W2 and W11.
- Transparent foregrounds, reversed depth and underwater transitions must not double-apply attenuation or expose another view's textures: W5-W7.

## Package and file map

`packages/zyren_geospatial_ocean` owns `lib/src/waves/`, `surface/`, `rendering/`,
`queries/`, `buoyancy/`, `interactions/`, `quality/`, the extension, tests and README.
Its main library imports only core and geospatial. Native backend packages are
test dependencies; production code uses core GPU interfaces.

`packages/zyren_geospatial_ocean_physics` owns the physics bridge, native tests and
physics examples. `packages/zyren_particles/lib/ocean.dart` supplies the optional
spray adapter if that dependency direction passes the boundary check. Otherwise
the Ocean Lab wires particle emitters through the interaction stream directly.

`examples/ocean_lab` owns the native Flutter app, scenes, capture scripts and
qualification records. Add workspace entries only with the first working package
task, preserving concurrent pubspec changes. No empty published packages.

Core/native changes are confined to W5's generic scene-input facility and, if
selected, W6's native reflection-view lease. Read current implementations before
editing because renderer work is concurrent.

## Task 1: W1 Deterministic spectrum and numerical reference

Files under `packages/zyren_geospatial_ocean`:

- Create `pubspec.yaml`, `lib/zyren_geospatial_ocean.dart`, `lib/src/waves/sea_state.dart`,
  `spectrum.dart`, `reference.dart`, `spectrum_model.dart`.
- Create `test/waves/reference_test.dart`, `spectrum_test.dart`,
  `test/support/sea_states.dart` and README with current capabilities only.
- Add the package to root workspace and boundary tooling after inspecting them.

Interfaces:

```dart
OceanSeaState({required int seed, required int canonicalResolution,
  required List<OceanWaveBand> bands, double gravity = 9.81,
  double density = 1025, double meanLevel = 0,
  OceanSpectrumModel spectrum = const PhillipsSpectrum()});
OceanWaveBand({required double patchMetres, required double minWaveNumber,
  required double maxWaveNumber, required double windSpeed,
  required double windHeadingRadians, double amplitude = 1,
  double choppiness = 1, double? depthMetres});
abstract interface class OceanSpectrumModel {
  String get id;
  int get version;
  double energy(double kx, double kz, OceanWaveBand band);
}
Float64List inverseDft2(Float64List complex, int size);
Float64List evolveSpectrum(OceanSeaState state, int band, double seconds);
```

`PhillipsSpectrum` is the initial implementation of `OceanSpectrumModel`, with a
const constructor, stable ID/version and the directional energy calculation.
Register custom model IDs/versions for saved-state decoding; reject missing models.

Complex arrays interleave real/imaginary scalars. Define centered integer
wave-number order and document the sole normalization convention. Input arrays
are immutable snapshots. Validation rejects nonfinite values, nonpositive patch
lengths/gravity, negative density/energy, bad band intervals and unsupported sizes.
Overlapping spectral windows partition energy; they must not sum to more than one.

- [x] Add a small exact inverse-transform test and record its initial failure:

```dart
test('a DC coefficient normalizes to a uniform real field', () {
  final values = Float64List(2 * 4 * 4)..[0] = 16;
  final field = inverseDft2(values, 4);
  for (var i = 0; i < 16; i++) {
    expect(field[2 * i], closeTo(1, 1e-12));
    expect(field[2 * i + 1], closeTo(0, 1e-12));
  }
});
```

- [x] Implement the independent O(N^4) oracle for small grids using these terms:

```dart
final angle = 2 * math.pi * (kx * x + kz * z) / size;
real += coefficientReal * math.cos(angle) - coefficientImag * math.sin(angle);
imag += coefficientReal * math.sin(angle) + coefficientImag * math.cos(angle);
// Store real/(size*size), imag/(size*size) for each output location.
```

  The loop variables come from nested `x,z,kx,kz` loops over `[0,size)`.
  Seed coefficients on the CPU from a specified 64-bit hash of band/kx/kz/seed,
  then upload them. Do not rely on matching CPU/GPU random-number generators.
  Evolve conjugate pairs consistently. DC is zero for a zero-mean wave field.
- [x] Add impulse, conjugate-pair, single-frequency and constant-zero fixtures,
  finite-depth dispersion tests, duplicate seed reproducibility and independent
  derivative finite differences. Restrict direct DFT to bounded test sizes.
- [x] Run package tests/analyzer and boundary checks. Record canonical coefficient
  hashes and the model version, with floating-point tolerance for evaluated waves.
- [x] Commit `feat(ocean): define spectral sea states and reference sampling`.

## Task 2: W2 Native FFT, displacement and derivative outputs

Files: `lib/src/waves/gpu_field.dart`, `fft_plan.dart`, `fft_wgsl.dart`,
`spectrum_wgsl.dart`, `field_snapshot.dart`; tests `test/waves/fft_gpu_test.dart`,
`fft_lifecycle_test.dart` and `field_derivative_test.dart`.

Contract: `OceanWaveFieldGpu.create(GpuScope scope, OceanSeaState state)` returns
a future field. `evaluate(double seconds, {required int resolution})` returns
an `OceanFieldSnapshot` with native displacement/derivative textures, evaluated
time, revision and logical payload bytes. Test-only explicit readback methods
return interleaved numeric arrays. `close()` waits for accepted work and retires
only owned resources.

- [x] Compare 4x4 and 8x8 GPU results to W1's oracle, including a non-symmetric
  complex fixture that catches conjugation, transposition and sign errors:

```dart
final expected = inverseDft2(coefficients, 8);
final actual = await field.debugInverse(coefficients, size: 8);
for (var i = 0; i < expected.length; i++) {
  expect(actual[i], closeTo(expected[i], 2e-5));
}
```

  Define `debugInverse(Float64List, {required int size}) -> Future<Float32List>`
  in test support using the same compiled FFT passes and explicit readback.
- [x] Implement radix-2 Stockham passes, first rows then columns, with ping-pong
  complex buffers and one final normalization. Each pass declares reads/writes;
  no pass binds the same subresource as sampled input and storage output.

```wgsl
fn multiply(a: vec2<f32>, b: vec2<f32>) -> vec2<f32> {
  return vec2(a.x*b.x - a.y*b.y, a.x*b.y + a.y*b.x);
}
fn inverseButterfly(a: vec2<f32>, b: vec2<f32>, phase: f32) -> vec2<f32> {
  return a + multiply(b, vec2(cos(phase), sin(phase)));
}
```

  Derive Stockham indices from stage width and validate every stage against a
  CPU butterfly fixture. Evaluate horizontal displacement, slopes, velocity and
  Jacobian from spectral derivatives, not neighbouring display pixels.
- [x] Build canonical coefficient subsets for each render grid. Missing visual
  bands transfer unresolved slope variance into shading; physical state is kept.
  Test overlapping-band energy, zeros, long time reduction and finite outputs.
- [x] Run with `RUN_NATIVE_GPU=1 ../../.fvm/flutter_sdk/bin/dart test test/waves`
  from this package. Test allocation failure, cancellation, repeated resize,
  quality replacement and zero remaining owned resources after close.
- [x] Commit `feat(ocean): simulate spectral waves with native compute`.

## Task 3: W3 Ellipsoid mesh LOD and stable wave charts

Files: `lib/src/surface/cube_patch.dart`, `neighbours.dart`, `selector.dart`,
`geometry.dart`, `morph.dart`, `wave_chart.dart`, `coverage.dart`;
tests `test/surface/lod_test.dart`, `seams_test.dart`, `chart_test.dart`.

Interfaces:

```dart
OceanPatchId({required int face, required int level, required int x, required int y});
OceanLodSettings({required double maxScreenError, required int maxPatches,
  required int maxVertices, double hysteresis = .2});
OceanSurfaceSelection selectOceanSurface(Camera camera, ViewportMetrics viewport,
  Ellipsoid ellipsoid, OceanLodSettings settings,
  {required double displacementBoundMetres});
// Selection: patches, neighbourEdges, budgetLimited and coverage status.
OceanChartBlend chartBlend(Geodetic position); // Fixed world charts and derivatives.
```

- [x] Test all face-edge mappings and cube corners before native rendering.
  For every neighbouring edge, sample its endpoints and midpoint in ECEF:

```dart
for (final pair in sharedEdges) {
  for (final t in [0.0, .5, 1.0]) {
    expect(pair.first.point(t).distanceTo(pair.second.point(1-t)), lessThan(1e-6));
  }
}
```

  `sharedEdges` comes from the tested `OceanPatchNeighbours.sharedEdges(...)`;
  its entries expose oriented `OceanEdge.point(double) -> Vec3`. The helper
  computes expected sphere/ellipsoid projection independently from mesh vertices.
- [x] Build six face quadtrees, displacement-aware bounds, horizon culling and
  hysteretic screen-error refinement. Enforce at most one-level neighbour deltas,
  edge stitching and geomorphs. Budget exhaustion keeps coarse complete coverage.
- [x] Define wave charts on a fixed world partition, independent of visible
  mesh patches. Blend displacement and its derivative with normalized smooth
  weights. The derivative must include the weight term:

```text
d(sum(w_i*h_i))/dx = sum(dw_i/dx*h_i + w_i*dh_i/dx)
```

  Keep resident charts requested by physics even off camera. Deterministic chart
  IDs/seeds survive rebase and streaming. Verify continuity at chart overlaps and
  poles. Reject unsafe displacement/fold-over configurations explicitly.
- [x] Render wireframe transitions and a continuous surface-to-orbit path.
  Record maximum screen-edge error, patch/vertex counts and no coverage holes.
  Check two cameras produce the same sampled world waves.
- [x] Commit `feat(ocean): add continuous globe surface detail`.

## Task 4: W4 Batched surface queries independent of render quality

Files: `lib/src/queries/query.dart`, `cpu_field.dart`, `gpu_query.dart`,
`inversion.dart`, `policy.dart`; tests `test/queries/sample_test.dart`,
`stale_test.dart`, `quality_independence_test.dart`.

Contract: `OceanQuery(positionEcef, GeoInstant time)`;
`OceanQueryPolicy(maxSamples, maxAge, maxHeightErrorMetres, maxIterations)`;
`OceanSampler.sampleBatch(List<OceanQuery>, OceanQueryPolicy)` returns
`Future<List<OceanSample>>` in input order. `OceanSample` fields follow the ocean
spec, including availability/error, so an error never masquerades as height zero.
`OceanSamplerCpu` reconstructs canonical fields in a bounded worker and
`OceanSamplerGpu` dispatches a bounded sample batch with timestamped readback.

- [x] Sample the same positions/tick before and after a visual preset change:

```dart
final before = await sampler.sampleBatch(queries, policy);
await renderer.setQuality(OceanRenderQuality.low);
final after = await sampler.sampleBatch(queries, policy);
expect(after.map((s) => s.height), before.map((s) => s.height));
expect(after.map((s) => s.seaStateRevision),
  before.map((s) => s.seaStateRevision));
```

  `renderer.setQuality` is the W11 controller API; until W11, use a test renderer
  configuration consumer that changes only its render grid. The sampler remains
  the same W4 instance. Keep the final integration test when W11 lands.
- [x] Implement bounded horizontal-displacement inversion with a derivative
  Jacobian and residual stopping criterion. Singular/nonconvergent samples return
  typed failure. Evaluate derivatives/velocity and chart blends from W1/W2/W3.
- [x] Attach sea-state/frame/tick generation to every job. A newer reset invalidates
  queued and in-flight results. CPU reconstruction error includes truncated
  frequencies and interpolation; no unverifiable numeric error claim is allowed.
- [x] Test deliberate readback delay, cancellation, partial out-of-coverage batches,
  removed sources, budget limits, chart boundaries and CPU/GPU agreement. Start
  with 1 cm height and 0.5 degree normal comparison targets in bounded fixtures;
  retain measured actual error and fail configurations that cannot meet policy.
- [x] Commit `feat(ocean): expose bounded physical surface queries`.

## Task 5: W5 Generic native scene inputs for custom surfaces

Files: core `lib/src/rendering/mesh_shader.dart`, `shader_bindings.dart`,
`capabilities.dart` and native `lib/src/` packet/compiler adapters as required;
native Rust `src/renderer/transmission.rs`, `draw_order.rs`, shader binding
validation and packet decoding. Tests: `packages/zyren/test/mesh_scene_inputs_test.dart`,
`packages/zyren_native/test/mesh_scene_inputs_test.dart` and support fixture.

Contract: add `MeshSceneInputs { none, opaqueColorDepth }` to the mesh program
descriptor, plus an advertised native feature. Core supplies a documented WGSL
prelude with current-frame HDR colour/depth, viewport, camera-relative inverse
projection and depth convention. Reserve an engine bind group without colliding
with the current user, instance or deformation groups. Recheck the actual shader
ABI before selecting that group; reject incompatible layouts before compilation.

- [ ] Add a non-water native fixture: opaque coloured geometry behind a custom
  refractive mesh, plus a foreground marker and alpha-blended object. Its sample
  must change in the same frame when the opaque object's colour changes.

```dart
expect(secondFrameBackgroundSample, isNot(firstFrameBackgroundSample));
expect(foregroundMarkerAfter, foregroundMarkerBefore);
expect(viewBBackgroundSample, isNot(viewABackgroundSample));
```

  These values are captured test pixels from the new `verifyMeshSceneInputs`
  fixture, with exact marker locations defined from its orthographic camera.
- [ ] Extend existing transmission capture to include opted-in custom meshes in
  the correct draw order. Exclude the consuming surface from its own opaque
  inputs. Resolve MSAA and preserve depth interpretation for standard and reversed
  modes. Do not encode water-specific packets or shaders in the renderer.
- [ ] Expose only valid frame-owned views. Resource retirement waits for accepted
  submissions; a view switch/resize cannot retain another view's inputs. Declare
  transparencies absent from the opaque capture; verify final sorting separately.
- [ ] Run native fixture tests for two views, HDR, transparency, MSAA, reversed
  depth, resize and failed allocation, plus existing transmission/shader tests.
- [ ] Commit `feat(rendering): expose scene inputs to custom surfaces`.

## Task 6: W6 Surface optics, lighting and reflections

Files: ocean `lib/src/rendering/material.dart`, `water_wgsl.dart`, `optics.dart`,
`reflections.dart`, `lighting.dart`; tests `test/rendering/optics_test.dart`,
`water_gpu_test.dart`, `reflection_test.dart`.

Interfaces: `OceanOptics(absorptionPerMetre: Vec3, scatteringPerMetre: Vec3,
indexOfRefraction: double, roughness: double)`; `waterTransmittance(Vec3 extinction,
double metres) -> Vec3`; `waterFresnel(double cosine, double fromIor,
double toIor) -> double`. `OceanReflectionSettings` contains mode, step limit,
pixel budget and confidence fade. Modes are environment, screenSpace and planar.

- [ ] Check unit-length absorption and optical conservation numerically:

```dart
expect(waterTransmittance(const Vec3(1, 2, 3), 0), const Vec3(1, 1, 1));
expect(waterFresnel(1, 1, 1.333), closeTo(.02037, .0001));
expect(waterFresnel(.1, 1.333, 1), closeTo(1, 1e-12));
```

- [ ] Implement filtered native wave displacement/normals, Fresnel reflection,
  sun/sky integration and bounded refracted water segments from W5 scene inputs.
  Guard foreground depth and empty background. Avoid applying aerial perspective
  to captured radiance twice. Preserve linear HDR until the core display pipeline.
- [ ] Implement screen-space reflections with hit confidence, edge/disocclusion
  rejection and explicit environment contribution outside screen coverage.
  Add planar mode only through a generic native secondary-view lease that owns
  clip plane, dimensions and lifetime. For this mode add core/native tests in
  `secondary_view_test.dart`; reject excessive globe curvature and unsupported
  backends. Never create a reflection CPU readback loop.
- [ ] Render controlled scenes for sun elevation, roughness, coloured submerged
  objects, grazing angles, foreground rejection and reflected nearby geometry.
  Test day/night atmosphere and profiles with reflection disabled explicitly.
- [ ] Commit `feat(ocean): render native water optics and reflections`.

## Task 7: W7 Underwater, caustics and waterline

Files: `lib/src/rendering/underwater.dart`, `underwater_wgsl.dart`,
`water_volume.dart`, `caustics.dart`; tests `test/rendering/underwater_test.dart`,
`waterline_test.dart`, `caustics_test.dart`.

Contract: `OceanUnderwaterSettings` declares absorption/scattering overrides,
shaft steps, maximum integration distance, caustic resolution and particle budget.
`OceanSubmersion.update(double signedDistance) -> bool` uses separately configured
entry/exit thresholds. Volume clipping returns water segment length in metres.

- [ ] Test submersion stability across alternating tiny signed distances:

```dart
final state = OceanSubmersion(enterBelow: -.02, exitAbove: .02);
expect(state.update(-.03), isTrue);
for (final d in [-.001, .001, -.002, .002]) {
  expect(state.update(d), isTrue);
}
expect(state.update(.03), isFalse);
```

- [ ] Integrate absorption/scattering to the nearest valid scene/volume/surface
  intersection. Reconstruct depth once. Clip air segments out, include water-to-air
  refraction and total internal reflection, and preserve transparent background
  semantics. Replace conflicting underwater registrations atomically.
- [ ] Add bounded projected caustics and shafts using actual light direction and
  available shadow visibility, plus suspended particles through the adapter.
  Report approximations and omit unavailable shadowing explicitly. Controls must
  alter real pass counts, target sizes or work limits.
- [ ] Render entry/exit, half-submerged camera, near clip changes, night, submerged
  geometry and geometry outside a bounded water volume. Verify no double fog,
  overbright energy buildup or resource growth across repeated transitions.
- [ ] Commit `feat(ocean): add underwater lighting and waterline effects`.

## Task 8: W8 Hydrostatic force models

Files: `lib/src/buoyancy/probes.dart`, `hull.dart`, `clipping.dart`, `solver.dart`,
`drag.dart`; tests `test/buoyancy/volume_test.dart`, `hull_test.dart`, `force_test.dart`.

Contract: `submergedSphereVolume(double radius, double submergedHeight) -> double`;
`BuoyancyProbe(Vec3 localCenter, double radius)`; `BuoyancyHull` validates a closed
convex indexed mesh and produces non-overlapping tetrahedra. `BuoyancyShape` is
the tagged union of `BuoyancyProbes(List<BuoyancyProbe>)` and `BuoyancyHull`.
`BuoyancyBodyState` contains position, rotation, world centre of mass, linear and
angular velocity, mass and world inverse-inertia tensor. It is CPU data without
a physics-package import. `BuoyancyLoads` contains point loads, intrinsic torque,
displaced volume and error diagnostics. All values use a declared local world frame.

```dart
BuoyancyLoads solve(BuoyancyBodyState body, BuoyancyShape shape,
  List<OceanSample> samples, {required Vec3 gravity, required double density,
  required double stepSeconds});
```

The method belongs to `BuoyancySolver`; query locations and sample IDs must match
the shape's quadrature points. Reject a mismatched sample batch before calculating
forces. Define the small symmetric inertia tensor type in `buoyancy/solver.dart`
if core supplies no suitable public type; do not import renderer matrix internals.

- [ ] Test exact sphere fractions:

```dart
expect(submergedSphereVolume(1, 0), 0);
expect(submergedSphereVolume(1, 1), closeTo(2 * math.pi / 3, 1e-12));
expect(submergedSphereVolume(1, 2), closeTo(4 * math.pi / 3, 1e-12));
```

- [ ] Implement spherical-cap volume with validated finite inputs:

```dart
final h = submergedHeight.clamp(0.0, 2 * radius);
return math.pi * h * h * (radius - h / 3);
```

  Reject overlapping authored sphere volumes unless the caller supplies an
  explicit partition/weight model; validate weights against total declared hull
  volume. Clip hull tetrahedra against local water planes and integrate volume and
  centroid. Test dry/full/half box cases and sloped clipping against an independent
  tetrahedral reference. Reject open/nonmanifold/nonconvex hull proxies.
- [ ] Compute buoyancy opposite gravity, plus drag from local relative velocity:

```dart
final relative = linearVelocity + angularVelocity.cross(point - centerOfMass)
    - waterVelocity;
final buoyancy = -gravity * (density * submergedVolume);
final drag = relative * (-linearDrag - quadraticDrag * relative.length);
```

  Bound drag impulses against effective mass/inertia and step size. Do not use
  the wave normal as gravity or silently erase other force contributors.
- [ ] Test force balance, righting torque, sinking, zero gravity, water currents,
  drag energy dissipation, invalid mass/inertia and hull subdivision convergence.
- [ ] Commit `feat(ocean): calculate buoyancy from displaced volume`.

## Task 9: W9 Native buoyancy bridge and shared ticking

Files: create `packages/zyren_geospatial_ocean_physics` with `pubspec.yaml`,
`lib/zyren_geospatial_ocean_physics.dart`, `lib/src/bridge.dart`, `binding.dart`,
`step.dart`; tests `test/float_test.dart`, `clock_test.dart`, `frame_test.dart`.
Extend generic physics snapshots in `packages/zyren_physics/lib/src/physics.dart`
and `native/src/lib.rs` to expose authoritative centre of mass and inertia, with
`packages/zyren_physics/test/mass_properties_test.dart` for compound colliders.

Contract: `OceanPhysicsBridge` accepts an existing `PhysicsWorld`, sampler and
query policy. `bind(PhysicsBody body, BuoyancyShape shape) -> Registration` owns
only the water binding; `prepare(GeoInstant instant) -> Future<OceanForceBatch>`
gathers validated forces. `apply(OceanForceBatch batch, double stepSeconds)`
checks world/tick/revisions before any impulse. It does not call `world.step()`.
`BuoyancyShape` is the W8 probe-set or hull tagged union. `close()` releases bindings.

Current `BodyState` exposes mass but not centre of mass/inertia. Add those native
properties and their revision before implementing the drag limiter; never infer
them from an old authored proxy after colliders or cargo change. Aggregate mass
properties include collider contributions and caller-supplied additional mass.

- [ ] Build a real dynamic cube and a four-probe vessel in a native PhysicsWorld.
  First verify the mass-property snapshot against symmetric and off-centre compound
  colliders, then verify a cargo change invalidates an already prepared water batch.
  Drive a fixed 60 Hz simulation while rendering at 30, 60, 120 and 144 Hz.
  Equal tick counts must yield matching body trajectories within recorded tolerance.
- [ ] Apply additive impulses at the sampled force points:

```dart
for (final load in batch.loads) {
  load.body.applyImpulse(load.force * stepSeconds, at: load.point);
  load.body.applyTorqueImpulse(load.torque * stepSeconds);
}
```

  `OceanForceBatch.loads` contains body, point, force and intrinsic torque from
  W8; point-force moment is already handled by `applyImpulse(at:)`, so do not
  include it again in `load.torque`. Validate all bodies and revisions first.
- [ ] Run preparation/apply before the single owner's physics integration. Reject
  applying the same tick twice. Stale/failed batches follow explicit pause or
  approximation policy. Transform bodies and velocities during an approved local
  rebase, preserving gravity and external forces.
- [ ] Verify rest displacement, asymmetric cargo, currents, sinking, sleeping,
  re-entry, detaching and persistent state on visual hide/quality change. Re-run
  convergence at 30/60/120 simulation Hz with identical physical duration.
- [ ] Commit `feat(ocean): integrate native physical buoyancy`.

## Task 10: W10 Persistent foam, wakes, ripples and spray

Files: `lib/src/interactions/emitter.dart`, `field.dart`, `field_wgsl.dart`,
`foam.dart`; optional particle adapter; tests `test/interactions/field_test.dart`,
`foam_test.dart`, `events_test.dart`.

Contract: `OceanInteraction(id, GeoInstant time, Vec3 ecefPosition,
Vec3 relativeVelocity, double radiusMetres, double energy)`;
`OceanInteractionField.enqueue(...)`, `step(GeoInstant)`, `reset(int epoch)`.
Settings declare patch size/resolution, damping, wave speed, max events and a
Courant limit. Foam history owns its own bounded native textures and epoch.

- [ ] Test impulse symmetry, finite propagation, energy decay and zero-input rest.
  Enqueue events with duplicate IDs, old epochs and future timestamps; enforce
  deterministic ordering and a bounded queue.
- [ ] Update the wave equation only at admitted stable substeps:

```text
heightNext = 2*height - heightPrevious
           + speed^2 * dt^2 * laplacian(height)
           - damping * dt * (height - heightPrevious)
```

  Check stability for the actual grid spacing before dispatch. Use absorbing
  boundaries and world-anchored windows. Feed hull interaction velocity into wake
  emitters and compression into foam emission, with explicit advection/decay.
- [ ] Couple field displacement into physical sampling when the query policy can
  cover it. Otherwise report visual-only interaction mode and keep its contribution
  out of claimed physical error bounds. Spray and foam use shared timestamped
  events with independent budgets; detach cancels all registrations.
- [ ] Capture a moving vessel wake, debris interaction, whitecaps and shore foam.
  Check field re-centering, pause/resume, budget exhaustion and offline replay.
- [ ] Commit `feat(ocean): render bounded water interactions`.

## Task 11: W11 Effective quality profiles, transitions and diagnostics

Files: `lib/src/quality/settings.dart`, `admission.dart`, `controller.dart`,
`adaptive.dart`, `diagnostics.dart`; tests `test/quality/settings_test.dart`,
`transition_test.dart`, `adaptive_test.dart`.

Contract: `OceanRenderQuality.low/medium/high/ultra` encode the exact initial table
in the ocean specification. `OceanController.setQuality(...) -> Future<void>`
prepares candidate resources and atomically publishes them. `effectiveQuality`,
`estimatedBytes`, `activeEffects`, `seaStateRevision` and `lastFailure` are
observable. `OceanAdaptivePolicy` contains target milliseconds, permitted profile
range, hysteresis and minimum dwell duration. It is disabled by default.

- [ ] Assert every preset field maps to a real allocation, pass setting or work
  bound; selecting an unsupported setting returns a typed error. No decorative
  FFT/LOD controls may survive serialization.
- [ ] Validate allocation admission across active charts, views, old/new resources
  and history before compilation. Preserve the current profile on rejection:

```dart
final previous = controller.effectiveQuality;
final revision = controller.seaStateRevision;
await expectLater(controller.setQuality(oversized), throwsA(isA<ResourceException>()));
expect(controller.effectiveQuality, previous);
expect(controller.seaStateRevision, revision);
```

  `oversized` is a settings copy whose target dimensions exceed the test backend's
  advertised limits. Test this using real candidate allocation as well as a small
  deterministic budget backend.
- [ ] Crossfade display bands/morphs without reseeding physical waves. Reset only
  histories whose layout or interpretation changed. Use deterministic timing traces
  to test adaptation hysteresis, no oscillation and no simulation-rate changes.
- [ ] Register per-pass GPU/CPU timing, logical payload, native allocation when
  available, chart/patch counts and query age/error. Unknown residency stays null.
- [ ] Commit `feat(ocean): expose measurable quality controls`.

## Task 12: W12 Full native lab, offline Earth data and qualification

Files: `lib/src/extension.dart`, ocean exports and README;
`examples/ocean_lab/pubspec.yaml`, `lib/main.dart`, `lib/scenes/`, `test/`,
`integration_test/` and `qualification/`; `tool/qualification/ocean_benchmark.dart`.
Update this directory's progress file and public package documentation.

Contract: `OceanExtension` implements the F1 extension and registers surface,
foam and optional underwater layers, sampler and sea-state services. Layer hiding
only disables corresponding visual contributions. The application supplies data
store, access policy, quality, frame/time owner, atmosphere and optional physics.

- [ ] Add lifecycle tests through the actual expanded scene plugin list: missing
  dependencies, attach failure, independent layers, scope cleanup and duplicate
  physics drivers. Preserve a standalone water use path if no globe is requested.
- [ ] Build six saved scenes: calm ocean, storm, shallow coast, buoyant vessel,
  underwater and orbit-to-surface flight. Use a procedural vessel/hull and owned
  fixtures with exact data revisions. Add compact quality/debug controls and a
  camera route. No control may claim an unregistered capability.
- [ ] Wire real Earth coastline/bathymetry datasets through D3 manifests only
  after documenting provenance and permitted offline distribution. Persist regions,
  restart with networking disabled and verify coast rendering and water samples.
  If that dataset is unavailable, record the global Earth gate as blocked while
  completing and testing the synthetic/all-water scenes.
- [ ] Run the CPU, native GPU, physics and Flutter suites with FVM. Capture fixed
  timestamps, LOD/effect debug views and a motion sequence. Measure whole-frame and
  water incremental CPU/GPU p50/p95/p99, allocations and query accuracy at the
  specification's desktop/mobile targets. Run 100 attach/detach or resize/quality
  cycles and verify resources return to the appropriate shared baseline.
- [ ] Verify desktop/narrow layouts, macOS Metal, Android Vulkan and iOS Metal
  on available hardware. List unrun devices individually; Windows/DX12 cannot pass
  from compilation alone. Record user visual review separately from numeric tests.
- [ ] Commit `feat(ocean): integrate and qualify the native ocean lab` only with
  an accurate completion matrix. Missing global data or platform runs stay open.

## Completion matrix and handoff

| Capability | Owning tasks | Required evidence | Current status |
| --- | --- | --- | --- |
| Spectral ocean and stable queries | W1, W2, W4 | Independent numeric oracle and native comparisons | W1/W2/W4 passed on macOS within documented numeric fixtures |
| Globe coverage and LOD | W3 | Seam tests and continuous native camera route | Passed on macOS with explicit unmet detail bounds; see surface evidence |
| Native optics and underwater effects | W5-W7 | Composition tests and saved captures | Planned |
| Physical buoyancy | W8, W9 | Native body trajectories, force balance and convergence | Planned |
| Wakes, foam and spray | W10 | Field tests, replay and motion capture | Planned |
| Quality and budgets | W11 | Actual work changes, admission failures and timing traces | Planned |
| Integrated offline world | W12, D3 | Cold restart with verified geographic data | Planned |
| Professional visual acceptance | W12 | Scene review plus measured device evidence | Not reviewed |

Read each task's preceding contracts before implementation. Keep first-party
reference summaries small and link to their source. This is an implementation
plan, not a promise that a numerical ocean model alone establishes AAA visuals.
