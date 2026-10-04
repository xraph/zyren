# Underwater qualification in progress

W7 remains open. The checked slices below do not establish final visual quality,
final caustic scene review, suspended particles, mobile performance or a completed Ocean Lab.

## Surface boundary and volume transport

The native boundary capture uses the surface's wave textures, stitch controls and
morph weights. It records the nearest entering or leaving face, with no per-frame
CPU readback. A separate near plane captures interfaces hidden by the main camera's
near plane. The distance encoding has at most 8 mm of half-float quantization below
60 km; raster coverage and mesh displacement remain subject to the selected LOD.

The first native fixtures verify perspective surface facing with both depth
conventions, stale camera and transform rejection, visibility changes, and near
clipping. The underwater fixtures verify analytic absorption with perspective and
orthographic cameras, bounded-volume exits, transparent backgrounds, replacement
of an existing effect slot, and zero owned allocations after retirement.

The generic native capture API was supplied by concurrent renderer work in
`8b74a20f`. W7 consumes that public API. The first W7 slice is `538ec085`.

## Air and water composition

`AerialMediumInputs` carries one non-air interval per pixel. The producer records
transmittance and inscatter separately from its entry and exit distances. The
atmosphere integrates the far air segment, then the medium, then the near air
segment. A map uses two horizontal halves in one float texture to stay within
native sampled-texture limits.

Native tests check a fully covered interval against known transport values. They
also compare the near and far air segments with independently positioned scene
renders. The integrated ocean test writes the map during the same frame and
matches the homogeneous water reference with atmosphere haze both enabled and
disabled. Transparent output remains transparent. Existing aerial and cloud-input
regressions pass.

## Projected caustics and single scattering

The caustic pass refracts filtered wave triangles onto a bounded tangent receiver.
Additive rasterization accumulates overlapping projections. Native reductions cap
concentration and keep mean irradiance below the incoming horizontal flux. The
receiver material supplies its own Lambertian direct-sun term, including water
attenuation on the light path. It does not add a second copy of direct sunlight.

Native fixtures verify flat-water Fresnel and Beer-Lambert values, wave variation,
night, a fully shadowed visibility map, actual 16 and 32 pixel targets, disabled
allocation, failed byte admission and final resource retirement. Receiver pixels
also match the flat-water radiance reference. The model omits occluders unless you
provide visibility; its finite footprint and planar receiver are explicit limits.

Single-scattering fixtures compare a 64-step result to an analytic vertical-ray
integral. Zero steps, zero visibility and a sun below the surface produce no direct
shaft contribution. The current full ocean rendering suite has 20 passing tests.

## Current limits

- Complete visible water coverage is a caller requirement. Rays without a surface
  hit use the supplied camera surface distance; orthographic ray origins use its
  local tangent plane. This is not a global height query.
- The optical distance cap bounds integration work. It does not move the physical
  surface. Hysteresis controls submersion state, not per-pixel optical clipping.
- Incoming sunlight depth currently uses a local water-plane approximation.
  Projected shadow visibility is optional and explicitly reported as unavailable
  when absent.
- Ordered transparent foreground media and cloud overlays are not a general
  multiple-medium transport solution.
- No manual window review, FPS claim or mobile/Windows qualification is recorded.
  Native offscreen execution works while the desktop remains locked.

## Checks so far

Run native tests from their package directory so the native asset is available:

- Ocean rendering suite: 18 passing tests after the surface/volume slice.
- Geospatial aerial perspective, cloud inputs and medium transport: 8 passing tests.
- Integrated ocean/atmosphere, underwater and surface capture: 3 passing tests.
- Ocean and changed atmosphere analyzer checks, package boundaries: clean.
