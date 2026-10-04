# Underwater qualification

W7 is implemented and checked on the native offscreen backend. These fixtures do
not establish final visual quality, mobile performance or a completed Ocean Lab.

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
shaft contribution. The full ocean rendering suite also covers the surface, reflection and stitched-LOD regressions.

## Waterline and suspended particles

The Snell-window fixture checks refracted environmental radiance and total internal
reflection with both depth conventions. It catches the near-plane disappearance
case and verifies the repaired surface shader at 5 cm and 2 m near distances. A
horizontal orthographic fixture verifies air above and water below the waterline
in the same image. One hundred entry/exit cycles preserve allocation and resident
payload counters. This is not a physical GPU residency measurement.

The particle adapter uses the existing native controller. Its test verifies an
empty provider, zero allocation at zero budget, Earth-scale world positions,
existing-particle motion when the emitter moves, real capacity reduction, clearing
on exit and retirement. Adapter and controller regressions pass together (3 tests).

Underwater and caustic receiver lighting retain shared atmosphere or convolved HDR
inputs. Native checks exercise day/night atmosphere, a constant HDR irradiance
reference, and a rotated local world frame. Sunlight visibility remains explicit.

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

- Ocean rendering suite: 21 passing tests after the completed W7 changes.
- Geospatial aerial perspective, cloud inputs and medium transport: 8 passing tests.
- Integrated ocean/atmosphere, underwater, caustics and Snell window: 4 focused tests, included in the full rendering suite.
- Ocean and changed atmosphere analyzer checks, package boundaries: clean.
