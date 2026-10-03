# Native professional ocean

Date: 2026-10-03. Requirements follow the approved geospatial architecture and
the explicit request for professional water, realistic effects, buoyancy and LOD.
Status: implementation specification. Nothing here is runtime evidence.

Read the [platform design](design.md) and [reference audit](water-reference-audit.md)
with this specification. The first domain package is `zyren_geospatial_ocean`.
Its independently installable physics bridge is `zyren_geospatial_ocean_physics`.
Both are required deliverables, but an application that only renders water need
not load native physics.

## Acceptance target

You can travel from orbit to a coastline, down to a floating vessel and through
the waterline. The water keeps continuous coverage, stable wave phase and useful
detail at each scale. Native buoyancy follows the same sea state, including while
the water layer is hidden or a second camera changes visual quality.

The required surface model is a spectral ocean with native compute transforms,
horizontal displacement and derivative outputs. An analytical reference mode is
useful for tests and constrained applications; it is named separately and does
not satisfy the spectral-water acceptance gate.

Required visuals include sky/sun reflections, nearby scene reflections,
depth-aware refraction, wavelength-dependent absorption, in-scattering, whitecaps,
shore/contact foam, persistent wake/ripple effects, bounded spray, underwater
absorption and scattering, caustics, suspended particles and waterline transitions.
The selected profile reports which effects are active.

The implementation remains a real-time surface/volume approximation. It does not
claim a validated naval hydrodynamics solver, general fluid simulation, complete
multiple scattering or naturally overturning surf. Those models can be added as
extensions with their own data, accuracy and resource requirements.

## Sea state and samples

`OceanSeaState` fixes a seed, versioned spectrum, physical wave bands, wind/swell,
gravity, water density and mean level. Heights use the declared vertical datum.
The initial spectral family is a directional Phillips model with finite-depth
dispersion where a depth is supplied. Fetch-limited JONSWAP/TMA models can be
registered later; no unused fetch control is exposed initially.

Canonical spectral coefficients are immutable for a sea-state revision and keyed
by band and integer frequency. Render resolution selects a subset of those same
coefficients. It must not reseed phases or double-count energy in overlapping
bands. Normalization and FFT sign conventions are part of the saved model version.

Produce displacement, derivatives, surface velocity and the horizontal Jacobian.
Finite-difference tests validate derivatives. Zero wind/energy, zero frequency,
long elapsed time and nonfinite input need explicit numerical treatment.
Whitecap emission uses compression with bounded persistence and decay.

`OceanSample` contains position/height, normal, water velocity, sea-state revision,
requested and evaluated time, spatial frame, coverage and error metadata. Queries
are batched and bounded. Choppy horizontal displacement requires inversion from
world position to the parameterized surface; failed convergence is observable.

Exact reference sampling evaluates the canonical field for small fixtures. Runtime
sampling supports a bounded CPU spectral reconstruction and timestamped native
GPU batches. CPU reconstruction has its own grid/work budget. Physics admits only
samples within its configured age and error limits; rejected batches cannot be
relabeled as current or replaced silently by flat water. The driver can await an
exact tick sample or apply the configured pause/approximation policy.

Simulation uses a shared fixed tick and epoch. Rendering interpolates completed
states. Pause, time scaling, checkpoints, replay and reset change all wave and
effect histories consistently. Camera movement never advances simulation time.

## Globe coverage and LOD

Use an ellipsoid-conforming coarse mesh for distant coverage and adaptive surface
patches for local displacement. Water height uses the same datum as terrain and
buoyancy. There is no arbitrary planetary radius lift to hide depth conflicts.

Start with six cube-face quadtrees projected onto the ellipsoid. Their neighbours
have explicit edge mappings, including cube corners. Select visible nodes using
screen error with hysteresis, a patch budget and a horizon test. Adjacent leaves
differ by at most one level; edge morphing/stitching preserves crack-free coverage.
Bounds include the maximum displacement and update when the sea state changes.

Mesh refinement depends on the view. Wave coordinates do not. Use fixed,
overlapping world-anchored wave charts with deterministic blend weights. Samples,
normals and velocity include the blend derivatives. Only required charts are
resident, chosen from both visible patches and physics-query regions. Wave charts
are independent of quadtree split decisions and viewport origin changes.

Transition high frequencies from geometry to filtered normals as projected mesh
spacing grows. Preserve unresolved slope energy in roughness at orbital scales.
Reject unsupported sea states whose displacement invalidates selected bounds or
fold-over limits. Test poles, dateline, chart edges, cube corners and long travel
without resetting phase or moving the ocean relative to the world.

Earth mode needs licensed, versioned land/water coverage. Bathymetry improves shore
behaviour and underwater path lengths. Missing data has a visible status, with
nearshore effects restricted to known coverage. The all-water mode is a separate
explicit configuration. Ocean masks and regional data use the shared offline store.

## Native optics and underwater composition

Reuse existing transmission capture and native render scopes. Add generic custom
mesh scene-input support if needed, including current-frame HDR colour and depth,
viewport, origin and depth convention. Give it a non-water native regression test.
MSAA resolution, reversed depth, transparent geometry and multiple views must have
defined behavior before the water shader consumes those inputs.

The water material computes Fresnel reflection/transmission, filtered surface
normals, sun glint, environmental radiance and absorption/scattering over a bounded
water segment. Foreground depth rejects refraction samples from objects above the
surface. Atmospheric attenuation and tone mapping each occur once.

Near reflections use bounded screen-space tracing with confidence. Missing
off-screen content blends to the environment explicitly. A local planar capture
is an optional high-quality reflection mode with its own size, refresh, clip-plane
and curvature limits. It needs a generic native secondary-view lease; no browser
rendering or CPU image readback belongs in the reflection loop.

Underwater integration clips rays to the water surface, terrain or configured
volume. Include the refracted sky opening and total internal reflection, with
waterline hysteresis to prevent frame-to-frame flicker. Caustics and shafts use
the same sun direction, water attenuation and shadow availability. The first
caustic model is a bounded projected approximation, identified in diagnostics.

Interaction emitters inject timestamped events into bounded local wake/ripple
fields. Track water-relative velocity, radius and energy. Fields advect and decay,
reject unstable time steps and retain stable world coordinates. Couple their
displacement into queries only when sampling can meet the selected physics policy.
Foam and spray consume the same interaction events; spray uses `zyren_particles`
through an optional adapter. Required integration is verified in the ocean lab.

## Physical buoyancy

The base ocean package provides water queries and a CPU force solver. The physics
bridge applies resulting forces/torques to native dynamic bodies through
`zyren_physics`. It never overwrites a simulated body's displayed transform.

Ship two declared models:

- Spherical pontoons with submerged spherical-cap volume. Multiple probes yield
  distributed forces, roll/pitch response and water entry/exit events. You configure
  probe volumes and validate overlap instead of counting the same hull volume twice.
- Closed convex hull proxies decomposed into non-overlapping tetrahedra. Clip
  each cell against its sampled local water plane, integrate submerged volume and
  centroid, and sum force/torque. This is a discretized hydrostatic approximation;
  cell size, surface curvature and sampling error are reported.

Buoyant force opposes the configured gravity vector with magnitude determined by
water density and displaced volume. It is not applied along the wave normal.
Hydrodynamic drag uses velocity relative to water at each sample point, including
angular body velocity. Support bounded linear/quadratic drag and angular damping,
with limits that do not reverse relative velocity within one admitted step.

Apply additive per-tick impulses or a scoped force accumulator that preserves
other force contributors. Validate the whole command batch before applying it.
The shared simulation owner advances physics once. Do not install another world
or clock inside the water plugin. Gravity changes and local-frame rebases must
transform body poses, linear/angular velocities and pending forces consistently.

Tests cover dry, partial and full submersion, asymmetric load, righting torque,
sinking when total displacement cannot support mass, currents, drag dissipation,
sleep/wake, moving frames, detach and two actors with independent configurations.
Convergence is checked at 30, 60 and 120 simulation Hz; a separate render-cadence
test holds simulation Hz fixed while rendering at 30, 60, 120 and 144 Hz.

## Quality controls

Keep four controls independent: physical sea state, mesh LOD, optical quality and
query/physics quality. Changing a visual preset cannot alter mean sea level,
water density, the canonical sea state or simulation tick rate.

These are starting resource limits for qualification, not measured device presets.
FFT sizes are per rendered wave chart and band. Allocation admission includes
all active charts, views, history and replacement resources, and may reject a
profile before publishing it.

| Render preset | FFT grid per rendered band | Max bands | Visible patches / max vertices | Scene-input scale / SSR steps | Shafts / spray particle cap | Water GPU payload budget |
| --- | --- | --- | --- | --- | --- | --- |
| Low | 64 x 64 | 2 | 96 / 65,536 | 0.5 / disabled | disabled / 0 | 32 MiB |
| Medium | 128 x 128 | 3 | 192 / 131,072 | 0.5 / 16 | 12 / 2,048 | 64 MiB |
| High | 256 x 256 | 4 | 384 / 262,144 | 0.75 / 32 | 24 / 8,192 | 128 MiB |
| Ultra | 512 x 512 | 4 | 768 / 524,288 | 1.0 / 64 | 48 / 32,768 | 256 MiB |

These limits do not include the rest of the scene or physical driver residency.
Screen targets also have explicit pixel and dimension caps. Ultra cannot be
selected when the canonical sea state lacks its requested frequency resolution.
Profile selection returns effective settings, required features, estimated bytes
and any rejected limits. It must never display Ultra while silently running Low.

Adaptive quality is opt-in, uses measured frame budgets, and has hysteresis and
a minimum dwell interval. It adjusts visual settings within the host's declared
range. It preserves wave coefficients, queries and physical bodies. Candidate
resources publish atomically; failures preserve the previous profile.

Initial measurement targets are 60 fps at 1920 x 1080 for desktop High and
30 fps at 1280 x 720 for mobile Medium in the specified lab scene. Measure water
incremental cost and whole-scene cost separately. Hardware qualification decides
which profiles can be recommended; these targets do not claim current performance.

## Delivery evidence

The native lab includes calm open water, storm swells, shallow coast, floating
vessels/debris, a submerged view and a continuous orbit-to-surface camera route.
Use owned procedural test geometry and data first. A global Earth coast demo
requires a separately documented dataset and offline redistribution rights.

Save fixed-time captures, motion sequences, numerical query comparisons, LOD
wireframes, effect contribution views and timing/resource records. Test macOS
Metal, Android Vulkan and iOS Metal where devices are available. DX12 remains
unqualified until a Windows device run exists. A shader compile is not device
qualification.

Professional water completion requires the spectral model, globe LOD, native
optics, interactions, physical buoyancy, effective quality controls, examples,
documentation and actual evidence. Record any missing provider data, device run
or visual acceptance item without marking the package complete.
