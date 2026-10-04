# Ocean quality qualification, 4 October 2026

W11 is in progress. These runs establish native resource behavior on macOS Metal.
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

## Remaining checks

- Real buoyancy trajectories across native quality transitions and render rates.
- Optional spray quality admission and capacity changes under the fixed clock.
- Full profile work mapping and combined qualification record.
- W12 lab scenes, real Earth data gate, performance and platform measurements.
- User visual review, including motion and orbit-to-surface presentation.
