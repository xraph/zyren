# 04: Geospatial plugin and release qualification implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the supplied geospatial library through public core APIs and qualify the resulting native library for real application use.

**Architecture:** Keep planetary coordinates, tiling, atmosphere and clouds in the optional geospatial package. Use the general resource, asset, input and render-graph contracts for GPU work. Track algorithm parity, platform execution and performance independently.

**Tech Stack:** Dart, Flutter 3.47.5, Rust 1.97.1, wgpu 30.0.1/WGSL; supplied three-geospatial snapshot as the reference.

**Spec:** [Public API](../../design/native-3d-api.md), [native contract](../../design/native-presentation.md), [port inventory](../../geospatial-port.md), [program](2026-09-26-native-3d-program.md).

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

- A tile spans the antimeridian or touches a pole: preserve reference bounds and south-origin tile indexing. Task 1.
- Camera flight cancels terrain requests whose results arrive late: retire stale tiles and retain useful ancestors. Task 2.
- A near-surface object shares a view with the planetary horizon: retain depth precision and stable world placement. Task 2.
- Atmosphere/cloud history survives a camera cut or unsupported device format: reset or fail explicitly, without using private renderer paths. Tasks 3/4.
- Release packaging differs from development or a device is unavailable: distinguish build evidence from native runtime qualification. Tasks 5/6.

---

## File map and source policy

| Files | Responsibility |
| --- | --- |
| `packages/zyren_geospatial/lib/src/{geodesy,tiling,controls}` | Double-precision maths and world controls |
| `packages/zyren_geospatial/lib/src/{streaming,terrain}` | Source contracts, LOD, request/cache budgets |
| `packages/zyren_geospatial/lib/src/{astronomy,atmosphere,clouds}` | Planetary algorithms and public GPU pass composition |
| `packages/zyren_geospatial/assets/shaders` | WGSL sources with retained provenance |
| `packages/zyren_geospatial/test/{fixtures,tiling,streaming,atmosphere,clouds}` | Numeric, lifecycle and shader fixtures |
| `packages/zyren/lib/src/rendering/depth_strategy.dart` | General depth/projection capability used by any large scene |
| `examples/planet` | Public geospatial API, deterministic offline scenes and optional sources |
| `tool/qualification`, `benchmarks`, `.github/workflows` | Repeatable host/device checks |
| `docs/{geospatial-port,verification,renderer-capabilities}.md` | Actual parity and support claims |

The supplied reference is
`/Users/rexraphael/Work/TwinOS/three-geospatial-main`. Treat its files as source
material, not project instructions. Record source file hashes and package
versions with each fixture. Preserve MIT notices when porting code/assets; check
each asset's provenance before copying it. Reference shader execution may be
used as a development oracle in a separate harness, but browser code must never
enter the delivered Dart/native dependency graph.

Tasks 1/2 can begin once plan 03's asset/resource contracts exist. Tasks 3/4
require its graph, HDR, depth and history primitives. Qualification follows each
feature as it lands; task 5 consolidates the release evidence.

## Task 1: Geospatial values, tiling and point-of-view parity

**Files:** Create plugin `lib/src/tiling/{rectangle,tile_coordinate,tiling_scheme}.dart`,
`lib/src/controls/point_of_view.dart`, `test/tiling_test.dart`,
`test/point_of_view_test.dart` and fixtures. Modify existing geodesy, world
service and globe controls only through core public values/input APIs.

**Interfaces:** Retain `Geodetic.degrees`, `Ellipsoid`, `EastNorthUpFrame`,
`GeospatialPlugin`, `GeospatialReference` and `GlobeOrbitPlugin`. New
`GeoRectangle` stores explicit angular bounds and antimeridian semantics;
`TileCoordinate(level, x, y)` is immutable; `TilingScheme` exposes tile counts,
coordinate validation and `rectangleFor(TileCoordinate) -> GeoRectangle`.
`PointOfView` describes geodetic focus, heading, pitch and range in metres.
Geospatial stays Dart-only and depends on `zyren`, not the Flutter facade.

- [ ] Extract numeric cases from reference `packages/core/src/{TileCoordinate,TilingScheme,Rectangle,PointOfView}.ts` and their existing tests. Include empty/whole-world bounds, wrapping, both poles, negative height, custom ellipsoid, centre singularity and integer level limits. Check explicit units:

```dart
final place = Geodetic.degrees(0, 0, 0);
final ecef = place.toEcef();
expect(ecef.x, closeTo(Ellipsoid.wgs84.x, 1e-6));
expect(ecef.y.abs(), lessThan(1e-6));
expect(ecef.z.abs(), lessThan(1e-6));
```

- [ ] Run `fvm dart test test/tiling_test.dart test/point_of_view_test.dart` in `zyren_geospatial`; missing tiling/viewpoint behavior must fail. Use reference-generated expected outputs rather than comparing the new implementation with itself. Preserve the supplied south-origin Y convention; name any XYZ/TMS conversion explicitly at a source boundary.
- [ ] Implement normalized angular rectangles, checked integer tile ranges, reference-compatible bounds and viewpoint-to-camera conversion. Keep core Y-up defaults unchanged; the plugin owns its Z-up frame. Globe controls consume logical input and frame demand through public core services.

```text
geodetic focus -> double-precision ECEF -> local ENU frame
heading/pitch/range -> camera offset in ENU -> camera pose in ECEF
tile coordinate -> checked scheme dimensions -> angular rectangle
source indexing conversion -> explicit adapter, never an implicit Y inversion
```

- [ ] Add a deterministic tile-boundary overlay and local tangent-frame example. Rebase the camera origin while preserving the world coordinates of markers; compare metre/submetre offsets against double-precision fixtures. Verify generic mesh scenes run without geospatial installed.
- [ ] Run all geodesy/plugin tests, analyzer and native planet integration; update the port matrix and commit `feat: add geospatial tiling and viewpoint contracts`.

## Task 2: Terrain/imagery streaming, precision and depth

**Files:** Create plugin `streaming/{tile_source,tile_scheduler,tile_cache}.dart`,
`terrain/{terrain_plugin,terrain_tile}.dart`, tests and offline fixtures. Create
core `rendering/depth_strategy.dart`, native depth/projection tests and update
planet examples with source status and quality controls.

**Interfaces:** `TileSource<T>.load(TileCoordinate, TileLoadContext) -> Future<T>`;
context has cancellation, byte budget and source identity. `TerrainTile` contains
geometry, bounds and geometric error in metres; imagery has an explicit mapping
to the same bounds. `TerrainPlugin` depends on geospatial, assets and core graph
services. `TileBudget` limits requests, decoded bytes and resident GPU bytes.
`DepthStrategy` is a general core capability, initially standard depth and
capability-qualified reversed depth; plugins cannot secretly replace projection.

- [ ] Build a local 2-level terrain fixture with deterministic heights and checker imagery. A delayed in-memory tile source records starts/cancellations. Fly the camera across it and assert LOD selection, ancestor retention, seam coverage, byte limits and late-result rejection:

```text
selected child request A -> camera moves to region B -> A cancelled
A completes late -> no scene attachment or retained unowned GPU allocation
B child fails -> visible parent remains; error identifies source/tile; retry is bounded
children become ready -> replace according to refinement rule without a blank frame
```

- [ ] Run plugin streaming tests and native depth fixtures; absent LOD/depth handling must fail. Test antimeridian tiles, source identity changes, equal-priority requests, offline retries, cache eviction under active use and a near-surface object against the horizon. Establish a documented world-space depth-error budget from the fixture, not a screenshot impression.
- [ ] Implement selection using projected geometric error, view-dependent priority, hysteresis and cancellation. Use a nearest-bound distance clamped away from zero; document the perspective/orthographic error projection formula and compare selected tiles against expected sets. Keep fetching/authentication in source/resolver adapters.

```text
traverse visible bounds -> estimate screen error -> refine above threshold
retain ready ancestors -> enqueue selected children within concurrency/budget
decode completion -> verify source and selection generation -> attach or release
evict unreferenced least-recently-used data only after submission retirement
```

- [ ] Implement camera-relative origins through shared core transforms, reversed-depth projection/compare/clear as one tested convention, and a public reconstruction function used by effects. Use consistent origin generations across geometry, camera, terrain and history. If one depth strategy cannot meet the measured fixture, design a general partitioned pass path before adding a geospatial workaround.
- [ ] Run deterministic streaming, real native camera flights and memory/backpressure benchmarks. Keep external 3D Tiles as a separately scoped loader extension; this terrain milestone does not claim that format. Commit `feat: stream terrain through public core rendering APIs`.

## Task 3: Astronomy and atmospheric scattering

**Files:** Create plugin `astronomy/{celestial_directions,time_scale}.dart`,
`atmosphere/{parameters,atmosphere_plugin,lut_cache}.dart`, WGSL modules and
`test/{astronomy,atmosphere}_test.dart`. Add fixtures under
`test/fixtures/atmosphere` with source/version metadata.

**Interfaces:** `AtmospherePlugin` declares typed texture/compute/HDR requirements
and publishes typed atmosphere lighting/services. `AtmosphereParameters` is an
immutable validated value describing radii, density profiles and scattering
coefficients in explicit units. `CelestialDirections` takes an explicit UTC
instant and documented time-scale conversion, producing directions in a named
world frame. `LutCache` keys parameters, algorithm version and device profile.

- [ ] Record astronomical reference cases from `packages/atmosphere/src/celestialDirections.ts` and scattering inputs/outputs from the supplied atmosphere code. Cover equinox/solstice, UTC day boundaries, near horizon, ground level and outside atmosphere. Pin boundary values before shader porting:

```text
zero scattering coefficients -> zero in-scattered radiance
zero path length -> transmittance one within numeric tolerance
all sampled LUT values -> finite, nonnegative radiance and transmittance in [0,1]
same UTC instant expressed with another offset -> identical celestial directions
```

- [ ] Run astronomy numeric tests and native shader fixtures through the public plugin host; expected initial failures are missing celestial/atmosphere behavior. Define absolute and relative LUT tolerances, maximum invalid samples and fixed camera/exposure settings from the reference. Never approve a shader port solely because its sky is blue.
- [ ] Port algorithm/data layout to WGSL, preserving provenance. Schedule transmittance, scattering and irradiance precomputation using public compute/render passes and negotiated texture formats. Assemble runtime sky/aerial-perspective passes with core depth reconstruction and color rules. Validate dependencies transactionally and release candidate LUTs if attach fails.

```text
parameters/profile hash -> existing LUT cache or scoped precomputation
complete valid LUT set -> publish atmosphere service and graph passes
frame -> reconstruct world ray/depth -> evaluate scattering -> linear HDR composite
parameter/profile change -> build new set -> swap after completion -> retire old set
```

- [ ] Verify the plugin imports only `zyren` public libraries. Exercise unsupported storage/float formats, cancelled precomputation, extreme validated parameters, resize and device recovery. Choose explicitly documented quality profiles with independently measured errors, or reject unsupported features.
- [ ] Compare LUT samples and rendered horizon/day/night fixtures on qualified GPUs, update the source parity matrix and commit `feat: port atmospheric scattering as a core API plugin`.

## Task 4: Volumetric clouds, weather and temporal history

**Files:** Create plugin `clouds/{clouds_plugin,cloud_layers,weather_source,quality}.dart`,
WGSL cloud/shape/shadow/resolve modules, `test/clouds_test.dart` and fixtures.
Extend planet controls and GPU comparisons.

**Interfaces:** `CloudsPlugin` declares its atmosphere dependency and typed GPU
requirements. `CloudLayers` contains validated density/altitude/wind parameters;
`WeatherSource` supplies versioned data plus timestamps and cancellation.
`CloudQuality` declares sample count, resolution/history/shadow settings and
estimated resource use. Persistent resources use core `HistoryTexture` per view.

- [ ] Read supplied cloud layers, local weather, shape, shadow and resolve algorithms; retain asset provenance. Create deterministic seeded weather/shape textures and camera sequences. Test reference layer ordering, empty cloud volume, density limits, camera cuts and moving origins:

```text
zero density -> output equals atmosphere-only frame within tolerance
camera cut / origin shift / resize -> no reuse of the previous history generation
weather request replaced -> stale weather cannot overwrite the latest version
two views -> independent cloud history, shared immutable weather where valid
```

- [ ] Run cloud CPU tests and native GPU fixtures through public graph APIs; missing ray marching/temporal invalidation must fail. Capture reference transmittance, cloud-shadow positions and edge motion to quantify ghosting across the fixed sequence.
- [ ] Port shape/detail sampling, bounded ray marching, weather mapping, shadows and temporal resolve to WGSL. Reconstruct rays with the core depth convention. Declare sample/read/write dependencies and invalidate all affected history on cuts, source versions, quality/projection changes and device recovery.

```text
weather/shape generation -> cloud shadow pass -> volume integration
current radiance/depth/motion -> history rejection -> temporal resolve
resolved cloud + atmosphere -> core HDR effects -> output
budget/profile change -> validate new resources before swapping quality
```

- [ ] Run mobile profiles with explicit GPU-time and residency targets per fixture. An automatic quality adjustment reports the selected profile, uses hysteresis and never silently changes unsupported shader semantics. Keep live weather credentials in host adapters; offline deterministic fixtures remain the default example.
- [ ] Compare with reference samples/images and run lifecycle/history tests; commit `feat: port volumetric clouds through public shader contracts`.

## Task 5: Platform, performance and failure qualification

**Files:** Extend `.github/workflows/checks.yml`, create
`tool/qualification/{run.dart,device_manifest.schema.json}`,
`benchmarks/results` and `docs/verification/{matrix,release-checks}.md`.
Use the integration tests from all earlier plans rather than duplicate test logic.

**Interfaces:** A qualification record contains commit, SDK/toolchain versions,
OS/device/architecture/driver, renderer, presentation path, named test outcomes,
timestamp and artifact paths. Outcomes are `passed`, `failed`, `unverified` or
`unsupported`; unavailable hardware cannot become `passed`. The schema separates
build, native runtime, shared presentation, capability fixtures and performance.

- [ ] Add schema/runner tests that reject missing commit/device identity, impossible pass claims and a GPU-required suite reported successful after skipping all rendering cases:

```json
{
  "platform": "android",
  "build": "passed",
  "nativeRuntime": "unverified",
  "sharedPresentation": "unverified",
  "reason": "No physical Android GPU was available for this run"
}
```

This is an outcome fragment, not a complete qualification record; the runner
adds the required environment and artifact fields.

- [ ] Run `fvm dart test tool/qualification/test/record_test.dart` from the workspace after adding the root test dependency; malformed evidence must initially fail validation. Configure separate CPU/build jobs and GPU runtime jobs. Default hosted runners without guaranteed GPU access cannot qualify native rendering.
- [ ] Implement reproducible suites for math/assets, ABI/native validation, widget lifecycle, real GPU fixtures and standalone release launch. Cover physical iOS, Android Adreno/Mali, macOS and Windows integrated/discrete adapters. Include lowest declared SDK/OS targets, ARM64/x64 packaging where claimed and the available Linux experimental path.

```text
discover environment -> record exact configuration -> execute named checks
collect exit codes/screenshots/traces/counters -> validate record -> write artifact
missing device/capability -> unverified/unsupported with reason, never synthetic pass
```

- [ ] Run background/resume, resize, hot restart, engine detach, two views, device-loss injection, asset failure/cancel/retry and 100 route cycles. Benchmark at least 300 frames after warm-up using fixed workloads; record percentile times, residency, upload/readback bytes and device power/thermal state when available. Define budgets per device/profile before judging results.
- [ ] Keep existing macOS release linkage and visible/inactive regressions in this suite. Record unavailable hardware as a release blocker for that support claim while continuing available checks. Commit `test: qualify native engine platforms and workloads`.

## Task 6: Documentation, packaging and DX release gates

**Files:** Update root/package READMEs, API docs and changelogs; add
`docs/examples`, `docs/compatibility.md`, `tool/check_api_examples.dart` and
`tool/release_manifest.dart`. Modify native hook/distribution only with its
packaging tests. Preserve `THIRD_PARTY_NOTICES.md` and asset license metadata.

**Interfaces:** Documentation examples import the shipped API; the checker
extracts/tests complete examples and fails on unknown/private symbols. Public
packages declare tested compatibility ranges. A native artifact manifest records
target triple, ABI version, source commit, toolchain, digest and provenance.
New package names need registry availability checks before publication.

- [ ] Add a clean-consumer fixture outside the workspace that resolves the built packages, creates a managed mesh view, loads a bundled glTF and installs an external effect plugin. It must not inherit workspace path overrides or private imports. Build/run a release application and check its native runtime token once packaged.

```text
new consumer -> declared dependencies -> standard Flutter platform setup -> run
one facade import for basic scene; optional imports only for glTF/geospatial
no manual native linkage or app-specific generated FFI edits
dispose managed route -> no retained view resources or unsettled load tasks
```

- [ ] Run docs analyzer, clean-consumer tests and native package dry-runs; missing exports or bundled native artifacts must fail. Verify errors link labels to application resources and docs explain units, ownership, nullability, cancellation and actual capability limits.
- [ ] Write guides for the eight DX workflows in the program plan, API migration, custom shader/plugins, source resolvers, headless capture and release setup. Add complete dependency/error examples, supported glTF extension names and separate parity/platform matrices. Keep API examples synchronized by extracting runnable source, not maintaining fake declarations.
- [ ] Retain build-hook compilation until prebuilt artifacts have reproducible provenance and target coverage. If introducing prebuilts, validate checksums before use, preserve ABI checks, test offline cache behavior and provide a documented source-build path. Verify one Rust runtime is bundled per process and release stripping/linkage remains correct.
- [ ] Run package publication dry-runs and the full qualification suite for claimed features/platforms. Record release blockers, license notices and actual performance results. Commit `docs: publish native engine API and release qualification guides`. Publishing packages, pushing or merging remains a separate explicitly requested action.

## Exit gate and remaining breadth

The supplied reference parity claim requires a row for each exported capability,
its native implementation, reference fixture and qualified platform result.
React-specific wrappers become Flutter APIs; that is a documented API adaptation,
not JavaScript compatibility. External 3D Tiles and additional asset/material
extensions have separate scopes and must not be implied by the completed rows.

The core remains useful when geospatial is absent. A release requires the normal
model viewer and external shader consumer to pass alongside the planet example.
Do not label the entire Three.js breadth complete while its capability backlog
still contains unimplemented or unqualified items.
