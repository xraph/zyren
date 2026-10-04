# Zyren geospatial ocean

You can define a deterministic sea state and inspect its numerical surface with
this optional package. You can also evaluate native FFT fields and build a stitched
ellipsoid mesh with native morph targets. Batched physical queries return world-space
water positions, normals and fluid velocities. Native water materials add filtered
displacement, optics, environment lighting and current-depth reflections. Read the
[surface-rendering guide](doc/surface-rendering.md) for API usage and limits.
You can compose [underwater transport](doc/underwater.md),
[foam and wakes](doc/interactions.md), [buoyancy](doc/buoyancy.md) and
[quality transitions](doc/quality.md). The [extension guide](doc/extension.md)
registers these services and visual layers with the geospatial host.

The [Ocean Lab](../../examples/planet/OCEAN.md) provides six saved native
scenes and an owned offline coast fixture. Professional visual acceptance,
performance targets and real Earth coverage remain open; read its
[qualification record](../../qualification/2026-10-04/ocean-lab.md).

```dart
final state = OceanSeaState(
  seed: 42,
  canonicalResolution: 256,
  bands: [
    OceanWaveBand(
      patchMetres: 512,
      minWaveNumber: 0,
      maxWaveNumber: 1.5,
      windSpeed: 12,
      windHeadingRadians: 0,
      amplitude: .02,
    ),
  ],
);
final waves = OceanSpectrum(state);
final coefficients = waves.evolve(0, 2.5);
final saved = state.toJson();
final restored = OceanSeaState.fromJson(saved);
```

Keep `OceanSpectrum` when you evaluate more than once. It owns immutable seeded
coefficients and dispersion frequencies. The convenience `evolveSpectrum` function
constructs those again. You can round-trip a state through JSON; decoding requires
the exact spectrum ID and version in `OceanSpectrumRegistry`. Custom models must
be deterministic and stateless. Change their registered version when you change
an equation or constant.

## Numerical convention

Arrays interleave real and imaginary Float64 values in row-major z/x order.
Wrapped centered frequencies run `[0, 1, ..., N/2-1, -N/2, ..., -1]`. DC occupies
index zero. Inverse transforms use the positive complex exponential and normalize
once by `1/N²`. Seeded coefficients include `N²`; selecting a smaller visual grid
will require rescaling by its squared size to preserve physical amplitudes.

The directional Phillips model uses wind length `V²/g`, squared wind alignment,
short-wave damping at `0.001` times wind length and a `0.07` counter-wind factor.
Amplitude scales density, which is integrated over `dkx * dkz`. These constants
belong to Phillips version 1. Heights follow the model developed in
[Tessendorf's course notes](https://people.computing.clemson.edu/~jtessen/reports/papers_files/coursenotes2004.pdf).

Time evolution uses `h0(k) exp(-iωt) + conjugate(h0(-k)) exp(iωt)` so the wind
heading points toward dominant wave travel, from +x toward +z. A supplied depth
uses `ω² = gk tanh(kd)`; otherwise dispersion is deep-water. Phases reduce time
modulo each frequency's period before evaluation. Accepted times span ±1e12
seconds from the epoch, though Float64 time resolution still limits very long
runs. DC and both Nyquist axes are zero. This keeps spectral derivatives real.

Bands have raised-sine frequency windows. At each wave number their weights are
divided by `max(1, sum(weights))`, so overlapping bands do not allocate more than
one unit of window weight. The canonical grid still bounds represented frequency;
a requested window does not add frequencies beyond that grid.

The seed algorithm is SplitMix64 with exact unsigned 64-bit modular arithmetic.
Mix the uint32 seed and the packed tuple `(band+1)<<32 | (nx+32768)<<16 |
(nz+32768)` separately, XOR them, then mix again. A second mix supplies the other
Box-Muller uniform. Uniforms use `(top52bits + 0.5) / 2^52`. Gaussian draws happen
on the CPU; the GPU will receive these coefficients without another random seed.
The descriptor revision is an FNV-1a fingerprint, not a cryptographic integrity key.

## Reference checks

`inverseDft2` is an independent O(N⁴) oracle limited to grids of at most 32.
`OceanSpectrum.reference(x, z, seconds)` reconstructs small fixtures with at most
4096 coefficients by default. It returns height, choppy displacement, spatial
derivatives and water velocity. Coordinates describe the undisplaced material
surface; this function does not solve the inverse displacement query for buoyancy.

The macOS numerical checks cover transform sign and normalization, Hermitian
pairs, reproducible coefficients, finite-depth limits, long elapsed time,
overlapping bands and finite-difference derivatives. The 8 x 8 fixture with seed
42 has little-endian Float64 coefficient SHA-256
`80c7073b2f58831998d2d2b0e69cd1cddab32589e5b3e9d0faabfec4108d36fe`.
An independent Python calculation reproduced that hash. Native checks are described below.
Physical buoyancy and cross-platform qualification are still pending.

## Native wave fields

Create `OceanWaveFieldGpu` from a plugin's `GpuScope`, then call
`evaluate(seconds, resolution: size)`. You receive one set of displacement,
derivative and velocity textures per band, plus evaluated time, sea-state revision,
logical payload bytes and unresolved slope variance. Texture heights are offsets;
add the snapshot's mean level once after combining bands.

The native path uses radix-2 Stockham passes over rows and columns. Six packed
complex transforms carry eleven real fields. Displacement is `(dx, h, dz, J)`,
derivatives are `(dh/dx, dh/dz, dDx/dx, dDz/dz)`, and velocity is
`(vx, vy, vz, dDx/dz)`. Cross derivatives are symmetric for this potential field.
When you combine bands, compute the horizontal Jacobian from summed derivatives;
summing the individual determinants would be incorrect.

The three RGBA32Float textures are unfiltered. Sample them with texture loads and
explicit interpolation. `debugRead` and `debugInverse` perform native readback for
numerical checks; they are not render-loop operations. Render grids select and
rescale canonical coefficients without reseeding. Removed frequencies contribute
to the reported time-average unresolved slope variance.

CPU phase anchors use power-of-two time intervals chosen to keep the GPU phase
increment below 32 radians. The native shader evolves between anchors. This avoids
converting a large absolute timestamp to Float32, though the original Float64
clock still sets the precision limit. Models with coefficient amplitudes above
one million metres per frequency are rejected before native publication.

Await each evaluation. Concurrent requests are rejected, and cancellation or a
failed allocation preserves the last completed output. Two output slots protect
the active textures during evaluation. A snapshot is current until the next
successful publication or close; retaining its texture does not freeze subsequent
slot reuse. Check `isCurrent` when consuming a query result. Cleanup failures after
publication appear in `lastRetirementFailure` and are also reported when closing
the GPU scope.

Admission counts all owned buffer and texture payloads, including two output slots
and the previous grid during replacement. One band requires
`208 * N² + 16 * (2 * log2(N) + 1)` bytes. Driver overhead and physical GPU residency
are not included. A replacement can exceed the allowance even when its final grid
would fit alone. It fails explicitly and keeps the previous field.

Native macOS checks now cover complex FFT agreement, packed derivatives, long-time
phases, zero wind, overlapping bands, cancellation and failed allocation. A one-band
64/128/256/512 sweep completed with finite output and zero owned allocations after
close. Those compute results do not establish water optics, buoyancy or visual quality.


## Globe surface and wave charts

Use `OceanSurfaceSelector` with a camera, viewport and explicit patch/vertex limits.
It keeps a complete six-face ellipsoid cover and returns the visible subset. Root
coverage survives budget exhaustion. Check `budgetLimited` and
`maximumScreenError`: the requested error is a target, not a guaranteed result.
The error estimate covers curvature and coarse-edge stitching in physical pixels;
perspective projection uses the distance to the conservative patch sphere, so
this is a selection estimate, not a strict screen-space bound. Wave interpolation
has a separate error budget. Supply a conservative displacement
bound for culling. Bounds at or above a tenth of the minimum body radius fail.

`OceanSurfaceGeometry` builds native buffers with double-precision patch origins
and Float32 local vertices. Its fine edges follow coarse triangle chords. You can
inspect the same piecewise-linear surface with `sample` or `sampleCube`.
`OceanSurfaceMorph` holds the common refinement of both endpoint covers. Create
meshes from its patches, place them at each patch origin, and set their sole morph
weight together from zero to one. Only replace the transition geometry after it
reaches one. Coarsening follows the same rule. The transition has its own vertex
admission and a hard limit of 4096 patches; a rejected candidate leaves ownership
of your current mesh unchanged.

Grids use 4..64 power-of-two segments and neighbours differ by at most one level.
Accepted ellipsoids have radii from 1 mm to 1e12 metres and an aspect ratio at most
100. Coverage checks certify the mesh, not coastline or geographic data coverage.

`OceanWaveCharts` supplies fixed ECEF metre coordinates, normalized smooth weights
and tangent derivatives for six charts. Its blend includes derivatives of the
weights, including at cube seams and poles. Pass a point on the declared ellipsoid.
Seeds derive from the physical seed and stable chart ID using the version 1 uint32
mapping; neither camera selection nor rebasing enters the calculation.
`OceanChartResidency` combines visible requests with explicit physics leases and
rejects over-budget changes atomically. Leases keep charts resident off camera.
This is residency admission; GPU chart allocation is wired by the later controller.

The native macOS route exercises an undistorted globe from 100 m to 20000 km
altitude, with mixed refinement/coarsening and Float32 mesh inspection. Use
altitude-aware camera clipping to retain depth precision. Water displacement,
optics and professional visual acceptance remain open.
See [surface evidence](../../qualification/2026-10-03/ocean-surface.md).

## Physical query building blocks

`OceanCanonicalField` prepares every active canonical mode at a specified time.
Its direct reconstruction matches the independent reference at arbitrary metre
coordinates. No display-grid interpolation or frequency truncation is involved.
The snapshot includes spectral amplitude, gradient and Hessian envelopes. These
are field bounds. The world sampler propagates them through blending and inversion.

Use `OceanCanonicalWorker` to move seeding and reconstruction into a persistent
isolate. It caches fixed charts and timestamps, admits a bounded number of batches,
and rejects work that exceeds its mode or memory allowance. Cancellation retains
admission until accepted work drains. A deadline terminates the worker, then
releases admission after its exit notification. Close drains accepted work.
Snapshots returned by `prepare` belong to you, so account for their retention in
your own budget. Worker diagnostics report logical work payload, including the
replacement reserve, rather than physical process memory.

`blendOceanSurface` computes the ellipsoid material surface, its tangent derivatives
and fluid velocity. `invertOceanHorizontal` supplies a bounded damped Newton solve
with explicit folded, singular and nonconvergent results. A successful local solve
does not prove global uniqueness. The world sampler below adds an admitted tangent
domain, numerical error estimates and coverage, time and frame checks.


`OceanCanonicalGpu` evaluates sparse canonical samples in native compute workgroups.
Pass a prepared snapshot and bounded coordinate pairs. You receive immutable CPU
readback values, their timestamp and revision, and numerical envelopes for height,
displacement, slopes, displacement derivatives and fluid velocity. Changing a
visual FFT grid never enters this path.

The native sampler reuses admitted buffers. Larger candidates count both old and
new allocations before replacement; failed allocation leaves the previous buffers
usable. Calls are exclusive, cancellation fences delivery, and close drains accepted
work. Numeric envelopes account for coefficient and phase quantization, accumulation
and the [WGSL floating-point accuracy rules](https://www.w3.org/TR/WGSL/#floating-point-accuracy).
They can be wider than the error observed on one device. The world sampler propagates
them through blending and inverse conditioning before a physical sample can pass
your accuracy policy.


## World-space physical sampling

Create `OceanSamplerCpu` for persistent worker reconstruction, or
`OceanSamplerGpu` with an owned `GpuScope` for native sparse evaluation. Both own
an immutable canonical sea state. Neither reads the visual FFT grid.

```dart
final sampler = await OceanSamplerCpu.create(
  state: state,
  frame: worldFrame,
  now: () => simulationClock.instant,
  coverage: const OceanAllWaterCoverage(),
);
final samples = await sampler.sampleBatch(
  [OceanQuery(positionEcef, simulationClock.instant)],
  OceanQueryPolicy(),
);
final sample = samples.single;
if (sample.available) {
  final heightMetres = sample.height!;
  final normalEcef = sample.value!.normalEcef;
  final fluidVelocityEcef = sample.value!.velocityEcef;
}
await sampler.close();
```

Supply explicit coverage. `OceanAllWaterCoverage` describes a procedural water
body; it does not establish where Earth's oceans or coastlines lie. A geographic
`GeoFieldSource<bool>` can instead reject land or unavailable data. Each query
checks its normal footpoint and the recovered material location. Access is checked
again after physical work drains. Providers must report availability truthfully,
return the requested timestamp, and change their revision when coverage changes.
Providers own their transport deadlines and must settle accepted requests so that
sampler close can drain them.

Results stay in input order. Failure has a typed reason and null physical values.
A successful result includes requested/evaluated time, sea-state and coverage
revisions, frame identity/revision, body-fixed and local vectors, residual, age,
and numerical height, normal and velocity estimates. Height is measured along the
query footpoint's ellipsoid normal. The recovered material coordinate is separate
from the displaced surface position. Returned values are immutable snapshots;
consumers must compare their provenance with the current world before retaining
and reusing them in a later step.

The default policy admits 256 points, eight distinct ticks, twelve Newton
iterations and 33,554,432 canonical mode evaluations. It requires zero simulation
age, at most 1 cm estimated height error, 0.5 degree normal error and 0.1 m/s fluid
velocity error. Exact-tick reads have zero simulation age even when computation
takes wall-clock time. Clock generation changes, rebases, changed or removed
coverage, cancellation and close invalidate delivery. Calls are exclusive. Close
stops admission immediately and retains accepted worker/GPU reservations until
work drains.

Physical evaluation includes every canonical mode. There is no display truncation
or grid-interpolation error. The worker returns small envelopes without copying
six full mode packets to the main isolate. Native calls cache packets separately,
and simultaneous Newton evaluations share chart batches. `OceanSamplerLimits`
bounds samples, modes, worker payload, host payload, native payload and worker
operation time. Host admission reserves retained packets, a transfer, upload
scratch and bounded sample geometry. Reported bytes exclude object/driver overhead
and do not claim physical GPU residency.

Strict admission uses a conservative contraction bound over a tangent disk, followed
by a residual/error disk wholly inside it. This establishes a unique local root
under the stated numerical model, not uniqueness around the planet. Rough states
can fail `accuracy` even where a particular local solve would converge. A portable
GPU error estimate can also reject a tight policy despite smaller observed device
error. Choose the CPU sampler explicitly when that fits your workload; we never
change wave amplitudes, choppiness or visual quality to force a pass.

The CPU estimates assume Float64 arithmetic and trigonometric error within four
ulps. Native estimates use WGSL's bounded trigonometric domain. Coefficient
rounding, phase reduction, vector error, surface conditioning and ellipsoid
calculation allowances are included. These are qualified numerical-model estimates,
not a formal proof of every platform's math library or an error bound against real
water. The Phillips model has separate physical limitations. See
[query evidence](../../qualification/2026-10-03/ocean-queries.md) for fixture scope,
observed differences and unrun devices. The [buoyancy solver](doc/buoyancy.md)
uses these samples for displaced volume, righting torque and bounded drag.
The optional [physics bridge](../zyren_geospatial_ocean_physics/README.md) applies
these loads to an existing native world on its shared simulation tick.

## Underwater and projected light

The [underwater API](doc/underwater.md) clips water transport against the displaced
surface, scene depth and optional convex bounds. It composes with atmosphere,
provides a refracted sky window and total internal reflection, and exposes bounded
shafts, projected caustics and the optional native suspended-particle adapter.
Quality settings change work and resource sizes. The qualification record identifies
approximations and the platforms and visual scenes that remain unverified.
