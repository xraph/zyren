# Navigation, renderer and atmosphere

This executes the requested items 1 through 3 in the primary checkout on `main`.
The contracts in `docs/parity/controls.md`, `docs/design/native-3d-api.md` and
plans 03 and 04 remain the authority. The upstream snapshot stays read only.

## Global constraints

- Keep native Metal, Vulkan and DX12 rendering and public plugin boundaries.
- Preserve concurrent workbench edits. Commit checked changes in focused groups.
- Reuse committed renderer work from `dart-core-api` when integration is safe.
  Do not copy that checkout's uncommitted render graph work.
- Keep terrain streaming and clouds outside these three items. Terrain controls
  accept a surface query so they can work with terrain supplied later.
- Record numerical reference evidence separately from device evidence. Passing
  a build or a CPU test does not establish a rendered atmosphere.

## Task 1: Camera transitions

Port the perspective/orthographic transition manager to the general core.
Preserve the fixed point, camera synchronization, duration, reversal and event
ordering from 3d-tiles-renderer 0.4.24. Validate invalid time and disposed use.

- [ ] Generate deterministic upstream fixtures for both directions, interruption,
  positional zoom, off-axis targets and rotated camera bases.
- [ ] Run reference and lifecycle tests red, implement, then run them green.
- [ ] Run core analysis and the complete core test suite; commit the result.

Expected: reference camera poses and projection parameters agree within declared
double precision tolerances, and listeners see one ordered transition lifecycle.

## Task 2: Environment and globe navigation

Implement surface dragging, pivot rotation, wheel/pinch zoom, height clearance,
touch gesture arbitration, inertia and globe near/far management. Wire a plugin
through the public input and camera interfaces. Keep existing orbit APIs intact.

- [ ] Add upstream replay fixtures before implementation.
- [ ] Cover 30/60/120 Hz, modifiers, cancellation, resize, Y/Z up, horizon misses,
  transformed ellipsoids, touch transitions and disposal.
- [ ] Exercise native navigation and selection together in Planet.
- [ ] Run affected core, geospatial, host and native integration checks; commit.

Expected: recorded input produces matching camera trajectories and terrain
clearance without losing surface taps or leaving frame demand active after idle.

## Task 3: Integrate committed renderer foundations

Inspect the pinned core checkpoint, renamed packages and picking contracts.
Integrate checked resources, texture decoding/mips, transparency, material sides,
glTF and WGSL support. Resolve mutable geometry BVH and sidedness implications.

- [ ] Inspect committed scope and concurrent changes before integration.
- [ ] Add failing regressions for integration conflicts, then resolve them.
- [ ] Run core/native suites, analysis, boundaries and native model fixtures.

Expected: the new renderer capabilities work through Zyren public imports while
existing picking, workbench and presentation contracts remain intact.

## Task 4: Render graphs, compute and extended textures

Complete plan 03 task 4, using committed graph work when available. Add explicit
float and 3D texture capabilities needed by atmosphere. Validate graph hazards,
transactional replacement, shader diagnostics and scope/fence retirement.

- [ ] Run descriptor and graph validation tests red before filling gaps.
- [ ] Run a real GPU compute-to-render fixture and a public ShaderMaterial.
- [ ] Verify malformed graphs, unsupported formats, cancellation and disposal.
- [ ] Run affected suites and native resource counts; commit.

Expected: a plugin computes into a texture and renders it without private native
imports, ordinary CPU readback or a partially published failed graph.

## Task 5: HDR, PBR, lights, shadows and instancing

Complete the requested capabilities from plan 03 tasks 5, 6 and 8. Use linear
HDR intermediates, one output tone mapping stage, standard metal/rough shading,
punctual lights, bounded shadow maps and instances with stable picking identity.

- [ ] Add numerical and rendered fixtures for each capability before changes.
- [ ] Verify alpha/depth ordering, mirrored transforms, roughness/metalness,
  normals, emissive/occlusion, light and shadow behavior and instance picking.
- [ ] Exercise public consumers on available native backends; commit stages.

Expected: deterministic render fixtures show the intended physical/material
behavior, with explicit capability failures and resource cleanup.

## Task 6: Atmospheric scattering and celestial scene

Complete plan 04 task 3 through public core APIs. Port parameters, celestial time
and directions, scattering tables, sky, sun, moon, stars and aerial perspective.

- [ ] Pin astronomical and atmospheric reference fixtures and tolerances.
- [ ] Test zero density/path, finite radiance, bounded transmittance and UTC.
- [ ] Implement transactional LUT caching, compute and sky/haze rendering.
- [ ] Compare LUT samples and day/night/horizon/space render fixtures.
- [ ] Verify parameter changes, resize, cancellation and disposal; commit.

Expected: the atmosphere is a usable optional plugin with numerical and rendered
evidence, rather than a sky-color approximation or a declared API without work.

## Task 7: Qualification and review

- [ ] Run full affected Dart/Rust suites, analysis and package boundaries.
- [ ] Exercise Planet navigation and atmosphere on macOS Metal, Pixel Vulkan
  and iPhone Metal where available, recording readbacks and cleanup counts.
- [ ] Update feature/platform evidence without implying untested DX12 support.
- [ ] Obtain one fresh review of the full change set, repair material findings
  with regressions and commit the verified result.

Expected: the requested three items have evidence and documented limits. Any
remaining requirement stays visible in the execution ledger and parity matrix.
