# Renderer benchmarks

Run the native instancing benchmark from `packages/gpu3d_native`:

```sh
dart run benchmark/instancing.dart
```

It checks 1000 and 10000 copies, one opaque draw, zero instance uploads on camera
motion, 112-byte single-copy updates and stable GPU residency. Each case warms
up for 10 frames and reports 20 samples. Timings include Dart capture, native
worker work, GPU completion and explicit 128x128 pixel readback. They do not
measure presentation FPS or GPU timestamps.

Local macOS Metal results on 28 September 2026:

| Copies | Edit | Median readback frame | P95 | Upload per frame |
| --- | --- | --- | --- | --- |
| 1000 | Camera | 1.765 ms | 2.930 ms | 0 B |
| 1000 | One transform | 1.893 ms | 3.206 ms | 112 B |
| 10000 | Camera | 1.191 ms | 2.946 ms | 0 B |
| 10000 | One transform | 2.438 ms | 3.231 ms | 112 B |

These short runs include scheduling and warm-up variation. Use repeated runs on
your target device before making a performance decision. Native Rust tests also
inspect the actual draw loop and pipeline cache, confirming one draw and one
pipeline variant for 10000 opaque copies.

## HDR effects

Build and run the AOT bundle from `packages/gpu3d_native`:

```sh
dart build cli -t benchmark/post_processing.dart -o build/renderer-profile
build/renderer-profile/bundle/bin/post_processing
```

The bundle includes its native library. `dart compile exe` alone does not.
The 28 September run used an Apple M3 Max with 40 GPU cores and Metal. Each
case renders 400 instanced spheres, warms 30 frames, then measures 300 frames.
Times include scene capture, worker submission, GPU completion and RGBA readback.
They are not presentation FPS or GPU timestamps.

| Pixels | Profile | Median | P95 | P99 | Resident resource payload |
| --- | --- | --- | --- | --- | --- |
| 640×360 | ldr | 0.651 ms | 1.113 ms | 1.320 ms | 0.06 MiB |
| 640×360 | hdr | 0.862 ms | 1.165 ms | 1.375 ms | 0.06 MiB |
| 640×360 | msaa4 | 0.712 ms | 1.023 ms | 1.292 ms | 0.06 MiB |
| 640×360 | bloom | 0.901 ms | 1.085 ms | 1.545 ms | 4.89 MiB |
| 640×360 | bloom+spatial | 0.953 ms | 1.169 ms | 1.480 ms | 6.65 MiB |
| 1280×720 | ldr | 0.853 ms | 1.192 ms | 1.760 ms | 0.06 MiB |
| 1280×720 | hdr | 0.785 ms | 1.073 ms | 1.260 ms | 0.06 MiB |
| 1280×720 | msaa4 | 1.043 ms | 1.266 ms | 1.555 ms | 0.06 MiB |
| 1280×720 | bloom | 1.021 ms | 1.186 ms | 1.526 ms | 19.39 MiB |
| 1280×720 | bloom+spatial | 1.057 ms | 1.258 ms | 1.814 ms | 26.42 MiB |

Every measured frame uploaded zero geometry/instance/texture bytes. Resource
counts and payload residency remained stable within each profile and returned
to zero after its view was disposed. The counters include scene and graph
resources, but exclude internal frame targets, driver padding and staging.
The GPU time field remains null.

Scheduling and warm-up still affect these results, including cases where four
samples measure faster than one. This does not imply that MSAA is free. Power
and thermal state were not measured. Repeat the run on your target device and
use a presentation benchmark for frame pacing.

[The 300-frame Metal run](2026-09-28-post-processing-metal-300.json) records P99,
maximum latency, source identity and null values for unavailable measurements.
[The initial 20-frame run](2026-09-28-post-processing-metal.json) is retained for
comparison. The warmer, longer run is not evidence of a renderer optimization.

## Temporal reconstruction

The 29 September AOT run adds temporal AA and bloom with temporal AA to the same
400-sphere fixture on the Apple M3 Max. Each case measures 300 frames after warmup.

| Pixels | Profile | Median | P95 | P99 | Temporal payload |
| --- | --- | --- | --- | --- | --- |
| 640x360 | HDR | 0.737 ms | 0.993 ms | 1.202 ms | 0 MiB |
| 640x360 | TAA | 1.378 ms | 1.631 ms | 1.775 ms | 11.53 MiB |
| 640x360 | Bloom + TAA | 1.507 ms | 1.673 ms | 1.731 ms | 11.53 MiB |
| 1280x720 | HDR | 1.401 ms | 1.657 ms | 1.827 ms | 0 MiB |
| 1280x720 | TAA | 2.073 ms | 2.300 ms | 2.354 ms | 45.81 MiB |
| 1280x720 | Bloom + TAA | 2.209 ms | 2.741 ms | 3.123 ms | 45.81 MiB |

Temporal and scoped resource allocations stayed constant during each measured
case and returned to zero after view disposal. Temporal payload counts history,
working targets and copied motion buffers. It excludes normal scene targets,
transient uniforms and driver overhead. Bloom allocations remain in the scoped
resource column of the JSON.

These timings include explicit readback. They are not presentation FPS. GPU
timestamps, power and thermal state remain unknown. This run followed validation
workloads, so compare profiles within the run rather than treating differences
from the previous day's measurements as a renderer regression or improvement.

[The temporal run](2026-09-29-temporal-metal-300.json) records all seven profiles,
source identity, readback bytes and separate temporal residency.
