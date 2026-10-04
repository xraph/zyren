# Ocean quality qualification, 4 October 2026

W11 implementation checks passed. These runs establish native resource behavior
on macOS Metal.
They do not establish professional visual acceptance or frame-rate targets.

## Native controller and view integration

The quality suite and water/stitch regression suite passed 13 checks using FVM
Dart from Flutter 3.47.5 with `RUN_NATIVE_GPU=1` and `--concurrency=1`.

The fixtures cover atomic publication, final/transition build failure, real native
allocation pressure, closure during preparation, downgrade peak admission,
persistent wave updates, native stitched geometry morphs, reflection limits,
scaled opaque capture, underwater setup, caustic resolution, missing camera-query
rollback and camera-driven topology rebuilds. The displaced shared-edge test
measured a maximum gap of 0.00000186643 metres.

## Repeated transitions

`test/quality/cycles_test.dart` passed 100 native quality fades with six wave
charts and two independent scene views (24 by 16 and 16 by 24 pixels). Both views
rendered the midpoint and final resources of every fade. The canonical source
revision stayed unchanged. Each profile returned to the same counters on every
cycle, and closure plus an empty submission returned owned resource, graph, mesh
binding and shader counts to zero.

| Effective grid | Registry allocations | Registry payload bytes | Live graphs | Mesh bindings | Mesh pipelines | Live modules | Cached modules |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 4 by 4 | 182 | 219,744 | 24 | 12 | 2 | 23 | 7 |
| 8 by 8 | 200 | 316,800 | 24 | 12 | 2 | 23 | 7 |

These are bounded functional fixtures with six root patches per view, one wave
band and zero wind. They use custom profiles, not the stock Low/Medium presets.
Registry payload is not physical GPU residency. This run is not a throughput
benchmark, real-Earth dataset check or desktop/mobile visual review.

## Generic native limits

The composed globe transition exposed the old 32-graph limit. The graph store now
admits 256 live graphs while retaining its 16 MiB descriptor allowance. A native
test filled that capacity, rejected one more graph, executed existing work,
released a slot and admitted a replacement. Three existing graph tests also passed.

Shared mesh module binding keeps per-patch bindings independent without registering
the same shader source for every patch. A native test bound 4,096 meshes to one
module, observed one pipeline, rejected the next binding, reused a released slot
and rendered after the original module owner closed. Four existing mesh shader
checks passed. The mesh descriptor allowance remains 16 MiB; binding and retained
pipeline-variant limits are 4,096 and 8,192 respectively.

## Physical independence

`zyren_geospatial_ocean_physics/test/native_quality_clock_test.dart` runs real
native GPU wave fields and water materials alongside a native physics body. The
canonical state has seed 42, resolution 8, a 64 metre band, 12 m/s wind, amplitude
0.002 and choppiness 0.5. The fixed clock advances 120 times at 60 Hz. Presentation
runs at 30, 60, 120 and 144 Hz, with alternating water visibility. The latter three
runs fade their visual grid from 4 to 8 and back while retaining the same sampler.

Maximum position and velocity differences against the 30 Hz baseline were both
zero. Rotations and angular velocities matched exactly at every physics tick.
Each presentation call left the physics step count and body state unchanged. All
11 physics bridge tests and all 15 buoyancy tests passed after this addition.

An initial amplitude 0.02 fixture failed safely at tick 23: its conservative
horizontal contraction bound was 0.801174, beyond the sampler's 0.8 admission
limit. The final amplitude 0.002 fixture gave 0.253345 at that instant. No query or
buoyancy accuracy limit was relaxed. This documents a numerical admission bound,
not a claim that larger physical seas are universally supported.

## Stock profile work

The native profile fixture uses one chart and one canonical band at resolution
512. Each stock profile allocates its selected grid, constructs the actual
reflection material, applies its opaque capture scale and emits fixed-tick spray.
Low installs no spray emitters. The other profiles each accept eight events and
produce 32 inspected droplets within their selected capacity. All four close to
zero owned allocations after an empty scene submission.

| Profile | FFT grid | Wave dispatches | Candidate payload bytes | Spray capacity | Spray payload bytes |
| --- | --- | --- | --- | --- | --- |
| Low | 64 | 22 | 1,380,936 | 0 | 0 |
| Medium | 128 | 25 | 6,068,856 | 2,048 | 559,104 |
| High | 256 | 28 | 24,160,680 | 8,192 | 2,131,968 |
| Ultra | 512 | 31 | 96,517,848 | 32,768 | 8,423,424 |

This source contains one band, so effective bands stay at one. Separate native
band-prefix tests verify allocation and dispatch reduction with multiple bands.
The full six-chart, four-band Ultra recipe exceeds its 256 MiB allowance with
this persistent layout and is rejected. This fixture does not certify that recipe.

The particle adapter now supports detached construction, retained-payload
admission, shared tick offsets and copied event watermarks. Its test verifies
that preparation does not enter the live scene, old events are not replayed,
and publication does not reset the shared clock. Changing capacity starts a new
visual population; it does not preserve living droplets or crossfade populations.
Spray remains an optional adapter outside the built-in ocean view recipe.

## Combined checks and remaining qualification

All 126 ocean tests passed with native GPU checks enabled and serial execution.
All 23 particle tests and 11 ocean physics bridge tests passed. Ocean, physics
bridge and particle analyzers passed. The package boundary and Apple ABI check
passed. Per-pass GPU timestamps and physical GPU residency remain unavailable;
the diagnostics retain null values for those measurements.

Remaining qualification:
- W12 lab scenes, real Earth data gate, performance and platform measurements.
- User visual review, including motion and orbit-to-surface presentation.
